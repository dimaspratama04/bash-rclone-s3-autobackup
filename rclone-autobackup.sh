#!/bin/bash
set -euo pipefail

SRC_DIR="${LARAVEL_STORAGE:-/opt/backend/storage/app}"
SRC_SIZE=$(du -sh "$SRC_DIR" 2>/dev/null | awk '{print $1}')
REMOTE=""
BUCKET=""
BACKUP_BASE="backups/storage/$(date +%Y/%m/%d)"
ARCHIVE_BASE="archives/storage/$(date +%Y)/$(date +%F_%H%M%S)"
LOG_DIR="/var/log/backups/storage"
LOG_FILE="$LOG_DIR/storage_backup_$(date +%Y%m%d_%H%M%S).log"
ERR_FILE="$LOG_DIR/storage_backup_errors.log"
TG_TOKEN=""
TG_CHAT_ID=""

log(){ 
  echo "$(date '+%F %T') $*"; 
}

send_to_telegram(){ 
  [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT_ID" ] && \
  curl -sS -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
  -d chat_id="$TG_CHAT_ID" \
  -d text="$*" >/dev/null || true; 
}

cleanup_remote_dir(){
  BASE_MONTHLY_DIRECTORY="backups/storage/$(date +%Y/%m)" 
  DAYS=3
  FOLDERS=$(rclone lsf $REMOTE:$BUCKET/$BASE_MONTHLY_DIRECTORY --dirs-only)
  TODAY=$(date +%s)

  for FOLDER in $FOLDERS; do
    # delete trailing slash
    FOLDER_NUM=$(echo "$FOLDER" | tr -d '/')

    # check folder is number (days of month)
    if [[ "$FOLDER_NUM" =~ ^[0-9]+$ ]]; then
        FOLDER_DATE=$(date -d "$(date +%Y-%m)-$FOLDER_NUM" +%s 2>/dev/null)

        # calculate different day
        DIFF=$(( (TODAY - FOLDER_DATE) / 86400 ))

        # retrive diffrerent day of folder
        # echo "Folder: $FOLDER_NUM → age: $DIFF hari"
    
        # delete if old then DAYS
        if (( DIFF > DAYS )); then
            log "Will delete: $BASE_MONTHLY_DIRECTORY/$FOLDER (diff age $DIFF days)." | tee -a "$LOG_FILE"
            rclone purge "$REMOTE:$BUCKET/$BASE_MONTHLY_DIRECTORY/$FOLDER" \
            --log-file "$LOG_FILE" 2>>"$ERR_FILE"
        fi
    fi
done
}

command -v rclone >/dev/null || { echo "rclone not found"; exit 1; }

[ -d "$SRC_DIR" ] || { 
  echo "source dir not found: $SRC_DIR"; exit 1; 
}

mkdir -p "$LOG_DIR"

trap 'send_to_telegram "🚨 Backup STORAGE: GAGAL pada $(hostname) di $(date +"%Y-%m-%d %H:%M:%S")"; exit 1' ERR

log "Start backup: $SRC_DIR -> $REMOTE:$BUCKET/$BACKUP_BASE" | tee -a "$LOG_FILE"

# Pastikan bucket/path ada
rclone mkdir "$REMOTE:$BUCKET/$BACKUP_BASE" || true

# Sync + versi (arsip file yang berubah/hilang)
log "Sync Dimulai pada $(date +"%Y-%m-%d %H:%M:%S:%Z")." | tee -a "$LOG_FILE"
rclone sync "$SRC_DIR" "$REMOTE:$BUCKET/$BACKUP_BASE" \
  --backup-dir "$REMOTE:$BUCKET/$ARCHIVE_BASE" \
  --exclude="/absensi/**" \
  --fast-list --transfers 4 --checkers 8 --metadata \
  --s3-upload-cutoff 5M --s3-chunk-size 8M \
  --s3-upload-concurrency 8 --s3-max-upload-parts 10000 \
  --log-file "$LOG_FILE" --log-level INFO --use-server-modtime
log "Sync Selesai pada $(date +"%Y-%m-%d %H:%M:%S:%Z")." | tee -a "$LOG_FILE"

# Retensi backup harian 7 hari (arsip disimpan)
rclone delete "$REMOTE:$BUCKET/$ARCHIVE_BASE" --min-age 3d --rmdirs \
  --log-file "$LOG_FILE" --log-level INFO 2>>"$ERR_FILE"

# Delete dirs > 3days di bulan saat ini
cleanup_remote_dir
log "Delete old files Selesai pada $(date +"%Y-%m-%d %H:%M:%S:%Z")." | tee -a "$LOG_FILE"

chmod 640 "$LOG_FILE" "$ERR_FILE" || true

log "Semua proses Selesai pada $(date +"%Y-%m-%d %H:%M:%S:%Z")." | tee -a "$LOG_FILE"

RCLONE_OUTPUT=$(rclone size $REMOTE:$BUCKET/$BACKUP_BASE)
TOTAL_OBJ=$(echo "$RCLONE_OUTPUT" | grep "Total objects" | awk '{print $3}')
TOTAL_SIZE=$(echo "$RCLONE_OUTPUT" | grep "Total size" | awk '{print $3, $4}')
msg="✅ Backup STORAGE: BERHASIL pada $(hostname) di $(date +"%Y-%m-%d %H:%M:%S:%Z") 
📂 Source: $REMOTE:$BUCKET/$BACKUP_BASE 
📦 Total Object: $TOTAL_OBJ
📦 Size: $TOTAL_SIZE"

send_to_telegram "$msg"
