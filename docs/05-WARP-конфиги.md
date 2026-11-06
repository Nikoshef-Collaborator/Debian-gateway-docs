# ЧАСТЬ 5 - WARP-конфиги: генерация, докрутка, проверка

> **Зачем.** Основной выход дома - WARP (`vpn-main`), он берётся из пула
> конфигов. Со временем ТСПУ учится узнавать конкретный конфиг, тот
> деградирует. Нужен запас разных конфигов. Эта часть - как их делать,
> проверять и что в них можно менять.
>
> **Правила для ИИ - в Части 0.** Здесь особенно: **не меняй `H1-H4`,
> `S1/S2` и `MTU` WARP-конфигов** - см. таблицу ниже.
>
> Объединяет прежние Часть 5 и заметки сообщества про докрутку конфигов
> (август 2026).

---

## Как работает маскировка

WARP - это WireGuard от Cloudflare. Чтобы ТСПУ не узнал WireGuard по
сигнатуре, AmneziaWG добавляет:
- **мусорные пакеты** перед рукопожатием (`Jc`, `Jmin`, `Jmax`);
- **I1** - поддельный первый пакет, похожий на начало QUIC/HTTP3
  (легитимный протокол), а не на WireGuard.

Принцип: **разные конфиги пула должны выглядеть по-разному.** Одинаковый
"мусорный поезд" у всех - готовая сигнатура для DPI. Разнообразие - через
`I1`, `Jc/Jmin/Jmax` и endpoint.

---

## ⛔ Что можно и что нельзя менять в WARP-конфиге

| Параметр | Можно? | Почему |
|---|---|---|
| `Jc`, `Jmin`, `Jmax` | ✅ да, и нужно | мусорные пакеты, сервер их не разбирает |
| `I1` (и `I2-I5`) | ✅ да | поддельный QUIC, чем разнообразнее - тем лучше |
| `Endpoint` (адрес и порт) | ✅ да | разные адреса пула WARP; порт не `2408` |
| `PersistentKeepalive` | ✅ (на шлюзе всегда 25) | ставит `warp-pick` |
| `DNS` | не важно | на шлюзе строку `DNS=` вырезают скрипты |
| **`H1, H2, H3, H4`** | ❌ **НЕТ** | для WARP строго `1/2/3/4`, иначе Cloudflare не примет рукопожатие |
| **`S1, S2`** | ❌ **НЕТ** | для WARP строго `0/0` |
| `MTU` | ⚠️ `1280` | больше - фрагментация, рвётся крупный трафик |
| `PrivateKey` / `PublicKey` | ❌ | из регистрации `wgcf` |

> Правило про `H` и `S` - **только для WARP**. Для своего сервера AmneziaWG
> (Часть 6) они задаются сервером, могут быть диапазонами и обязаны совпадать
> у клиента и сервера.

### Порт endpoint

`2408` - "визитная карточка" WARP, его ловят первым. Рабочие альтернативы:
**`500`, `1701`, `4500`**. Пример адреса: `162.159.195.1:500`.

Реальный случай: подсеть `162.159.192.0/24` целиком перестала работать, а
соседняя `162.159.195.0/24` осталась живой - при тех же ключах и маскировке.
Поэтому в пуле нужны разные адреса.

Ноябрь 2026: на порту `500` ТСПУ режет скорость (около 5 MB/s), на `2408` с
подходящим мусором - 6-12 MB/s. Какой узел Cloudflare (`DME` = Москва) стоит
за адресом и как пересадить пул - Шаг 5.7.

### Jc / Jmin / Jmax

Единого рецепта нет - подбирать. Рабочие варианты из практики и сообщества:

```
Jc = 4,  Jmin = 40, Jmax = 70
Jc = 6,  Jmin = 40, Jmax = 133
Jc = 3,  Jmin = 4,  Jmax = 911
```

