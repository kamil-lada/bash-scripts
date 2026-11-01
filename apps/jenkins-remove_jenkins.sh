#!/bin/bash
# Remove Jenkins installed by jenkins-upsert_all.sh (Java is left installed)

LOG_FILE="/var/log/jenkins_uninstall.log"

# Function to print messages
log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to log failed commands (continues — removal should get as far as possible)
log_error() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - ERROR: $1" | tee -a "$LOG_FILE" >&2
}

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
  log_error "This script must be run as root."
  exit 1
fi

# Set variables (must match jenkins-upsert_all.sh)
JENKINS_USER="jenkins"
JENKINS_WAR_PATH="/opt/jenkins.war"
JENKINS_SERVICE="/etc/systemd/system/jenkins.service"

# Data location: default is the current one (from the service file) or /data/jenkins
CURRENT_HOME=$(sed -n 's/^Environment=JENKINS_HOME=//p' "$JENKINS_SERVICE" 2>/dev/null)
DEFAULT_HOME="${CURRENT_HOME:-/data/jenkins}"
read -rp "Jenkins data location [$DEFAULT_HOME]: " JENKINS_HOME
JENKINS_HOME="${JENKINS_HOME:-$DEFAULT_HOME}"
JENKINS_HOME="${JENKINS_HOME%/}"
case "$JENKINS_HOME" in
  /?*) ;;
  *) log_error "Data location must be an absolute path (not /): '$JENKINS_HOME'"; exit 1 ;;
esac
# Backups next to the data dir: /data/jenkins -> /data/_backup/jenkins_backup
BACKUP_DIR="$(dirname "$JENKINS_HOME")/_backup/jenkins_backup"

read -rp "Remove Jenkins service, WAR file and user? (y/N) " confirm
if [ "$confirm" != "y" ]; then
  echo "Aborted."
  exit 0
fi
read -rp "Also DELETE Jenkins data ($JENKINS_HOME) and WAR backups ($BACKUP_DIR)? (y/N) " delete_data

# Stop Jenkins service
log "Stopping Jenkins service."
systemctl stop jenkins 2>>"$LOG_FILE" || log_error "Failed to stop Jenkins service."

# Disable Jenkins service
log "Disabling Jenkins service."
systemctl disable jenkins 2>>"$LOG_FILE" || log_error "Failed to disable Jenkins service."

# Remove Jenkins service file
log "Removing Jenkins service file."
rm -f "$JENKINS_SERVICE" 2>>"$LOG_FILE" || log_error "Failed to remove Jenkins service file."

# Reload systemd
log "Reloading systemd."
systemctl daemon-reload 2>>"$LOG_FILE" || log_error "Failed to reload systemd daemon."

# Remove Jenkins WAR file
log "Removing Jenkins WAR file."
rm -f "$JENKINS_WAR_PATH" "$JENKINS_WAR_PATH.new" 2>>"$LOG_FILE" || log_error "Failed to remove Jenkins WAR file."

# Remove Jenkins user (home directory only when data deletion was confirmed)
if id "$JENKINS_USER" &>/dev/null; then
  log "Removing Jenkins user."
  userdel "$JENKINS_USER" 2>>"$LOG_FILE" || log_error "Failed to remove Jenkins user."
else
  log "Jenkins user does not exist."
fi

if [ "$delete_data" = "y" ]; then
  log "Removing Jenkins data and backups."
  rm -rf "$JENKINS_HOME" "$BACKUP_DIR" 2>>"$LOG_FILE" || log_error "Failed to remove Jenkins data or backups."
else
  log "Keeping Jenkins data ($JENKINS_HOME) and backups ($BACKUP_DIR)."
fi

log "Jenkins uninstallation script completed."
