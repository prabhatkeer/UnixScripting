#!/bin/bash

# Config
DATE=`date +%y%m%d`
BACKUP_DIR=/home/backup/mysql/
BACKUP_FILE="jeenee_$DATE".gz
LOG_FILE=/home/backup/log/db_backup.log

# Stuff
function log {
  echo $1 >> $LOG_FILE
}
cd $BACKUP_DIR

log ""
log "Backup started at $(date '+%Y-%m-%d %H:%M:%S')"
log "DB Master Status:"
mysql --defaults-file=/scripts/MY_PASS -B -e 'show master status\G' | head -3 | tail -2 >> $LOG_FILE
log ""

log "Starting db backup..."
SECONDS=0

/usr/bin/mysqldump --defaults-file=/scripts/MY_PASS -uroot --skip-lock-tables --skip-add-drop-table --skip-comments --skip-compact --disable-keys --databases m
ysql --databases jeenee --ignore-table jeenee.API_mur_costs --ignore-table jeenee.API_mur_costs_201511 | gzip -c > $BACKUP_FILE

DURATION=$SECONDS
log "Done. Took $(($DURATION / 60))m $((DURATION % 60))s. Size: `du -ms $BACKUP_FILE | cut -f1` MB"
log ""

log "Changing backup owner."
chown backup:backup $BACKUP_FILE

log "Looking for old backups."
LAST_BACKUP=`ls -lastrd /home/backup/mysql/jeenee_*.gz | head -1 | awk '{print $NF}'`
BACKUP_COUNTS=`ls -lastrd /home/backup/mysql/jeenee_*.gz | wc -l`
if (( ${BACKUP_COUNTS} >= 14 )); then
  log "Removing $LAST_BACKUP...."
  /bin/rm -f $LAST_BACKUP
else
  log "Nothing to remove."
fi

# ????
#/bin/tar -cjps --same-owner --atime-preserve -f ./jeenee_"$DATE".bz2 /home/backup/mysql/jeenee_"$DATE".gz && rm -f /home/backup/mysql/jeenee_"$DATE".gz