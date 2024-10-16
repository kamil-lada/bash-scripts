#!/bin/bash

log_error() {
    echo "[ERROR] $1" >&2
}

read -p "Create MongoDB admin username: " admin_user
read -s -p "Create MongoDB admin password: " admin_password
echo

read -p "Do you want to prepare host for replication? (y/N): " REPLICATION_CHOICE
REPLICATION_CHOICE=${REPLICATION_CHOICE,,} # Convert to lowercase

read -p "Do you want to create a Zabbix monitoring user? (y/N): " zbx_choice
zbx_choice=${zbx_choice,,} # Convert to lowercase

if [[ "$zbx_choice" == "y" ]]; then
    read -sp "Please create password for Zabbix monitoring user 'zbx_monitor': " zbx_password
    echo
fi

echo "Please enter the desired MongoDB data directory location (default: /var/lib/mongodb, opt: /data/mongodb):"
read -p "Data directory: " data_dir

echo "Installing MongoDB..."
sudo rm /usr/share/keyrings/mongodb-server-7.0.gpg  > /dev/null 2>&1
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor  2>/dev/null || log_error "Failed to add MongoDB GPG key"
echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] http://repo.mongodb.org/apt/debian bookworm/mongodb-org/7.0 main" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list > /dev/null
apt-get update -qq || log_error "Failed to update apt repositories"
apt-get install -qq mongodb-org || log_error "MongoDB installation failed"

if [ -z "$data_dir" ]; then
    data_dir="/var/lib/mongodb"
fi

if [ ! -d "$data_dir" ]; then
    mkdir -p "$data_dir" || log_error "Failed to create directory $data_dir"
fi
chown -R mongodb:mongodb "$data_dir" || log_error "Failed to set permissions on $data_dir"


echo "Configuring MongoDB security..."
cat <<EOL | sudo tee /etc/mongod.conf >/dev/null
security:
  authorization: "enabled"
  keyFile: /etc/mongo-keyfile

storage:
  dbPath: "$data_dir"

net:
  bindIp: 0.0.0.0
  port: 27017


EOL

if [[ "$REPLICATION_CHOICE" == "y" ]]; then
    cat  <<EOF | sudo tee -a /etc/mongod.conf >/dev/null
replication:
  replSetName: rs0
EOF
fi
# Temporary key-file
echo $(openssl rand -base64 756) > /etc/mongo-keyfile
systemctl start mongod
sleep 10

echo "Creating MongoDB admin user..."
mongosh <<EOF
use admin
db.createUser({
  user: "$admin_user",
  pwd: "$admin_password",
  roles: [{ role: "userAdminAnyDatabase", db: "admin" }, { role: "dbAdminAnyDatabase", db: "admin" }, { role: "root", db: "admin" }, { role: "readWriteAnyDatabase", db: "admin" }]
})
EOF

if [[ "$zbx_choice" == "y" ]]; then
    echo "Creating Zabbix monitoring user..."
    mongosh -u $admin_user -p $admin_password --authenticationDatabase admin <<EOF
    use admin
    db.createUser({
      user: "zbx_monitor",
      pwd: "$zbx_password",
      roles: [{ role: "clusterMonitor", db: "admin" }]
    })
EOF
    echo "Zabbix monitoring user 'zbx_monitor' created."
fi
sudo systemctl enable mongod
sudo systemctl restart mongod || log_error "Failed to restart MongoDB"
sudo systemctl --type=service --state=active | grep mongod
sudo apt-mark hold mongodb-org || log_error "Failed to mark as hold"
echo "MongoDB setup completed."