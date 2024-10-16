#!/bin/bash

LOG_FILE="/var/log/jenkins_install.log"

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
JENKINS_WAR_URL="https://get.jenkins.io/war-stable/latest/jenkins.war"
JENKINS_WAR_PATH="/opt/jenkins.war"
JENKINS_SERVICE="/etc/systemd/system/jenkins.service"
JENKINS_PORT=8080

# Check if /data directory exists, create if not
if [ ! -d "$JENKINS_HOME" ]; then
  log "Creating $JENKINS_HOME directory."
  mkdir -p "$JENKINS_HOME" 2>>"$LOG_FILE" || log_error "Failed to create $JENKINS_HOME directory."
fi

# Check if jenkins user exists, create if not
if id "$JENKINS_USER" &>/dev/null; then
  log "User $JENKINS_USER already exists."
else
  log "Creating user $JENKINS_USER."
  useradd -d "$JENKINS_HOME" -s /bin/bash "$JENKINS_USER" 2>>"$LOG_FILE" || log_error "Failed to create user $JENKINS_USER."
fi

# Set ownership and permissions for /data
log "Setting ownership and permissions for $JENKINS_HOME."
chown -R "$JENKINS_USER":"$JENKINS_USER" "$JENKINS_HOME" 2>>"$LOG_FILE" || log_error "Failed to set ownership and permissions for $JENKINS_HOME."
chmod -R 755 "$JENKINS_HOME" 2>>"$LOG_FILE" || log_error "Failed to set permissions for $JENKINS_HOME."

# Install Java (required for Jenkins)
log "Installing Java."
{
  apt-get update && apt-get install -y openjdk-17-jdk
} 2>>"$LOG_FILE" || log_error "Failed to install Java. Check $LOG_FILE for details."

# Function to backup the current Jenkins WAR file
backup_war_file() {
  local backup_dir="/data/_backup/jenkins_backup"
  local timestamp=$(date +'%Y%m%d%H%M%S')
  local backup_file="$backup_dir/jenkins_$timestamp.war"

  mkdir -p "$backup_dir" 2>>"$LOG_FILE" || log_error "Failed to create backup directory $backup_dir."
  log "Backing up current Jenkins WAR file to $backup_file."
  cp "$JENKINS_WAR_PATH" "$backup_file" 2>>"$LOG_FILE" || log_error "Failed to backup Jenkins WAR file."
}

# Download the latest Jenkins WAR file
log "Checking for the latest Jenkins WAR file."
wget -q --spider "$JENKINS_WAR_URL" 2>>"$LOG_FILE"
if [ $? -eq 0 ]; then
  if [ -f "$JENKINS_WAR_PATH" ]; then
    log "Jenkins WAR file already exists. Checking for updates."
    NEW_WAR_HASH=$(curl -sL "$JENKINS_WAR_URL" | sha256sum | awk '{ print $1 }')
    CURRENT_WAR_HASH=$(sha256sum "$JENKINS_WAR_PATH" | awk '{ print $1 }')
    if [ "$NEW_WAR_HASH" != "$CURRENT_WAR_HASH" ]; then
      read -p "A newer version of the Jenkins WAR file is available. Do you want to update? (y/n) " choice
      if [ "$choice" = "y" ]; then
        log "Stopping Jenkins service."
        systemctl stop jenkins 2>>"$LOG_FILE" || log_error "Failed to stop Jenkins service."
        backup_war_file
        log "Downloading the latest Jenkins WAR file."
        wget -O "$JENKINS_WAR_PATH" "$JENKINS_WAR_URL" 2>>"$LOG_FILE" || log_error "Failed to download Jenkins WAR file."
        log "Starting Jenkins service."
        systemctl start jenkins 2>>"$LOG_FILE" || log_error "Failed to start Jenkins service."
      fi
    else
      log "The Jenkins WAR file is up to date."
    fi
  else
    log "Downloading the Jenkins WAR file."
    wget -O "$JENKINS_WAR_PATH" "$JENKINS_WAR_URL" 2>>"$LOG_FILE" || log_error "Failed to download Jenkins WAR file."
  fi
else
  log_error "Failed to access the Jenkins WAR URL."
  exit 1
fi

# Create Jenkins service file if it doesn't exist
if [ ! -f "$JENKINS_SERVICE" ]; then
  log "Creating Jenkins service file."
  cat <<EOF >"$JENKINS_SERVICE"
[Unit]
Description=Jenkins Daemon

[Service]
ExecStart=/usr/bin/java -jar $JENKINS_WAR_PATH --httpPort=$JENKINS_PORT --prefix=/jenkins
User=$JENKINS_USER
Environment=JENKINS_HOME=$JENKINS_HOME
TimeoutStopSec=900

[Install]
WantedBy=multi-user.target
EOF
else
  log "Jenkins service file already exists. Checking timeout setting."
  if grep -q "TimeoutStopSec" "$JENKINS_SERVICE"; then
    log "Removing existing TimeoutStopSec setting."
    sed -i '/TimeoutStopSec/d' "$JENKINS_SERVICE" 2>>"$LOG_FILE" || log_error "Failed to remove existing TimeoutStopSec setting."
  fi
  log "Setting TimeoutStopSec=900 in Jenkins service file."
  sed -i '/\[Service\]/a TimeoutStopSec=900' "$JENKINS_SERVICE" 2>>"$LOG_FILE" || log_error "Failed to set TimeoutStopSec=900."
fi

# Reload systemd and start Jenkins service
log "Reloading systemd and starting Jenkins service."
systemctl daemon-reload 2>>"$LOG_FILE" || log_error "Failed to reload systemd daemon."
systemctl enable jenkins 2>>"$LOG_FILE" || log_error "Failed to enable Jenkins service."
systemctl restart jenkins 2>>"$LOG_FILE" || log_error "Failed to restart Jenkins service."

# Extract the initial admin password
log "Extracting the initial admin password."
while [ ! -f "$JENKINS_HOME/secrets/initialAdminPassword" ]; do
  log "Waiting for Jenkins to generate the initial admin password..."
  sleep 5
done

INITIAL_ADMIN_PASSWORD=$(cat "$JENKINS_HOME/secrets/initialAdminPassword" 2>>"$LOG_FILE")
if [ -n "$INITIAL_ADMIN_PASSWORD" ]; then
  log "Jenkins is set up successfully. The initial admin password is:"
  echo "$INITIAL_ADMIN_PASSWORD" | tee -a "$LOG_FILE"
else
  log_error "Failed to extract the initial admin password. Please check the Jenkins logs."
fi

# Set up passwordless login for Jenkins user
log "Setting up passwordless login for Jenkins user."
sudo passwd -d jenkins >/dev/null 2>&1 || log_error "Failed to set passwordless login for Jenkins user."

log "Jenkins setup script completed."
