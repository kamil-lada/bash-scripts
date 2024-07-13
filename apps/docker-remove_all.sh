#!/bin/bash

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Function to stop Docker containers
stop_containers() {
  sudo docker stop $(sudo docker ps -a -q) >/dev/null 2>&1
}

# Function to remove Docker containers
remove_containers() {
  sudo docker rm -f $(sudo docker ps -a -q) >/dev/null 2>&1
}

# Function to remove Docker images
remove_images() {
  sudo docker rmi -f $(sudo docker images -a -q) >/dev/null 2>&1
}

# Function to uninstall Docker Engine and related packages
uninstall_docker() {
  sudo apt-get purge -y docker-ce docker-ce-cli containerd.io >/dev/null 2>&1
}

# Function to remove Docker configuration files and directories
cleanup_docker_files() {
  sudo rm -rf /etc/docker
  sudo rm -rf /var/lib/docker
  sudo rm -rf ~/.docker
}

# Function to remove Docker group and user
remove_docker_group_user() {
  sudo groupdel docker >/dev/null 2>&1
  sudo userdel -r docker >/dev/null 2>&1
}

# Function to remove Docker and Docker Compose executables
remove_docker_compose() {
  sudo rm -f /usr/local/bin/docker-compose >/dev/null 2>&1
}

# Function to remove Docker Compose configuration files and directories
cleanup_docker_compose_files() {
  sudo rm -rf /etc/docker-compose >/dev/null 2>&1
}

# Function to perform autoremove of dependencies
autoremove_dependencies() {
  sudo apt-get autoremove --purge -y >/dev/null 2>&1
}

# Main script execution

# Stop Docker containers
stop_containers

# Remove Docker containers
remove_containers

# Remove Docker images
remove_images

# Uninstall Docker Engine and related packages
uninstall_docker

# Remove Docker configuration files and directories
cleanup_docker_files

# Remove Docker group and user
remove_docker_group_user

# Remove Docker Compose executable
remove_docker_compose

# Remove Docker Compose configuration files and directories
cleanup_docker_compose_files

# Autoremove dependencies
autoremove_dependencies

echo "Docker and Docker Compose have been uninstalled and cleaned up."