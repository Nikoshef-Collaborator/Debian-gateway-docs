#!/bin/bash
# warp-bench.sh - скорость каждого конфига пула на временном интерфейсе wgbench.
# Боевые слоты (vpn-main/vpn-backup/vpn-amz) не трогает.
# Конфиг готовится так же, как в warp-pick: Table=off, без DNS/IPv6/Pre-PostUp,
# AllowedIPs только IPv4, keepalive 25.
# Результат: скорость_MBps|connect_ms|конфиг (мёртвые: 0|9999|конфиг), лучшие сверху.
# Пулы по умолчанию: /etc/warp/pool и /etc/gateway/pool (или POOL=папка).
set -u
export LC_ALL=C LC_NUMERIC=C
POOLS=${POOL:-"/etc/warp/pool /etc/gateway/pool"}
RESULTS=${RESULTS:-/etc/warp/bench-results}
TESTIF=wgbench
TMPCONF=/run/${TESTIF}.conf
TEST_URL="https://speed.cloudflare.com/__down?bytes=5000000"

say(){ echo "[warp-bench] $*"; logger -t warp-bench "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "запускай через sudo"; exit 1; }
exec 9>/run/warp-bench.lock; flock -n 9 || { say "уже запущен"; exit 0; }

cleanup(){ awg-quick down "$TMPCONF" >/dev/null 2>&1; ip link del "$TESTIF" 2>/dev/null; rm -f "$TMPCONF"; }
trap cleanup EXIT

prep(){
    awk '
        /^\[Interface\]/ { print; print "Table = off"; next }
        /^[[:space:]]*Table[[:space:]]*=/ { next }
        /^[[:space:]]*(PreUp|PostUp|PreDown|PostDown)[[:space:]]*=/ { next }
        /^[[:space:]]*PersistentKeepalive[[:space:]]*=/ { next }
        /^\[Peer\]/ { print; print "PersistentKeepalive = 25"; next }
        /^[[:space:]]*DNS[[:space:]]*=/ { next }
        /^[[:space:]]*Address[[:space:]]*=/ { sub(/,.*/,""); print; next }
        /^[[:space:]]*AllowedIPs[[:space:]]*=/ { print "AllowedIPs = 0.0.0.0/0"; next }
        { print }
    ' "$1" > "$TMPCONF"
    chmod 600 "$TMPCONF"
}

cfgs=()
for d in $POOLS; do for f in "$d"/*.conf; do [ -f "$f" ] && cfgs+=("$f"); done; done
[ "${#cfgs[@]}" -eq 0 ] && { say "пул пуст: $POOLS"; exit 1; }
say "старт: ${#cfgs[@]} конфигов на $TESTIF (боевые не трогаю)"

tmp=$(mktemp)
for cfg in "${cfgs[@]}"; do
    name=$(basename "$cfg")
    cleanup; sleep 2
    prep "$cfg"
    if ! err=$(awg-quick up "$TMPCONF" 2>&1); then
        say "  $name: awg-quick ошибка -> $(echo "$err" | grep -iE 'error|invalid|unable' | head -1)"
        echo "0|9999|$cfg" >> "$tmp"; continue
    fi
    ping -c2 -W2 -I "$TESTIF" 1.1.1.1 >/dev/null 2>&1   # пнуть рукопожатие
    hs=0
    for i in $(seq 1 16); do
        h=$(awg show "$TESTIF" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
        [ -n "$h" ] && [ "$h" != "0" ] && { hs=1; break; }
        sleep 0.5
    done
    if [ "$hs" -eq 0 ]; then
        say "  $name: нет рукопожатия -> мёртв"; echo "0|9999|$cfg" >> "$tmp"; continue
    fi
    res=$(curl -s --max-time 20 --interface "$TESTIF" -o /dev/null -w '%{speed_download}|%{time_connect}' "$TEST_URL" 2>/dev/null)
    bps=$(echo "$res" | cut -d'|' -f1 | tr ',' '.' | cut -d'.' -f1)
    cs=$(echo "$res" | cut -d'|' -f2 | tr ',' '.')
    mbps=$(awk "BEGIN{printf \"%.1f\", ${bps:-0}/1048576}")
    cms=$(awk "BEGIN{printf \"%.1f\", ${cs:-0}*1000}")
    if awk "BEGIN{exit !(${mbps:-0} > 0.1)}"; then
        say "  $name: ${mbps} MB/s, connect ${cms} ms"; echo "${mbps}|${cms}|$cfg" >> "$tmp"
    else
        say "  $name: рукопожатие есть, скорость 0 -> мёртв"; echo "0|9999|$cfg" >> "$tmp"
    fi
done
sort -t'|' -k1 -rn "$tmp" > "$RESULTS"; rm -f "$tmp"
say "готово. Лидер: $(head -1 "$RESULTS")"
say "рейтинг: $RESULTS"
