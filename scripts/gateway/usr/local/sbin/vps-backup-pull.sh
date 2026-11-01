#!/bin/bash
# vps-backup-pull.sh - забирает бэкап конфигурации VPS на шлюз.
# Ключ /root/.ssh/vps_backup на VPS ограничен: умеет только отдать архив.
# Сначала через туннель AmneziaWG, при неудаче - через Tailscale.
set -u
HOSTS="10.78.0.1 ПОДСТАВЬ_TS_VPS"
KEY=/root/.ssh/vps_backup
DIR=/var/backups/vps
KEEP=8
LOG=/var/log/vps-backup.log
log(){ echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
tg(){ [ -x /usr/local/sbin/tg-notify.sh ] && /usr/local/sbin/tg-notify.sh "Бэкап VPS" "$1" "$2"; }
mkdir -p "$DIR"; chmod 700 "$DIR"
umask 077
OUT="$DIR/vps-$(date +%F_%H%M).tar.gz"
ok=0
for h in $HOSTS; do
    if ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=yes "root@$h" > "$OUT.part" 2>>"$LOG" \
       && [ -s "$OUT.part" ] && gzip -t "$OUT.part" 2>/dev/null; then
        ok=1; log "получен через $h"; break
    fi
    log "через $h не вышло"
done
if [ "$ok" -ne 1 ]; then
    rm -f "$OUT.part"; log "ОШИБКА: бэкап VPS не получен"
    tg "ОШИБКА: бэкап VPS не получен (лог $LOG)" warn; exit 1
fi
mv "$OUT.part" "$OUT"
grep -q 'etc/amnezia/amneziawg/awg1.conf' <(tar tzf "$OUT") || { log "ОШИБКА: в архиве нет awg1.conf"; tg "ОШИБКА: в бэкапе VPS нет awg1.conf" warn; exit 1; }
ls -1t "$DIR"/vps-*.tar.gz | tail -n +$((KEEP+1)) | xargs -r rm -f
log "готово: $(basename "$OUT"), $(du -h "$OUT" | cut -f1), хранится $(ls -1 "$DIR"/vps-*.tar.gz | wc -l)"
exit 0
