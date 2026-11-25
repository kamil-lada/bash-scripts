#!/bin/bash

# Function to log errors
log_error() {
    echo "[ERROR] $1" >&2
}

# Step 1: Ask for confirmation before proceeding
read -p "Are you sure you want to remove MongoDB and all its data? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
    echo "Aborting MongoDB removal."
    exit 0
fi

# Step 2: Stop MongoDB service
echo "Stopping MongoDB service..."
systemctl stop mongod || log_error "Failed to stop MongoDB service"

# Step 3: Check for custom MongoDB data path from config file
if [ -f /etc/mongod.conf ]; then
    custom_db_path=$(grep "^ *dbPath:" /etc/mongod.conf | awk '{print $2}')
    if [ -z "$custom_db_path" ]; then
        custom_db_path="/var/lib/mongodb"  # Fallback to default path
    fi
else
    custom_db_path="/var/lib/mongodb"
fi

# Step 4: Remove MongoDB packages and dependencies
echo "Removing MongoDB packages..."
apt-get purge -qq mongodb-org* || log_error "Failed to purge MongoDB packages"
apt-get autoremove -qq || log_error "Failed to remove unused dependencies"

# Step 5: Remove MongoDB data directory (including custom path)
echo "Removing MongoDB data directory..."
sudo rm -rf "$custom_db_path" || log_error "Failed to remove MongoDB data directory at $custom_db_path"

# Step 6: Remove MongoDB log directory
echo "Removing MongoDB log directory..."
sudo rm -rf /var/log/mongodb || log_error "Failed to remove MongoDB log directory"

# Step 7: Remove MongoDB config file
echo "Removing MongoDB config file..."
rm -rf /etc/mongod.conf || log_error "Failed to remove MongoDB configuration file"

# Step 8: Remove MongoDB repository list and GPG key
echo "Removing MongoDB repository and GPG key..."
rm -f /etc/apt/sources.list.d/mongodb-org-6.0.list || log_error "Failed to remove MongoDB repository list"
rm -f /usr/share/keyrings/mongodb-server-6.0.gpg || log_error "Failed to remove MongoDB GPG key"
rm -f /tmp/mongodb-27017.sock || log_error "Failed to remove socket file"

# Final clean-up
echo "Performing final clean-up..."
apt-get update -qq || log_error "Failed to update package list"

echo "MongoDB and its data have been successfully removed."