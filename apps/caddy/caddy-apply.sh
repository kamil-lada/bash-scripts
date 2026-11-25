#!/bin/bash
# caddy-apply — validate and activate a Caddyfile (for Jenkins / git pull / scp deploys)
#
# Standalone: needs only bash and systemd — NOT this repository.
# caddy-install_cloudflare.sh installs it as /usr/local/sbin/caddy-apply.
#
# Usage:
#   caddy-apply FILE           validate FILE, install it as /etc/caddy/Caddyfile, reload caddy
#   caddy-apply                validate /etc/caddy/Caddyfile in place (after git pull), reload
#   caddy-apply --check [FILE] validate only, change nothing
#   -q, --quiet                only warnings/errors
#   -h, --help
#
# Validation runs as the caddy user with the real CF_API_TOKEN from /etc/caddy/caddy.env,
# so permission problems and a missing DNS plugin are caught before activation.
# 'systemctl reload' is atomic in Caddy: if the new config fails to load, the old one
# keeps running and the previous file is put back.
#
# Exit codes: 0 ok / unchanged, 1 error, 2 validation failed (nothing changed)
set -Eeuo pipefail
umask 022

readonly CADDYFILE=/etc/caddy/Caddyfile
readonly PREV_FILE=/etc/caddy/Caddyfile.prev
readonly ENV_FILE=/etc/caddy/caddy.env
readonly CADDY_BIN=/usr/bin/caddy
readonly CADDY_USER=caddy
readonly SERVICE=caddy
readonly LOCK_FILE=/run/caddy-apply.lock

MODE=apply
SRC=""
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
die()  { echo -e "${C_RED}[✗]${C_NC} $1" >&2; exit "${2:-1}"; }

usage() { sed -n '/^# Usage:/,/^#   -h/s/^# \{0,1\}//p' "$0"; }

cleanup() { [[ -n $TMP_DIR ]] && rm -rf "$TMP_DIR"; }

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

# validate FILE — copy to a private dir readable by caddy, validate as the caddy user
validate() {
    local file="$1" copy out
    copy="$TMP_DIR/Caddyfile"
    install -m 0644 "$file" "$copy"
    if ! out=$(
        export_env_file "$ENV_FILE"
        cd /
        runuser -u "$CADDY_USER" -- "$CADDY_BIN" validate --config "$copy" --adapter caddyfile 2>&1
    ); then
        warn "Validation failed for $file:"
        out=${out//$copy/$file}
        grep -E '"level":"error"|^Error' <<< "$out" | tail -n 10 | sed 's/^/    /' >&2 \
            || tail -n 10 <<< "$out" | sed 's/^/    /' >&2
        return 1
    fi
    if grep -q 'not formatted' <<< "$out"; then
        info "Hint: file is not 'caddy fmt' formatted (harmless)"
    fi
}

# Load the on-disk Caddyfile into the running server
activate() {
    if systemctl is-active --quiet "$SERVICE"; then
        systemctl reload "$SERVICE"
    else
        warn "$SERVICE was not running — starting it"
        systemctl start "$SERVICE"
    fi
}

show_journal() {
    journalctl -u "$SERVICE" -n 15 --no-pager -o cat 2>/dev/null | sed 's/^/    /' >&2 || true
}

############################################################# MAIN
main() {
    while (( $# > 0 )); do
        case "$1" in
            --check)    MODE=check ;;
            -q|--quiet) QUIET=y ;;
            -h|--help)  usage; exit 0 ;;
            -*) usage >&2; die "Unknown option: $1" ;;
            *)  [[ -z $SRC ]] || die "Only one file can be given"
                SRC="$1" ;;
        esac
        shift
    done

    [[ $EUID -eq 0 ]] || die "Run as root (sudo caddy-apply ...)"
    [[ -x $CADDY_BIN ]] || die "$CADDY_BIN not found"
    id "$CADDY_USER" &>/dev/null || die "User $CADDY_USER does not exist (caddy package not installed?)"

    if [[ -n $SRC ]]; then
        [[ -f $SRC && -r $SRC ]] || die "Cannot read $SRC"
        SRC=$(readlink -f "$SRC")
    fi
    local target="${SRC:-$CADDYFILE}"
    [[ -f $target ]] || die "$target not found"

    exec 9>"$LOCK_FILE"
    flock -w 60 9 || die "Another caddy-apply is still running"

    TMP_DIR=$(mktemp -d /run/caddy-apply.XXXXXX)
    chmod 0755 "$TMP_DIR"
    trap cleanup EXIT

    validate "$target" || die "Nothing changed" 2
    ok "Configuration is valid: $target"
    [[ $MODE == check ]] && exit 0

    # In place (git pull into /etc/caddy): nothing to install, just reload
    if [[ -z $SRC || $SRC == "$CADDYFILE" ]]; then
        if ! activate; then
            show_journal
            die "Reload failed — caddy keeps running the previous config"
        fi
        ok "Reloaded $SERVICE with $CADDYFILE"
        exit 0
    fi

    if [[ -f $CADDYFILE ]] && cmp -s "$SRC" "$CADDYFILE"; then
        ok "Unchanged — nothing to do"
        exit 0
    fi

    [[ -f $CADDYFILE ]] && cp -p "$CADDYFILE" "$PREV_FILE"
    install -m 0644 -o root -g root "$SRC" "$CADDYFILE.new"
    mv -f "$CADDYFILE.new" "$CADDYFILE"

    if ! activate; then
        show_journal
        if [[ -f $PREV_FILE ]]; then
            cp -p "$PREV_FILE" "$CADDYFILE"
            warn "Restored previous $CADDYFILE"
        fi
        die "Reload failed — caddy keeps running the previous config"
    fi
    ok "Applied $SRC -> $CADDYFILE (previous kept as $PREV_FILE)"
}

main "$@"
