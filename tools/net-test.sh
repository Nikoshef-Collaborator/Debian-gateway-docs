#!/bin/bash
# net-test.sh - учения: имитация блокировок на WAN (2026-11-02).
#   status | block-ts | block-warp | block-vps | unblock
# Блокировка - отдельная таблица nft "inet nettest" (наши правила не трогает),
# снимается через 30 минут сама, даже если про неё забыть.
T="inet nettest"
stop_timers(){ systemctl stop 'nettest-unblock-*.timer' 2>/dev/null; }  # старый таймер снял бы новую блокировку раньше времени
lan_dev(){  # через что LAN выходит наружу; "нет-маршрута" = blackhole/unreachable (ip route get тогда пишет ошибку)
    local r; r=$(ip route get 1.1.1.1 from 192.168.50.100 iif lan 2>&1)
    echo "$r" | grep -oE 'dev [^ ]+' | head -1 | sed 's/^dev //' | grep . || echo "нет-маршрута"
}
eps(){ awk -F'=' '/^[[:space:]]*Endpoint/{gsub(/[[:space:]]/,"",$2); sub(/:[0-9]+$/,"",$2); print $2}' "$@" 2>/dev/null | grep -E '^[0-9.]+$' | sort -u; }
block(){  # $1 = что, остальное - адреса/подсети
    local what=$1; shift
    [ $# -eq 0 ] && { echo "нет адресов для $what"; exit 1; }
    nft list table $T >/dev/null 2>&1 || {
        stop_timers
        nft add table $T
        nft add chain $T out '{ type filter hook postrouting priority 0; policy accept; }'
        systemd-run --quiet --on-active=1800 --unit="nettest-unblock-$(date +%s)" nft delete table $T
    }
    for a in "$@"; do nft add rule $T out oifname "wan" ip daddr "$a" counter drop comment "\"$what\""; done
    echo "заблокировано ($what): $*"; echo "само снимется через 30 мин; снять сейчас: sudo $0 unblock"
}
case "$1" in
status)
    echo "=== $(date '+%H:%M:%S')"
    echo "tailscale онлайн:     $(tailscale status --json 2>/dev/null | jq -r '.Self.Online')"
    echo "правил 5200 (TS->туннель): $(ip rule show priority 5200 | wc -l)"
    echo "LAN выходит через:    $(lan_dev)"
    echo "таблица 100:"; ip route show table 100 | sed 's/^/    /'
    echo "handshake:"; awg show all latest-handshakes 2>/dev/null | awk -v now="$(date +%s)" '{printf "    %-11s %s\n", $1, ($3? now-$3" с назад":"нет")}'
    echo "блокировки:"; nft list table $T 2>/dev/null | grep -oE 'ip daddr [^ ]+ counter packets [0-9]+|comment "[^"]+"' | paste - - | sed 's/^/    /'
    nft list table $T >/dev/null 2>&1 || echo "    нет"
    echo "журнал:"; journalctl --since "-15min" --no-pager -o short-unix -t ts-guard -t gw-orchestrator -t warp-pick 2>/dev/null | tail -5 | cut -c1-160 | sed 's/^/    /'
    ;;
block-ts)
    block tailscale 192.200.0.0/24 $(getent ahostsv4 controlplane.tailscale.com | awk '{print $1}' | sort -u | grep -v '^192\.200\.0\.')
    ;;
block-warp)
    block warp $(eps /etc/gateway/tunnels/vpn-main.conf /etc/warp/pool/*.conf /etc/gateway/pool/*.conf)
    ;;
block-vps)
    block vps $(eps /etc/gateway/tunnels/vpn-backup.conf /etc/gateway/tunnels/vpn-amz.conf)
    ;;
unblock)
    stop_timers
    nft delete table $T 2>/dev/null && echo "блокировки сняты" || echo "блокировок не было"
    ;;
*) echo "использование: $0 status|block-ts|block-warp|block-vps|unblock"; exit 1 ;;
esac
