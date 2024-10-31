#!/bin/bash

# Prompt for required information
echo "This script will help fix replication issues in a MariaDB cluster."
echo "It requires access to a private SSH key with permissions on both master and replica nodes."
echo "Warning: This process may delete all data from the replica node. Proceed with caution."
read -p "Master host address: " MASTER_HOST
read -p "Replica host address: " REPLICA_HOST
read -p "SSH username: " SSH_USER
read -p "Path to private SSH key: " SSH_KEY_PATH
read -sp "MariaDB root password for master: " MARIADB_ROOT_PASSWORD_MASTER
echo
read -sp "MariaDB root password for replica: " MARIADB_ROOT_PASSWORD_REPLICA
echo
read -p "Replication username: " REPL_USER
read -sp "Replication password: " REPL_PASSWORD
echo

# Stop writes on the master using BACKUP STAGE for consistency
echo "Blocking writes on the master with BACKUP STAGE..."
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$MASTER_HOST" \
    "mysql -u root -p'$MARIADB_ROOT_PASSWORD_MASTER' -e 'BACKUP STAGE START;'"

# Backup databases (excluding system databases)
echo "Starting database backup on master..."
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$MASTER_HOST" \
    "mysqldump --all-databases --ignore-database=pma --ignore-database=sys \
               --ignore-database=performance_schema --ignore-database=mysql \
               --ignore-database=information_schema > /tmp/mariadb_backup.sql"

# Fetch GTID and log position from master
echo "Fetching GTID and log position from master..."
MASTER_STATUS=$(ssh -i "$SSH_KEY_PATH" "$SSH_USER@$MASTER_HOST" \
    "mysql -u root -p'$MARIADB_ROOT_PASSWORD_MASTER' -e 'SHOW MASTER STATUS\G'")
GTID=$(echo "$MASTER_STATUS" | grep -i "Executed_Gtid_Set:" | awk '{print $2}')
LOG_FILE=$(echo "$MASTER_STATUS" | grep -i "File:" | awk '{print $2}')
LOG_POS=$(echo "$MASTER_STATUS" | grep -i "Position:" | awk '{print $2}')
echo "GTID: $GTID, Log file: $LOG_FILE, Position: $LOG_POS"

# Transfer backup to local and then to replica
echo "Downloading backup from master..."
scp -i "$SSH_KEY_PATH" "$SSH_USER@$MASTER_HOST:/tmp/mariadb_backup.sql" /tmp/
echo "Transferring backup to replica..."
scp -i "$SSH_KEY_PATH" /tmp/mariadb_backup.sql "$SSH_USER@$REPLICA_HOST:/tmp/"

# Prepare replica for database import
echo "Stopping replication on replica and importing databases..."
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$REPLICA_HOST" << EOF
mysql -u root -p'$MARIADB_ROOT_PASSWORD_REPLICA' <<MYSQL_CMDS
STOP SLAVE;
RESET SLAVE ALL;
SOURCE /tmp/mariadb_backup.sql;
MYSQL_CMDS
EOF

# Configure replication on replica
echo "Configuring replication on replica using GTID..."
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$REPLICA_HOST" << EOF
mysql -u root -p'$MARIADB_ROOT_PASSWORD_REPLICA' <<MYSQL_CMDS
STOP SLAVE;
SET GLOBAL gtid_slave_pos = '$GTID';
CHANGE MASTER TO
  MASTER_HOST='$MASTER_HOST',
  MASTER_USER='$REPL_USER',
  MASTER_PASSWORD='$REPL_PASSWORD',
  MASTER_USE_GTID=slave_pos;
START SLAVE;
MYSQL_CMDS
EOF

# Verify replication status
echo "Verifying replication status..."
REPL_STATUS=$(ssh -i "$SSH_KEY_PATH" "$SSH_USER@$REPLICA_HOST" \
    "mysql -u root -p'$MARIADB_ROOT_PASSWORD_REPLICA' -e 'SHOW SLAVE STATUS\G'")
echo "$REPL_STATUS" | grep -E 'Slave_IO_Running:|Slave_SQL_Running:|Last_Error:'

# Resume writes on master
echo "Unlocking writes on master..."
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$MASTER_HOST" \
    "mysql -u root -p'$MARIADB_ROOT_PASSWORD_MASTER' -e 'BACKUP STAGE END;'"

echo "Replication reconfiguration complete. Check for errors in the output above."
