#!/bin/bash
# warp-reseat.sh - пересадка пула WARP на точки входа мимо Москвы (узел DME).
#  1) warpscout ищет точки входа, которые с нашей сети ведут не в DME;
#  2) каждому конфигу пула - копия <имя>-ws.conf: новая точка входа + мусор
#     (Jc/Jmin/Jmax/I1), с которым warpscout в ЭТОМ ЖЕ скане прошёл туннель;
#  3) копия проверяется gw-warp-test: рукопожатие, узел не DME, скорость.
# Оригиналы не трогает. Копии, не прошедшие проверку, удаляет. Копию, чей
# ключ сейчас стоит в слоте, не трогает (тест с тем же ключом невозможен).
# Запуск: sudo warp-reseat.sh   (таймер warp-reseat.timer - раз в неделю)
set -u
export LC_ALL=C
WS=/opt/warpscout/warpscout
ACC=/opt/warpscout/warpscout-account.json
POOLS=(/etc/warp/pool /etc/gateway/pool)
TUNNELS=/etc/gateway/tunnels
TEST=/usr/local/sbin/gw-warp-test.sh
AVOID_COLO="DME"   # узлы, на которые не садиться (через запятую)
SKIP_PORTS="500"   # порты, где ТСПУ режет скорость (если других нет - берём и их)
CAND_MAX=6         # сколько лучших точек входа брать из скана
TRY_MAX=3          # сколько точек входа пробовать на один конфиг
MIN_MBPS=1.0       # медленнее - копию не оставляем

say(){ echo "[warp-reseat] $*"; logger -t warp-reseat "$*" 2>/dev/null; }
[ "$(id -u)" -eq 0 ] || { echo "запускай через sudo"; exit 1; }
{ [ -x "$WS" ] && [ -f "$ACC" ]; } || { say "нет $WS или $ACC - Часть 5, Шаг 5.7"; exit 1; }
exec 9>/run/warp-reseat.lock
flock -n 9 || { say "уже запущен"; exit 0; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# точки входа из отчёта: первая таблица, потери 0%; $1 = порты, которые пропустить
cands(){
    awk -v skip=" $1 " '
        /^ENDPOINT /{t++; next}
        /^$/{ if (t == 1) exit; next }
        /^#/{ next }
        t == 1 && $4 == "0%" { split($1, a, ":"); if (index(skip, " " a[2] " ") == 0) print $1 }
    ' "$TMP/report.txt" 2>/dev/null | head -n "$CAND_MAX"
}

scan(){  # $@ - флаги мусора для warpscout
    rm -f "$TMP/report.txt" "$TMP/scout.conf"
    (cd "$TMP" && "$WS" scan -a "$ACC" -p awg -P -plain -exclude-node "$AVOID_COLO" \
        -o "$TMP/report.txt" -conf "$TMP/scout.conf" "$@" >/dev/null 2>&1)
    cands "$SKIP_PORTS" > "$TMP/cand.txt"
    [ -s "$TMP/cand.txt" ] || cands "" > "$TMP/cand.txt"
    [ -s "$TMP/cand.txt" ] && [ -s "$TMP/scout.conf" ]
}

# ключ конфига сейчас стоит в одном из слотов?
inslot(){
    local key
    key=$(awk '/^[[:space:]]*PrivateKey[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/, ""); print; exit}' "$1")
    [ -n "$key" ] && grep -qsF -- "$key" "$TUNNELS"/vpn-*.conf
}

# копия: ключи и адреса из $1, мусор из junk.txt, Endpoint = $3; пишет в $2
build(){
    awk -v ep="Endpoint = $3" '
        NR == FNR { ifl = ifl $0 "\n"; next }
        /^[[:space:]]*(Jc|Jmin|Jmax|I[1-5]|Endpoint)[[:space:]]*=/ { next }
        /^\[Interface\]/ { print; printf "%s", ifl; next }
        /^\[Peer\]/ { print; print ep; next }
        { print }
    ' "$TMP/junk.txt" "$1" > "$2"
    chmod 600 "$2"
}

if scan; then
    say "скан: $(wc -l < "$TMP/cand.txt") точек входа мимо $AVOID_COLO, мусор по умолчанию warpscout"
elif scan -gen-junk -gen-i1 quic; then
    say "скан: с мусором по умолчанию пусто - взят случайный мусор и I1 под QUIC"
else
    say "скан не нашёл точек входа мимо $AVOID_COLO - пул не трогаю"; exit 1
fi
grep -E '^[[:space:]]*(Jc|Jmin|Jmax|I[1-5])[[:space:]]*=' "$TMP/scout.conf" > "$TMP/junk.txt"
rm -f "$TMP/scout.conf"   # в нём ключ аккаунта warpscout - не держим дольше нужного
mapfile -t CAND < "$TMP/cand.txt"
N=${#CAND[@]}

ok=0; bad=0; kept=0; n=0
for d in "${POOLS[@]}"; do
    for src in "$d"/*.conf; do
        [ -f "$src" ] || continue
        case "$(basename "$src")" in *-ws.conf) continue ;; esac
        dst="${src%.conf}-ws.conf"; name=$(basename "$dst")
        if inslot "$src"; then
            say "  $name: ключ сейчас в слоте - не трогаю"; kept=$((kept+1)); continue
        fi
        done1=0
        for k in $(seq 0 $((TRY_MAX - 1))); do
            [ "$k" -ge "$N" ] && break
            ep=${CAND[$(( (n + k) % N ))]}   # по кругу: конфиги расходятся по разным точкам входа
            build "$src" "$dst" "$ep"
            out=$("$TEST" "$name" 2>&1)
            colo=$(echo "$out" | awk -F'[:,] *' '/узел:/{print $2; exit}')
            mbps=$(echo "$out" | awk '/скорость:/{ if ($2 ~ /^[0-9.]+$/) print $2; else print 0; exit }')
            if echo "$out" | grep -q 'РЕЗУЛЬТАТ: OK' && [ -n "$colo" ] && [ "$colo" != "н/д" ] \
               && ! echo ",$AVOID_COLO," | grep -q ",$colo," \
               && awk -v s="${mbps:-0}" -v m="$MIN_MBPS" 'BEGIN{exit !(s >= m)}'; then
                say "  $name: $ep -> узел $colo, $mbps MB/s"; done1=1; break
            fi
            say "  $name: $ep не прошёл (узел ${colo:-н/д}, ${mbps:-0} MB/s)"
        done
        if [ "$done1" -eq 1 ]; then ok=$((ok+1)); else rm -f "$dst"; bad=$((bad+1)); fi
        n=$((n+1))
    done
done

# копии, у которых оригинал удалён
for d in "${POOLS[@]}"; do
    for f in "$d"/*-ws.conf; do
        [ -f "$f" ] || continue
        [ -f "${f%-ws.conf}.conf" ] && continue
        inslot "$f" && continue
        rm -f "$f"; say "  удалена копия без оригинала: $(basename "$f")"
    done
done

say "готово: пересажено $ok, не прошли $bad, в слоте $kept"
[ -x /usr/local/sbin/tg-notify.sh ] && /usr/local/sbin/tg-notify.sh "WARP: пересадка пула" "Мимо $AVOID_COLO пересажено $ok, не прошли $bad, в слоте $kept" info
exit 0
