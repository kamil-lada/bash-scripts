#!/bin/bash
# Caddy with Cloudflare DNS-01 certificates — Debian 12 (bookworm) / 13 (trixie), VM or LXC
#
# Sets up the host only; the Caddyfile itself is a single file managed elsewhere
# (git / Jenkins) and activated with caddy-apply. A starter Caddyfile
# (caddy-Caddyfile.example) is installed only when none exists yet.
#
# Layout (Caddy docs: "Debian packages + custom binary"):
#   - Debian 'caddy' package from the official Cloudsmith repo provides the
#     service, the caddy user, /etc/caddy and apt updates of the stock binary
#   - optional catch-all in the starter: every other *.zone host is forwarded to
#     another Caddy (e.g. Docker, see docker-setup_caddy.sh)
#   - stock binary diverted to /usr/bin/caddy.default, /usr/bin/caddy is an
#     alternatives link to /usr/bin/caddy.custom = build with caddy-dns/cloudflare
#
# Installed tools (standalone, do not need this repository):
#   /usr/local/sbin/caddy-update   update Caddy + plugins (apps/caddy/caddy-update.sh)
#   /usr/local/sbin/caddy-apply    validate + activate a Caddyfile (apps/caddy/caddy-apply.sh)
#
# Files:
#   /etc/caddy/Caddyfile           the config (deployed by automation)
#   /etc/caddy/caddy.env           CF_API_TOKEN (0600, systemd EnvironmentFile)
#   /etc/caddy/caddy-update.conf   plugin list + settings of this script
#
# Usage:
#   caddy-install_cloudflare.sh             install, or menu when already installed
#   caddy-install_cloudflare.sh --update [caddy-update options]
#                                           refresh the tools from this repo and run caddy-update
set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

LOGFILE="/var/log/caddy-install.log"

trap 'echo -e "${RED}Script failed. Check $LOGFILE for details${NC}" >&2' ERR

readonly UPDATER_SRC="$SCRIPT_DIR/caddy-update.sh"
readonly APPLY_SRC="$SCRIPT_DIR/caddy-apply.sh"
readonly TEMPLATE_SRC="$SCRIPT_DIR/caddy-Caddyfile.example"
readonly UPDATER=/usr/local/sbin/caddy-update
readonly APPLY=/usr/local/sbin/caddy-apply
readonly CONF_FILE=/etc/caddy/caddy-update.conf
readonly ENV_FILE=/etc/caddy/caddy.env
readonly CADDYFILE=/etc/caddy/Caddyfile
readonly CADDY_LOG_DIR=/var/log/caddy
readonly DROPIN=/etc/systemd/system/caddy.service.d/10-cloudflare.conf
readonly TIMER_UNIT=/etc/systemd/system/caddy-update.timer
readonly TIMER_SERVICE=/etc/systemd/system/caddy-update.service
readonly SUDOERS_FILE=/etc/sudoers.d/caddy-apply
readonly SYSCTL_FILE=/etc/sysctl.d/60-caddy-quic.conf
readonly CUSTOM_BIN=/usr/bin/caddy.custom
readonly MANAGED_MARK="# Managed by caddy-install_cloudflare.sh"
readonly CF_PLUGIN=github.com/caddy-dns/cloudflare
readonly CADDY_REPO=https://dl.cloudsmith.io/public/caddy/stable/deb/debian
readonly CADDY_KEY=https://dl.cloudsmith.io/public/caddy/stable/gpg.key

# Settings — defaults, overridden by $CONF_FILE on reconfigure
CF_ZONE=""
EXTRA_PLUGINS=""
AUTO_UPDATE="n"
DEPLOY_USER=""
PLUGINS=""

CF_API_TOKEN=""
INSTALL_STARTER="n"
CATCH_ALL_UPSTREAM=""
RECONFIGURE="n"

############################################################# HELPERS
is_pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

is_installed() {
    [[ -f "$CONF_FILE" && -x "$CUSTOM_BIN" ]]
}

validate_user() {
    [[ -z "$1" ]] || id "$1" &>/dev/null
}

# ask_optional "Question" CURRENT -> answer; "-" clears the current value
ask_optional() {
    local answer
    answer=$(ask "$1 (- for none)" "$2")
    [[ "$answer" == "-" ]] && answer=""
    echo "$answer"
}

