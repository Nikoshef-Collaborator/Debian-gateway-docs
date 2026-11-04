#!/bin/bash
# warp-pick.sh [--force] - переключить vpn-main на случайный здоровый конфиг из пула.
#  - lock /run/warp-pick.lock на время перебора (оркестратор в это время молчит)
#  - ждёт WAN до 120 с (после простоя линк и DHCP поднимаются не сразу)
#  - первые 15 мин после загрузки: если текущий конфиг здоров - не трогает
#  - успешный откат на lastgood = exit 0
set -u
export LC_ALL=C
POOLS=(/etc/warp/pool /etc/gateway/pool)
SLOT=vpn-main
CONF=/etc/gateway/tunnels/${SLOT}.conf
GOOD=/etc/gateway/tunnels/${SLOT}.conf.lastgood
STATE=/etc/warp/pool-last
ATTEMPTS=5
PING_MAX=400
PROBE_TRIES=3
PROBE_MIN=2
FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1

say(){ echo "[warp-pick] $*"; logger -t warp-pick "$*"; }

# привести конфиг из пула к формату слота
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
    ' "$1" > "$2"
    chmod 600 "$2"
}

health(){
    local avg code ok url tries
    avg=$(ping -I "$SLOT" -c3 -W3 1.1.1.1 2>/dev/null | awk -F'/' '/rtt|round-trip/{print $5}')
    [ -z "$avg" ] && { say "  нет связи через $SLOT (ping)"; return 1; }
    awk "BEGIN{exit !($avg+0 <= $PING_MAX)}" || { say "  пинг ${avg}ms > ${PING_MAX}"; return 1; }
    ok=0
    for url in https://api.telegram.org https://web.whatsapp.com https://discord.com; do
        for tries in $(seq 1 "$PROBE_TRIES"); do
            code=$(curl --interface "$SLOT" -s -o /dev/null -m8 -w '%{http_code}' "$url" 2>/dev/null)
            [ "$code" != "000" ] && { ok=$((ok+1)); break; }
            sleep 1
        done
    done
    [ "$ok" -ge "$PROBE_MIN" ] && { say "  OK: пинг ${avg}ms, мессенджеры ${ok}/3"; return 0; }
    say "  мессенджеры не отвечают (${ok}/3)"; return 1
}

# ТОЛЬКО через systemd. Если звать awg-quick напрямую, а модуля ядра нет,
# процесс amneziawg-go попадёт в службу, запустившую warp-pick, и systemd
# убьёт его вместе с ней - туннель пропадёт через ~40 с после выбора.
restart_slot(){
    systemctl restart "vpn-slot@${SLOT}" 2>/dev/null || true
    ping -c2 -W2 -I "$SLOT" 1.1.1.1 >/dev/null 2>&1   # пнуть рукопожатие
}

wait_wan(){
    local t=0
    while [ "$t" -lt 120 ]; do
        ping -c1 -W2 -I wan 1.1.1.1 >/dev/null 2>&1 && return 0
        curl -s -o /dev/null -m4 --interface wan http://1.1.1.1 2>/dev/null && return 0
        sleep 3; t=$((t+3))
    done
    return 1
}

kick_orch(){ flock -u 9 2>/dev/null; systemctl start gw-orchestrator.service 2>/dev/null || true; }

[ "$(id -u)" -eq 0 ] || { echo "запускай через sudo"; exit 1; }
exec 9>/run/warp-pick.lock
flock -n 9 || { say "другой warp-pick уже работает - этот запуск не нужен"; exit 0; }   # 0: не ошибка, иначе служба висит в failed

cfgs=()
for d in "${POOLS[@]}"; do
    [ -d "$d" ] || mkdir -p "$d"
    for f in "$d"/*.conf; do [ -f "$f" ] && cfgs+=("$f"); done
done
[ "${#cfgs[@]}" -eq 0 ] && { say "пул пуст: положи конфиги в ${POOLS[*]}"; exit 1; }
[ -f "$GOOD" ] || { [ -f "$CONF" ] && cp -a "$CONF" "$GOOD"; }

wait_wan || { say "WAN не поднялся за 120 с - оставляю текущий конфиг"; exit 1; }

up=$(cut -d. -f1 /proc/uptime)
if [ "$FORCE" -eq 0 ] && [ "$up" -lt 900 ] && ip link show "$SLOT" >/dev/null 2>&1; then
    say "загрузка (uptime ${up} с): проверяю текущий конфиг"
    if health; then kick_orch; say "текущий конфиг здоров - оставляю (--force для перебора)"; exit 0; fi
fi

# на время перебора дом -> vpn-backup (если реально жив), чтобы не было простоя.
# После выбора оркестратор сам вернёт дом на vpn-main.
if curl --interface vpn-backup -s -o /dev/null -m5 https://cloudflare.com/cdn-cgi/trace 2>/dev/null; then
    ip route replace default dev vpn-backup table 100 2>/dev/null && say "дом на время перебора -> vpn-backup"
    conntrack -F 2>/dev/null || true
fi

mapfile -t order < <(printf '%s\n' "${cfgs[@]}" | shuf)
i=0
for pick in "${order[@]}"; do
    i=$((i+1)); [ "$i" -gt "$ATTEMPTS" ] && break
    say "попытка $i/$ATTEMPTS: $(basename "$pick")"
    prep "$pick" "$CONF"
    restart_slot; sleep 5
    if health; then
        cp -a "$CONF" "$GOOD"; echo "$pick" > "$STATE"
        kick_orch; say "ВЫБРАН: $(basename "$pick")"; exit 0
    fi
done

say "все попытки мимо - откат на lastgood"
if [ -f "$GOOD" ]; then
    cp -a "$GOOD" "$CONF"; restart_slot; sleep 5
    health && { kick_orch; say "lastgood поднят"; exit 0; }
fi
kick_orch
exit 1
