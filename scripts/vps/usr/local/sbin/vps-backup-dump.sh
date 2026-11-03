#!/bin/bash
# vps-backup-dump.sh - выдаёт в stdout tar.gz с конфигурацией VPS.
# Вызывается ТОЛЬКО через ключ бэкапа (command= в authorized_keys).
# Внутри есть приватные ключи AmneziaWG - архив хранить с правами 600.
set -u
cd /
LIST=""
for p in etc/amnezia etc/nftables.conf etc/nftables-cve.nft etc/caddy var/www usr/local/sbin \
         etc/systemd/system etc/sysctl.d etc/ssh/sshd_config.d \
         etc/systemd/journald.conf.d etc/apt/apt.conf.d opt/AdGuardHome \
         root/.ssh/authorized_keys etc/hostname etc/netplan; do
    [ -e "$p" ] && LIST="$LIST $p"
done
# shellcheck disable=SC2086
tar czf - --exclude='opt/AdGuardHome/data/querylog*' --exclude='opt/AdGuardHome/data/stats.db' $LIST 2>/dev/null
