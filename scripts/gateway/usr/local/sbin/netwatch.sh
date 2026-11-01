#!/bin/bash
# netwatch.sh - раз в 10 с проверяет пути шлюза, в лог пишет только смену
# состояния (OK <-> FAIL). При новом FAIL - снимок туннелей и таблицы 100.
LOG=/var/log/netwatch.log
VPS_IP=ПОДСТАВЬ_IP_VPS
declare -A last
stamp(){ date '+%F %T'; }
check(){  # имя, команда...
    local name="$1"; shift
    local st=FAIL
    "$@" >/dev/null 2>&1 && st=OK
    if [ "${last[$name]:-}" != "$st" ]; then
        echo "$(stamp) $name $st" >> "$LOG"
        if [ "$st" = FAIL ] && [ -n "${last[$name]:-}" ]; then
            {
                echo "  --- снимок $(stamp) ---"
                awg show all latest-handshakes | awk -v n="$(date +%s)" '{print "  "$1" рукопожатие "($3==0?"нет":n-$3" с назад")}'
                ip route show table 100 | sed 's/^/  t100: /'
                ip -br addr show wan | sed 's/^/  /'
            } >> "$LOG" 2>&1
        fi
        last[$name]=$st
    fi
}
dns_ok(){ [ -n "$(dig +time=2 +tries=1 @127.0.0.1 example.com +short 2>/dev/null)" ]; }
echo "$(stamp) netwatch старт" >> "$LOG"
while true; do
    PONGW=$(ip route show default dev wan 2>/dev/null | awk '{print $3; exit}')
    check pon      ping -c1 -W2 -I wan "${PONGW:-192.168.0.1}"
    check wan      ping -c1 -W2 -I wan 1.1.1.1
    check warp     ping -c1 -W2 -I vpn-main 1.1.1.1
    check vps_dir  ping -c1 -W2 -I wan "$VPS_IP"
    check vps_tun  ping -c1 -W2 10.78.0.1
    check vps_inet curl -s -m5 -o /dev/null --interface vpn-backup http://1.1.1.1
    check dns      dns_ok
    sleep 10
done
