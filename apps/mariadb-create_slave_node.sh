#!/bin/bash

# Function to fetch the latest MariaDB versions
get_latest_versions() {
    # Query MariaDB repository for the latest stable versions
    curl -s 'https://downloads.mariadb.org/rest-api/mariadb' | \
    jq -r '[.major_releases[] | select(.release_status == "Stable") | .release_id]'
}

# Function to install MariaDB
install_mariadb() {
    local version=$1

    sudo apt-key adv --fetch-keys 'https://mariadb.org/mariadb_release_signing_key.asc' >/dev/null 2>&1
    sudo add-apt-repository -y "deb [arch=amd64,arm64,ppc64el] https://mirror.mariadb.org/repo/${version}/debian bookworm main" >/dev/null 2>&1

    sudo apt-get update >/dev/null 2>&1
    sudo apt-get install -y mariadb-server expect >/dev/null 2>&1

    # Confirm installation with version
    echo "MariaDB Server version $version installed successfully."
}

read -p "Please enter master host: " MASTER_HOST
# Check if the input is not empty
if [ -z "$MASTER_HOST" ]; then
  error "Value cannot be empty. Exiting."
  exit 1
fi

# Variables
read -sp "Please enter replication user password: " REPLICATION_PASSWORD
echo
# Check if the input is not empty
if [ -z "$REPLICATION_PASSWORD" ]; then
  error "Value cannot be empty. Exiting."
  exit 1
fi

# Variables
read -p "Please enter GTID value from master (SELECT @@gtid_current_pos;): " GTID
# Check if the input is not empty
if [ -z "$GTID" ]; then
  error "Value cannot be empty. Exiting."
  exit 1
fi

# Variables
read -sp "Please enter password for MariaDB root user: " MARIADB_ROOT_PASSWORD
echo
# Check if the input is not empty
if [ -z "$MARIADB_ROOT_PASSWORD" ]; then
  echo "Value cannot be empty. Exiting."
  exit 1
fi

# Replication user variables
REPLICATION_USER="replica_user"

# Variables
read -sp "Please enter root password: " ROOT_PASSWORD
echo
# Check if the input is not empty
if [ -z "$ROOT_PASSWORD" ]; then
  error "Value cannot be empty. Exiting."
  exit 1
fi

# Main script starts here

echo "Fetching latest MariaDB versions..."
LATEST_VERSIONS=$(get_latest_versions)

# Display available versions
echo "Available MariaDB versions:"
echo "$LATEST_VERSIONS"
echo ""

# Default MariaDB version if user does not select a version
DEFAULT_VERSION="10.11"

# Prompt user for version
read -p "Enter the version you want to install (default is $DEFAULT_VERSION): " selected_version

# If no version is selected, use the default
if [ -z "$selected_version" ]; then
    selected_version=$DEFAULT_VERSION
fi

# Default data directory
DEFAULT_DATA_DIR="/var/lib/mysql"

# Ask user about custom data directory location, fallback to default
read -p "Enter custom location path for MariaDB data directory (default: $DEFAULT_DATA_DIR, opt: /data/mariadb): " DATA_DIR
DATA_DIR=${DATA_DIR:-$DEFAULT_DATA_DIR}

# Ask user if they want to create a Zabbix monitoring user
read -p "Do you want to create a Zabbix monitoring user? (y/N): " ZABBIX_CHOICE
ZABBIX_CHOICE=${ZABBIX_CHOICE,,} # Convert to lowercase

if [[ "$ZABBIX_CHOICE" == "y" ]]; then
    read -sp "Enter password for Zabbix monitoring user 'zbx_monitor': " ZABBIX_PASSWORD
    echo
fi
echo "Installation may take up to 4 minutes, grab some coffee."
# Check if selected version is valid (matches the available versions)
if [[ "$LATEST_VERSIONS" == *"$selected_version"* || "$selected_version" == "$DEFAULT_VERSION" ]]; then
    echo "Installing MariaDB version $selected_version..."
    install_mariadb "$selected_version"
else
    echo "Error: Invalid version selected. Aborting."
    exit 1
fi

# Stop MariaDB service
sudo systemctl stop mariadb

# Create new data directory and move existing data only if custom path is provided
if [ "$DATA_DIR" != "/var/lib/mysql" ]; then
  sudo mkdir -p $DATA_DIR
  sudo rsync -aq /var/lib/mysql/ $DATA_DIR/
  sudo chown -R mysql:mysql $DATA_DIR
