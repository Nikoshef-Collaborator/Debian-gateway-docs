#!/bin/bash
# immich-update.sh - безопасное автообновление Immich (docker compose, плавающий тег вроде v3).
# Раз в неделю по таймеру. Тихо выходит, если нового образа нет.
#
# Что делает:
#   1) проверяет: нет другого запуска, система не только что загрузилась, не идёт бэкап,
#      снимок Immich свежий, на диске Docker есть место;
#   2) запоминает ID текущих образов, делает pull; если образы не изменились - выходит;
#   3) up -d, ждёт ответа Immich (ping), пишет результат в Telegram.
# Чего НЕ делает: не откатывает сам (после миграции БД откат образа может сломать Immich),
# не трогает apt и не перезагружает систему.
#
#   immich-update.sh --check   показать состояние и проверки, ничего не менять
#   immich-update.sh           выполнить (от root)
#
# Переменные (необязательно): IMMICH_DIR, SNAP_DIR, WAIT_MIN, MIN_FREE_GB, BACKUP_WAIT_MIN
set -u
IMMICH_DIR="${IMMICH_DIR:-/home/user/immich}"
SNAP_DIR="${SNAP_DIR:-/mnt/photos/immich-snap}"
WAIT_MIN="${WAIT_MIN:-10}"
BACKUP_WAIT_MIN="${BACKUP_WAIT_MIN:-20}"
MIN_FREE_GB="${MIN_FREE_GB:-5}"
MIN_UPTIME_MIN="${MIN_UPTIME_MIN:-10}"
DOCKER_DIR="${DOCKER_DIR:-/var/lib/docker}"
LOG="${LOG:-/var/log/immich-update.log}"
LOCK="${LOCK:-/run/immich-update.lock}"
STATE="${STATE:-/var/lib/immich-update}"
TG="${TG:-/usr/local/sbin/tg-notify.sh}"
API="${API:-http://localhost:2283}"
MODE=run
case "${1:-}" in
    --check) MODE=check ;;
    "") ;;
    *) echo "использование: $0 [--check]"; exit 2 ;;
