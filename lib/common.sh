#!/bin/bash
# Shared library for all scripts in this repository (apps/, pve/, ...)
# Source: source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

[[ -n "${_LIB_COMMON_LOADED:-}" ]] && return 0
_LIB_COMMON_LOADED=1

# Plain 'su' (without '-') keeps the user's PATH on Debian — no /usr/sbin
# (useradd, sysctl, dpkg-reconfigure, ...). Make sure the sbin dirs are there.
case ":$PATH:" in
    *:/usr/sbin:*) ;;
    *) export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH" ;;
esac

############################################################# COLORS
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly L_BLUE='\033[0;94m'
readonly NC='\033[0m'

############################################################# LOGGING
log_info() {
    echo -e "${L_BLUE}[→]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# _run fatal|continue "Description" cmd args... — output goes to $LOGFILE
_run() {
    local mode="$1" desc="$2"
    shift 2
    local log="${LOGFILE:-/dev/null}"
    printf "%-60s" "$desc..."
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Running: $desc" >> "$log"
    if "$@" >>"$log" 2>&1; then
        echo -e "${GREEN}OK${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $desc" >> "$log"
        return 0
    fi
    if [[ "$mode" == "fatal" ]]; then
        echo -e "${RED}ERROR${NC}"
        log_error "Failed: $desc"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $desc" >> "$log"
        tail -n 50 "$log" | sed 's/^/  /' >&2
    else
        echo -e "${YELLOW}SKIPPED${NC}"
        log_warning "Failed (continuing): $desc"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED (skipped): $desc" >> "$log"
    fi
    return 1
}

run_cmd()          { _run fatal "$@"; }
run_cmd_continue() { _run continue "$@"; }

############################################################# SYSTEM CHECKS
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root: sudo bash $0, or 'su -' first (no sudo access)"
        exit 1
    fi
}

detect_debian_version() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "/etc/os-release not found"
        exit 1
    fi
    source /etc/os-release
    if [[ "$ID" != "debian" ]]; then
        log_error "This script is for Debian only (detected: $ID)"
        exit 1
    fi
    local version="${VERSION_ID:-unknown}"
    if [[ "$version" != "12" && "$version" != "13" ]]; then
        log_error "This script supports Debian 12 and 13 only (detected: $version)"
        exit 1
    fi
    echo "${VERSION_CODENAME:-bookworm}"
}

# Detected once, then cached
is_lxc() {
    if [[ -z "${_IS_LXC:-}" ]]; then
        _IS_LXC=n
        if command -v systemd-detect-virt &>/dev/null && systemd-detect-virt --container &>/dev/null; then
            _IS_LXC=y
        elif grep -qa container /proc/1/environ 2>/dev/null; then
            _IS_LXC=y
        elif grep -q "lxc" /proc/self/cgroup 2>/dev/null; then
            _IS_LXC=y
        fi
    fi
    [[ "$_IS_LXC" == "y" ]]
}

# 0 if the systemd unit file exists (no pipe: grep -q + pipefail gives false negatives)
unit_exists() {
    [[ -n "$(systemctl list-unit-files --no-legend "$1" 2>/dev/null)" ]]
}

check_network_manager() {
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        echo "NetworkManager"
        return 0
    elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        echo "systemd-networkd"
        return 0
    fi
    echo "ifupdown"
    return 0
}

check_network_connectivity() {
    local test_host="deb.debian.org"
    log_info "Checking network connectivity..."
    if ping -c 1 -W 5 "$test_host" &>/dev/null; then
        log_success "Network connectivity OK"
        return 0
    fi
    log_warning "Cannot reach $test_host via ping"
    if getent hosts "$test_host" &>/dev/null; then
        log_success "DNS resolution OK (ICMP blocked but network reachable)"
        return 0
    fi
    log_error "No network connectivity to $test_host"
    return 1
}

check_disk_space() {
    local min_free_mb="${1:-500}"
    local available_mb
    available_mb=$(df -m / | tail -1 | awk '{print $4}')
    if (( available_mb < min_free_mb )); then
        log_error "Insufficient disk space: ${available_mb}MB available, need ${min_free_mb}MB"
        return 1
    fi
    log_info "Disk space OK: ${available_mb}MB free"
    return 0
}

############################################################# VALIDATION
validate_hostname() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

validate_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

validate_ip() {
    local ip="$1" octet
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local -a octets
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

# Space-separated list of IPs
validate_ip_list() {
    local ip
    [[ -n "$1" ]] || return 1
    for ip in $1; do
        validate_ip "$ip" || return 1
    done
}

validate_cidr() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 32 ))
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

validate_positive_int() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 ))
}

validate_network_type() {
    [[ "$1" == "dhcp" || "$1" == "static" ]]
}