Высокий `Jc` (100-200) без `I1` работает хуже, чем умеренный `Jc` (3-8) с
динамическим `I1`.

### I1

- Генерируй свой, не бери чужой статичный.
- `<r N>` внутри I1 - N случайных байт **на каждое рукопожатие**: DPI не
  может запомнить сигнатуру. Статичный `I1 = <b 0x...>` (фиксированные байты)
  - слабее.
- Если I1 изображает TLS/QUIC с именем сайта (SNI) - для WARP бери **мировые
  сервисы** (например `update.microsoft.com`, `dl.google.com`,
  `connectivitycheck.gstatic.com`). Российский домен в SNI при трафике на
  иностранный адрес - заметный признак.
- Готовый генератор QUIC-пакета (из сообщества):
  https://sageptr.github.io/mini_quic_generator/ - вписать мировой домен,
  нажать генерацию, строку вставить в `I1`.
- Тег `<c>` - не используй (в старых версиях не работает, разработчики от
  него отказались). Теги `<d>`, `<ds>`, `<dz>` - не реализованы до конца, не
  используй.

### DNS в конфиге

Советы сообщества про DNS в конфиге (не ставить публичные `1.1.1.1`,
`8.8.8.8`, ставить DNS магистральных операторов) относятся к клиентам на
телефоне и ПК. **На шлюзе это не важно:** скрипты вырезают строку `DNS=`, DNS
идёт через dnsmasq и dnscrypt.

---

## Шаг 5.1 - Регистрация WARP (`wgcf`)

Каждая регистрация `wgcf` - отдельный аккаунт со своим ключом. Несколько
регистраций дают больше разнообразия. Как поставить `wgcf` - Часть 2,
Шаг 2.4. Новая регистрация - в отдельной папке:

```
mkdir -p ~/wgcf2 && cd ~/wgcf2 && ~/wgcf register
```

```
cd ~/wgcf2 && ~/wgcf generate
```

**ОЖИДАЕТСЯ:** `~/wgcf2/wgcf-profile.conf`.

---

## Шаг 5.2 - Сгенерировать партию (`warpgen3.py`)

`warpgen3.py` - скрипт владельца шлюза: на каждый конфиг генерирует свой I1
(структурно правильный QUIC v1 Initial >= 1200 байт со случайными DCID/SCID),
свои `Jc/Jmin/Jmax` и свой endpoint из списка `WARP_IPS`.

> ⛔ Если скрипта у тебя нет - возьми из своего бэкапа. **Не пиши его заново по
> памяти и не проси ИИ выдумать.** Без него можно собирать конфиги вручную
> (Шаг 5.3).

Из профиля `wgcf`:

```
python3 ~/warpgen3.py --wgcf ~/wgcf2/wgcf-profile.conf --count 6 --out ~/warp-configs
```

**ОЖИДАЕТСЯ:** таблица - имя, параметры I1, `Jc/Jmin/Jmax`, endpoint. Каждая
строка - отдельный `.conf` в `~/warp-configs`.

Параметры: `--count` - сколько конфигов, `--out` - куда, `--seed N` - та же
партия при повторе (обычно не нужно).

---

## Шаг 5.3 - Конфиг вручную (без генератора)

Шаблон (как в Части 2, Шаг 2.4), меняй только разрешённое:

```
[Interface]
PrivateKey = КЛЮЧ_ИЗ_wgcf-profile.conf
Address = 172.16.0.2/32
MTU = 1280
Jc = 6
Jmin = 40
Jmax = 133
S1 = 0
S2 = 0
H1 = 1
H2 = 2
H3 = 3
H4 = 4
I1 = СТРОКА_ИЗ_ГЕНЕРАТОРА

[Peer]
PublicKey = PublicKey_ИЗ_wgcf-profile.conf
AllowedIPs = 0.0.0.0/0
Endpoint = 162.159.195.1:1701
PersistentKeepalive = 25
```

