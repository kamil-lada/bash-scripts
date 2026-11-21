#!/bin/bash
# jenkins-worker — prepare a Debian 13 LXC/VM as an SSH build agent. The controller connects to it
# via SSH (SSH Build Agents): nothing Jenkins-specific runs or is installed as a service here.
#
# Usage (the exact command is printed by jenkins-controller.sh):
#   jenkins-worker.sh [--java 25] --key '<controller agent public key>' --dir <agent folder> [--user jenkins]
#
# --java: Java major of the controller image (default 25). Several versions can live side by side
# (one worker, two controllers); the node's Java path in Jenkins picks the one used.
#
# Installs openjdk-<java>-jre-headless, git, openssh-server (only if missing), creates the user and
# the agent folder if missing, adds the key to authorized_keys and github.com to known_hosts only
# if not present. Safe to re-run with the same or another controller's key. Never deletes anything.
#
# Standalone: needs only bash + apt (Debian 13).
set -Eeuo pipefail


info() { echo "[→] $*"; }
ok()   { echo "[✓] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[✗] $*" >&2; exit 1; }
usage() { sed -n '/^# Usage/,/^#   jenkins-worker/s/^# \{0,1\}//p' "$0"; }

# Prints github.com known_hosts lines from ssh-keyscan, verified against GitHub's published fingerprints
github_known_hosts() {
    local meta scan line fp out=""
    meta=$(curl -fsS --max-time 20 https://api.github.com/meta) || die "Cannot fetch https://api.github.com/meta"
    scan=$(ssh-keyscan -T 10 -t ed25519,ecdsa,rsa github.com 2>/dev/null) || true
    [[ -n $scan ]] || die "ssh-keyscan github.com returned nothing"
    while read -r line; do
        [[ $line == "github.com "* ]] || continue
        fp=$(ssh-keygen -lf - <<< "$line" | awk '{print $2}')
        grep -qF "\"${fp#SHA256:}\"" <<< "$meta" || die "github.com host key $fp does not match GitHub's published fingerprints"
        out+="$line"$'\n'
    done <<< "$scan"
    printf '%s' "$out"
}

KEY="" DIR="" USER_NAME=jenkins JAVA_MAJOR=25
while (( $# > 0 )); do
    case "$1" in
        --key)  KEY="${2:-}"; shift ;;
        --dir)  DIR="${2:-}"; shift ;;
        --java) JAVA_MAJOR="${2:-}"; shift ;;
        --user) USER_NAME="${2:-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown argument: $1" ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] || die "Run as root"
[[ $KEY =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)\ [A-Za-z0-9+/=]+(\ .*)?$ ]] || { usage >&2; die "--key: not an SSH public key"; }
[[ $DIR =~ ^/[A-Za-z0-9._/-]+$ ]] || { usage >&2; die "--dir: absolute path required"; }
[[ $USER_NAME =~ ^[a-z_][a-z0-9_-]*$ ]] || die "--user: invalid user name"
[[ $JAVA_MAJOR =~ ^[0-9]+$ ]] && (( JAVA_MAJOR >= 21 )) || die "--java: 21 or newer required"
PACKAGES=("openjdk-$JAVA_MAJOR-jre-headless" git openssh-server curl ca-certificates)
EXPECTED_JAVA=/usr/lib/jvm/java-$JAVA_MAJOR-openjdk-amd64/bin/java   # javaPath set by the controller
# shellcheck source=/dev/null
. /etc/os-release
[[ ${VERSION_ID:-} == 13 ]] || warn "Expected Debian 13, found ${PRETTY_NAME:-unknown} — continuing"

# --- packages (apt only when something is missing, so a re-run changes nothing)
missing=()
for p in "${PACKAGES[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
done
if (( ${#missing[@]} )); then
    info "Installing: ${missing[*]}"
    apt-get update -q >/dev/null || die "apt-get update failed"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${missing[@]}" >/dev/null \
        || die "apt-get install failed (missing package? openjdk-$JAVA_MAJOR needs trixie or trixie-security)"
    ok "Packages installed"
else
    ok "Packages already installed"
fi

# --- sshd running and enabled
if [[ -d /run/systemd/system ]]; then
    systemctl is-enabled --quiet ssh 2>/dev/null && systemctl is-active --quiet ssh || systemctl enable --now ssh
    ok "sshd enabled and running"
else
    pgrep -x sshd >/dev/null || warn "No systemd and sshd is not running — start it yourself"
fi

# --- user
if id "$USER_NAME" &>/dev/null; then
    ok "User $USER_NAME exists"
else
    useradd -m -s /bin/bash "$USER_NAME"
    ok "User $USER_NAME created (password locked, SSH key login only)"
fi
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
GROUP=$(id -gn "$USER_NAME")
install -d -m 700 -o "$USER_NAME" -g "$GROUP" "$HOME_DIR/.ssh"

# --- authorized_keys: compare type + key blob, ignore the comment
AK="$HOME_DIR/.ssh/authorized_keys"
[[ -f $AK ]] || install -m 600 -o "$USER_NAME" -g "$GROUP" /dev/null "$AK"
read -r ktype kblob _ <<< "$KEY"
if grep -qF "$ktype $kblob" "$AK"; then
    ok "Key already in $AK"
else
    echo "$KEY" >> "$AK"
    ok "Key added to $AK"
fi

# --- github.com in known_hosts (used by 'checkout scm' on this agent)
KH="$HOME_DIR/.ssh/known_hosts"
if [[ -f $KH ]] && ssh-keygen -F github.com -f "$KH" >/dev/null; then
    ok "github.com already in $KH"
else
    lines=$(github_known_hosts)
    printf '%s' "$lines" >> "$KH"
    chown "$USER_NAME:$GROUP" "$KH"; chmod 644 "$KH"
    ok "github.com added to $KH (fingerprints verified against api.github.com/meta)"
fi

# --- agent folder
if [[ -d $DIR ]]; then
    owner=$(stat -c %U "$DIR")
    [[ $owner == "$USER_NAME" ]] && ok "Agent folder $DIR exists" || warn "Agent folder $DIR exists but is owned by $owner"
else
    install -d -m 755 -o "$USER_NAME" -g "$GROUP" "$DIR"
    ok "Agent folder $DIR created"
fi

# --- summary
echo
echo "Worker ready — the controller connects by itself (retries every few minutes)"
echo "  User:          $USER_NAME ($HOME_DIR), $(grep -c . "$AK") authorized key(s)"
echo "  Agent folder:  $DIR"
if [[ -x $EXPECTED_JAVA ]]; then
    echo "  Java:          $("$EXPECTED_JAVA" -version 2>&1 | head -1)"
    echo "  Java path:     $EXPECTED_JAVA (as configured on the controller)"
else
    warn "Java path:     $EXPECTED_JAVA missing — fix the node's Java path in Jenkins"
fi
echo "  Host keys (informational — the controller trusts the key on first connect):"
for k in /etc/ssh/ssh_host_*_key.pub; do
    [[ -f $k ]] && echo "    $(ssh-keygen -lf "$k")"
done
