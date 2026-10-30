#!/bin/bash
# Docker complete removal — reverts docker-install_fresh.sh with no leftovers
#
# Reads /etc/docker-install.state (written by the installer) to know custom data
# locations, stacks dir, users and pre-install state. Without it, falls back to
# detecting locations from daemon.json / containerd config.toml.
set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

LOGFILE="/var/log/docker-remove.log"
STATE_FILE="/etc/docker-install.state"
: > "$LOGFILE"

trap 'echo -e "${RED}Script failed. Check $LOGFILE for details${NC}" >&2' ERR

readonly DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                          docker-ce-rootless-extras docker-model-plugin docker-scan-plugin)
readonly DEFAULT_DOCKER_ROOT="/var/lib/docker"
readonly DEFAULT_CONTAINERD_ROOT="/var/lib/containerd"

# Defaults, overridden by state file
USE_CUSTOM_LOCATION="n"
DATA_BASE=""
DOCKER_ROOT=""
CONTAINERD_ROOT=""
STACKS_DIR=""
IP_FORWARD_BEFORE="unknown"
GROUP_DOCKER_EXISTED="n"
PREREQS_INSTALLED=""
USERS_ADDED=""
HAS_STATE="n"
REMOVE_STACKS="n"
declare -a FSTAB_ENTRIES=()
declare -a EXTRA_DATA_DIRS=()

############################################################# HELPERS
step() { run_cmd_continue "$@" || true; }

is_pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

docker_running() {
    command -v docker &>/dev/null && docker info &>/dev/null
}

# Paths that must never be deleted, even if a broken config points there
is_protected_path() {
    local p
    p=$(readlink -m "$1")
    case "$p" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/var/lib|/data|/mnt|/media)
            return 0 ;;
    esac
    return 1
}

safe_rm() {
    local p="$1"
    [[ -z "$p" ]] && return 0
    if is_protected_path "$p"; then
        log_warning "Refusing to delete protected path: $p"
        return 0
    fi
    if [[ -L "$p" ]]; then
        rm -f "$p"
    elif [[ -e "$p" ]]; then
        rm -rf --one-file-system "$p"
    fi
}

dir_size() {
    [[ -d "$1" ]] && du -sh "$1" 2>/dev/null | cut -f1 || echo "-"
}

############################################################# DETECTION
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        HAS_STATE="y"
        log_success "Install state loaded from $STATE_FILE"
    else
        log_warning "No install state ($STATE_FILE) — detecting locations from config"
    fi

    if [[ -z "$DOCKER_ROOT" && -f /etc/docker/daemon.json ]]; then
        DOCKER_ROOT=$(sed -n 's/.*"data-root"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /etc/docker/daemon.json | head -1)
    fi
    if [[ -z "$CONTAINERD_ROOT" && -f /etc/containerd/config.toml ]]; then
        CONTAINERD_ROOT=$(sed -n "s/^[[:space:]]*root[[:space:]]*=[[:space:]]*[\"']\([^\"']*\)[\"'].*/\1/p" /etc/containerd/config.toml | head -1)
    fi
    DOCKER_ROOT="${DOCKER_ROOT:-$DEFAULT_DOCKER_ROOT}"
    CONTAINERD_ROOT="${CONTAINERD_ROOT:-$DEFAULT_CONTAINERD_ROOT}"

    # Legacy setups (older script / manual): /var/lib/docker or /var/lib/containerd
    # as symlink or bind mount to the data disk — resolve the real location
    local link
    for link in "$DEFAULT_DOCKER_ROOT" "$DEFAULT_CONTAINERD_ROOT"; do
        if [[ -L "$link" ]]; then
            log_info "$link is a symlink -> $(readlink -f "$link")"
            EXTRA_DATA_DIRS+=("$(readlink -f "$link")")
        fi
    done

    # fstab mounts onto docker/containerd dirs; for bind mounts the source holds the real data
    local line src opts
    while IFS= read -r line; do
        FSTAB_ENTRIES+=("$line")
        src=$(awk '{print $1}' <<< "$line")
        opts=$(awk '{print $4}' <<< "$line")
        if [[ ",$opts," == *",bind,"* || ",$opts," == *",rbind,"* ]]; then
            EXTRA_DATA_DIRS+=("$src")
        else
            log_warning "fstab mounts device $src for Docker data — its contents will be deleted before unmount"
        fi
    done < <(awk '!/^[[:space:]]*#/ && ($2 ~ "^/var/lib/(docker|containerd)" || $2 == "'"$DOCKER_ROOT"'" || $2 == "'"$CONTAINERD_ROOT"'") {print}' /etc/fstab 2>/dev/null)
}

