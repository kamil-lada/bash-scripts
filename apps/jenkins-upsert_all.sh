#!/bin/bash
# Install or update Jenkins (WAR + systemd service) on Debian 12/13

LOG_FILE="/var/log/jenkins_install.log"

# Function to print messages
log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to log an error and stop
log_error() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - ERROR: $1" | tee -a "$LOG_FILE" >&2
  exit 1
}

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
  log_error "This script must be run as root."
fi

# Set variables
JENKINS_USER="jenkins"
JENKINS_WAR_URL="https://get.jenkins.io/war-stable/latest/jenkins.war"
JENKINS_WAR_PATH="/opt/jenkins.war"
JENKINS_SERVICE="/etc/systemd/system/jenkins.service"
JENKINS_PORT=8080

# Data location: default is the current one (from the service file) or /data/jenkins
CURRENT_HOME=$(sed -n 's/^Environment=JENKINS_HOME=//p' "$JENKINS_SERVICE" 2>/dev/null)
DEFAULT_HOME="${CURRENT_HOME:-/data/jenkins}"
read -rp "Jenkins data location [$DEFAULT_HOME]: " JENKINS_HOME
JENKINS_HOME="${JENKINS_HOME:-$DEFAULT_HOME}"
JENKINS_HOME="${JENKINS_HOME%/}"
case "$JENKINS_HOME" in
  /?*) ;;
  *) log_error "Data location must be an absolute path (not /): '$JENKINS_HOME'" ;;
esac
# Backups next to the data dir: /data/jenkins -> /data/_backup/jenkins_backup
BACKUP_DIR="$(dirname "$JENKINS_HOME")/_backup/jenkins_backup"
if [ -n "$CURRENT_HOME" ] && [ "$CURRENT_HOME" != "$JENKINS_HOME" ]; then
  log "WARNING: Jenkins currently uses $CURRENT_HOME — its data is NOT moved to $JENKINS_HOME."
fi

RESTART_NEEDED="n"
# Fresh = Jenkins never ran on this home (reinstall over kept data is not fresh)
FRESH_INSTALL="n"
[ -f "$JENKINS_HOME/config.xml" ] || FRESH_INSTALL="y"

# Check if Jenkins home exists, create if not
if [ ! -d "$JENKINS_HOME" ]; then
  log "Creating $JENKINS_HOME directory."
  mkdir -p "$JENKINS_HOME" 2>>"$LOG_FILE" || log_error "Failed to create $JENKINS_HOME directory."
fi

# Check if jenkins user exists, create if not
if id "$JENKINS_USER" &>/dev/null; then
  log "User $JENKINS_USER already exists."
  if [ "$(getent passwd "$JENKINS_USER" | cut -d: -f6)" != "$JENKINS_HOME" ]; then
    usermod -d "$JENKINS_HOME" "$JENKINS_USER" 2>>"$LOG_FILE" || log_error "Failed to set home of $JENKINS_USER to $JENKINS_HOME."
  fi
else
  log "Creating user $JENKINS_USER."
  useradd -d "$JENKINS_HOME" -s /bin/bash "$JENKINS_USER" 2>>"$LOG_FILE" || log_error "Failed to create user $JENKINS_USER."
fi

# Ownership for everything, but only the top directory gets 750 —
# Jenkins manages permissions inside (secrets/ must not be world-readable)
log "Setting ownership and permissions for $JENKINS_HOME."
chown -R "$JENKINS_USER":"$JENKINS_USER" "$JENKINS_HOME" 2>>"$LOG_FILE" || log_error "Failed to set ownership for $JENKINS_HOME."
chmod 750 "$JENKINS_HOME" 2>>"$LOG_FILE" || log_error "Failed to set permissions for $JENKINS_HOME."

# Install Java 21 (required by current Jenkins LTS)
# Debian 13 ships openjdk-21, Debian 12 only 17 -> use Adoptium Temurin there
log "Installing Java 21."
apt-get update >>"$LOG_FILE" 2>&1 || log_error "apt-get update failed."
# (apt-cache show succeeds even for packages without an installable version)
if apt-cache policy openjdk-21-jre-headless | grep -q "Candidate: [0-9]"; then
  JAVA_PKG="openjdk-21-jre-headless"
else
  log "openjdk-21 not available in this Debian release, adding Adoptium repository."
  {
    apt-get install -y wget gpg &&
    wget -qO- https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor --yes -o /usr/share/keyrings/adoptium.gpg &&
    echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo "$VERSION_CODENAME") main" > /etc/apt/sources.list.d/adoptium.list &&
    apt-get update
  } >>"$LOG_FILE" 2>&1 || log_error "Failed to add Adoptium repository."
  JAVA_PKG="temurin-21-jre"
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y "$JAVA_PKG" fontconfig wget >>"$LOG_FILE" 2>&1 || log_error "Failed to install $JAVA_PKG."

