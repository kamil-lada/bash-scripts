#!/bin/bash

# Function to display partition information
display_partition_info() {
    echo "Current partitions:"
    sudo lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT
}

# Function to expand an ext4 partition to 100% free space
expand_ext4_partition() {
    local disk="$1"
    local partition_number="$2"


    # Resize the partition to use all available space
    sudo parted "/dev/$disk" resizepart "$partition_number" 100%

    # Resize the filesystem
    sudo resize2fs "/dev/${disk}${partition_number}"

    echo "Partition /dev/${disk}${partition_number} expanded successfully."
}

# Main script starts here

# Display current partition information
display_partition_info

# Prompt user for disk and partition number to expand
read -p "Enter the disk (e.g., sda, nvme0n1): " disk
read -p "Enter the partition number to expand (e.g., 1, 2, 3, ...): " partition_number

# Validate partition number input (numeric check)
if ! [[ "$partition_number" =~ ^[0-9]+$ ]]; then
    echo "Error: Invalid partition number. Please enter a valid numeric value."
    exit 1
fi

# Confirm with user before proceeding
read -p "You are about to expand /dev/${disk}${partition_number}. Are you sure? (y/n): " confirm
if [ "$confirm" != "y" ]; then
    echo "Operation aborted."
    exit 1
fi

# Call function to expand the partition
expand_ext4_partition "$disk" "$partition_number"
