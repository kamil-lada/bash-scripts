#!/bin/bash
# Common library for template and init scripts
# Source: source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

############################################################# COLORS
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly L_BLUE='\033[0;94m'
readonly NC='\033[0m'

############################################################# LOGGING
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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Running: $desc" >> "${LOGFILE:-/dev/null}"
    if "$@" >>"${LOGFILE:-/dev/null}" 2>&1; then
        echo -e "${GREEN}OK${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $desc" >> "${LOGFILE:-/dev/null}"
        return 0
    else
        echo -e "${RED}ERROR${NC}"
        log_error "Failed: $desc"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $desc" >> "${LOGFILE:-/dev/null}"
        tail -n 50 "${LOGFILE:-/dev/null}" | sed 's/^/  /' >&2
        exit 1
    fi
}

############################################################# SYSTEM CHECKS
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

detect_debian_version() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "/etc/os-release not found"
        exit 1
    fi
    source /etc/os-release
    if [[ "$ID" != "debian" ]]; then
        log_error "This script is for Debian only (detected: $ID)"
        exit 1
    fi
    local version="${VERSION_ID:-unknown}"
    if [[ "$version" != "12" && "$version" != "13" ]]; then
        log_error "This script supports Debian 12 and 13 only (detected: $version)"
        exit 1
    fi
    echo "${VERSION_CODENAME:-bookworm}"
}

