#!/bin/bash
# Instance Initialization Script (Phase 2) — handles both VM and LXC
set -euo pipefail

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

# Set log file
LOGFILE="/var/log/initialize_for_usecase.log"
CONFIG_FILE="/etc/instance_config"
: > "$LOGFILE"

trap 'echo -e "${RED}Initialization failed. Check $LOGFILE for details${NC}" >&2' ERR

# Load config if exists (read-only, never written back)
load_config "$CONFIG_FILE"

############################################################# VM-SPECIFIC FUNCTIONS
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

regenerate_machine_id() {
    run_cmd "Regenerating machine-id" bash -c '
    if [[ ! -s /etc/machine-id ]]; then
        systemd-machine-id-setup
    fi
    '
    run_cmd "Restarting D-Bus" systemctl restart dbus
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
    if ! grep -q '$swap_file' /etc/fstab; then
        echo '$swap_file none swap sw 0 0' >> /etc/fstab
    fi
    if ! swapon --show | grep -q '$swap_file'; then
        swapon $swap_file
    fi
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
    echo "  • Hostname and domain"
    if ! is_lxc; then
        echo "  • Network (DHCP or static IP)"
    else
        echo "  • Network: managed by Proxmox (no internal config)"
    fi
    echo "  • Optional: Zabbix Agent"
    echo "  • Optional: Graylog Sidecar"
    if ! is_lxc; then
        echo "  • Optional: Swapfile"
    fi
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
    ip -br addr show | grep -v "^lo"
    echo ""

    local codename
    codename=$(detect_debian_version)
    log_info "Debian version: $codename"

    local net_manager
    net_manager=$(check_network_manager)
    log_info "Network manager: $net_manager"
    echo ""

    log_section "Instance Configuration"

    # Hostname (from config or prompt)
    local new_hostname
    if [[ -n "${INSTANCE_HOSTNAME:-}" ]]; then
        new_hostname="$INSTANCE_HOSTNAME"
        log_info "Using hostname from config: $new_hostname"
    else
        while true; do
            read -rp "Enter hostname (e.g., web01): " new_hostname
            if [[ -z "$new_hostname" ]]; then
                log_error "Hostname cannot be empty"
                continue
            fi
            if ! validate_hostname "$new_hostname"; then
                log_error "Invalid hostname format"
                continue
            fi
            break
        done
    fi

    # Domain
    local domain
    if [[ -n "${INSTANCE_DOMAIN:-}" ]]; then
        domain="$INSTANCE_DOMAIN"
        log_info "Using domain from config: $domain"
    else
        while true; do
            read -rp "Enter domain (e.g., example.com) [localdomain]: " domain
            domain="${domain:-localdomain}"
            if validate_domain "$domain"; then
                break
            fi
            log_error "Invalid domain format"
        done
    fi
    echo ""

    # Network configuration — VM only (LXC managed by Proxmox)
    local network_type="" static_ip="" cidr="" gateway="" dns_servers="" enable_legacy_naming="n"
    local configure_network_flag="no"
    if ! is_lxc; then
        configure_network_flag="yes"
        if [[ "$net_manager" != "ifupdown" ]]; then
            log_warning "═══════════════════════════════════════════════════════"
            log_warning "  $net_manager is active on this system"
            log_warning "  This script only configures ifupdown (native)"
            log_warning "  Network configuration will be skipped"
            log_warning "═══════════════════════════════════════════════════════"
            configure_network_flag="no"
        fi

        if [[ "$configure_network_flag" == "yes" ]]; then
            # Legacy naming check
            if check_using_predictable_names; then
                log_info "Currently using predictable names (ens*, enp*)"
                if [[ -n "${LEGACY_NAMING:-}" ]]; then
                    enable_legacy_naming="${LEGACY_NAMING}"
                    log_info "Using legacy naming from config: $enable_legacy_naming"
                else
                    read -rp "Switch to legacy names (eth0, eth1)? (y/N): " enable_legacy_naming
                    enable_legacy_naming="${enable_legacy_naming:-n}"
                fi
            else
                log_info "Using legacy interface names (eth0, eth1, etc.)"
            fi
            echo ""

            # Network type
            if [[ -n "${NETWORK_TYPE:-}" ]]; then
                network_type="${NETWORK_TYPE}"
                log_info "Using network type from config: $network_type"
            else
                while true; do
                    read -rp "Choose IP assignment method (dhcp/static) [dhcp]: " network_type
                    network_type="${network_type:-dhcp}"
                    network_type=$(echo "$network_type" | tr '[:upper:]' '[:lower:]')
                    if [[ "$network_type" == "dhcp" || "$network_type" == "static" ]]; then
                        break
                    fi
                    log_error "Please enter 'dhcp' or 'static'"
                done
            fi

            if [[ "$network_type" == "static" ]]; then
                if [[ -n "${STATIC_IP:-}" ]]; then
                    static_ip="$STATIC_IP"
                    cidr="${CIDR_PREFIX:-24}"
                    gateway="${GATEWAY_IP:-}"
                    dns_servers="${DNS_SERVERS:-$gateway 9.9.9.9}"
                    log_info "Using static IP from config: $static_ip/$cidr"
                else
                    while true; do
                        read -rp "IP address (e.g., 192.168.1.100): " static_ip
                        if validate_ip "$static_ip"; then
                            break
                        fi
                        log_error "Invalid IP format"
                    done
                    while true; do
                        read -rp "Network prefix [24]: " cidr
                        cidr="${cidr:-24}"
                        if validate_cidr "$cidr"; then
                            break
                        fi
                        log_error "Invalid CIDR"
                    done
                    local default_gateway
                    default_gateway=$(echo "$static_ip" | sed 's/\.[0-9]*$/\.1/')
                    read -rp "Gateway [$default_gateway]: " gateway
                    gateway="${gateway:-$default_gateway}"
                    dns_servers="$gateway 9.9.9.9"
                fi
            fi
        fi
    else
        log_info "LXC detected — Proxmox manages network configuration"
        log_info "To set static IP, use Proxmox: pct set <vmid> --ip <ip>/<cidr>"
        if [[ -n "${NETWORK_TYPE:-}" && "${NETWORK_TYPE}" == "static" ]]; then
            log_warning "Static IP found in config but LXC network is managed by Proxmox"
            log_warning "Configure IP via Proxmox instead: pct set <vmid> --ip ${STATIC_IP:-<ip>}/${CIDR_PREFIX:-24}"
        fi
    fi
    echo ""

    # Zabbix
    local install_zabbix="n" zabbix_address="" zabbix_port=""
    if [[ -n "${INSTALL_ZABBIX:-}" && "${INSTALL_ZABBIX}" =~ ^[Yy]$ ]]; then
        install_zabbix="y"
        zabbix_address="${ZABBIX_ADDRESS:-}"
        zabbix_port="${ZABBIX_PORT:-10051}"
        log_info "Zabbix from config: $zabbix_address:$zabbix_port"
    else
        read -rp "Install Zabbix Agent 2? (y/N): " install_zabbix
        install_zabbix="${install_zabbix:-n}"
    fi

    if [[ "$install_zabbix" =~ ^[Yy]$ ]] && [[ -z "$zabbix_address" ]]; then
        while true; do
            read -rp "Zabbix server address: " zabbix_address
            [[ -n "$zabbix_address" ]] && break
            log_error "Zabbix address cannot be empty"
        done
        read -rp "Zabbix server port [10051]: " zabbix_port
        zabbix_port="${zabbix_port:-10051}"
    fi
    echo ""

    # Graylog
    local install_graylog="n" graylog_address="" graylog_api_token="" graylog_tags=""
    if [[ -n "${INSTALL_GRAYLOG:-}" && "${INSTALL_GRAYLOG}" =~ ^[Yy]$ ]]; then
        install_graylog="y"
        graylog_address="${GRAYLOG_ADDRESS:-}"
        graylog_api_token="${GRAYLOG_API_TOKEN:-}"
        graylog_tags="${GRAYLOG_TAGS:-linux}"
        log_info "Graylog from config: $graylog_address"
    else
        read -rp "Install Graylog Sidecar? (y/N): " install_graylog
        install_graylog="${install_graylog:-n}"
    fi

    if [[ "$install_graylog" =~ ^[Yy]$ ]] && [[ -z "$graylog_address" ]]; then
        while true; do
            read -rp "Graylog server URL (must end with /api/): " graylog_address
            if [[ -n "$graylog_address" ]]; then
                if [[ ! "$graylog_address" =~ /api/?$ ]]; then
                    if [[ "$graylog_address" =~ /$ ]]; then
                        graylog_address="${graylog_address}api/"
                    else
                        graylog_address="${graylog_address}/api/"
                    fi
                fi
                if validate_graylog_url "$graylog_address"; then
                    break
                fi
            fi
            log_error "Invalid URL"
        done
        while true; do
            read -rp "Graylog API token: " graylog_api_token
            [[ -n "$graylog_api_token" ]] && break
            log_error "API token cannot be empty"
        done
        read -rp "Additional tags [linux]: " graylog_tags
        graylog_tags="${graylog_tags:-linux}"
    fi
    echo ""

    # VM-only: Swap
    local create_swap="n" swap_size="1"
    if ! is_lxc; then
        if [[ -n "${CREATE_SWAP:-}" && "${CREATE_SWAP}" =~ ^[Yy]$ ]]; then
            create_swap="y"
            swap_size="${SWAP_SIZE_GB:-1}"
            log_info "Swap from config: ${swap_size}GB"
        else
            read -rp "Create swapfile? (y/N): " create_swap
            create_swap="${create_swap:-n}"
        fi

        if [[ "$create_swap" =~ ^[Yy]$ ]] && [[ -z "${SWAP_SIZE_GB:-}" ]]; then
            read -rp "Swapfile size in GB [1]: " swap_size
            swap_size="${swap_size:-1}"
        fi
        echo ""
    fi

    # Bash scripts repo
    local clone_repo="n"
    if [[ -n "${CLONE_REPO:-}" && "${CLONE_REPO}" =~ ^[Yy]$ ]]; then
        clone_repo="y"
    else
        read -rp "Clone bash-scripts repository? (y/N): " clone_repo
        clone_repo="${clone_repo:-n}"
    fi
    echo ""

    # Summary
    log_section "Configuration Summary"
    echo "  Environment: $(is_lxc && echo "LXC" || echo "VM")"
    echo "  Hostname: $new_hostname"
    echo "  Domain: $domain"
    echo "  FQDN: $new_hostname.$domain"
    if [[ "$install_zabbix" =~ ^[Yy]$ ]]; then
        echo "  Zabbix: $zabbix_address:$zabbix_port"
    fi
    if [[ "$install_graylog" =~ ^[Yy]$ ]]; then
        echo "  Graylog: $graylog_address"
    fi
    if ! is_lxc; then
        if [[ "$configure_network_flag" == "yes" ]]; then
            echo "  Network: $network_type"
            if [[ "$network_type" == "static" ]]; then
                echo "    IP: $static_ip/$cidr"
                echo "    Gateway: $gateway"
            fi
        else
            echo "  Network: Skipped (other network manager active)"
        fi
        if [[ "$create_swap" =~ ^[Yy]$ ]]; then
            echo "  Swapfile: ${swap_size}GB"
        fi
    else
        echo "  Network: Managed by Proxmox"
    fi
    echo ""

    read -rp "Proceed with initialization? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Aborted by user"
        exit 0
    fi

    # Execute
    log_section "Initializing Instance"

    regenerate_ssh_keys

    # VM-only: regenerate machine-id
    if ! is_lxc; then
        regenerate_machine_id
    fi

    set_hostname "$new_hostname" "$domain"

    # Network (VM only — LXC handled by Proxmox)
    if [[ "$configure_network_flag" == "yes" ]]; then
        configure_network "$network_type" "$static_ip" "$cidr" "$gateway" "$dns_servers" "$enable_legacy_naming"
    fi

    configure_time_sync "${INSTANCE_TIMEZONE:-Europe/Warsaw}"

    if [[ "$install_zabbix" =~ ^[Yy]$ ]]; then
        install_zabbix "$codename" "$zabbix_address" "$zabbix_port" "$new_hostname"
    fi

    if [[ "$install_graylog" =~ ^[Yy]$ ]]; then
        install_graylog "$graylog_address" "$graylog_api_token" "$graylog_tags"
    fi

    if ! is_lxc && [[ "$create_swap" =~ ^[Yy]$ ]]; then
        create_swapfile "$swap_size"
    fi

    if [[ "$clone_repo" =~ ^[Yy]$ ]]; then
        clone_bash_scripts
    fi

    start_services

    # Lock down AFTER everything is configured and working
    harden_ssh
    secure_root_account

    # Verification and summary
    verify_installation
    show_final_summary

    log_info "Initialization complete"
    echo ""
    log_warning "A reboot is recommended to apply all changes"
    read -rp "Reboot now? (Y/n): " reboot_now
    reboot_now="${reboot_now:-y}"
    if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
        sync
        sleep 3
        systemctl reboot
    fi
}

main "$@"