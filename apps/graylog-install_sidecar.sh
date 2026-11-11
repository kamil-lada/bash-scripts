#!/bin/bash
# Graylog Sidecar install / reconfigure — Debian 12 (bookworm) / 13 (trixie), VM or LXC
#
# Installs the latest release .deb from GitHub (bundles filebeat + auditbeat in
# /usr/lib/graylog-sidecar/). Re-running upgrades the package and rewrites the config.
#
# Unattended: preset any of the settings in the environment, e.g.
#   GRAYLOG_ADDRESS=https://graylog:9000/api/ GRAYLOG_API_TOKEN=xxx GRAYLOG_TAGS=linux,web \
#   GRAYLOG_TLS_SKIP_VERIFY=n bash graylog-install_sidecar.sh
set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

LOGFILE="/var/log/graylog-sidecar-install.log"
: > "$LOGFILE"

trap 'echo -e "${RED}Script failed. Check $LOGFILE for details${NC}" >&2' ERR

main() {
    log_section "Graylog Sidecar Installation"
    check_root
    local codename
    codename=$(detect_debian_version)
    log_success "Debian $codename ($(dpkg --print-architecture))$(is_lxc && echo ', LXC')"

    get_opt GRAYLOG_ADDRESS "Graylog server URL (e.g., https://graylog:9000/api/)" "" validate_url
    # Sidecar needs the API endpoint
    [[ "$GRAYLOG_ADDRESS" =~ /api/?$ ]] || GRAYLOG_ADDRESS="${GRAYLOG_ADDRESS%/}/api/"
    get_opt GRAYLOG_API_TOKEN "Graylog API token"
    get_opt GRAYLOG_TAGS "Tags (comma separated)" "linux"
    get_yn GRAYLOG_TLS_SKIP_VERIFY "Skip TLS certificate verification (self-signed)?" n

    if ! install_graylog "$GRAYLOG_ADDRESS" "$GRAYLOG_API_TOKEN" "$GRAYLOG_TAGS" "$GRAYLOG_TLS_SKIP_VERIFY"; then
        log_error "Graylog Sidecar installation failed. Check $LOGFILE for details"
        exit 1
    fi

    run_cmd "Starting Graylog Sidecar" systemctl restart graylog-sidecar
    sleep 3
    if ! systemctl is-active --quiet graylog-sidecar; then
        log_error "Graylog Sidecar is not running — see: journalctl -u graylog-sidecar"
        exit 1
    fi
    log_success "Graylog Sidecar: Running"

    log_section "Done"
    printf "  %-18s %s\n" "Version:" "$(dpkg-query -W -f='${Version}' graylog-sidecar)"
    printf "  %-18s %s\n" "Server:" "$GRAYLOG_ADDRESS"
    printf "  %-18s %s\n" "Tags:" "$GRAYLOG_TAGS"
    printf "  %-18s %s\n" "Config:" "/etc/graylog/sidecar/sidecar.yml"
    printf "  %-18s %s\n" "Sidecar log:" "/var/log/graylog-sidecar/sidecar.log"
    printf "  %-18s %s\n" "Install log:" "$LOGFILE"
    echo ""
    log_info "Check the host appears in Graylog: System > Sidecars (errors: sidecar.log above)"
    if is_lxc; then
        log_warning "LXC: auditbeat cannot run in an unprivileged container — assign only filebeat configs to this host's tags"
    fi
}

main "$@"
