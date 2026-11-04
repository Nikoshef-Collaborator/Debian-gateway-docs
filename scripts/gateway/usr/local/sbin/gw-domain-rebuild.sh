#!/bin/bash
# gw-domain-rebuild.sh - пересобирает 05-gw-manual.conf из lane-state.conf
# и свежих service-groups. Вызывают gw-domain-move.sh и gw-feeder.sh.
# Перенесённый домен вычищается из 03/04: иначе он остаётся в двух наборах,
# и полоса VPS (метка 0x200 ставится последней) перебивает перенос.
set -u
STATE="/etc/gateway/lane-state.conf"
MANUAL_CONF="/etc/dnsmasq.d/05-gw-manual.conf"
YT_CONF="/etc/dnsmasq.d/03-yt-direct.conf"
AI_CONF="/etc/dnsmasq.d/04-ai-direct.conf"
GROUPS_DIR="/etc/gateway/service-groups"
TABLE="gwroute"
[ "$(id -u)" -eq 0 ] || { echo "запускай через sudo"; exit 1; }
touch "$STATE"
: > "${MANUAL_CONF}.new"
while IFS='=' read -r target lane; do
    [ -z "$target" ] && continue
    case "$lane" in
        direct) SET="zapret_direct" ;;
        amz)    SET="ai_direct" ;;
        *) continue ;;
    esac
    DOMAINS=()
    if [ -f "$GROUPS_DIR/$target.txt" ]; then
        while IFS= read -r d; do
            [ -z "$d" ] && continue
            DOMAINS+=("$d")
        done < "$GROUPS_DIR/$target.txt"
    else
        DOMAINS=("$target")
    fi
    for d in "${DOMAINS[@]}"; do
        # вычистить из 03/04 при каждой пересборке
        for f in "$YT_CONF" "$AI_CONF"; do
            [ -f "$f" ] && sed -i "\#/${d}/#d" "$f"
        done
        echo "nftset=/${d}/4#ip#${TABLE}#${SET}" >> "${MANUAL_CONF}.new"
    done
done < "$STATE"
mv "${MANUAL_CONF}.new" "$MANUAL_CONF"
if dnsmasq --test 2>&1 | grep -qi "syntax check OK"; then
    systemctl restart dnsmasq
    cnt=$(grep -c '^nftset=' "$MANUAL_CONF" 2>/dev/null || echo 0)
    echo "OK: пересобрано, $cnt записей в $MANUAL_CONF"
    exit 0
else
    echo "ERROR: dnsmasq --test не прошёл, dnsmasq НЕ перезапущен"
    exit 1
fi