esac
[ "$(id -u)" -eq 0 ] || [ -n "${ALLOW_NONROOT:-}" ] || { echo "нужен root (sudo)"; exit 1; }

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
tg() { [ "$MODE" = check ] && return 0; [ -x "$TG" ] && "$TG" "Immich: автообновление" "$1" "${2:-info}" >/dev/null 2>&1; return 0; }
# skip: условия не выполнены, ничего не менялось - предупреждение и выход без ошибки
skip() { log "ПРОПУСК: $1"; tg "Пропущено: $1
Ничего не изменено. Следующая попытка по расписанию." warn; exit 0; }
# fail: что-то пошло не так в процессе
fail() { log "СБОЙ: $1"; tg "СБОЙ: $1
Проверь: cd $IMMICH_DIR && sudo docker compose ps && sudo docker compose logs --tail 50" crit; exit 1; }

immich_ver() {
    curl -s --max-time 5 "$API/api/server/version" 2>/dev/null \
        | jq -r '"v\(.major).\(.minor).\(.patch)"' 2>/dev/null
}
immich_up() {
    [ "$(curl -s --max-time 3 "$API/api/server/ping" 2>/dev/null | jq -r '.res' 2>/dev/null)" = "pong" ]
}
# ID образов, перечисленных в compose, одной строкой (для сравнения до/после pull)
image_ids() {
    local img
    docker compose config --images 2>/dev/null | sort -u | while read -r img; do
        [ -n "$img" ] || continue
        printf '%s=%s\n' "$img" "$(docker image inspect --format '{{.Id}}' "$img" 2>/dev/null || echo none)"
    done
}

mkdir -p "$STATE" 2>/dev/null
exec 9>"$LOCK" || exit 1
flock -n 9 || { log "другой экземпляр уже работает, выход"; exit 0; }

log "=== immich-update ($MODE) ==="

# --- проверки ---
[ -d "$IMMICH_DIR" ] || fail "нет папки Immich: $IMMICH_DIR"
cd "$IMMICH_DIR" || fail "cd $IMMICH_DIR"
[ -f docker-compose.yml ] || [ -f compose.yaml ] || [ -f compose.yml ] || fail "нет compose-файла в $IMMICH_DIR"
command -v docker >/dev/null 2>&1 || fail "docker не найден"
command -v jq >/dev/null 2>&1 || fail "jq не найден (apt install jq)"

PIN=$(grep -E '^IMMICH_VERSION=' .env 2>/dev/null | cut -d= -f2)
log "IMMICH_VERSION в .env: ${PIN:-<не задана>}"
if echo "${PIN:-}" | grep -qE '^v?[0-9]+\.[0-9]+\.[0-9]+$'; then
    skip "версия Immich зафиксирована в .env ($PIN) - обновлять нечего. Поставь v3 или release, чтобы обновления шли"
fi

BEFORE=$(immich_ver)
log "Immich сейчас: ${BEFORE:-не отвечает}"

UPM=$(awk '{printf "%d", $1/60}' /proc/uptime 2>/dev/null || echo 999)
[ "$UPM" -ge "$MIN_UPTIME_MIN" ] || skip "система загрузилась ${UPM} мин назад (нужно >= $MIN_UPTIME_MIN)"

FREE=$(df --output=avail -BG "$DOCKER_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')
log "свободно в $DOCKER_DIR: ${FREE:-?} ГБ"
if [ -n "${FREE:-}" ] && [ "$FREE" -lt "$MIN_FREE_GB" ]; then
    skip "мало места в $DOCKER_DIR: ${FREE} ГБ (нужно >= $MIN_FREE_GB)"
fi

if [ -d "$SNAP_DIR" ]; then
    LAST=$(ls -dt "$SNAP_DIR"/* 2>/dev/null | head -1)
    [ -n "$LAST" ] || skip "в $SNAP_DIR нет снимков Immich"
    AGE=$(( ( $(date +%s) - $(stat -c %Y "$LAST") ) / 3600 ))
    log "последний снимок: $LAST (${AGE} ч назад)"
    [ "$AGE" -le 30 ] || skip "последний снимок Immich старше 30 ч (${AGE} ч), без свежей копии не обновляю"
else
    skip "нет папки снимков $SNAP_DIR, не могу проверить резервную копию"
fi

if [ "$MODE" = check ]; then
    log "--- образы сейчас ---"
    image_ids | tee -a "$LOG"
    log "=== --check завершён, ничего не изменено ==="
    exit 0
fi

# --- ждать окончания бэкапов и ночного обслуживания ---
n=0
while pgrep -f 'backup-immich|backup-system|night-maint' >/dev/null 2>&1; do
    [ "$n" -lt "$((BACKUP_WAIT_MIN * 6))" ] || skip "идёт бэкап или обслуживание дольше $BACKUP_WAIT_MIN мин"
    [ "$n" -eq 0 ] && log "идёт бэкап/обслуживание, жду..."
    n=$((n + 1)); sleep 10
done

# --- pull ---
OLD=$(image_ids)
echo "$OLD" > "$STATE/prev-images.txt"
log "docker compose pull"
timeout 20m docker compose pull 2>&1 | tail -6 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
[ "$RC" -eq 0 ] || skip "docker compose pull не удался (код $RC): нет сети или реестр недоступен"
NEW=$(image_ids)

if [ "$OLD" = "$NEW" ]; then
    log "образы не изменились, Immich актуален (${BEFORE:-?})"
    log "=== готово ==="
    exit 0
fi

# --- обновление ---
log "образы изменились, docker compose up -d"
docker compose up -d 2>&1 | tail -8 | tee -a "$LOG"
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "docker compose up -d завершился с ошибкой"

n=0
until immich_up; do
    n=$((n + 1))
    [ "$n" -lt "$((WAIT_MIN * 12))" ] || fail "Immich не ответил на ping за $WAIT_MIN мин (${BEFORE:-?} -> образ обновлён). Старые образы сохранены, список в $STATE/prev-images.txt. Авто-отката нет: после миграции БД он опасен, восстановление из снимка - Часть 8"
    sleep 5
done
AFTER=$(immich_ver)
log "Immich после: ${AFTER:-?}"

# старые безымянные образы старше 30 суток - убрать (только dangling, чужое не трогаем)
docker image prune -f --filter "until=720h" >/dev/null 2>&1

tg "${BEFORE:-?} -> ${AFTER:-?}
Immich отвечает. Предыдущие образы пока сохранены." info
log "=== готово ==="
exit 0
