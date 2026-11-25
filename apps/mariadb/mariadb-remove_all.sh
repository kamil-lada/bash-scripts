#!/bin/bash

# Stop the MariaDB service
echo "Stopping MariaDB service..."
sudo systemctl stop mariadb

# Uninstall MariaDB and its dependencies
echo "Removing MariaDB packages..."
sudo apt-get purge -y mariadb-server mariadb-client mariadb-common mariadb-server-core-* mariadb-client-core-*

# Remove any remaining MariaDB packages
echo "Removing any remaining MariaDB packages..."
remaining_packages=$(dpkg -l | grep mariadb | awk '{print $2}')
if [ -n "$remaining_packages" ]; then
    sudo apt-get purge -y $remaining_packages
fi

# Remove configuration files and data directories
echo "Removing MariaDB configuration and data directories..."
sudo rm -rf /etc/mysql /var/lib/mysql /var/log/mysql /data/mariadb

# Remove dependencies no longer needed
echo "Removing unnecessary dependencies..."
sudo apt-get autoremove -y

# Clean up the package cache
echo "Cleaning up package cache..."
sudo apt-get clean

echo "MariaDB and all related packages, configurations, and dependencies have been removed."
