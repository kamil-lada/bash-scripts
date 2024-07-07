#!/bin/bash

# Variables
read -p "Please enter ROOT_PASSWORD: " ROOT_PASSWORD

# Check if the input is not empty
if [ -z "$ROOT_PASSWORD" ]; then
  error "Value cannot be empty. Exiting."
  exit 1
fi

read -p "Please enter REPLICATION_USER: " REPLICATION_USER

# Check if the input is not empty
if [ -z "$REPLICATION_USER" ]; then
  error "Value cannot be empty. Exiting."
  exit 1
fi

read -p "Please enter REPLICATION_PASSWORD: " REPLICATION_PASSWORD

# Check if the input is not empty
if [ -z "$REPLICATION_PASSWORD" ]; then
  error "Value cannot be empty. Exiting."
  exit 1
fi

DATA_DIR="/data/mariadb"

sudo apt update && sudo apt install -y mariadb-server

# Stop MariaDB service
sudo systemctl stop mariadb

# Create new data directory and move existing data
sudo mkdir -p $DATA_DIR
sudo rsync -av /var/lib/mysql/ $DATA_DIR/
sudo chown -R mysql:mysql $DATA_DIR

# Update MariaDB configuration
sudo sed -i "s|^datadir.*|datadir = $DATA_DIR|g" /etc/mysql/mariadb.conf.d/50-server.cnf

# Update AppArmor profile for MariaDB
if [ -f /etc/apparmor.d/usr.sbin.mysqld ]; then
    echo -e "\n# Custom data directory configuration" | sudo tee -a /etc/apparmor.d/usr.sbin.mysqld
    echo "$DATA_DIR r," | sudo tee -a /etc/apparmor.d/usr.sbin.mysqld
    echo "$DATA_DIR/** rwk," | sudo tee -a /etc/apparmor.d/usr.sbin.mysqld
    sudo systemctl reload apparmor
fi

# Start MariaDB service
sudo systemctl start mariadb

# Secure MariaDB installation
sudo mysql_secure_installation 2>/dev/null <<MSI

n
y
${ROOT_PASSWORD}
${ROOT_PASSWORD}
y
n
y
y
MSI

# Configure MariaDB for replication
mysql -u root -p"$ROOT_PASSWORD" <<EOF
CREATE USER ${REPLICATION_USER}@% IDENTIFIED BY '${REPLICATION_PASSWORD}';
GRANT REPLICATION SLAVE ON *.* TO '$REPLICATION_USER'@'%';
FLUSH PRIVILEGES;
FLUSH TABLES WITH READ LOCK;
SHOW MASTER STATUS;
EOF

echo "MariaDB master setup complete. Note the 'File' and 'Position' from the SHOW MASTER STATUS output above."
