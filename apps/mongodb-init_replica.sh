#!/bin/bash

# Arrays to hold MongoDB host addresses, usernames, and passwords
declare -a HOSTS
declare -a USERS
declare -a PASSWORDS

# Step 1: Prompt for MongoDB host addresses in a loop
echo "Enter MongoDB host addresses (e.g., host1:27017), press enter when done:"
while true; do
    read -p "MongoDB Host: " HOST
    [ -z "$HOST" ] && break  # Exit loop on empty input
    HOSTS+=("$HOST")
done

# Exit if no hosts were provided
if [ ${#HOSTS[@]} -eq 0 ]; then
    echo "No hosts provided. Exiting..."
    exit 1
fi

# Step 2: Ask for username and password for each host
for HOST in "${HOSTS[@]}"; do
    echo "Enter credentials for MongoDB host $HOST"
    read -p "Username: " USER
    read -sp "Password: " PASSWORD
    echo  # move to new line after password prompt
    USERS+=("$USER")
    PASSWORDS+=("$PASSWORD")
done

# Function to configure replication on a MongoDB host
setup_replication() {
    local HOST="$1"
    local USER="$2"
    local PASSWORD="$3"
    local CONFIG_STRING="$4"

    # Step 3: Connect to each host and setup replication
    mongo --host "$HOST" -u "$USER" -p "$PASSWORD" --authenticationDatabase "admin" <<EOF
    rs.initiate({
        _id: "rs0",
        members: [
            $CONFIG_STRING
        ]
    })
EOF

    if [ $? -ne 0 ]; then
        echo "Failed to configure replication on $HOST"
    else
        echo "Replication configured on $HOST"
    fi
}

# Step 4: Generate the replication configuration string
REPLICA_MEMBERS=""
for i in "${!HOSTS[@]}"; do
    if [ "$i" -ne 0 ]; then
        REPLICA_MEMBERS+=","
    fi
    REPLICA_MEMBERS+=" { _id: $i, host: \"${HOSTS[$i]}\" }"
done

# Step 5: Generate connection strings
PRIMARY_CONNECTION_STRING="mongodb://${USERS[0]}:${PASSWORDS[0]}@${HOSTS[0]},${HOSTS[1]}/?replicaSet=rs0&readPreference=primary"
SECONDARY_CONNECTION_STRING="mongodb://${USERS[0]}:${PASSWORDS[0]}@${HOSTS[1]},${HOSTS[0]}/?replicaSet=rs0&readPreference=secondaryPreferred"

echo "Generated primary connection string:"
echo "$PRIMARY_CONNECTION_STRING"
echo "Generated secondary-preferred connection string:"
echo "$SECONDARY_CONNECTION_STRING"

# Setup replication on each host
for i in "${!HOSTS[@]}"; do
    setup_replication "${HOSTS[$i]}" "${USERS[$i]}" "${PASSWORDS[$i]}" "$REPLICA_MEMBERS"
done

echo "MongoDB replication setup complete."
