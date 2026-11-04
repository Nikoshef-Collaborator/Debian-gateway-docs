#!/bin/bash
# docs-drift.sh (2026-11-04) - сверка "документация <-> живая машина". Только читает.
# Берёт из публичного репозитория папку scripts/ (файлы так, как они записаны в документации)
# и сравнивает каждый с тем же путём на этой машине.
#   sudo docs-drift.sh                 - отчёт (роль gateway/vps определяется сама)
#   sudo docs-drift.sh vps             - явно указать роль
#   sudo docs-drift.sh --diff ПУТЬ     - построчная разница по одному файлу (не для файлов с ключами)
#   sudo docs-drift.sh -v              - показать и файлы, отличающиеся только комментариями
# Итог: ✓ совпадает, ≈ только пробелы, ≠ отличается, ✗ нет на машине, ~ шаблон (с ПОДСТАВЬ_ - отличаться обязан),
#       ? наши скрипты в /usr/local/sbin, которых нет в документации.
set -u
REPO="https://github.com/Nikoshef-Collaborator/Debian-gateway-docs/archive/refs/heads/main.tar.gz"
ROOT="${ROOT:-}"          # для проверки на копии: ROOT=/путь/к/корню
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SECRET='(/tunnels/|/pool|tg\.conf|/amnezia/|authorized_keys|\.example$)'
VERBOSE=0; [ "${1:-}" = "-v" ] && { VERBOSE=1; shift; }
# без строк-комментариев, пустых строк и хвостовых пробелов: сравниваем код, а не пояснения
norm(){ grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | sed 's/[[:space:]]*$//'; }

fetch(){
    if [ -n "${DRIFT_SRC:-}" ]; then cp -a "$DRIFT_SRC/." "$TMP/repo/"; return; fi   # локальная копия scripts/
    mkdir -p "$TMP/dl"
    curl -fsSL -m 60 "$REPO" | tar xz -C "$TMP/dl" || { echo "не скачать репозиторий: $REPO" >&2; exit 1; }
    cp -a "$TMP"/dl/*/scripts/. "$TMP/repo/"   # repo/ уже создан: mv положил бы scripts ВНУТРЬ него
}
mkdir -p "$TMP/repo"

if [ "${1:-}" = "--diff" ]; then
    f=${2:?укажи путь, например /usr/local/sbin/gw-feeder.sh}
    echo "$f" | grep -qE "$SECRET" && { echo "в этом файле ключи/пароли - разницу не показываю"; exit 1; }
    fetch
    for role in gateway vps; do
        src="$TMP/repo/$role$f"
        if [ -f "$src" ]; then
            echo "=== $role: - документация, + машина"
            diff -u "$src" "$ROOT$f" | tail -n +3
            exit 0
        fi
    done
    echo "в документации такого файла нет: $f"; exit 1
fi

ROLE="${1:-}"
if [ -z "$ROLE" ]; then
    if [ -d "$ROOT/etc/gateway" ]; then ROLE=gateway
    elif [ -d "$ROOT/etc/amnezia/amneziawg" ]; then ROLE=vps
    else echo "не понять роль машины - укажи: gateway или vps"; exit 1; fi
fi
fetch
BASE="$TMP/repo/$ROLE"
[ -d "$BASE" ] || { echo "в репозитории нет scripts/$ROLE"; exit 1; }

declare -A known
n_ok=0; n_ws=0; n_ne=0; n_miss=0; n_tpl=0
echo "════ сверка: роль $ROLE, $(hostname), $(date '+%F %T') ════"
while IFS= read -r src; do
    rel=${src#"$BASE"}
    live="$ROOT${rel%.example}"
    known["${rel%.example}"]=1
    if [[ "$rel" == *.example ]]; then         # файлы с ключами: только наличие, имя у каждого своё
        [ -e "$live" ] && echo "  ~ шаблон (есть)  ${rel%.example}" || echo "  ~ шаблон (свой файл под другим именем?) ${rel%.example}"
        n_tpl=$((n_tpl+1)); continue
    fi
    if [ ! -e "$live" ]; then
        echo "  ✗ нет на машине  $rel"; n_miss=$((n_miss+1)); continue
    fi
    if grep -q 'ПОДСТАВЬ' "$src"; then         # шаблон: строки с ПОДСТАВЬ на машине обязаны быть другими
        dd=$(diff "$src" "$live" 2>/dev/null)
        lt=$(grep '^<' <<<"$dd" | grep -vc 'ПОДСТАВЬ')   # пропавшие обычные строки
        lp=$(grep '^<' <<<"$dd" | grep -c 'ПОДСТАВЬ')    # заменённые строки с ПОДСТАВЬ
        gt=$(grep -c '^>' <<<"$dd")                      # строки, которые есть только на машине
        if [ "$lt" = 0 ] && [ "$gt" -le "$lp" ]; then n_tpl=$((n_tpl+1))
        else echo "  ≠ отличается     $rel  (шаблон; лишних строк: $((lt + gt - lp)))"; n_ne=$((n_ne+1)); fi
        continue
    fi
    if cmp -s "$src" "$live"; then
        n_ok=$((n_ok+1))
    elif diff -qwB <(norm "$src") <(norm "$live") >/dev/null 2>&1; then
        n_ws=$((n_ws+1)); [ "$VERBOSE" = 1 ] && echo "  ≈ комментарии    $rel"
    else
        d=$(diff -wB <(norm "$src") <(norm "$live") 2>/dev/null | grep -c '^[<>]')
        echo "  ≠ отличается     $rel  (строк кода: $d)"; n_ne=$((n_ne+1))
    fi
done < <(find "$BASE" -type f | sort)

echo "  -- в /usr/local/sbin, но нет в документации (кто запускает: юнит/cron/скрипт):"
n_unk=0; baks=""
for f in "$ROOT"/usr/local/sbin/*; do
    [ -f "$f" ] || continue
    b=$(basename "$f"); rel="/usr/local/sbin/$b"
    [ -n "${known[$rel]:-}" ] && continue
    case "$b" in *.bak*|*~|*.orig|*.old) baks="$baks $b"; continue ;; esac
    who=$(grep -rlsF "$b" "$ROOT"/etc/systemd/system "$ROOT"/etc/cron* "$ROOT"/var/spool/cron "$ROOT"/etc/OliveTin "$ROOT"/usr/local/sbin 2>/dev/null \
          | grep -v "/$b\$" | grep -vE '\.bak|~$' | sed "s|^$ROOT||; s|^/etc/systemd/system/||" | head -2 | tr '\n' ' ')
    printf '  ? %-34s %s\n' "$b" "${who:-НИКТО не запускает}"; n_unk=$((n_unk+1))
done
[ "$n_unk" = 0 ] && echo "     нет"
[ -n "$baks" ] && echo "  -- резервные копии в /usr/local/sbin (место им в /root):$baks"
echo "════ итог: ✓ $n_ok  ≈ $n_ws (только комментарии)  ≠ $n_ne  ✗ $n_miss  ~ $n_tpl  ? $n_unk ════"
echo "Разница по файлу: sudo $0 --diff ПУТЬ"
