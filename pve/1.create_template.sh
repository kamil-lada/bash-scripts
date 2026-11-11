#!/bin/bash
# Template Preparation Script (Phase 1) — handles both VM and LXC
# Usage: sudo bash 1.create_template.sh [config_file]   (default: pve/config)
set -euo pipefail

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Set log file
LOGFILE="/var/log/create_template.log"
CONFIG_FILE="${1:-$SCRIPT_DIR/config}"
: > "$LOGFILE"

trap 'echo -e "${RED}Script failed. Check $LOGFILE for details${NC}" >&2' ERR

# Load config if exists (read-only)
load_config "$CONFIG_FILE"

############################################################# VM-SPECIFIC FUNCTIONS
# Whole disks with nothing mounted on them or their partitions/LVs (and no active swap)
get_unmounted_disks() {
    local disk
    while read -r disk; do
        if [[ -z "$(lsblk -nro MOUNTPOINT "/dev/$disk" 2>/dev/null | tr -d '[:space:]')" ]]; then
            echo "$disk"
        fi
    done < <(lsblk -ndo NAME,TYPE 2>/dev/null | awk '$2=="disk" {print $1}')
}

enable_qemu_agent() {
    run_cmd "Enabling QEMU guest agent" systemctl enable --now qemu-guest-agent
}

configure_optional_disk() {
    local data_disk="$1"
    local mount_point="$2"
    local dev="/dev/$data_disk"

    # Any partition table, filesystem, LVM or RAID signature (read from disk, not udev cache)
    if [[ -n "$(wipefs --noheadings "$dev" 2>/dev/null)" ]]; then
        log_warning "Disk $dev contains data:"
        wipefs "$dev" | sed 's/^/    /'
        if ! confirm_typed "ALL data on $dev will be DESTROYED." "$data_disk"; then
            log_info "Disk configuration cancelled"
            return 0
        fi
    fi

    run_cmd "Wiping signatures on $dev" wipefs -a "$dev"
    run_cmd "Creating partition table on $dev" bash -c "
    set -e
    parted -s '$dev' mklabel gpt
    parted -s '$dev' mkpart primary ext4 0% 100%
    partprobe '$dev'
    udevadm settle
    "
    local partition
    partition=$(lsblk -lnpo NAME,TYPE "$dev" | awk '$2=="part" {print $1; exit}')
    if [[ -z "$partition" ]]; then
        log_error "Partition on $dev not found after partitioning"
        return 1
    fi

    run_cmd "Creating ext4 filesystem on $partition" mkfs.ext4 -F "$partition"
    run_cmd "Creating mount point $mount_point" mkdir -p "$mount_point"
    run_cmd "Adding to fstab" bash -c "
    set -e
    uuid=\$(blkid -s UUID -o value '$partition')
    echo \"UUID=\$uuid $mount_point ext4 defaults,noatime,nofail 0 2\" >> /etc/fstab
    "
    run_cmd "Reloading systemd (fstab)" systemctl daemon-reload
    run_cmd "Mounting $mount_point" mount "$mount_point"
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
        echo "  • Network (DHCP or static IP), optional interface name pinning"
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
    local ssh_key
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

    get_opt INSTANCE_TIMEZONE "Timezone for template" "Europe/Warsaw" validate_timezone
    echo ""

    # VM-only: optional disk
    local mount_disk="n" data_disk="" mount_point="/data"
    if ! is_lxc; then
        local -a unmounted_disks
        mapfile -t unmounted_disks < <(get_unmounted_disks)

        if [[ ${#unmounted_disks[@]} -gt 0 ]]; then
            log_info "Available unmounted disks:"
            local disk idx=1
            for disk in "${unmounted_disks[@]}"; do
                printf "  %d. %-10s %-8s %s\n" "$idx" "$disk" \
                    "$(lsblk -ndo SIZE "/dev/$disk")" "$(lsblk -ndo MODEL "/dev/$disk" | xargs)"
                idx=$((idx + 1))
            done
            echo ""
            if confirm "Configure additional disk in template?" n; then
                mount_disk="y"
                while true; do
                    data_disk=$(ask "Disk name" "${unmounted_disks[0]}")
                    [[ " ${unmounted_disks[*]} " == *" $data_disk "* ]] && break
                    log_error "'$data_disk' is not in the list above"
                done
                while true; do
                    mount_point=$(ask "Mount point" "/data")
                    if [[ "$mount_point" != /* || "$mount_point" == "/" ]]; then
                        log_error "Use an absolute path (not /)"
                    elif mountpoint -q "$mount_point" 2>/dev/null; then
                        log_error "$mount_point is already a mount point"
                    elif findmnt --fstab -n "$mount_point" &>/dev/null; then
                        log_error "$mount_point already has an /etc/fstab entry"
                    else
                        break
                    fi
                done
            fi
        fi
        echo ""
    fi

    # Summary
    log_info "Configuration Summary:"
    echo "  Environment: $(is_lxc && echo "LXC" || echo "VM")"
    echo "  Debian version: $codename"
    echo "  SSH keys: ${#ssh_keys[@]}"
    echo "  Timezone: $INSTANCE_TIMEZONE"
    if ! is_lxc; then
        if [[ "$mount_disk" == "y" ]]; then
            echo "  Additional disk: /dev/$data_disk → $mount_point"
        fi
    else
        echo "  Network: Managed by Proxmox"
    fi
    echo ""

    if ! confirm "Proceed with template creation?" n; then
        log_info "Aborted by user"
        exit 0
    fi

    # Execute
    log_section "Creating Template"

    create_admin_user "${ssh_keys[@]}"
    install_base_packages
    configure_admin_sudo
    install_java
    upgrade_system
    configure_unattended_upgrades
    configure_shell_aliases
    configure_time_sync "$INSTANCE_TIMEZONE"

    # Network (VM only — LXC handled by Proxmox). Interface names are NOT pinned here:
    # clones get new MAC addresses, pinning happens in phase 2.
    if ! is_lxc; then
        if [[ "$(check_network_manager)" == "ifupdown" ]]; then
            configure_network "dhcp"
        else
            log_warning "Non-ifupdown network manager active — network config left as is"
        fi
        enable_qemu_agent
        if [[ "$mount_disk" == "y" ]]; then
            configure_optional_disk "$data_disk" "$mount_point"
        fi
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
    log_info "Next steps:"
    if is_lxc; then
        echo "  1. Log out without saving history: unset HISTFILE; exit"
        echo "  2. Stop container: pct stop <vmid>"
        echo "  3. Convert to template: pct template <vmid>"
        echo "  4. Clone for new instances: pct clone <vmid> <newvmid>"
        echo "  5. Start new instance: pct start <newvmid>"
        echo "  6. Run init script: sudo bash 2.initialize_for_usecase.sh"
    else
        echo "  1. Shutdown without saving history: unset HISTFILE; sudo poweroff"
        echo "  2. Convert to template in Proxmox"
        echo "  3. Clone for new instances"
        echo "  4. Run init script: sudo bash 2.initialize_for_usecase.sh"
    fi
}

main "$@"
