#!/bin/bash

LOG_FILE="/var/log/jenkins_uninstall.log"

# Function to print messages
log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to log failed commands
log_error() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2 | tee -a "$LOG_FILE"
}

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
  log_error "This script must be run as root."
  exit 1
fi

# Set variables
JENKINS_USER="jenkins"
JENKINS_HOME="/data/jenkins"
JENKINS_WAR_PATH="/opt/jenkins.war"
JENKINS_SERVICE="/etc/systemd/system/jenkins.service"
BACKUP_DIR="/opt/jenkins_backup"

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
rm -f "$JENKINS_WAR_PATH" 2>>"$LOG_FILE" || log_error "Failed to remove Jenkins WAR file."

# Remove Jenkins user and home directory
if id "$JENKINS_USER" &>/dev/null; then
  log "Removing Jenkins user and home directory."
  userdel -r "$JENKINS_USER" 2>>"$LOG_FILE" || log_error "Failed to remove Jenkins user and home directory."
else
  log "Jenkins user does not exist."
fi

# Remove backup directory
log "Removing backup directory."
rm -rf "$BACKUP_DIR" 2>>"$LOG_FILE" || log_error "Failed to remove backup directory."

log "Jenkins uninstallation script completed."
