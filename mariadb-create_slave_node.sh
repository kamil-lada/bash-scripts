#!/bin/bash
# Variables
read -p "Please enter MASTER_HOST: " MASTER_HOST

# Check if the input is not empty
if [ -z "$MASTER_HOST" ]; then
  error "Value cannot be empty. Exiting."
  exit 1
fi

# Variables
read -p "Please enter REPLICATION_USER: " REPLICATION_USER

# Check if the input is not empty
if [ -z "$REPLICATION_USER" ]; then
  error "Value cannot be empty. Exiting."
  exit 1
fi

# Variables
read -p "Please enter REPLICATION_PASSWORD: " REPLICATION_PASSWORD

# Check if the input is not empty
if [ -z "$REPLICATION_PASSWORD" ]; then
  error "Value cannot be empty. Exiting."
  exit 1
fi

# Variables
read -p "Please enter MASTER_LOG_FILE: " MASTER_LOG_FILE

# Check if the input is not empty
if [ -z "$MASTER_LOG_FILE" ]; then
  error "Value cannot be empty. Exiting."
  exit 1
fi

# Variables
read -p "Please enter MASTER_LOG_POS: " MASTER_LOG_POS

# Check if the input is not empty
if [ -z "$MASTER_LOG_POS" ]; then
  error "Value cannot be empty. Exiting."
  exit 1
fi

# Variables
read -p "Please enter ROOT_PASSWORD: " ROOT_PASSWORD

# Check if the input is not empty
if [ -z "$ROOT_PASSWORD" ]; then
  error "Value cannot be empty. Exiting."
  exit 1
fi

DATA_DIR="/data/mariadb"
BUFFER_POOL_SIZE="4G"
LOG_FILE_SIZE="512M"
sudo apt update && sudo apt install -y mariadb-server

# Stop MariaDB service
sudo systemctl stop mariadb

# Create new data directory and move existing data
sudo mkdir -p $DATA_DIR
sudo rsync -av /var/lib/mysql/ $DATA_DIR/
sudo chown -R mysql:mysql $DATA_DIR

# Update MariaDB configuration
sudo sed -i "s|^datadir.*|datadir = $DATA_DIR|g" /etc/mysql/mariadb.conf.d/50-server.cnf

cat <<EOF | sudo tee -a /etc/mysql/mariadb.conf.d/50-server.cnf
[mysqld]
# Performance Improvements
innodb_buffer_pool_size = $BUFFER_POOL_SIZE
innodb_log_file_size = $LOG_FILE_SIZE
innodb_flush_method = O_DIRECT
query_cache_size = 0
query_cache_type = 0

# Preventing Data Corruption
innodb_flush_log_at_trx_commit = 1
innodb_doublewrite = 1
sync_binlog = 1

# Replication Settings
server_id = 2
relay_log = $DATA_DIR/relay-bin
read_only = 1

# Log Settings
log_error = $DATA_DIR/error.log
slow_query_log = 1
slow_query_log_file = $DATA_DIR/slow.log
general_log = 1
general_log_file = $DATA_DIR/general.log

# Other recommended settings
max_connections = 500
thread_cache_size = 50
table_open_cache = 2000
EOF

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

y
y
${ROOT_PASSWORD}
${ROOT_PASSWORD}
y
n
y
y
MSI

# Set up replication
mysql -u root -p$ROOT_PASSWORD <<EOF
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
mmysql -u root -p$ROOT_PASSWORD -e "SHOW SLAVE STATUS \G"

echo "MariaDB slave setup complete."