`I1` можно не писать вовсе - тогда работает только мусор `Jc`.

---

## Шаг 5.4 - Проверить и положить в пул

⛔ **Не добавляй партию вслепую.** Сначала один конфиг.

Перенести конфиги в пул (если генерировал на шлюзе):

```
sudo cp ~/warp-configs/*.conf /etc/gateway/pool/
```

```
sudo chmod 600 /etc/gateway/pool/*.conf
```

Или по одному через панель: кнопка "Добавить конфиг в пул" (Часть 3).

Проверить один (на временном интерфейсе, боевые слоты не трогает):

```
sudo /usr/local/sbin/gw-warp-test.sh ИМЯ_ФАЙЛА.conf
```

**ОЖИДАЕТСЯ:** `РЕЗУЛЬТАТ: OK`, рукопожатие, пинг, скорость.

**ЕСЛИ `нет рукопожатия`** -> проверь ещё пару конфигов (другие endpoint).
Не встаёт ни один - ключ `wgcf` протух (новая регистрация, Шаг 5.1) или
endpoint-адреса в генераторе мертвы (Шаг 5.6).

Обновить список для панели:

```
sudo /usr/local/sbin/gw-pool-refresh-entities.sh
```

> Мёртвые конфиги в пуле не опасны: `warp-pick` проверяет каждый (пинг +
> мессенджеры) и пропускает нерабочие. Но чисти пул от стабильно мёртвых,
> чтобы не тратить на них попытки.

---

## Шаг 5.5 - Бенчмарк всего пула

Поднимает каждый конфиг на временном интерфейсе, качает 5 МБ, сортирует по
скорости. Боевые слоты не трогает.

