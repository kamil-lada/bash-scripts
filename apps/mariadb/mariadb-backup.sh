echo "Starting global database backup job"

USER="debian"
SERVER_ADDR="host"
ssh -o LogLevel=error -T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER}@${SERVER_ADDR} "export VAR_BUILD_NUMBER='${BUILD_NUMBER}' && bash -s" <<'EOF'
# variables
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
TARGET="mysql_eset"
INFO="$TIMESTAMP: INFO: $TARGET:"
ERROR="$TIMESTAMP: ERROR: $TARGET:"
LOG="$TARGET.log"
SQL="$TARGET_$(date +"%Y-%m-%d_%H-%M-%S").sql"
REMOVE_AFTER_DAYS=30
WORK_PATH="/mnt/matrix-share/backups/automatic/dbs/$TARGET" 

cd "$WORK_PATH"
echo "$INFO Starting backup on remote host..." > $LOG
echo "$INFO Jenkins build number: $VAR_BUILD_NUMBER" >> $LOG
echo "$INFO Config REMOVE_AFTER_DAYS=$REMOVE_AFTER_DAYS" >> $LOG
echo "$INFO Config WORK_PATH=$WORK_PATH" >> $LOG

if [ ! -d "$WORK_PATH" ]; then
  echo "$ERROR Directory $WORK_PATH doesnt exist. Check mounts and fstab"
  exit 1
fi
# list system dbs
USER_DBS=$(sudo mysql -B -N -e "SHOW DATABASES" | grep -Ev '^(information_schema|mysql|performance_schema|sys)$') && \
  echo "$INFO List DBs OK" >> $LOG || \
  echo "$ERROR List DBs error. Check Jenkins build log" >> $LOG 
# dbs to backup
echo "$INFO DBs to backup: $USER_DBS" >> $LOG
# backup only 
sudo mysqldump --databases $USER_DBS --no-data --routines --triggers --add-drop-database --add-drop-table --single-transaction --quick | sudo tee structure.sql > /dev/null && \
  echo "$INFO Backup structure OK" >> $LOG || \
  echo "$ERROR Backup structure error. Check error in structure.sql" >> $LOG 

# backup only data
sudo mysqldump --databases $USER_DBS --no-create-info --routines --triggers --add-drop-database --add-drop-table --single-transaction --quick | sudo tee data.sql > /dev/null && \
  echo "$INFO Backup data OK" >> $LOG || \
  echo "$ERROR Backup data error. Check error in data.sql" >> $LOG 

# combine structure and data to maintain order of queries 
(
  echo "SET FOREIGN_KEY_CHECKS=0;";
  cat structure.sql;
  cat data.sql;
  echo "SET FOREIGN_KEY_CHECKS=1;";
) | sudo tee $SQL > /dev/null && \
  echo "$INFO Merging files OK" >> $LOG || \
  echo "$ERROR Merging files error. Check error in mariadb_*.sql" >> $LOG  
# delete leftovers
rm -f data.sql structure.sql > /dev/null 2>&1 

# maintain backup rotations
find . -name '*.sql' -type f -mtime $REMOVE_AFTER_DAYS -exec rm {} \;  && \
  echo "$INFO Removing old files OK" >> $LOG || \
  echo "$ERROR Removing old files error." >> $LOG 
# stats
SIZE_NICE=$(du $SQL -sh | awk '{print $1}')
SIZE_RAW=$(du $SQL -s | awk '{print $1}')
SIZE_PREVIOUS_RAW=$(du $(ls -Art | grep "sql" | tail -n 2 | head -n 1) -s | awk '{print $1}')
DIFF=$(( SIZE_RAW - SIZE_PREVIOUS_RAW ))
FOLDER_SIZE_NICE=$(du . -sh | awk '{print $1}')
FOLDER_FILE_COUNT=$(ls -alhF | wc -l)
#echo $SIZE_RAW
#echo $SIZE_PREVIOUS_RAW
if [ -n "$SIZE_NICE" ]; then
	echo "$INFO Backup size: $SIZE_NICE" >> $LOG
else
	echo "$ERROR Backup size is 0, check logs." >> $LOG
fi
echo "$INFO Backup size change: $DIFF kb" >> $LOG
echo "$INFO Backup folder size: $FOLDER_SIZE_NICE" >> $LOG
echo "$INFO Backup file count: $FOLDER_FILE_COUNT" >> $LOG
echo "$INFO Backup completed." >> $LOG

# prints log back to jenkins build $LOG
cat $LOG
EOF

####################################################    KONIEC mariadb