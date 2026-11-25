#!/bin/bash
# apply.sh — validate and activate a Caddyfile in the Caddy Docker stack
#
# Standalone: needs only bash and docker compose — NOT this repository.
# docker-setup_caddy.sh copies it into the stack directory as apply.sh.
# Run as root or as a member of the docker group (e.g. the Jenkins deploy user).
#
# Usage:
#   apply.sh FILE           validate FILE, install it as conf/Caddyfile, reload caddy
#   apply.sh                validate conf/Caddyfile in place (after git pull), reload
#   apply.sh --check [FILE] validate only, change nothing
#   -q, --quiet             only warnings/errors
#   -h, --help
#
# Validation runs inside the caddy image with the real CF_API_TOKEN (caddy.env).
# 'caddy reload' is atomic: if the new config fails to load, the old one keeps
# running and the previous file is put back.
#
# Exit codes: 0 ok / unchanged, 1 error, 2 validation failed (nothing changed)
set -Eeuo pipefail
umask 002

STACK_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly STACK_DIR
readonly CONF_DIR="$STACK_DIR/conf"
readonly CADDYFILE="$CONF_DIR/Caddyfile"
readonly PREV_FILE="$CONF_DIR/Caddyfile.prev"
readonly CANDIDATE="$CONF_DIR/.Caddyfile.candidate"
readonly LOCK_FILE="$STACK_DIR/.apply.lock"
readonly SERVICE=caddy
readonly IN_CONTAINER=/etc/caddy

MODE=apply
SRC=""
QUIET=n

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

cleanup() { rm -f "$CANDIDATE"; }

############################################################# HELPERS
# stdin from /dev/null: never swallow the caller's input (ssh 'apply.sh f; next cmd')
dc() { docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/compose.yaml" "$@" </dev/null; }

is_running() {
    [[ -n "$(dc ps -q --status running "$SERVICE" 2>/dev/null)" ]]
}

# caddy CMD... inside the running container, or a throwaway one (no ports published)
caddy_cmd() {
    if is_running; then
        dc exec -T "$SERVICE" caddy "$@"
    else
        dc run --rm --no-deps -T "$SERVICE" caddy "$@"
    fi
}

# validate FILE — staged as conf/.Caddyfile.candidate, visible in the container
validate() {
    local file="$1" out
    if [[ $file != "$CADDYFILE" ]]; then
        cp "$file" "$CANDIDATE"
        chmod 0664 "$CANDIDATE"
    fi
    local name
    name=$([[ $file == "$CADDYFILE" ]] && echo Caddyfile || echo .Caddyfile.candidate)
    if ! out=$(caddy_cmd validate --config "$IN_CONTAINER/$name" --adapter caddyfile 2>&1); then
        warn "Validation failed for $file:"
        out=${out//$IN_CONTAINER\/$name/$file}
        grep -E '"level":"error"|^Error' <<< "$out" | tail -n 10 | sed 's/^/    /' >&2 \
            || tail -n 10 <<< "$out" | sed 's/^/    /' >&2
        return 1
    fi
}

# Load conf/Caddyfile into the running server, or start the stack
activate() {
    local out
    if is_running; then
        if ! out=$(dc exec -T "$SERVICE" caddy reload --config "$IN_CONTAINER/Caddyfile" --adapter caddyfile 2>&1); then
            grep -E '"level":"error"|^Error' <<< "$out" | tail -n 5 | sed 's/^/    /' >&2 || true
            return 1
        fi
    else
        warn "$SERVICE was not running — starting the stack"
        dc up -d
    fi
}

show_logs() {
    dc logs --no-color --tail 15 "$SERVICE" 2>/dev/null | sed 's/^/    /' >&2 || true
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

    docker info &>/dev/null || die "Cannot talk to Docker (run as root or a docker group member)"
    [[ -f $STACK_DIR/compose.yaml ]] || die "$STACK_DIR/compose.yaml not found"

    if [[ -n $SRC ]]; then
        [[ -f $SRC && -r $SRC ]] || die "Cannot read $SRC"
        SRC=$(readlink -f "$SRC")
    fi
    local target="${SRC:-$CADDYFILE}"
    [[ -f $target ]] || die "$target not found"

    exec 9>"$LOCK_FILE"
    flock -w 60 9 || die "Another apply.sh is still running"
    trap cleanup EXIT

    validate "$target" || die "Nothing changed" 2
    ok "Configuration is valid: $target"
    [[ $MODE == check ]] && exit 0

    # In place (git pull into conf/): nothing to install, just reload
    if [[ -z $SRC || $SRC == "$CADDYFILE" ]]; then
        activate || { show_logs; die "Reload failed — caddy keeps running the previous config"; }
        ok "Reloaded $SERVICE with $CADDYFILE"
        exit 0
    fi

    if [[ -f $CADDYFILE ]] && cmp -s "$SRC" "$CADDYFILE"; then
        ok "Unchanged — nothing to do"
        exit 0
    fi

    # Same directory -> atomic rename; conf/ is mounted as a directory, so the
    # container sees the new file (a single-file bind mount would keep the old inode)
    [[ -f $CADDYFILE ]] && cp -p "$CADDYFILE" "$PREV_FILE"
    mv -f "$CANDIDATE" "$CADDYFILE"

    if ! activate; then
        show_logs
        if [[ -f $PREV_FILE ]]; then
            cp -p "$PREV_FILE" "$CADDYFILE"
            warn "Restored previous $CADDYFILE"
        fi
        die "Reload failed — caddy keeps running the previous config"
    fi
    ok "Applied $SRC -> $CADDYFILE (previous kept as $PREV_FILE)"
}

main "$@"
