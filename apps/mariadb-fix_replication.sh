#!/bin/bash

prompt() {
    read -rp "$1" input
    echo "$input"
}

promptPass() {
    read -s -rp "$1" input
    echo "$input"
}

# Escape value for a double-quoted option-file value
cnf_escape() {
    local v="${1//\\/\\\\}"
    echo "${v//\"/\\\"}"
}

# Escape value for a single-quoted SQL string
sql_escape() {
    local v="${1//\\/\\\\}"
    echo "${v//\'/\'\'}"
}


echo "Warning: This process will remove all data from the replica node."
echo "Warning: This script MUST be run from other host then MariaDB"
echo "Warning: You will be asked for path to SSH private key"
read -rp "Do you wish to continue? (y/N): " confirmation
if [[ "$confirmation" != "y" ]]; then
    echo "Operation canceled."
    exit 1
fi


MASTER_HOST=$(prompt "Enter the master host address: ")
REPLICA_HOST=$(prompt "Enter the replica host address: ")
USERNAME=$(prompt "Enter the SSH username with access to both hosts: ")
PRIVATE_KEY_PATH=$(prompt "Enter the path to the SSH private key: ")
REPLICATION_USER=$(prompt "Enter the replication user for MariaDB: ")
REPLICATION_PASSWORD=$(promptPass "Enter the replication password for MariaDB: ") && echo
MASTER_ROOT_PASSWORD=$(promptPass "Enter the MariaDB root password for the master: ") && echo
REPLICA_ROOT_PASSWORD=$(promptPass "Enter the MariaDB root password for the replica: ") && echo

DUMP=/tmp/mariadb_backup.sql
DEFAULTS=/tmp/.mariadb_fix_replication.cnf
# Passwords live in a 600 option file on each host, never on a command line
MYSQL="sudo mysql --defaults-extra-file=$DEFAULTS"
MYSQLDUMP="sudo mysqldump --defaults-extra-file=$DEFAULTS"

master()  { ssh -i "$PRIVATE_KEY_PATH" "$USERNAME@$MASTER_HOST" "$@"; }
replica() { ssh -i "$PRIVATE_KEY_PATH" "$USERNAME@$REPLICA_HOST" "$@"; }

LOCKED=n
cleanup() {
    if [[ "$LOCKED" == "y" ]]; then
        echo "Unlocking writes on the master..."
        master "$MYSQL -e 'SET GLOBAL read_only = OFF;'"
    fi
    echo "Removing temporary files..."
    master "rm -f $DUMP $DEFAULTS"
    replica "rm -f $DUMP $DEFAULTS"
    rm -f "$DUMP"
}
trap cleanup EXIT

fail() {
    echo "$1"
    exit 1
}

printf '[client]\nuser=root\npassword="%s"\n' "$(cnf_escape "$MASTER_ROOT_PASSWORD")" \
    | master "umask 077; cat > $DEFAULTS" || fail "Failed to connect to the master."
printf '[client]\nuser=root\npassword="%s"\n' "$(cnf_escape "$REPLICA_ROOT_PASSWORD")" \
    | replica "umask 077; cat > $DEFAULTS" || fail "Failed to connect to the replica."

echo "Locking writes..."
BINLOG=$(master "$MYSQL -e 'SHOW MASTER STATUS;' | awk 'NR==2 {print \$1}'")

master "$MYSQL -e 'FLUSH TABLES; SET GLOBAL read_only = ON;PURGE BINARY LOGS TO \"$BINLOG\";'" \
    || fail "Failed to lock writes."
LOCKED=y


echo "Creating backup on the master..."
# --single-transaction + --master-data --gtid: consistent snapshot with matching GTID,
# even if privileged users still write (read_only does not stop them)
master "set -o pipefail; umask 077; $MYSQLDUMP --single-transaction --master-data=2 --gtid --all-databases --triggers --routines --events --ignore-database=mysql --ignore-database=information_schema --ignore-database=performance_schema --ignore-database=sys --ignore-database=pma > $DUMP" \
    || fail "Failed to create backup on the master."

GTID=$(master "grep -m1 -o \"gtid_slave_pos='[^']*'\" $DUMP" | cut -d"'" -f2)
[[ -n "$GTID" ]] || fail "Failed to read GTID position from the backup."

