#!/bin/bash
# gw-pool-delete.sh <имя_файла> - удалить конфиг из пула (только имя, без путей)
set -u
NAME=$(basename -- "${1:-}")
case "$NAME" in ""|.|..) echo "некорректное имя" >&2; exit 1 ;; esac
[ -f "/etc/gateway/pool/$NAME" ] || { echo "нет в пуле: $NAME" >&2; exit 1; }
rm -f -- "/etc/gateway/pool/$NAME"; logger -t gw-pool "удалён: $NAME"; echo "Удалено: $NAME"
/usr/local/sbin/gw-pool-refresh-entities.sh
