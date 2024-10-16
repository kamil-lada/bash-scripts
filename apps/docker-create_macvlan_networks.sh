#!/bin/bash

# Function to prompt for user input and validate
prompt() {
  local var_name=$1
  local prompt_message=$2

  read -p "$prompt_message: " $var_name
}

# Function to calculate gateway and IP range
calculate_ip_details() {
  local subnet=$1
  local base_ip=$(echo $subnet | cut -d'/' -f1)
  local netmask=$(echo $subnet | cut -d'/' -f2)
  local IFS='.' read -r -a ip_array <<< "$base_ip"
  
  ip_array[3]=$((ip_array[3] + 1))  # Gateway is the first IP address
  gateway=$(IFS=. ; echo "${ip_array[*]}")

  ip_range_start=$((ip_array[3] + 1)) # Start range after gateway
  ip_range="${ip_array[0]}.${ip_array[1]}.${ip_array[2]}.$ip_range_start/$netmask"

  echo "$gateway $ip_range"
}

# Function to add a macvlan interface
add_macvlan_interface() {
  local parent_iface=$1
  local macvlan_iface=$2
  local ip_addr=$3
  local netmask=$4

  sudo ip link add $macvlan_iface link $parent_iface type macvlan mode bridge
  sudo ip addr add $ip_addr/$netmask dev $macvlan_iface
  sudo ip link set $macvlan_iface up
}

# Function to create a Docker macvlan network
create_docker_network() {
  local subnet=$1
  local gateway=$2
  local ip_range=$3
  local parent_iface=$4
  local network_name=$5

  docker network create -d macvlan \
    --subnet=$subnet \
    --gateway=$gateway \
    --ip-range=$ip_range \
    -o parent=$parent_iface $network_name
}

# Prompt for inputs
prompt PARENT_IFACE_1 "Enter the parent interface name for VLAN 10 (e.g., eth0.10)"
prompt MACVLAN_IFACE_1 "Enter the macvlan interface name for VLAN 10 (e.g., macvlan10)"
prompt SUBNET_1 "Enter the subnet for VLAN 10 (e.g., 10.0.10.224/27)"
prompt NETWORK_NAME_1 "Enter the Docker network name for VLAN 10 (e.g., vlan10_net)"

prompt PARENT_IFACE_2 "Enter the parent interface name for VLAN 20 (e.g., eth0.20)"
prompt MACVLAN_IFACE_2 "Enter the macvlan interface name for VLAN 20 (e.g., macvlan20)"
prompt SUBNET_2 "Enter the subnet for VLAN 20 (e.g., 10.0.20.192/26)"
prompt NETWORK_NAME_2 "Enter the Docker network name for VLAN 20 (e.g., vlan20_net)"

# Enable IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1
sudo sed -i '/net.ipv4.ip_forward=1/ s/^#//' /etc/sysctl.conf
sudo sysctl -p

# Calculate IP details for VLAN 10
read GATEWAY_1 IP_RANGE_1 <<< $(calculate_ip_details $SUBNET_1)
# Add macvlan interfaces and create Docker network for VLAN 10
add_macvlan_interface $PARENT_IFACE_1 $MACVLAN_IFACE_1 $GATEWAY_1 ${SUBNET_1#*/}
create_docker_network $SUBNET_1 $GATEWAY_1 $IP_RANGE_1 $PARENT_IFACE_1 $NETWORK_NAME_1

# Calculate IP details for VLAN 20
read GATEWAY_2 IP_RANGE_2 <<< $(calculate_ip_details $SUBNET_2)
# Add macvlan interfaces and create Docker network for VLAN 20
add_macvlan_interface $PARENT_IFACE_2 $MACVLAN_IFACE_2 $GATEWAY_2 ${SUBNET_2#*/}
create_docker_network $SUBNET_2 $GATEWAY_2 $IP_RANGE_2 $PARENT_IFACE_2 $NETWORK_NAME_2

echo "Configuration completed successfully."
