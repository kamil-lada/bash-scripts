#!/bin/bash

set -e

log() {
    echo "[INFO] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# Function to add SSH public key to authorized_keys file
add_ssh_key() {
    local ssh_key="$1"

    # Check if the key is not empty
    if [ -n "$ssh_key" ]; then
        log "Adding SSH public key to authorized_keys:"
        echo "$ssh_key" >> /home/debian/.ssh/authorized_keys
    else
        echo "Empty input received. Stopping."
    fi
}

############################################################# START

# Configure 'debian' user for sudo without password
username="debian"
mkdir -p /etc/sudoers.d
touch /etc/sudoers.d/debian
if id "debian" &>/dev/null; then
    log "User 'debian' already exists. Skipping creation."
    if -l -U "$username" 2>/dev/null | grep -q "may run the following commands"; then
        log "User 'debian' already has sudo privileges. Skipping creation."
    else
        log "Granting sudo privileges to user debian"
        echo "debian ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/debian || error "Failed to grant sudo privileges to 'debian'."
        chmod 440 /etc/sudoers.d/debian || error "Failed to set permissions on /etc/sudoers.d/debian."
    fi
else
    log "Creating user 'debian' with sudo privileges..."
    useradd -m -s /bin/bash debian || error "Failed to create user 'debian'."
    echo "debian ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/debian || error "Failed to grant sudo privileges to 'debian'."
    chmod 440 /etc/sudoers.d/debian || error "Failed to set permissions on /etc/sudoers.d/debian."
fi


# Ensure .ssh directory exists
mkdir -p /home/debian/.ssh && chown -R debian:debian /home/debian/.ssh

# Loop to prompt user for SSH public keys
log "Enter public keys from all users, press enter when finished..."
while true; do
    read -p "SSH Public Key: " ssh_key_input

    # Break the loop if input is empty
    if [ -z "$ssh_key_input" ]; then
        echo "No more keys to add. Exiting."
        break
    fi

    # Call function to add SSH key to authorized_keys
    add_ssh_key "$ssh_key_input"
done

log "All provided SSH keys have been added to /home/debian/.ssh/authorized_keys."

chown debian:debian /home/debian/.ssh/authorized_keys || error "Failed to set ownership on /home/debian/.ssh/authorized_keys."
chmod 600 /home/debian/.ssh/authorized_keys || error "Failed to set permissions on /home/debian/.ssh/authorized_keys."

read -p "Enter zabbix proxy/server address: " zabbix_address

# Install common packages
log "Installing common packages, it can take up to 5 minutes..."
wget -q https://repo.zabbix.com/zabbix/7.0/debian/pool/main/z/zabbix-release/zabbix-release_latest+debian12_all.deb && dpkg -i zabbix-release_latest+debian12_all.deb 
wget -q https://packages.graylog2.org/repo/packages/graylog-sidecar-repository_1-5_all.deb && dpkg -i graylog-sidecar-repository_1-5_all.deb
apt update && apt install -y vim git gpg jq nfs-common software-properties-common graylog-sidecar dirmngr curl wget net-tools htop sudo openjdk-17-jdk parted tcpdump zabbix-agent2 zabbix-agent2-plugin-*
rm zabbix-release_latest+12_all.deb 
rm graylog-sidecar-repository_1-5_all.deb
sudo graylog-sidecar -service install
sudo mkdir -p /var/lib/zabbix && sudo touch /var/lib/zabbix/zabbix_agent2.db && sudo chown -R zabbix:zabbix /var/lib/zabbix
sudo mv /etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agent2.conf.bak 
sudo mv /etc/zabbix/zabbix-agent2.conf /etc/zabbix/zabbix-agent2.conf.bak 
cat <<EOL | sudo tee /etc/zabbix/zabbix_agent2.conf 
BufferSend=5
BufferSize=100
EnablePersistentBuffer=1
HostMetadata=linux
#HostnameItem=system.hostname
PersistentBufferFile=/var/lib/zabbix/zabbix_agent2.db
PersistentBufferPeriod=30d
ControlSocket=/run/zabbix/agent.sock
Include=/etc/zabbix/zabbix_agent2.d/*.conf
Include=/etc/zabbix/zabbix_agent2.d/plugins.d/*.conf
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=10
PidFile=/var/run/zabbix/zabbix_agent2.pid
PluginSocket=/run/zabbix/agent.plugin.sock
Timeout=10
DebugLevel=3
Server=${zabbix_address}
ServerActive=${zabbix_address}
EOL

systemctl stop zabbix-agent2 && systemctl enable zabbix-agent2
systemctl stop graylog-sidecar && systemctl enable graylog-sidecar
# Set up aliases in /etc/bash.bashrc
log "Setting up aliases in /etc/bash.bashrc..."

# Alias for 'll'
echo "alias ll='ls -alhF --group-directories-first'" >> /etc/bash.bashrc || error "Failed to add 'll' alias to /etc/bash.bashrc."

# Alias for 'nanosh'
echo "alias nanosh='nanosh_func () { touch \$1 && chmod +x \$1 && nano \$1; }; nanosh_func'" >> /etc/bash.bashrc || error "Failed to add 'nanosh' alias to /etc/bash.bashrc."

# Update package list and upgrade all packages
log "Updating package list and upgrading packages..."
apt update > /dev/null 2>&1 && apt upgrade -y > /dev/null 2>&1 || error "Failed to update and upgrade packages."

# Set the timezone to Warsaw
log "Setting timezone to Warsaw..."
timedatectl set-timezone Europe/Warsaw || error "Failed to set timezone."

# Disable Predictable Network Interface Names and revert to old naming convention
log "Disabling predictable network interface names..."
ln -s /dev/null /etc/udev/rules.d/80-net-setup-link.rules || error "Failed to disable predictable network interface names."
update-initramfs -u || error "Failed to update initramfs."

# Install qemu-guest-agent for Proxmox
log "Installing qemu-guest-agent..."
apt install -y qemu-guest-agent > /dev/null 2>&1 || error "Failed to install qemu-guest-agent."
systemctl enable qemu-guest-agent > /dev/null 2>&1 || error "Failed to enable qemu-guest-agent."
systemctl start qemu-guest-agent > /dev/null 2>&1 || error "Failed to start qemu-guest-agent."

# Path to the SSH configuration file
SSH_CONFIG="/etc/ssh/sshd_config"

# Backup the current SSH configuration file
cp "$SSH_CONFIG" "${SSH_CONFIG}.bak.$(date +%F-%H-%M-%S)"

# Function to add or replace a configuration setting
add_or_replace_setting() {
    local setting="$1"
    local value="$2"
    local config_file="$3"
    
    if grep -q "^${setting}" "$config_file"; then
        sed -i "s|^${setting}.*|${setting} ${value}|" "$config_file"
    else
        echo "${setting} ${value}" >> "$config_file"
    fi
}

# Add or replace the necessary settings
add_or_replace_setting "PubkeyAuthentication" "yes" "$SSH_CONFIG"
add_or_replace_setting "PasswordAuthentication" "no" "$SSH_CONFIG"
add_or_replace_setting "ChallengeResponseAuthentication" "no" "$SSH_CONFIG"
add_or_replace_setting "PermitRootLogin" "no" "$SSH_CONFIG"
add_or_replace_setting "ClientAliveInterval" "300" "$SSH_CONFIG"
add_or_replace_setting "ClientAliveCountMax" "12" "$SSH_CONFIG"

# Restart the SSH service to apply the changes
systemctl restart ssh

log "SSH configuration updated and service restarted."

echo "IP: \4" | tee -a /etc/issue
log "/etc/issue file modified."

mkdir /home/debian/bash-scripts && cd /home/debian/bash-scripts && git clone https://github.com/kamil-lada/bash-scripts.git . > /dev/null 2>&1 && log "Scripts repo cloned." || error "Failed to clone scripts repo."
chown -R debian:debian /home/debian/bash-scripts
chmod +x /home/debian/bash-scripts/*.sh

# Set root user with no password
log "Removing password for root user..."
passwd -d root > /dev/null 2>&1 || error "Failed to remove password for root user."

# Set swappiness to a lower value
log "Setting swappiness to 10..."
echo "vm.swappiness = 10" >> /etc/sysctl.conf || error "Failed to set swappiness in /etc/sysctl.conf."
sysctl -p /etc/sysctl.conf || error "Failed to apply sysctl settings."

# Enable and start fstrim.timer for periodic disk trimming
log "Enabling and starting fstrim.timer..."
systemctl enable fstrim.timer || error "Failed to enable fstrim.timer."
systemctl start fstrim.timer || error "Failed to start fstrim.timer."

# Clean up APT cache
log "Cleaning up APT cache..."
apt clean || error "Failed to clean APT cache."

# Clean machine ID
log "Cleaning machine ID..."
truncate -s 0 /etc/machine-id || error "Failed to truncate /etc/machine-id."
rm /var/lib/dbus/machine-id || error "Failed to remove /var/lib/dbus/machine-id."
ln -s /etc/machine-id /var/lib/dbus/machine-id || error "Failed to link /etc/machine-id to /var/lib/dbus/machine-id."

# Clear logs
log "Clearing log files..."
find /var/log -type f -exec truncate -s 0 {} \; || error "Failed to clear log files."

# Clean up temporary directories
log "Cleaning up temporary directories..."
rm -rf /tmp/* || error "Failed to clean /tmp directory."
rm -rf /var/tmp/* || error "Failed to clean /var/tmp directory."

# Ensure the VM gets new DHCP leases
log "Removing DHCP leases..."
rm /var/lib/dhcp/* || error "Failed to remove DHCP leases."

# Clear the shell history
log "Clearing shell history..."
history -c || error "Failed to clear shell history."
echo > ~/.bash_history || error "Failed to clear .bash_history."

# Verify Java installation
log "Verifying Java installation..."
java -version > /dev/null 2>&1 || error "Java is not installed properly."

# Identify new disks (assumes /dev/sdb is the new disk)
NEW_DISK="/dev/sdb"
PARTITION="${NEW_DISK}1"
MOUNT_POINT="/data"

# Create a GPT partition table on the new disk
log "Creating GPT partition table on $NEW_DISK..."
parted $NEW_DISK --script mklabel gpt >/dev/null 2>&1 || error "Creating GPT partition table on $NEW_DISK failed."

# Create a new partition that spans the entire disk
log "Creating new partition on $NEW_DISK..."
parted $NEW_DISK --script mkpart primary ext4 0% 100% >/dev/null 2>&1 || error "Creating new partition on $NEW_DISK failed."

# Create a filesystem on the new disk (if not already formatted)
log "Creating filesystem on $PARTITION..."
mkfs.ext4 ${PARTITION}

# Create the mount point
log "Creating mount point $MOUNT_POINT..."
mkdir -p $MOUNT_POINT || error "Creating mount point failed."

# Get the UUID of the new partition
UUID=$(blkid -s UUID -o value $PARTITION)

# Add the new partition to /etc/fstab using UUID
echo "Adding $PARTITION to /etc/fstab..."
echo "UUID=$UUID    $MOUNT_POINT    ext4    defaults    0 2" >> /etc/fstab

systemctl daemon-reload

# Mount the new disk
log "Mounting $PARTITION..."
mount -a > /dev/null 2>&1 || error "Mounting $PARTITION... failed."

# Reconfigure GRUB
log "Updating GRUB configuration..."
update-grub > /dev/null 2>&1 || error "Updating GRUB failed."

# Install GRUB on the primary disk (assuming /dev/sda)
log "Installing GRUB on /dev/sda..."
grub-install /dev/sda >/dev/null 2>&1 || error "Installing GRUB failed."


log "VM preparation completed successfully."
