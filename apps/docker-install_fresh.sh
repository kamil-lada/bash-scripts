#!/bin/bash

# Update package index
sudo apt-get update

# Install Docker packages
sudo apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# Create Docker group and add the current user to it
sudo groupadd docker >/dev/null 2>&1 || true
sudo usermod -aG docker debian

# Apply group changes immediately
# No need for `newgrp docker` here

# Configure Docker to use custom data directory
# Ensure the custom directory exists and has proper permissions
sudo mkdir -p /data/docker
sudo chown root:docker /data/docker
sudo chmod 770 /data/docker

# Stop Docker service before making changes
sudo systemctl stop docker

# Backup the current Docker data directory
sudo mv /var/lib/docker /var/lib/docker.old

# Create a symbolic link from the custom directory to the default Docker data directory
sudo ln -s /data/docker /var/lib/docker

# Start Docker service to apply changes
sudo systemctl start docker

# Test Docker installation
docker run hello-world

# Clean up the backup if everything works correctly
if [ $? -eq 0 ]; then
    sudo rm -rf /var/lib/docker.old
    echo "Old Docker data directory removed."
else
    echo "Failed to start Docker with the new configuration. Restoring the old configuration."
    sudo systemctl stop docker
    sudo rm /var/lib/docker
    sudo mv /var/lib/docker.old /var/lib/docker
    sudo systemctl start docker
fi

echo "Docker and Docker Compose installation and configuration completed."
echo "Please log out and log back in for the group changes to take effect."
