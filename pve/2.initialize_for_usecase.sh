#!/bin/bash
# Instance Initialization Script (Phase 2) — handles both VM and LXC
# Usage: sudo bash 2.initialize_for_usecase.sh [config_file]
#        default config: /etc/instance_config if present, else pve/config
set -euo pipefail

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Set log file
LOGFILE="/var/log/initialize_for_usecase.log"
if [[ -n "${1:-}" ]]; then
    CONFIG_FILE="$1"
elif [[ -f /etc/instance_config ]]; then
    CONFIG_FILE="/etc/instance_config"
else
    CONFIG_FILE="$SCRIPT_DIR/config"
fi
: > "$LOGFILE"

trap 'echo -e "${RED}Initialization failed. Check $LOGFILE for details${NC}" >&2' ERR

# Load config if exists (read-only, never written back)
load_config "$CONFIG_FILE"

############################################################# VM-SPECIFIC FUNCTIONS
# Active swap partitions as "NAME (SIZE), ..." (empty when none)
list_swap_partitions() {
    swapon --show=NAME,TYPE,SIZE --noheadings 2>/dev/null \
        | awk '$2 == "partition" {printf "%s%s (%s)", sep, $1, $3; sep = ", "}'
}

create_swapfile() {
    local swap_size="$1"
    local swap_file="/swapfile"
    if [[ "$(swapon --show=NAME --noheadings 2>/dev/null)" == *"$swap_file"* ]]; then
        log_info "Swapfile $swap_file already active — skipping"
        return 0
    fi
    run_cmd "Creating swapfile ($swap_size GB)" bash -c "
    set -e
    rm -f $swap_file
    fallocate -l ${swap_size}G $swap_file
    chmod 600 $swap_file
    mkswap $swap_file
    "
    run_cmd "Enabling swapfile" bash -c "
    set -e
    if ! grep -q '^$swap_file ' /etc/fstab; then
        echo '$swap_file none swap sw 0 0' >> /etc/fstab
    fi
    swapon $swap_file
    "
}

############################################################# MAIN
show_intro() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                                                                ║${NC}"
    echo -e "${BLUE}║       Instance Initialization (Phase 2)                        ║${NC}"
    echo -e "${BLUE}║                                                                ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Environment: $(is_lxc && echo "LXC Container" || echo "Virtual Machine")${NC}"
    echo ""
    log_info "This script will configure instance-specific settings:"
    echo "  • Hostname, domain and timezone"
    if ! is_lxc; then
        echo "  • Network (DHCP or static IP)"
        echo "  • Optional: pin interface names to MAC (nic0, nic1, … like Proxmox VE 9)"
    else
        echo "  • Network: managed by Proxmox (no internal config)"
    fi
    echo "  • Optional: Zabbix Agent"
    echo "  • Optional: Graylog Sidecar"
    echo "  • Optional: NFS shares (fstab)"
    if ! is_lxc; then
        echo "  • Optional: Swapfile"
    fi
    echo "  • Hardens SSH (at the end)"
    echo ""
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Config file detected: $CONFIG_FILE"
        log_info "Non-empty values will be used without prompting"
        echo ""
    fi
}

