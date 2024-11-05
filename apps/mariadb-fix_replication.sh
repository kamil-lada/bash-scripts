#!/bin/bash

# Function to prompt for input
prompt() {
    read -rp "$1" input
    echo "$input"
}

# Step 1: Get necessary information from the user
MASTER_HOST=$(prompt "Enter the master host address: ")
REPLICA_HOST=$(prompt "Enter the replica host address: ")
USERNAME=$(prompt "Enter the SSH username with access to both hosts: ")
PRIVATE_KEY_PATH=$(prompt "Enter the path to the SSH private key: ")
REPLICATION_USER=$(prompt "Enter the replication user for MariaDB: ")
REPLICATION_PASSWORD=$(prompt "Enter the replication password for MariaDB: ")
MASTER_ROOT_PASSWORD=$(prompt "Enter the MariaDB root password for the master: ")
REPLICA_ROOT_PASSWORD=$(prompt "Enter the MariaDB root password for the replica: ")

# Step 2: Warn the user about data removal on the replica
echo "Warning: This process will remove all data from the replica node."
read -rp "Do you wish to continue? (yes/no): " confirmation
if [[ "$confirmation" != "yes" ]]; then
    echo "Operation canceled."
    exit 1
fi

# Step 3: Connect to the master, lock writes, and retrieve the GTID position
echo "Locking writes..."
BINLOG=$(ssh -i "$PRIVATE_KEY_PATH" "$USERNAME@$MASTER_HOST" "sudo mysql -u root -p'$MASTER_ROOT_PASSWORD' -e 'SHOW MASTER STATUS;' | awk 'NR==2 {print \$1}'")

sudo ssh -i "$PRIVATE_KEY_PATH" "$USERNAME@$MASTER_HOST" "
    sudo mysql -u root -p'$MASTER_ROOT_PASSWORD' -e 'FLUSH TABLES; SET GLOBAL read_only = ON;PURGE BINARY LOGS TO \"$BINLOG\";'
"
if [[ $? -ne 0 ]]; then
    echo "Failed to lock writes."
    exit 1
fi

GTID=$(ssh -i "$PRIVATE_KEY_PATH" "$USERNAME@$MASTER_HOST" "mysql -u root -p'$MASTER_ROOT_PASSWORD' -e 'SHOW GLOBAL VARIABLES LIKE \"gtid_binlog_pos\";' | awk 'NR==2 {print \$2}'")


# Step 4: Create a backup on the master
echo "Creating backup on the master..."
sudo ssh -i "$PRIVATE_KEY_PATH" "$USERNAME@$MASTER_HOST" "
sudo mysqldump -u root -p'$MASTER_ROOT_PASSWORD' --all-databases --triggers --routines --events --ignore-database=mysql --ignore-database=information_schema --ignore-database=performance_schema --ignore-database=sys --ignore-database=pma > /tmp/mariadb_backup.sql && sudo chmod 777 /tmp/mariadb_backup.sql
"

if [[ $? -ne 0 ]]; then
    echo "Failed to create backup on the master."
    exit 1
fi

# Step 5: Download the backup to the local host
echo "Downloading backup from master..."
sudo rm /tmp/mariadb_backup.sql
sudo scp -i "$PRIVATE_KEY_PATH" "$USERNAME@$MASTER_HOST:/tmp/mariadb_backup.sql" /tmp/mariadb_backup.sql
if [[ $? -ne 0 ]]; then
    echo "Failed to download the backup from the master."
    exit 1
fi

# Step 6: Transfer the backup to the replica
echo "Transferring backup to replica..."
sudo chmod 777 /tmp/mariadb_backup.sql
sudo scp -i "$PRIVATE_KEY_PATH" /tmp/mariadb_backup.sql "$USERNAME@$REPLICA_HOST:/tmp/mariadb_backup.sql"
if [[ $? -ne 0 ]]; then
    echo "Failed to transfer the backup to the replica."
    exit 1
fi

