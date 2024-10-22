#!/bin/bash

# Prompt for PostgreSQL version
read -p "Enter PostgreSQL version (e.g., 14): " psql_version

# Prompt for custom data path, with default suggestion
read -p "Enter custom data path (suggested: /data): " data_path
data_path=${data_path:-/data}

# Prompt if user wants to configure replication
read -p "Do you want to configure replication? (y/n): " replication_choice

# Prompt if user wants to create Zabbix monitoring user
read -p "Do you want to create a Zabbix monitoring user? (y/n): " zabbix_choice
if [[ "$zabbix_choice" == "y" ]]; then
    read -sp "Enter the password for zbx_monitoring: " zbx_password
    echo
fi

# Update and install PostgreSQL
sudo apt-get update
sudo apt-get install -y postgresql-$psql_version postgresql-contrib

# Move the data directory if a custom path is provided
if [[ -n "$data_path" && "$data_path" != "/var/lib/postgresql/$psql_version/main" ]]; then
    sudo systemctl stop postgresql
    sudo mv /var/lib/postgresql/$psql_version/main "$data_path/main"
    sudo ln -s "$data_path/main" /var/lib/postgresql/$psql_version/main
    sudo chown -R postgres:postgres "$data_path/main"
    sudo systemctl start postgresql
fi

# Perform initial PostgreSQL configuration (reliability & consistency settings)
sudo bash -c "cat <<EOF >> /etc/postgresql/$psql_version/main/postgresql.conf
# Reliability and consistency settings
synchronous_commit = on
full_page_writes = on
wal_level = replica
max_wal_senders = 10
wal_keep_size = 16MB
archive_mode = on
archive_command = 'cp %p /var/lib/postgresql/archive/%f'
EOF"

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

# Restart PostgreSQL to apply changes
sudo systemctl restart postgresql

echo "PostgreSQL installation and configuration complete."
if [[ "$replication_choice" == "y" ]]; then
    echo "Replication has been configured."
fi
