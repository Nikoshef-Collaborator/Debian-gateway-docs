#!/bin/bash
# tg-notify.sh - Telegram-уведомления шлюза. tg-notify.sh "Заголовок" "Текст" [info|warn|crit]
# Отправка по очереди через полосы VPN_CASCADE_ORDER, затем vpn-amz, затем
# напрямую - до первого ответа Telegram "200". Причины (2026-11-01):
#  - старая версия слала только через awg0, которого в схеме давно нет -> молча не слала НИЧЕГО;
#  - WARP не всегда пускает к сети Telegram 149.154.167.x (там же api.telegram.org).
CONF=/etc/gateway/tg.conf
[ -f "$CONF" ] || { echo "tg-notify: нет конфига $CONF" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONF"
# shellcheck source=/dev/null
source /etc/gateway/gateway.conf 2>/dev/null || true
TITLE="${1:-gateway}"; MSG="${2:-тест}"; LEVEL="${3:-info}"
case "$LEVEL" in crit) ICON="🔴";; warn) ICON="🟡";; *) ICON="🟢";; esac
TEXT="${ICON} [$(hostname)] ${TITLE}
${MSG}
🕐 $(date '+%Y-%m-%d %H:%M:%S')"

send(){  # $1 = интерфейс или пусто (напрямую); 0 = Telegram принял
    local opt=() code
    [ -n "$1" ] && opt=(--interface "$1")
    code=$(curl -s "${opt[@]}" --max-time 10 -o /dev/null -w '%{http_code}' \
        -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT}" --data-urlencode "text=${TEXT}" 2>/dev/null)
    [ "$code" = "200" ]
}

for s in ${VPN_CASCADE_ORDER:-vpn-main vpn-backup} vpn-amz; do
    ip link show "$s" >/dev/null 2>&1 || continue
    send "$s" && exit 0
done
send "" && exit 0
logger -t tg-notify "не удалось отправить: $TITLE" 2>/dev/null
exit 0
