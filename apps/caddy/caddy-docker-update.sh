#!/bin/bash
# update.sh — rebuild the Caddy image of the Docker stack (latest Caddy + plugins)
#
# Standalone: needs only bash and docker compose — NOT this repository.
# docker-setup_caddy.sh copies it into the stack directory as update.sh.
#
# Rebuild without cache (xcaddy fetches the newest plugin versions) -> verify
# plugins -> validate conf/Caddyfile with the new image -> recreate container ->
# roll back to the previous image automatically if it does not become healthy.
# The previous image is kept as <image>:previous.
#
# Usage: update.sh [options]
#   --check       compare running and latest Caddy release, change nothing
#   --force       recreate the container even if the new build is identical
#   --rollback    swap back to <image>:previous
#   -q, --quiet   only warnings/errors (for cron)
#   -h, --help
set -Eeuo pipefail

STACK_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly STACK_DIR
readonly ENV_FILE="$STACK_DIR/.env"
readonly LOCK_FILE="$STACK_DIR/.update.lock"
readonly SERVICE=caddy
readonly RELEASES_API=https://api.github.com/repos/caddyserver/caddy/releases/latest

MODE=update
FORCE=n
QUIET=n
IMAGE=""
PLUGINS=""

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

############################################################# HELPERS
# stdin from /dev/null: never swallow the caller's input (ssh 'apply.sh f; next cmd')
dc() { docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/compose.yaml" "$@" </dev/null; }

# conf_get FILE KEY — value of KEY=value, parsed as text (never sourced)
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

image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }

# caddy CMD... in a throwaway container of an image (no stack config needed)
in_image() { docker run --rm --entrypoint caddy "$1" "${@:2}" </dev/null; }

build_fingerprint() {
    in_image "$1" build-info 2>/dev/null | grep -E '^[[:space:]]*(go|path|mod|dep|=>)[[:space:]]' || true
}

core_version() { in_image "$1" version 2>/dev/null | awk '{print $1}'; }

check_plugins() {
    local img="$1" p pkgs missing=()
    pkgs=$(in_image "$img" list-modules --packages 2>/dev/null | awk '{print $2}' | sort -u)
    for p in $PLUGINS; do
        grep -qxF "${p%@*}" <<< "$pkgs" || missing+=("$p")
    done
    (( ${#missing[@]} == 0 )) || { warn "Build is missing plugin(s): ${missing[*]}"; return 1; }
}

# conf/Caddyfile with the image now tagged :latest (throwaway container, stack env)
validate_config() {
    local out
    if ! out=$(dc run --rm --no-deps -T "$SERVICE" caddy validate \
            --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1); then
        warn "New image rejects conf/Caddyfile:"
        grep -E '"level":"error"|^Error' <<< "$out" | tail -n 10 | sed 's/^/    /' >&2 \
            || tail -n 10 <<< "$out" | sed 's/^/    /' >&2
        return 1
    fi
}

# Recreate the container and wait until the healthcheck passes
recreate_and_wait() {
    local cid status i
    dc up -d --force-recreate "$SERVICE" >/dev/null 2>&1 || return 1
    cid=$(dc ps -q "$SERVICE")
    [[ -n $cid ]] || return 1
    for (( i = 0; i < 30; i++ )); do
        status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo gone)
        case "$status" in
            healthy|running) [[ $status == healthy || $i -ge 5 ]] && return 0 ;;
            unhealthy|exited|dead|gone) return 1 ;;
        esac
        sleep 2
    done
    return 1
}

show_logs() {
    dc logs --no-color --tail 15 "$SERVICE" 2>/dev/null | sed 's/^/    /' >&2 || true
}

# Remove an image id if no tag points to it anymore
drop_if_untagged() {
    local id="$1"
    [[ -n $id ]] || return 0
    if [[ -z "$(docker image inspect -f '{{join .RepoTags ""}}' "$id" 2>/dev/null)" ]]; then
        docker image rm "$id" >/dev/null 2>&1 || true
    fi
}

############################################################# ACTIONS
do_check() {
    local current latest
    current=$(core_version "$IMAGE:latest")
    [[ -n $current ]] || die "Image $IMAGE:latest not found — run docker-setup_caddy.sh"
    latest=$(curl -fsSL --max-time 30 "$RELEASES_API" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1) \
        || die "Cannot query $RELEASES_API"
    [[ -n $latest ]] || die "Cannot parse latest release from $RELEASES_API"
    QUIET=n
    info "Installed: $current"
    info "Latest:    $latest"
    if [[ $current == "$latest" ]]; then
        ok "Caddy core is up to date (plugins may still have updates — run update.sh)"
    else
        warn "Update available: $current -> $latest (run update.sh)"
    fi
}