# Missing or still the package's default (:80 file_server)
caddyfile_is_default() {
    [[ ! -s "$CADDYFILE" ]] && return 0
    grep -q 'root \* /usr/share/caddy' "$CADDYFILE" \
        && [[ $(grep -cvE '^[[:space:]]*(#|$)' "$CADDYFILE") -le 8 ]]
}

load_settings() {
    [[ -r "$CONF_FILE" ]] || return 0
    PLUGINS=$(conf_get "$CONF_FILE" PLUGINS)
    CF_ZONE=$(conf_get "$CONF_FILE" CF_ZONE)
    AUTO_UPDATE=$(conf_get "$CONF_FILE" AUTO_UPDATE)
    DEPLOY_USER=$(conf_get "$CONF_FILE" DEPLOY_USER)
    [[ "$AUTO_UPDATE" == "y" ]] || AUTO_UPDATE="n"
    validate_caddy_plugins "$PLUGINS" || { log_error "Invalid PLUGINS in $CONF_FILE: '$PLUGINS'"; exit 1; }
    local p extra=""
    for p in $PLUGINS; do
        [[ "$p" == "$CF_PLUGIN" ]] || extra+="${extra:+ }$p"
    done
    EXTRA_PLUGINS="$extra"
}

read_env_token() {
    conf_get "$ENV_FILE" CF_API_TOKEN
}

install_tools() {
    local src
    for src in "$UPDATER_SRC" "$APPLY_SRC"; do
        [[ -f "$src" ]] || { log_error "$src not found"; exit 1; }
    done
    run_cmd "Installing $UPDATER" install -m 0755 "$UPDATER_SRC" "$UPDATER"
    run_cmd "Installing $APPLY" install -m 0755 "$APPLY_SRC" "$APPLY"
}

############################################################# PRE-FLIGHT
preflight() {
    log_section "Pre-flight checks"
    check_root
    local codename
    codename=$(detect_debian_version)
    log_success "Debian $codename ($(dpkg --print-architecture))"

    if is_lxc; then
        log_success "LXC container detected (unprivileged is fine — caddy binds 80/443 via CAP_NET_BIND_SERVICE)"
    else
        log_success "Virtual machine / bare metal detected"
    fi

    check_network_connectivity || exit 1
    check_disk_space 300 || exit 1

    if [[ "$RECONFIGURE" == "n" ]] && is_pkg_installed caddy; then
        log_warning "Caddy package is already installed (not set up by this script)"
        log_warning "It will be converted to the custom build; the existing Caddyfile is kept"
        confirm "Continue?" y || exit 0
    fi

    local busy
    busy=$(ss -Hltnp '( sport = :80 or sport = :443 )' 2>/dev/null | grep -v '"caddy' || true)
    if [[ -n "$busy" ]]; then
        log_warning "Ports 80/443 are already used by another process:"
        echo "$busy" | sed 's/^/  /'
        confirm "Continue anyway?" n || exit 1
    fi
}

