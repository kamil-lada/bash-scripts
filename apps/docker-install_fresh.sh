#!/bin/bash
# Docker Engine fresh install — Debian 12 (bookworm) / 13 (trixie), VM or LXC
#
# Optional custom data location (system on small partition, data on big one).
# Uses the native, documented settings instead of symlinks / bind mounts:
#   - Docker:     "data-root" in /etc/docker/daemon.json
#   - containerd: "root" in /etc/containerd/config.toml
#     (Engine 29+ uses the containerd image store by default on fresh installs,
#      so images and container snapshots live in containerd's root, NOT data-root)
#   - systemd:    RequiresMountsFor= drop-ins so daemons wait for the data mount
#
# Everything the script changes is recorded in $STATE_FILE so that
# docker-remove_all.sh can revert it completely.
set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

LOGFILE="/var/log/docker-install.log"
STATE_FILE="/etc/docker-install.state"
: > "$LOGFILE"

trap 'echo -e "${RED}Script failed. Check $LOGFILE for details${NC}" >&2' ERR

readonly DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
readonly CONFLICTING_PACKAGES=(docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc)
readonly PREREQ_PACKAGES=(ca-certificates curl)
readonly SUPPORTED_ARCHS="amd64 arm64 armhf ppc64le"
readonly DEFAULT_DOCKER_ROOT="/var/lib/docker"
readonly DEFAULT_CONTAINERD_ROOT="/var/lib/containerd"

USE_CUSTOM_LOCATION="n"
DATA_BASE=""
DOCKER_ROOT="$DEFAULT_DOCKER_ROOT"
CONTAINERD_ROOT="$DEFAULT_CONTAINERD_ROOT"
STACKS_DIR=""
CODENAME=""
ARCH=""
declare -a DOCKER_USERS=()

############################################################# HELPERS
is_pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# Append KEY=VALUE (shell-quoted) to state file — sourced by docker-remove_all.sh
state_set() {
    printf '%s=%q\n' "$1" "$2" >> "$STATE_FILE"
}

# mkdir -p that records every directory it actually creates (outermost first)
mkdir_tracked() {
    local target="$1" dir
    local -a missing=()
    dir="$target"
    while [[ ! -e "$dir" ]]; do
        missing=("$dir" "${missing[@]}")
        dir="$(dirname "$dir")"
    done
    mkdir -p "$target"
    for dir in "${missing[@]}"; do
        echo "$dir" >> "${STATE_FILE}.dirs"
    done
}

# Filesystem checks for a directory that will hold overlay data
# check_data_filesystem PATH [check_same_fs_as_root=y]
check_data_filesystem() {
    local path="$1" check_root_fs="${2:-y}" probe fstype source root_source
    probe="$path"
    while [[ ! -e "$probe" ]]; do probe="$(dirname "$probe")"; done

    fstype=$(findmnt -n -o FSTYPE --target "$probe")
    source=$(findmnt -n -o SOURCE --target "$probe")
    root_source=$(findmnt -n -o SOURCE --target /)

    log_info "Location $path -> filesystem $fstype on $source"

    case "$fstype" in
        ext4|xfs|btrfs|zfs) ;;
        nfs*|cifs|smb*|fuse*|tmpfs|ramfs|overlay|9p|virtiofs)
            log_error "Filesystem '$fstype' is not supported for Docker/containerd data"
            return 1 ;;
        *)
            log_warning "Filesystem '$fstype' is not tested — overlayfs may not work" ;;
    esac

    if [[ "$fstype" == "xfs" ]] && command -v xfs_info &>/dev/null; then
        if xfs_info "$probe" 2>/dev/null | grep -q "ftype=0"; then
            log_error "XFS without ftype=1 (d_type) cannot be used with overlayfs"
            return 1
        fi
    fi

    if [[ "$check_root_fs" == "y" && "$source" == "$root_source" ]]; then
        log_warning "$path is on the same filesystem as / — custom location gives no extra space"
        confirm "Continue anyway?" n || return 1
    fi

    if ! touch "$probe/.docker-install-write-test" 2>/dev/null; then
        log_error "$probe is not writable by root (unprivileged LXC mount with wrong ownership?)"
        return 1
    fi
    rm -f "$probe/.docker-install-write-test"
    return 0
}

