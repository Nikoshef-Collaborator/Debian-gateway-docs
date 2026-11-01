import sys
p = sys.argv[1]
t = open(p).read()
if 'fetch(){' in t:
    sys.exit("УЖЕ ПОПРАВЛЕН - ничего не делаю")
FETCH = '''TABLE="gwroute"

# --- скачивание с повторами и кэшем (2026-10-31) ---
# Причина: при сбое DNS/сети в момент запуска (после загрузки, в полночь) списки
# не качались, и наборы (voice_direct, ru_cidr) оставались ПУСТЫМИ до следующего
# удачного запуска - Telegram и РФ-сайты уходили не в свои полосы.
# fetch URL OUT: 5 попыток; удачно -> обновить кэш; неудачно -> взять из кэша.
CACHE_DIR=/var/lib/gw-feeder
mkdir -p "$CACHE_DIR"
fetch(){
    local url=$1 out=$2 key
    key="$CACHE_DIR/$(printf '%s' "$url" | md5sum | cut -c1-16)"
    if curl -fsS --max-time 30 --retry 4 --retry-delay 15 --retry-all-errors "$url" -o "$out" && [ -s "$out" ]; then
        cp -f "$out" "$key"
        return 0
    fi
    if [ -s "$key" ]; then
        cp -f "$key" "$out"
        logger -t "$LOG_TAG" "WARN: не скачать $url - беру из кэша от $(date -r "$key" +%F)"
        return 0
    fi
    return 1
}
'''
reps = [
    ('TABLE="gwroute"\n', FETCH),
    ('if curl -fsS --max-time 30 "$RU_DOMAINS_URL" -o "$tmp" && [ -s "$tmp" ]; then', 'if fetch "$RU_DOMAINS_URL" "$tmp"; then'),
    ('if curl -fsS --max-time 30 "$RU_CIDR_URL" -o "$tmp" && [ -s "$tmp" ]; then', 'if fetch "$RU_CIDR_URL" "$tmp"; then'),
    ('curl -fsS --max-time 30 "$url" >> "$tmp" || ok=0', '{ fetch "$url" "$tmp.part" && cat "$tmp.part" >> "$tmp"; } || ok=0; rm -f "$tmp.part"'),
    ('if curl -fsS --max-time 30 "$url" -o "$tmp" && [ -s "$tmp" ]; then', 'if fetch "$url" "$tmp"; then'),
]
for a, b in reps:
    if t.count(a) != 1:
        sys.exit("ЯКОРЬ НЕ НАЙДЕН ИЛИ НЕ ОДИН: " + a.strip()[:70])
    t = t.replace(a, b)
open(p, 'w').write(t)
print("OK: фидер поправлен (повторы + кэш)")