############################################################# INTERACTIVE CONFIG
gather_config() {
    log_section "Configuration"

    while true; do
        CF_ZONE=$(ask "Cloudflare zone (domain managed in Cloudflare, e.g. example.com)" "$CF_ZONE")
        CF_ZONE="${CF_ZONE,,}"
        validate_domain "$CF_ZONE" && [[ "$CF_ZONE" == *.* ]] && break
        log_error "Invalid domain: '$CF_ZONE'"
    done

    ask_cf_token CF_API_TOKEN "$CF_ZONE" "$(read_env_token)"

    while true; do
        EXTRA_PLUGINS=$(ask_optional "Additional Caddy plugins (Go package paths, space separated)" "$EXTRA_PLUGINS")
        validate_caddy_plugins "$EXTRA_PLUGINS" && break
        log_error "Use Go package paths like github.com/mholt/caddy-ratelimit"
    done
    PLUGINS="$CF_PLUGIN${EXTRA_PLUGINS:+ $EXTRA_PLUGINS}"

    if confirm "Enable weekly automatic update of the Caddy binary (systemd timer)?" "$AUTO_UPDATE"; then
        AUTO_UPDATE="y"
    else
        AUTO_UPDATE="n"
    fi

    log_info "A deploy user (e.g. jenkins, via SSH) may run 'sudo caddy-apply' without a password."
    log_info "It can then change what Caddy serves — give it to automation accounts only."
    while true; do
        DEPLOY_USER=$(ask_optional "Deploy user allowed to run caddy-apply" "$DEPLOY_USER")
        validate_user "$DEPLOY_USER" && break
        log_error "User '$DEPLOY_USER' does not exist — create it first"
    done

    if caddyfile_is_default; then
        INSTALL_STARTER="y"
        log_info "Starter Caddyfile: optionally forward every other *.$CF_ZONE host (no own"
        log_info "site block) to another Caddy, e.g. Caddy in Docker (docker-setup_caddy.sh)."
        while true; do
            CATCH_ALL_UPSTREAM=$(ask_optional "Catch-all target Caddy (IP or host[:port], HTTPS)" "")
            [[ -z "$CATCH_ALL_UPSTREAM" ]] || validate_hostport "$CATCH_ALL_UPSTREAM" && break
            log_error "Use an IP or hostname, optionally with :port"
        done
    fi

    log_section "Summary"
    printf "  %-26s %s\n" "Environment:" "$(is_lxc && echo "LXC Container" || echo "Virtual Machine")"
    printf "  %-26s %s\n" "Cloudflare zone:" "$CF_ZONE"
    printf "  %-26s %s\n" "Plugins:" "$PLUGINS"
    printf "  %-26s %s\n" "Auto update:" "$([[ "$AUTO_UPDATE" == "y" ]] && echo "weekly (caddy-update.timer)" || echo "no — run caddy-update manually")"
    printf "  %-26s %s\n" "Deploy user (sudo):" "${DEPLOY_USER:-none}"
    printf "  %-26s %s\n" "Caddyfile:" "$([[ "$INSTALL_STARTER" == "y" ]] && echo "install starter (example hosts in $CF_ZONE)" || echo "keep existing")"
    if [[ "$INSTALL_STARTER" == "y" ]]; then
        printf "  %-26s %s\n" "Catch-all *.$CF_ZONE:" \
            "$([[ -n "$CATCH_ALL_UPSTREAM" ]] && echo "-> https://$CATCH_ALL_UPSTREAM" || echo "none")"
    fi
    echo ""
    confirm "Proceed?" y || { log_info "Aborted."; exit 0; }
}

############################################################# INSTALL
install_caddy_package() {
    log_section "Installing Caddy package"
    if is_pkg_installed caddy && [[ -f /etc/apt/sources.list.d/caddy-stable.sources ]]; then
        log_success "Caddy package already installed from the official repository"
        return 0
    fi
    ensure_packages curl ca-certificates
    add_apt_repo caddy-stable "$CADDY_REPO" any-version main "$CADDY_KEY"
    run_cmd "Installing caddy" env DEBIAN_FRONTEND=noninteractive apt-get install -y caddy
    log_success "Installed caddy package $(dpkg-query -W -f='${Version}' caddy)"
}

