#!/bin/bash
# gw-slot-clear.sh <vpn-main|vpn-backup|vpn-amz> - остановить слот, конфиг в .bak
set -u
[ "$(id -u)" -eq 0 ] || { echo "запускай через sudo"; exit 1; }
SLOT="${1:-}"
case "$SLOT" in vpn-main|vpn-backup|vpn-amz) ;; *) echo "ERROR: неизвестный слот '$SLOT'"; exit 1 ;; esac
systemctl stop "vpn-slot@${SLOT}.service" 2>/dev/null
DST="/etc/gateway/tunnels/${SLOT}.conf"
[ -f "$DST" ] && mv "$DST" "${DST}.bak-$(date +%Y%m%d-%H%M%S)" && echo "Слот $SLOT очищен, конфиг в .bak"
logger -t gw-slot "очищен слот: $SLOT"
[ "$SLOT" = "vpn-main" ] && echo "ВНИМАНИЕ: vpn-main - основная полоса. Без него дом на запасном слоте или в kill-switch."
exit 0
