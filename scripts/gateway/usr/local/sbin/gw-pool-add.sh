#!/bin/bash
# gw-pool-add.sh <имя> <текст_конфига> - сохранить конфиг в пул
set -u
[ "$(id -u)" -eq 0 ] || { echo "запускай через sudo"; exit 1; }
POOL="/etc/gateway/pool"; RAW="${1:-}"; BODY="${2:-}"
NAME=$(basename -- "$RAW" | tr -cd 'A-Za-z0-9._-')
[ -n "$NAME" ] || NAME="manual-$(date +%Y%m%d-%H%M%S)"
case "$NAME" in *.conf) ;; *) NAME="${NAME}.conf" ;; esac
[ -n "$BODY" ] || { echo "ERROR: пустой текст конфига"; exit 1; }
printf '%s' "$BODY" | grep -q '\[Interface\]' || { echo "ERROR: нет [Interface] - это не конфиг WG/AWG"; exit 1; }
mkdir -p "$POOL"; DST="${POOL}/${NAME}"
[ -f "$DST" ] && cp "$DST" "${DST}.bak-$(date +%Y%m%d-%H%M%S)"
printf '%s\n' "$BODY" > "$DST"; chmod 600 "$DST"
logger -t gw-pool "добавлен конфиг: $NAME"; echo "Добавлено в пул: $NAME"
/usr/local/sbin/gw-pool-refresh-entities.sh
