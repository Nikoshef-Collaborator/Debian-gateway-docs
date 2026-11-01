#!/bin/bash
# backup-immich.sh - бэкап Immich: живая библиотека -> снимки на другом диске.
# Запуск: sudo backup-immich.sh [--force]
set -u
SRC=/mnt/photos/immich            # живая библиотека (UPLOAD_LOCATION)
DST=/mnt/backup/immich-snap       # снимки - на ДРУГОМ диске
DBLOCAL=/var/backups/immich-db    # последний дамп базы - на системном SSD
KEEP=8                            # сколько снимков хранить
QUIET_FROM=21; QUIET_TO=9         # в эти часы не запускаться (шумный диск)
LOG=/var/log/backup-immich.log
STATE=/var/lib/backup-immich
FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1

log(){ echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
tg(){ [ -x /usr/local/sbin/tg-notify.sh ] && /usr/local/sbin/tg-notify.sh "Бэкап Immich" "$1" "$2"; }
fail(){ log "ERROR: $*"; tg "ОШИБКА: $* (лог $LOG)" warn; exit 1; }

h=$((10#$(date +%H)))
if [ "$FORCE" -eq 0 ] && { [ "$h" -ge "$QUIET_FROM" ] || [ "$h" -lt "$QUIET_TO" ]; }; then
  log "тихие часы ($h ч) - пропуск"; exit 0
fi

mountpoint -q "$(dirname "$SRC")" || fail "диск библиотеки $(dirname "$SRC") не примонтирован"
mountpoint -q "$(dirname "$DST")" || fail "диск бэкапа $(dirname "$DST") не примонтирован"
LIVE=$(docker inspect immich_server --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
[ "$LIVE" = "$SRC" ] || fail "живая библиотека Immich '$LIVE' != SRC '$SRC' - поправь SRC"
mkdir -p "$DST" "$DBLOCAL" "$STATE"

log "=== старт ==="
TMP="$DBLOCAL/new.sql"
docker exec immich_postgres pg_dumpall -U postgres > "$TMP" 2>>"$LOG" || fail "дамп базы"
[ -s "$TMP" ] || fail "дамп базы пустой"
NEWMD5=$(md5sum < "$TMP" | cut -d' ' -f1)
OLDMD5=$(cat "$STATE/db.md5" 2>/dev/null)

if [ -f "$STATE/last-ok" ] && [ "$FORCE" -eq 0 ]; then
  NEWF=$(find "$SRC" -newer "$STATE/last-ok" -type f -print -quit 2>/dev/null)
  if [ -z "$NEWF" ] && [ "$NEWMD5" = "$OLDMD5" ]; then
    rm -f "$TMP"; log "изменений нет - пропуск"; exit 0
  fi
fi

SNAP="$DST/$(date +%F_%H%M)"
LATEST=$(ls -1d "$DST"/20??-??-??_???? 2>/dev/null | tail -1)
log "снимок $SNAP${LATEST:+ (от $LATEST)}"
rsync -aAX --delete ${LATEST:+--link-dest="$LATEST"} "$SRC/" "$SNAP.partial/" >>"$LOG" 2>&1
rc=$?
[ "$rc" -eq 0 ] || [ "$rc" -eq 24 ] || fail "rsync rc=$rc"
mkdir -p "$SNAP.partial/_db"
gzip -c "$TMP" > "$SNAP.partial/_db/immich-db.sql.gz" || fail "gzip дампа"
mv "$SNAP.partial" "$SNAP" || fail "переименование снимка"

[ -f "$DBLOCAL/latest.sql.gz" ] && mv -f "$DBLOCAL/latest.sql.gz" "$DBLOCAL/previous.sql.gz"
gzip -c "$TMP" > "$DBLOCAL/latest.sql.gz"; rm -f "$TMP"

ls -1d "$DST"/20??-??-??_???? | head -n -"$KEEP" | while read -r old; do
  rm -rf -- "$old" && log "удалён старый снимок $old"
done
rm -rf "$DST"/*.partial 2>/dev/null

echo "$NEWMD5" > "$STATE/db.md5"; touch "$STATE/last-ok"
N=$(ls -1d "$DST"/20??-??-??_???? | wc -l)
log "=== готово: снимков $N ==="
tg "Готово, снимок $(basename "$SNAP"), всего снимков $N" info
exit 0