write_settings() {
    log_section "Writing configuration"

    {
        echo "$MANAGED_MARK — read by caddy-update and by the installer on re-run"
        echo "# Plain KEY=value, parsed as text (never sourced)"
        printf 'PLUGINS=%s\n' "$PLUGINS"
        printf 'CF_ZONE=%s\n' "$CF_ZONE"
        printf 'AUTO_UPDATE=%s\n' "$AUTO_UPDATE"
        printf 'DEPLOY_USER=%s\n' "$DEPLOY_USER"
    } > "$CONF_FILE"
    chmod 0644 "$CONF_FILE"
    log_success "Settings: $CONF_FILE"

    ( umask 077; printf '%s\nCF_API_TOKEN=%s\n' "$MANAGED_MARK" "$CF_API_TOKEN" > "$ENV_FILE" )
    chown root:root "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
    log_success "Token: $ENV_FILE (root only, 0600)"

    mkdir -p "$(dirname "$DROPIN")"
    cat > "$DROPIN" <<EOF
$MANAGED_MARK
[Service]
EnvironmentFile=$ENV_FILE
EOF
    log_success "systemd drop-in: $DROPIN"

    # For file access logs (log { output file /var/log/caddy/... })
    install -d -m 0755 -o caddy -g caddy "$CADDY_LOG_DIR"

    if [[ "$INSTALL_STARTER" == "y" ]]; then
        [[ -f "$TEMPLATE_SRC" ]] || { log_error "$TEMPLATE_SRC not found"; exit 1; }
        if [[ -s "$CADDYFILE" ]]; then
            cp -p "$CADDYFILE" "$CADDYFILE.package-default"
            log_info "Package default Caddyfile saved as $CADDYFILE.package-default"
        fi
        caddy_render_template "$TEMPLATE_SRC" "$CADDYFILE" "$CF_ZONE" "$CATCH_ALL_UPSTREAM" ""
        chmod 0644 "$CADDYFILE"
        log_success "Starter Caddyfile: $CADDYFILE (example hosts — replace via your deployment)"
    else
        log_info "Existing $CADDYFILE kept"
    fi

    if [[ -n "$DEPLOY_USER" ]]; then
        ensure_packages sudo
        local tmp
        tmp=$(mktemp)
        cat > "$tmp" <<EOF
$MANAGED_MARK
$DEPLOY_USER ALL=(root) NOPASSWD: $APPLY, $APPLY *
EOF
        if visudo -cqf "$tmp"; then
            install -m 0440 "$tmp" "$SUDOERS_FILE"
            log_success "sudo rule for $DEPLOY_USER: $SUDOERS_FILE"
        else
            log_error "Generated sudoers rule is invalid — not installed"
        fi
        rm -f "$tmp"
    elif [[ -f "$SUDOERS_FILE" ]]; then
        rm -f "$SUDOERS_FILE"
        log_info "Removed $SUDOERS_FILE"
    fi
}

install_binary() {
    log_section "Installing custom Caddy build"
    install_tools
    log_info "Downloading Caddy + $PLUGINS from caddyserver.com (built on demand, may take a minute)..."
    # Installs the binary, dpkg-divert + alternatives; restart is done below
    if ! "$UPDATER" --no-restart 2>&1 | tee -a "$LOGFILE"; then
        log_error "caddy-update failed — see output above"
        exit 1
    fi
    if ! /usr/bin/caddy list-modules 2>/dev/null | grep -qx 'dns.providers.cloudflare'; then
        log_error "/usr/bin/caddy has no dns.providers.cloudflare module"
        exit 1
    fi
    log_success "/usr/bin/caddy -> $(readlink -f /usr/bin/caddy) ($(/usr/bin/caddy version | awk '{print $1}'))"
}

