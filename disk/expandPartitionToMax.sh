#!/bin/bash

# Function to expand an ext4 partition to 100% free space
expand_ext4_partition() {
    local disk="$1"
    local partition_number="$2"

    # Fix the GPT table (force fixing without user prompt)
    echo "Fixing GPT table..."
    echo "Fix" | sudo parted ---pretend-input-tty "/dev/$disk" print
    echo "Resizing partition..."
    yes | sudo parted ---pretend-input-tty "/dev/$disk" resizepart "$partition_number" 100%
    sudo resize2fs "/dev/${disk}${partition_number}"

    new_size=$(lsblk -n -o SIZE "/dev/${disk}${partition_number}")

    echo "Partition /dev/${disk}${partition_number} expanded successfully."
    echo "New partition size: $new_size"
}

# Main script

# Display current partition information
echo "Current partitions:"
sudo lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT

# Prompt user for disk and partition number to expand
read -p "Enter the disk (e.g., sda, nvme0n1): " disk
read -p "Enter the partition number to expand (e.g., 1, 2, 3, ...): " partition_number

# Validate partition number input
if ! [[ "$partition_number" =~ ^[0-9]+$ ]]; then
    echo "Error: Invalid partition number. Please enter a valid numeric value."
    exit 1
fi

# Confirm
read -p "You are about to expand /dev/${disk}${partition_number}. Are you sure? (y/n): " confirm
if [ "$confirm" != "y" ]; then
    echo "Operation aborted."
    exit 1
fi

# Call function
expand_ext4_partition "$disk" "$partition_number"
