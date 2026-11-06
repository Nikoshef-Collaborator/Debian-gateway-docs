#!/bin/bash
# warp-reseat.sh - пересадка пула WARP на точки входа мимо Москвы (узел DME).
#  1) warpscout ищет точки входа, которые с нашей сети ведут не в DME;
#  2) каждому конфигу пула - копия <имя>-ws.conf: новая точка входа + СВОЙ мусор
#     (случайные Jc/Jmin/Jmax и I1 под QUIC), который warpscout тут же проверяет
#     на этой точке входа; не прошёл - общий набор из скана (тоже проверенный);
#  3) копия проверяется gw-warp-test: рукопожатие, узел не DME, скорость.
# Оригиналы не трогает. Копии, не прошедшие проверку, удаляет. Копию, чей
# ключ сейчас стоит в слоте, не трогает (тест с тем же ключом невозможен).
# Запуск: sudo warp-reseat.sh          (таймер warp-reseat.timer - раз в неделю)
#         sudo warp-reseat.sh --test   - обкатка: копии кладутся в /etc/warp/pool-test,
#                                        warp-pick их не видит, живой пул не меняется
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
JUNK_MODE="unique" # unique - свой мусор на каждую копию; template - один набор из скана на все
TESTDIR=/etc/warp/pool-test
MODE="live"; [ "${1:-}" = "--test" ] && MODE="test"

say(){ local p="[warp-reseat]"; [ "$MODE" = test ] && p="[warp-reseat тест]"; echo "$p $*"; logger -t warp-reseat "$p $*" 2>/dev/null; }
[ "$(id -u)" -eq 0 ] || { echo "запускай через sudo"; exit 1; }
{ [ -x "$WS" ] && [ -f "$ACC" ]; } || { say "нет $WS или $ACC - Часть 5, Шаг 5.7"; exit 1; }
exec 9>/run/warp-reseat.lock
flock -n 9 || { say "уже запущен"; exit 0; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
if [ "$MODE" = test ]; then
    mkdir -p "$TESTDIR" && chmod 700 "$TESTDIR" && rm -f "$TESTDIR"/*-ws.conf
fi

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

# свой мусор для точки входа $1 (ip:port) -> $TMP/junk1.txt. warpscout генерирует
# случайные Jc/Jmin/Jmax и I1 под QUIC и проверяет туннель с ними; конфиг печатает
# в поток (там ключ сканера) - берём из него только строки мусора
genjunk(){
    (cd "$TMP" && "$WS" scan -a "$ACC" -p awg -P -plain -no-report -target "${1%:*}" -port "${1##*:}" \
        -exclude-node "$AVOID_COLO" -gen-junk -gen-i1 quic -conf - 2>/dev/null) \
        | grep -E '^[[:space:]]*(Jc|Jmin|Jmax|I[1-5])[[:space:]]*=' > "$TMP/junk1.txt"
    grep -q '^[[:space:]]*I1' "$TMP/junk1.txt"
}

# копия: ключи и адреса из $1, мусор из файла $4, Endpoint = $3; пишет в $2
build(){
    awk -v ep="Endpoint = $3" '
        NR == FNR { ifl = ifl $0 "\n"; next }
        /^[[:space:]]*(Jc|Jmin|Jmax|I[1-5]|Endpoint)[[:space:]]*=/ { next }
        /^\[Interface\]/ { print; printf "%s", ifl; next }
        /^\[Peer\]/ { print; print ep; next }
        { print }
    ' "$4" "$1" > "$2"
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
        if [ "$MODE" = test ]; then
            dst="$TESTDIR/$(basename "${src%.conf}")-ws.conf"
            tname="../pool-test/$(basename "$dst")"   # gw-warp-test ищет от папки пула
        else
            dst="${src%.conf}-ws.conf"; tname=$(basename "$dst")
        fi
        name=$(basename "$dst")
        if inslot "$src"; then
            say "  $name: ключ сейчас в слоте - не трогаю"; kept=$((kept+1)); continue
        fi
        done1=0
        for k in $(seq 0 $((TRY_MAX - 1))); do
            [ "$k" -ge "$N" ] && break
            ep=${CAND[$(( (n + k) % N ))]}   # по кругу: конфиги расходятся по разным точкам входа
            jlist="$TMP/junk.txt"
            [ "$JUNK_MODE" = unique ] && genjunk "$ep" && jlist="$TMP/junk1.txt $TMP/junk.txt"
            for jf in $jlist; do
                how="общий мусор"; [ "$jf" = "$TMP/junk1.txt" ] && how="свой мусор"
                build "$src" "$dst.new" "$ep" "$jf"   # .new не попадает под *.conf - warp-pick его не возьмёт
                out=$("$TEST" "$tname.new" 2>&1)
                colo=$(echo "$out" | awk -F'[:,] *' '/узел:/{print $2; exit}')
                mbps=$(echo "$out" | awk '/скорость:/{ if ($2 ~ /^[0-9.]+$/) print $2; else print 0; exit }')
                if echo "$out" | grep -q 'РЕЗУЛЬТАТ: OK' && [ -n "$colo" ] && [ "$colo" != "н/д" ] \
                   && ! echo ",$AVOID_COLO," | grep -q ",$colo," \
                   && awk -v s="${mbps:-0}" -v m="$MIN_MBPS" 'BEGIN{exit !(s >= m)}'; then
                    mv -f "$dst.new" "$dst"   # подмена одним действием, только проверенного
                    say "  $name: $ep ($how) -> узел $colo, $mbps MB/s"; done1=1; break
                fi
                say "  $name: $ep ($how) не прошёл (узел ${colo:-н/д}, ${mbps:-0} MB/s)"
            done
            [ "$done1" -eq 1 ] && break
        done
        rm -f "$dst.new"
        if [ "$done1" -eq 1 ]; then ok=$((ok+1)); else rm -f "$dst"; bad=$((bad+1)); fi
        n=$((n+1))
    done
done

# копии, у которых оригинал удалён (в обкатке не нужно)
[ "$MODE" = test ] || for d in "${POOLS[@]}"; do
    for f in "$d"/*-ws.conf; do
        [ -f "$f" ] || continue
        [ -f "${f%-ws.conf}.conf" ] && continue
        inslot "$f" && continue
        rm -f "$f"; say "  удалена копия без оригинала: $(basename "$f")"
    done
done

say "готово: пересажено $ok, не прошли $bad, в слоте $kept"
[ "$MODE" = test ] && say "копии в $TESTDIR - живой пул не тронут"
[ "$MODE" = test ] || { [ -x /usr/local/sbin/tg-notify.sh ] && /usr/local/sbin/tg-notify.sh "WARP: пересадка пула" "Мимо $AVOID_COLO пересажено $ok, не прошли $bad, в слоте $kept" info; }
exit 0
