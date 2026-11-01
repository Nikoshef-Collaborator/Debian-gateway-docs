#!/bin/bash
# gw-routing-restore.sh - восстановление инверсной маршрутизации при загрузке.
set -u
source /etc/gateway/gateway.conf 2>/dev/null || true
LAN_NET="${LAN_NET:-192.168.50.0/24}"

# 1. наборы и метки (сначала проверка синтаксиса, битый файл не применяем)
[ -f /etc/gwroute.nft ] && nft -c -f /etc/gwroute.nft 2>/dev/null && nft -f /etc/gwroute.nft

# 2. метки -> таблицы
ip rule add fwmark 0x200 lookup 200 priority 8996 2>/dev/null || true

# 3. 0x100 (Россия, endpoints) -> main, то есть напрямую через wan
ip rule add fwmark 0x100 lookup main priority 8900 2>/dev/null || true

# 4. локальные сети -> main (иначе теряем SSH/LAN-доступ)
ip rule add to 192.168.0.0/16 lookup main priority 8800 2>/dev/null || true

# 5. всё, для чего в main есть конкретный маршрут (Docker 172.x, сети
#    туннелей, 192.168.0.x и т.п.), - через main. Без этого трафик LAN к
#    локальным сервисам (например контейнерам Docker) уходит в туннель.
ip rule add lookup main suppress_prefixlength 0 priority 8810 2>/dev/null || true

# 6. LAN по умолчанию -> таблица 100 (VPN)
ip rule add from "$LAN_NET" lookup 100 priority 9500 2>/dev/null || true

# 7. endpoints из конфигов слотов
for conf in /etc/gateway/tunnels/*.conf; do
    [ -e "$conf" ] || continue
    ep=$(awk -F'=' '/^[[:space:]]*Endpoint/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$conf")
    ip="${ep%%:*}"
    case "$ip" in *[!0-9.]*|"") continue ;; esac
    nft add element ip gwroute endpoints "{ $ip }" 2>/dev/null || true
done

# 8. MSS clamp на выходе в туннели (иначе часть сайтов и Telegram виснут: MTU)
nft add chain ip gwroute mss '{ type filter hook postrouting priority mangle; policy accept; }' 2>/dev/null
nft flush chain ip gwroute mss 2>/dev/null
nft add rule ip gwroute mss oifname '{ "vpn-main", "vpn-backup", "vpn-amz" }' tcp flags syn tcp option maxseg size set rt mtu 2>/dev/null

# 9. страховка: если интерфейс VPN исчезнет, трафик упрётся в blackhole, а не уйдёт напрямую
ip route replace blackhole default metric 1000 table 100 2>/dev/null || true

logger -t gw-routing "инверсная маршрутизация восстановлена"
