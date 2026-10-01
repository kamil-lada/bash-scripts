#!/bin/bash
# Template Preparation Script (Phase 1) — handles both VM and LXC
set -euo pipefail

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

# Set log file
LOGFILE="/var/log/create_template.log"
CONFIG_FILE="/var/log/template_config.txt"
: > "$LOGFILE"

trap 'echo -e "${RED}Script failed. Check $LOGFILE for details${NC}" >&2' ERR

# Load config if exists (read-only)
load_config "$CONFIG_FILE"

############################################################# VM-SPECIFIC FUNCTIONS
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
    printf '%s\n' "${unmounted[@]}"
}

enable_qemu_agent() {
    run_cmd "Enabling QEMU guest agent" bash -c '
    systemctl enable qemu-guest-agent
    systemctl start qemu-guest-agent
    '
}

update_grub() {
    run_cmd "Updating GRUB configuration" update-grub
    local boot_disk
    boot_disk=$(get_boot_disk)
    run_cmd "Installing GRUB on $boot_disk" grub-install "$boot_disk"
}

configure_optional_disk() {
    local data_disk="$1"
    local mount_point="$2"
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
    if ! grep -q \"UUID=\$uuid\" /etc/fstab 2>/dev/null; then
        echo \"UUID=\$uuid $mount_point ext4 defaults,noatime,nofail 0 2\" >> /etc/fstab
    fi
    "
    run_cmd "Mounting filesystem" mount -a
}

open_ssh_for_template() {
    run_cmd "Ensuring SSH allows password login (template mode)" bash -c '
    sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
    sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
    systemctl restart ssh
    '
}

############################################################# MAIN
show_intro() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                                                                ║${NC}"
    echo -e "${BLUE}║       Template Preparation Script (Phase 1)                    ║${NC}"
    echo -e "${BLUE}║                                                                ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Environment: $(is_lxc && echo "LXC Container" || echo "Virtual Machine")${NC}"
    echo ""
    echo -e "${YELLOW}This script uses a 2-phase approach:${NC}"
    echo ""
    echo -e "${GREEN}PHASE 1 — Template Preparation (this script):${NC}"
    echo "  • Creates generic, reusable template"
    echo "  • Installs base packages"
    echo "  • Sets up time sync and automatic updates"
    if ! is_lxc; then
        echo "  • Configures DHCP for network visibility"
        echo "  • Optional: Configure additional disk"
    else
        echo "  • Network managed by Proxmox (no internal config)"
    fi
    echo ""
    echo -e "${GREEN}PHASE 2 — Instance Initialization (after cloning):${NC}"
    echo "  • Configures instance-specific settings"
    echo "  • Sets hostname, domain"
    if ! is_lxc; then
        echo "  • Network (DHCP or static IP)"
    fi
    echo "  • Optionally installs: Zabbix, Graylog Sidecar"
    echo "  • Hardens SSH (locks down access)"
    echo ""
}

