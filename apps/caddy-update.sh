#!/bin/bash
# caddy-update — update the custom Caddy build (Caddy + DNS plugins)
#
# Standalone: needs only bash, curl, dpkg and systemd — NOT this repository.
# caddy-install_cloudflare.sh installs it as /usr/local/sbin/caddy-update.
#
# How the install is laid out (Caddy docs: "Debian packages + custom binary"):
#   - the Debian 'caddy' package provides the service, user, /etc/caddy, ...
#   - its binary is diverted to /usr/bin/caddy.default (dpkg-divert)
#   - /usr/bin/caddy -> /etc/alternatives/caddy -> /usr/bin/caddy.custom
#   - /usr/bin/caddy.custom is a build from caddyserver.com with $PLUGINS
# 'apt upgrade' only updates caddy.default. This script updates caddy.custom:
# download -> verify plugins -> validate Caddyfile -> swap -> restart ->
# roll back automatically if caddy does not come up.
#
# Usage: caddy-update [options]
#   --check       compare installed and latest Caddy release, change nothing
#   --force       install the downloaded build even if it matches the current one
#   --rollback    swap back to the previous binary (caddy.custom.prev)
#   --no-restart  replace the binary, do not restart caddy
#   -q, --quiet   only warnings/errors (for the systemd timer)
#   -h, --help
#
# Settings: /etc/caddy/caddy-update.conf (PLUGINS="pkg/path pkg/path ...")
set -Eeuo pipefail
umask 022

readonly CONF_FILE=/etc/caddy/caddy-update.conf
readonly LINK=/usr/bin/caddy
readonly DEFAULT_BIN=/usr/bin/caddy.default
readonly CUSTOM_BIN=/usr/bin/caddy.custom
readonly PREV_BIN=/usr/bin/caddy.custom.prev
readonly NEW_BIN=/usr/bin/caddy.custom.new
readonly LOCK_FILE=/run/caddy-update.lock
readonly DOWNLOAD_API=https://caddyserver.com/api/download
readonly RELEASES_API=https://api.github.com/repos/caddyserver/caddy/releases/latest

# Defaults — overridden by $CONF_FILE
PLUGINS="github.com/caddy-dns/cloudflare"
CADDYFILE=/etc/caddy/Caddyfile
ENV_FILE=/etc/caddy/caddy.env
SERVICE=caddy

MODE=update
FORCE=n
RESTART=y
QUIET=n
TMP_DIR=""

############################################################# OUTPUT
if [[ -t 1 ]]; then
    C_RED='\033[0;31m' C_GREEN='\033[0;32m' C_YELLOW='\033[1;33m' C_BLUE='\033[0;94m' C_NC='\033[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_NC=''
fi
info() { [[ $QUIET == y ]] || echo -e "${C_BLUE}[→]${C_NC} $*"; }
ok()   { [[ $QUIET == y ]] || echo -e "${C_GREEN}[✓]${C_NC} $*"; }
warn() { echo -e "${C_YELLOW}[⚠]${C_NC} $*" >&2; }
die()  { echo -e "${C_RED}[✗]${C_NC} $*" >&2; exit 1; }

usage() { sed -n '/^# Usage:/,/^#   -h/s/^# \{0,1\}//p' "$0"; }

cleanup() {
    [[ -n $TMP_DIR ]] && rm -rf "$TMP_DIR"
    rm -f "$NEW_BIN"
}

############################################################# HELPERS
# conf_get FILE KEY — value of KEY=value (last one wins). Plain text parsing,
# nothing in the file is ever executed. Surrounding quotes are stripped.
conf_get() {
    local file="$1" key="$2" line value=""
    [[ -r $file ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == "$key="* ]] && value="${line#"$key="}"
    done < "$file"
    value="${value%$'\r'}"
    if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
    fi
    printf '%s' "$value"
}

