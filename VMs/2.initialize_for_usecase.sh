#!/bin/bash

# Strict error handling
set -euo pipefail

# Logging configuration
readonly LOGFILE="/var/log/initialize_for_usecase.log"
readonly CONFIG_FILE="/var/log/instance_config.txt"
: > "$LOGFILE"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly L_BLUE='\033[0;94m'
readonly NC='\033[0m'

trap 'echo -e "${RED}Initialization failed. Check $LOGFILE for details${NC}" >&2' ERR

# Utility functions
log_info() {
    echo -e "${L_BLUE}[→]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

run_cmd() {
    local desc="$1"
    shift
    printf "%-60s" "$desc..."
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Running: $desc" >> "$LOGFILE"
    if "$@" >>"$LOGFILE" 2>&1; then
        echo -e "${GREEN}OK${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $desc" >> "$LOGFILE"
        return 0
    else
        echo -e "${RED}ERROR${NC}"
        log_error "Failed: $desc"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $desc" >> "$LOGFILE"
        tail -n 50 "$LOGFILE" | sed 's/^/  /' >&2
        exit 1
    fi
}

# Input validation functions
validate_hostname() {
    local hostname="$1"
    if [[ ! "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        return 1
    fi
    return 0
}

validate_domain() {
    local domain="$1"
    # Allow single-label domains (localdomain, local, internal) or FQDN
    if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        return 0  # Single-label domain
    elif [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 0  # FQDN
    fi
    return 1
}

validate_ip() {
    local ip="$1"
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 1
    fi
    local IFS='.'
    local -a octets=($ip)
    for octet in "${octets[@]}"; do
        if ((octet > 255)); then
            return 1
        fi
    done
    return 0
}

validate_cidr() {
    local cidr="$1"
    if [[ ! "$cidr" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if ((cidr < 1 || cidr > 32)); then
        return 1
    fi
    return 0
}

validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
        return 1
    fi
    return 0
}

validate_graylog_url() {
    local url="$1"
    if [[ ! "$url" =~ ^https?://[^/]+.*/?$ ]]; then
        return 1
    fi
    if [[ ! "$url" =~ /api/?$ ]]; then
        return 1
    fi
    return 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

detect_debian_version() {
    if [[ ! -f /etc/os-release ]]; then
        return 1
    fi

    source /etc/os-release
    echo "${VERSION_CODENAME:-bookworm}"
}

get_system_disk() {
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//')
    basename "$root_dev"
}

check_network_manager() {
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        echo "NetworkManager"
        return 0
    elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        echo "systemd-networkd"
        return 0
    fi
    echo "ifupdown"
    return 0
}

check_legacy_naming_enabled() {
    if grep -q "net.ifnames=0" /etc/default/grub 2>/dev/null; then
        return 0
    fi
    return 1
}

check_using_predictable_names() {
    local ifaces
    ifaces=$(ls /sys/class/net 2>/dev/null | grep -vE '^(lo|docker|bond|vlan)' | head -1)

    if [[ "$ifaces" =~ ^(ens|enp|enx|eno) ]]; then
        return 0
    fi
    return 1
}

# Returns disks that are either:
# 1. Completely unpartitioned, OR
# 2. Have partitions but none are mounted
get_unmounted_disks() {
    local system_disk
    system_disk=$(get_system_disk)

    local -a unmounted=()

    while IFS= read -r disk; do
        [[ -z "$disk" ]] && continue

        [[ "$disk" == "$system_disk" ]] && continue

        [[ ! -b "/dev/$disk" ]] && continue

        # Check if disk or any partition has a mountpoint
        # lsblk -no MOUNTPOINT returns mountpoint if mounted, empty if not
        local has_mountpoint=false
        while IFS= read -r mountpoint; do
            # If any line has non-empty mountpoint, disk is mounted
            if [[ -n "$mountpoint" ]]; then
                has_mountpoint=true
                break
            fi
        done < <(lsblk -no MOUNTPOINT "/dev/$disk" 2>/dev/null || true)

        # Add to unmounted list if nothing is mounted
        if [[ "$has_mountpoint" == false ]]; then
            unmounted+=("$disk")
        fi
    done < <(lsblk -ndo NAME,TYPE 2>/dev/null | awk '$2=="disk" {print $1}')

    # Return array
    printf '%s\n' "${unmounted[@]}"
}

############################################################# FEATURE FUNCTIONS

regenerate_machine_id() {
    run_cmd "Regenerating machine-id" bash -c '
        if [[ ! -s /etc/machine-id ]]; then
            systemd-machine-id-setup
        fi
    '

    run_cmd "Restarting D-Bus" systemctl restart dbus
}

regenerate_ssh_keys() {
    run_cmd "Removing old SSH host keys" bash -c '
        rm -f /etc/ssh/ssh_host_* || true
    '

    run_cmd "Regenerating SSH host keys" bash -c '
        if command -v dpkg-reconfigure >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive dpkg-reconfigure openssh-server
        else
            ssh-keygen -A
        fi
    '

    run_cmd "Restarting SSH service" systemctl restart ssh
}

set_hostname() {
    local new_hostname="$1"
    local domain="$2"

    run_cmd "Setting hostname" hostnamectl set-hostname "$new_hostname"

    run_cmd "Updating /etc/hosts" bash -c "
        sed -i '/^127.0.1.1/d' /etc/hosts
        echo -e \"127.0.1.1\t$new_hostname.$domain\t$new_hostname\" >> /etc/hosts
    "
}

install_zabbix() {
    local codename="$1"
    local zabbix_address="$2"
    local zabbix_port="$3"
    local hostname="$4"

    run_cmd "Installing Zabbix repository" bash -c "
        wget -qO /tmp/zabbix-key.asc https://repo.zabbix.com/zabbix-official-repo.key
        gpg --dearmor < /tmp/zabbix-key.asc > /usr/share/keyrings/zabbix-archive-keyring.gpg
        echo \"deb [signed-by=/usr/share/keyrings/zabbix-archive-keyring.gpg] https://repo.zabbix.com/zabbix/7.0/debian $codename main\" > /etc/apt/sources.list.d/zabbix.list
        rm -f /tmp/zabbix-key.asc
    "

    run_cmd "Updating package lists" apt-get update

    run_cmd "Installing Zabbix Agent 2" bash -c '
        DEBIAN_FRONTEND=noninteractive apt-get install -y zabbix-agent2 zabbix-agent2-plugin-* || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y zabbix-agent2
    '

    run_cmd "Configuring Zabbix Agent" bash -c "
        mkdir -p /var/lib/zabbix
        touch /var/lib/zabbix/zabbix_agent2.db
        chown -R zabbix:zabbix /var/lib/zabbix

        if [[ -f /etc/zabbix/zabbix_agent2.conf ]]; then
            cp /etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agent2.conf.bak
        fi

        cat > /etc/zabbix/zabbix_agent2.conf <<EOL
# Zabbix Agent 2 Configuration
PidFile=/run/zabbix/zabbix_agent2.pid
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=10
DebugLevel=3
Server=0.0.0.0/0
ServerActive=$zabbix_address:$zabbix_port
HostnameItem=system.hostname
Timeout=10
BufferSend=5
BufferSize=100
EnablePersistentBuffer=1
PersistentBufferFile=/var/lib/zabbix/zabbix_agent2.db
PersistentBufferPeriod=30d
ControlSocket=/run/zabbix/agent.sock
PluginSocket=/run/zabbix/agent.plugin.sock
Include=/etc/zabbix/zabbix_agent2.d/*.conf
Include=/etc/zabbix/zabbix_agent2.d/plugins.d/*.conf
EOL
    "

    run_cmd "Enabling Zabbix Agent" systemctl enable zabbix-agent2
}

install_graylog_sidecar() {
    local graylog_address="$1"
    local graylog_api_token="$2"
    local graylog_tags="$3"

    run_cmd "Downloading Graylog Sidecar repository" bash -c '
        wget -qO /tmp/graylog-sidecar-repo.deb https://packages.graylog2.org/repo/packages/graylog-sidecar-repository_1-5_all.deb
        dpkg -i /tmp/graylog-sidecar-repo.deb
        rm -f /tmp/graylog-sidecar-repo.deb
    '

    run_cmd "Updating package lists" apt-get update

    run_cmd "Installing Graylog Sidecar" bash -c '
        DEBIAN_FRONTEND=noninteractive apt-get install -y graylog-sidecar
    '

    local tags_yaml=""
    IFS=',' read -ra tag_array <<< "$graylog_tags"
    for tag in "${tag_array[@]}"; do
        tag=$(echo "$tag" | xargs)
        tags_yaml+="  - \"$tag\"
"
    done

    run_cmd "Configuring Graylog Sidecar" bash -c "
        if [[ -f /etc/graylog/sidecar/sidecar.yml ]]; then
            cp /etc/graylog/sidecar/sidecar.yml /etc/graylog/sidecar/sidecar.yml.bak
        fi

        cat > /etc/graylog/sidecar/sidecar.yml <<'EOL'
server_url: \"$graylog_address\"
server_api_token: \"$graylog_api_token\"
node_id: \"file:/etc/graylog/sidecar/node-id\"
node_name: \"\$(hostname)\"
update_interval: 10
tls_skip_verify: true
send_status: true
tags:
$tags_yaml
log_path: \"/var/log/graylog-sidecar\"
log_rotate_max_file_size: 100MiB
log_rotate_keep_files: 20
collector_binaries_accesslist: \"/usr/bin/filebeat,/usr/bin/packetbeat,/usr/bin/metricbeat,/usr/bin/heartbeat,/usr/bin/auditbeat,/usr/bin/journalbeat,/usr/share/filebeat/bin/filebeat,/usr/share/packetbeat/bin/packetbeat,/usr/share/metricbeat/bin/metricbeat,/usr/share/heartbeat/bin/heartbeat,/usr/share/auditbeat/bin/auditbeat,/usr/share/journalbeat/bin/journalbeat\"
EOL
    "

    run_cmd "Installing Graylog Sidecar service" bash -c '
        graylog-sidecar -service install
    '

    run_cmd "Enabling and starting Graylog Sidecar" bash -c '
        systemctl enable graylog-sidecar
        systemctl start graylog-sidecar
    '
}

# Shared function to generate interfaces file
# Parameters: $1=network_type, $2=static_ip, $3=cidr, $4=gateway, $5=dns_servers, $6=use_legacy
generate_interfaces_file() {
    local network_type="$1"
    local static_ip="$2"
    local cidr="$3"
    local gateway="$4"
    local dns_servers="$5"
    local use_legacy="$6"

    run_cmd "Backing up network config" bash -c '
        if [[ -f /etc/network/interfaces ]]; then
            cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%s)
        fi
    '

    # Determine interface names
    local all_interfaces primary_iface

    if [[ "$use_legacy" =~ ^[Yy]$ ]]; then
        # Count interfaces for eth0, eth1, etc
        local iface_count
        iface_count=$(ls /sys/class/net 2>/dev/null | grep -vE '^(lo|docker|bond|vlan)' | wc -l)
        all_interfaces=$(seq 0 $((iface_count - 1)) | sed 's/^/eth/')
        primary_iface="eth0"
    else
        # Enumerate actual interface names
        all_interfaces=$(ls /sys/class/net 2>/dev/null | grep -vE '^(lo|docker|bond|vlan)' | sort || true)
        primary_iface=$(echo "$all_interfaces" | head -1)
    fi

    if [[ -z "$all_interfaces" ]]; then
        log_error "No network interfaces found!"
        return 1
    fi

    # Log configuration
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Network Configuration Details:" >> "$LOGFILE"
    echo "  All interfaces: $all_interfaces" >> "$LOGFILE"
    echo "  Primary interface: $primary_iface" >> "$LOGFILE"
    echo "  Network type: $network_type" >> "$LOGFILE"
    echo "  Using legacy names: $use_legacy" >> "$LOGFILE"

    if [[ "$network_type" == "static" ]]; then
        echo "  Static IP: $static_ip/$cidr" >> "$LOGFILE"
        echo "  Gateway: $gateway" >> "$LOGFILE"
        echo "  DNS: $dns_servers" >> "$LOGFILE"

        run_cmd "Configuring static IP" bash -c "
            cat > /etc/network/interfaces <<'EOF'
# Network configuration - Static IP
# Generated by init.sh on \$(date)
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# Primary interface with static IP
auto $primary_iface
iface $primary_iface inet static
    address $static_ip/$cidr
    gateway $gateway
    dns-nameservers $dns_servers

EOF

            # Add other interfaces with DHCP
            for iface in $all_interfaces; do
                if [[ \"\$iface\" != \"$primary_iface\" ]]; then
                    cat >> /etc/network/interfaces <<EOF

# Additional interface
auto \$iface
iface \$iface inet dhcp

EOF
                fi
            done

            echo '[Network Config] Generated interfaces file:' >> $LOGFILE
            cat /etc/network/interfaces >> $LOGFILE
        "
    else
        run_cmd "Configuring DHCP" bash -c "
            cat > /etc/network/interfaces <<'EOF'
# Network configuration - DHCP
# Generated by init.sh on \$(date)
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

EOF

            for iface in $all_interfaces; do
                cat >> /etc/network/interfaces <<EOF

auto \$iface
iface \$iface inet dhcp

EOF
            done

            echo '[Network Config] Generated interfaces file:' >> $LOGFILE
            cat /etc/network/interfaces >> $LOGFILE
        "
    fi
}

configure_network_naming() {
    local legacy_naming="$1"

    if [[ "$legacy_naming" =~ ^[Yy]$ ]]; then
        run_cmd "Configuring legacy network naming" bash -c '
            if ! grep -q "net.ifnames=0" /etc/default/grub; then
                sed -i "s/GRUB_CMDLINE_LINUX=\"\(.*\)\"/GRUB_CMDLINE_LINUX=\"\1 net.ifnames=0 biosdevname=0\"/" /etc/default/grub
                update-grub
            fi
        '

        log_info "Note: Interface names will change to eth0, eth1, etc. after reboot"
    fi
}

configure_network_simple() {
    local network_type="$1"
    local static_ip="$2"
    local cidr="$3"
    local gateway="$4"
    local dns_servers="$5"
    local use_legacy="$6"

    generate_interfaces_file "$network_type" "$static_ip" "$cidr" "$gateway" "$dns_servers" "$use_legacy"
}

mount_additional_disk() {
    local data_disk="$1"
    local mount_point="$2"

    # Check if disk has partitions
    local has_partitions=false
    local partition=""

    if lsblk -n "/dev/$data_disk" 2>/dev/null | grep -q part; then
        has_partitions=true
        # Get first partition
        if [[ "$data_disk" =~ nvme ]]; then
            partition="/dev/${data_disk}p1"
        else
            partition="/dev/${data_disk}1"
        fi

        log_info "Disk /dev/$data_disk has existing partition: $partition"

        # Check if partition has filesystem
        if blkid "$partition" >/dev/null 2>&1; then
            local fs_type
            fs_type=$(blkid -s TYPE -o value "$partition" 2>/dev/null || echo "unknown")
            log_warning "Partition has existing filesystem: $fs_type"
            log_warning "This could contain data from previous use"
            echo ""
            echo "Options:"
            echo "  1) Format (DESTROYS ALL DATA - creates fresh ext4 filesystem)"
            echo "  2) Mount as-is (keeps existing data)"
            echo "  3) Skip (don't mount this disk)"
            echo ""

            local choice
            read -rp "Choose option [2]: " choice
            choice="${choice:-2}"

            case "$choice" in
                1)
                    log_warning "Formatting $partition - ALL DATA WILL BE LOST"
                    read -rp "Type 'yes' to confirm: " confirm
                    if [[ "$confirm" == "yes" ]]; then
                        run_cmd "Formatting $partition" mkfs.ext4 -F "$partition"
                    else
                        log_info "Format cancelled - mounting as-is"
                    fi
                    ;;
                2)
                    log_info "Mounting existing filesystem without formatting"
                    ;;
                3)
                    log_info "Skipping disk mount"
                    return 0
                    ;;
                *)
                    log_warning "Invalid choice - mounting as-is"
                    ;;
            esac
        else
            # Partition exists but no filesystem
            log_info "Partition exists but has no filesystem"
            run_cmd "Creating ext4 filesystem" mkfs.ext4 -F "$partition"
        fi
    else
        # No partitions - create new partition and format

        run_cmd "Creating partition table" bash -c "
            parted -s /dev/$data_disk mklabel gpt
            parted -s /dev/$data_disk mkpart primary ext4 0% 100%
        "

        sleep 2

        if [[ "$data_disk" =~ nvme ]]; then
            partition="/dev/${data_disk}p1"
        else
            partition="/dev/${data_disk}1"
        fi

        run_cmd "Creating ext4 filesystem" mkfs.ext4 -F "$partition"
    fi

    run_cmd "Creating mount point" mkdir -p "$mount_point"

    run_cmd "Configuring fstab" bash -c "
        uuid=\$(blkid -s UUID -o value $partition)
        if ! grep -q \"\$uuid\" /etc/fstab 2>/dev/null; then
            echo \"UUID=\$uuid $mount_point ext4 defaults,noatime,nofail 0 2\" >> /etc/fstab
        fi
    "

    run_cmd "Mounting filesystem" mount -a

    log_success "Disk mounted at $mount_point"
}

create_swapfile() {
    local swap_size="$1"
    local swap_file="/swapfile"

    run_cmd "Creating swapfile ($swap_size GB)" bash -c "
        fallocate -l ${swap_size}G $swap_file
        chmod 600 $swap_file
        mkswap $swap_file
    "

    run_cmd "Enabling swapfile" bash -c "
        swapon $swap_file
        echo '$swap_file none swap sw 0 0' >> /etc/fstab
    "

    log_success "Swapfile created and enabled"
}

clone_bash_scripts() {
    run_cmd "Installing git (if needed)" bash -c '
        if ! command -v git &>/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y git
        fi
    '

    run_cmd "Cloning bash-scripts repository" bash -c '
        cd /home/debian
        if [[ -d "bash-scripts" ]]; then
            rm -rf bash-scripts
        fi
        sudo -u debian git clone https://github.com/kamil-lada/bash-scripts.git
    '
}

start_services() {
    run_cmd "Ensuring SSH is running" systemctl start ssh

    if systemctl list-unit-files | grep -q zabbix-agent2; then
        run_cmd "Starting Zabbix Agent" systemctl start zabbix-agent2 || true
    fi

    if systemctl list-unit-files | grep -q graylog-sidecar; then
        run_cmd "Starting Graylog Sidecar" systemctl start graylog-sidecar || true
    fi
}

############################################################# MAIN

show_intro() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                                                                ║${NC}"
    echo -e "${BLUE}║          VM Instance Initialization (Phase 2)                 ║${NC}"
    echo -e "${BLUE}║                                                                ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    log_info "This script will configure instance-specific settings:"
    echo "  • Hostname and domain"
    echo "  • Network (keep DHCP or configure static IP)"
    echo "  • Optional: Zabbix Agent"
    echo "  • Optional: Graylog Sidecar"
    echo "  • Optional: Additional disk mounting"
    echo ""
    echo -e "${YELLOW}How to answer prompts:${NC}"
    echo "  • Default values shown in square brackets: [like this]"
    echo "  • Just press Enter to accept default"
    echo "  • Capital letter shows default: (Y/n)=Yes, (y/N)=No"
    echo ""
}

main() {
    check_root
    show_intro

    log_section "Current Status"

    log_info "Current network configuration:"
    ip -br addr show | grep -v "^lo"
    echo ""

    local codename
    codename=$(detect_debian_version)
    log_info "Debian version: $codename"

    local net_manager
    net_manager=$(check_network_manager)
    log_info "Network manager: $net_manager"

    if check_legacy_naming_enabled && check_using_predictable_names; then
        log_warning "Legacy network naming is configured but not yet active"
        log_warning "Interface names will change on next reboot (ens18 → eth0, etc.)"
    fi

    echo ""

    log_section "Instance Configuration"

    # Hostname
    local new_hostname
    while true; do
        read -rp "Enter hostname (e.g., web01): " new_hostname
        if [[ -z "$new_hostname" ]]; then
            log_error "Hostname cannot be empty"
            continue
        fi
        if ! validate_hostname "$new_hostname"; then
            log_error "Invalid hostname (use a-z, 0-9, hyphens only)"
            continue
        fi
        break
    done

    # Domain
    local domain
    while true; do
        read -rp "Enter domain (e.g., example.com) [localdomain]: " domain
        domain="${domain:-localdomain}"
        if validate_domain "$domain"; then
            break
        fi
        log_error "Invalid domain format"
    done
    echo ""

    # Zabbix installation
    local install_zabbix="n" zabbix_address="" zabbix_port=""
    read -rp "Install Zabbix Agent 2? (y/N): " install_zabbix
    install_zabbix="${install_zabbix:-n}"

    if [[ "$install_zabbix" =~ ^[Yy]$ ]]; then
        echo ""
        log_info "Zabbix Agent configuration:"

        while true; do
            read -rp "Zabbix server address (IP or hostname): " zabbix_address
            if [[ -z "$zabbix_address" ]]; then
                log_error "Zabbix address cannot be empty"
                continue
            fi
            if validate_ip "$zabbix_address" || [[ "$zabbix_address" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,253}[a-zA-Z0-9])?$ ]]; then
                break
            fi
            log_error "Invalid address format"
        done

        while true; do
            read -rp "Zabbix server port [10051]: " zabbix_port
            zabbix_port="${zabbix_port:-10051}"
            if validate_port "$zabbix_port"; then
                break
            fi
            log_error "Invalid port (must be 1-65535)"
        done
    fi
    echo ""

    # Graylog Sidecar installation
    local install_graylog="n" graylog_address="" graylog_api_token="" graylog_tags=""
    read -rp "Install Graylog Sidecar? (y/N): " install_graylog
    install_graylog="${install_graylog:-n}"

    if [[ "$install_graylog" =~ ^[Yy]$ ]]; then
        echo ""
        log_info "Graylog Sidecar configuration:"

        while true; do
            read -rp "Graylog server URL (e.g., http://graylog.example.com:9000/api/): " graylog_address
            if [[ -z "$graylog_address" ]]; then
                log_error "Graylog server URL cannot be empty"
                continue
            fi
            # Ensure URL ends with /api/
            if [[ ! "$graylog_address" =~ /api/?$ ]]; then
                if [[ "$graylog_address" =~ /$ ]]; then
                    graylog_address="${graylog_address}api/"
                else
                    graylog_address="${graylog_address}/api/"
                fi
            fi
            # Ensure it ends with /
            if [[ ! "$graylog_address" =~ /$ ]]; then
                graylog_address="${graylog_address}/"
            fi
            if validate_graylog_url "$graylog_address"; then
                break
            fi
            log_error "Invalid URL format (must be http:// or https:// and end with /api/)"
        done

        while true; do
            read -rp "Graylog API token: " graylog_api_token
            if [[ -z "$graylog_api_token" ]]; then
                log_error "API token cannot be empty"
                continue
            fi
            break
        done

        read -rp "Additional tags (comma-separated) [leave empty for 'linux' only]: " graylog_tags
        if [[ -z "$graylog_tags" ]]; then
            graylog_tags="linux"
        else
            graylog_tags="linux,$graylog_tags"
        fi
    fi
    echo ""

    # Network configuration
    log_info "Script supports only native server network manager - ifupdown"
    echo ""

    local other_manager
    other_manager=$(check_network_manager)

    local configure_network="yes"
    if [[ "$other_manager" != "ifupdown" ]]; then
        log_warning "═══════════════════════════════════════════════════════"
        log_warning "  $other_manager is active on this system"
        log_warning "  This script only configures ifupdown (native)"
        log_warning "  Network configuration will be skipped"
        log_warning "  Please configure network manually or disable $other_manager"
        log_warning "═══════════════════════════════════════════════════════"
        echo ""
        read -rp "Press Enter to continue without network configuration..."
        configure_network="no"
    fi

    local network_type="" static_ip="" cidr="" gateway="" dns_servers="" enable_legacy_naming="n"

    if [[ "$configure_network" == "yes" ]]; then
        # Check current naming and offer legacy naming if predictable is in use
        if check_using_predictable_names; then
            log_info "Currently using predictable interface names (ens*, enp*, etc.)"
            if check_legacy_naming_enabled; then
                log_info "Legacy naming already configured in GRUB (will activate on reboot)"
                read -rp "Switch to legacy names (eth0, eth1) now? (y/N): " enable_legacy_naming
                enable_legacy_naming="${enable_legacy_naming:-n}"
            else
                read -rp "Switch to legacy names (eth0, eth1)? (y/N): " enable_legacy_naming
                enable_legacy_naming="${enable_legacy_naming:-n}"
            fi
        else
            log_info "Using legacy interface names (eth0, eth1, etc.)"
            enable_legacy_naming="n"  # Already using legacy names
        fi

        # Configure GRUB if enabling legacy naming
        if [[ "$enable_legacy_naming" =~ ^[Yy]$ ]]; then
            configure_network_naming "$enable_legacy_naming"
        fi

        echo ""

        while true; do
            read -rp "Choose IP assignment method (dhcp/static) [dhcp]: " network_type
            network_type="${network_type:-dhcp}"
            network_type=$(echo "$network_type" | tr '[:upper:]' '[:lower:]')

            if [[ "$network_type" == "dhcp" || "$network_type" == "static" ]]; then
                break
            fi
            log_error "Please enter 'dhcp' or 'static'"
        done

        if [[ "$network_type" == "static" ]]; then
            echo ""
            log_info "Static IP configuration:"

            while true; do
                read -rp "IP address (e.g., 192.168.1.100): " static_ip
                if [[ -z "$static_ip" ]]; then
                    log_error "IP address cannot be empty"
                    continue
                fi
                if validate_ip "$static_ip"; then
                    break
                fi
                log_error "Invalid IP address format"
            done

            while true; do
                read -rp "Network prefix (CIDR notation, e.g., 24 for /24) [24]: " cidr
                cidr="${cidr:-24}"
                if validate_cidr "$cidr"; then
                    break
                fi
                log_error "Invalid CIDR (must be 1-32)"
            done

            # Calculate default gateway (same network, .1 at end)
            local default_gateway
            default_gateway=$(echo "$static_ip" | sed 's/\.[0-9]*$/\.1/')

            while true; do
                read -rp "Gateway [$default_gateway]: " gateway
                gateway="${gateway:-$default_gateway}"
                if validate_ip "$gateway"; then
                    break
                fi
                log_error "Invalid gateway IP format"
            done

            # DNS configuration - gateway is always primary, user can change secondary
            log_info "DNS Configuration:"
            log_info "Primary DNS will be set to gateway: $gateway"
            local secondary_dns
            read -rp "Secondary DNS [9.9.9.9]: " secondary_dns
            secondary_dns="${secondary_dns:-9.9.9.9}"

            # Validate secondary DNS
            if ! validate_ip "$secondary_dns"; then
                log_warning "Invalid secondary DNS, using default: 9.9.9.9"
                secondary_dns="9.9.9.9"
            fi

            dns_servers="$gateway $secondary_dns"
        fi
    fi
    echo ""

    # Optional disk mounting - check first, then ask
    local mount_disk="n" data_disk="" mount_point="/data"

    # Check for unmounted disks first
    local -a unmounted_disks
    mapfile -t unmounted_disks < <(get_unmounted_disks)

    # Only proceed if disks exist
    if [[ ${#unmounted_disks[@]} -gt 0 ]]; then
        # First pass: check if any disks are valid
        local idx=1
        local has_valid_disks=false
        local -a valid_disk_info=()

        for disk in "${unmounted_disks[@]}"; do
            local size model
            size=$(lsblk -ndo SIZE "/dev/$disk" 2>/dev/null | head -1 || echo "")
            model=$(lsblk -ndo MODEL "/dev/$disk" 2>/dev/null | head -1 || echo "")

            if [[ -n "$size" && "$size" != "unknown" ]]; then
                has_valid_disks=true
                valid_disk_info+=(" $idx. $disk   $size   ${model:-unknown}")
                ((idx++))
            fi
        done

        # Only show list and ask if we found valid disks
        if [[ "$has_valid_disks" == true ]]; then
            log_info "Available unmounted disks:"
            printf '%s\n' "${valid_disk_info[@]}"
            echo ""
            read -rp "Mount additional disk? (y/N): " mount_disk
            mount_disk="${mount_disk:-n}"

            if [[ "$mount_disk" =~ ^[Yy]$ ]]; then
                while true; do
                    read -rp "Enter disk name (e.g., ${unmounted_disks[0]}): " data_disk
                    if [[ -z "$data_disk" ]]; then
                        log_error "Disk name cannot be empty"
                        continue
                    fi

                    local found=false
                    for disk in "${unmounted_disks[@]}"; do
                        if [[ "$disk" == "$data_disk" ]]; then
                            found=true
                            break
                        fi
                    done

                    if [[ "$found" == false ]]; then
                        log_error "Disk must be one of the unmounted disks listed above"
                        continue
                    fi

                    break
                done

                read -rp "Mount point [/data]: " mount_point
                mount_point="${mount_point:-/data}"
            fi
        fi
    fi
    echo ""

    # Swapfile configuration
    local create_swap="n" swap_size="1"
    log_info "Swapfile Configuration"
    log_info "Note: Swap is not mandatory if VM uses memory ballooning (e.g., Proxmox)"
    read -rp "Create swapfile? (y/N): " create_swap
    create_swap="${create_swap:-n}"

    if [[ "$create_swap" =~ ^[Yy]$ ]]; then
        read -rp "Swapfile size in GB [1]: " swap_size
        swap_size="${swap_size:-1}"

        # Validate swap size is a number
        if [[ ! "$swap_size" =~ ^[0-9]+$ ]]; then
            log_warning "Invalid size, using default: 1GB"
            swap_size="1"
        fi
    fi
    echo ""

    # Bash scripts repository
    local clone_repo="n"
    log_info "Bash Scripts Repository"
    log_info "Clone common server installer scripts (Docker, databases, etc.)?"
    read -rp "Clone bash-scripts repository to /home/debian? (y/N): " clone_repo
    clone_repo="${clone_repo:-n}"
    echo ""

    # Summary
    log_section "Configuration Summary"

    echo "  Hostname: $new_hostname"
    echo "  Domain: $domain"
    echo "  FQDN: $new_hostname.$domain"
    if [[ "$install_zabbix" =~ ^[Yy]$ ]]; then
        echo "  Zabbix: $zabbix_address:$zabbix_port"
    fi
    if [[ "$install_graylog" =~ ^[Yy]$ ]]; then
        echo "  Graylog: $graylog_address"
        echo "  Graylog tags: $graylog_tags"
    fi

    if [[ "$configure_network" == "yes" ]]; then
        echo "  Network: $network_type"
        if [[ "$enable_legacy_naming" =~ ^[Yy]$ ]]; then
            echo "  Interface naming: Legacy (eth0, eth1) - will apply on reboot"
        fi
        if [[ "$network_type" == "static" ]]; then
            echo "    IP: $static_ip/$cidr"
            echo "    Gateway: $gateway"
            echo "    DNS: $dns_servers"
        fi
    else
        echo "  Network: Skipped (other network manager active)"
    fi

    if [[ "$mount_disk" =~ ^[Yy]$ ]]; then
        echo "  Mount disk: /dev/$data_disk → $mount_point"
    fi

    if [[ "$create_swap" =~ ^[Yy]$ ]]; then
        echo "  Swapfile: ${swap_size}GB at /swapfile"
    fi

    if [[ "$clone_repo" =~ ^[Yy]$ ]]; then
        echo "  Bash scripts: Clone to /home/debian/bash-scripts"
    fi
    echo ""

    read -rp "Proceed with initialization? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Aborted by user"
        exit 0
    fi

    # Save configuration
    cat > "$CONFIG_FILE" <<EOF
# Instance Configuration
# Generated: $(date -Iseconds)
HOSTNAME=$new_hostname
DOMAIN=$domain
FQDN=$new_hostname.$domain
INSTALL_ZABBIX=$install_zabbix
INSTALL_GRAYLOG=$install_graylog
CONFIGURE_NETWORK=$configure_network
EOF

    if [[ "$configure_network" == "yes" ]]; then
        cat >> "$CONFIG_FILE" <<EOF
NETWORK_TYPE=$network_type
ENABLE_LEGACY_NAMING=$enable_legacy_naming
EOF

        if [[ "$network_type" == "static" ]]; then
            cat >> "$CONFIG_FILE" <<EOF
STATIC_IP=$static_ip
CIDR=$cidr
GATEWAY=$gateway
DNS_SERVERS=$dns_servers
EOF
        fi
    fi

    if [[ "$mount_disk" =~ ^[Yy]$ ]]; then
        cat >> "$CONFIG_FILE" <<EOF
MOUNT_DISK=yes
DATA_DISK=$data_disk
MOUNT_POINT=$mount_point
EOF
    fi

    if [[ "$create_swap" =~ ^[Yy]$ ]]; then
        cat >> "$CONFIG_FILE" <<EOF
CREATE_SWAP=yes
SWAP_SIZE=$swap_size
EOF
    fi

    if [[ "$clone_repo" =~ ^[Yy]$ ]]; then
        cat >> "$CONFIG_FILE" <<EOF
CLONE_REPO=yes
EOF
    fi

    echo ""
    log_section "System Initialization"

    regenerate_machine_id
    regenerate_ssh_keys
    set_hostname "$new_hostname" "$domain"

    if [[ "$install_zabbix" =~ ^[Yy]$ ]]; then
        install_zabbix "$codename" "$zabbix_address" "$zabbix_port" "$new_hostname.$domain"
    fi

    if [[ "$install_graylog" =~ ^[Yy]$ ]]; then
        install_graylog_sidecar "$graylog_address" "$graylog_api_token" "$graylog_tags"
    fi

    if [[ "$configure_network" == "yes" ]]; then
        configure_network_simple "$network_type" "$static_ip" "$cidr" "$gateway" "$dns_servers" "$enable_legacy_naming"
    fi

    if [[ "$mount_disk" =~ ^[Yy]$ ]]; then
        mount_additional_disk "$data_disk" "$mount_point"
    fi

    if [[ "$create_swap" =~ ^[Yy]$ ]]; then
        create_swapfile "$swap_size"
    fi

    if [[ "$clone_repo" =~ ^[Yy]$ ]]; then
        clone_bash_scripts
    fi

    start_services

    echo ""
    log_section "Initialization Complete"

    log_success "All configuration completed successfully!"
    echo ""

    log_info "System Information:"
    echo "  Hostname: $(hostname)"
    echo "  FQDN: $(hostname -f 2>/dev/null || echo "$new_hostname.$domain")"
    echo "  Machine-ID: $(cat /etc/machine-id)"
    echo ""

    log_info "Current Network:"
    ip -br addr show | grep -v "^lo" | while read -r line; do
        echo "  $line"
    done
    echo ""

    if [[ "$create_swap" =~ ^[Yy]$ ]]; then
        log_info "Swap Configuration:"
        swapon --show | tail -n +2 | while read -r line; do
            echo "  $line"
        done
        echo ""
    fi

    if [[ "$clone_repo" =~ ^[Yy]$ ]]; then
        log_info "Bash Scripts Repository:"
        echo "  Location: /home/debian/bash-scripts"
        echo "  Owner: debian"
        echo ""
    fi

    if [[ "$configure_network" == "yes" && "$network_type" == "static" ]]; then
        log_info "Static IP configured (will be applied after reboot):"
        echo "  IP: $static_ip/$cidr"
        echo "  Gateway: $gateway"
        echo "  DNS: $dns_servers"
        echo ""
        log_warning "IMPORTANT: Network config written but NOT applied yet"
        log_warning "Current DHCP will continue until reboot"
        log_warning "After reboot, connect to: ssh debian@$static_ip"
    fi
    echo ""

    log_info "Service Status:"
    systemctl is-active --quiet ssh && echo "  ✓ SSH: Running" || echo "  ✗ SSH: Stopped"
    if [[ "$install_zabbix" =~ ^[Yy]$ ]]; then
        systemctl is-active --quiet zabbix-agent2 && echo "  ✓ Zabbix Agent: Running" || echo "  ✗ Zabbix Agent: Stopped"
    fi
    if [[ "$install_graylog" =~ ^[Yy]$ ]]; then
        systemctl is-active --quiet graylog-sidecar && echo "  ✓ Graylog Sidecar: Running" || echo "  ✗ Graylog Sidecar: Stopped"
    fi
    systemctl is-active --quiet qemu-guest-agent && echo "  ✓ QEMU Guest Agent: Running" || echo "  ✗ QEMU Guest Agent: Stopped"
    echo ""

    log_info "Configuration saved to: $CONFIG_FILE"
    log_info "Detailed log: $LOGFILE"
    echo ""

    log_info "A reboot is required to apply all changes"
    echo ""

    read -rp "Reboot now? (Y/n): " reboot_now
    reboot_now="${reboot_now:-y}"

    if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
        log_info "Syncing filesystems..."
        sync
        log_info "Rebooting in 3 seconds... (Ctrl+C to cancel)"
        sleep 1
        echo "2..."
        sleep 1
        echo "1..."
        sleep 1
        systemctl reboot
    else
        log_info "Please reboot manually when ready: sudo reboot"
        if [[ "$configure_network" == "yes" && "$network_type" == "static" ]]; then
            log_warning "Remember: Network changes will only take effect after reboot"
        fi
    fi
}

main "$@"