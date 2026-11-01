#!/bin/bash
# gw-warp-test.sh <файл_в_pool> - рукопожатие, пинг, скорость на интерфейсе warptest
set -u
[ "$(id -u)" -eq 0 ] || { echo "запускай через sudo"; exit 1; }
SRC="/etc/gateway/pool/${1:-}"
[ -f "$SRC" ] || { echo "Использование: $0 <файл_в_pool>"; exit 1; }
TESTIF=warptest; TESTCONF="/etc/gateway/tunnels/${TESTIF}.conf"
TEST_URL="https://speed.cloudflare.com/__down?bytes=5000000"
cleanup(){ awg-quick down "$TESTCONF" 2>/dev/null; rm -f "$TESTCONF"; }
trap cleanup EXIT
awk '
/^[[:space:]]*(DNS|Table|PreUp|PostUp|PreDown|PostDown)[[:space:]]*=/ { next }
/^[[:space:]]*(Address|AllowedIPs)[[:space:]]*=/ {
    eq=index($0,"="); key=substr($0,1,eq-1); n=split(substr($0,eq+1),p,","); out=""
    for(i=1;i<=n;i++){ gsub(/^[ \t]+|[ \t]+$/,"",p[i]); if(p[i]!~/:/) out=(out==""?p[i]:out", "p[i]) }
    if(out!="") print key"= "out; next }
{ print }' "$SRC" > "$TESTCONF"
sed -i '/^\[Interface\]/a Table = off' "$TESTCONF"; chmod 600 "$TESTCONF"
awg-quick up "$TESTCONF" >/dev/null 2>&1 || { echo "РЕЗУЛЬТАТ: awg-quick up ошибка -> конфиг мёртв"; exit 1; }
# без keepalive рукопожатие само не стартует - пинаем пакетом и меряем пинг
ping_avg=$(ping -I "$TESTIF" -c3 -W3 1.1.1.1 2>/dev/null | awk -F'/' '/rtt|round-trip/{print $5}')
hs=$(awg show "$TESTIF" 2>/dev/null | awk '/latest handshake/{$1=$2=""; print}')
[ -z "$hs" ] && { echo "РЕЗУЛЬТАТ: нет рукопожатия -> конфиг мёртв"; exit 1; }
bps=$(curl -o /dev/null -s --interface "$TESTIF" -m 20 -w '%{speed_download}' "$TEST_URL" 2>/dev/null | tr ',' '.')
echo "РЕЗУЛЬТАТ: OK"; echo "  рукопожатие:$hs"; echo "  пинг: ${ping_avg:-н/д} ms"
echo "  скорость: $(awk "BEGIN{printf \"%.1f\", ${bps:-0}/1048576}") MB/s"
