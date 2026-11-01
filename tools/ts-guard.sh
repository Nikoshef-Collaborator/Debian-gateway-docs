#!/bin/bash
# ts-guard.sh - страховка удалённого доступа Tailscale (2026-11-02). Таймер раз в минуту.
# Режимы связи с сервером управления Tailscale: "напрямую" (обычный) и "через туннель".
#  - offline LIMIT проверок подряд напрямую, туннель жив   -> через туннель;
#  - offline LIMIT_TUN проверок подряд через туннель       -> снова напрямую (не залипаем);
# После каждого переключения tailscaled перезапускается: сам он переподключается
# с задержками в минуты (учения 2026-11-02: 3 мин после переключения - всё ещё offline).
#  - через туннель и онлайн уже RETRY секунд               -> пробуем напрямую (не помогло - вернёмся);
#  - все туннели мертвы                                    -> напрямую;
#  - после перезагрузки                                    -> напрямую.
# Ручной откат: while sudo ip rule del priority 5200; do :; done
PRIO=5200; TABLE=100; LIMIT=3; LIMIT_TUN=5; RETRY=21600; TAG=ts-guard
CNT=/run/ts-guard.cnt; SINCE=/run/ts-guard.since; NOTE=/run/ts-guard.notified
NET="192.200.0.0/24"   # серверы controlplane.tailscale.com (ноябрь 2026)
now=$(date +%s)

notify(){  # в журнал - всегда, в Telegram - не чаще раза в час (без спама при качелях)
    logger -t "$TAG" "$1"
    local last; last=$(cat "$NOTE" 2>/dev/null || echo 0)
    [ $((now - last)) -lt 3600 ] && [ "${2:-warn}" != crit ] && return
    echo "$now" > "$NOTE"
    [ -x /usr/local/sbin/tg-notify.sh ] && /usr/local/sbin/tg-notify.sh "Tailscale" "$1" "${2:-warn}" >/dev/null 2>&1
}
has_rule(){ ip rule show priority "$PRIO" | grep -q .; }
tunnel_ok(){  # туннель в таблице 100 есть И у него свежий handshake (учения S4: маршрут есть, туннель мёртв)
    local d t; d=$(ip route show table "$TABLE" | awk '/^default dev vpn-/{print $3; exit}')
    [ -n "$d" ] || return 1
    t=$(awg show "$d" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
    [ -n "$t" ] && [ "$t" != 0 ] && [ $(( $(date +%s) - t )) -lt 240 ]
}
add_rules(){
    ip rule add to "$NET" lookup "$TABLE" priority "$PRIO" 2>/dev/null
    for a in $(getent ahostsv4 controlplane.tailscale.com | awk '{print $1}' | sort -u); do
        case "$a" in 192.200.0.*) ;; *) ip rule add to "$a/32" lookup "$TABLE" priority "$PRIO" 2>/dev/null ;; esac
    done
    echo "$now" > "$SINCE"
}
del_rules(){ while ip rule del priority "$PRIO" 2>/dev/null; do :; done; rm -f "$SINCE"; }
kick(){ systemctl restart --no-block tailscaled; }   # переподключиться сразу, новым путём

if has_rule && ! tunnel_ok; then
    del_rules; kick; echo 0 > "$CNT"
    notify "все туннели мертвы - связь с сервером Tailscale снова напрямую" crit
    exit 0
fi

# не "// empty": jq считает false пустым, и offline никогда бы не ловился
online=$(tailscale status --json 2>/dev/null | jq -r '.Self.Online' 2>/dev/null)
case "$online" in true|false) ;; *) exit 0 ;; esac   # tailscaled не отвечает - не судим

if [ "$online" = true ]; then
    echo 0 > "$CNT"
    if has_rule && [ $((now - $(cat "$SINCE" 2>/dev/null || echo "$now"))) -ge "$RETRY" ]; then
        del_rules; kick
        logger -t "$TAG" "через туннель уже $((RETRY / 3600)) ч - пробую снова напрямую"
    fi
    exit 0
fi

n=$(( $(cat "$CNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CNT"
if has_rule; then lim=$LIMIT_TUN; else lim=$LIMIT; fi
[ "$n" -lt "$lim" ] && exit 0
echo 0 > "$CNT"
if has_rule; then
    del_rules; kick
    notify "через туннель связи с сервером Tailscale тоже нет - пробую напрямую" warn
elif tunnel_ok; then
    add_rules; kick
    notify "узел offline $n мин подряд - связь с сервером Tailscale пущена через туннель" warn
fi
exit 0