dir_is_empty_or_missing() {
    [[ ! -e "$1" ]] || [[ -d "$1" && -z "$(ls -A "$1" 2>/dev/null)" ]]
}

############################################################# PRE-FLIGHT
preflight() {
    log_section "Pre-flight checks"
    check_root
    CODENAME=$(detect_debian_version)
    ARCH=$(dpkg --print-architecture)
    log_success "Debian $CODENAME ($ARCH)"

    if [[ " $SUPPORTED_ARCHS " != *" $ARCH "* ]]; then
        log_error "Architecture $ARCH is not supported by Docker's Debian repository"
        exit 1
    fi

    if is_pkg_installed docker-ce || is_pkg_installed containerd.io || [[ -f "$STATE_FILE" ]]; then
        log_error "Docker is already installed (or a previous install left state in $STATE_FILE)"
        log_error "Run $SCRIPT_DIR/docker-remove_all.sh first for a fresh install"
        exit 1
    fi

    local leftover
    for leftover in "$DEFAULT_DOCKER_ROOT" "$DEFAULT_CONTAINERD_ROOT" /etc/docker /etc/containerd; do
        if [[ -e "$leftover" ]] && ! dir_is_empty_or_missing "$leftover"; then
            log_warning "Leftover from a previous Docker install found: $leftover"
            log_warning "Run docker-remove_all.sh to clean it, or remove it manually"
            confirm "Continue anyway?" n || exit 1
        fi
    done

    if is_lxc; then
        log_warning "LXC container detected — Docker in LXC is not recommended by Proxmox"
        log_warning "Required on the Proxmox host for this CT: features nesting=1 (and keyctl=1 if unprivileged)"
        log_warning "Known issue: newer containerd/runc + Proxmox < 9.1 fails with"
        log_warning "  'open sysctl net.ipv4.ip_unprivileged_port_start ... permission denied' — upgrade Proxmox"
        confirm "Continue with installation in LXC?" y || exit 1
    else
        log_success "Virtual machine / bare metal detected"
    fi

    check_network_connectivity || exit 1
    check_disk_space 1024 || exit 1

    local -a conflicts=()
    local pkg
    for pkg in "${CONFLICTING_PACKAGES[@]}"; do
        is_pkg_installed "$pkg" && conflicts+=("$pkg")
    done
    if (( ${#conflicts[@]} > 0 )); then
        log_warning "Conflicting packages installed: ${conflicts[*]}"
        confirm "Remove them (required by Docker)?" y || exit 1
        run_cmd "Removing conflicting packages" apt-get remove -y "${conflicts[@]}"
    fi
}

############################################################# INTERACTIVE CONFIG
gather_config() {
    log_section "Configuration"

    if confirm "Use a custom data location (e.g. separate big disk)?" y; then
        USE_CUSTOM_LOCATION="y"
        while true; do
            DATA_BASE=$(ask "Base path for Docker data (uses <path>/system and <path>/stacks)" "/data")
            DATA_BASE="${DATA_BASE%/}"
            if [[ "$DATA_BASE" != /* || -z "$DATA_BASE" || "$DATA_BASE" =~ [[:space:]] ]]; then
                log_error "Use an absolute path without spaces (not /)"
                continue
            fi
            case "$DATA_BASE" in
                /var/lib|/var/lib/docker*|/var/lib/containerd*|/etc*|/usr*|/boot*|/proc*|/sys*|/dev*|/run*)
                    log_error "$DATA_BASE is a system location — choose another path"
                    continue ;;
            esac
            check_data_filesystem "$DATA_BASE" && break
        done

        DOCKER_ROOT="$DATA_BASE/system/docker"
        CONTAINERD_ROOT="$DATA_BASE/system/containerd"
        STACKS_DIR="$DATA_BASE/stacks"

        local dir
        for dir in "$DOCKER_ROOT" "$CONTAINERD_ROOT"; do
            if ! dir_is_empty_or_missing "$dir"; then
                log_error "$dir exists and is not empty — Docker docs require a dedicated directory"
                exit 1
            fi
        done
    else
        check_data_filesystem "$DEFAULT_DOCKER_ROOT" n || exit 1
    fi

    # Users for the docker group (docker group == root-equivalent access)
    local -a candidates=()
    [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && candidates+=("$SUDO_USER")
    local user
    for user in debian zabbix; do
        id "$user" &>/dev/null && [[ " ${candidates[*]} " != *" $user "* ]] && candidates+=("$user")
    done
    for user in "${candidates[@]}"; do
        if confirm "Add user '$user' to docker group (grants root-equivalent access)?" y; then
            DOCKER_USERS+=("$user")
        fi
    done

    log_section "Summary"
    printf "  %-26s %s\n" "Environment:" "$(is_lxc && echo "LXC Container" || echo "Virtual Machine")"
    printf "  %-26s %s\n" "Debian:" "$CODENAME ($ARCH)"
    printf "  %-26s %s\n" "Docker data-root:" "$DOCKER_ROOT"
    printf "  %-26s %s\n" "containerd root:" "$CONTAINERD_ROOT"
    printf "  %-26s %s\n" "Compose stacks:" "${STACKS_DIR:-not created (vanilla install)}"
    printf "  %-26s %s\n" "docker group users:" "${DOCKER_USERS[*]:-none}"
    echo ""
    confirm "Proceed with installation?" y || { log_info "Aborted."; exit 0; }
}

############################################################# INSTALL
init_state() {
    : > "$STATE_FILE"
    : > "${STATE_FILE}.dirs"
    chmod 600 "$STATE_FILE" "${STATE_FILE}.dirs"
    {
        echo "# Written by docker-install_fresh.sh on $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# Used by docker-remove_all.sh to revert the installation — do not edit"
    } >> "$STATE_FILE"
    state_set USE_CUSTOM_LOCATION "$USE_CUSTOM_LOCATION"
    state_set DATA_BASE "$DATA_BASE"
    state_set DOCKER_ROOT "$DOCKER_ROOT"
    state_set CONTAINERD_ROOT "$CONTAINERD_ROOT"
    state_set STACKS_DIR "$STACKS_DIR"
    state_set IP_FORWARD_BEFORE "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"
    state_set GROUP_DOCKER_EXISTED "$(getent group docker &>/dev/null && echo y || echo n)"
}

install_packages() {
    log_section "Installing Docker Engine"

    local -a new_prereqs=()
    local pkg
    for pkg in "${PREREQ_PACKAGES[@]}"; do
        is_pkg_installed "$pkg" || new_prereqs+=("$pkg")
    done
    state_set PREREQS_INSTALLED "${new_prereqs[*]}"

    run_cmd "Updating package lists" apt-get update
    if (( ${#new_prereqs[@]} > 0 )); then
        run_cmd "Installing prerequisites (${new_prereqs[*]})" \
            env DEBIAN_FRONTEND=noninteractive apt-get install -y "${new_prereqs[@]}"
    fi

    # Old one-line repo file from previous script version conflicts with deb822 file
    rm -f /etc/apt/sources.list.d/docker.list

    run_cmd "Creating keyring directory" install -m 0755 -d /etc/apt/keyrings
    run_cmd "Downloading Docker GPG key" \
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    run_cmd "Adding Docker repository (deb822)" bash -c "
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $CODENAME
Components: stable
Architectures: $ARCH
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    "

    run_cmd "Updating package lists (Docker repo)" apt-get update
    run_cmd "Installing ${DOCKER_PACKAGES[*]}" \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y "${DOCKER_PACKAGES[@]}"

    local version
    version=$(dpkg-query -W -f='${Version}' docker-ce 2>/dev/null || echo unknown)
    log_success "Installed docker-ce $version, containerd.io $(dpkg-query -W -f='${Version}' containerd.io 2>/dev/null)"
}

configure_daemons() {
    log_section "Configuring Docker and containerd"

    # Packages start the services right away — stop them before relocating data
    run_cmd "Stopping docker and containerd" \
        systemctl stop docker.socket docker.service containerd.service

    # Engine 29 / containerd 2.1.5+: default open-files limit in containers dropped
    # from 1048576 to 1024. Restore a sane default, capped at what this host allows
    # (unprivileged LXC can have a lower hard limit).
    local nofile hard_limit
    hard_limit=$(ulimit -Hn)
    if [[ "$hard_limit" == "unlimited" ]] || (( hard_limit > 1048576 )); then
        nofile=1048576
    else
        nofile=$hard_limit
    fi

    run_cmd "Writing /etc/docker/daemon.json" bash -c "
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  \"data-root\": \"$DOCKER_ROOT\",
  \"log-driver\": \"json-file\",
  \"log-opts\": {
    \"max-size\": \"100m\",
    \"max-file\": \"5\"
  },
  \"default-ulimits\": {
    \"nofile\": { \"Name\": \"nofile\", \"Soft\": $nofile, \"Hard\": $nofile }
  }
}
EOF
    "

    if [[ "$USE_CUSTOM_LOCATION" == "y" ]]; then
        # Only set top-level "root" in the packaged config (it ships '#root = "/var/lib/containerd"').
        # The rest stays as packaged — its v1-format 'disabled_plugins = ["cri"]' is
        # rejected by containerd 2.x once a 'version = 2' header is added.
        run_cmd "Setting root in /etc/containerd/config.toml" bash -c '
        cfg=/etc/containerd/config.toml
        mkdir -p /etc/containerd
        touch "$cfg"
        sed -i "/^#\?root[[:space:]]*=/d" "$cfg"
        { printf "# root set by docker-install_fresh.sh\nroot = \"%s\"\n\n" "$1"; cat "$cfg"; } > "$cfg.tmp"
        mv "$cfg.tmp" "$cfg"
        ' _ "$CONTAINERD_ROOT"

        # Make daemons wait for (and depend on) the filesystem holding their data
        run_cmd "Adding systemd mount dependencies" bash -c "
        mkdir -p /etc/systemd/system/containerd.service.d /etc/systemd/system/docker.service.d
        cat > /etc/systemd/system/containerd.service.d/10-data-location.conf <<EOF
# Managed by docker-install_fresh.sh
[Unit]
RequiresMountsFor=$CONTAINERD_ROOT
EOF
        cat > /etc/systemd/system/docker.service.d/10-data-location.conf <<EOF
# Managed by docker-install_fresh.sh
[Unit]
RequiresMountsFor=$DOCKER_ROOT
EOF
        "

        mkdir_tracked "$(dirname "$DOCKER_ROOT")"
        mkdir_tracked "$(dirname "$CONTAINERD_ROOT")"

        # Fresh install: default dirs only hold empty scaffolding created at package install
        run_cmd "Removing unused default data dirs" \
            rm -rf --one-file-system "$DEFAULT_DOCKER_ROOT" "$DEFAULT_CONTAINERD_ROOT"
    fi

    run_cmd "Reloading systemd" systemctl daemon-reload
}

start_and_verify() {
    log_section "Starting and verifying"

    run_cmd "Enabling and starting containerd" systemctl enable --now containerd.service
    if ! run_cmd_continue "Enabling and starting docker" systemctl enable --now docker.socket docker.service; then
        journalctl -u docker.service -u containerd.service -n 30 --no-pager | sed 's/^/  /' >&2
        show_failure_hints
        exit 1
    fi

    if ! run_cmd_continue "Running hello-world test container" docker run --rm hello-world; then
        show_failure_hints
        exit 1
    fi
    run_cmd_continue "Removing hello-world image" docker image rm hello-world || true

    local actual_docker_root actual_containerd_root driver
    actual_docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
    actual_containerd_root=$(containerd config dump 2>/dev/null | sed -n "s/^root = [\"']\(.*\)[\"']\$/\1/p" || true)
    driver=$(docker info --format '{{.Driver}}' 2>/dev/null || true)

    if [[ "$actual_docker_root" == "$DOCKER_ROOT" ]]; then
        log_success "Docker data-root: $actual_docker_root"
    else
        log_error "Docker data-root is '$actual_docker_root', expected '$DOCKER_ROOT'"
    fi
    if [[ "$actual_containerd_root" == "$CONTAINERD_ROOT" ]]; then
        log_success "containerd root: $actual_containerd_root"
    else
        log_error "containerd root is '$actual_containerd_root', expected '$CONTAINERD_ROOT'"
    fi

    if [[ "$driver" == *vfs* || "$driver" == "native" ]]; then
        log_warning "Storage driver is '$driver' — overlayfs not available, this is slow and wastes space"
    else
        log_success "Storage driver: $driver"
    fi

    if [[ "$USE_CUSTOM_LOCATION" == "y" ]]; then
        local dir
        for dir in "$DEFAULT_DOCKER_ROOT" "$DEFAULT_CONTAINERD_ROOT"; do
            if [[ -e "$dir" ]]; then
                log_warning "$dir was re-created — something still writes to the default location"
            fi
        done
    fi
}

show_failure_hints() {
    log_error "Docker failed to start or run a container"
    if is_lxc; then
        log_warning "LXC hints: enable 'nesting=1' (and 'keyctl=1' for unprivileged) in CT options,"
        log_warning "upgrade Proxmox to 9.1+ if you see 'ip_unprivileged_port_start' errors,"
        log_warning "ZFS-backed CT rootfs needs ZFS 2.2+ for overlayfs."
    fi
    log_warning "To undo this install: $SCRIPT_DIR/docker-remove_all.sh"
}

setup_stacks_and_users() {
    log_section "Stacks directory and users"

    # Vanilla install (no custom location): no stacks directory
    if [[ -n "$STACKS_DIR" ]]; then
        mkdir_tracked "$STACKS_DIR"
        run_cmd "Setting $STACKS_DIR ownership (root:docker, 2775)" bash -c "
        chown root:docker '$STACKS_DIR'
        chmod 2775 '$STACKS_DIR'
        "
    fi

    local user
    for user in "${DOCKER_USERS[@]}"; do
        run_cmd "Adding $user to docker group" usermod -aG docker "$user"
    done
    state_set USERS_ADDED "${DOCKER_USERS[*]}"
}

############################################################# MAIN
main() {
    log_section "Docker Engine Installation"
    preflight
    gather_config
    init_state
    install_packages
    configure_daemons
    start_and_verify
    setup_stacks_and_users
    state_set INSTALL_COMPLETED "y"

    log_section "Done"
    printf "  %-26s %s\n" "Docker:" "$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
    printf "  %-26s %s\n" "Compose:" "$(docker compose version --short 2>/dev/null)"
    printf "  %-26s %s\n" "Docker data-root:" "$DOCKER_ROOT"
    printf "  %-26s %s\n" "containerd root:" "$CONTAINERD_ROOT"
    printf "  %-26s %s\n" "Compose stacks:" "${STACKS_DIR:-not created (vanilla install)}"
    printf "  %-26s %s\n" "State file:" "$STATE_FILE"
    printf "  %-26s %s\n" "Log file:" "$LOGFILE"
    echo ""
    if (( ${#DOCKER_USERS[@]} > 0 )); then
        log_info "Users ${DOCKER_USERS[*]} must log out and back in for docker group access"
    fi
    log_warning "Published container ports bypass ufw/firewalld — use the DOCKER-USER chain for filtering"
}

main "$@"
