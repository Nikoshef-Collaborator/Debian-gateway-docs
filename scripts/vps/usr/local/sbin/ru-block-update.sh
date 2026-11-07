#!/bin/sh
# ru-block-update.sh - обновляет набор inet filter ru4 списком российских сетей
# (ipdeny.com). Клиентам туннеля соединения на эти адреса запрещены (Шаг 6.4).
#
# Защиты:
#  - в набор попадают только строки вида a.b.c.d/nn;
#  - меньше MIN_LINES сетей -> сбой загрузки, ничего не меняем;
#  - новый список меньше MIN_RATIO% или больше MAX_RATIO% текущего -> ничего не меняем;
#  - западные контрольные адреса в списке или нет российских -> ничего не меняем;
#  - замена набора одной транзакцией nft: либо целиком новый, либо старый,
#    пустого набора не бывает ни на миг;
#  - список сохраняется в /etc/nftables.d/ru4.nft - после перезагрузки сразу на месте.
set -eu

URL="${URL:-https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone}"
OUT="${OUT:-/etc/nftables.d/ru4.nft}"
MIN_LINES="${MIN_LINES:-5000}"
MIN_RATIO="${MIN_RATIO:-80}"
MAX_RATIO="${MAX_RATIO:-125}"
# 1.1.1.1/8.8.8.8/9.9.9.9 - DNS; 149.154.167.50 - Telegram; 142.250.0.1 - Google;
# 104.16.0.1 - Cloudflare; 140.82.112.3 - GitHub; последний - адрес самого VPS
SENTINEL_WEST="${SENTINEL_WEST:-1.1.1.1 8.8.8.8 9.9.9.9 149.154.167.50 142.250.0.1 104.16.0.1 140.82.112.3 ПОДСТАВЬ_IP_VPS}"
# 77.88.8.8 - Яндекс DNS
SENTINEL_RU="${SENTINEL_RU:-77.88.8.8}"

TMP="$(mktemp)"
NEW="$(mktemp)"
trap 'rm -f "$TMP" "$TMP.ok" "$TMP.err" "$NEW"' EXIT

curl -fsS --max-time 120 "$URL" -o "$TMP"

# Строго: 4 октета 0-255 и маска 8-32. Всё прочее отбрасываем,
# чтобы nft никогда не увидел строку, которую примет за имя хоста.
# (без ведущих нулей: "001" nft тоже принял бы за имя хоста)
awk -F'[./]' 'NF == 5 && $0 ~ /^((0|[1-9][0-9]?[0-9]?)\.)((0|[1-9][0-9]?[0-9]?)\.)((0|[1-9][0-9]?[0-9]?)\.)(0|[1-9][0-9]?[0-9]?)\/[0-9][0-9]?$/ \
    && $1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255 && $5 >= 8 && $5 <= 32' \
    "$TMP" > "$TMP.ok"
BAD="$(grep -cv '^[[:space:]]*$' "$TMP" || true)"
BAD=$((BAD - $(wc -l < "$TMP.ok")))
if [ "$BAD" -gt 0 ]; then
    echo "ru-block: отброшено строк с неверным форматом: $BAD" >&2
fi

N="$(wc -l < "$TMP.ok")"
if [ "$N" -lt "$MIN_LINES" ]; then
    echo "ru-block: в списке всего $N сетей (< $MIN_LINES), похоже на сбой загрузки - ничего не меняю" >&2
    exit 1
fi

OLD=0
if [ -f "$OUT" ]; then
    OLD="$(grep -o '/' "$OUT" | wc -l)"
fi
if [ "$OLD" -gt 0 ] && [ $((N * 100)) -lt $((OLD * MIN_RATIO)) ]; then
    echo "ru-block: новый список $N сетей, был $OLD (меньше ${MIN_RATIO}%) - подозрительно, ничего не меняю" >&2
    exit 1
fi

if [ "$OLD" -gt 0 ] && [ $((N * 100)) -gt $((OLD * MAX_RATIO)) ]; then
    echo "ru-block: новый список $N сетей, был $OLD (рост больше ${MAX_RATIO}%) - подозрительно, ничего не меняю" >&2
    exit 1
fi

# Контрольные адреса. WEST - не должны попасть в набор (иначе сломаем
# западные сервисы для клиентов). RU - обязаны быть (иначе список не тот).
inlist() {  # $1 - адреса через пробел; печатает те, что покрыты списком
    awk -v s="$1" '
        function ip(a,  p) { split(a, p, "."); return ((p[1]*256 + p[2])*256 + p[3])*256 + p[4] }
        BEGIN { n = split(s, S, " ") }
        { split($0, c, "/"); b = ip(c[1]); m = 2 ^ (32 - c[2])
          for (i = 1; i <= n; i++) { x = ip(S[i]); if (x >= b && x < b + m) hit[S[i]] = 1 } }
        END { for (k in hit) print k }' "$TMP.ok"
}
W_HIT="$(inlist "$SENTINEL_WEST")"
if [ -n "$W_HIT" ]; then
    echo "ru-block: в список попали западные контрольные адреса: $(echo $W_HIT) - ничего не меняю" >&2
    exit 1
fi
R_HIT="$(inlist "$SENTINEL_RU" | wc -l)"
if [ "$R_HIT" -ne "$(echo $SENTINEL_RU | wc -w)" ]; then
    echo "ru-block: в списке нет обязательных российских адресов ($SENTINEL_RU) - ничего не меняю" >&2
    exit 1
fi

{
    echo "flush set inet filter ru4"
    printf 'add element inet filter ru4 { '
    paste -sd, "$TMP.ok"
    echo ' }'
} > "$NEW"

if ! nft -c -f "$NEW" 2>"$TMP.err"; then
    echo "ru-block: nft отверг новый список, набор не тронут:" >&2
    cut -c1-300 "$TMP.err" | head -n 5 >&2
    exit 1
fi
nft -f "$NEW"

install -m 0644 "$NEW" "$OUT"
echo "ru-block: загружено $N сетей (было $OLD)"
