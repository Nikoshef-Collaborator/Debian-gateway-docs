#!/bin/bash
# docs-drift.sh (2026-11-04) - сверка "документация <-> живая машина". Только читает.
# Берёт из публичного репозитория папку scripts/ (файлы так, как они записаны в документации)
# и сравнивает каждый с тем же путём на этой машине.
#   sudo docs-drift.sh                 - отчёт (роль gateway/vps определяется сама)
#   sudo docs-drift.sh vps             - явно указать роль
#   sudo docs-drift.sh --diff ПУТЬ...  - построчная разница по файлам (не для файлов с ключами)
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
    if [ -n "${DRIFT_SRC:-}" ]; then   # локальная копия scripts/ (и tools/ рядом, если есть)
        cp -a "$DRIFT_SRC/." "$TMP/repo/"
        [ -d "$DRIFT_SRC/../tools" ] && cp -a "$DRIFT_SRC/../tools/." "$TMP/tools/"
        return
    fi
    mkdir -p "$TMP/dl"
    curl -fsSL -m 60 "$REPO" | tar xz -C "$TMP/dl" || { echo "не скачать репозиторий: $REPO" >&2; exit 1; }
    cp -a "$TMP"/dl/*/scripts/. "$TMP/repo/"   # repo/ уже создан: mv положил бы scripts ВНУТРЬ него
    cp -a "$TMP"/dl/*/tools/. "$TMP/tools/" 2>/dev/null || true
}
mkdir -p "$TMP/repo" "$TMP/tools"

