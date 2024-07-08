#!/bin/bash

# Function to display available disks
list_disks() {
    echo "Available disks:"
    lsblk -d -o NAME,SIZE,MODEL | grep -v "NAME"
}

# Function to format the disk with ext4 and mount it to /data
format_and_mount() {
    local disk="$1"

    # Confirm the operation with the user
    read -p "Are you sure you want to format /dev/${disk} and mount it to /data? This will erase all data on the disk. (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        echo "Operation aborted."
        exit 1
    fi

    # Create a partition on the disk
    echo "Creating partition on /dev/${disk}..."
    echo -e "o\nn\np\n1\n\n\nw" | sudo fdisk /dev/${disk}

    # Format the partition with ext4
    echo "Formatting /dev/${disk}1 with ext4 filesystem..."
    sudo mkfs.ext4 /dev/${disk}1

    # Create /data directory if it doesn't exist
    if [ ! -d "/data" ]; then
        echo "Creating /data directory..."
        sudo mkdir /data
    fi

    # Mount the partition to /data
    echo "Mounting /dev/${disk}1 to /data..."
    sudo mount /dev/${disk}1 /data

    # Add entry to /etc/fstab to mount the partition at boot
    echo "Adding /dev/${disk}1 to /etc/fstab..."
    echo "/dev/${disk}1 /data ext4 defaults 0 2" | sudo tee -a /etc/fstab

    echo "Disk /dev/${disk} formatted and mounted to /data successfully."
}

# Main script starts here

# List available disks
list_disks

# Prompt user for the disk name
read -p "Enter the disk name (e.g., sda, sdb, nvme0n1): " disk

# Validate disk name input
if [ ! -b "/dev/${disk}" ]; then
    echo "Error: Invalid disk name. Please enter a valid disk name."
    exit 1
fi

# Call function to format and mount the disk
format_and_mount "$disk"
