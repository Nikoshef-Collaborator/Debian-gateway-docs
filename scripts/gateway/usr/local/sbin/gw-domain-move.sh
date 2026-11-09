#!/bin/bash
# gw-domain-move.sh <домен|группа> <warp|direct|amz> [--force]
# Обновляет lane-state.conf и пересобирает 05-gw-manual.conf.
# Защита: amz = полоса своего VPS, а VPS отклоняет российские адреса (Часть 6).
# Поэтому домен с РФ-адресом через amz работать НЕ будет - предупреждаем.
set -u
STATE="/etc/gateway/lane-state.conf"
GROUPS_DIR="/etc/gateway/service-groups"
[ "$(id -u)" -eq 0 ] || { echo "запускай через sudo"; exit 1; }
TARGET="${1:-}"; LANE="${2:-}"; FORCE=0; [ "${3:-}" = "--force" ] && FORCE=1
[ -z "$TARGET" ] || [ -z "$LANE" ] && { echo "Использование: $0 <домен|группа> <warp|direct|amz> [--force]"; exit 1; }
case "$LANE" in warp|direct|amz) ;; *) echo "ERROR: полоса только warp, direct, amz"; exit 1 ;; esac

# amz + российский адрес = домен уедет на VPS и там получит отказ. Проверяем,
# но только для одиночного домена (у группы доменов слишком много - пропускаем).
if [ "$LANE" = amz ] && [ "$FORCE" -eq 0 ] && [ ! -f "$GROUPS_DIR/$TARGET.txt" ]; then
    ru=""
    for ip in $(dig +short "$TARGET" @127.0.0.1 2>/dev/null | grep -E '^[0-9.]+$' | head -8); do
        nft get element ip gwroute ru_cidr "{ $ip }" >/dev/null 2>&1 && { ru="$ip"; break; }
    done
    if [ -n "$ru" ]; then
        echo "ВНИМАНИЕ: у '$TARGET' российский адрес ($ru)."
        echo "Полоса amz идёт через ваш VPS, а он отклоняет российские адреса -"
        echo "через amz этот домен открываться НЕ будет (ERR_CONNECTION_REFUSED)."
        echo "Для РФ-домена нужна полоса 'direct' (напрямую) или 'warp'."
        if [ -t 0 ]; then
            printf "Всё равно отправить на amz? введите ДА: "; read -r a
            [ "$a" = "ДА" ] || { echo "отменено"; exit 1; }
        else
            echo "(неинтерактивно) не трогаю. Повторите с --force, если уверены."; exit 1
        fi
    fi
fi

touch "$STATE"
grep -v "^${TARGET}=" "$STATE" > "${STATE}.tmp" 2>/dev/null || : > "${STATE}.tmp"
[ "$LANE" != "warp" ] && echo "${TARGET}=${LANE}" >> "${STATE}.tmp"
mv "${STATE}.tmp" "$STATE"
/usr/local/sbin/gw-domain-rebuild.sh
