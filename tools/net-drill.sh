#!/bin/bash
# net-drill.sh - автоматические учения шлюза (2026-11-02). ~45 минут.
# Запуск (переживает обрыв SSH):  sudo systemd-run --unit=net-drill /usr/local/sbin/net-drill.sh [s3 s5 s6 s4]
#   без аргументов - все сценарии по порядку
# Смотреть:                       tail -f /var/log/net-drill.log   (Ctrl+C учения не прерывает)
# Прервать:                       sudo systemctl stop net-drill    (блокировки снимутся, службы поднимутся)
# Сценарии: S3 блок VPS, S5 сбои служб, S6 падение туннеля WARP, S4 пропал весь интернет.
LOG=/var/log/net-drill.log; T="inet nettest"; LANIP=192.168.50.100; ARGS="$*"
declare -a RES

log(){ echo "$(date +%T) $*" | tee -a "$LOG"; }
# через что LAN выходит наружу; при blackhole/unreachable ip route get пишет ошибку -> "нет-маршрута"
lan_dev(){ ip route get 1.1.1.1 from "$LANIP" iif lan 2>&1 | grep -oE 'dev [^ ]+' | head -1 | sed 's/^dev //' | grep . || echo "нет-маршрута"; }
amz_dev(){ ip route get 1.1.1.1 from "$LANIP" iif lan mark 0x200 2>&1 | grep -oE 'dev [^ ]+' | head -1 | sed 's/^dev //' | grep . || echo "нет-маршрута"; }
hs_age(){ local t; t=$(awg show "$1" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
          if [ -n "$t" ] && [ "$t" != 0 ]; then echo $(( $(date +%s) - t )); else echo 99999; fi; }
ts_on(){ tailscale status --json 2>/dev/null | jq -r '.Self.Online' 2>/dev/null; }
dns_ok(){ dig +short +time=2 +tries=1 example.com @127.0.0.1 2>/dev/null | grep -q .; }
snap(){ log "    lan=$(lan_dev) amz=$(amz_dev) ts=$(ts_on) hs: main=$(hs_age vpn-main) backup=$(hs_age vpn-backup) amz=$(hs_age vpn-amz) ts->tun=$(ip rule show priority 5200 | wc -l) dns=$(dns_ok && echo ok || echo НЕТ)"; }
wait_for(){  # описание, секунд, условие -> 0 если дождались
    local desc=$1 lim=$2 cond=$3 t=0
    while [ "$t" -lt "$lim" ]; do
        if eval "$cond"; then log "  + $desc - за ${t} с"; return 0; fi
        [ $((t % 60)) -eq 0 ] && snap
        sleep 15; t=$((t + 15))
    done
    log "  - $desc - НЕ дождались за ${lim} с"; snap; return 1
}
result(){ RES+=("$1: $2"); log "=== $1: $2"; }
block_all(){
    nft list table $T >/dev/null 2>&1 || {
        systemctl stop 'nettest-unblock-*.timer' 2>/dev/null
        nft add table $T
        nft add chain $T out '{ type filter hook postrouting priority 0; policy accept; }'
    }
    nft add rule $T out oifname "wan" counter drop comment '"all"'
}
cleanup(){
    systemctl stop 'nettest-unblock-*.timer' 2>/dev/null
    nft delete table $T 2>/dev/null
    for s in tailscaled dnscrypt-proxy dnsmasq; do systemctl is-active -q "$s" || systemctl start "$s"; done
}
trap 'cleanup; log "прервано - блокировки сняты"; exit 1' INT TERM

: > "$LOG"
log "УЧЕНИЯ: старт"; snap
[ "$(lan_dev)" = vpn-main ] || { log "исходно LAN не через vpn-main - учения не начинаю"; exit 1; }
want(){ [ -z "$ARGS" ] || [[ " $ARGS " == *" $1 "* ]]; }

if want s3; then
# --- S3: блок VPS. Дом не должен заметить, полоса ИИ/голоса - без запасного выхода
log "S3: блокирую VPS"; net-test.sh block-vps >> "$LOG" 2>&1
bad=0
for _ in $(seq 24); do [ "$(lan_dev)" = vpn-main ] || bad=1; sleep 15; done
snap
if [ $bad = 0 ] && [ "$(hs_age vpn-backup)" -ge 180 ] && [ "$(ts_on)" = true ]; then ok=1; else ok=0; fi
net-test.sh unblock >> "$LOG" 2>&1; log "S3: блокировка снята"
wait_for "VPS ожил (backup)" 300 '[ "$(hs_age vpn-backup)" -lt 150 ]' || ok=0
wait_for "полоса ИИ ожила (amz)" 300 '[ "$(hs_age vpn-amz)" -lt 150 ]' || ok=0
[ $ok = 1 ] && result S3 "OK - дом на WARP не дрогнул, VPS вернулся" || result S3 "ПРОВАЛ - смотри лог"
fi

if want s5; then
# --- S5: убитые службы должны подниматься сами
for s in tailscaled dnscrypt-proxy dnsmasq; do
    log "S5: убиваю $s"; systemctl kill -s KILL "$s"; sleep 3
    if wait_for "$s снова active" 90 "systemctl is-active -q $s"; then
        case $s in
            tailscaled) wait_for "tailscale онлайн" 240 '[ "$(ts_on)" = true ]' && r=OK || r="ПРОВАЛ (не онлайн)";;
            *)          wait_for "DNS отвечает" 60 'dns_ok' && r=OK || r="ПРОВАЛ (DNS молчит)";;
        esac
    else
        r="ПРОВАЛ - сама не поднялась (нет Restart=), поднимаю вручную"; systemctl start "$s"
        wait_for "$s поднят вручную" 60 "systemctl is-active -q $s"
    fi
    result "S5 $s" "$r"
