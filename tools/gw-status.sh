#!/bin/bash
# gw-status.sh v3 (2026-11-04) - состояние шлюза одним экраном. Запуск: sudo gw-status.sh
# Под нынешнюю схему: слоты vpn-main (WARP) / vpn-backup (VPS) / vpn-amz (ИИ и голос),
# таблицы 100 (каскад WARP -> VPS -> blackhole) и 200 (kill-switch ИИ), набор правил gwroute.
# v2 смотрел на awg0-awg3, table ip warp, zapret2 - этого в системе давно нет.
set -u
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; N='\033[0m'
ok(){ echo -e "  ${G}✓${N} $1"; }
bad(){ echo -e "  ${R}✗${N} $1"; }
warn(){ echo -e "  ${Y}!${N} $1"; }
now=$(date +%s)
hs_age(){ local t; t=$(awg show "$1" latest-handshakes 2>/dev/null | awk '{print $2; exit}'); [ -n "$t" ] && [ "$t" != 0 ] && echo $((now - t)) || echo -1; }
route_of(){ ip route show table "$1" 2>/dev/null | awk '/^blackhole default/{print "blackhole"; exit} /^default/{print $3; exit}'; }
set_n(){ nft -j list set ip gwroute "$1" 2>/dev/null | jq '[.nftables[] | select(.set) | .set.elem // [] | length] | add // 0' 2>/dev/null || echo -1; }

echo "════════════════════════════════════════════════"
echo " ШЛЮЗ $(hostname) - $(date '+%Y-%m-%d %H:%M:%S'), ядро $(uname -r)"
echo "════════════════════════════════════════════════"

echo; echo "── Туннели (возраст handshake) ──"
for s in vpn-main vpn-backup vpn-amz; do
    if ! ip link show "$s" >/dev/null 2>&1; then bad "$s - интерфейса нет"; continue; fi
    a=$(hs_age "$s")
    if [ "$a" -lt 0 ]; then bad "$s - handshake не было"
    elif [ "$a" -lt 180 ]; then ok "$s - ${a} с"
    elif [ "$a" -lt 300 ]; then warn "$s - ${a} с (стареет)"
    else bad "$s - ${a} с (мёртв)"; fi
done
if lsmod | grep -q '^amneziawg'; then ok "модуль ядра amneziawg загружен"; else warn "модуля ядра нет - работает amneziawg-go (медленнее)"; fi

echo; echo "── Полосы ──"
r=$(route_of 100)
case "$r" in
    vpn-main)   ok   "table 100 (дом) -> WARP" ;;
    vpn-backup) warn "table 100 (дом) -> VPS (WARP лежит или идёт перебор)" ;;
    blackhole)  bad  "table 100 (дом) -> BLACKHOLE: оба туннеля мертвы, иностранное не ходит" ;;
    "")         bad  "table 100 пустая - gw-routing не отработал" ;;
    *)          warn "table 100 -> $r" ;;
esac
r=$(route_of 200)
case "$r" in
    vpn-amz)   ok  "table 200 (ИИ, голос) -> VPS" ;;
    blackhole) bad "table 200 -> BLACKHOLE (kill-switch: туннель ИИ мёртв)" ;;
    "")        bad "table 200 пустая - ИИ-трафик может уйти напрямую" ;;
    *)         warn "table 200 -> $r" ;;
esac
for p in 8900 8996 9400 9500; do
    ip rule show priority $p | grep -q . && ok "ip rule $p есть" || bad "ip rule $p НЕТ (gw-routing-restore.sh)"
done
ip rule show priority 5200 | grep -q . && warn "ip rule 5200: связь с сервером Tailscale идёт через туннель (сработал ts-guard)"

echo; echo "── Наборы gwroute (элементов) ──"
if nft list table ip gwroute >/dev/null 2>&1; then
    line=""
    for s in ru_cidr ru_direct cf_warp warp_force zapret_direct ai_direct voice_direct endpoints; do
        line="$line $s=$(set_n $s)"
    done
    echo " $line"
    [ "$(set_n ru_cidr)" -lt 1000 ] && bad "ru_cidr почти пуст - российское уйдёт в туннель (sudo systemctl start gw-feeder)"
    [ "$(set_n voice_direct)" -lt 1 ] && bad "voice_direct пуст - медиа Telegram/звонки мимо VPS (sudo systemctl start gw-feeder)"
    [ "$(set_n endpoints)" -lt 1 ] && bad "endpoints пуст - риск петли маршрута до серверов туннелей"
else
    bad "таблицы ip gwroute нет - полосы НЕ работают"
fi

echo; echo "── DNS и удалённый доступ ──"
dig +short +time=3 +tries=1 example.com @127.0.0.1 2>/dev/null | grep -qE '^[0-9.]+$' && ok "DNS отвечает" || bad "DNS не отвечает (dnsmasq/dnscrypt-proxy)"
ts=$(tailscale status --json 2>/dev/null | jq -r '.Self.Online' 2>/dev/null)
[ "$ts" = true ] && ok "Tailscale онлайн" || bad "Tailscale: ${ts:-нет ответа}"

echo; echo "── Службы ──"
for u in dnsmasq dnscrypt-proxy tailscaled gw-fw gw-nat gw-routing vpn-slot@vpn-backup vpn-slot@vpn-amz; do
    st=$(systemctl is-active "$u" 2>/dev/null)
    case "$st" in active) ok "$u";; *) bad "$u - $st";; esac
done
echo; echo "── Таймеры ──"
for t in gw-orchestrator gw-feeder warp-rotate ts-guard backup-immich backup-immich-daily vps-backup; do
    systemctl list-unit-files "$t.timer" >/dev/null 2>&1 || continue
    st=$(systemctl is-active "$t.timer" 2>/dev/null)
    [ "$st" = active ] && ok "$t.timer" || warn "$t.timer - $st"
done
failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
[ -z "$failed" ] && ok "упавших юнитов нет" || bad "упали: $failed"

echo; echo "── Диски ──"
df -h --output=target,pcent,avail 2>/dev/null | awk 'NR==1 || $1=="/" || $1 ~ /^\/mnt\//'
for d in /dev/disk/by-id/ata-*; do
    case "$d" in *-part*) continue;; esac
    v=$(smartctl -A "$d" 2>/dev/null | awk '$1==5{r=$10} $1==197{p=$10} $1==198{u=$10} END{print r+0, p+0, u+0}')
    set -- $v
    n=${d##*/ata-}; n=${n:0:40}
    if [ "$1" = 0 ] && [ "$2" = 0 ] && [ "$3" = 0 ]; then ok "$n"; else warn "$n: переназначено $1, ждут $2, нечитаемых $3"; fi
done

echo; echo "════════════════════════════════════════════════"
echo " Разбор проблем - документация, Часть 4"
echo "════════════════════════════════════════════════"
