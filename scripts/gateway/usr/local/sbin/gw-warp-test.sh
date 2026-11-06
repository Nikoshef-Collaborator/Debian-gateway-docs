#!/bin/bash
# gw-warp-test.sh <файл_в_pool> - рукопожатие, пинг, скорость на интерфейсе warptest
# Пул - /etc/gateway/pool или /etc/warp/pool (как у warp-pick).
set -u
export LC_ALL=C   # иначе awk пишет скорость с запятой
[ "$(id -u)" -eq 0 ] || { echo "запускай через sudo"; exit 1; }
# интерфейс warptest один на всех: второй тест ждёт первого (до 3 минут)
exec 8>/run/gw-warp-test.lock
flock -w 180 8 || { echo "РЕЗУЛЬТАТ: другой тест занял warptest больше 3 минут - пропуск"; exit 1; }
SRC=""
for d in /etc/gateway/pool /etc/warp/pool; do [ -f "$d/${1:-}" ] && { SRC="$d/$1"; break; }; done
[ -n "$SRC" ] || { echo "Использование: $0 <файл_в_pool>  (нет в /etc/gateway/pool и /etc/warp/pool)"; exit 1; }
# Конфиг с тем же ключом, что уже стоит в слоте, тестировать нельзя: Cloudflare
# пускает трафик только по одному из двух туннелей - рукопожатие есть, скорость 0.
KEY=$(awk '/^[[:space:]]*PrivateKey[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,""); print; exit}' "$SRC")
for t in /etc/gateway/tunnels/vpn-*.conf; do
    [ -n "$KEY" ] && [ -f "$t" ] && grep -qF -- "$KEY" "$t" && {
        echo "этот конфиг сейчас стоит в слоте $(basename "$t" .conf) - тест дал бы скорость 0, выбери другой"; exit 1; }
done
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
# код ответа и размер: 0 MB/s без них не отличить "туннель не везёт" от "сервер отказал"
read -r code bps size < <(curl -o /dev/null -s --interface "$TESTIF" -m 20 -w '%{http_code} %{speed_download} %{size_download}' "$TEST_URL" 2>/dev/null)
# через какой узел Cloudflare идёт туннель (DME = Москва) и кем нас видят сайты
trace=$(curl -s -m 8 --interface "$TESTIF" https://cloudflare.com/cdn-cgi/trace 2>/dev/null)
colo=$(echo "$trace" | awk -F= '$1=="colo"{print $2}'); loc=$(echo "$trace" | awk -F= '$1=="loc"{print $2}')
echo "РЕЗУЛЬТАТ: OK"; echo "  рукопожатие:$hs"; echo "  пинг: ${ping_avg:-н/д} ms"
echo "  узел: ${colo:-н/д}, сайты видят: ${loc:-н/д}"
if [ "${code:-000}" = 200 ] && [ "${size:-0}" -gt 0 ]; then
    echo "  скорость: $(awk "BEGIN{printf \"%.1f\", ${bps:-0}/1048576}") MB/s (скачано ${size} байт)"
else
    echo "  скорость: не измерена (HTTP ${code:-000}, скачано ${size:-0} байт; 000 = ничего не пришло)"
fi
