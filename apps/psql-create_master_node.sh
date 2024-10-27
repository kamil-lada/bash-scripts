#!/bin/bash

echo "WARNING: This script will purge any existing psql packages and config. "
read -p "Press [Enter] to continue or [Ctrl+C] to cancel."
echo "Updating package lists..."

sudo apt install -y gpg
curl -fsSl https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor | sudo tee /usr/share/keyrings/postgresql.gpg > /dev/null
echo deb [arch=amd64,arm64,ppc64el signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main | sudo tee /etc/apt/sources.list.d/pgdg.list

sudo apt update
sudo apt install -y postgresql-common

# Prompt for PostgreSQL version and install
read -p "Enter PostgreSQL version to install (e.g., 15, 16, 17): " psql_version

# Prompt for custom data path, with default suggestion
data_path=/var/lib
custom_path=false
read -p "Enter custom data path or press [Enter] to keep default path (default: /var/lib, opt: /data): " data_path
if [ ! -z "$data_path" ]; then
    data_path=$data_path
    custom_path=true
fi

# Prompt if user wants to configure replication
read -p "Do you want to configure replication? (y/n): " replication_choice

# Prompt if user wants to create Zabbix monitoring user
read -p "Do you want to create a Zabbix monitoring user? (y/n): " zabbix_choice
if [[ "$zabbix_choice" == "y" ]]; then
    read -sp "Enter the password for zbx_monitoring: " zbx_password
    echo
fi
sudo sed -i s/data_directory/#data_directory/g /etc/postgresql-common/createcluster.conf
echo "data_directory = '$data_path/postgresql/%v/%c'" | sudo tee -a /etc/postgresql-common/createcluster.conf

echo "Installing PostgreSQL version $psql_version..."
sudo apt install -y postgresql-$psql_version

# Perform initial PostgreSQL configuration (reliability & consistency settings)
cat <<EOF | sudo tee /etc/postgresql/$psql_version/main/postgresql.conf
#Safety options
synchronous_commit = on
full_page_writes = on
wal_level = replica
max_wal_senders = 10
wal_keep_size = 16MB
archive_mode = on

#Native options
cluster_name = '${psql_version}/main'			# added to process titles if nonempty
datestyle = 'iso, mdy'
default_text_search_config = 'pg_catalog.english'
dynamic_shared_memory_type = posix	# the default is usually the first option
external_pid_file = '/var/run/postgresql/${psql_version}-main.pid'			# write an extra PID file
hba_file = '/etc/postgresql/${psql_version}/main/pg_hba.conf'	# host-based authentication file
ident_file = '/etc/postgresql/${psql_version}/main/pg_ident.conf'	# ident configuration file
include_dir = 'conf.d'			# include files ending in '.conf' from
lc_messages = 'en_US.UTF-8'		# locale for system error message
lc_monetary = 'en_US.UTF-8'		# locale for monetary formatting
lc_numeric = 'en_US.UTF-8'		# locale for number formatting
lc_time = 'en_US.UTF-8'			# locale for time formatting
listen_addresses = '*'
log_line_prefix = '%m [%p] %q%u@%d '
log_timezone = 'Europe/Warsaw'
max_connections = 100			# (change requires restart)
max_wal_size = 1GB
min_wal_size = 80MB
port = 5433				# (change requires restart)
shared_buffers = 128MB			# min 128kB
ssl = on
ssl_cert_file = '/etc/ssl/certs/ssl-cert-snakeoil.pem'
ssl_key_file = '/etc/ssl/private/ssl-cert-snakeoil.key'
timezone = 'Europe/Warsaw'
unix_socket_directories = '/var/run/postgresql'
EOF

sudo systemctl stop postgresql
cd "$data_path/postgresql"
# Move the data directory if a custom path is provided
if [[ $custom_path ]]; then
    # Stop PostgreSQL service
    sudo cp -r /var/lib/postgresql "$data_path"
    sudo mkdir -p "$data_path"/postgresql/archive
    sudo chown -R postgres:postgres "$data_path"
    sudo chmod -R 750 "$data_path"
    echo "archive_command = 'cp %p ${data_path}/postgresql/archive/%f'" | sudo tee -a /etc/postgresql/$psql_version/main/postgresql.conf
    echo "data_directory = '${data_path}/postgresql/${psql_version}/main'" | sudo tee -a /etc/postgresql/$psql_version/main/postgresql.conf
    sed -i "/^\[Service\]/a\Environment=PGDATA=${data_path}/postgresql/${psql_version}" /lib/systemd/system/postgresql.service
    sed -i "/^\[Service\]/a\Environment=PGHOST=localhost" /lib/systemd/system/postgresql.service
else
    echo "archive_command = 'cp %p /var/lib/postgresql/archive/%f'" | sudo tee -a /etc/postgresql/$psql_version/main/postgresql.conf
    echo "data_directory = '/var/lib/postgresql/${psql_version}/main'" | sudo tee -a /etc/postgresql/$psql_version/main/postgresql.conf
    sed -i "/^\[Service\]/a\Environment=PGHOST=localhost" /lib/systemd/system/postgresql.service
fi
systemctl daemon-reload
sudo systemctl restart postgresql

# Replication setup if user chooses to configure it
if [[ "$replication_choice" == "y" ]]; then
    read -sp "Enter the replication password: " replication_password
    replication_user='replica_user'
    sudo touch "/etc/postgresql/$psql_version/main/pg_hba.conf"
    sudo -u postgres psql -c "CREATE ROLE $replication_user WITH REPLICATION LOGIN PASSWORD '$replication_password';"
    echo "host replication $replication_user 0.0.0.0/0 md5" | sudo tee -a /etc/postgresql/$psql_version/main/pg_hba.conf
fi

# Zabbix monitoring user creation
if [[ "$zabbix_choice" == "y" ]]; then
    sudo -u postgres psql -c "CREATE ROLE zbx_monitoring WITH LOGIN PASSWORD '$zbx_password';"
    sudo -u postgres psql -c "GRANT SELECT ON pg_stat_activity, pg_stat_replication TO zbx_monitoring;"
fi

echo "PostgreSQL installation and configuration complete."
if [[ "$replication_choice" == "y" ]]; then
    echo "Replication has been configured. Username for replication is: $replication_user"
fi
echo "Check config file: /etc/postgresql/$psql_version/main/postgresql.conf"
echo "Check replication file: /etc/postgresql/$psql_version/main/pg_hba.conf"
echo "Check service file: /lib/systemd/system/postgresql.service"

