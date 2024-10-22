#!/bin/bash

# Prompt for PostgreSQL version
read -p "Enter PostgreSQL version (e.g., 14): " psql_version

# Prompt for custom data path, with default suggestion
read -p "Enter custom data path (suggested: /data): " data_path
data_path=${data_path:-/data}

# Prompt for primary server details
read -p "Enter the primary server IP: " primary_ip
read -p "Enter the replication user: " replication_user
read -sp "Enter the replication password: " replication_password
echo

# Stop PostgreSQL service
sudo systemctl stop postgresql

# Perform base backup for replication
sudo -u postgres pg_basebackup -h $primary_ip -D "$data_path/main" -U $replication_user -Fp -Xs -P

# Configure replication in postgresql.conf
sudo bash -c "cat <<EOF >> /etc/postgresql/$psql_version/main/postgresql.conf
primary_conninfo = 'host=$primary_ip port=5432 user=$replication_user password=$replication_password'
hot_standby = on
EOF"

# Move the data directory if a custom path is provided
if [[ -n "$data_path" && "$data_path" != "/var/lib/postgresql/$psql_version/main" ]]; then
    sudo mv /var/lib/postgresql/$psql_version/main "$data_path/main"
    sudo ln -s "$data_path/main" /var/lib/postgresql/$psql_version/main
    sudo chown -R postgres:postgres "$data_path/main"
fi

# Start PostgreSQL service
sudo systemctl start postgresql

echo "PostgreSQL replica configuration complete."
