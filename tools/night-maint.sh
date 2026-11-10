#!/bin/bash
# night-maint.sh - разовое ночное обслуживание шлюза с Immich:
#   1) ждёт окончания бэкапов, 2) обновляет Immich (pull + up -d, ждёт ответа),
#   3) apt full-upgrade, 4) проверяет, что модуль AmneziaWG собран под новое ядро,
#   5) пишет в Telegram и перезагружает.
# При любой проблеме ДО перезагрузки - СТОП: перезагрузки не будет, придёт тревога.
#
#   night-maint.sh --check       ничего не менять, показать что будет сделано
#   night-maint.sh               выполнить (от root)
#   night-maint.sh --no-reboot   выполнить всё, но не перезагружать
#
# Переменные (необязательно): IMMICH_DIR, SNAP_DIR, WAIT_MIN
set -u
IMMICH_DIR="${IMMICH_DIR:-/home/user/immich}"
SNAP_DIR="${SNAP_DIR:-/mnt/photos/immich-snap}"
WAIT_MIN="${WAIT_MIN:-20}"
LOG=/var/log/night-maint.log
TG=/usr/local/sbin/tg-notify.sh
MODE=run
case "${1:-}" in
    --check) MODE=check ;;
    --no-reboot) MODE=noreboot ;;
    "") ;;
    *) echo "использование: $0 [--check|--no-reboot]"; exit 2 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "нужен root (sudo)"; exit 1; }

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
tg() { [ -x "$TG" ] && "$TG" "Ночное обслуживание" "$1" "${2:-info}" >/dev/null 2>&1; return 0; }
die() { log "СТОП: $1"; tg "СТОП: $1
Перезагрузки НЕ будет, проверь вручную." crit; exit 1; }

immich_ver() {
    curl -s --max-time 5 http://localhost:2283/api/server/version 2>/dev/null \
        | jq -r '"v\(.major).\(.minor).\(.patch)"' 2>/dev/null
}
immich_wait() {
    for _ in $(seq 1 60); do
        [ "$(curl -s --max-time 3 http://localhost:2283/api/server/ping 2>/dev/null | jq -r '.res' 2>/dev/null)" = "pong" ] && return 0
        sleep 5
    done
    return 1
}
newest_kernel() {
    ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V | tail -1
}
dkms_ok() {
    # модуль amneziawg должен быть в статусе installed именно под этим ядром
    dkms status 2>/dev/null | grep -i amneziawg | grep -F "$1" | grep -q installed
}

log "=== night-maint ($MODE) ==="

# --- проверки перед стартом ---
[ -d "$IMMICH_DIR" ] || die "нет папки Immich: $IMMICH_DIR"
[ -f "$IMMICH_DIR/docker-compose.yml" ] || [ -f "$IMMICH_DIR/compose.yaml" ] || [ -f "$IMMICH_DIR/compose.yml" ] || die "нет compose-файла в $IMMICH_DIR"
PIN=$(grep -E '^IMMICH_VERSION=' "$IMMICH_DIR/.env" 2>/dev/null | cut -d= -f2)
log "IMMICH_VERSION в .env: ${PIN:-<не задана>}"
if echo "${PIN:-}" | grep -qE '^v?[0-9]+\.[0-9]+\.[0-9]+$'; then
    log "ВНИМАНИЕ: версия Immich зафиксирована ($PIN) - pull ничего нового не принесёт"
    tg "Версия Immich зафиксирована в .env ($PIN): обновления Immich не будет, поменяй на release или нужный номер." warn
fi
BEFORE=$(immich_ver)
log "Immich сейчас: ${BEFORE:-не отвечает}"
KOLD=$(uname -r)
KNEW=$(newest_kernel)
log "ядро сейчас: $KOLD, новейшее на диске: $KNEW"
dkms_ok "$KNEW" || log "ВНИМАНИЕ: amneziawg под $KNEW пока не собран"

# свежесть снимка Immich
if [ -d "$SNAP_DIR" ]; then
    LAST=$(ls -dt "$SNAP_DIR"/* 2>/dev/null | head -1)
    if [ -n "$LAST" ]; then
        AGE=$(( ( $(date +%s) - $(stat -c %Y "$LAST") ) / 3600 ))
        log "последний снимок: $LAST (${AGE} ч назад)"
        [ "$AGE" -le 30 ] || die "последний снимок Immich старше 30 ч ($AGE ч)"
    else
        log "ВНИМАНИЕ: в $SNAP_DIR нет снимков"
    fi
else
    log "ВНИМАНИЕ: папки снимков нет ($SNAP_DIR), свежесть не проверена"
fi

if [ "$MODE" = check ]; then
    log "--- что поставит apt (симуляция) ---"
    apt-get update -qq 2>&1 | tail -3 | tee -a "$LOG"
    apt-get -s full-upgrade 2>/dev/null | grep -E '^(Inst|Remv)' | tee -a "$LOG"
    log "=== --check завершён, ничего не изменено ==="
    exit 0
fi

# --- 1. ждать окончания бэкапов ---
n=0
while pgrep -f 'backup-immich|backup-system' >/dev/null 2>&1; do
    [ "$n" -lt "$((WAIT_MIN * 6))" ] || die "бэкап не закончился за $WAIT_MIN мин"
    [ "$n" -eq 0 ] && log "идёт бэкап, жду..."
    n=$((n + 1)); sleep 10
done

# --- 2. Immich ---
log "Immich: docker compose pull"
cd "$IMMICH_DIR" || die "cd $IMMICH_DIR"
docker compose pull 2>&1 | tail -5 | tee -a "$LOG"
[ "${PIPESTATUS[0]}" -eq 0 ] || die "docker compose pull не удался"
log "Immich: docker compose up -d"
docker compose up -d 2>&1 | tail -8 | tee -a "$LOG"
[ "${PIPESTATUS[0]}" -eq 0 ] || die "docker compose up -d не удался"
immich_wait || die "Immich не ответил на ping в течение 5 мин после обновления"
AFTER=$(immich_ver)
log "Immich после: ${AFTER:-?}"

# --- 3. apt ---
log "apt update + full-upgrade"
apt-get update -qq 2>&1 | tail -3 | tee -a "$LOG"
NPKG=$(apt-get -s full-upgrade 2>/dev/null | grep -c '^Inst')
DEBIAN_FRONTEND=noninteractive apt-get -y -qq -o Dpkg::Options::=--force-confold full-upgrade 2>&1 | tail -15 | tee -a "$LOG"
[ "${PIPESTATUS[0]}" -eq 0 ] || die "apt full-upgrade завершился с ошибкой"

# --- 4. DKMS под новое ядро ---
KNEW=$(newest_kernel)
if ! dkms_ok "$KNEW"; then
    log "dkms autoinstall -k $KNEW"
    dkms autoinstall -k "$KNEW" 2>&1 | tail -8 | tee -a "$LOG"
fi
dkms_ok "$KNEW" || die "модуль amneziawg не собран под ядро $KNEW - после перезагрузки не поднимутся туннели"
log "amneziawg собран под $KNEW"

# --- 5. итог и перезагрузка ---
MSG="Immich: ${BEFORE:-?} -> ${AFTER:-?}
Пакетов обновлено: $NPKG
Ядро: $KOLD -> $KNEW (amneziawg собран)
Перезагрузка через 60 с."
log "$MSG"
if [ "$MODE" = noreboot ]; then
    tg "$MSG
(режим --no-reboot: перезагрузки не будет)" info
    log "=== готово, без перезагрузки ==="
    exit 0
fi
tg "$MSG" info
sleep 60
log "reboot"
systemctl reboot
