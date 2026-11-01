#!/bin/bash
# export-for-git.sh - собрать скрипты и конфиги шлюза для GitHub БЕЗ секретов.
# Запуск: sudo bash export-for-git.sh   -> /tmp/git-export-<host>.tar.gz
# Секреты (ключи AWG/WARP, tg.conf, пулы, authorized_keys, .env) НЕ берутся.
# Архив всё равно проверяется на утечки перед заливкой.
set -u
H=$(hostname -s)
OUT=/tmp/git-export-$H.tar.gz
INC=()
for p in usr/local/sbin etc/systemd/system etc/dnsmasq.d etc/gateway \
         etc/gwroute.nft etc/gw-fw.nft etc/gw-dnsredirect.nft etc/nftables.conf \
         etc/smartd.conf etc/default/hd-idle etc/OliveTin/config.yaml \
         etc/caddy etc/sysctl.d etc/ssh/sshd_config.d etc/systemd/journald.conf.d \
         etc/sudoers.d etc/mdadm/mdadm.conf etc/systemd/network etc/default/grub; do
    [ -e "/$p" ] && INC+=("$p")
done
tar -C / -czf "$OUT" \
    --exclude='*.bak*' --exclude='*.orig' --exclude='*.old*' --exclude='*.lastgood' \
    --exclude='*.wants' --exclude='*.requires' \
    --exclude='etc/gateway/tg.conf' --exclude='etc/gateway/tunnels' \
    --exclude='etc/gateway/pool' --exclude='etc/gateway/vps' --exclude='etc/warp' --exclude='etc/amnezia' \
    --exclude='*.key' --exclude='*.pem' --exclude='.env' --exclude='authorized_keys' \
    "${INC[@]}" 2>/dev/null
# страховка: если в архив всё же попал приватный ключ - архив удаляется
if tar -xzOf "$OUT" 2>/dev/null | grep -qE '(PrivateKey|PresharedKey|HeaderProtectionKey)[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{20}'; then
    echo "СТОП: в архиве найден ключ AmneziaWG/WireGuard. Архив удалён. Файлы с ключом:"
    tar -tzf "$OUT" | while read -r f; do tar -xzOf "$OUT" "$f" 2>/dev/null | grep -qE '(PrivateKey|PresharedKey)[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{20}' && echo "  /$f"; done
    rm -f "$OUT"; exit 1
fi
chmod 600 "$OUT"; [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$OUT"   # чтобы забрать по scp без sudo
echo "Готово: $OUT ($(du -h "$OUT" | cut -f1), файлов: $(tar -tzf "$OUT" | grep -vc '/$'))"
