#!/bin/bash
set -euo pipefail

# Root check
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (or with sudo). Exiting."
    exit 1
fi

# Exit if run as the default 'debian' user
if [ "$(whoami)" = "debian" ]; then
    echo "This script should not be run as the default 'debian' user. Exiting."
    exit 1
fi

read -rp "Do you want to use a custom Docker data location? (y/n) " use_custom
if [[ "$use_custom" =~ ^[Yy]$ ]]; then
    read -rp "Enter the path for Docker data (default: /data/docker): " custom_path
    if [ -n "$custom_path" ]; then
        DATA_ROOT="$custom_path"
    else
        DATA_ROOT="/data/docker"
    fi
else
    DATA_ROOT="/var/lib/docker"
fi

sudo apt-get update >/dev/null && echo "apt-get update ok" || echo "apt-get update fail"
sudo apt-get install -y ca-certificates curl >/dev/null && echo "install ca-certificates curl ok" || echo "install ca-certificates curl fail"
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && echo "download docker gpg ok" || { echo "download docker gpg fail"; exit 1; }
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update >/dev/null && echo "apt-get update (docker repo) ok" || echo "apt-get update (docker repo) fail"

sudo apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin >/dev/null && echo "install docker packages ok" || echo "install docker packages fail"

sudo mkdir -p /etc/docker
cat <<EOF | sudo tee /etc/docker/daemon.json > /dev/null
{
  "data-root": "$DATA_ROOT",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "5"
  }
}
EOF


if [ "$DATA_ROOT" != "/var/lib/docker" ]; then
    sudo systemctl stop docker.service docker.socket || true
    # handle re-run: if /var/lib/docker is a symlink, remove it; if directory, move it
    if [ -L /var/lib/docker ]; then
        sudo rm /var/lib/docker && echo "removed existing symlink /var/lib/docker ok" || echo "remove symlink fail"
    elif [ -d /var/lib/docker ]; then
        sudo mv /var/lib/docker /var/lib/docker.old && echo "moved /var/lib/docker to .old ok" || echo "move to .old fail"
    fi
    sudo ln -s "$DATA_ROOT" /var/lib/docker && echo "created symlink /var/lib/docker -> $DATA_ROOT ok" || echo "create symlink fail"
fi

sudo systemctl start docker >/dev/null && echo "systemctl start docker ok" || echo "systemctl start docker fail"
docker run hello-world >/dev/null
DOCKER_EXIT=$?

if [ "$DATA_ROOT" != "/var/lib/docker" ] && [ $DOCKER_EXIT -eq 0 ]; then
    sudo rm -rf /var/lib/docker.old && echo "removed /var/lib/docker.old ok" || echo "remove .old fail"
    echo "Old Docker data directory removed."
else
    if [ $DOCKER_EXIT -ne 0 ]; then
        echo "Failed to start Docker with the new configuration. Restoring the old configuration."
        if [ "$DATA_ROOT" != "/var/lib/docker" ]; then
            sudo systemctl stop docker || true
            sudo rm /var/lib/docker && echo "removed symlink ok" || echo "remove symlink fail"
            sudo mv /var/lib/docker.old /var/lib/docker && echo "restored /var/lib/docker.old ok" || echo "restore .old fail"
            sudo systemctl start docker && echo "systemctl start docker (restored) ok" || echo "systemctl start docker (restored) fail"
        fi
    fi
fi

if id "zabbix" >/dev/null 2>&1; then
    sudo gpasswd -a zabbix docker && echo "added zabbix to docker group ok" || echo "add zabbix to docker group fail"
fi

echo "Docker and Docker Compose installation and configuration completed."
echo "Please log out and log back in for the group changes to take effect."