# export_env_file FILE — export KEY=value lines (systemd EnvironmentFile style)
# into the current (sub)shell without executing anything
export_env_file() {
    local file="$1" line key
    [[ -r $file ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        key="${BASH_REMATCH[1]}"
        export "$key=$(conf_get "$file" "$key")"
    done < "$file"
}

load_conf() {
    local key value
    for key in PLUGINS CADDYFILE ENV_FILE SERVICE; do
        value=$(conf_get "$CONF_FILE" "$key")
        [[ -n $value ]] && printf -v "$key" '%s' "$value"
    done
    local p
    for p in $PLUGINS; do
        [[ $p =~ ^[A-Za-z0-9._~/@-]+$ ]] || die "Invalid plugin path in $CONF_FILE: '$p'"
    done
}

download_url() {
    local arch p url
    case "$(dpkg --print-architecture)" in
        amd64)   arch="arch=amd64" ;;
        arm64)   arch="arch=arm64" ;;
        armhf)   arch="arch=arm&arm=7" ;;
        armel)   arch="arch=arm&arm=6" ;;
        i386)    arch="arch=386" ;;
        ppc64el) arch="arch=ppc64le" ;;
        riscv64) arch="arch=riscv64" ;;
        s390x)   arch="arch=s390x" ;;
        *) die "Unsupported architecture: $(dpkg --print-architecture)" ;;
    esac
    url="$DOWNLOAD_API?os=linux&$arch"
    for p in $PLUGINS; do url+="&p=$p"; done
    echo "$url"
}

# Module/dependency versions of a binary — equal output == same build contents
build_fingerprint() {
    "$1" build-info 2>/dev/null | grep -E '^[[:space:]]*(go|path|mod|dep|=>)[[:space:]]' || true
}

core_version() {
    "$1" version 2>/dev/null | awk '{print $1}'
}