show_summary() {
    log_section "Docker Removal Summary"

    local containers="-" images="-" volumes="-"
    if docker_running; then
        containers=$(docker ps -aq 2>/dev/null | wc -l)
        images=$(docker image ls -aq 2>/dev/null | sort -u | wc -l)
        volumes=$(docker volume ls -q 2>/dev/null | wc -l)
    fi

    printf "  %-26s %s\n" "Containers / images / vols:" "$containers / $images / $volumes"
    printf "  %-26s %s (%s)\n" "Docker data-root:" "$DOCKER_ROOT" "$(dir_size "$DOCKER_ROOT")"
    printf "  %-26s %s (%s)\n" "containerd root:" "$CONTAINERD_ROOT" "$(dir_size "$CONTAINERD_ROOT")"
    [[ "$DOCKER_ROOT" != "$DEFAULT_DOCKER_ROOT" && -e "$DEFAULT_DOCKER_ROOT" ]] && \
        printf "  %-26s %s (%s)\n" "Default docker dir:" "$DEFAULT_DOCKER_ROOT" "$(dir_size "$DEFAULT_DOCKER_ROOT")"
    [[ "$CONTAINERD_ROOT" != "$DEFAULT_CONTAINERD_ROOT" && -e "$DEFAULT_CONTAINERD_ROOT" ]] && \
        printf "  %-26s %s (%s)\n" "Default containerd dir:" "$DEFAULT_CONTAINERD_ROOT" "$(dir_size "$DEFAULT_CONTAINERD_ROOT")"
    printf "  %-26s %s\n" "Compose stacks:" "${STACKS_DIR:-none}$( [[ -n "$STACKS_DIR" ]] && echo " ($(dir_size "$STACKS_DIR"))")"
    printf "  %-26s %s\n" "Installed packages:" "$(for p in "${DOCKER_PACKAGES[@]}"; do is_pkg_installed "$p" && printf '%s ' "$p"; done)"
    printf "  %-26s %s\n" "Prereqs to remove:" "${PREREQS_INSTALLED:-none}"
    printf "  %-26s %s\n" "Users in docker group:" "$(getent group docker | cut -d: -f4 || true)"
    local d
    for d in "${EXTRA_DATA_DIRS[@]}"; do
        printf "  %-26s %s (%s)\n" "Legacy data location:" "$d" "$(dir_size "$d")"
    done
    if (( ${#FSTAB_ENTRIES[@]} > 0 )); then
        printf "  %-26s\n" "fstab entries to remove:"
        printf "    %s\n" "${FSTAB_ENTRIES[@]}"
    fi
    echo ""
    echo "  Will also remove: /etc/docker, /etc/containerd, apt repo + key, systemd drop-ins,"
    echo "  docker group, ~/.docker of users, docker bridges and firewall rules, install state."
    echo ""
}

ask_confirmation() {
    confirm_typed "ALL containers, images, volumes and Docker data will be PERMANENTLY deleted." "REMOVE" \
        || { log_info "Aborted."; exit 0; }

    if [[ -n "$STACKS_DIR" && -d "$STACKS_DIR" ]]; then
        if [[ -n "$(ls -A "$STACKS_DIR" 2>/dev/null)" ]]; then
            log_warning "$STACKS_DIR contains compose files and possibly bind-mounted app data"
            ls -A "$STACKS_DIR" | head -20 | sed 's/^/    /'
        fi
        if confirm "Also delete compose stacks directory $STACKS_DIR?" n; then
            if [[ -z "$(ls -A "$STACKS_DIR" 2>/dev/null)" ]] \
                || confirm_typed "Delete $STACKS_DIR with all its contents?" "DELETE"; then
                REMOVE_STACKS="y"
            fi
        fi
    fi
}

############################################################# REMOVAL STEPS
stop_workloads() {
    log_section "Stopping workloads"
    if docker_running; then
        step "Stopping all containers" bash -c 'docker ps -q | xargs -r docker stop -t 30'
        step "Removing all containers" bash -c 'docker ps -aq | xargs -r docker rm -f -v'
        # Lets the daemon delete its own bridges and firewall rules cleanly
        step "Removing custom networks" docker network prune -f
    else
        log_info "Docker daemon not running — skipping graceful cleanup"
    fi

    step "Stopping docker and containerd" \
        systemctl stop docker.socket docker.service containerd.service
    step "Disabling docker and containerd" \
        systemctl disable docker.socket docker.service containerd.service
    step "Killing leftover containerd shims" bash -c "pkill -f '[c]ontainerd-shim' || true"
}

unmount_leftovers() {
    log_section "Unmounting leftovers"
    local -a mounts=()
    local m root
    # overlay / shm / netns mounts below data roots and runtime dirs (deepest first)
    while IFS= read -r m; do
        for root in "$DOCKER_ROOT" "$CONTAINERD_ROOT" "$DEFAULT_DOCKER_ROOT" "$DEFAULT_CONTAINERD_ROOT" \
                    /run/docker /run/containerd /run/docker/netns; do
            if [[ "$m" == "$root/"* ]]; then
                mounts+=("$m")
                break
            fi
        done
    done < <(findmnt -rn -o TARGET | sort -r)

    for m in "${mounts[@]}"; do
        step "Unmounting $m" umount -l "$m"
    done

    # Legacy mounts of the data dirs themselves (bind or whole device):
    # wipe contents first (bind source is also removed later), then unmount
    for m in "$DEFAULT_DOCKER_ROOT" "$DEFAULT_CONTAINERD_ROOT"; do
        if mountpoint -q "$m" 2>/dev/null; then
            step "Wiping contents of mounted $m" find "$m" -mindepth 1 -xdev -delete
            step "Unmounting $m" umount -l "$m"
        fi
    done

    if (( ${#FSTAB_ENTRIES[@]} > 0 )); then
        local backup="/etc/fstab.bak.$(date +%s)"
        step "Backing up /etc/fstab to $backup" cp /etc/fstab "$backup"
        local entry
        for entry in "${FSTAB_ENTRIES[@]}"; do
            step "Removing fstab entry: $entry" \
                bash -c 'grep -vxF -- "$1" /etc/fstab > /etc/fstab.tmp && mv /etc/fstab.tmp /etc/fstab' _ "$entry"
        done
        step "Reloading systemd (fstab)" systemctl daemon-reload
    fi
    (( ${#mounts[@]} == 0 && ${#FSTAB_ENTRIES[@]} == 0 )) && log_info "Nothing to unmount" || true
}

cleanup_network() {
    log_section "Cleaning network leftovers"

    # Must run before package purge — iptables may be autoremoved with docker-ce
    local tool
    for tool in iptables ip6tables; do
        if command -v "${tool}-save" &>/dev/null && "${tool}-save" 2>/dev/null | grep -q DOCKER; then
            step "Removing Docker $tool chains and rules" bash -c "
            ${tool}-save | grep -Ev 'DOCKER|docker0|br-[0-9a-f]{12}' | ${tool}-restore
            "
        fi
    done

    # nftables firewall backend (experimental in Engine 29)
    if command -v nft &>/dev/null; then
        local table
        while read -r _ family table; do
            [[ "$table" == docker* ]] && step "Removing nft table $family $table" nft delete table "$family" "$table"
        done < <(nft list tables 2>/dev/null || true)
    fi

    local iface
    while read -r iface; do
        [[ -z "$iface" ]] && continue
        step "Deleting interface $iface" ip link delete "$iface"
    done < <(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 \
             | grep -E '^(docker0|docker_gwbridge|br-[0-9a-f]{12})$' || true)

    if [[ "$IP_FORWARD_BEFORE" == "0" && "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]]; then
        step "Restoring net.ipv4.ip_forward=0 (pre-install value)" sysctl -w net.ipv4.ip_forward=0
    fi
}

purge_packages() {
    log_section "Removing packages"
    local -a installed=()
    local pkg
    for pkg in "${DOCKER_PACKAGES[@]}"; do
        is_pkg_installed "$pkg" && installed+=("$pkg")
        # also catch packages left in 'rc' (config-files) state
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "config-files" && installed+=("$pkg")
    done

    if (( ${#installed[@]} > 0 )); then
        step "Purging ${installed[*]}" \
            env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${installed[@]}"
    fi

    # Prereqs the installer added: mark auto so autoremove drops them unless
    # something installed since then depends on them (purging could cascade)
    if [[ -n "$PREREQS_INSTALLED" ]]; then
        local -a prereqs
        read -ra prereqs <<< "$PREREQS_INSTALLED"
        step "Marking installer prerequisites as auto (${prereqs[*]})" apt-mark auto "${prereqs[@]}"
    fi

    step "Removing unused dependencies" \
        env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y

    step "Removing Docker apt repository and key" rm -f \
        /etc/apt/sources.list.d/docker.sources \
        /etc/apt/sources.list.d/docker.list \
        /etc/apt/keyrings/docker.asc \
        /etc/apt/keyrings/docker.gpg \
        /usr/share/keyrings/docker-archive-keyring.gpg
    step "Updating package lists" apt-get update
    step "Cleaning apt cache" apt-get clean
}

remove_files() {
    log_section "Removing data and configuration"

    local p
    for p in "$DOCKER_ROOT" "$CONTAINERD_ROOT" "${EXTRA_DATA_DIRS[@]}"; do
        [[ -e "$p" || -L "$p" ]] && step "Removing $p" safe_rm "$p"
    done
    # Default dirs, legacy symlinks and old-script backup
    for p in "$DEFAULT_DOCKER_ROOT" "$DEFAULT_CONTAINERD_ROOT" "${DEFAULT_DOCKER_ROOT}.old"; do
        [[ -e "$p" || -L "$p" ]] && step "Removing $p" safe_rm "$p"
    done

    step "Removing configuration" bash -c '
    rm -rf /etc/docker /etc/containerd \
           /etc/systemd/system/docker.service.d /etc/systemd/system/containerd.service.d \
           /etc/systemd/system/docker.service /etc/systemd/system/docker.socket \
           /etc/systemd/system/containerd.service \
           /etc/default/docker /etc/init.d/docker
    '
    step "Removing runtime and plugin leftovers" bash -c '
    rm -rf /run/docker /run/containerd /run/docker.sock /var/run/docker.sock /var/run/docker.pid \
           /opt/containerd /usr/local/bin/docker-compose /usr/local/lib/docker /usr/libexec/docker
    '

    # Per-user CLI config (~/.docker): root, sudo user, users added by installer, docker group members
    local -a users=(root)
    [[ -n "${SUDO_USER:-}" ]] && users+=("$SUDO_USER")
    local u
    for u in $USERS_ADDED $(getent group docker | cut -d: -f4 | tr ',' ' '); do
        users+=("$u")
    done
    local home
    for u in $(printf '%s\n' "${users[@]}" | sort -u); do
        home=$(getent passwd "$u" | cut -d: -f6)
        [[ -n "$home" && -d "$home/.docker" ]] && step "Removing $home/.docker" rm -rf "$home/.docker"
    done

    if [[ "$REMOVE_STACKS" == "y" ]]; then
        step "Removing stacks directory $STACKS_DIR" safe_rm "$STACKS_DIR"
    fi

    # Directories the installer created (deepest first) — only if empty and not a mountpoint
    if [[ -f "${STATE_FILE}.dirs" ]]; then
        local d
        while IFS= read -r d; do
            [[ -z "$d" || ! -d "$d" ]] && continue
            if mountpoint -q "$d"; then
                log_info "Keeping $d (mountpoint)"
            elif [[ -z "$(ls -A "$d" 2>/dev/null)" ]]; then
                step "Removing empty directory $d" rmdir "$d"
            else
                log_info "Keeping $d (not empty)"
            fi
        done < <(sort -ru "${STATE_FILE}.dirs")
    fi

    if getent group docker &>/dev/null; then
        if [[ "$HAS_STATE" == "y" && "$GROUP_DOCKER_EXISTED" == "y" ]]; then
            log_info "Keeping docker group (existed before install)"
        else
            step "Removing docker group" groupdel docker
        fi
    fi

    step "Reloading systemd" bash -c 'systemctl daemon-reload; systemctl reset-failed'
    step "Removing install state" rm -f "$STATE_FILE" "${STATE_FILE}.dirs"
}

verify_clean() {
    log_section "Verification"
    local -a leftovers=()
    local p
    for p in "$DOCKER_ROOT" "$CONTAINERD_ROOT" "$DEFAULT_DOCKER_ROOT" "$DEFAULT_CONTAINERD_ROOT" \
             "${EXTRA_DATA_DIRS[@]}" /etc/docker /etc/containerd /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc \
             "$STATE_FILE"; do
        [[ -e "$p" || -L "$p" ]] && leftovers+=("$p")
    done
    for p in "${DOCKER_PACKAGES[@]}"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -qE " (installed|config-files)$" && leftovers+=("package:$p")
    done
    hash -r
    command -v docker &>/dev/null && leftovers+=("binary:$(command -v docker)")
    getent group docker &>/dev/null && [[ "$GROUP_DOCKER_EXISTED" != "y" ]] && leftovers+=("group:docker")

    if (( ${#leftovers[@]} > 0 )); then
        log_warning "Leftovers found:"
        printf "    %s\n" "${leftovers[@]}"
        return 1
    fi
    log_success "Docker completely removed — no leftovers"
    [[ "$REMOVE_STACKS" != "y" && -n "$STACKS_DIR" && -d "$STACKS_DIR" ]] && log_info "Kept stacks directory: $STACKS_DIR"
    log_info "Reboot recommended to unload kernel modules (overlay, br_netfilter) loaded by Docker"
    return 0
}

############################################################# MAIN
main() {
    check_root
    log_section "Docker Complete Removal"
    load_state
    show_summary
    ask_confirmation
    stop_workloads
    unmount_leftovers
    cleanup_network
    purge_packages
    remove_files
    verify_clean || exit 1
    echo ""
    log_info "Log file: $LOGFILE"
}

main "$@"