fi

CONFIG_FILE="/etc/mysql/mariadb.conf.d/50-server.cnf"
BACKUP_FILE="/etc/mysql/mariadb.conf.d/50-server.cnf.bak.$(date +%F-%H-%M-%S)"

# Backup the current configuration file
sudo cp "$CONFIG_FILE" "$BACKUP_FILE"

# Add performance and durability settings to MariaDB configuration
cat <<EOF | sudo tee "$CONFIG_FILE" >/dev/null
[mysqld]
# Native options
pid-file = /run/mysqld/mysqld.pid
basedir = /usr
bind-address = 0.0.0.0
expire_logs_days = 10
max_binlog_size = 500M
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci
datadir = $DATA_DIR

# Performance Improvements
innodb_buffer_pool_size = 4G
innodb_log_file_size = 512M
innodb_flush_method = O_DIRECT
query_cache_size = 64M
query_cache_type = 1

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
slave_exec_mode = IDEMPOTENT
slave_parallel_mode = none
log_slave_updates = ON
relay_log = $DATA_DIR/relay-bin
read_only = 1
replicate-ignore-db = pma
replicate-ignore-db = sys
replicate-ignore-db = performance_schema
replicate-ignore-db = mysql
replicate-ignore-db = information_schema

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
tmp_table_size = 64M
max_heap_table_size = 64M

# Paths for other files
tmpdir = $DATA_DIR/tmp

# InnoDB Paths
innodb_data_home_dir = $DATA_DIR
innodb_log_group_home_dir = $DATA_DIR

# Fix for "eror reading comunication packets"
max_allowed_packet=1024M
net_read_timeout=3600
net_write_timeout=3600
innodb_log_buffer_size = 32M
innodb_log_file_size = 2047M
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

# Automating mysql_secure_installation with Expect
SECURE_MYSQL=$(expect -c "

set timeout 10
spawn mysql_secure_installation

expect \"Enter current password for root (enter for none):\"
send \"$MARIADB_ROOT_PASSWORD\r\"

expect \"Switch to unix_socket authentication \[Y/n\]\"
send \"y\r\"

expect \"Change the root password? \[Y/n\]\"
send \"n\r\"

expect \"Remove anonymous users? \[Y/n\]\"
send \"y\r\"

expect \"Disallow root login remotely? \[Y/n\]\"
send \"n\r\"

expect \"Remove test database and access to it? \[Y/n\]\"
send \"y\r\"

expect \"Reload privilege tables now? \[Y/n\]\"
send \"y\r\"

expect eof
")

# Run the Expect script
echo "$SECURE_MYSQL" >/dev/null 2>&1

echo "MySQL secure installation automated successfully."

# Create Zabbix monitoring user if requested
if [[ "$ZABBIX_CHOICE" == "y" ]]; then
    mysql -u root -p$ROOT_PASSWORD <<EOF
CREATE USER 'zbx_monitor'@'%' IDENTIFIED BY '${ZABBIX_PASSWORD}';
GRANT REPLICATION CLIENT, PROCESS, SLAVE MONITOR, SHOW DATABASES, SHOW VIEW, SELECT, REPLICATION SLAVE, BINLOG MONITOR ON *.* TO 'zbx_monitor'@'%';
FLUSH PRIVILEGES;
EOF
    echo "Zabbix monitoring user 'zbx_monitor' created."
fi

# Set up replication
mysql -u root -p$ROOT_PASSWORD <<EOF
STOP SLAVE;
SET GLOBAL gtid_slave_pos = '$GTID';
CHANGE MASTER TO
  MASTER_HOST='$MASTER_HOST',
  MASTER_USER='$REPLICATION_USER',
  MASTER_PASSWORD='$REPLICATION_PASSWORD',
  MASTER_USE_GTID=slave_pos;
START SLAVE;
EOF

systemctl restart mariadb
echo "MariaDB has been restarted to apply changes."
echo "Check config in /etc/mysql/mariadb.conf.d/50-server.cnf"

# Just in case
sleep 3
# Verify replication status
mysql -u root -p$ROOT_PASSWORD -e "SHOW SLAVE STATUS \G"

echo "MariaDB slave setup complete."
