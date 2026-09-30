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
    if [[ -n "${INSTALL_ZABBIX:-}" && "${INSTALL_ZABBIX}" =~ ^[