do_rollback() {
    local cur prev
    cur=$(image_id "$IMAGE:latest")
    prev=$(image_id "$IMAGE:previous")
    [[ -n $prev ]] || die "No $IMAGE:previous image to roll back to"
    info "Rolling back $(core_version "$IMAGE:latest") -> $(core_version "$IMAGE:previous")"
    docker tag "$prev" "$IMAGE:latest"
    [[ -n $cur ]] && docker tag "$cur" "$IMAGE:previous"
    recreate_and_wait || { show_logs; die "$SERVICE is not healthy after rollback"; }
    ok "Rolled back — running $(core_version "$IMAGE:latest") (other build kept as $IMAGE:previous)"
}

do_update() {
    local old_id old_prev_id new_id old_ver="" new_ver
    old_id=$(image_id "$IMAGE:latest")
    old_prev_id=$(image_id "$IMAGE:previous")
    [[ -n $old_id ]] && old_ver=$(core_version "$IMAGE:latest")

    info "Building Caddy with: $PLUGINS (no cache, pulls base images — takes a few minutes)"
    [[ -n $old_id ]] && docker tag "$old_id" "$IMAGE:previous"
    local build_log
    build_log=$(mktemp)
    if ! dc build --pull --no-cache "$SERVICE" >"$build_log" 2>&1; then
        tail -n 20 "$build_log" | sed 's/^/    /' >&2
        rm -f "$build_log"
        [[ -n $old_id ]] && docker tag "$old_id" "$IMAGE:latest"
        die "Build failed — running container untouched"
    fi
    rm -f "$build_log"
    new_id=$(image_id "$IMAGE:latest")
    new_ver=$(core_version "$IMAGE:latest")

    restore_old() {
        if [[ -n $old_id ]]; then
            docker tag "$old_id" "$IMAGE:latest"
            if [[ -n $old_prev_id ]]; then docker tag "$old_prev_id" "$IMAGE:previous"
            else docker image rm "$IMAGE:previous" >/dev/null 2>&1 || true; fi
        fi
        drop_if_untagged "$new_id"
    }

    check_plugins "$IMAGE:latest" || { restore_old; die "Aborting — running container untouched"; }

    if [[ -n $old_id && $FORCE != y \
          && "$(build_fingerprint "$IMAGE:latest")" == "$(build_fingerprint "$old_id")" ]]; then
        restore_old
        ok "Already up to date ($old_ver, same plugin versions)"
        return 0
    fi

    validate_config || { restore_old; die "Aborting — running container untouched"; }

    if ! recreate_and_wait; then
        show_logs
        if [[ -n $old_id ]]; then
            warn "$SERVICE is not healthy with $new_ver — rolling back to $old_ver"
            restore_old
            recreate_and_wait || { show_logs; die "$SERVICE is not healthy after rollback either"; }
            die "Update failed, rolled back to $old_ver"
        fi
        die "$SERVICE is not healthy with $new_ver"
    fi
    drop_if_untagged "$old_prev_id"

    if [[ -z $old_id ]]; then
        ok "Built and started Caddy $new_ver"
    elif [[ $old_ver == "$new_ver" ]]; then
        ok "Updated plugins (Caddy $new_ver) — previous image kept as $IMAGE:previous"
    else
        ok "Updated Caddy $old_ver -> $new_ver — previous image kept as $IMAGE:previous"
    fi
}

############################################################# MAIN
main() {
    while (( $# > 0 )); do
        case "$1" in
            --check)    MODE=check ;;
            --rollback) MODE=rollback ;;
            --force)    FORCE=y ;;
            -q|--quiet) QUIET=y ;;
            -h|--help)  usage; exit 0 ;;
            *) usage >&2; die "Unknown option: $1" ;;
        esac
        shift
    done

    docker info &>/dev/null || die "Cannot talk to Docker (run as root or a docker group member)"
    [[ -f $STACK_DIR/compose.yaml ]] || die "$STACK_DIR/compose.yaml not found"
    IMAGE=$(conf_get "$ENV_FILE" CADDY_IMAGE)
    PLUGINS=$(conf_get "$ENV_FILE" CADDY_PLUGINS)
    [[ $IMAGE =~ ^[a-z0-9._/-]+$ ]] || die "Invalid or missing CADDY_IMAGE in $ENV_FILE"

    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Another update.sh is running"

    case "$MODE" in
        check)    do_check ;;
        rollback) do_rollback ;;
        update)   do_update ;;
    esac
}

main "$@"
