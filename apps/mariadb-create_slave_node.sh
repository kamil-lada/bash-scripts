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
read -p "Please enter ROOT_PASSWORD: " ROOT_PASSWORD

# Check if the input is not empty
if [ -z "$ROOT_PASSWORD" ]; then
  error "Value cannot be empty. Exiting."
  exit 1
fi

DATA_DIR="/data/mariadb"

sudo apt update && sudo apt install -y mariadb-server expect

sudo systemctl stop mariadb

# Create new data directory and move existing data
sudo mkdir -p $DATA_DIR
sudo rsync -av /var/lib/mysql/ $DATA_DIR/
sudo chown -R mysql:mysql $DATA_DIR

CONFIG_FILE="/etc/mysql/mariadb.conf.d/50-server.cnf"
BACKUP_FILE="/etc/mysql/mariadb.conf.d/50-server.cnf.bak.$(date +%F-%H-%M-%S)"
DATA_DIR="/data/mariadb"

# Backup the current configuration file
sudo cp "$CONFIG_FILE" "$BACKUP_FILE"
# 
# Add performance and durability settings to MariaDB configuration
cat <<EOF | sudo tee "$CONFIG_FILE"
[mysqld]
# Native options
pid-file = /run/mysqld/mysqld.pid
basedir = /usr
bind-address = 0.0.0.0
expire_logs_days = 10
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci
datadir = $DATA_DIR

# Performance Improvements
innodb_buffer_pool_size = 4G
innodb_log_file_size = 512M
innodb_flush_method = O_DIRECT
query_cache_size = 0
query_cache_type = 0

# Preventing Data Corruption
innodb_flush_log_at_trx_commit = 1
innodb_doublewrite = 1
sync_binlog = 1

# Replication Settings
server_id = 2
log_bin = $DATA_DIR/mariadb-bin
binlog_format = ROW
binlog_checksum = CRC32
gtid_strict_mode = ON
gtid_domain_id = 1
log_slave_updates = ON

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

# Paths for other files
tmpdir = $DATA_DIR/tmp

# InnoDB Paths
innodb_data_home_dir = $DATA_DIR
innodb_log_group_home_dir = $DATA_DIR

# Slave-specific settings
relay_log = $DATA_DIR/relay-bin
read_only = 1
EOF

mkdir "$DATA_DIR"/tmp && chown -R mysql:mysql "$DATA_DIR"

# Update AppArmor profile for MariaDB
if [ -f /etc/apparmor.d/usr.sbin.mysqld ]; then
    echo -e "\n# Custom data directory configuration" | sudo tee -a /etc/apparmor.d/usr.sbin.mysqld
    echo "$DATA_DIR r," | sudo tee -a /etc/apparmor.d/usr.sbin.mysqld
    echo "$DATA_DIR/** rwk," | sudo tee -a /etc/apparmor.d/usr.sbin.mysqld
    sudo systemctl reload apparmor
fi

# Start MariaDB service
sudo systemctl start mariadb

# Secure MariaDB installation using expect script
/home/debian/bash-scripts/apps/mariadb-mysql_secure_install.sh $ROOT_PASSWORD

# Set up replication
mysql -u root -p$ROOT_PASSWORD <<EOF
STOP SLAVE;
CHANGE MASTER TO
  MASTER_HOST='$MASTER_HOST',
  MASTER_USER='$REPLICATION_USER',
  MASTER_PASSWORD='$REPLICATION_PASSWORD',
  MASTER_USE_GTID=slave_pos;
START SLAVE;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASSWORD}';
FLUSH PRIVILEGES;
EOF

NEW_USER="admin"

# Connect to MariaDB as root and create user
mysql -u root -p$ROOT_PASSWORD <<EOF
CREATE USER 'admin'@'%' IDENTIFIED BY '$ROOT_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO '$NEW_USER'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

# Verify replication status
mysql -u root -p -e "SHOW SLAVE STATUS \G"

echo "MariaDB slave setup complete."
