#!/bin/bash
# gw-orchestrator.sh - каскадный вотчдог дефолтной полосы (таблица 100).
#  - живость по возрасту handshake (не ping/curl: те дают ложные провалы)
#  - падение подтверждается 3 провалами, восстановление немедленное
#  - все слоты мертвы -> blackhole, а НЕ напрямую (не выпускать дом в открытую)
#  - conntrack -F при смене выхода
#  - пока warp-pick перебирает конфиги (держит lock), тик пропускается
#  - WARP умер и дом ушёл на резерв -> сам запускает перебор WARP-конфигов
#    (warp-rotate), не чаще раза в 15 мин; первые 10 мин после загрузки - нет
#
# ===== ЗАМЕТКА ДЛЯ ИИ / БУДУЩЕГО РЕДАКТОРА =====
# Политика владельца: WARP (vpn-main) - ОСНОВНОЙ канал, свой VPS (vpn-backup) - только РЕЗЕРВ.
# Гонять весь дом через VPS постоянно нежелательно. Не меняй это без согласия владельца.
# Если WARP закроют насовсем (весь пул конфигов стабильно без handshake/трафика днями,
# warp-pick раз за разом пишет "все попытки мимо"), политику меняют так:
#   1) /etc/gateway/gateway.conf: VPN_CASCADE_ORDER="vpn-backup vpn-main" (VPS первым);
#   2) здесь отключить блок "авто-перебор WARP" внизу (или поднять REPICK_EVERY до часов),
#      а warp-rotate.timer выключить - иначе перебор будет зря дёргать мёртвый WARP.
# Сам каскад/failback переписывать не нужно: порядок задаётся только VPN_CASCADE_ORDER.
# ================================================
set -u
source /etc/gateway/gateway.conf 2>/dev/null || true
LOG_TAG="gw-orchestrator"
CASCADE="${VPN_CASCADE_ORDER:-vpn-main vpn-backup}"
FAIL_THRESHOLD=3
PICK_LOCK="/run/warp-pick.lock"

pick_busy() {
    # фигурные скобки обязательны: голый "exec 8>... 2>/dev/null"
    # навсегда отправил бы stderr всего скрипта в /dev/null
    { exec 8>"$PICK_LOCK"; } 2>/dev/null || return 1
    if flock -n 8; then flock -u 8; exec 8>&-; return 1
    else exec 8>&-; return 0; fi
}

slot_ok() {
    local s="$1" hs now age
    ip link show "$s" >/dev/null 2>&1 || return 1
    hs=$(awg show "$s" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
    { [ -z "$hs" ] || [ "$hs" = "0" ]; } && return 1
    now=$(date +%s); age=$(( now - hs ))
    [ "$age" -lt 180 ]
}

first_live_slot() {
    local s
    for s in $CASCADE; do slot_ok "$s" && { echo "$s"; return 0; }; done
    return 1
}

set_route() {
    local table="$1" dev="$2" cur
    # первая строка таблицы - действующий маршрут (меньшая метрика выше)
    cur=$(ip route show table "$table" 2>/dev/null | awk '/^blackhole default/{print "blackhole"; exit} /^default/{print $3; exit}')
    if [ "$dev" = "blackhole" ]; then
        [ "$cur" = "blackhole" ] && return 0
        ip route replace blackhole default table "$table"
        logger -t "$LOG_TAG" "table $table -> BLACKHOLE (kill-switch)"
        conntrack -F 2>/dev/null || true
    else
        [ "$cur" = "$dev" ] && return 0
        ip route replace default dev "$dev" table "$table"
        logger -t "$LOG_TAG" "table $table -> $dev"
        conntrack -F 2>/dev/null || true
    fi
}

handle_lane_ks() {
    local table="$1" live n failfile
    failfile="/run/gw-lane${table}-fail"
    live=$(first_live_slot)
    if [ -n "$live" ]; then rm -f "$failfile"; set_route "$table" "$live"; return; fi
    n=$(( $(cat "$failfile" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$failfile"
    [ "$n" -lt "$FAIL_THRESHOLD" ] && { logger -t "$LOG_TAG" "table $table: все слоты мертвы, $n/$FAIL_THRESHOLD"; return; }
    set_route "$table" blackhole
}

if pick_busy; then
    logger -t "$LOG_TAG" "warp-pick активен, тик пропущен"
    exit 0
fi

# страховка: blackhole с метрикой 1000 ПОД основным маршрутом. Если интерфейс
# слота исчезнет, его маршрут пропадёт - трафик упрётся сюда, а не утечёт в main.
ip route replace blackhole default metric 1000 table 100 2>/dev/null || true
handle_lane_ks 100

# авто-перебор WARP: дом не на vpn-main (WARP мёртв) -> ищем живой WARP-конфиг.
# Асинхронно (--no-block): тик не ждёт. Не чаще REPICK_EVERY секунд.
REPICK_EVERY=900
cur=$(ip route show table 100 2>/dev/null | awk '/^default dev/{print $3; exit}')
# первые 10 мин после загрузки WARP поднимает warp-pick-boot - не мешаем ему
if [ "$cur" != "vpn-main" ] && [ "$(cut -d. -f1 /proc/uptime)" -ge 600 ]; then
    stamp=/run/gw-warp-repick
    last=$(stat -c %Y "$stamp" 2>/dev/null || echo 0)
    if [ $(( $(date +%s) - last )) -ge "$REPICK_EVERY" ]; then
        touch "$stamp"
        logger -t "$LOG_TAG" "WARP мёртв, дом на ${cur:-blackhole} - запускаю перебор WARP (warp-rotate)"
        systemctl start --no-block warp-rotate.service 2>/dev/null || true
    fi
fi