is_elf() {
    [[ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" == "7f454c46" ]]
}

# Every configured plugin package must be compiled in
check_plugins() {
    local bin="$1" p pkgs missing=()
    pkgs=$("$bin" list-modules --packages 2>/dev/null | awk '{print $2}' | sort -u)
    for p in $PLUGINS; do
        grep -qxF "${p%@*}" <<< "$pkgs" || missing+=("$p")
    done
    (( ${#missing[@]} == 0 )) || { warn "Build is missing plugin(s): ${missing[*]}"; return 1; }
}

# Validate the Caddyfile with the given binary, as the caddy user (so log files
# opened during validation are not created root-owned); env file loaded for
# {env.*} placeholders.
validate_config() {
    local bin="$1" out
    [[ -f $CADDYFILE ]] || { warn "$CADDYFILE not found — config validation skipped"; return 0; }
    if ! out=$(
        export_env_file "$ENV_FILE"
        cd /
        runuser -u caddy -- "$bin" validate --config "$CADDYFILE" --adapter caddyfile 2>&1
    ); then
        warn "New binary rejects $CADDYFILE:"
        tail -n 15 <<< "$out" | sed 's/^/    /' >&2
        return 1
    fi
}

# dpkg-divert the packaged binary + register alternatives (idempotent)
ensure_layout() {
    if ! dpkg-divert --list "$LINK" 2>/dev/null | grep -qF "$DEFAULT_BIN"; then
        info "Diverting packaged $LINK to $DEFAULT_BIN"
        dpkg-divert --local --divert "$DEFAULT_BIN" --rename "$LINK" >/dev/null
    fi
    if [[ -x $DEFAULT_BIN ]]; then
        update-alternatives --quiet --install "$LINK" caddy "$DEFAULT_BIN" 10
    fi
    update-alternatives --quiet --install "$LINK" caddy "$CUSTOM_BIN" 50
    update-alternatives --quiet --set caddy "$CUSTOM_BIN"
}

service_exists() {
    [[ -n "$(systemctl list-unit-files --no-legend "$SERVICE.service" 2>/dev/null)" ]]
}

# Restart and confirm the service stays up
restart_service() {
    service_exists || { warn "$SERVICE.service not found — not restarted"; return 0; }
    systemctl restart "$SERVICE" || return 1
    sleep 3
    systemctl is-active --quiet "$SERVICE"
}

show_journal() {
    journalctl -u "$SERVICE" -n 20 --no-pager 2>/dev/null | sed 's/^/    /' >&2 || true
}

############################################################# ACTIONS
do_check() {
    local current latest
    [[ -x $CUSTOM_BIN ]] || die "$CUSTOM_BIN not installed"
    current=$(core_version "$CUSTOM_BIN")
    latest=$(curl -fsSL --max-time 30 "$RELEASES_API" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1) \
        || die "Cannot query $RELEASES_API"
    [[ -n $latest ]] || die "Cannot parse latest release from $RELEASES_API"
    QUIET=n
    info "Installed: $current"
    info "Latest:    $latest"
    if [[ $current == "$latest" ]]; then
        ok "Caddy core is up to date (plugins may still have updates — run caddy-update)"
    else
        warn "Update available: $current -> $latest (run caddy-update)"
    fi
}

do_rollback() {
    [[ -x $PREV_BIN ]] || die "No previous binary ($PREV_BIN) to roll back to"
    info "Rolling back $(core_version "$CUSTOM_BIN") -> $(core_version "$PREV_BIN")"
    mv -f "$CUSTOM_BIN" "$NEW_BIN"
    mv -f "$PREV_BIN" "$CUSTOM_BIN"
    mv -f "$NEW_BIN" "$PREV_BIN"
    ensure_layout
    if [[ $RESTART == y ]]; then
        restart_service || { show_journal; die "$SERVICE failed to start after rollback"; }
    fi
    ok "Rolled back — now running $(core_version "$CUSTOM_BIN") (previous kept as $PREV_BIN)"
}

do_update() {
    local url tmp_bin old_ver new_ver first_install=n
    dpkg-query -W -f='${Status}' caddy 2>/dev/null | grep -q "install ok installed" \
        || die "Debian package 'caddy' is not installed (it provides the service and config)"
    [[ -x $CUSTOM_BIN ]] || first_install=y

    url=$(download_url)
    tmp_bin="$TMP_DIR/caddy"
    info "Downloading Caddy build with: ${PLUGINS:-no plugins}"
    # Builds are made on demand by caddyserver.com — can take a minute or two
    curl -fL --retry 3 --retry-delay 10 --connect-timeout 20 --max-time 900 \
        -sS -o "$tmp_bin" "$url" || die "Download failed: $url"
    is_elf "$tmp_bin" || die "Downloaded file is not a Linux binary (API error?)"
    chmod 0755 "$tmp_bin"

    new_ver=$(core_version "$tmp_bin")
    [[ $new_ver == v2.* ]] || die "Downloaded binary does not run (version: '${new_ver:-none}')"
    check_plugins "$tmp_bin" || die "Aborting — current binary left untouched"

    if [[ $first_install == n ]]; then
        old_ver=$(core_version "$CUSTOM_BIN")
        if [[ $FORCE != y && "$(build_fingerprint "$tmp_bin")" == "$(build_fingerprint "$CUSTOM_BIN")" ]]; then
            ensure_layout
            ok "Already up to date ($old_ver, same plugin versions)"
            return 0
        fi
    fi

    validate_config "$tmp_bin" || die "Aborting — current binary left untouched"

    # Same filesystem -> atomic rename; the running process keeps its old inode
    install -m 0755 "$tmp_bin" "$NEW_BIN"
    [[ $first_install == n ]] && cp -p "$CUSTOM_BIN" "$PREV_BIN"
    mv -f "$NEW_BIN" "$CUSTOM_BIN"
    ensure_layout

    if [[ $RESTART == y ]] && ! restart_service; then
        show_journal
        if [[ -x $PREV_BIN && $first_install == n ]]; then
            warn "$SERVICE failed with $new_ver — rolling back to $old_ver"
            mv -f "$PREV_BIN" "$CUSTOM_BIN"
            restart_service || { show_journal; die "$SERVICE does not start after rollback either"; }
            die "Update failed, rolled back to $old_ver"
        fi
        die "$SERVICE failed to start with $new_ver"
    fi

    if [[ $first_install == y ]]; then
        ok "Installed custom Caddy $new_ver"
    elif [[ $old_ver == "$new_ver" ]]; then
        ok "Updated plugins (Caddy $new_ver) — previous build kept as $PREV_BIN"
    else
        ok "Updated Caddy $old_ver -> $new_ver — previous kept as $PREV_BIN"
    fi
    [[ $RESTART == y ]] || warn "Not restarted — run: systemctl restart $SERVICE"
}

############################################################# MAIN
main() {
    while (( $# > 0 )); do
        case "$1" in
            --check)      MODE=check ;;
            --rollback)   MODE=rollback ;;
            --force)      FORCE=y ;;
            --no-restart) RESTART=n ;;
            -q|--quiet)   QUIET=y ;;
            -h|--help)    usage; exit 0 ;;
            *) usage >&2; die "Unknown option: $1" ;;
        esac
        shift
    done

    [[ $EUID -eq 0 ]] || die "Run as root"
    command -v curl &>/dev/null || die "curl is required (apt-get install curl)"
    load_conf

    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Another caddy-update is running"

    TMP_DIR=$(mktemp -d /var/tmp/caddy-update.XXXXXX)
    chmod 0755 "$TMP_DIR"
    trap cleanup EXIT

    case "$MODE" in
        check)    do_check ;;
        rollback) do_rollback ;;
        update)   do_update ;;
    esac
}

main "$@"
