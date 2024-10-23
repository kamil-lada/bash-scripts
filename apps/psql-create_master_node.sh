#!/bin/bash

echo "WARNING: This script will purge any existing psql packages and config. "
read -p "Press [Enter] to continue or [Ctrl+C] to cancel."
echo "Updating package lists..."

sudo apt install -y postgresql-common > /dev/null 2>&1
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -yp > /dev/null 2>&1

# Update package lists
sudo apt update > /dev/null 2>&1

# Prompt for PostgreSQL version and install
read -p "Enter PostgreSQL version to install (e.g., 15, 16, 17): " psql_version

# Prompt for custom data path, with default suggestion
read -p "Enter custom data path (suggested: /data/psql): " data_path
data_path=${data_path:-/var/lib/postgresql/$psql_version/main}

# Prompt if user wants to configure replication
read -p "Do you want to configure replication? (y/n): " replication_choice

# Prompt if user wants to create Zabbix monitoring user
read -p "Do you want to create a Zabbix monitoring user? (y/n): " zabbix_choice
if [[ "$zabbix_choice" == "y" ]]; then
    read -sp "Enter the password for zbx_monitoring: " zbx_password
    echo
fi

echo "Installing PostgreSQL version $psql_version..."
sudo apt install -y postgresql-$psql_version postgresql-contrib > /dev/null 2>&1

# Perform initial PostgreSQL configuration (reliability & consistency settings)
cat <<EOF | sudo tee /etc/postgresql/$psql_version/main/postgresql.conf > /dev/null 2>&1
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

# Move the data directory if a custom path is provided
if [[ -n "$data_path" && "$data_path" != "/var/lib/postgresql/$psql_version/main" ]]; then
    # Stop PostgreSQL service
    sudo systemctl stop postgresql
    sudo mkdir -p "$data_path"/archive  > /dev/null 2>&1
    sudo chown postgres:postgres "$data_path" > /dev/null 2>&1
    sudo mv /var/lib/postgresql/$psql_version/main "$data_path"
    sudo chown -R postgres:postgres "$data_path"
    echo "archive_command = 'cp %p ${data_path}/archive/%f'" | sudo tee -a /etc/postgresql/$psql_version/main/postgresql.conf > /dev/null 2>&1
    echo "data_directory = '${data_path}/${psql_version}/main'" | sudo tee -a /etc/postgresql/$psql_version/main/postgresql.conf > /dev/null 2>&1
else
    echo "archive_command = 'cp %p /var/lib/postgresql/archive/%f'" | sudo tee -a /etc/postgresql/$psql_version/main/postgresql.conf > /dev/null 2>&1
    echo "data_directory = '/var/lib/postgresql/${psql_version}/main'" | sudo tee -a /etc/postgresql/$psql_version/main/postgresql.conf > /dev/null 2>&1
fi



sudo systemctl restart postgresql

# Replication setup if user chooses to configure it
if [[ "$replication_choice" == "y" ]]; then
    read -p "Enter the replication username: " replication_user
    read -sp "Enter the replication password: " replication_password
    echo

    sudo -u postgres psql -c "CREATE ROLE $replication_user WITH REPLICATION LOGIN PASSWORD '$replication_password';"
    sudo bash -c "echo 'host replication $replication_user 0.0.0.0/0 md5' >> /etc/postgresql/$psql_version/main/pg_hba.conf"
fi

# Zabbix monitoring user creation
if [[ "$zabbix_choice" == "y" ]]; then
    sudo -u postgres psql -c "CREATE ROLE zbx_monitoring WITH LOGIN PASSWORD '$zbx_password';"
    sudo -u postgres psql -c "GRANT SELECT ON pg_stat_activity, pg_stat_replication TO zbx_monitoring;"
fi

echo "PostgreSQL installation and configuration complete."
if [[ "$replication_choice" == "y" ]]; then
    echo "Replication has been configured."
fi