validate_timezone() {
    [[ -f "/usr/share/zoneinfo/$1" ]]
}

# server:/export (hostname or IPv4)
validate_nfs_share() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+:/[^[:space:]]*$ ]]
}

validate_url() {
    [[ "$1" =~ ^https?://[^/[:space:]]+ ]]
}

# Interface name prefix: lowercase, short, not the kernel's own "eth"
# (same reason Proxmox VE uses "nic")
validate_pin_prefix() {
    [[ "$1" =~ ^[a-z]{1,8}$ && "$1" != "eth" ]]
}

############################################################# CONFIG
load_config() {
    local config_path="$1"
    if [[ -f "$config_path" ]]; then
        source "$config_path"
        log_info "Config loaded from: $config_path"
    else
        log_info "No config file, using interactive mode"
    fi
    return 0
}

############################################################# TIME SYNC
configure_time_sync() {
    local timezone="$1"

    run_cmd "Setting timezone to $timezone" timedatectl set-timezone "$timezone"

    if is_lxc; then
        log_info "LXC detected — checking host time sync..."
        if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
            log_info "Host time sync active (LXC inherits host clock)"
        else
            log_warning "Host time sync not detected — container may drift"
        fi
        return 0
    fi

    # VM: try timesyncd first, then chrony
    if unit_exists systemd-timesyncd.service; then
        run_cmd "Enabling NTP via timesyncd" timedatectl set-ntp true
        run_cmd_continue "Restarting timesyncd" systemctl restart systemd-timesyncd || true
        if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
            return 0
        fi
    fi

    if ! command -v chronyd &>/dev/null; then
        run_cmd "Installing chrony" env DEBIAN_FRONTEND=noninteractive apt-get install -y chrony
    fi

    run_cmd_continue "Enabling and starting chrony" systemctl enable --now chrony || true
}

############################################################# NETWORK
readonly PIN_LINK_DIR="/usr/local/lib/systemd/network"

# Physical NICs only (have a backing device) — skips lo, veth, bridges, bonds, vlans, docker...
list_physical_ifaces() {
    local dev
    for dev in /sys/class/net/*; do
        [[ -e "$dev/device" ]] && basename "$dev"
    done | sort
}

# Pin NIC names to MAC addresses with systemd .link files, the way Proxmox VE 9
# (pve-network-interface-pinning) does it: <prefix>0, <prefix>1, ...
# Must run AFTER cloning — clones get new MAC addresses.
# Sets global PINNED_NAMES[old]=new for configure_network. Effective after reboot.
declare -gA PINNED_NAMES=()
pin_interface_names() {
    local prefix="$1" iface mac idx=0
    run_cmd "Removing previous interface pins" bash -c "mkdir -p '$PIN_LINK_DIR' && rm -f '$PIN_LINK_DIR'/50-pin-*.link"
    for iface in $(list_physical_ifaces); do
        mac=$(cat "/sys/class/net/$iface/address")
        PINNED_NAMES[$iface]="${prefix}${idx}"
        run_cmd "Pinning $iface ($mac) -> ${prefix}${idx}" bash -c "
        cat > '$PIN_LINK_DIR/50-pin-${prefix}${idx}.link' <<EOF
# Managed by bash-scripts (2.initialize_for_usecase.sh)
[Match]
MACAddress=$mac
Type=ether

[Link]
Name=${prefix}${idx}
EOF
        "
        idx=$((idx + 1))
    done
    # Renames may also happen in the initramfs
    run_cmd "Updating initramfs" update-initramfs -u
}

# Writes /etc/network/interfaces (ifupdown). Applied on next reboot — applying live
# would cut the SSH session running this script.
# configure_network dhcp|static [ip cidr gateway "dns1 dns2"]
configure_network() {
    local network_type="$1" static_ip="${2:-}" cidr="${3:-}" gateway="${4:-}" dns_servers="${5:-}"

    if is_lxc; then
        log_info "LXC — Proxmox manages network, skipping internal configuration"
        return 0
    fi

    local -a ifaces=()
    local iface
    for iface in $(list_physical_ifaces); do
        ifaces+=("${PINNED_NAMES[$iface]:-$iface}")
    done
    if (( ${#ifaces[@]} == 0 )); then
        log_error "No physical network interfaces found!"
        return 1
    fi
    local primary="${ifaces[0]}"

    local use_resolvconf="n"
    dpkg-query -W -f='${Status}' resolvconf 2>/dev/null | grep -q "install ok installed" && use_resolvconf="y"

    local new_file
    new_file=$(mktemp)
    {
        echo "# Network configuration — managed by bash-scripts"
        echo "source /etc/network/interfaces.d/*"
        echo ""
        echo "auto lo"
        echo "iface lo inet loopback"
        echo ""
        echo "auto $primary"
        if [[ "$network_type" == "static" ]]; then
            echo "iface $primary inet static"
            echo "    address $static_ip/$cidr"
            echo "    gateway $gateway"
            [[ "$use_resolvconf" == "y" ]] && echo "    dns-nameservers $dns_servers"
        else
            echo "iface $primary inet dhcp"
        fi
        for iface in "${ifaces[@]:1}"; do
            echo ""
            echo "# Additional interface — brought up when present, does not block boot"
            echo "allow-hotplug $iface"
            echo "iface $iface inet dhcp"
        done
    } > "$new_file"

    if ! ifquery --interfaces="$new_file" --list -a >> "${LOGFILE:-/dev/null}" 2>&1; then
        log_error "Generated network config is invalid (kept in $new_file)"
        return 1
    fi

    local backup_file
    backup_file="/etc/network/interfaces.bak.$(date +%s)"
    [[ -f /etc/network/interfaces ]] && run_cmd "Backing up network config to $backup_file" cp /etc/network/interfaces "$backup_file"
    run_cmd "Writing /etc/network/interfaces ($network_type, primary: $primary)" install -m 644 "$new_file" /etc/network/interfaces
    rm -f "$new_file"

    # Without resolvconf, dns-nameservers is ignored — write resolv.conf directly
    if [[ "$network_type" == "static" && "$use_resolvconf" == "n" ]]; then
        if [[ -L /etc/resolv.conf ]]; then
            log_warning "/etc/resolv.conf is a symlink (managed elsewhere) — DNS not changed"
        else
            run_cmd "Writing /etc/resolv.conf" bash -c "
            cp /etc/resolv.conf /etc/resolv.conf.bak.\$(date +%s) 2>/dev/null || true
            : > /etc/resolv.conf
            for dns in $dns_servers; do echo \"nameserver \$dns\" >> /etc/resolv.conf; done
            "
        fi
    fi
    log_info "Network config takes effect after reboot (backup: $backup_file)"
}

############################################################# APT
# apt-get update that fails on ANY repo error (unsigned repo, missing key, 404...).
# Plain apt-get update exits 0 on many of these, and the failure only shows up
# later as "package has no installation candidate".
apt_update() {
    run_cmd "${1:-Updating package lists}" apt-get update --error-on=any
}

# add_apt_repo NAME URI SUITE COMPONENTS KEY_URL [ARCHITECTURES]
# Third-party repo set up the way Debian 12/13 apt expects it:
#   - key in /etc/apt/keyrings/NAME.asc|.gpg, mode 0644 (apt verifies as user _apt)
#   - deb822 /etc/apt/sources.list.d/NAME.sources with Signed-By. Never the legacy
#     /etc/apt/trusted.gpg: Debian 13 apt ignores it ("Missing key ...").
#   - other entries for the same URI (old .list files, vendor release packages,
#     manual setups) are set aside — they carry other keys and break apt update
# Ends with apt_update, so a broken repo fails here, not at install time.
add_apt_repo() {
    local name="$1" uri="$2" suite="$3" components="$4" key_url="$5" archs="${6:-}"
    local target="/etc/apt/sources.list.d/$name.sources"
    local match="${uri#*://}" tmp key f
    match="${match%/}"

    tmp=$(mktemp)
    if ! run_cmd "Downloading $name repository key" curl -fsSL -o "$tmp" "$key_url"; then
        rm -f "$tmp"
        return 1
    fi
    key="/etc/apt/keyrings/$name.gpg"
    grep -q -- "-----BEGIN PGP PUBLIC KEY BLOCK-----" "$tmp" && key="/etc/apt/keyrings/$name.asc"
    install -d -m 0755 /etc/apt/keyrings
    rm -f "/etc/apt/keyrings/$name.asc" "/etc/apt/keyrings/$name.gpg"
    install -m 0644 "$tmp" "$key"
    rm -f "$tmp"

    for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" && "$f" != "$target" ]] || continue
        if grep -qF -- "$match" "$f"; then
            mv "$f" "$f.bak"
            log_warning "Old $name repo entry set aside: $f -> $f.bak"
        fi
    done
    if [[ -f /etc/apt/sources.list ]] && grep -v '^[[:space:]]*#' /etc/apt/sources.list | grep -qF -- "$match"; then
        sed -i "\|^[^#].*${match}|s|^|# |" /etc/apt/sources.list
        log_warning "Old $name repo entry commented out in /etc/apt/sources.list"
    fi

    cat > "$target" <<EOF
Types: deb
URIs: $uri
Suites: $suite
Components: $components
${archs:+Architectures: $archs
}Signed-By: $key
EOF
    chmod 0644 "$target"
    log_success "Repository $name: $uri $suite"

    apt_update "Updating package lists ($name repo)"
}

############################################################# TEMPLATE FUNCTIONS
create_admin_user() {
    local ssh_keys=("$@")
    run_cmd "Creating/configuring debian user" bash -c '
    if ! id debian &>/dev/null; then
        useradd -m -s /bin/bash debian
    fi
    '
    run_cmd "Creating SSH directory" bash -c '
    mkdir -p /home/debian/.ssh
    chmod 700 /home/debian/.ssh
    chown -R debian:debian /home/debian/.ssh
    '
    run_cmd "Adding SSH keys" bash -c '
    f=/home/debian/.ssh/authorized_keys
    touch "$f"
    for key in "$@"; do
        grep -qxF -- "$key" "$f" || echo "$key" >> "$f"
    done
    chmod 600 "$f"
    chown debian:debian "$f"
    ' bash "${ssh_keys[@]}"
}

admin_has_sudo() {
    sudo -l -U debian 2>/dev/null | grep -q "NOPASSWD: ALL"
}

# Passwordless sudo for debian: rule validated by visudo, then verified.
# Phase 1 (template) and phase 2 (clones of older templates may lack it).
configure_admin_sudo() {
    if ! command -v sudo &>/dev/null; then
        apt_update
        run_cmd "Installing sudo" env DEBIAN_FRONTEND=noninteractive apt-get install -y sudo
    fi
    run_cmd "Configuring passwordless sudo (debian)" bash -c '
    set -e
    tmp=$(mktemp)
    echo "debian ALL=(ALL) NOPASSWD:ALL" > "$tmp"
    visudo -cf "$tmp"
    install -d -m 0750 /etc/sudoers.d
    install -m 0440 -o root -g root "$tmp" /etc/sudoers.d/debian
    rm -f "$tmp"
    '
    run_cmd "Verifying sudo access (debian)" admin_has_sudo
}

secure_root_account() {
    run_cmd "Locking root account" passwd -l root
}

install_base_packages() {
    apt_update

    local -a base_packages=(vim git curl wget gpg jq nfs-common dirmngr net-tools htop sudo logrotate unattended-upgrades tcpdump iproute2 gnupg)

    if ! is_lxc; then
        base_packages+=(qemu-guest-agent parted)
    fi

    run_cmd "Installing base packages" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${base_packages[@]}"
}

install_java() {
    # apt-cache show succeeds even without an installable version — check the candidate
    run_cmd "Installing OpenJDK" bash -c '
    has() { apt-cache policy "$1" | grep -q "Candidate: [0-9]"; }
    if has openjdk-25-jdk; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-25-jdk
    elif has openjdk-21-jdk; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-21-jdk
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y default-jdk
    fi
    '
}

upgrade_system() {
    run_cmd "Upgrading system packages" env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
}

configure_unattended_upgrades() {
    run_cmd "Enabling automatic security updates" bash -c '
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    '
}

configure_shell_aliases() {
    run_cmd "Configuring shell aliases" bash -c "
    if ! grep -q 'alias ll=' /etc/bash.bashrc; then
        cat >> /etc/bash.bashrc <<'EOL'

# Custom aliases
alias ll='ls -alhF --group-directories-first'
EOL
    fi
    "
}

# Drop-in instead of sed on sshd_config: sshd uses the FIRST value it reads and
# Debian includes sshd_config.d/*.conf at the top, so 00- wins over e.g. 50-cloud-init.conf.
# Does not restart sshd — caller restarts once.
harden_ssh() {
    local dropin="/etc/ssh/sshd_config.d/00-hardening.conf"
    if [[ ! -s /home/debian/.ssh/authorized_keys ]]; then
        log_error "No SSH keys for user debian — skipping SSH hardening to avoid lock-out"
        return 1
    fi
    run_cmd "Writing SSH hardening drop-in" bash -c "
    mkdir -p /etc/ssh/sshd_config.d
    cat > '$dropin' <<EOF
# Managed by bash-scripts
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
    "
    if ! run_cmd "Validating SSH configuration" sshd -t; then
        rm -f "$dropin"
        log_error "Invalid SSH configuration — hardening drop-in removed"
        return 1
    fi
}

configure_console_banner() {
    # \4 = IPv4 of the default-route interface (works with any interface name)
    run_cmd "Configuring login banner" bash -c '
    sed -i "/^IP:/d" /etc/issue 2>/dev/null || true
    echo "IP: \4" >> /etc/issue
    '
}

configure_motd() {
    run_cmd "Creating MOTD script" bash -c "
    mkdir -p /etc/update-motd.d
    cat > /etc/update-motd.d/10-system-info <<'EOF'
#!/bin/bash
echo \"\"
echo \"  ═════════════════════════════════════════════\"
echo \"\"
echo \"  Hostname:  \$(hostname)\"
echo \"  IP:        \$(hostname -I 2>/dev/null | head -1)\"
echo \"  Uptime:    \$(uptime -p 2>/dev/null)\"
echo \"  Disk /:    \$(df -h / | tail -1 | awk '{print \$3, \"/\", \$2, \"(\" \$5 \")\"}')\"
echo \"  Memory:    \$(free -h | awk '/Mem:/ {print \$3, \"/\", \$2}')\"
echo \"\"
echo \"  ═════════════════════════════════════════════\"
echo \"\"
EOF
    chmod +x /etc/update-motd.d/10-system-info
    "
}

clean_packages() {
    run_cmd "Cleaning package cache" bash -c '
    set -e
    apt-get clean
    apt-get autoremove -y
    '
}

configure_journal() {
    local journal_size="200M"
    local keep_free="100M"
    if is_lxc; then
        journal_size="100M"
        keep_free="50M"
    fi
    run_cmd "Configuring journal size limit" bash -c "
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/size-limit.conf <<EOF
[Journal]
SystemMaxUse=$journal_size
SystemKeepFree=$keep_free
MaxFileSec=1month
EOF
    "
}

clear_machine_id() {
    run_cmd "Clearing machine-id for clone uniqueness" bash -c '
    truncate -s 0 /etc/machine-id
    rm -f /var/lib/dbus/machine-id
    ln -sf /etc/machine-id /var/lib/dbus/machine-id
    '
}

# Truncates history files. The calling shell keeps its in-memory history and writes
# it on logout — the caller is told to log out with 'unset HISTFILE; exit'.
clear_history() {
    run_cmd "Clearing shell history files" bash -c '
    for user in root debian; do
        user_home=$(getent passwd "$user" | cut -d: -f6)
        if [[ -n "$user_home" && -f "$user_home/.bash_history" ]]; then
            truncate -s 0 "$user_home/.bash_history"
        fi
    done
    '
}

clear_temp_files() {
    run_cmd "Clearing temporary files" bash -c '
    find /tmp -mindepth 1 -delete 2>/dev/null || true
    find /var/tmp -mindepth 1 -delete 2>/dev/null || true
    '
}

remove_dhcp_leases() {
    run_cmd "Removing DHCP leases" bash -c '
    rm -f /var/lib/dhcp/* 2>/dev/null || true
    rm -f /var/lib/NetworkManager/*.lease 2>/dev/null || true
    '
}

clear_cloud_init() {
    run_cmd "Clearing cloud-init data" bash -c '
    rm -rf /var/lib/cloud/* 2>/dev/null || true
    rm -f /etc/machine-info 2>/dev/null || true
    '
}

############################################################# INIT FUNCTIONS
regenerate_ssh_keys() {
    run_cmd "Removing old SSH host keys" bash -c '
    rm -f /etc/ssh/ssh_host_* || true
    '
    run_cmd "Regenerating SSH host keys" bash -c '
    if command -v dpkg-reconfigure >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive dpkg-reconfigure openssh-server
    else
        ssh-keygen -A
    fi
    '
}

set_hostname() {
    local new_hostname="$1"
    local domain="$2"
    run_cmd "Setting hostname" hostnamectl set-hostname "$new_hostname"
    run_cmd "Updating /etc/hosts" bash -c "
    sed -i '/^127.0.1.1/d' /etc/hosts
    echo -e \"127.0.1.1\t$new_hostname.$domain\t$new_hostname\" >> /etc/hosts
    "
    # Proxmox rewrites these files on every CT start unless told not to
    if is_lxc; then
        run_cmd "Keeping hostname across CT restarts (.pve-ignore)" \
            touch /etc/.pve-ignore.hostname /etc/.pve-ignore.hosts
        log_info "Proxmox UI still shows the old CT name — rename with: pct set <vmid> --hostname $new_hostname"
    fi
}

install_zabbix() {
    local codename="$1"
    local zabbix_address="$2"
    local zabbix_port="$3"
    local hostname="$4"

    rm -f /usr/share/keyrings/zabbix-archive-keyring.gpg   # keyring of the previous version of this function
    add_apt_repo zabbix https://repo.zabbix.com/zabbix/7.0/debian "$codename" main \
        https://repo.zabbix.com/zabbix-official-repo.key || return 1
    run_cmd "Installing Zabbix Agent 2" env DEBIAN_FRONTEND=noninteractive apt-get install -y zabbix-agent2

    run_cmd "Configuring Zabbix Agent" bash -c "
    mkdir -p /var/lib/zabbix
    touch /var/lib/zabbix/zabbix_agent2.db
    chown -R zabbix:zabbix /var/lib/zabbix
    if [[ -f /etc/zabbix/zabbix_agent2.conf ]]; then
        cp /etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agent2.conf.bak
    fi
    cat > /etc/zabbix/zabbix_agent2.conf <<EOF
PidFile=/run/zabbix/zabbix_agent2.pid
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=10
Server=$zabbix_address
ServerActive=$zabbix_address:$zabbix_port
Hostname=$hostname
Include=/etc/zabbix/zabbix_agent2.d/*.conf
ControlSocket=/run/zabbix/agent.sock
EOF
    "
    run_cmd_continue "Enabling Zabbix Agent" systemctl enable zabbix-agent2 || true
}

# install_graylog URL TOKEN "tag1,tag2" y|n(tls_skip_verify)
# Installs/updates, configures and enables (not starts) the sidecar. Safe to re-run.
# Returns 1 on any failure.
install_graylog() {
    local graylog_address="$1"
    local graylog_api_token="$2"
    local tags="$3"
    local tls_skip_verify="${4:-n}"
    local deb="/tmp/graylog-sidecar.deb"

    # Graylog's apt repo (added by older installs) has a SHA1-bound key —
    # Debian 13's apt rejects it and every apt update fails
    if dpkg -s graylog-sidecar-repository &>/dev/null; then
        run_cmd_continue "Removing old Graylog Sidecar apt repository" \
            apt-get purge -y graylog-sidecar-repository || return 1
    fi
    # Same key problem: Graylog server repo written by this function before 2026-10-31
    # (not owned by a package — a graylog-X.Y-repository package on a Graylog server is left alone)
    local old_list=/etc/apt/sources.list.d/graylog.list old_key=/usr/share/keyrings/graylog-archive-keyring.gpg
    if [[ -f "$old_list" ]] && grep -qF "packages.graylog2.org/repo/debian stable" "$old_list" \
            && ! dpkg -S "$old_list" &>/dev/null; then
        rm -f "$old_list"
        dpkg -S "$old_key" &>/dev/null || rm -f "$old_key"
        log_warning "Removed old Graylog apt repository ($old_list) — sidecar now installs from GitHub"
    fi

    if ! command -v curl &>/dev/null; then
        apt_update || return 1
        run_cmd_continue "Installing curl" \
            env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates || return 1
    fi

    # Latest release .deb from GitHub, verified against the release checksums.
    # Graylog's apt repo key has a SHA1 binding signature, which Debian 13's
    # apt (sqv) rejects since 2026-02-01.
    local arch
    arch=$(dpkg --print-architecture)
    [[ "$arch" == "armhf" ]] && arch="armv7"
    if ! run_cmd_continue "Downloading latest Graylog Sidecar ($arch)" bash -c '
    set -eo pipefail
    arch="$1" deb="$2"
    tag=$(curl -fsSLI -o /dev/null -w "%{url_effective}" https://github.com/Graylog2/collector-sidecar/releases/latest)
    tag=${tag##*/}
    base="https://github.com/Graylog2/collector-sidecar/releases/download/$tag"
    file="graylog-sidecar_${tag}-1_${arch}.deb"
    echo "Release: $tag, file: $file"
    curl -fsSL -o "$deb" "$base/$file"
    curl -fsSL "$base/CHECKSUMS-SHA256.txt" | awk -v f="$file" -v d="$deb" '\''$2 == f {print $1 "  " d}'\'' | sha256sum -c -
    ' _ "$arch" "$deb"; then
        rm -f "$deb"
        log_warning "Graylog Sidecar download failed — skipping Graylog installation"
        return 1
    fi

    # sidecar.yml is a conffile and gets rewritten below — keep the old one on upgrade, no prompt
    if ! run_cmd_continue "Installing Graylog Sidecar" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$deb"; then
        rm -f "$deb"
        log_warning "Graylog Sidecar installation failed — skipping configuration"
        return 1
    fi
    rm -f "$deb"

    # tags must be a YAML list: "linux,web" -> ["linux", "web"]
    local tag tags_yaml=""
    local -a tag_list
    IFS=',' read -ra tag_list <<< "$tags"
    for tag in "${tag_list[@]}"; do
        tag="${tag// /}"
        [[ -n "$tag" ]] && tags_yaml+="${tags_yaml:+, }\"$tag\""
    done
    local skip_verify="false"
    [[ "$tls_skip_verify" == "y" ]] && skip_verify="true"

    run_cmd_continue "Configuring Graylog Sidecar" bash -c "
    set -e
    mkdir -p /etc/graylog/sidecar
    if [[ -f /etc/graylog/sidecar/sidecar.yml ]]; then
        cp /etc/graylog/sidecar/sidecar.yml /etc/graylog/sidecar/sidecar.yml.bak
    fi
    cat > /etc/graylog/sidecar/sidecar.yml <<EOF
server_url: \"$graylog_address\"
server_api_token: \"$graylog_api_token\"
node_id: \"file:/etc/graylog/sidecar/node-id\"
node_name: \"\$(hostname)\"
update_interval: 10
tls_skip_verify: $skip_verify
send_status: true
tags: [$tags_yaml]
log_path: \"/var/log/graylog-sidecar\"
EOF
    " || return 1

    # The package ships no systemd unit; 'graylog-sidecar -service install' creates it
    # and fails if it already exists (re-run / upgrade)
    if ! unit_exists graylog-sidecar.service; then
        run_cmd_continue "Installing Graylog Sidecar service" graylog-sidecar -service install || return 1
    fi
    run_cmd_continue "Enabling Graylog Sidecar" systemctl enable graylog-sidecar || return 1
}

# add_nfs_mount "server:/export" /mount/point — fstab entry + mount now.
# A failed mount is not fatal: the entry stays (nofail) and mounts at boot.
add_nfs_mount() {
    local share="$1" mount_point="$2"
    if findmnt --fstab -n "$mount_point" &>/dev/null; then
        log_warning "$mount_point already in /etc/fstab — skipping $share"
        return 0
    fi
    run_cmd "Adding NFS share $share -> $mount_point" bash -c "
    set -e
    mkdir -p '$mount_point'
    echo '$share $mount_point nfs defaults,_netdev,nofail 0 0' >> /etc/fstab
    systemctl daemon-reload
    "
    run_cmd_continue "Mounting $mount_point" mount "$mount_point" \
        || log_warning "Not mounted now (server reachable? exported to this host?) — will mount at boot"
}

# Clone, or fast-forward an existing clone — never deletes it (script may run from there)
clone_bash_scripts() {
    run_cmd "Installing git (if needed)" bash -c '
    if ! command -v git &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y git
    fi
    '
    if [[ -d /home/debian/bash-scripts/.git ]]; then
        run_cmd_continue "Updating bash-scripts repository" \
            sudo -u debian git -C /home/debian/bash-scripts pull --ff-only || true
    else
        run_cmd "Cloning bash-scripts repository" \
            sudo -u debian git clone https://github.com/kamil-lada/bash-scripts.git /home/debian/bash-scripts
    fi
}

start_services() {
    run_cmd "Ensuring SSH is running" systemctl start ssh
    if unit_exists zabbix-agent2.service; then
        run_cmd_continue "Starting Zabbix Agent" systemctl start zabbix-agent2 || true
    fi
    if unit_exists graylog-sidecar.service; then
        run_cmd_continue "Starting Graylog Sidecar" systemctl start graylog-sidecar || true
    fi
    if ! is_lxc && unit_exists qemu-guest-agent.service; then
        run_cmd_continue "Starting QEMU Guest Agent" systemctl start qemu-guest-agent || true
    fi
}

############################################################# VERIFICATION & SUMMARY
# Uses the config globals of 2.initialize_for_usecase.sh:
# INSTANCE_HOSTNAME, INSTALL_ZABBIX, ZABBIX_ADDRESS, ZABBIX_PORT, INSTALL_GRAYLOG, GRAYLOG_ADDRESS
verify_installation() {
    log_section "Verification"
    local -a failures=()

    if [[ -n "${INSTANCE_HOSTNAME:-}" ]]; then
        if [[ "$(hostname)" == "$INSTANCE_HOSTNAME" ]]; then
            log_success "Hostname: OK ($(hostname))"
        else
            log_error "Hostname: MISMATCH (expected $INSTANCE_HOSTNAME, got $(hostname))"
            failures+=("hostname")
        fi
    fi

    if systemctl is-active --quiet ssh; then
        log_success "SSH: Running"
    else
        log_error "SSH: Not running"
        failures+=("ssh")
    fi

    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
        log_success "Time sync: Active"
    else
        log_warning "Time sync: Not active"
    fi

    if ip -4 addr show | grep -q "inet.*global"; then
        log_success "Network: IP assigned"
    else
        log_warning "Network: No IP detected (may be pending restart)"
    fi

    if [[ "${INSTALL_ZABBIX:-n}" == "y" ]]; then
        if systemctl is-active --quiet zabbix-agent2; then
            log_success "Zabbix Agent: Running"
        else
            log_error "Zabbix Agent: Not running"
            failures+=("zabbix")
        fi
    fi

    if [[ "${INSTALL_GRAYLOG:-n}" == "y" ]]; then
        if systemctl is-active --quiet graylog-sidecar; then
            log_success "Graylog Sidecar: Running"
        else
            log_error "Graylog Sidecar: Not running"
            failures+=("graylog")
        fi
    fi

    if (( ${#failures[@]} > 0 )); then
        log_warning "Verification completed with ${#failures[@]} failure(s): ${failures[*]}"
        return 1
    fi
    log_success "All verifications passed"
    return 0
}

show_final_summary() {
    log_section "Installation Summary"
    echo "  Setting                    Value"
    echo "  ─────────────────────────  ────────────────────────────────"

    printf "  %-26s %s\n" "Environment:" "$(is_lxc && echo "LXC Container" || echo "Virtual Machine")"
    printf "  %-26s %s\n" "Hostname:" "$(hostname)"
    printf "  %-26s %s\n" "FQDN:" "$(hostname -f 2>/dev/null || echo 'N/A')"
    printf "  %-26s %s\n" "Timezone:" "$(timedatectl show -p Timezone --value 2>/dev/null || echo 'N/A')"
    printf "  %-26s %s\n" "NTP Sync:" "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo 'N/A')"

    local primary_ip
    primary_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    printf "  %-26s %s\n" "Primary IP:" "${primary_ip:-Not assigned yet}"

    printf "  %-26s %s\n" "SSH:" "Port 22, key-only"

    if [[ "${INSTALL_ZABBIX:-n}" == "y" ]]; then
        printf "  %-26s %s\n" "Zabbix:" "${ZABBIX_ADDRESS:-not configured}:${ZABBIX_PORT:-10051}"
    fi
    if [[ "${INSTALL_GRAYLOG:-n}" == "y" ]]; then
        printf "  %-26s %s\n" "Graylog:" "${GRAYLOG_ADDRESS:-not configured}"
    fi

    echo ""
    echo "  Log file: ${LOGFILE:-N/A}"
    echo "  Config:   ${CONFIG_FILE:-N/A}"
}

############################################################# PROMPTS
# ask "Question" "default" -> echoes answer (default when empty)
ask() {
    local question="$1" default="${2:-}" answer
    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${YELLOW}[?]${NC} $question [$default]: ")" answer
    else
        read -rp "$(echo -e "${YELLOW}[?]${NC} $question: ")" answer
    fi
    echo "${answer:-$default}"
}

# normalize_yn VALUE -> echoes y|n, returns 1 if not a yes/no value
normalize_yn() {
    case "${1,,}" in
        y|yes|true|1)  echo y ;;
        n|no|false|0)  echo n ;;
        *) return 1 ;;
    esac
}

# confirm "Question" [default y|n] -> 0 on yes
confirm() {
    local question="$1" default="${2:-n}" hint answer
    [[ "$default" =~ ^[Yy]$ ]] && hint="Y/n" || hint="y/N"
    while true; do
        read -rp "$(echo -e "${YELLOW}[?]${NC} $question [$hint]: ")" answer
        answer=$(normalize_yn "${answer:-$default}") && break
    done
    [[ "$answer" == "y" ]]
}

# confirm_typed "Question" "WORD" -> 0 only when user types WORD exactly
confirm_typed() {
    local question="$1" word="$2" answer
    read -rp "$(echo -e "${RED}[!]${NC} $question Type '${word}' to continue: ")" answer
    [[ "$answer" == "$word" ]]
}

# get_opt VAR "Question" [default] [validator]
# Uses the config value of VAR when set and valid, otherwise asks. Result stored in VAR.
get_opt() {
    local var="$1" question="$2" default="${3:-}" validator="${4:-}" value
    value="${!var:-}"
    if [[ -n "$value" ]]; then
        if [[ -z "$validator" ]] || "$validator" "$value"; then
            log_info "$question: $value (from config)"
            return 0
        fi
        log_error "Invalid $var in config: '$value'"
    fi
    while true; do
        value=$(ask "$question" "$default")
        if [[ -n "$value" ]] && { [[ -z "$validator" ]] || "$validator" "$value"; }; then
            break
        fi
        log_error "Invalid value: '$value'"
    done
    printf -v "$var" '%s' "$value"
}

# get_yn VAR "Question" [default y|n] — like get_opt for yes/no; VAR becomes y|n
get_yn() {
    local var="$1" question="$2" default="${3:-n}" value
    if [[ -n "${!var:-}" ]]; then
        if value=$(normalize_yn "${!var}"); then
            log_info "$question: $value (from config)"
            printf -v "$var" '%s' "$value"
            return 0
        fi
        log_error "Invalid $var in config: '${!var}'"
    fi
    if confirm "$question" "$default"; then value=y; else value=n; fi
    printf -v "$var" '%s' "$value"
}