```
sudo tee /usr/local/sbin/warp-bench.sh > /dev/null <<'EOF'
#!/bin/bash
# warp-bench.sh - скорость каждого конфига пула на временном интерфейсе wgbench.
# Боевые слоты (vpn-main/vpn-backup/vpn-amz) не трогает.
# Конфиг готовится так же, как в warp-pick: Table=off, без DNS/IPv6/Pre-PostUp,
# AllowedIPs только IPv4, keepalive 25.
# Результат: скорость_MBps|connect_ms|конфиг, лучшие сверху.
# Мёртвые: 0|9999|конфиг. Живые, но скорость не измерена (сервер замера отказал): 0|9998|конфиг.
# Пулы по умолчанию: /etc/warp/pool и /etc/gateway/pool (или POOL=папка).
set -u
export LC_ALL=C LC_NUMERIC=C
POOLS=${POOL:-"/etc/warp/pool /etc/gateway/pool"}
RESULTS=${RESULTS:-/etc/warp/bench-results}
TESTIF=wgbench
TMPCONF=/run/${TESTIF}.conf
TEST_URL="https://speed.cloudflare.com/__down?bytes=5000000"

say(){ echo "[warp-bench] $*"; logger -t warp-bench "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "запускай через sudo"; exit 1; }
exec 9>/run/warp-bench.lock; flock -n 9 || { say "уже запущен"; exit 0; }

cleanup(){ awg-quick down "$TMPCONF" >/dev/null 2>&1; ip link del "$TESTIF" 2>/dev/null; rm -f "$TMPCONF"; }
trap cleanup EXIT

prep(){
    awk '
        /^\[Interface\]/ { print; print "Table = off"; next }
        /^[[:space:]]*Table[[:space:]]*=/ { next }
        /^[[:space:]]*(PreUp|PostUp|PreDown|PostDown)[[:space:]]*=/ { next }
        /^[[:space:]]*PersistentKeepalive[[:space:]]*=/ { next }
        /^\[Peer\]/ { print; print "PersistentKeepalive = 25"; next }
        /^[[:space:]]*DNS[[:space:]]*=/ { next }
        /^[[:space:]]*Address[[:space:]]*=/ { sub(/,.*/,""); print; next }
        /^[[:space:]]*AllowedIPs[[:space:]]*=/ { print "AllowedIPs = 0.0.0.0/0"; next }
        { print }
    ' "$1" > "$TMPCONF"
    chmod 600 "$TMPCONF"
}

cfgs=()
for d in $POOLS; do for f in "$d"/*.conf; do [ -f "$f" ] && cfgs+=("$f"); done; done
[ "${#cfgs[@]}" -eq 0 ] && { say "пул пуст: $POOLS"; exit 1; }
say "старт: ${#cfgs[@]} конфигов на $TESTIF (боевые не трогаю)"

tmp=$(mktemp)
for cfg in "${cfgs[@]}"; do
    name=$(basename "$cfg")
    cleanup; sleep 2
    prep "$cfg"
    if ! err=$(awg-quick up "$TMPCONF" 2>&1); then
        say "  $name: awg-quick ошибка -> $(echo "$err" | grep -iE 'error|invalid|unable' | head -1)"
        echo "0|9999|$cfg" >> "$tmp"; continue
    fi
    ping -c2 -W2 -I "$TESTIF" 1.1.1.1 >/dev/null 2>&1   # пнуть рукопожатие
    hs=0
    for _ in $(seq 1 16); do
        h=$(awg show "$TESTIF" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
        [ -n "$h" ] && [ "$h" != "0" ] && { hs=1; break; }
        sleep 0.5
    done
    if [ "$hs" -eq 0 ]; then
        say "  $name: нет рукопожатия -> мёртв"; echo "0|9999|$cfg" >> "$tmp"; continue
    fi
    res=$(curl -s --max-time 20 --interface "$TESTIF" -o /dev/null -w '%{http_code}|%{speed_download}|%{time_connect}' "$TEST_URL" 2>/dev/null)
    code=$(echo "$res" | cut -d'|' -f1)
    bps=$(echo "$res" | cut -d'|' -f2 | tr ',' '.' | cut -d'.' -f1)
    cs=$(echo "$res" | cut -d'|' -f3 | tr ',' '.')
    mbps=$(awk "BEGIN{printf \"%.1f\", ${bps:-0}/1048576}")
    cms=$(awk "BEGIN{printf \"%.1f\", ${cs:-0}*1000}")
    if awk "BEGIN{exit !(${mbps:-0} > 0.1)}"; then
        say "  $name: ${mbps} MB/s, connect ${cms} ms"; echo "${mbps}|${cms}|$cfg" >> "$tmp"
    else
        if [ -n "$code" ] && [ "$code" != 000 ] && [ "$code" != 200 ]; then
            # туннель везёт, но сервер замера отказал (например, 429 - слишком часто)
            say "  $name: живой, сервер замера ответил HTTP $code - скорость не измерена"; echo "0|9998|$cfg" >> "$tmp"
        else
            say "  $name: рукопожатие есть, данные не идут -> мёртв"; echo "0|9999|$cfg" >> "$tmp"
        fi
    fi
done
sort -t'|' -k1 -rn "$tmp" > "$RESULTS"; rm -f "$tmp"
say "готово. Лидер: $(head -1 "$RESULTS")"
say "рейтинг: $RESULTS"
EOF
```

```
sudo chmod 755 /usr/local/sbin/warp-bench.sh
```

```
sudo /usr/local/sbin/warp-bench.sh 2>&1 | tee /tmp/warp-bench.log
```

**ОЖИДАЕТСЯ:** строка на каждый конфиг, в конце пять лучших.

---

## Шаг 5.6 - Найти живые адреса WARP (сканер)

Когда все конфиги разом без рукопожатия, а ключ свежий - вероятно, умерли
адреса endpoint. `CloudflareWarpSpeedTest` (проект сообщества) делает
настоящее рукопожатие к сотням адресов Cloudflare.

