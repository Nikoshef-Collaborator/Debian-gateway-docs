#!/bin/bash
# gw-pppoe.sh - перевод WAN шлюза на PPPoE (логин/пароль провайдера) и обратно.
# Документация: docs/09-PPPoE.md. Проверено на схеме "шлюз Debian 13 + NetworkManager".
#
# ИДЕЯ: имя "wan" сохраняется. Физическая карта переименовывается в "wanphy",
# а PPP-интерфейс получает имя "wan". Поэтому NAT, фаервол, полосы, warp-pick,
# netwatch и всё, что завязано на "wan", продолжают работать без правок.
#
# Команды (все от root):
#   check                 - проверка готовности, ничего не меняет
#   prepare [--vlan N] [--mac AA:BB:CC:DD:EE:FF]
#                         - поставить ppp, спросить логин/пароль, создать профили
#                           (выключенными), подготовить скрипты шлюза. Сеть НЕ трогает.
#   test                  - пробная PPPoE-сессия рядом с текущей сетью (нужен
#                           PPPoE passthrough на роутере или прямой кабель провайдера)
#   enable [--guard-min N] [--no-reboot]
#                         - переключить WAN на PPPoE + перезагрузка. Включается
#                           СТРАЖ: если за N минут (по умолч. 20) PPPoE не дал
#                           интернет - сам откатит на DHCP и перезагрузится.
#   disable [--no-reboot] - вернуть WAN на DHCP (как было) + перезагрузка
#   status                - текущее состояние
#   guard                 - (служебная, запускается systemd при загрузке)
set -u
export LC_ALL=C.UTF-8

SELF_DST=/usr/local/sbin/gw-pppoe.sh
STATE=/var/lib/gw-pppoe
PROFILE=gw-pppoe            # профиль PPPoE (боевой)
TPROFILE=gw-pppoe-test      # профиль PPPoE для пробы
VPROFILE=gw-wan-vlan        # профиль VLAN (если провайдер требует тег)
TVPROFILE=gw-wan-vlan-test
PHY=wanphy                  # новое имя физической WAN-карты в режиме PPPoE
PPPIF=wan                   # имя PPP-интерфейса (= старое имя WAN)
TESTIF=ppptest
VLANIF=wanvlan
TVLANIF=wvlantest
NMCONF=/etc/NetworkManager/conf.d/90-gw-pppoe.conf
GUARD_UNIT=/etc/systemd/system/gw-pppoe-guard.service
SLOTUP=/usr/local/sbin/vpn-slot-up.sh
RESTORE=/usr/local/sbin/gw-routing-restore.sh

say(){ echo "[gw-pppoe] $*"; logger -t gw-pppoe "$*" 2>/dev/null || true; }
die(){ echo "[gw-pppoe] ОШИБКА: $*" >&2; logger -t gw-pppoe "ОШИБКА: $*" 2>/dev/null || true; exit 1; }
tg(){ [ -x /usr/local/sbin/tg-notify.sh ] && /usr/local/sbin/tg-notify.sh "$1" "$2" "${3:-info}" >/dev/null 2>&1 || true; }
need_root(){ [ "$(id -u)" -eq 0 ] || die "запускай через sudo"; }
getv(){ [ -f "$STATE/$1" ] && cat "$STATE/$1" || true; }
setv(){ mkdir -p "$STATE"; chmod 700 "$STATE"; printf '%s\n' "$2" > "$STATE/$1"; }