done
fi

if want s6; then
# --- S6: туннель WARP пропал (сбой процесса/модуля)
log "S6: удаляю интерфейс vpn-main"; ip link del vpn-main
ok=1
wait_for "дом ушёл на VPS" 240 '[ "$(lan_dev)" = vpn-backup ]' || ok=0
wait_for "WARP поднят заново, дом на нём" 1200 '[ "$(lan_dev)" = vpn-main ] && [ "$(hs_age vpn-main)" -lt 150 ]' || {
    ok=0; log "S6: сам не поднялся - запускаю перебор WARP вручную"; systemctl start --no-block warp-rotate.service
    wait_for "WARP после ручного перебора" 300 '[ "$(lan_dev)" = vpn-main ]'; }
[ $ok = 1 ] && result S6 "OK - VPS подхватил, WARP поднялся сам" || result S6 "ПРОВАЛ - смотри лог"
fi

if want s4; then
# --- S4: пропал весь интернет на 6 минут. Главное - ни секунды LAN напрямую в WAN (утечка)
log "S4: режу весь WAN на 6 минут"; block_all
ok=1; cut=""
for i in $(seq 24); do
    d=$(lan_dev)
    [ "$d" = wan ] && { log "  - УТЕЧКА: LAN идёт напрямую в wan"; ok=0; }
    [ -z "$cut" ] && [ "$d" = "нет-маршрута" ] && { cut=$((i * 15)); log "  + дом отрезан (blackhole) через ~${cut} с"; }
    [ "$(ip rule show priority 5200 | wc -l)" = 0 ] || [ "$d" = "нет-маршрута" ] || log "    (правило TS->туннель есть, туннель ещё числится живым)"
    [ $((i % 4)) = 0 ] && snap
    sleep 15
done
[ -n "$cut" ] || log "  ~ за 6 мин оркестратор так и не перевёл дом в blackhole (утечки нет: трафик уходил в мёртвый туннель)"
[ "$(ip rule show priority 5200 | wc -l)" = 0 ] || { log "  - правило TS->туннель осталось при мёртвых туннелях"; ok=0; }
nft delete table $T; log "S4: WAN вернул"
wait_for "всё восстановилось (WARP, Tailscale, DNS)" 600 '[ "$(lan_dev)" = vpn-main ] && [ "$(ts_on)" = true ] && dns_ok' || ok=0
[ $ok = 1 ] && result S4 "OK - утечек нет${cut:+, отрезан за ~${cut} с}, поднялся сам" || result S4 "ПРОВАЛ - смотри лог"
fi

cleanup
log "ИТОГ:"; for r in "${RES[@]}"; do log "  $r"; done
[ -x /usr/local/sbin/tg-notify.sh ] && /usr/local/sbin/tg-notify.sh "Учения" "$(printf '%s\n' "${RES[@]}")" info >/dev/null 2>&1
exit 0