Скачай архив `linux-amd64` со страницы
https://github.com/peanut996/CloudflareWarpSpeedTest/releases (если GitHub на
шлюзе не открывается - скачай на ПК и перенеси `scp`). Распакуй и:

```
sudo install -m755 ~/CloudflareWarpSpeedTest /usr/local/sbin/CloudflareWarpSpeedTest
```

Пробный прогон на 300 адресов:

```
/usr/local/sbin/CloudflareWarpSpeedTest -n 200 -t 5 -c 300 -o /tmp/warp-scan.csv
```

**ОЖИДАЕТСЯ:** топ-10 по задержке и строка про запись в `/tmp/warp-scan.csv`
(формат `IP:Port,Loss,Latency`).

Живые адреса (0% потерь) используй в `Endpoint` новых конфигов или внеси в
`WARP_IPS` генератора. У владельца шлюза для этого есть свой скрипт
`update-warpgen-ips.py` (берёт из CSV живые с задержкой до 100 мс,
добавляет, мёртвые только показывает, делает бэкап генератора, отказывается
работать при подозрительно малом числе живых). ⛔ Нет скрипта - вноси руками,
не выдумывай его.

Гонять раз в несколько недель или когда бенчмарк показал, что живых в пуле
мало. Не по таймеру.

---

## Шаг 5.7 - Пересадить пул мимо Москвы (`warpscout` + `warp-reseat`)

**Зачем.** Узел Cloudflare, через который идёт туннель, определяется
**адресом точки входа** (`Endpoint`), а не ключом. Многие адреса ведут в
московский узел `DME`, а там трафик фильтрует DPI: конфиг живой, но
мессенджеры то есть, то нет, скорость низкая. Соседние адреса ведут, например,
в Стокгольм (`ARN`). Ключ и точка входа не связаны - любой конфиг можно
"пересадить" на хороший адрес.

Реальный замер (ноябрь 2026, один и тот же ключ):

| Точка входа | Мусор | Узел | Скорость |
|---|---|---|---|
| старая, порт 500 | свой | `DME` | 4.5 MB/s |
| стокгольмская, порт 2408 | свой | - | нет рукопожатия |
| стокгольмская, порт 500 | свой | `ARN` | 5.1 MB/s |
| стокгольмская, порт 2408 | от warpscout | `ARN` | 6-12 MB/s |

Выводы: **узел задаёт адрес, скорость - порт** (на 500 ТСПУ режет), а на 2408
нужен мусор, с которым warpscout сам проверил туннель. ⚠️ Страну для сайтов
это не меняет - Cloudflare всё равно показывает `RU`. От гео-блокировок
по-прежнему VPS (Часть 6).

Проверить, через какой узел идёт текущий `vpn-main`:

```
curl -s --interface vpn-main https://cloudflare.com/cdn-cgi/trace | grep -E '^(colo|loc)='
```

### 5.7.1 - Поставить warpscout

