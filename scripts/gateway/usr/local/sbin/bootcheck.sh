#!/usr/bin/env bash
# bootcheck.sh - снимок здоровья шлюза. Дописывает пронумерованный отчёт
# в /var/log/bootcheck.log и шлёт итог в Telegram.
LOG=/var/log/bootcheck.log
CNT=/var/lib/bootcheck.count
SERVICES="gw-lan gw-nat gw-fw gw-routing gw-dnsredirect dnsmasq dnscrypt-proxy tailscaled vpn-slot@vpn-main"
TIMERS="gw-orchestrator gw-feeder"
SETS="endpoints ru_cidr ru_direct cf_warp warp_force zapret_direct ai_direct voice_direct"
VPS_IP="ПОДСТАВЬ_IP_VPS"
WAN_IP="ПОДСТАВЬ_WAN_IP"
[ -n "$VPS_IP" ] && SERVICES="$SERVICES vpn-slot@vpn-backup vpn-slot@vpn-amz"

n=$(( $(cat "$CNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CNT"
WARN=""
cnt(){ nft list set ip gwroute "$1" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | wc -l; }
hs_age(){ local t; t=$(awg show "$1" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
          [ -n "$t" ] && [ "$t" != 0 ] && echo $(( $(date +%s) - t )) || echo "нет"; }

{
  echo "================ BOOT #$n  $(date '+%F %T')  uptime $(cut -d. -f1 /proc/uptime)s ================"
  fail=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
  echo "FAILED units: ${fail:-НЕТ}"
  echo "-- сервисы --"
  for s in $SERVICES; do
    st=$(systemctl is-active "$s.service" 2>/dev/null)
    [ "$st" = active ] || { st="$st  <<<<"; WARN="$WARN $s"; }
    printf "  %-22s %s\n" "$s" "$st"
  done
  echo "-- таймеры --"
  for t in $TIMERS; do
    st=$(systemctl is-active "$t.timer" 2>/dev/null)
    [ "$st" = active ] || { st="$st  <<<<"; WARN="$WARN $t.timer"; }
    printf "  %-22s %s\n" "$t.timer" "$st"
  done
  echo "-- полосы --"
  for T in 100 200; do
    r=$(ip route show table "$T" 2>/dev/null | awk '/^default dev/{print $3; exit}')
    [ -n "$r" ] || { r="пусто  <<<<"; [ "$T" = 100 ] || [ -n "$VPS_IP" ] && WARN="$WARN table$T"; }
    printf "  table %-5s %s\n" "$T" "$r"
  done
  echo "-- наборы gwroute (элементов) --"
  for S in $SETS; do printf "  %-14s %s\n" "$S" "$(cnt "$S")"; done
  [ "$(cnt cf_warp)" -gt 0 ] || WARN="$WARN cf_warp-пуст"
  r=$(nft list chain ip gwroute gwmark 2>/dev/null | grep -cE '@cf_warp|@warp_force')
  echo "  правила cf_warp/warp_force в gwmark: $r из 2"; [ "$r" = 2 ] || WARN="$WARN gwmark"
  echo "-- функции --"
  d=$(dig +time=2 +tries=1 @127.0.0.1 +short example.com 2>/dev/null | tail -1)
  echo "  DNS @local : ${d:-FAIL}"; [ -n "$d" ] || WARN="$WARN DNS"
  w=$(ip -4 -o addr show wan 2>/dev/null | awk '{print $4}')
  echo "  WAN        : ${w:-нет адреса}"; [ "${w%/*}" = "$WAN_IP" ] || WARN="$WARN WAN-IP"
  echo "  tailscale  : $(tailscale ip -4 2>/dev/null | head -1 || echo n/a)"
  m=$(curl --interface vpn-main -s --max-time 8 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -E '^warp=')
  echo "  WARP vpn-main : ${m:-FAIL} (рукопожатие: $(hs_age vpn-main) с назад)"; [ -n "$m" ] || WARN="$WARN vpn-main"
  if [ -n "$VPS_IP" ]; then
    for I in vpn-backup vpn-amz; do
      ip=$(curl --interface "$I" -s --max-time 8 https://api.ipify.org 2>/dev/null)
      printf "  VPS %-10s: %s (рукопожатие: %s с назад)\n" "$I" "${ip:-FAIL}" "$(hs_age "$I")"
      [ "$ip" = "$VPS_IP" ] || WARN="$WARN $I"
    done
  fi
  echo "  ИТОГ: ${WARN:-всё в норме}"
} >> "$LOG" 2>&1

[ -x /usr/local/sbin/tg-notify.sh ] || exit 0
T100=$(ip route show table 100 2>/dev/null | awk '/^default dev/{print $3; exit}')
if [ -z "$fail$WARN" ]; then
  /usr/local/sbin/tg-notify.sh "Boot #${n} ✅" "Все проверки в норме, WARP: ${T100:-пусто}" info
else
  /usr/local/sbin/tg-notify.sh "Boot #${n} ⚠️" "Упавшие юниты: ${fail:-нет}
Проблемы:${WARN:- нет}
WARP: ${T100:-пусто}" warn
fi
