#!/bin/bash

# Prompt for PostgreSQL version
read -p "Enter PostgreSQL version to remove (e.g., 14): " psql_version

# Stop PostgreSQL service
echo "Stopping PostgreSQL service..."
sudo systemctl stop postgresql

# Uninstall PostgreSQL packages
echo "Removing PostgreSQL packages..."
sudo apt-get --purge remove -y postgresql-$psql_version postgresql-contrib postgresql-client-common postgresql-common

# Remove remaining configuration files, logs, and data directories
echo "Removing PostgreSQL configuration files, logs, and data directories..."
sudo rm -rf /etc/postgresql /etc/postgresql-common /var/lib/postgresql /var/log/postgresql /var/run/postgresql

# Optionally remove custom data directories (e.g., if data was stored under /data or another custom path)
read -p "Do you want to remove custom data directories (e.g., /data)? (y/n): " remove_data_choice
if [[ "$remove_data_choice" == "y" ]]; then
    read -p "Enter the custom data directory path to remove: " custom_data_path
    if [[ -d "$custom_data_path" ]]; then
        sudo rm -rf "$custom_data_path"
        echo "Custom data directory removed."
    else
        echo "Custom data directory not found."
    fi
fi

# Remove PostgreSQL user and group
echo "Removing PostgreSQL system user and group..."
sudo deluser --remove-home postgres
sudo delgroup postgres

# Clean apt cache and dependencies
echo "Cleaning up apt..."
sudo apt-get autoremove -y
sudo apt-get autoclean

# Check for any remaining traces of PostgreSQL
echo "Searching for any remaining PostgreSQL traces..."
if dpkg -l | grep -q postgresql; then
    echo "Some PostgreSQL components might still be installed. You may need to manually review them."
else
    echo "PostgreSQL and its components have been removed successfully."
fi

echo "PostgreSQL removal process complete."
