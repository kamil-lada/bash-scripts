#!/bin/bash

echo "WARNING: This script requires access to a private SSH key that can connect to all MongoDB hosts."
echo "Make sure you can SSH into all hosts using this private key before proceeding."
read -p "Press [Enter] to continue or [Ctrl+C] to cancel."

echo "Generating replica set authentication key..."
AUTH_KEY=$(openssl rand -base64 756)
echo "Replica set authentication key generated."

declare -A CREDS
declare -a HOSTS
while true; do
  read -p "Enter MongoDB host address (or press [Enter] to finish): " host
  if [ -z "$host" ]; then
    break
  fi
  HOSTS+=("$host")

  read -p "Enter MongoDB admin username for $host: " MONGO_USER
  read -sp "Enter MongoDB admin password for $host: " MONGO_PASS
  echo
  CREDS["$host"]="$MONGO_USER:$MONGO_PASS"
done

if [ ${#HOSTS[@]} -eq 0 ]; then
  echo "No hosts provided. Exiting."
  exit 1
fi

read -p "Enter the path to your SSH private key: " SSH_KEY_PATH
if [ ! -f "$SSH_KEY_PATH" ]; then
  echo "Invalid private key path: $SSH_KEY_PATH Exiting."
  exit 1
fi

read -p "Enter the username for SSH connection: " user
if [ -z "$user" ]; then
  echo "Invalid username. Exiting."
  exit 1
fi

for host in "${HOSTS[@]}"; do
  echo "Connecting to $host..."

  ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY_PATH" "$user@$host" <<EOF
  sudo tee /etc/mongo-keyfile <<< "$AUTH_KEY"
  sudo chown mongodb:mongodb /etc/mongo-keyfile
  sudo chmod 600 /etc/mongo-keyfile

  sudo systemctl restart mongod
EOF

  if [ $? -eq 0 ]; then
    echo "MongoDB configured and restarted successfully on $host."
  else
    echo "Failed to configure MongoDB on $host. Exiting."
    exit 1
  fi
done

echo "Replica set configuration phase completed."
echo "Now initializing replica set..."

read -p "Enter the primary MongoDB host for replica set initialization: " PRIMARY_HOST

RS_INIT_COMMAND="rs.initiate({_id: 'rs0', members: ["
for ((i = 0; i < ${#HOSTS[@]}; i++)); do
  host=${HOSTS[$i]}
  if [ $i -eq 0 ]; then
    RS_INIT_COMMAND+="{ _id: $i, host: '$host', priority: 1 }"
  else
    RS_INIT_COMMAND+=", { _id: $i, host: '$host', priority: 0.5 }"
  fi
done
RS_INIT_COMMAND+="]})"

USER_PASS="${CREDS["$PRIMARY_HOST"]}"
IFS=":" read -r MONGO_USER MONGO_PASS <<< "$USER_PASS"
echo "$RS_INIT_COMMAND"
ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY_PATH" "$user@$PRIMARY_HOST" <<EOF
  mongosh --username $MONGO_USER --password $MONGO_PASS --authenticationDatabase admin --eval "$RS_INIT_COMMAND"
  mongosh --username $MONGO_USER --password $MONGO_PASS --authenticationDatabase admin --eval 'rs.status();'
EOF

echo "Replica set initialized successfully."

echo "Your connection string is:"
CONNECTION_STRING="mongodb://${MONGO_USER}:${MONGO_PASS}@${HOSTS[0]},${HOSTS[1]}:27017/admin?replicaSet=rs0"
ALTERNATE_CONNECTION_STRING="mongodb://${MONGO_USER}:${MONGO_PASS}@${HOSTS[1]},${HOSTS[0]}:27017/admin?replicaSet=rs0&readPreference=secondaryPreferred"
echo "Primary preferred connection string: $CONNECTION_STRING"
echo "Secondary preferred connection string: $ALTERNATE_CONNECTION_STRING"