# Use the Java 21 binary explicitly (an older default java may still be installed)
JAVA_BIN=$(update-alternatives --list java 2>/dev/null | grep -m1 -- "-21")
[ -x "$JAVA_BIN" ] || log_error "Java 21 binary not found after installing $JAVA_PKG."
log "Using Java: $JAVA_BIN"

# Function to backup the current Jenkins WAR file
backup_war_file() {
  local backup_file="$BACKUP_DIR/jenkins_$(date +'%Y%m%d%H%M%S').war"
  mkdir -p "$BACKUP_DIR" 2>>"$LOG_FILE" || log_error "Failed to create backup directory $BACKUP_DIR."
  log "Backing up current Jenkins WAR file to $backup_file."
  cp "$JENKINS_WAR_PATH" "$backup_file" 2>>"$LOG_FILE" || log_error "Failed to backup Jenkins WAR file."
}

# Download the WAR to a temp file and verify it — the live WAR is only replaced on success
download_war() {
  local tmp="$JENKINS_WAR_PATH.new"
  log "Downloading the latest Jenkins WAR file."
  wget -qO "$tmp" "$JENKINS_WAR_URL" 2>>"$LOG_FILE" || { rm -f "$tmp"; log_error "Failed to download Jenkins WAR file."; }
  if [ "$(sha256sum "$tmp" | awk '{ print $1 }')" != "$NEW_WAR_HASH" ]; then
    rm -f "$tmp"
    log_error "Downloaded WAR checksum does not match."
  fi
  mv "$tmp" "$JENKINS_WAR_PATH" || log_error "Failed to install Jenkins WAR file."
}

# Compare with the published checksum instead of downloading the whole WAR
log "Checking for the latest Jenkins WAR file."
NEW_WAR_HASH=$(wget -qO- "$JENKINS_WAR_URL.sha256" 2>>"$LOG_FILE" | awk '{ print $1 }')
[ -n "$NEW_WAR_HASH" ] || log_error "Failed to access the Jenkins WAR checksum URL."

if [ -f "$JENKINS_WAR_PATH" ]; then
  CURRENT_WAR_HASH=$(sha256sum "$JENKINS_WAR_PATH" | awk '{ print $1 }')
  if [ "$NEW_WAR_HASH" != "$CURRENT_WAR_HASH" ]; then
    read -rp "A newer version of the Jenkins WAR file is available. Do you want to update? (y/n) " choice
    if [ "$choice" = "y" ]; then
      backup_war_file
      download_war
      RESTART_NEEDED="y"
    fi
  else
    log "The Jenkins WAR file is up to date."
  fi
else
  download_war
  RESTART_NEEDED="y"
fi

# Service file is always (re)written, restart only if it changed
log "Writing Jenkins service file."
NEW_SERVICE=$(cat <<EOF
[Unit]
Description=Jenkins Daemon
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$JAVA_BIN -jar $JENKINS_WAR_PATH --httpPort=$JENKINS_PORT --prefix=/jenkins
User=$JENKINS_USER
Environment=JENKINS_HOME=$JENKINS_HOME
TimeoutStopSec=900

[Install]
WantedBy=multi-user.target
EOF
)
if [ "$NEW_SERVICE" != "$(cat "$JENKINS_SERVICE" 2>/dev/null)" ]; then
  echo "$NEW_SERVICE" > "$JENKINS_SERVICE" || log_error "Failed to write $JENKINS_SERVICE."
  RESTART_NEEDED="y"
fi

log "Reloading systemd and enabling Jenkins service."
systemctl daemon-reload 2>>"$LOG_FILE" || log_error "Failed to reload systemd daemon."
systemctl enable jenkins 2>>"$LOG_FILE" || log_error "Failed to enable Jenkins service."

if [ "$RESTART_NEEDED" = "y" ] || ! systemctl is-active --quiet jenkins; then
  log "Restarting Jenkins service."
  systemctl restart jenkins 2>>"$LOG_FILE" || log_error "Failed to restart Jenkins service."
else
  log "No changes, Jenkins keeps running."
fi

# Initial admin password exists only until the setup wizard is completed
if [ "$FRESH_INSTALL" = "y" ]; then
  log "Waiting for Jenkins to generate the initial admin password..."
  for _ in $(seq 1 36); do
    [ -f "$JENKINS_HOME/secrets/initialAdminPassword" ] && break
    systemctl is-active --quiet jenkins || log_error "Jenkins service is not running. Check: journalctl -u jenkins"
    sleep 5
  done
  if [ -f "$JENKINS_HOME/secrets/initialAdminPassword" ]; then
    log "Jenkins is set up successfully. The initial admin password is:"
    cat "$JENKINS_HOME/secrets/initialAdminPassword"
  else
    log_error "Initial admin password not generated after 3 minutes. Check: journalctl -u jenkins"
  fi
fi

log "Jenkins setup script completed. URL: http://$(hostname -I | awk '{print $1}'):$JENKINS_PORT/jenkins"