main() {
    check_root
    show_intro
    log_section "Current Status"
    log_info "Current hostname: $(hostname)"
    log_info "Current network:"
    ip -br addr show | grep -v "^lo" || true
    echo ""

    local codename
    codename=$(detect_debian_version)
    log_info "Debian version: $codename"

    local net_manager
    net_manager=$(check_network_manager)
    log_info "Network manager: $net_manager"
    echo ""

    log_section "Instance Configuration"

    get_opt INSTANCE_HOSTNAME "Hostname (e.g., web01)" "" validate_hostname
    get_opt INSTANCE_DOMAIN "Domain (e.g., example.com)" "localdomain" validate_domain
    # Default: keep the timezone chosen for the template
    get_opt INSTANCE_TIMEZONE "Timezone" \
        "$(timedatectl show -p Timezone --value 2>/dev/null || echo Europe/Warsaw)" validate_timezone
    echo ""

    # Network configuration — VM only (LXC managed by Proxmox)
    local configure_network_flag="n"
    PIN_INTERFACES="${PIN_INTERFACES:-}"
    NETWORK_TYPE="${NETWORK_TYPE:-}"
    NETWORK_TYPE="${NETWORK_TYPE,,}"

    if ! is_lxc; then
        if [[ "$net_manager" != "ifupdown" ]]; then
            log_warning "═══════════════════════════════════════════════════════"
            log_warning "  $net_manager is active on this system"
            log_warning "  This script only configures ifupdown (native)"
            log_warning "  Network configuration will be skipped"
            log_warning "═══════════════════════════════════════════════════════"
            PIN_INTERFACES="n"
        else
            configure_network_flag="y"
            log_info "Physical interfaces: $(list_physical_ifaces | xargs)"
            get_yn PIN_INTERFACES "Pin interface names to MAC (nic0, nic1, … like Proxmox VE 9)?" n
            if [[ "$PIN_INTERFACES" == "y" ]]; then
                get_opt PIN_PREFIX "Interface name prefix" "nic" validate_pin_prefix
            fi

            get_opt NETWORK_TYPE "IP assignment method (dhcp/static)" "dhcp" validate_network_type
            if [[ "$NETWORK_TYPE" == "static" ]]; then
                get_opt STATIC_IP "IP address (e.g., 192.168.1.100)" "" validate_ip
                get_opt CIDR_PREFIX "Network prefix" "24" validate_cidr
                get_opt GATEWAY_IP "Gateway" "${STATIC_IP%.*}.1" validate_ip
                get_opt DNS_SERVERS "DNS servers (space separated)" "$GATEWAY_IP 9.9.9.9" validate_ip_list
            fi
        fi
    else
        PIN_INTERFACES="n"
        log_info "LXC detected — Proxmox manages network configuration"
        log_info "To set static IP, use Proxmox: pct set <vmid> --net0 ...,ip=<ip>/<cidr>,gw=<gw>"
        if [[ "$NETWORK_TYPE" == "static" ]]; then
            log_warning "Static IP found in config but LXC network is managed by Proxmox"
        fi
    fi
    echo ""

    # Zabbix
    get_yn INSTALL_ZABBIX "Install Zabbix Agent 2?" n
    if [[ "$INSTALL_ZABBIX" == "y" ]]; then
        get_opt ZABBIX_ADDRESS "Zabbix server address"
        get_opt ZABBIX_PORT "Zabbix server port" "10051" validate_port
        check_network_connectivity || true
    fi
    echo ""

    # Graylog
    get_yn INSTALL_GRAYLOG "Install Graylog Sidecar?" n
    if [[ "$INSTALL_GRAYLOG" == "y" ]]; then
        get_opt GRAYLOG_ADDRESS "Graylog server URL (e.g., https://graylog:9000/api/)" "" validate_url
        # Sidecar needs the API endpoint
        [[ "$GRAYLOG_ADDRESS" =~ /api/?$ ]] || GRAYLOG_ADDRESS="${GRAYLOG_ADDRESS%/}/api/"
        get_opt GRAYLOG_API_TOKEN "Graylog API token"
        get_opt GRAYLOG_TAGS "Tags (comma separated)" "linux"
        get_yn GRAYLOG_TLS_SKIP_VERIFY "Skip TLS certificate verification (self-signed)?" n
    fi
    echo ""

    # VM-only: Swap
    local swap_partitions=""
    if ! is_lxc; then
        swap_partitions=$(list_swap_partitions || true)
        if [[ -n "$swap_partitions" ]]; then
            log_warning "Swap partition already active: $swap_partitions — a swapfile is probably not needed"
        fi
        get_opt SWAP_SIZE_GB "Swapfile size in GB (0 = no swapfile)" "0" validate_non_negative_int
        SWAP_SIZE_GB=$((10#$SWAP_SIZE_GB))
        echo ""
    else
        SWAP_SIZE_GB=0
    fi

    # SSH keys for debian — required when it has none (clones of older templates),
    # without them SSH hardening and root locking are skipped
    local -a ssh_keys=()
    local existing_keys=0
    if [[ -f /home/debian/.ssh/authorized_keys ]]; then
        existing_keys=$(grep -cE '^(ssh-|ecdsa-|sk-)' /home/debian/.ssh/authorized_keys || true)
    fi
    log_info "User debian has $existing_keys SSH key(s) — add more below or press Enter to keep them"
    read_ssh_keys ssh_keys $(( existing_keys > 0 ? 0 : 1 ))
    echo ""

    # NFS shares (interactive, like SSH keys)
    local -a nfs_shares=() nfs_mounts=()
    local line share mount_point name
    if is_lxc; then
        log_warning "LXC: NFS mounts need a privileged CT with the 'nfs' feature enabled in Proxmox"
    fi
    log_info "NFS shares to mount — 'server:/export [/mount/point]', one per line, empty line to finish:"
    while true; do
        read -r line
        [[ -z "$line" ]] && break
        read -r share mount_point _ <<< "$line"
        if ! validate_nfs_share "$share"; then
            log_error "Invalid share '$share' — use server:/export"
            continue
        fi
        if [[ -z "${mount_point:-}" ]]; then
            name="${share#*:}"; name="${name%/}"; name="${name##*/}"
            mount_point="/mnt/${name:-nfs}"
        fi
        if [[ "$mount_point" != /* || "$mount_point" == "/" ]]; then
            log_error "Invalid mount point '$mount_point' — use an absolute path"
            continue
        fi
        if [[ " ${nfs_mounts[*]} " == *" $mount_point "* ]]; then
            log_error "Mount point $mount_point already used above"
            continue
        fi
        nfs_shares+=("$share")
        nfs_mounts+=("$mount_point")
        echo "  Share ${#nfs_shares[@]} added: $share -> $mount_point"
    done
    echo ""

    # APT sources: http -> https where the mirror supports it (probed, rolled back on errors)
    get_yn APT_HTTPS "Switch apt sources to https (where supported)?" y
    echo ""

    # Summary
    log_section "Configuration Summary"
    echo "  Environment: $(is_lxc && echo "LXC" || echo "VM")"
    echo "  Hostname: $INSTANCE_HOSTNAME"
    echo "  Domain: $INSTANCE_DOMAIN"
    echo "  FQDN: $INSTANCE_HOSTNAME.$INSTANCE_DOMAIN"
    echo "  SSH keys (debian): $existing_keys existing + ${#ssh_keys[@]} new"
    echo "  Timezone: $INSTANCE_TIMEZONE"
    echo "  APT sources to https: $APT_HTTPS"
    if [[ "$INSTALL_ZABBIX" == "y" ]]; then
        echo "  Zabbix: $ZABBIX_ADDRESS:$ZABBIX_PORT"
    fi
    if [[ "$INSTALL_GRAYLOG" == "y" ]]; then
        echo "  Graylog: $GRAYLOG_ADDRESS (tags: $GRAYLOG_TAGS)"
    fi
    if ! is_lxc; then
        if [[ "$configure_network_flag" == "y" ]]; then
            if [[ "$PIN_INTERFACES" == "y" ]]; then
                echo "  Interface names: pinned (${PIN_PREFIX}0, ${PIN_PREFIX}1, …)"
            else
                echo "  Interface names: unchanged"
            fi
            echo "  Network: $NETWORK_TYPE"
            if [[ "$NETWORK_TYPE" == "static" ]]; then
                echo "    IP: $STATIC_IP/$CIDR_PREFIX"
                echo "    Gateway: $GATEWAY_IP"
                echo "    DNS: $DNS_SERVERS"
            fi
        else
            echo "  Network: Skipped (other network manager active)"
        fi
        if [[ -n "$swap_partitions" ]]; then
            echo "  Swap partition: $swap_partitions"
        fi
        if (( SWAP_SIZE_GB > 0 )); then
            echo "  Swapfile: ${SWAP_SIZE_GB}GB"
        else
            echo "  Swapfile: none"
        fi
    else
        echo "  Network: Managed by Proxmox"
    fi
    local i
    for i in "${!nfs_shares[@]}"; do
        echo "  NFS: ${nfs_shares[$i]} -> ${nfs_mounts[$i]}"
    done
    echo ""

    if ! confirm "Proceed with initialization?" n; then
        log_info "Aborted by user"
        exit 0
    fi

    # Execute — non-disruptive first
    log_section "Initializing Instance"

    # Same start as the template: clones of older templates get what they lack.
    # Broken repo entries out first — they fail every apt update.
    remove_legacy_apt_repos
    install_base_packages
    # After base packages: needs curl + ca-certificates. Not fatal — on apt errors
    # the function restores the http sources itself.
    if [[ "$APT_HTTPS" == "y" ]]; then
        apt_https_migrate --apply || log_warning "APT sources left on http (see $LOGFILE)"
    fi
    create_admin_user "${ssh_keys[@]}"
    configure_admin_sudo
    configure_shell_aliases

    set_hostname "$INSTANCE_HOSTNAME" "$INSTANCE_DOMAIN"

    # Network (VM only) — takes effect after reboot
    if [[ "$PIN_INTERFACES" == "y" ]]; then
        pin_interface_names "$PIN_PREFIX"
    fi
    if [[ "$configure_network_flag" == "y" ]]; then
        if [[ "$NETWORK_TYPE" == "static" ]]; then
            configure_network static "$STATIC_IP" "$CIDR_PREFIX" "$GATEWAY_IP" "$DNS_SERVERS"
        else
            configure_network dhcp
        fi
    fi

    configure_time_sync "$INSTANCE_TIMEZONE"

    if [[ "$INSTALL_ZABBIX" == "y" ]]; then
        install_zabbix "$codename" "$ZABBIX_ADDRESS" "$ZABBIX_PORT" "$INSTANCE_HOSTNAME"
    fi

    if [[ "$INSTALL_GRAYLOG" == "y" ]]; then
        install_graylog "$GRAYLOG_ADDRESS" "$GRAYLOG_API_TOKEN" "$GRAYLOG_TAGS" "$GRAYLOG_TLS_SKIP_VERIFY" || true
    fi

    if (( SWAP_SIZE_GB > 0 )); then
        create_swapfile "$SWAP_SIZE_GB"
    fi

    if (( ${#nfs_shares[@]} > 0 )); then
        for i in "${!nfs_shares[@]}"; do
            add_nfs_mount "${nfs_shares[$i]}" "${nfs_mounts[$i]}"
        done
    fi

    start_services

    # Disruptive operations LAST
    log_section "Finalizing (disruptive operations)"

    regenerate_ssh_keys

    # Lock down AFTER everything is configured and working.
    # Root is only locked when key-only SSH and sudo for debian are in place — otherwise no way in.
    if harden_ssh; then
        if admin_has_sudo; then
            secure_root_account
        else
            log_warning "debian has no working sudo — root NOT locked"
        fi
    else
        log_warning "SSH not hardened and root not locked — fix SSH keys and re-run"
    fi

    # Single restart: new host keys + hardening
    run_cmd "Restarting SSH service" systemctl restart ssh

    # Verification and summary (failures are reported, not fatal)
    verify_installation || log_warning "Check the failures above"
    show_final_summary

    log_info "Initialization complete"
    echo ""
    if [[ "$configure_network_flag" == "y" ]]; then
        log_warning "Network changes are applied on REBOOT — reboot required"
    else
        log_warning "A reboot is recommended to apply all changes"
    fi
    log_info "Note: SSH host keys have been regenerated — clear known_hosts entries"
    if confirm "Reboot now?" y; then
        sync
        sleep 3
        systemctl reboot
    fi
}

main "$@"
