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

    # Add MariaDB repository (mute command outputs)
    # sudo apt-get install -y software-properties-common dirmngr >/dev/null 2>&1
    sudo apt-key adv --fetch-keys 'https://mariadb.org/mariadb_release_signing_key.asc' #>/dev/null 2>&1
    sudo add-apt-repository -y "deb [arch=amd64,arm64,ppc64el] https://mirror.mariadb.org/repo/${version}/debian bookworm main" #>/dev/null 2>&1

    # Update package list and install MariaDB (mute outputs)
    sudo apt-get update >/dev/null 2>&1
    sudo apt-get install -y mariadb-server expect >/dev/null 2>&1

    # Confirm installation with version
    echo "MariaDB Server version $version installed successfully."
}

# Variables
read -p "Please enter ROOT_PASSWORD: " ROOT_PASSWORD

# Check if the input is not empty
if [ -z "$ROOT_PASSWORD" ]; then
  echo "Value cannot be empty. Exiting."
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

# Check if selected version is valid (matches the available versions)
if [[ "$LATEST_VERSIONS" == *"$selected_version"* || "$selected_version" == "$DEFAULT_VERSION" ]]; then
    echo "Installing MariaDB version $selected_version..."
    install_mariadb "$selected_version"
else
    echo "Error: Invalid version selected. Aborting."
    exit 1
fi

# Default data directory
DEFAULT_DATA_DIR="/var/lib/mysql"

# Ask user about custom data directory location, fallback to default
read -p "Enter custom location path for MariaDB data directory (default: $DEFAULT_DATA_DIR, opt: /data/mariadb): " DATA_DIR
DATA_DIR=${DATA_DIR:-$DEFAULT_DATA_DIR}

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

# Ask user if they want to configure replication
read -p "Do you want to configure replication? (y/N): " REPLICATION_CHOICE
REPLICATION_CHOICE=${REPLICATION_CHOICE,,} # Convert to lowercase

# Replication user variables
REPLICATION_USER="replica_user"

if [[ "$REPLICATION_CHOICE" == "y" ]]; then
    # Ask the user for the replication password only if replication is enabled
    read -p "Please enter REPLICATION_PASSWORD for $REPLICATION_USER: " REPLICATION_PASSWORD

    # Check if the input is not empty
    if [ -z "$REPLICATION_PASSWORD" ]; then
      echo "Value cannot be empty. Exiting."
      exit 1
    fi
fi

# Ask user if they want to create a Zabbix monitoring user
read -p "Do you want to create a Zabbix monitoring user? (y/N): " ZABBIX_CHOICE
ZABBIX_CHOICE=${ZABBIX_CHOICE,,} # Convert to lowercase

if [[ "$ZABBIX_CHOICE" == "y" ]]; then
    read -sp "Enter password for Zabbix monitoring user 'zbx_monitor': " ZABBIX_PASSWORD
    echo
fi

# Add performance and durability settings to MariaDB configuration
cat >/dev/null <<EOF | sudo tee "$CONFIG_FILE"
[mysqld]
# Native options
pid-file = /run/mysqld/mysqld.pid
basedir = /usr
bind-address = 0.0.0.0
expire_logs_days = 10
max_binlog_size = 500M
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci
datadir = ${DATA_DIR}

# Performance Improvements
innodb_buffer_pool_size = 4G
#innodb_log_file_size = 512M # changed on the bottom
innodb_flush_method = O_DIRECT
query_cache_size = 64M
query_cache_type = 1

# Preventing Data Corruption
innodb_flush_log_at_trx_commit = 1
innodb_doublewrite = 1
sync_binlog = 1

# Log Settings
log_error = ${DATA_DIR}/error.log
slow_query_log = 1
slow_query_log_file = ${DATA_DIR}/slow.log
general_log = 1
general_log_file = ${DATA_DIR}/general.log

# Other recommended settings
max_connections = 500
thread_cache_size = 50
table_open_cache = 2000
tmp_table_size = 64M
max_heap_table_size = 64M

# Paths for other files
tmpdir = ${DATA_DIR}/tmp

# InnoDB Paths
innodb_data_home_dir = ${DATA_DIR}
innodb_log_group_home_dir = ${DATA_DIR}

# Fix for "eror reading comunication packets"
max_allowed_packet=1024M
net_read_timeout=3600
net_write_timeout=3600
innodb_log_buffer_size = 32M
innodb_log_file_size = 2047M
EOF

# Add replication settings only if replication is enabled
if [[ "$REPLICATION_CHOICE" == "y" ]]; then
    SERVER_ID=$(($RANDOM % 100))
    cat >/dev/null <<EOF | sudo tee -a "$CONFIG_FILE"
        # Replication Settings
        server_id = ${SERVER_ID}
        log_bin = ${DATA_DIR}/mariadb-bin
        binlog_format = ROW
        binlog_checksum = CRC32
        gtid_strict_mode = ON
        log_slave_updates = ON
EOF
fi

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
send \"$ROOT_PASSWORD\r\"

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
echo "$SECURE_MYSQL"

echo "MySQL secure installation automated successfully."

# Configure MariaDB users
mysql -u root -p$ROOT_PASSWORD <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASSWORD}';
EOF

# Create replication user only if replication is enabled
if [[ "$REPLICATION_CHOICE" == "y" ]]; then
    mysql -u root -p$ROOT_PASSWORD <<EOF
CREATE USER '${REPLICATION_USER}'@'%' IDENTIFIED BY '${REPLICATION_PASSWORD}';
GRANT REPLICATION SLAVE ON *.* TO '${REPLICATION_USER}'@'%';
FLUSH PRIVILEGES;
EOF
    echo "Replication user '$REPLICATION_USER' created."
fi

# Create Zabbix monitoring user if requested
if [[ "$ZABBIX_CHOICE" == "y" ]]; then
    mysql -u root -p$ROOT_PASSWORD <<EOF
CREATE USER 'zbx_monitor'@'%' IDENTIFIED BY '${ZABBIX_PASSWORD}';
GRANT REPLICATION CLIENT, PROCESS, SLAVE MONITOR, SHOW DATABASES, SHOW VIEW, SELECT, REPLICATION SLAVE, BINLOG MONITOR ON *.* TO 'zbx_monitor'@'%';
FLUSH PRIVILEGES;
EOF
    echo "Zabbix monitoring user 'zbx_monitor' created."
fi

# Restart MariaDB to apply changes
systemctl restart mariadb
echo "MariaDB has been restarted to apply changes."

# Inform the user about created users
echo "MariaDB master setup complete."

if [[ "$REPLICATION_CHOICE" == "y" ]]; then
    echo "Replication user created: $REPLICATION_USER"
fi

if [[ "$ZABBIX_CHOICE" == "y" ]]; then
    echo "Zabbix monitoring user created: zbx_monitor"
fi

# Reminder to note SHOW MASTER STATUS
if [[ "$REPLICATION_CHOICE" == "y" ]]; then
    echo "ServerID for replica setup: $SERVER_ID."
    mysql -u root -p$ROOT_PASSWORD <<EOF
        SHOW MASTER STATUS;
EOF
fi