Сканер сообщества (https://github.com/vernette/warpscout, MIT). Работает без
root и без сетевых интерфейсов (туннель целиком в программе), маршрутизацию
шлюза не трогает. ⛔ Запускать **на шлюзе**: с клиента трафик к адресам
Cloudflare уходит в WARP, и сканер мерил бы WARP через WARP.

Версию возьми со страницы релизов (здесь - проверенная `0.16.1`):

```
sudo mkdir -p /opt/warpscout && cd /tmp && curl -fsSL -o ws.tgz https://github.com/vernette/warpscout/releases/download/v0.16.1/warpscout_0.16.1_linux_amd64.tar.gz && sudo tar xzf ws.tgz -C /opt/warpscout warpscout && sudo chmod 755 /opt/warpscout/warpscout && rm -f ws.tgz
```

Аккаунт WARP для сканера. Ключ создаётся на шлюзе, в Cloudflare уходит только
открытая часть; `-relay none` - не пускать регистрацию через чужой прокси:

```
cd /opt/warpscout && sudo ./warpscout register -relay none && sudo chmod 600 /opt/warpscout/warpscout-account.json
```

**ОЖИДАЕТСЯ:** `Registered fresh WARP account -> warpscout-account.json`.

Ручной скан (живая табличка на экране; отчёт пишет в файл):

```
cd /opt/warpscout && sudo ./warpscout scan -p awg -P -exclude-node DME -conf /tmp/warp-scout.conf
```

В отчёте `warpscout-report-*.txt` - точки входа, потери, узел. Ключей в нём
нет. ⛔ `/tmp/warp-scout.conf` и `warpscout-account.json` - с приватным
ключом, в чат не вставлять.

### 5.7.2 - Скрипт пересадки (`warp-reseat`)

Сканирует, для каждого конфига пула делает копию `<имя>-ws.conf` с новой
точкой входа и мусором из этого же скана, проверяет её `gw-warp-test`
(Часть 3) и оставляет только прошедшие: рукопожатие есть, узел не `DME`,
скорость не ниже 1 MB/s. Оригиналы не трогает. `warp-pick` (Часть 2) сначала
пробует копии `*-ws.conf`.

```
sudo tee /usr/local/sbin/warp-reseat.sh > /dev/null <<'EOF'
#!/bin/bash
# warp-reseat.sh - пересадка пула WARP на точки входа мимо Москвы (узел DME).
#  1) warpscout ищет точки входа, которые с нашей сети ведут не в DME;
#  2) каждому конфигу пула - копия <имя>-ws.conf: новая точка входа + мусор
#     (Jc/Jmin/Jmax/I1), с которым warpscout в ЭТОМ ЖЕ скане прошёл туннель;
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
            build "$src" "$dst.new" "$ep"   # .new не попадает под *.conf - warp-pick его не возьмёт
            out=$("$TEST" "$tname.new" 2>&1)
            colo=$(echo "$out" | awk -F'[:,] *' '/узел:/{print $2; exit}')
            mbps=$(echo "$out" | awk '/скорость:/{ if ($2 ~ /^[0-9.]+$/) print $2; else print 0; exit }')
            if echo "$out" | grep -q 'РЕЗУЛЬТАТ: OK' && [ -n "$colo" ] && [ "$colo" != "н/д" ] \
               && ! echo ",$AVOID_COLO," | grep -q ",$colo," \
               && awk -v s="${mbps:-0}" -v m="$MIN_MBPS" 'BEGIN{exit !(s >= m)}'; then
                mv -f "$dst.new" "$dst"   # подмена одним действием, только проверенного
                say "  $name: $ep -> узел $colo, $mbps MB/s"; done1=1; break
            fi
            say "  $name: $ep не прошёл (узел ${colo:-н/д}, ${mbps:-0} MB/s)"
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
EOF
```

```
sudo chmod 755 /usr/local/sbin/warp-reseat.sh
```

Сначала **обкатка**: копии ложатся в `/etc/warp/pool-test`, живой пул и
`warp-pick` их не видят (5-30 минут: скан + проверка каждой копии с загрузкой 5 МБ):

```
sudo /usr/local/sbin/warp-reseat.sh --test 2>&1 | tee /tmp/warp-reseat-test.log
```

```
sudo ls -l /etc/warp/pool-test
```

Обкатка прошла (копии есть, узел не `DME`, скорость нормальная) - боевой прогон,
копии ложатся в пул рядом с оригиналами:

```
sudo /usr/local/sbin/warp-reseat.sh 2>&1 | tee /tmp/warp-reseat.log
```

**ОЖИДАЕТСЯ:** `скан: N точек входа мимо DME`, строки `<имя>-ws.conf: адрес -> узел ARN, X MB/s`,
в конце `готово: пересажено N`. В пуле появились файлы `*-ws.conf`.

Раз в неделю сам (суббота 05:10, после ночного бэкапа и до утра):

```
sudo tee /etc/systemd/system/warp-reseat.service > /dev/null <<'EOF'
[Unit]
Description=WARP pool reseat past DME (warp-reseat)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/warp-reseat.sh
Nice=10
TimeoutStartSec=1h
EOF
```

```
sudo tee /etc/systemd/system/warp-reseat.timer > /dev/null <<'EOF'
[Unit]
Description=WARP pool reseat weekly

[Timer]
OnCalendar=Sat *-*-* 05:10:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
```

```
sudo systemctl daemon-reload && sudo systemctl enable --now warp-reseat.timer && systemctl list-timers warp-reseat.timer --no-pager
```

Перейти на пересаженный конфиг сразу, не дожидаясь ротации:

```
sudo systemctl start warp-rotate.service; journalctl -t warp-pick -n 15 --no-pager
```

**ОЖИДАЕТСЯ:** `попытка 1/5: <имя>-ws.conf`, `OK: ... узел ARN`, `ВЫБРАН`.

> Если скан перестал находить узлы мимо `DME` (Cloudflare поменял маршруты),
> `warp-reseat` пишет об этом и пул не трогает, а `warp-pick` работает по
> оригиналам, как раньше. Другой узел, которого надо избегать, - в
> `AVOID_COLO` обоих скриптов через запятую.

---

## Версии протокола AmneziaWG (справка)

| Версия | Что добавляет | Требует |
|---|---|---|
| 1.0 | `Jc/Jmin/Jmax`, `S1/S2`, фиксированные `H1-H4` | - |
| 1.5 | `I1-I5` (поддельные первые пакеты) | работают на стороне клиента |
| 2.0 | `S3/S4`, `H1-H4` диапазонами | обе стороны 2.0 |
| 3.0 | `HeaderProtectionKey` (шифрование заголовков), `ContentPaddingAddition`, случайные таймеры | обе стороны 3.0+ |
| 3.1 (27.08.2026) | защита от поведенческого анализа соединения, новое поведение `i1`, совет MTU 1376 -> 1280 при проблемах | обе стороны 3.1 |

**Для WARP** другая сторона - Cloudflare, она версию не поднимает. Пул WARP
по сути 1.5: `I1` работает, `H/S` фиксированы. Поднимать нечего.

**Для своего сервера** (Часть 6) обе стороны твои - используй 3.1. Правила
для своего сервера:
- обязаны совпадать у клиента и сервера: `S1-S4`, `H1-H4`,
  `HeaderProtectionKey`. Не совпало - пакеты молча выбрасываются, без ошибки
  в логе (поэтому всегда сначала смотри рукопожатие);
- могут и должны различаться между клиентами: `Jc/Jmin/Jmax`, `I1-I5`,
  `ContentPaddingAddition`;
- диапазоны `H1-H4` не пересекаются между собой и не заходят в `1-4`;
- `S1 + 56` не должно равняться `S2`.

Источники: [AmneziaWG 3.1](https://amnezia.org/blog/amneziawg-3-1-is-here),
FAQ проекта AmneziaWG-Architect (github.com/Vadim-Khristenko/AmneziaWG-Architect).
Протокол развивается быстро - перепроверяй.

---

## Частые вопросы

**Сгенерировал, рукопожатия нет.** Ключ протух - новая регистрация `wgcf`.
Или мёртвые адреса - Шаг 5.6.

**Поднять `Jc` до 200 для стойкости?** Нет. Умеренный `Jc` с `I1` работает
лучше.

**Поменять `H1-H4` для разнообразия?** Нет, никогда для WARP.

**Готовые конфиги из чатов - добавлять?** Можно, вреда нет: проверка их
отбракует. Но обычно у них статичный `I1`, а часть уже задушена. Свои
генераторные стойче.

**Как часто делать новую партию?** Когда `warp-pick` всё чаще перебирает
конфиги или бенчмарк показывает мало живых. Обычно раз в несколько
недель-месяцев.
