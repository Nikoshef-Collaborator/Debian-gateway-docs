#!/bin/bash
# gw-domain-move.sh <домен|группа> <warp|direct|amz>
# Обновляет lane-state.conf и пересобирает 05-gw-manual.conf.
set -u
STATE="/etc/gateway/lane-state.conf"
[ "$(id -u)" -eq 0 ] || { echo "запускай через sudo"; exit 1; }
TARGET="${1:-}"; LANE="${2:-}"
[ -z "$TARGET" ] || [ -z "$LANE" ] && { echo "Использование: $0 <домен|группа> <warp|direct|amz>"; exit 1; }
case "$LANE" in warp|direct|amz) ;; *) echo "ERROR: полоса только warp, direct, amz"; exit 1 ;; esac
touch "$STATE"
grep -v "^${TARGET}=" "$STATE" > "${STATE}.tmp" 2>/dev/null || : > "${STATE}.tmp"
[ "$LANE" != "warp" ] && echo "${TARGET}=${LANE}" >> "${STATE}.tmp"
mv "${STATE}.tmp" "$STATE"
/usr/local/sbin/gw-domain-rebuild.sh
