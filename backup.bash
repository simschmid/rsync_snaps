#! /bin/bash
#
#   Snapshot backup
#
set -e;
set -E;
#set -x;

#LEVEL=$1
PID_FILE=/var/run/rsync_ss.pid
NBACKUPS=5
SRC="rsync://backup@192.168.178.88/synology/"
ROOT=/media/snapshots/synology
LOGFILE=/var/log/rsync_ss.log

if [[ -z "$1" ]]; then echo "No config specified."; exit 1; fi
source "$1" 

DATE=`date +"%Y-%m-%d_%H-%M-%S"`
DST=$ROOT/$LEVEL/$DATE
TMP=$ROOT/$LEVEL/.temp
LATEST=$ROOT/latest
LINKOPT="--link-dest $LATEST/"
PID_DIR=/tmp/rsync_ss
LEVEL_PID_FILE=$PID_DIR/${ROOT//\//_}_$LEVEL


function log {
    date=`date --rfc-3339=seconds`
    echo -e "[$date] Backup: $1" | tee -a $LOGFILE 
}

function log_cmd {
    if [[ ! -z "$LOGFILE" ]]; then    
        $@ 2>&1 | tee -a $LOGFILE 
    else 
        $@
    fi
}


if [[ -z "$LEVEL" ]]; then log "Please provide level"; exit 1; fi
if [[ "$LEVEL" = "latest" ]]; then log "Level latest is forbidden"; exit 1;fi
if [[ ! -z "$RSYNC_PASSWORD" ]]; then export RSYNC_PASSWORD=$RSYNC_PASSWORD; fi

# This breaks the trap for some reason ... 
#if [[ ! -z "$LOGFILE" ]]; then
#   exec &> >(exec tee -a "$LOGFILE") 2>&1
#fi


log "Starting Backup from $SRC to $DST."
# PIDFILE concurrency HANDLING
# Same-level-> just exit
# other-level -> wait.
mkdir -p $PID_DIR
function check_pid {
    pid=`cat $1 2>/dev/null`
    if [[ $pid -eq $$ ]]; then return 1; fi 
    ps -lp $pid &>/dev/null && ps -up $pid | grep -q $0
}
if check_pid $LEVEL_PID_FILE; then
    log "Backup already running. Exiting. $LEVEL_PID_FILE"    
    exit 1
fi
echo $$ > $LEVEL_PID_FILE
PID_FOUND=TRUE
while  [ "$PID_FOUND" != "FALSE" ]; do
    PID_FOUND=FALSE    
    for PID_FILE in `ls $PID_DIR`; do
        PID_FILE=$PID_DIR/$PID_FILE    
        if check_pid $PID_FILE; then
            log "Another Backup is already running. Waiting for $PID_FILE" 
            PID_FOUND=TRUE   
            tail --pid=`cat $PID_FILE` -f /dev/null
            # clean up if any.
            rm $PID_FILE 2>/dev/null || :  
            log "Continueing..."
        fi
    done
done

if [[ ! -d "$LATEST" ]]; then
    LINKOPT=""
fi

# Run RSYNC
#mkdir -p $DST
mkdir -p $TMP
rsync_rc=0

function cleanup {
    rsync_rc=$?
    
    if [[ $rsync_rc -ne 0 ]]; then   
        log "Backup failed with exitcode $rsync_rc. Cleanup and exit."
        rm -rf $DST 2>/dev/null || : 
        rm $LEVEL_PID_FILE        
        #sleep 10;    
    fi
    exit $rsync_rc
}
trap cleanup EXIT #INT
log_cmd rsync --info=progress2 -a $LINKOPT $EXTRA_OPTS "$SRC" "$TMP" 
trap - EXIT
mv $TMP $DST

# Symlink latest 
rm $LATEST 2>/dev/null || :
ln -sf $DST $LATEST

#  CLEANUP
log "Cleanup old backups."
i=0;
for dir in `ls -rt $ROOT/$LEVEL | grep -v latest`; do
    i=$((i+1))
    if [[ "$i" -gt "$NBACKUPS" ]]; then 
        log "Remove old Backup $ROOT/$LEVEL/$dir"
        rm -rf $ROOT/$LEVEL/$dir; 
    fi
done

log "Backup Done."