# .link-файл, который даёт карте имя wan (в DHCP-режиме) или wanphy (в PPPoE)
find_link(){
    local f
    f=$(getv linkfile); [ -n "$f" ] && [ -f "$f" ] && { echo "$f"; return; }
    for f in /etc/systemd/network/*.link; do
        [ -f "$f" ] || continue
        grep -qE "^Name=($PPPIF|$PHY)\$" "$f" && { echo "$f"; return; }
    done
}

mode(){ local f; f=$(find_link); [ -n "$f" ] && grep -q "^Name=$PHY\$" "$f" && echo pppoe || echo dhcp; }

# ---------------------------------------------------------------- check
cmd_check(){
    need_root
    local ok=1 f m
    echo "== Проверка готовности (ничего не меняется)"
    if command -v nmcli >/dev/null && systemctl is-active --quiet NetworkManager; then
        echo "  OK   NetworkManager работает"
    else echo "  FAIL NetworkManager не установлен или не работает"; ok=0; fi
    if [ -f /etc/network/interfaces ] && grep -qE "^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+($PPPIF|$PHY)\b" /etc/network/interfaces; then
        echo "  FAIL WAN описан в /etc/network/interfaces (ifupdown) - скрипт рассчитан на NetworkManager"; ok=0
    fi
    f=$(find_link)
    if [ -n "$f" ]; then echo "  OK   имя WAN задаётся файлом $f"
    else echo "  FAIL нет /etc/systemd/network/*.link с Name=$PPPIF (имя карты по MAC) - см. docs/09, шаг 9.0"; ok=0; fi
    m=$(mode)
    echo "  ..   текущий режим WAN: $m"
    if [ "$m" = dhcp ]; then
        if nmcli -t -f DEVICE,TYPE device 2>/dev/null | grep -q "^$PPPIF:ethernet$"; then
            echo "  OK   $PPPIF - ethernet под NetworkManager"
            local p; p=$(nmcli -g GENERAL.CONNECTION device show "$PPPIF" 2>/dev/null)
            [ -n "$p" ] && echo "  OK   DHCP-профиль на $PPPIF: '$p'" || { echo "  FAIL на $PPPIF нет активного профиля NetworkManager"; ok=0; }
        else echo "  FAIL устройство $PPPIF не найдено как ethernet в NetworkManager"; ok=0; fi
    fi
    [ -f "$SLOTUP" ] && echo "  OK   есть $SLOTUP" || echo "  ..   нет $SLOTUP (не страшно, правка пропустится)"
    [ -f "$RESTORE" ] && echo "  OK   есть $RESTORE" || echo "  ..   нет $RESTORE (MSS для wan добавь вручную, docs/09)"
    command -v update-initramfs >/dev/null && echo "  OK   update-initramfs есть" || echo "  ..   нет update-initramfs"
    [ "$ok" -eq 1 ] && { echo "== ГОТОВО к prepare"; return 0; } || { echo "== НЕ ГОТОВО: исправь FAIL выше"; return 1; }
}

# ---------------------------------------------------------------- prepare
patch_slotup(){
    [ -f "$SLOTUP" ] || return 0
    if grep -q 'PPPoE: шлюза нет' "$SLOTUP"; then say "vpn-slot-up.sh уже поправлен"; return 0; fi
    cp -a "$SLOTUP" "$BK/"
    # шлюз берём из слова после "via" (у PPPoE его нет - маршрут просто через интерфейс)
    perl -0pi -e 's/WAN_GW_R=\$\(ip route show default \| awk \x27\/default\/\{print \$3; exit\}\x27\)/WAN_GW_R=\$(ip route show default | awk \x27\/default\/{for(i=1;i<=NF;i++) if(\$i=="via"){print \$(i+1); exit}}\x27)/' "$SLOTUP"
    perl -0pi -e 's/    if \[ -n "\$WAN_GW_R" \]; then\n        ip route replace "\$EP_IP\/32" via "\$WAN_GW_R" dev "\$\{WAN_IF_R:-wan\}" 2>\/dev\/null\n/    if [ -n "\$WAN_GW_R" ] || [ -n "\$WAN_IF_R" ]; then\n        if [ -n "\$WAN_GW_R" ]; then\n            ip route replace "\$EP_IP\/32" via "\$WAN_GW_R" dev "\${WAN_IF_R:-wan}" 2>\/dev\/null\n        else\n            ip route replace "\$EP_IP\/32" dev "\$WAN_IF_R" 2>\/dev\/null   # PPPoE: шлюза нет, маршрут через интерфейс\n        fi\n/' "$SLOTUP"
    if grep -q 'PPPoE: шлюза нет' "$SLOTUP" && grep -q '"via"' "$SLOTUP" && sh -n "$SLOTUP"; then
        say "vpn-slot-up.sh: пин endpoint теперь работает и без шлюза (PPPoE)"
    else
        cp -a "$BK/$(basename "$SLOTUP")" "$SLOTUP"
        say "ВНИМАНИЕ: vpn-slot-up.sh не совпал с ожидаемым текстом - оставлен как был. Правка вручную: docs/09, шаг 9.2"
    fi
}

patch_mss(){
    [ -f "$RESTORE" ] || return 0
    local line
    line=$(grep -E '^nft add rule ip gwroute mss oifname \{' "$RESTORE" | head -1)
    [ -z "$line" ] && { say "ВНИМАНИЕ: в $RESTORE нет строки MSS - добавь вручную (docs/09, шаг 9.2)"; return 0; }
    if ! printf '%s' "$line" | grep -q '"wan"'; then
        cp -a "$RESTORE" "$BK/"
        perl -pi -e 's/^(nft add rule ip gwroute mss oifname \{ )([^}]*?)( \} tcp flags syn)/$1$2, "wan"$3/' "$RESTORE"
        bash -n "$RESTORE" || { cp -a "$BK/$(basename "$RESTORE")" "$RESTORE"; die "правка MSS сломала синтаксис - откатил"; }
        line=$(grep -E '^nft add rule ip gwroute mss oifname \{' "$RESTORE" | head -1)
    fi
    # применить сразу (без перезапуска маршрутизации)
    nft flush chain ip gwroute mss 2>/dev/null && eval "$line"
    say "MSS подрезается и для wan (PPPoE MTU 1492)"
}

install_guard(){
    cat > "$GUARD_UNIT" <<EOF
[Unit]
Description=gw-pppoe guard: auto-rollback to DHCP if PPPoE trial fails
After=NetworkManager.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SELF_DST guard

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable gw-pppoe-guard.service >/dev/null 2>&1
}

nm_mk_pppoe(){  # имя профиля, ifname, parent, autoconnect, never-default
    local name=$1 ifn=$2 parent=$3 ac=$4 nd=$5
    nmcli -t -f NAME connection show | grep -qx "$name" && nmcli connection delete "$name" >/dev/null
    nmcli connection add type pppoe con-name "$name" ifname "$ifn" \
        pppoe.parent "$parent" pppoe.username "$PU" pppoe.password "$PP" pppoe.password-flags 0 \
        connection.autoconnect "$ac" connection.autoconnect-retries 0 \
        ppp.mtu 1492 ppp.mru 1492 ppp.lcp-echo-interval 10 ppp.lcp-echo-failure 6 \
        ipv4.method auto ipv4.never-default "$nd" ipv4.ignore-auto-dns "$nd" \
        ipv6.method disabled >/dev/null || die "не удалось создать профиль $name"
}

nm_mk_vlan(){   # имя профиля, ifname, parent, id, autoconnect
    local name=$1 ifn=$2 parent=$3 id=$4 ac=$5
    nmcli -t -f NAME connection show | grep -qx "$name" && nmcli connection delete "$name" >/dev/null
    nmcli connection add type vlan con-name "$name" ifname "$ifn" vlan.parent "$parent" vlan.id "$id" \
        connection.autoconnect "$ac" ipv4.method disabled ipv6.method disabled >/dev/null \
        || die "не удалось создать VLAN-профиль $name"
}

cmd_prepare(){
    need_root
    local vlan="" mac=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --vlan) vlan=${2:-}; shift 2;;
            --mac)  mac=${2:-};  shift 2;;
            *) die "неизвестный параметр: $1";;
        esac
    done
    [ -z "$vlan" ] || [[ "$vlan" =~ ^[0-9]{1,4}$ ]] || die "--vlan: число 1-4094"
    [ -z "$mac" ]  || [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || die "--mac: вид AA:BB:CC:DD:EE:FF"
    [ "$(mode)" = dhcp ] || die "WAN уже в режиме PPPoE. Сначала: gw-pppoe.sh disable"
    cmd_check >/dev/null || { cmd_check; die "сначала исправь проблемы из check"; }

    BK="$STATE/backup-$(date +%F-%H%M%S)"; mkdir -p "$BK"; chmod 700 "$STATE"
    [ "$(readlink -f "$0")" = "$SELF_DST" ] || install -m 755 "$0" "$SELF_DST"

    if ! dpkg -s ppp >/dev/null 2>&1; then
        say "ставлю пакет ppp"
        apt-get install -y ppp >/dev/null || die "apt-get install ppp не прошёл (есть интернет?)"
    fi

    setv linkfile "$(find_link)"
    setv dhcpprofile "$(nmcli -g GENERAL.CONNECTION device show "$PPPIF")"
    setv vlan "$vlan"; setv mac "$mac"

    echo
    echo "Логин и пароль PPPoE (из договора / от провайдера). В чат их НЕ присылай."
    read -rp "  Логин: " PU
    [ -n "$PU" ] || die "пустой логин"
    read -rsp "  Пароль: " PP; echo
    local PP2; read -rsp "  Пароль ещё раз: " PP2; echo
    [ -n "$PP" ] && [ "$PP" = "$PP2" ] || die "пароли пустые или не совпали"

    local parent=$PHY tparent=$PPPIF
    if [ -n "$vlan" ]; then
        nm_mk_vlan "$VPROFILE"  "$VLANIF"  "$PHY"    "$vlan" no
        nm_mk_vlan "$TVPROFILE" "$TVLANIF" "$PPPIF"  "$vlan" no
        parent=$VLANIF; tparent=$TVLANIF
    fi
    nm_mk_pppoe "$PROFILE"  "$PPPIF"  "$parent"  no  no    # боевой: выключен до enable
    nm_mk_pppoe "$TPROFILE" "$TESTIF" "$tparent" no  yes   # проба: без маршрута по умолчанию
    unset PP PP2
    say "профили NetworkManager созданы (выключены): $PROFILE, $TPROFILE${vlan:+, $VPROFILE (VLAN $vlan)}"

    patch_slotup
    patch_mss
    install_guard
    setv prepared "$(date '+%F %T')"
    echo
    say "ГОТОВО. Сеть не менялась. Дальше: 'gw-pppoe.sh test' (если есть passthrough) или 'gw-pppoe.sh enable'."
    say "Бэкапы изменённых файлов: $BK"
}

# ---------------------------------------------------------------- test
cmd_test(){
    need_root
    [ -n "$(getv prepared)" ] || die "сначала prepare"
    [ "$(mode)" = dhcp ] || die "test - только в режиме DHCP (до enable)"
    local vlan; vlan=$(getv vlan)
    say "пробная PPPoE-сессия ($TESTIF), маршрут по умолчанию НЕ трогается. До 60 с..."
    say "Если провайдер даёт 1 сессию на логин - на время пробы может отвалиться интернет у роутера."
    [ -n "$vlan" ] && nmcli connection up "$TVPROFILE" >/dev/null 2>&1
    if nmcli --wait 60 connection up "$TPROFILE" >/dev/null 2>&1; then
        local ip; ip=$(ip -4 -o addr show "$TESTIF" 2>/dev/null | awk '{print $4}')
        say "PPPoE ПОДНЯЛСЯ: адрес ${ip:-?}, MTU $(cat /sys/class/net/$TESTIF/mtu 2>/dev/null)"
        if ping -c3 -W3 -I "$TESTIF" 1.1.1.1 >/dev/null 2>&1; then say "интернет через PPPoE: ЕСТЬ - логин и пароль верные"
        else say "адрес есть, но ping 1.1.1.1 через $TESTIF не прошёл"; fi
        nmcli connection down "$TPROFILE" >/dev/null 2>&1
        [ -n "$vlan" ] && nmcli connection down "$TVPROFILE" >/dev/null 2>&1
        setv tested "$(date '+%F %T')"
        return 0
    fi
    nmcli connection down "$TPROFILE" >/dev/null 2>&1; [ -n "$vlan" ] && nmcli connection down "$TVPROFILE" >/dev/null 2>&1
    say "PPPoE НЕ поднялся. Причину покажет журнал:"
    journalctl -b --since "-2min" --no-pager 2>/dev/null | grep -iE 'pppd|pppoe|PADO|PADI|auth|CHAP|PAP' | tail -15
    echo "  - 'Timeout waiting for PADO' -> PPPoE не проходит до провайдера (нет passthrough у роутера / нужен VLAN)"
    echo "  - 'authentication failed' / CHAP / PAP -> неверный логин или пароль"
    echo "  - сессия уже занята -> провайдер даёт одну сессию на логин; проверяй при отключённом роутере"
    return 1
}

# ---------------------------------------------------------------- enable / disable
set_link_name(){  # $1 = wan|wanphy ; MACAddress только в режиме wanphy и если задан
    local f; f=$(find_link); [ -n "$f" ] || die "не найден .link"
    cp -a "$f" "$STATE/$(basename "$f").bak-$(date +%F-%H%M%S)"
    sed -i -E "s/^Name=($PPPIF|$PHY)\$/Name=$1/" "$f"
    sed -i '/^# gw-pppoe-mac$/{N;d}' "$f"            # убрать свою строку MAC (если была)
    local mac; mac=$(getv mac)
    if [ "$1" = "$PHY" ] && [ -n "$mac" ]; then
        # опознание карты - по ЗАВОДСКОМУ MAC (PermanentMACAddress): после подмены
        # текущий MAC станет другим, и правило "по текущему MAC" карту бы потеряло
        sed -i '/^\[Match\]/,/^\[/ s/^MACAddress=/PermanentMACAddress=/' "$f"
        # в .link комментарий только отдельной строкой: хвост "# ..." испортил бы значение
        sed -i "/^\[Link\]/a # gw-pppoe-mac\nMACAddress=$mac" "$f"
    fi
}

cmd_enable(){
    need_root
    local gmin=20 reboot=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --guard-min) gmin=${2:-}; shift 2;;
            --no-reboot) reboot=0; shift;;
            *) die "неизвестный параметр: $1";;
        esac
    done
    [[ "$gmin" =~ ^[0-9]+$ ]] && [ "$gmin" -ge 5 ] || die "--guard-min: минут, не меньше 5"
    [ -n "$(getv prepared)" ] || die "сначала prepare"
    [ "$(mode)" = dhcp ] || die "уже включено (режим pppoe)"
    [ -n "$(getv tested)" ] || say "ВНИМАНИЕ: test не проходил. Логин/пароль не проверены - страж откатит, если не заработает."
    echo
    echo "Сейчас: карта WAN станет '$PHY', PPPoE поднимется как '$PPPIF', DHCP на WAN выключится,"
    echo "шлюз перезагрузится. Если за $gmin мин PPPoE не даст интернет - откат на DHCP сам."
    echo "Кабель провайдера должен оказаться в WAN шлюза (до перезагрузки или в эти $gmin мин)."
    read -rp "Продолжить? Введи ДА: " a; [ "$a" = "ДА" ] || die "отменено"

    local dp; dp=$(getv dhcpprofile)
    [ -n "$dp" ] && nmcli connection modify "$dp" connection.autoconnect no
    nmcli connection modify "$PROFILE" connection.autoconnect yes
    [ -n "$(getv vlan)" ] && nmcli connection modify "$VPROFILE" connection.autoconnect yes
    printf '[main]\nno-auto-default=interface-name:%s\n' "$PHY" > "$NMCONF"   # не плодить DHCP на wanphy
    set_link_name "$PHY"
    setv trial "$gmin"
    systemctl enable gw-pppoe-guard.service >/dev/null 2>&1
    command -v update-initramfs >/dev/null && update-initramfs -u >/dev/null 2>&1
    say "режим PPPoE включён (пробный, страж $gmin мин)"
    tg "PPPoE" "WAN переключается на PPPoE, перезагрузка. Страж $gmin мин." warn
    [ "$reboot" -eq 1 ] && { sync; systemctl reboot; } || say "перезагрузку сделай сам: sudo reboot"
}

cmd_disable(){
    need_root
    local reboot=1; [ "${1:-}" = "--no-reboot" ] && reboot=0
    local dp; dp=$(getv dhcpprofile)
    nmcli connection modify "$PROFILE" connection.autoconnect no 2>/dev/null
    nmcli connection modify "$VPROFILE" connection.autoconnect no 2>/dev/null
    [ -n "$dp" ] && nmcli connection modify "$dp" connection.autoconnect yes
    rm -f "$NMCONF"
    set_link_name "$PPPIF"
    rm -f "$STATE/trial"
    command -v update-initramfs >/dev/null && update-initramfs -u >/dev/null 2>&1
    say "WAN возвращён на DHCP (профиль '${dp:-?}')"
    [ "$reboot" -eq 1 ] && { sync; systemctl reboot; } || say "перезагрузку сделай сам: sudo reboot"
}

# ---------------------------------------------------------------- guard
cmd_guard(){
    local gmin; gmin=$(getv trial)
    [ -n "$gmin" ] || exit 0                       # не пробный режим - страж молчит
    [ "$(mode)" = pppoe ] || { rm -f "$STATE/trial"; exit 0; }
    local deadline=$(( $(date +%s) + gmin * 60 )) okc=0
    say "страж: жду интернет через PPPoE до $gmin мин"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ip link show "$PPPIF" >/dev/null 2>&1 && ping -c1 -W3 -I "$PPPIF" 1.1.1.1 >/dev/null 2>&1; then
            okc=$((okc+1))
            if [ "$okc" -ge 3 ]; then
                rm -f "$STATE/trial"; setv confirmed "$(date '+%F %T')"
                say "страж: PPPoE работает ($(ip -4 -o addr show "$PPPIF" | awk '{print $4}')) - режим закреплён"
                tg "PPPoE" "PPPoE работает, режим закреплён." info
                exit 0
            fi
        else okc=0; fi
        sleep 20
    done
    say "страж: за $gmin мин PPPoE не дал интернет - ОТКАТ на DHCP"
    journalctl -b --no-pager 2>/dev/null | grep -iE 'pppd|pppoe|PADO|auth' | tail -20 > "$STATE/last-fail.log"
    cmd_disable
}

# ---------------------------------------------------------------- status
cmd_status(){
    echo "режим WAN       : $(mode)"
    echo "подготовлено    : $(getv prepared)"
    echo "проба (test)    : $(getv tested)"
    echo "закреплено      : $(getv confirmed)"
    echo "пробный режим   : $( [ -n "$(getv trial)" ] && echo "ДА, страж $(getv trial) мин" || echo нет)"
    echo "VLAN / MAC      : $(getv vlan) / $(getv mac)"
    echo "--- интерфейсы"
    ip -br link show "$PPPIF" 2>/dev/null; ip -br link show "$PHY" 2>/dev/null
    ip -4 -br addr show "$PPPIF" 2>/dev/null
    echo "MTU $PPPIF       : $(cat /sys/class/net/$PPPIF/mtu 2>/dev/null)"
    echo "--- маршрут по умолчанию (main)"
    ip route show default
    echo "--- профили NetworkManager"
    nmcli -f NAME,DEVICE,AUTOCONNECT,TYPE connection show 2>/dev/null | grep -E "NAME|$PROFILE|$TPROFILE|$VPROFILE|$(getv dhcpprofile)"
    [ -f "$STATE/last-fail.log" ] && { echo "--- последний откат стража:"; tail -5 "$STATE/last-fail.log"; }
}

case "${1:-}" in
    check)   shift; cmd_check "$@";;
    prepare) shift; cmd_prepare "$@";;
    test)    shift; cmd_test "$@";;
    enable)  shift; cmd_enable "$@";;
    disable) shift; cmd_disable "$@";;
    guard)   shift; cmd_guard "$@";;
    status)  shift; cmd_status "$@";;
    *) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 1;;
esac
