#!/bin/bash

# Strict error handling
set -euo pipefail

# Logging configuration
readonly LOGFILE="/var/log/create_template.log"
readonly CONFIG_FILE="/var/log/template_config.txt"
: > "$LOGFILE"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

trap 'echo -e "${RED}Script failed. Check $LOGFILE for details${NC}" >&2' ERR

############################################################# HELPER FUNCTIONS

log_info() {
    echo -e "${YELLOW}[→]${NC} $1"
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
    if "$@" >>"$LOGFILE" 2>&1; then
        echo -e "${GREEN}OK${NC}"
        return 0
    else
        echo -e "${RED}ERROR${NC}"
        log_error "Failed: $desc"
        tail -n 50 "$LOGFILE" | sed 's/^/  /' >&2
        exit 1
    fi
}

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

get_boot_disk() {
    local boot_dev
    boot_dev=$(findmnt -n -o SOURCE /boot 2>/dev/null || findmnt -n -o SOURCE /)
    boot_dev=$(echo "$boot_dev" | sed 's/[0-9]*$//')
    echo "$boot_dev"
}

get_system_disk() {
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//')
    basename "$root_dev"
}

get_unmounted_disks() {
    local system_disk
    system_disk=$(get_system_disk)

    local -a unmounted=()

    while IFS= read -r disk; do
        [[ -z "$disk" ]] && continue

        [[ "$disk" == "$system_disk" ]] && continue

        [[ ! -b "/dev/$disk" ]] && continue

        local has_mountpoint=false
        while IFS= read -r mountpoint; do
            if [[ -n "$mountpoint" ]]; then
                has_mountpoint=true
                break
            fi
        done < <(lsblk -no MOUNTPOINT "/dev/$disk" 2>/dev/null || true)

        if [[ "$has_mountpoint" == false ]]; then
            unmounted+=("$disk")
        fi
    done < <(lsblk -ndo NAME,TYPE 2>/dev/null | awk '$2=="disk" {print $1}')

    # Return array
    printf '%s\n' "${unmounted[@]}"
}

############################################################# FEATURE FUNCTIONS

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

    # Base packages
    local base_packages="vim git curl wget gpg jq nfs-common dirmngr net-tools htop sudo parted tcpdump qemu-guest-agent iproute2"

    if [[ "$codename" == "bookworm" ]]; then
        if apt-cache show software-properties-common >/dev/null 2>&1; then
            base_packages="$base_packages software-properties-common"
        fi
    fi

    run_cmd "Installing base packages" bash -c "
        DEBIAN_FRONTEND=noninteractive apt-get install -y $base_packages
    "
}

install_java() {
    run_cmd "Installing OpenJDK" bash -c '
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-17-jdk 2>/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y default-jdk
        fi
    '
}

upgrade_system() {
    run_cmd "Upgrading system packages" bash -c '
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    '
}

configure_timezone() {
    local timezone="$1"
    run_cmd "Setting timezone to $timezone" timedatectl set-timezone "$timezone"
}

configure_swappiness() {
    run_cmd "Configuring kernel swappiness to 2" bash -c '
        echo "vm.swappiness = 2" > /etc/sysctl.d/99-swappiness.conf
        sysctl -p /etc/sysctl.d/99-swappiness.conf
    '
}

