#!/bin/bash

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

sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

sudo apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

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
    sudo systemctl stop docker.service docker.socket >/dev/null 2>&1 || true
    sudo mv /var/lib/docker /var/lib/docker.old 2>/dev/null || true
    sudo ln -s "$DATA_ROOT" /var/lib/docker
fi

sudo systemctl start docker
docker run hello-world

if [ "$DATA_ROOT" != "/var/lib/docker" ] && [ $? -eq 0 ]; then
    sudo rm -rf /var/lib/docker.old
    echo "Old Docker data directory removed."
else
    if [ $? -ne 0 ]; then
        echo "Failed to start Docker with the new configuration. Restoring the old configuration."
        if [ "$DATA_ROOT" != "/var/lib/docker" ]; then
            sudo systemctl stop docker
            sudo rm /var/lib/docker
            sudo mv /var/lib/docker.old /var/lib/docker 2>/dev/null || true
            sudo systemctl start docker
        fi
    fi
fi

if id "zabbix" >/dev/null 2>&1; then
    sudo gpasswd -a zabbix docker >/dev/null 2>&1 || true
fi

if [ "$DATA_ROOT" != "/var/lib/docker" ]; then
    if command -v apparmor_parser >/dev/null && [ -d /etc/apparmor.d ]; then
        APPARMOR_PROFILE="/etc/apparmor.d/docker"
        if [ ! -f "$APPARMOR_PROFILE" ]; then
            cat <<'EOF' | sudo tee "$APPARMOR_PROFILE" > /dev/null
# Minimal AppArmor profile for Docker
#include <tunables/global>
/usr/bin/docker {
    capability sys_admin,
    capability sys_module,
    network inet,
    network inet6,
    network unix,
    /var/run/docker.sock r,
    "$DATA_ROOT/**" rw,
}
EOF
            sudo apparmor_parser -r "$APPARMOR_PROFILE" || true
        fi
    fi
fi

echo "Docker and Docker Compose installation and configuration completed."
echo "Please log out and log back in for the group changes to take effect."