echo "Downloading backup from master..."
rm -f "$DUMP"
(umask 077; scp -i "$PRIVATE_KEY_PATH" "$USERNAME@$MASTER_HOST:$DUMP" "$DUMP") \
    || fail "Failed to download the backup from the master."

echo "Transferring backup to replica..."
scp -i "$PRIVATE_KEY_PATH" "$DUMP" "$USERNAME@$REPLICA_HOST:$DUMP" \
    || fail "Failed to transfer the backup to the replica."

echo "Stopping replication, removing old databases and importing the backup on replica..."
replica bash -e -s -- "$DEFAULTS" "$DUMP" <<'EOF' || fail "Failed to import backup on the replica."
set -o pipefail
MYSQL="sudo mysql --defaults-extra-file=$1"
$MYSQL -e 'STOP SLAVE; RESET SLAVE ALL; FLUSH LOGS;'
$MYSQL -N -e "SELECT CONCAT('DROP DATABASE \`', schema_name, '\`;') FROM information_schema.schemata
              WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys','pma')" | $MYSQL
$MYSQL < "$2"
EOF

echo "Configuring replication on replica..."
# slave_pos: local writes from the import must not affect the start position
replica "$MYSQL" <<EOF || fail "Failed to configure replication on the replica."
STOP SLAVE;
SET GLOBAL gtid_slave_pos = '$GTID';
CHANGE MASTER TO
  MASTER_HOST='$(sql_escape "$MASTER_HOST")',
  MASTER_USER='$(sql_escape "$REPLICATION_USER")',
  MASTER_PASSWORD='$(sql_escape "$REPLICATION_PASSWORD")',
  MASTER_USE_GTID=slave_pos;
START SLAVE;
EOF

echo "Verifying replication status on replica..."
for _ in {1..10}; do
    sleep 2
    REPLICA_STATUS=$(replica "$MYSQL -e 'SHOW SLAVE STATUS\G'")
    echo "$REPLICA_STATUS" | grep -q "Slave_IO_Running: Yes" \
        && echo "$REPLICA_STATUS" | grep -q "Slave_SQL_Running: Yes" && break
done
echo "$REPLICA_STATUS" | grep -E "Slave_IO_State|Slave_IO_Running|Slave_SQL_Running:|Last_SQL_Error|Last_IO_Error"

if echo "$REPLICA_STATUS" | grep -q "Slave_IO_Running: Yes" \
    && echo "$REPLICA_STATUS" | grep -q "Slave_SQL_Running: Yes"; then

    # Create a test database and table on the master (root can write while read_only)
    # Recreated from scratch (may exist from a previous run / the imported dump);
    # unique value so an old row can't give a false positive
    TEST_VALUE_EXPECTED="Test Value $(date +%s)"
    echo "Creating test database and table on the master..."
    master "$MYSQL -e 'DROP DATABASE IF EXISTS replication_test; CREATE DATABASE replication_test; CREATE TABLE replication_test.test_table (test_value VARCHAR(255)); INSERT INTO replication_test.test_table (test_value) VALUES (\"$TEST_VALUE_EXPECTED\");'" \
        || fail "Failed to create test data on the master."

    # Verify the value on the replica
    echo "Checking for the test value on the replica..."
    for _ in {1..10}; do
        sleep 1
        TEST_VALUE=$(replica "$MYSQL -N -e 'SELECT test_value FROM replication_test.test_table WHERE test_value = \"$TEST_VALUE_EXPECTED\";'" 2>/dev/null)
        [[ "$TEST_VALUE" == *"$TEST_VALUE_EXPECTED"* ]] && break
    done
    echo "Test value on the replica: $TEST_VALUE"

    if [[ "$TEST_VALUE" == *"$TEST_VALUE_EXPECTED"* ]]; then
        echo "Replication verified successfully! Test value found on the replica."
        master "$MYSQL -e 'DROP DATABASE IF EXISTS replication_test;'"
        echo "Replication setup completed successfully."
        # cleanup (EXIT trap) unlocks writes on the master
    else
        LOCKED=n
        echo "Replication verification failed. Test value not found on the replica."
        echo "Writes remain locked on master for investigation (SET GLOBAL read_only = OFF; to unlock)."
        exit 1
    fi

else
    LOCKED=n
    echo "Replication setup encountered errors. Writes remain locked on master for investigation."
    echo "Unlock on master with: SET GLOBAL read_only = OFF;"
    exit 1
fi