main() {
    check_root
    show_intro

    # Pre-flight checks
    check_network_connectivity
    check_disk_space 1000

    local codename
    codename=$(detect_debian_version)

    log_section "Configuration Input"

    # SSH keys (always interactive — multi-line input)
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

    # Timezone (from config or interactive)
    local timezone
    if [[ -n "${INSTANCE_TIMEZONE:-}" ]]; then
        timezone="$INSTANCE_TIMEZONE"
        log_info "Using timezone from config: $timezone"
    else
        read -rp "Timezone for template [Europe/Warsaw]: " timezone
        timezone="${timezone:-Europe/Warsaw}"
    fi
    echo ""

    # VM-only: legacy naming
    local legacy_naming="n"
    if ! is_lxc; then
        if [[ -n "${LEGACY_NAMING:-}" ]]; then
            legacy_naming="$LEGACY_NAMING"
            log_info "Using legacy naming from config: $legacy_naming"
        else
            read -rp "Use legacy network names (eth0, eth1)? (y/N): " legacy_naming
            legacy_naming="${legacy_naming:-n}"
        fi
        echo ""

        # VM-only: optional disk
        local mount_disk="n" data_disk="" mount_point="/data"
        local -a unmounted_disks
        mapfile -t unmounted_disks < <(get_unmounted_disks)

        if [[ ${#unmounted_disks[@]} -gt 0 ]]; then
            log_info "Available unmounted disks:"
            local idx=1
            local -a valid_disk_info=()
            for disk in "${unmounted_disks[@]}"; do
                local size model
                size=$(lsblk -ndo SIZE "/dev/$disk" 2>/dev/null | head -1 || echo "")
                model=$(lsblk -ndo MODEL "/dev/$disk" 2>/dev/null | head -1 || echo "")
                if [[ -n "$size" && "$size" != "unknown" ]]; then
                    valid_disk_info+=(" $idx. $disk   $size   ${model:-unknown}")
                    ((idx++))
                fi
            done

            if [[ ${#valid_disk_info[@]} -gt 0 ]]; then
                printf '%s\n' "${valid_disk_info[@]}"
                echo ""
                read -rp "Configure additional disk in template? (y/N): " mount_disk
                mount_disk="${mount_disk:-n}"
                if [[ "$mount_disk" =~ ^[Yy]$ ]]; then
                    read -rp "Enter disk name (e.g., ${unmounted_disks[0]}): " data_disk
                    read -rp "Mount point [/data]: " mount_point
                    mount_point="${mount_point:-/data}"
                fi
            fi
        fi
        echo ""
    fi

    # Summary
    log_info "Configuration Summary:"
    echo "  Environment: $(is_lxc && echo "LXC" || echo "VM")"
    echo "  Debian version: $codename"
    echo "  SSH keys: ${#ssh_keys[@]}"
    echo "  Timezone: $timezone"
    if ! is_lxc; then
        echo "  Legacy network names: $legacy_naming"
        if [[ "$mount_disk" =~ ^[Yy]$ ]]; then
            echo "  Additional disk: /dev/$data_disk → $mount_point"
        fi
    else
        echo "  Network: Managed by Proxmox"
    fi
    echo ""

    read -rp "Proceed with template creation? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Aborted by user"
        exit 0
    fi

    # Execute
    log_section "Creating Template"

    create_admin_user "${ssh_keys[@]}"
    open_ssh_for_template
    install_base_packages "$codename"
    install_java
    upgrade_system
    configure_unattended_upgrades
    configure_shell_aliases
    configure_time_sync "$timezone"

    # Network (VM only — LXC handled by Proxmox)
    if ! is_lxc; then
        configure_network "dhcp" "" "" "" "" "$legacy_naming"
    else
        log_info "LXC — Proxmox manages network, skipping internal configuration"
    fi

    # VM-only: QEMU agent, optional disk, GRUB
    if ! is_lxc; then
        enable_qemu_agent
        if [[ "$mount_disk" =~ ^[Yy]$ ]]; then
            configure_optional_disk "$data_disk" "$mount_point"
        fi
        update_grub
    fi

    configure_console_banner
    configure_motd
    clean_packages
    configure_journal
    clear_machine_id
    clear_history
    clear_temp_files
    remove_dhcp_leases
    clear_cloud_init

    log_section "Template Preparation Complete"
    log_success "Template is ready for use"
    echo ""
    if is_lxc; then
        log_info "Next steps:"
        echo "  1. Stop container: pct stop <vmid>"
        echo "  2. Convert to template: pct template <vmid>"
        echo "  3. Clone for new instances: pct clone <vmid> <newvmid>"
        echo "  4. Start new instance: pct start <newvmid>"
        echo "  5. Run init script: sudo bash 2.initialize_for_usecase.sh"
    else
        log_info "Next steps:"
        echo "  1. Shutdown VM: sudo poweroff"
        echo "  2. Convert to template in Proxmox"
        echo "  3. Clone for new instances"
        echo "  4. Run init script: sudo bash 2.initialize_for_usecase.sh"
    fi
}

main "$@"