if [ "${1:-}" = "--diff" ]; then   # --diff ПУТЬ [ПУТЬ...]: одно скачивание на все файлы
    shift; [ $# -gt 0 ] || { echo "укажи путь, например /usr/local/sbin/gw-feeder.sh"; exit 1; }
    fetch
    for f in "$@"; do
        echo "════ $f"
        if echo "$f" | grep -qE "$SECRET"; then echo "в этом файле ключи/пароли - разницу не показываю"; continue; fi
        src=""; who=""
        for role in gateway vps; do [ -f "$TMP/repo/$role$f" ] && { src="$TMP/repo/$role$f"; who=$role; break; }; done
        if [ -z "$src" ] && [ "$(dirname "$f")" = /usr/local/sbin ] && [ -f "$TMP/tools/$(basename "$f")" ]; then
            src="$TMP/tools/$(basename "$f")"; who=tools
        fi
        [ -z "$src" ] && { echo "в документации такого файла нет"; continue; }
        [ -e "$ROOT$f" ] || { echo "на машине такого файла нет"; continue; }
        echo "=== $who: - документация, + машина"
        diff -u "$src" "$ROOT$f" | tail -n +3
    done
    exit 0
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

declare -A known mine
n_ok=0; n_ws=0; n_ne=0; n_miss=0; n_tpl=0; n_mine=0
# свои сознательные правки: строка "ПУТЬ  # зачем" в drift-local.conf - такой файл
# идёт отдельной строкой ◇ и не считается расхождением
LOCALF="$ROOT/etc/gateway/drift-local.conf"
if [ -f "$LOCALF" ]; then
    while IFS= read -r l; do
        p=${l%%#*}; p=${p//[[:space:]]/}; [ -z "$p" ] && continue
        n=""; [[ "$l" == *#* ]] && n=${l#*#}
        mine["$p"]="${n# }"
    done < "$LOCALF"
fi
# ≠ или ◇: $1=путь, $2=пояснение в скобках
ne(){
    if [ -n "${mine[$1]+x}" ]; then echo "  ◇ свои правки    $1  ($2)${mine[$1]:+ - ${mine[$1]}}"; n_mine=$((n_mine+1))
    else echo "  ≠ отличается     $1  ($2)"; n_ne=$((n_ne+1)); fi
}
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
        if [ -n "${mine[$rel]+x}" ]; then echo "  ◇ нет сознательно $rel${mine[$rel]:+ - ${mine[$rel]}}"; n_mine=$((n_mine+1))
        else echo "  ✗ нет на машине  $rel"; n_miss=$((n_miss+1)); fi
        continue
    fi
    if grep -q 'ПОДСТАВЬ' "$src"; then         # шаблон: строки с ПОДСТАВЬ на машине обязаны быть другими
        dd=$(diff "$src" "$live" 2>/dev/null)
        lt=$(grep '^<' <<<"$dd" | grep -vc 'ПОДСТАВЬ')   # пропавшие обычные строки
        lp=$(grep '^<' <<<"$dd" | grep -c 'ПОДСТАВЬ')    # заменённые строки с ПОДСТАВЬ
        gt=$(grep -c '^>' <<<"$dd")                      # строки, которые есть только на машине
        if [ "$lt" = 0 ] && [ "$gt" -le "$lp" ]; then n_tpl=$((n_tpl+1))
        else ne "$rel" "шаблон; лишних строк: $((lt + gt - lp))"; fi
        continue
    fi
    if cmp -s "$src" "$live"; then
        n_ok=$((n_ok+1))
    elif diff -qwB <(norm "$src") <(norm "$live") >/dev/null 2>&1; then
        n_ws=$((n_ws+1)); [ "$VERBOSE" = 1 ] && echo "  ≈ комментарии    $rel"
    else
        d=$(diff -wB <(norm "$src") <(norm "$live") 2>/dev/null | grep -c '^[<>]')
        ne "$rel" "строк кода: $d"
    fi
done < <(find "$BASE" -type f | sort)

# инструменты из tools/ (ставятся скачиванием, Часть 4): сверяем, если стоят
for src in "$TMP"/tools/*; do
    [ -f "$src" ] || continue
    rel="/usr/local/sbin/$(basename "$src")"; live="$ROOT$rel"
    [ -n "${known[$rel]:-}" ] && continue
    [ -e "$live" ] || continue
    known["$rel"]=1
    if cmp -s "$src" "$live"; then n_ok=$((n_ok+1))
    elif diff -qwB <(norm "$src") <(norm "$live") >/dev/null 2>&1; then
        n_ws=$((n_ws+1)); [ "$VERBOSE" = 1 ] && echo "  ≈ комментарии    $rel"
    else
        ne "$rel" "tools/, строк кода: $(diff -wB <(norm "$src") <(norm "$live") 2>/dev/null | grep -c '^[<>]')"
    fi
done
echo "  -- в /usr/local/sbin, но нет в документации (кто вызывает; (выкл) - юнит выключен):"
n_unk=0; baks=""
for f in "$ROOT"/usr/local/sbin/*; do
    [ -f "$f" ] || continue
    b=$(basename "$f"); rel="/usr/local/sbin/$b"
    [ -n "${known[$rel]:-}" ] && continue
    case "$b" in *.bak*|*~|*.orig|*.old) baks="$baks $b"; continue ;; esac
    who=""
    while IFS= read -r r; do
        r=${r#"$ROOT"}
        case "$r" in
        /etc/systemd/system/*.service)
            u=${r#/etc/systemd/system/}
            # включён ли юнит: у сервиса с таймером смотрим таймер
            [ -f "$ROOT/etc/systemd/system/${u%.service}.timer" ] && u2=${u%.service}.timer || u2=$u
            st=""; [ -z "$ROOT" ] && st=$(systemctl is-enabled "$u2" 2>/dev/null)
            case "$st" in disabled|masked) r="$u(выкл)" ;; *) r="$u" ;; esac ;;
        /etc/systemd/system/*) r=${r#/etc/systemd/system/} ;;
        esac
        who="$who$r "
    done < <(grep -rlsF "$b" "$ROOT"/etc/systemd/system "$ROOT"/etc/cron* "$ROOT"/var/spool/cron "$ROOT"/etc/OliveTin \
                 "$ROOT"/etc/smartd.conf "$ROOT"/etc/NetworkManager/dispatcher.d "$ROOT"/etc/network "$ROOT"/etc/udev/rules.d \
                 "$ROOT"/usr/local/sbin 2>/dev/null | grep -v "/$b\$" | grep -vE '\.bak|~$|\.timer$' | head -3)
    printf '  ? %-34s %s\n' "$b" "${who:-НИКТО не запускает (руками?)}"; n_unk=$((n_unk+1))
done
[ "$n_unk" = 0 ] && echo "     нет"
[ -n "$baks" ] && echo "  -- резервные копии в /usr/local/sbin (место им в /root):$baks"
echo "════ итог: ✓ $n_ok  ≈ $n_ws (только комментарии)  ◇ $n_mine (свои правки)  ≠ $n_ne  ✗ $n_miss  ~ $n_tpl  ? $n_unk ════"
echo "Разница по файлу: sudo $0 --diff ПУТЬ"
