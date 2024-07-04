#!/bin/bash

# Variables
MASTER_HOST="master_ip_or_hostname"
REPLICATION_USER="replication_user"
REPLICATION_PASSWORD="replication_password"
DATA_DIR="/data/mariadb"
MASTER_LOG_FILE="mysql-bin.000001" # Update with the actual log file from master
MASTER_LOG_POS=1234                 # Update with the actual log position from master

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
sudo mysql_secure_installation

# Set up replication
mysql -u root -p <<EOF
STOP SLAVE;
CHANGE MASTER TO
  MASTER_HOST='$MASTER_HOST',
  MASTER_USER='$REPLICATION_USER',
  MASTER_PASSWORD='$REPLICATION_PASSWORD',
  MASTER_LOG_FILE='$MASTER_LOG_FILE',
  MASTER_LOG_POS=$MASTER_LOG_POS;
START SLAVE;
EOF

# Verify replication status
mysql -u root -p -e "SHOW SLAVE STATUS \G"

echo "MariaDB slave setup complete."
