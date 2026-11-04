#!/bin/bash
# update.sh - обновление системы и проверка новой версии Immich.
# Запускается в 4:00 через update.timer.
#   1. apt upgrade; если нужна перезагрузка (новое ядро) - перезагрузка
#   2. проверка новой версии Immich -> уведомление в Telegram
#   Все результаты -> Telegram

set -u
LOG="/var/log/update-system.log"
TG="/usr/local/sbin/tg-notify.sh"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

log "=== Старт обновления ==="

# --- 1. apt upgrade ---
log "apt update..."
apt-get update -qq 2>&1 | tee -a "$LOG"

UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -v "^Listing" | wc -l)
log "Доступно обновлений: $UPGRADABLE"

if [ "$UPGRADABLE" -gt 0 ]; then
    log "apt upgrade..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq 2>&1 | tee -a "$LOG"

    # нужна ли перезагрузка (обычно - обновилось ядро)
    if [ -f /var/run/reboot-required ]; then
        KERNEL_NEW=$(uname -r)
        log "Обновлено ядро — планируем перезагрузку через 1 минуту"
        "$TG" "Обновление системы" "Установлено $UPGRADABLE обновлений ✅
Обновлено ядро → перезагрузка через 1 минуту" warn
        sleep 60
        log "Перезагрузка..."
        reboot
    else
        log "Перезагрузка не требуется"
        "$TG" "Обновление системы" "Установлено $UPGRADABLE обновлений ✅
Перезагрузка не требуется" info
    fi
else
    log "Система актуальна"
fi

# --- 2. Проверка версии Immich ---
log "Проверка версии Immich..."

# текущая версия - у запущенного контейнера
CURRENT=$(curl -s http://localhost:2283/api/server/version 2>/dev/null | grep -oE '[0-9]+' | paste -sd '.' | awk '{print "v"$0}')

# последняя версия - из GitHub API
LATEST=$(curl -s --max-time 10 \
    https://api.github.com/repos/immich-app/immich/releases/latest 2>/dev/null | \
    grep '"tag_name"' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)

log "Immich: текущая=$CURRENT последняя=$LATEST"

if [ -n "$LATEST" ] && [ -n "$CURRENT" ] && [ "$LATEST" != "$CURRENT" ]; then
    "$TG" "Immich: доступно обновление" "Текущая версия: $CURRENT
Новая версия:   $LATEST

Как обновить — см. FAQ в документации." warn
else
    log "Immich актуален ($CURRENT)"
fi

log "=== Обновление завершено ==="
