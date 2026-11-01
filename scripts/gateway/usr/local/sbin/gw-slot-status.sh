#!/bin/bash
# gw-slot-status.sh - конфиг, служба и рукопожатие каждого слота
for SLOT in vpn-main vpn-backup vpn-amz; do
    conf="/etc/gateway/tunnels/${SLOT}.conf"; echo "-> $SLOT"
    if [ -f "$conf" ]; then
        echo "    конфиг:  есть (Endpoint: $(awk -F'=' '/^[[:space:]]*Endpoint/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$conf"))"
    else echo "    конфиг:  НЕТ"; fi
    echo "    служба:  $(systemctl is-active "vpn-slot@${SLOT}.service" 2>/dev/null)"
    if ip link show "$SLOT" >/dev/null 2>&1; then
        hs=$(awg show "$SLOT" 2>/dev/null | awk '/latest handshake/{$1=$2="";print;exit}')
        echo "    рукопожатие:${hs:- нет}"
    else echo "    интерфейс: не поднят"; fi
done