is_lxc() {
    if command -v systemd-detect-virt &>/dev/null; then
        systemd-detect-virt --container &>/dev/null && return 0
    fi
    if grep -qa container /proc/1/environ 2>/dev/null; then
        return 0
    fi
    if [[ -f /proc/self/cgroup ]] && grep -q "lxc" /proc/self/cgroup 2>/dev/null; then
        return 0
    fi
    return 1
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

check_network_connectivity() {
    local test_host="deb.debian.org"
    log_info "Checking network connectivity..."
    if ping -c 1 -W 5 "$test_host" &>/dev/null; then
        log_success "Network connectivity OK"
        return 0
    fi
    log_warning "Cannot reach $test_host via ping"
    if getent hosts "$test_host" &>/dev/null; then
        log_success "DNS resolution OK (ICMP blocked but network reachable)"
        return 0
    fi
    log_error "No network connectivity to $test_host"
    return 1
}

check_disk_space() {
    local min_free_mb="${1:-500}"
    local available_mb
    available_mb=$(df -m / | tail -1 | awk '{print $4}')
    if (( available_mb < min_free_mb )); then
        log_error "Insufficient disk space: ${available_mb}MB available, need ${min_free_mb}MB"
        return 1
    fi
    log_info "Disk space OK: ${available_mb}MB free"
    return 0
}

############################################################# VALIDATION
validate_hostname() {
    local hostname="$1"
    if [[ ! "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        return 1
    fi
    return 0
}

validate_domain() {
    local domain="$1"
    if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        return 0
    elif [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 0
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

############################################################# CONFIG
load_config() {
    local config_path="$1"
    if [[ -f "$config_path" ]]; then
        source "$config_path"
        log_info "Config loaded from: $config_path"
    else
        log_info "No config file, using interactive mode"
    fi
    return 0
}

check_package_in_repo() {
    local package="$1"
    apt-cache show "$package" &>/dev/null
    return $?
}

############################################################# TIME SYNC
configure_time_sync() {
    local timezone="$1"

    run_cmd "Setting timezone to $timezone" timedatectl set-timezone "$timezone"

    if is_lxc; then
        log_info "LXC detected — checking host time sync..."
        if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
            log_success "Host time sync active (LXC inherits host clock)"
            return 0
        else
            log_warning "Host time sync not detected — container may drift"
            log_info "This is normal if Proxmox host is properly configured"
            return 0
        fi
    fi

    # VM: try timesyncd first, then chrony
    if systemctl list-unit-files 2>/dev/null | grep -q systemd-timesyncd; then
        run_cmd "Enabling NTP via timesyncd" timedatectl set-ntp true
        run_cmd "Restarting timesyncd" systemctl restart systemd-timesyncd
        if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
            log_success "Time sync configured via systemd-timesyncd"
            return 0
        fi
    fi

    if ! command -v chronyd &>/dev/null; then
        run_cmd "Installing chrony" bash -c '
        DEBIAN_FRONTEND=noninteractive apt-get install -y chrony
        '
    fi

    run_cmd "Enabling chrony" systemctl enable chrony
    run_cmd "Starting chrony" systemctl start chrony

    if systemctl is-active --quiet chrony; then
        log_success "Time sync configured via chrony"
    else
        log_warning "Could not configure time sync automatically"
    fi
}

############################################################# NETWORK
configure_network() {
    local network_type="$1"
    local static_ip="$2"
    local cidr="$3"
    local gateway="$4"
    local dns_servers="$5"
    local use_legacy="${6:-n}"

    # LXC: Proxmox manages network — skip internal configuration
    if is_lxc; then
        log_info "LXC detected — Proxmox manages network configuration"
        if [[ "$network_type" == "static" ]]; then
            log_warning "Static IP requested but LXC network is managed by Proxmox"
            log_warning "To set static IP, use Proxmox instead:"
            log_warning "  pct set <vmid> --ip ${static_ip}/${cidr} --gw ${gateway}"
        fi
        log_info "Skipping internal network configuration"
        return 0
    fi

    # VM: configure via ifupdown
    run_cmd "Backing up network config" bash -c '
    if [[ -f /etc/network/interfaces ]]; then
        cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%s)
    fi
    '

    if [[ "$use_legacy" =~ ^[Yy]$ ]]; then
        run_cmd "Configuring legacy network naming" bash -c '
        if ! grep -q "net.ifnames=0" /etc/default/grub; then
            sed -i "s/GRUB_CMDLINE_LINUX=\"\(.*\)\"/GRUB_CMDLINE_LINUX=\"\1 net.ifnames=0 biosdevname=0\"/" /etc/default/grub
            update-grub
        fi
        '
        log_info "Interface names will change to eth0, eth1 after reboot"
    fi

    # Determine interface names
    local all_interfaces primary_iface
    if [[ "$use_legacy" =~ ^[Yy]$ ]]; then
        local iface_count
        iface_count=$(ls /sys/class/net 2>/dev/null | grep -vE '^(lo|docker|bond|vlan)' | wc -l)
        all_interfaces=$(seq 0 $((iface_count - 1)) | sed 's/^/eth/')
        primary_iface="eth0"
    else
        all_interfaces=$(ls /sys/class/net 2>/dev/null | grep -vE '^(lo|docker|bond|vlan)' | sort || true)
        primary_iface=$(echo "$all_interfaces" | head -1)
    fi

    if [[ -z "$all_interfaces" ]]; then
        log_error "No network interfaces found!"
        return 1
    fi

    # Log configuration
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Network Configuration Details:"
        echo "  All interfaces: $all_interfaces"
        echo "  Primary interface: $primary_iface"
        echo "  Network type: $network_type"
        echo "  Environment: $(is_lxc && echo "LXC" || echo "VM")"
    } >> "${LOGFILE:-/dev/null}"

    if [[ "$network_type" == "static" ]]; then
        {
            echo "  Static IP: $static_ip/$cidr"
            echo "  Gateway: $gateway"
            echo "  DNS: $dns_servers"
        } >> "${LOGFILE:-/dev/null}"

        run_cmd "Configuring static IP" bash -c "
        cat > /etc/network/interfaces <<'INNEREOF'
# Network configuration — Static IP
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback
INNEREOF
cat >> /etc/network/interfaces <<EOF

# Primary interface with static IP
auto $primary_iface
iface $primary_iface inet static
    address $static_ip/$cidr
    gateway $gateway
    dns-nameservers $dns_servers
EOF
for iface in $all_interfaces; do
    if [[ \"\$iface\" != \"\$primary_iface\" ]]; then
        cat >> /etc/network/interfaces <<EOF

# Additional interface
auto \$iface
iface \$iface inet dhcp
EOF
    fi
done
"
    else
        run_cmd "Configuring DHCP" bash -c "
        cat > /etc/network/interfaces <<'INNEREOF'
# Network configuration — DHCP
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback
INNEREOF
for iface in $all_interfaces; do
    cat >> /etc/network/interfaces <<EOF

# Interface \$iface
auto \$iface
iface \$iface inet dhcp
EOF
done
"
    fi

    # Ensure DNS is configured for static
    if [[ "$network_type" == "static" ]]; then
        run_cmd "Configuring DNS resolvers" bash -c "
        if [[ -f /etc/resolv.conf ]]; then
            cp /etc/resolv.conf /etc/resolv.conf.bak.\$(date +%s)
        fi
        cat > /etc/resolv.conf <<EOF
nameserver $gateway
nameserver $(echo $dns_servers | awk '{print $NF}')
EOF
"
    fi

    log_success "Network configuration written"
}

############################################################# TEMPLATE FUNCTIONS
create_admin_user() {
    local ssh_keys=("$@")
    run_cmd "Creating/configuring debian user" bash -c '
    if ! id debian &>/dev/null; then
        useradd -m -s /bin/bash debian
    fi
    '
    run_cmd "Configuring passwordless sudo" bash -c '
    mkdir -p /etc/sudoers.d
    echo "debian ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/debian
    chmod 440 /etc/sudoers.d/debian
    '
    run_cmd "Creating SSH directory" bash -c '
    mkdir -p /home/debian/.ssh
    chmod 700 /home/debian/.ssh
    chown -R debian:debian /home/debian/.ssh
    '
    run_cmd "Adding SSH keys" bash -c "
    touch /home/debian/.ssh/authorized_keys
    for key in \"\${@}\"; do
        echo \"\$key\" >> /home/debian/.ssh/authorized_keys
    done
    chmod 600 /home/debian/.ssh/authorized_keys
    chown debian:debian /home/debian/.ssh/authorized_keys
    " bash "${ssh_keys[@]}"
}

secure_root_account() {
    run_cmd "Locking root account" passwd -l root
}

install_base_packages() {
    local codename="$1"
    run_cmd "Updating package lists" apt-get update

    local base_packages="vim git curl wget gpg jq nfs-common dirmngr net-tools htop sudo logrotate unattended-upgrades tcpdump iproute2"

    if ! is_lxc; then
        base_packages="$base_packages qemu-guest-agent parted"
    fi

    run_cmd "Installing base packages" bash -c "
    DEBIAN_FRONTEND=noninteractive apt-get install -y $base_packages
    "
}

install_java() {
    run_cmd "Installing OpenJDK" bash -c '
    if apt-cache show openjdk-25-jdk &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-25-jdk
    elif apt-cache show openjdk-21-jdk &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-21-jdk
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y default-jdk
    fi
    '
}

upgrade_system() {
    run_cmd "Upgrading system packages" bash -c '
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    '
}

configure_unattended_upgrades() {
    run_cmd "Enabling automatic security updates" bash -c '
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    '
}

configure_shell_aliases() {
    run_cmd "Configuring shell aliases" bash -c "
    if ! grep -q 'alias ll=' /etc/bash.bashrc; then
        cat >> /etc/bash.bashrc <<'EOL'

# Custom aliases
alias ll='ls -alhF --group-directories-first'
EOL
    fi
    "
}

harden_ssh() {
    run_cmd "Hardening SSH configuration" bash -c '
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak."$(date +%s)"
    sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
    sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
    sed -i "s/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/" /etc/ssh/sshd_config
    sed -i "s/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
    sed -i "s/^#\?ClientAliveInterval.*/ClientAliveInterval 300/" /etc/ssh/sshd_config
    sed -i "s/^#\?ClientAliveCountMax.*/ClientAliveCountMax 2/" /etc/ssh/sshd_config
    systemctl restart ssh
    '
}

configure_console_banner() {
    if is_lxc; then
        run_cmd "Configuring login banner" bash -c '
        sed -i "/^IP:/d" /etc/issue 2>/dev/null || true
        echo "IP: \4{eth0}" >> /etc/issue
        '
    else
        run_cmd "Configuring login banner" bash -c '
        sed -i "/^IP:/d" /etc/issue 2>/dev/null || true
        echo "IP: \4{eth0} \4{ens18} \4{enp0s3}" >> /etc/issue
        '
    fi
}

configure_motd() {
    run_cmd "Creating MOTD directory" mkdir -p /etc/update-motd.d
    cat > /etc/update-motd.d/10-system-info <<'EOF'
#!/bin/bash
echo ""
echo "  ═════════════════════════════════════════════"
echo ""
echo "  Hostname:  $(hostname)"
echo "  IP:        $(hostname -I 2>/dev/null | head -1)"
echo "  Uptime:    $(uptime -p 2>/dev/null)"
echo "  Disk /:    $(df -h / | tail -1 | awk '{print $3, "/", $2, "(" $5 ")"}')"
echo "  Memory:    $(free -h | awk '/Mem:/ {print $3, "/", $2}')"
echo ""
echo "  ═════════════════════════════════════════════"
echo ""
EOF
chmod +x /etc/update-motd.d/10-system-info
}

clean_packages() {
    run_cmd "Cleaning package cache" bash -c '
    apt-get clean
    apt-get autoremove -y
    '
}

configure_journal() {
    local journal_size="200M"
    local keep_free="100M"
    if is_lxc; then
        journal_size="100M"
        keep_free="50M"
    fi
    run_cmd "Configuring journal size limit" bash -c "
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/size-limit.conf <<EOF
[Journal]
SystemMaxUse=$journal_size
SystemKeepFree=$keep_free
MaxFileSec=1month
EOF
"
}

clear_machine_id() {
    run_cmd "Clearing machine-id for clone uniqueness" bash -c '
    truncate -s 0 /etc/machine-id
    rm -f /var/lib/dbus/machine-id
    ln -sf /etc/machine-id /var/lib/dbus/machine-id
    '
}

clear_history() {
    run_cmd "Clearing shell history" bash -c '
    for user in root debian; do
        user_home=$(eval echo ~"$user" 2>/dev/null)
        if [[ -f "$user_home/.bash_history" ]]; then
            truncate -s 0 "$user_home/.bash_history"
        fi
    done
    history -c || true
    unset HISTFILE || true
    '
}

clear_temp_files() {
    run_cmd "Clearing temporary files" bash -c '
    find /tmp -mindepth 1 -delete 2>/dev/null || true
    find /var/tmp -mindepth 1 -delete 2>/dev/null || true
    '
}

remove_dhcp_leases() {
    run_cmd "Removing DHCP leases" bash -c '
    rm -f /var/lib/dhcp/* 2>/dev/null || true
    rm -f /var/lib/NetworkManager/*.lease 2>/dev/null || true
    '
}

clear_cloud_init() {
    run_cmd "Clearing cloud-init data" bash -c '
    rm -rf /var/lib/cloud/* 2>/dev/null || true
    rm -f /etc/machine-info 2>/dev/null || true
    '
}

############################################################# INIT FUNCTIONS
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
    DEBIAN_FRONTEND=noninteractive apt-get install -y zabbix-agent2
    '

    run_cmd "Configuring Zabbix Agent" bash -c "
    mkdir -p /var/lib/zabbix
    touch /var/lib/zabbix/zabbix_agent2.db
    chown -R zabbix:zabbix /var/lib/zabbix
    if [[ -f /etc/zabbix/zabbix_agent2.conf ]]; then
        cp /etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agent2.conf.bak
    fi
    cat > /etc/zabbix/zabbix_agent2.conf <<EOF
PidFile=/run/zabbix/zabbix_agent2.pid
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=10
Server=$zabbix_address
ServerActive=$zabbix_address:$zabbix_port
Hostname=$hostname
Include=/etc/zabbix/zabbix_agent2.d/*.conf
ControlSocket=/run/zabbix/agent.sock
EOF
    "
}

install_graylog() {
    local graylog_address="$1"
    local graylog_api_token="$2"
    local tags="$3"

    run_cmd "Installing Graylog repository" bash -c "
    wget -qO /tmp/graylog-key.asc https://packages.graylog2.org/repo/graylog-keyring.gpg
    gpg --dearmor < /tmp/graylog-key.asc > /usr/share/keyrings/graylog-archive-keyring.gpg
    echo \"deb [signed-by=/usr/share/keyrings/graylog-archive-keyring.gpg] https://packages.graylog2.org/repo/debian stable 7.0\" > /etc/apt/sources.list.d/graylog.list
    rm -f /tmp/graylog-key.asc
    "

    run_cmd "Updating package lists" apt-get update
    run_cmd "Installing Graylog Sidecar" bash -c '
    DEBIAN_FRONTEND=noninteractive apt-get install -y graylog-sidecar
    '

    run_cmd "Configuring Graylog Sidecar" bash -c "
    mkdir -p /etc/graylog/sidecar
    if [[ -f /etc/graylog/sidecar/sidecar.yml ]]; then
        cp /etc/graylog/sidecar/sidecar.yml /etc/graylog/sidecar/sidecar.yml.bak
    fi
    cat > /etc/graylog/sidecar/sidecar.yml <<EOF
server_url: \"$graylog_address\"
server_api_token: \"$graylog_api_token\"
node_id: \"file:/etc/graylog/sidecar/node-id\"
node_name: \"\$(hostname)\"
update_interval: 10
tls_skip_verify: true
send_status: true
tags: $tags
log_path: \"/var/log/graylog-sidecar\"
EOF
    "

    run_cmd "Installing Graylog Sidecar service" bash -c '
    graylog-sidecar -service install
    '
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
    if ! is_lxc && systemctl list-unit-files | grep -q qemu-guest-agent; then
        run_cmd "Starting QEMU Guest Agent" systemctl start qemu-guest-agent || true
    fi
}

############################################################# VERIFICATION & SUMMARY
verify_installation() {
    log_section "Verification"
    local -a failures=()

    if [[ -n "${new_hostname:-}" ]]; then
        if [[ "$(hostname)" == "$new_hostname" ]]; then
            log_success "Hostname: OK ($(hostname))"
        else
            log_error "Hostname: MISMATCH (expected $new_hostname, got $(hostname))"
            failures+=("hostname")
        fi
    fi

    if systemctl is-active --quiet ssh; then
        log_success "SSH: Running"
    else
        log_error "SSH: Not running"
        failures+=("ssh")
    fi

    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
        log_success "Time sync: Active"
    else
        log_warning "Time sync: Not active"
        if ! is_lxc; then
            failures+=("time_sync")
        fi
    fi

    if ip -4 addr show | grep -q "inet.*global" 2>/dev/null; then
        log_success "Network: IP assigned"
    else
        log_warning "Network: No IP detected (may be pending restart)"
    fi

    if [[ "${install_zabbix:-n}" =~ ^[Yy]$ ]]; then
        if systemctl is-active --quiet zabbix-agent2; then
            log_success "Zabbix Agent: Running"
        else
            log_error "Zabbix Agent: Not running"
            failures+=("zabbix")
        fi
    fi

    if [[ "${install_graylog:-n}" =~ ^[Yy]$ ]]; then
        if systemctl is-active --quiet graylog-sidecar; then
            log_success "Graylog Sidecar: Running"
        else
            log_error "Graylog Sidecar: Not running"
            failures+=("graylog")
        fi
    fi

    if (( ${#failures[@]} > 0 )); then
        log_warning "Verification completed with ${#failures[@]} failure(s)"
        return 1
    fi
    log_success "All verifications passed"
    return 0
}

show_final_summary() {
    log_section "Installation Summary"
    echo "  Setting                    Value"
    echo "  ─────────────────────────  ────────────────────────────────"

    printf "  %-26s %s\n" "Environment:" "$(is_lxc && echo "LXC Container" || echo "Virtual Machine")"
    printf "  %-26s %s\n" "Hostname:" "$(hostname)"
    printf "  %-26s %s\n" "FQDN:" "$(hostname -f 2>/dev/null || echo 'N/A')"
    printf "  %-26s %s\n" "Timezone:" "$(timedatectl show -p Timezone --value 2>/dev/null || echo 'N/A')"
    printf "  %-26s %s\n" "NTP Sync:" "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo 'N/A')"

    local primary_ip
    primary_ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -1)
    printf "  %-26s %s\n" "Primary IP:" "${primary_ip:-Not assigned yet}"

    printf "  %-26s %s\n" "SSH:" "Port 22, key-only"

    if [[ "${install_zabbix:-n}" =~ ^[Yy]$ ]]; then
        printf "  %-26s %s\n" "Zabbix:" "${zabbix_address:-not configured}:${zabbix_port:-10051}"
    fi
    if [[ "${install_graylog:-n}" =~ ^[Yy]$ ]]; then
        printf "  %-26s %s\n" "Graylog:" "${graylog_address:-not configured}"
    fi

    echo ""
    echo "  Log file: ${LOGFILE:-N/A}"
    echo "  Config:   ${CONFIG_FILE:-N/A}"
}