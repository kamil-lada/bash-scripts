#!/bin/bash
set -euo pipefail

# Docker Complete Removal - Simple Version

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
confirm() { read -rp "$(echo -e "${YELLOW}[CONFIRM]${NC} $* [y/N] ")" -n 1 -r; echo; [[ $REPLY =~ ^[Yy]$ ]]; }

[[ $EUID -ne 0 ]] && { error "Run as root (sudo)."; exit 1; }

# Get Docker data root from daemon.json
get_data_root() {
    local root="/var/lib/docker"
    local f="/etc/docker/daemon.json"
    [[ -f "$f" ]] && root=$(grep -o '"data-root"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/' || true)
    readlink -f "$root" 2>/dev/null || echo "$root"
}

# Simple stats
get_stats() {
    local c=0 i=0 v=0 n=0 size="0B" root
    root=$(get_data_root)
    if command -v docker >/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
        c=$(docker ps -aq 2>/dev/null | wc -l)
        i=$(docker images -aq 2>/dev/null | wc -l)
        v=$(docker volume ls -q 2>/dev/null | wc -l)
        n=$(docker network ls -q 2>/dev/null | wc -l)
    fi
    [[ -d "$root" ]] && size=$(du -sh "$root" 2>/dev/null | cut -f1)
    echo "containers=$c images=$i volumes=$v networks=$n root=$root size=$size"
}

# Show summary
eval "$(get_stats)"
echo -e "\n${BLUE}Docker Removal Summary${NC}"
echo "  Data root: $root ($size)"
echo "  Containers: $containers  Images: $images  Volumes: $volumes  Networks: $networks"
echo

confirm "Remove ALL Docker containers, images, volumes, networks?" || { info "Aborted."; exit 0; }
confirm "PERMANENTLY DELETE Docker data directory ($root)?" || { info "Aborted."; exit 0; }

info "Removing Docker..."

# Stop/remove containers, images, volumes, networks
if command -v docker >/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
    docker ps -aq | xargs -r docker stop >/dev/null 2>&1
    docker ps -aq | xargs -r docker rm -f >/dev/null 2>&1
    docker images -aq | xargs -r docker rmi -f >/dev/null 2>&1
    docker volume ls -q | xargs -r docker volume rm >/dev/null 2>&1
    docker network ls -q --filter type=custom | xargs -r docker network rm >/dev/null 2>&1
fi

# Stop service
systemctl stop docker.service docker.socket 2>/dev/null || true
systemctl disable docker.service docker.socket 2>/dev/null || true

# Purge packages
apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras docker-scan-plugin >/dev/null 2>&1 || true
rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker.gpg
apt-get update >/dev/null 2>&1 || true

# Remove data directory (handles custom root + symlink)
real_root=$(get_data_root)
default_root="/var/lib/docker"
[[ -d "$real_root" ]] && rm -rf "$real_root" && success "Removed data: $real_root"
[[ -L "$default_root" ]] && rm -f "$default_root" && success "Removed symlink: $default_root"
[[ -d "$default_root" && ! -L "$default_root" ]] && rm -rf "$default_root" && success "Removed default dir: $default_root"
[[ -d "${default_root}.old" ]] && rm -rf "${default_root}.old" && success "Removed backup: ${default_root}.old"

# Config dirs
rm -rf /etc/docker /etc/docker-compose /usr/local/bin/docker-compose ~/.docker
[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && rm -rf "$(getent passwd "$SUDO_USER" | cut -d: -f6)/.docker"

# Group/user
getent group docker >/dev/null && groupdel docker >/dev/null 2>&1 && success "Removed group: docker"
id docker >/dev/null 2>&1 && userdel -r docker >/dev/null 2>&1 && success "Removed user: docker"

# Clean apt
apt-get autoremove --purge -y >/dev/null 2>&1 || true
apt-get autoclean -y >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1 || true

success "Docker completely removed. No trace remains."