configure_auto_update() {
    if [[ "$AUTO_UPDATE" == "y" ]]; then
        cat > "$TIMER_SERVICE" <<EOF
$MANAGED_MARK
[Unit]
Description=Update custom Caddy build (caddy-update)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$UPDATER --quiet
EOF
        cat > "$TIMER_UNIT" <<EOF
$MANAGED_MARK
[Unit]
Description=Weekly update of custom Caddy build

[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
        run_cmd "Reloading systemd" systemctl daemon-reload
        run_cmd "Enabling caddy-update.timer" systemctl enable --now caddy-update.timer
    elif [[ -f "$TIMER_UNIT" ]]; then
        run_cmd_continue "Disabling caddy-update.timer" systemctl disable --now caddy-update.timer || true
        rm -f "$TIMER_UNIT" "$TIMER_SERVICE"
        run_cmd "Reloading systemd" systemctl daemon-reload
    fi
}

# HTTP/3 (QUIC) wants bigger UDP buffers. net.core.* is not namespaced: in LXC it
# can only be set on the Proxmox host.
configure_quic_buffers() {
    if is_lxc; then
        if (( $(sysctl -n net.core.rmem_max 2>/dev/null || echo 0) < 7500000 )); then
            log_info "HTTP/3: for full UDP buffers set on the Proxmox HOST (affects all CTs):"
            log_info "  net.core.rmem_max=7500000 and net.core.wmem_max=7500000 in /etc/sysctl.d/"
        fi
        return 0
    fi
    cat > "$SYSCTL_FILE" <<EOF
$MANAGED_MARK — UDP buffers for HTTP/3 (quic-go)
net.core.rmem_max=7500000
net.core.wmem_max=7500000
EOF
    run_cmd_continue "Applying UDP buffer sysctls" sysctl -p "$SYSCTL_FILE" || true
}

start_and_verify() {
    log_section "Starting and verifying"

    if ! "$APPLY" --check 2>&1 | tee -a "$LOGFILE"; then
        log_error "Caddyfile validation failed — fix $CADDYFILE, then: caddy-apply"
        exit 1
    fi

    run_cmd "Reloading systemd" systemctl daemon-reload
    run_cmd "Enabling caddy" systemctl enable caddy
    # Restart (not reload): picks up the new binary and the EnvironmentFile
    if ! run_cmd_continue "Restarting caddy" systemctl restart caddy; then
        journalctl -u caddy -n 30 --no-pager -o cat | sed 's/^/  /' >&2
        exit 1
    fi
    sleep 2
    if ! systemctl is-active --quiet caddy; then
        log_error "caddy is not running"
        journalctl -u caddy -n 30 --no-pager -o cat | sed 's/^/  /' >&2
        exit 1
    fi
    log_success "caddy is running"
    if [[ "$INSTALL_STARTER" == "y" ]]; then
        log_warning "The starter Caddyfile has example hosts — Caddy will try to get certificates for them"
        log_warning "until you deploy your own Caddyfile (watch: journalctl -u caddy -f)"
    fi
}

############################################################# MODES
mode_update() {
    check_root
    install_tools
    log_section "Updating Caddy"
    exec "$UPDATER" "$@"
}

show_menu() {
    log_section "Caddy (Cloudflare DNS) is already installed"
    printf "  %-26s %s\n" "Binary:" "$("$CUSTOM_BIN" version 2>/dev/null | awk '{print $1}')"
    printf "  %-26s %s\n" "Plugins:" "$(sed -n 's/^PLUGINS=//p' "$CONF_FILE")"
    printf "  %-26s %s\n" "Service:" "$(systemctl is-active caddy 2>/dev/null || true)"
    echo ""
    echo "  1) Update Caddy binary (latest Caddy + plugins)"
    echo "  2) Reconfigure (token, plugins, auto update, deploy user)"
    echo "  3) Roll back to the previous binary"
    echo "  4) Exit"
    echo ""
    local choice
    while true; do
        choice=$(ask "Choice" "1")
        case "$choice" in
            1) mode_update ;;
            2) RECONFIGURE="y"; return 0 ;;
            3) mode_update --rollback ;;
            4) exit 0 ;;
        esac
        log_error "Choose 1-4"
    done
}

############################################################# MAIN
main() {
    case "${1:-}" in
        --update) shift; mode_update "$@" ;;
        -h|--help) sed -n '2,/^set -eEuo/{/^set/d;s/^# \{0,1\}//p}' "$0"; exit 0 ;;
        "") ;;
        *) log_error "Unknown option: $1 (use --help)"; exit 1 ;;
    esac

    check_root
    : > "$LOGFILE"

    if is_installed; then
        show_menu
        load_settings
    fi

    log_section "Caddy with Cloudflare DNS challenge"
    preflight
    gather_config
    [[ "$RECONFIGURE" == "y" ]] || install_caddy_package
    write_settings
    install_binary
    configure_auto_update
    configure_quic_buffers
    start_and_verify

    log_section "Done"
    printf "  %-26s %s\n" "Caddy:" "$(/usr/bin/caddy version | awk '{print $1}')"
    printf "  %-26s %s\n" "Caddyfile:" "$CADDYFILE"
    printf "  %-26s %s\n" "Token:" "$ENV_FILE"
    printf "  %-26s %s\n" "Log file:" "$LOGFILE"
    echo ""
    log_info "Deploy a Caddyfile:      caddy-apply /path/to/Caddyfile   (in place after git pull: caddy-apply)"
    log_info "Validate only:           caddy-apply --check /path/to/Caddyfile"
    log_info "Update Caddy + plugins:  caddy-update   (--check, --rollback, --force)"
    log_info "'apt upgrade' only updates /usr/bin/caddy.default — the running binary is updated by caddy-update"
}

main "$@"