configure_shell_aliases() {
    run_cmd "Configuring shell aliases" bash -c "
        cat >> /etc/bash.bashrc <<'EOL'

# Custom aliases
alias ll='ls -alhF --group-directories-first'
alias nanosh='_nanosh() { touch \"\$1\" && chmod +x \"\$1\" && nano \"\$1\"; }; _nanosh'
EOL
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

enable_qemu_agent() {
    run_cmd "Enabling QEMU guest agent" bash -c '
        systemctl enable qemu-guest-agent
        systemctl start qemu-guest-agent
    '
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

# Shared function to generate interfaces file with DHCP
# Parameters: $1=use_legacy (y/n), $2=description
generate_interfaces_dhcp() {
    local use_legacy="$1"
    local description="$2"
    local current_date
    current_date=$(date)

    run_cmd "Backing up network config" bash -c '
        if [[ -f /etc/network/interfaces ]]; then
            cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%s)
        fi
    '

    if [[ "$use_legacy" =~ ^[Yy]$ ]]; then
        # Count interfaces to know how many eth0, eth1, etc to configure
        run_cmd "$description (legacy names)" bash -c "
            IFACE_COUNT=\$(ls /sys/class/net 2>/dev/null | grep -vE '^(lo|docker)' | wc -l)

            cat > /etc/network/interfaces <<EOF
# Network configuration - DHCP
# Generated by prep.sh on $current_date
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

EOF

            for i in \$(seq 0 \$((IFACE_COUNT - 1))); do
                cat >> /etc/network/interfaces <<EOF

auto eth\$i
iface eth\$i inet dhcp

EOF
            done
        "
    else
        # Enumerate actual interface names
        run_cmd "$description (current names)" bash -c "
            cat > /etc/network/interfaces <<EOF
# Network configuration - DHCP
# Generated by prep.sh on $current_date
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

EOF

            for iface in \$(ls /sys/class/net 2>/dev/null | grep -vE '^(lo|docker)' | sort); do
                [[ -z \"\$iface\" ]] && continue
                cat >> /etc/network/interfaces <<EOF

auto \$iface
iface \$iface inet dhcp

EOF
            done
        "
    fi

    # Log the generated config
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Generated /etc/network/interfaces:" >> "$LOGFILE"
    cat /etc/network/interfaces >> "$LOGFILE"
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
    fi
}

configure_dhcp_network() {
    local legacy_naming="$1"
    generate_interfaces_dhcp "$legacy_naming" "Configuring DHCP"
}

configure_optional_disk() {
    local data_disk="$1"
    local mount_point="$2"

    # Check if disk has partitions
    local has_partitions=false
    if lsblk -n "/dev/$data_disk" 2>/dev/null | grep -q part; then
        has_partitions=true
        log_warning "Disk /dev/$data_disk has existing partition(s)"
        log_warning "All partitions and data will be DESTROYED"
        echo ""
        read -rp "Continue with wiping disk? (y/N): " wipe_confirm
        if [[ ! "$wipe_confirm" =~ ^[Yy]$ ]]; then
            log_info "Disk configuration cancelled"
            return 0
        fi
    fi

    run_cmd "Creating partition table on $data_disk" bash -c "
        parted -s /dev/$data_disk mklabel gpt
        parted -s /dev/$data_disk mkpart primary ext4 0% 100%
    "

    sleep 2

    local partition="/dev/${data_disk}1"
    if [[ "$data_disk" =~ nvme ]]; then
        partition="/dev/${data_disk}p1"
    fi

    run_cmd "Creating ext4 filesystem on $partition" mkfs.ext4 -F "$partition"

    run_cmd "Creating mount point $mount_point" mkdir -p "$mount_point"

    run_cmd "Adding to fstab" bash -c "
        uuid=\$(blkid -s UUID -o value $partition)
        echo \"UUID=\$uuid $mount_point ext4 defaults,noatime,nofail 0 2\" >> /etc/fstab
    "

    run_cmd "Mounting filesystem" mount -a

    log_success "Disk configured and mounted at $mount_point"
}

update_grub() {
    run_cmd "Updating GRUB configuration" update-grub

    local boot_disk
    boot_disk=$(get_boot_disk)
    run_cmd "Installing GRUB on $boot_disk" grub-install "$boot_disk"
}

configure_console_banner() {
    run_cmd "Configuring login banner" bash -c '
        sed -i "/^IP:/d" /etc/issue 2>/dev/null || true
        echo "IP: \4{eth0} \4{ens18} \4{enp0s3}" >> /etc/issue
    '
}

clean_packages() {
    run_cmd "Cleaning package cache" bash -c '
        apt-get clean
        apt-get autoremove -y
    '
}

clear_machine_id() {
    run_cmd "Clearing machine-id" bash -c '
        truncate -s 0 /etc/machine-id
        rm -f /var/lib/dbus/machine-id
        ln -sf /etc/machine-id /var/lib/dbus/machine-id
    '
}

configure_journal() {
    run_cmd "Configuring journal size limit" bash -c '
        mkdir -p /etc/systemd/journald.conf.d
        cat > /etc/systemd/journald.conf.d/size-limit.conf <<EOL
[Journal]
SystemMaxUse=5G
EOL
        systemctl restart systemd-journald
    '
}

clear_logs() {
    run_cmd "Clearing system logs" bash -c '
        journalctl --rotate || true
        journalctl --vacuum-time=1s || true
        find /var/log -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null || true
        find /var/log -type f -name "*.old" -delete 2>/dev/null || true
        find /var/log -type f -name "*.gz" -delete 2>/dev/null || true
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
        rm -f /var/lib/systemd/random-seed 2>/dev/null || true
    '
}

############################################################# MAIN

show_intro() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                                                                ║${NC}"
    echo -e "${BLUE}║          Debian VM Template Preparation Script                ║${NC}"
    echo -e "${BLUE}║                                                                ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}This script uses a 2-phase approach:${NC}"
    echo ""
    echo -e "${GREEN}PHASE 1 - Template Preparation (this script):${NC}"
    echo "  • Creates generic, reusable VM template"
    echo "  • Installs base packages and security hardening"
    echo "  • Configures DHCP for network visibility"
    echo "  • Optional: Configure additional disk"
    echo "  • Asks minimal questions (SSH keys, timezone)"
    echo ""
    echo -e "${GREEN}PHASE 2 - Instance Initialization (after cloning):${NC}"
    echo "  • Configures instance-specific settings"
    echo "  • Sets hostname, domain, network (DHCP/static)"
    echo "  • Optionally installs: Zabbix, Graylog Sidecar"
    echo "  • Mounts additional disks if not already mounted"
    echo "  • Regenerates machine-id and SSH keys"
    echo ""
    echo -e "${YELLOW}How to answer prompts:${NC}"
    echo "  • Default values shown in square brackets: [like this]"
    echo "  • Just press Enter to accept default"
    echo "  • Capital letter shows default: (Y/n)=Yes, (y/N)=No"
    echo ""
    read -rp "Press Enter to continue..."
    echo ""
}

main() {
    check_root
    show_intro

    local codename
    codename=$(detect_debian_version)

    log_section "Configuration Input"

    # SSH keys
    log_info "Enter SSH public keys for admin access (one per line, empty line to finish):"
    local -a ssh_keys=()
    while true; do
        read -r ssh_key
        if [[ -z "$ssh_key" ]]; then
            break
        fi
        ssh_keys+=("$ssh_key")
        echo "  Key $(( ${#ssh_keys[@]} )) added"
    done

    if [[ ${#ssh_keys[@]} -eq 0 ]]; then
        log_error "At least one SSH key is required for admin access"
        exit 1
    fi
    echo ""

    # Timezone
    local timezone
    read -rp "Timezone for template [Europe/Warsaw]: " timezone
    timezone="${timezone:-Europe/Warsaw}"
    echo ""

    # Network interface naming
    local legacy_naming="n"
    echo ""
    log_info "Script supports only native server network manager - ifupdown"

    # Check for other network managers
    local other_manager
    other_manager=$(check_network_manager)
    if [[ "$other_manager" != "ifupdown" ]]; then
        log_warning "═══════════════════════════════════════════════════════"
        log_warning "  $other_manager is active on this system"
        log_warning "  This script only configures ifupdown (native)"
        log_warning "  Network configuration will be skipped"
        log_warning "  Please configure network manually or disable $other_manager"
        log_warning "═══════════════════════════════════════════════════════"
        echo ""
        read -rp "Press Enter to continue without network configuration..."
        legacy_naming="n"
    else
        log_info "Template will use DHCP (static IP available in init phase)"
        echo ""
        read -rp "Use legacy network names (eth0, eth1)? (y/N): " legacy_naming
        legacy_naming="${legacy_naming:-n}"
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
            read -rp "Configure additional disk in template? (y/N): " mount_disk
            mount_disk="${mount_disk:-n}"

            if [[ "$mount_disk" =~ ^[Yy]$ ]]; then
                while true; do
                    read -rp "Enter disk name (e.g., ${unmounted_disks[0]}): " data_disk
                    if [[ -z "$data_disk" ]]; then
                        log_error "Disk name cannot be empty"
                        continue
                    fi

                    # Check if disk is in unmounted list
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

                    if lsblk -n "/dev/$data_disk" 2>/dev/null | grep -q part; then
                        log_warning "Disk has existing partitions - will be wiped!"
                        read -rp "Continue? (y/N): " wipe_confirm
                        if [[ ! "$wipe_confirm" =~ ^[Yy]$ ]]; then
                            continue
                        fi
                    fi

                    break
                done

                read -rp "Mount point [/data]: " mount_point
                mount_point="${mount_point:-/data}"
            fi
        fi
    fi
    echo ""

    # Summary
    log_info "Configuration Summary:"
    echo "  Debian version: $codename"
    echo "  SSH keys: ${#ssh_keys[@]}"
    echo "  Timezone: $timezone"
    echo "  Legacy network names: $legacy_naming"
    if [[ "$mount_disk" =~ ^[Yy]$ ]]; then
        echo "  Additional disk: /dev/$data_disk → $mount_point"
    fi
    echo ""
    log_info "Phase 2 (init) will ask for: hostname, domain, network, optional monitoring"
    echo ""

    read -rp "Proceed with template creation? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Aborted by user"
        exit 0
    fi

    # Save configuration
    cat > "$CONFIG_FILE" <<EOF
# Template Configuration
# Generated: $(date -Iseconds)
CODENAME=$codename
SSH_KEYS_COUNT=${#ssh_keys[@]}
TIMEZONE=$timezone
LEGACY_NAMING=$legacy_naming
DISK_CONFIGURED=$mount_disk
EOF

    if [[ "$mount_disk" =~ ^[Yy]$ ]]; then
        cat >> "$CONFIG_FILE" <<EOF
DATA_DISK=$data_disk
MOUNT_POINT=$mount_point
EOF
    fi

    echo ""
    log_section "System Configuration"

    create_admin_user "${ssh_keys[@]}"
    secure_root_account
    install_base_packages "$codename"
    install_java
    upgrade_system
    configure_timezone "$timezone"
    configure_swappiness
    configure_shell_aliases
    harden_ssh
    enable_qemu_agent
    configure_network_naming "$legacy_naming"
    configure_dhcp_network "$legacy_naming"

    if [[ "$mount_disk" =~ ^[Yy]$ ]]; then
        configure_optional_disk "$data_disk" "$mount_point"
    fi

    update_grub
    configure_console_banner

    #log_section "Template Cleanup"

    clean_packages
    clear_machine_id
    configure_journal
    clear_logs
    clear_history
    clear_temp_files
    remove_dhcp_leases
    clear_cloud_init

    echo ""
    log_section "Completion"

    log_success "Template preparation completed successfully!"
    echo ""
    log_info "Configuration saved to: $CONFIG_FILE"
    log_info "Detailed log: $LOGFILE"
    echo ""

    if [[ "$legacy_naming" =~ ^[Yy]$ ]]; then
        log_info "  IMPORTANT: Legacy network naming is configured"
        log_info "   After shutdown and clone boot:"
        log_info "   - Interface names: ens18/enp0s3 → eth0, eth1"
        log_info "   - Network file already configured for eth0, eth1"
        log_info "   - DHCP will work immediately after first boot"
        log_info "   - Run init.sh to configure hostname/static IP"
        echo ""
    fi

    log_info "Next steps:"
    echo "  1. Shut down this VM: shutdown -h now"
    echo "  2. Convert to template in Proxmox"
    echo "  3. Clone from template"
    echo "  4. VM will boot with DHCP - check IP in Proxmox console"
    echo "  5. SSH as debian user: ssh debian@<ip-from-console>"
    echo "  6. Run init script: sudo bash init.sh"
    echo ""
    log_info "Init script (Phase 2) will configure:"
    echo "  • Hostname and domain"
    echo "  • Network (keep DHCP or configure static IP)"
    echo "  • Optional: Zabbix Agent (with server address/port)"
    echo "  • Optional: Graylog Sidecar (with server/API key)"
    echo "  • Optional: Additional disk (if not configured in template)"
    echo ""
}

main "$@"