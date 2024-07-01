#!/bin/bash

# Stop and remove Docker containers
sudo docker stop $(sudo docker ps -a -q)
sudo docker rm $(sudo docker ps -a -q)

# Remove Docker images
sudo docker rmi $(sudo docker images -a -q)

# Uninstall Docker Engine
sudo apt-get purge docker-ce docker-ce-cli containerd.io

# Remove Docker configuration files
sudo rm -rf /etc/docker
sudo rm -rf /var/lib/docker
sudo rm -rf ~/.docker

# Remove Docker Compose (if installed)
sudo rm /usr/local/bin/docker-compose
sudo rm -rf /etc/docker-compose

# Autoremove dependencies (optional)
sudo apt-get autoremove --purge

echo "Docker and Docker Compose have been uninstalled."
