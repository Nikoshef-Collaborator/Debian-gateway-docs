#!/bin/bash
# NAT шлюза: маскарад подсети LAN через физический WAN.
# WAN задан явно, без автоопределения по default route.
WAN=wan
nft delete table ip gw_nat 2>/dev/null
nft -f - <<NFT
table ip gw_nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 192.168.50.0/24 oifname "$WAN" masquerade
    }
}
NFT
echo "gw_nat applied: 192.168.50.0/24 -> $WAN"
