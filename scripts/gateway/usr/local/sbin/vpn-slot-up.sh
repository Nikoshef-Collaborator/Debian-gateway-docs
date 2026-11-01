#!/bin/sh
# vpn-slot-up.sh <слот> - после awg-quick up: endpoint слота -> напрямую через WAN.
SLOT="$1"
CONF="/etc/gateway/tunnels/${SLOT}.conf"
EP=$(awk -F'=' '/^[[:space:]]*Endpoint/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$CONF")
EP_HOST="${EP%%:*}"
case "$EP_HOST" in
    *[!0-9.]*) EP_IP=$(getent ahostsv4 "$EP_HOST" 2>/dev/null | awk '{print $1; exit}') ;;
    *) EP_IP="$EP_HOST" ;;
esac
if [ -n "$EP_IP" ]; then
    WAN_IF_R=$(ip route show default | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    # шлюз - слово после "via"; у PPPoE (Часть 9) шлюза нет - маршрут просто через интерфейс
    WAN_GW_R=$(ip route show default | awk '/default/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
    if [ -n "$WAN_GW_R" ] || [ -n "$WAN_IF_R" ]; then
        if [ -n "$WAN_GW_R" ]; then
            ip route replace "$EP_IP/32" via "$WAN_GW_R" dev "${WAN_IF_R:-wan}" 2>/dev/null
        else
            ip route replace "$EP_IP/32" dev "$WAN_IF_R" 2>/dev/null   # PPPoE: шлюза нет, маршрут через интерфейс
        fi
        nft add element ip gwroute endpoints "{ $EP_IP }" 2>/dev/null || true
        logger -t vpn-slot "endpoint $EP_IP pinned to WAN ($WAN_GW_R)"
    fi
fi
# Свой VPS (Часть 6): внутренняя сеть туннеля через vpn-backup -
# доступ к VPS по туннелю и обратный путь для профилей "Чебурнет"/"Дом".
[ "$SLOT" = "vpn-backup" ] && ip route replace 10.78.0.0/24 dev vpn-backup
# exit 0 ОБЯЗАТЕЛЕН: для других слотов строка выше возвращает 1, systemd
# считает запуск проваленным и сносит туннель.
exit 0
