#!/bin/bash
# gw-warp-activate.sh <файл_в_pool> <vpn-main|vpn-backup|vpn-amz>
set -u
[ "$(id -u)" -eq 0 ] || { echo "запускай через sudo"; exit 1; }
POOLFILE="${1:-}"; SLOT="${2:-}"
case "$SLOT" in vpn-main|vpn-backup|vpn-amz) ;; *) echo "Использование: $0 <файл_в_pool> <vpn-main|vpn-backup|vpn-amz>"; exit 1 ;; esac
SRC="/etc/gateway/pool/${POOLFILE}"; DST="/etc/gateway/tunnels/${SLOT}.conf"
[ -f "$SRC" ] || { echo "ERROR: нет в пуле: $SRC"; exit 1; }
[ -f "$DST" ] && cp "$DST" "${DST}.bak-$(date +%Y%m%d-%H%M%S)"
# убрать DNS= (DNS на шлюзе - dnsmasq; awg-quick падает без resolvconf),
# Pre/PostUp (чужие скрипты), IPv6-адреса (IPv6 выключен - awg-quick up падает)
awk '
/^[[:space:]]*(DNS|PreUp|PostUp|PreDown|PostDown)[[:space:]]*=/ { next }
/^[[:space:]]*(Address|AllowedIPs)[[:space:]]*=/ {
    eq=index($0,"="); key=substr($0,1,eq-1); n=split(substr($0,eq+1),p,","); out=""
    for(i=1;i<=n;i++){ gsub(/^[ \t]+|[ \t]+$/,"",p[i]); if(p[i]!~/:/) out=(out==""?p[i]:out", "p[i]) }
    if(out!="") print key"= "out; next }
{ print }' "$SRC" > "$DST"
chmod 600 "$DST"
# Table: vpn-amz сам ведёт таблицу 200, остальные - off (иначе awg-quick
# перехватит весь трафик шлюза своим ip rule)
TBL=off; [ "$SLOT" = "vpn-amz" ] && TBL=200
sed -i '/^[[:space:]]*Table[[:space:]]*=/d' "$DST"
sed -i "/^\[Interface\]/a Table = $TBL" "$DST"
# keepalive обязателен: оркестратор судит о живости по свежести рукопожатия
grep -qE '^[[:space:]]*PersistentKeepalive' "$DST" || sed -i '/^\[Peer\]/a PersistentKeepalive = 25' "$DST"
systemctl restart "vpn-slot@${SLOT}.service"; sleep 3
ping -c2 -W2 -I "$SLOT" 1.1.1.1 >/dev/null 2>&1
hs=$(awg show "$SLOT" 2>/dev/null | awk '/latest handshake/{$1=$2=""; print}')
[ -n "$hs" ] && echo "OK: $SLOT из $POOLFILE, рукопожатие:$hs" || echo "WARNING: $SLOT перезапущен, рукопожатия нет - проверь конфиг"
