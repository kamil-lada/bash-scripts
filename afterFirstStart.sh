#!/bin/bash

set -e

log() {
    echo "[INFO] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

####################################################################  START

# Prompt the user for a hostname
read -p "Please enter the new hostname: " new_hostname

# Check if the input is not empty
if [ -z "$new_hostname" ]; then
  error "Hostname cannot be empty. Exiting."
  exit 1
fi


MACHINE_ID_FILE="/etc/machine-id"

# Check if the machine-id file exists and is not empty
if [ -s "$MACHINE_ID_FILE" ]; then
    echo "machine-id is set."
else
    echo "machine-id is empty or not set. Generating a new machine-id..."
    
    # Generate a new machine-id
    sudo systemd-machine-id-setup > /dev/null 2>&1
    # Restart the D-Bus service
    sudo systemctl restart dbus > /dev/null 2>&1
    
    # Verify if the machine-id was successfully generated
    if [ -s "$MACHINE_ID_FILE" ]; then
        echo "New machine-id has been generated successfully."
    else
        echo "Failed to generate a new machine-id."
        exit 1
    fi
fi


# Display the new machine-id
log "The new machine-id is: $(cat /etc/machine-id)"


log "Removing SSH host keys..."
rm -f /etc/ssh/ssh_host_* || error "Failed to remove SSH host keys."
# Generate SSH host keys if they do not exist
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
  ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N ''  > /dev/null 2>&1 || error "Failed to create ssh_host_rsa_key host keys."
fi
if [ ! -f /etc/ssh/ssh_host_ecdsa_key ]; then
  ssh-keygen -t ecdsa -f /etc/ssh/ssh_host_ecdsa_key -N ''  > /dev/null 2>&1 || error "Failed to create ssh_host_ecdsa_key host keys."
fi
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ''  > /dev/null 2>&1 || error "Failed to create ssh_host_ed25519_key host keys."
fi
log "Restarting SSH"
systemctl restart ssh || error "Failed to restart SSH service."

# Backup existing interfaces file
if [ -f /etc/network/interfaces ]; then
    sudo cp /etc/network/interfaces /etc/network/interfaces.bak
    log "Existing /etc/network/interfaces file backed up to /etc/network/interfaces.bak"
fi

# Start with a new interfaces file
cat <<EOL | sudo tee /etc/network/interfaces  > /dev/null 2>&1
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

# The loopback network interface
auto lo
iface lo inet loopback

EOL

# Get all network interfaces except loopback
interfaces=$(ls /sys/class/net | grep -v lo | grep -v docker0)

# Add DHCP configuration for each interface
for iface in $interfaces; do
    cat <<EOL | sudo tee -a /etc/network/interfaces  > /dev/null 2>&1

# DHCP configuration for $iface
auto $iface
iface $iface inet dhcp

EOL
done

log "Generated /etc/network/interfaces file with DHCP configuration for the following interfaces: $interfaces"

# Restart networking service to apply changes
sudo systemctl restart networking
log "Networking service restarted."

# Get list of network interfaces excluding loopback
interfaces=$(ip link show | grep -oP '\d+: [a-zA-Z0-9_.-]+:' | grep -v 'lo:' | awk '{print $2}' | sed 's/://')

# Iterate over each interface and execute ifup
for iface in $interfaces; do
    log "Bringing up interface: $iface"
    sudo ifup $iface
done

log "All non-loopback network interfaces have been brought up."

sudo dhclient -v

# Get the current hostname
current_hostname=$(hostname)

# Replace the hostname in /etc/hosts

sudo hostnamectl set-hostname "$new_hostname"  > /dev/null 2>&1

log "The hostname has been set to: $(hostname)"


sudo sed -i "s/$current_hostname/$new_hostname/g" /etc/hosts

log "Hostname in /etc/hosts updated from $current_hostname to $new_hostname."