# Step 7: Stop replication on the replica, reset, and import the backup
echo "Stopping replication and importing the backup on replica..."
sudo ssh -i "$PRIVATE_KEY_PATH" "$USERNAME@$REPLICA_HOST" "
sudo mysql -u root -p'$REPLICA_ROOT_PASSWORD' -e 'STOP SLAVE; RESET SLAVE ALL; FLUSH LOGS;'
sudo mysql -u root -p'$REPLICA_ROOT_PASSWORD' < /tmp/mariadb_backup.sql
"
if [[ $? -ne 0 ]]; then
    echo "Failed to import backup on the replica."
    exit 1
fi

# Step 8: Configure GTID-based replication on the replica
echo "Configuring replication on replica..."
sudo ssh -i "$PRIVATE_KEY_PATH" "$USERNAME@$REPLICA_HOST" "
sudo mysql -u root -p'$REPLICA_ROOT_PASSWORD' <<EOF
STOP SLAVE;
SET GLOBAL gtid_slave_pos = '$GTID';
CHANGE MASTER TO
  MASTER_HOST='$MASTER_HOST',
  MASTER_USER='$REPLICATION_USER',
  MASTER_PASSWORD='$REPLICATION_PASSWORD',
  MASTER_USE_GTID=CURRENT_POS;
START SLAVE;
SHOW SLAVE STATUS\G
EOF
"
if [[ $? -ne 0 ]]; then
    echo "Failed to configure replication on the replica."
    exit 1
fi

# Step 9: Verify replication status on the replica
echo "Verifying replication status on replica..."
REPLICA_STATUS=$(ssh -i "$PRIVATE_KEY_PATH" "$USERNAME@$REPLICA_HOST" "sudo mysql -u root -p'$REPLICA_ROOT_PASSWORD' -e 'SHOW SLAVE STATUS\G'")
echo "$REPLICA_STATUS" | grep -E "Slave_IO_State|Last_SQL_Error|Last_IO_Error"

# Step 10: If replication is working, unlock writes on the master
if echo "$REPLICA_STATUS" | grep -q "Slave_IO_State: Waiting for master"; then
    echo "Replication is active and running. Unlocking writes on the master..."
    sudo ssh -i "$PRIVATE_KEY_PATH" "$USERNAME@$MASTER_HOST" "sudo mysql -u root -p'$MASTER_ROOT_PASSWORD' -e 'SET GLOBAL read_only = OFF;'"
    echo "Replication setup completed successfully."

    # Step 11: Create a test database and table on the master
    echo "Creating test database and table on the master..."
    sudo ssh -i "$PRIVATE_KEY_PATH" "$USERNAME@$MASTER_HOST" "
    sudo mysql -u root -p'$MASTER_ROOT_PASSWORD' -e 'CREATE DATABASE replication_test;'
    sudo mysql -u root -p'$MASTER_ROOT_PASSWORD' -e 'CREATE TABLE replication_test.test_table (test_value VARCHAR(255));'
    sudo mysql -u root -p'$MASTER_ROOT_PASSWORD' -e 'INSERT INTO replication_test.test_table (test_value) VALUES (\"Test Value\");'
    "

    # Step 12: Wait for a second and check on the replica
    echo "Waiting for replication to catch up..."
    sleep 1

    # Step 13: Verify the value on the replica
    echo "Checking for the test value on the replica..."
    TEST_VALUE=$(sudo ssh -i "$PRIVATE_KEY_PATH" "$USERNAME@$REPLICA_HOST" "
    sudo mysql -u root -p'$REPLICA_ROOT_PASSWORD' -e 'SELECT test_value FROM replication_test.test_table LIMIT 1;'"
    )
    echo "Test value on the replica: $TEST_VALUE"

    if [[ "$TEST_VALUE" == *"Test Value"* ]]; then
        echo "Replication verified successfully! Test value found on the replica."
    else
        echo "Replication verification failed. Test value not found on the replica."
    fi

else
    echo "Replication setup encountered errors. Writes remain locked on master for investigation."
fi
