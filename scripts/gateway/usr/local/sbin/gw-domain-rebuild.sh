#!/bin/bash
# gw-domain-rebuild.sh - пересобирает 05-gw-manual.conf из lane-state.conf
# и свежих service-groups. Вызывают gw-domain-move.sh и gw-feeder.sh.
set -u
STATE="/etc/gateway/lane-state.conf"
MANUAL_CONF="/etc/dnsmasq.d/05-gw-manual.conf"
GROUPS_DIR="/etc/gateway/service-groups"
TABLE="gwroute"
[ "$(id -u)" -eq 0 ] || { echo "запускай через sudo"; exit 1; }
touch "$STATE"
: > "${MANUAL_CONF}.new"
while IFS='=' read -r target lane; do
    [ -z "$target" ] && continue
    case "$lane" in direct) SET="zapret_direct" ;; amz) SET="ai_direct" ;; *) continue ;; esac
    if [ -f "$GROUPS_DIR/$target.txt" ]; then
        mapfile -t DOMAINS < <(grep -v '^$' "$GROUPS_DIR/$target.txt")
    else
        DOMAINS=("$target")
    fi
    for d in "${DOMAINS[@]}"; do
        echo "nftset=/${d}/4#ip#${TABLE}#${SET}" >> "${MANUAL_CONF}.new"
    done
done < "$STATE"
mv "${MANUAL_CONF}.new" "$MANUAL_CONF"
if dnsmasq --test 2>&1 | grep -qi "syntax check OK"; then
    systemctl restart dnsmasq
    echo "OK: пересобрано, $(grep -c '^nftset=' "$MANUAL_CONF") записей"
else
    echo "ERROR: dnsmasq --test не прошёл, dnsmasq НЕ перезапущен"; exit 1
fi
