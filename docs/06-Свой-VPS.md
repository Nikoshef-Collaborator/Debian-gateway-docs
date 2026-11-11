# ЧАСТЬ 6 - Свой VPS: сервер AmneziaWG, туннели шлюза, профили "Чебурнет" и "Дом"

> **Зачем свой VPS.**
> 1. **Запасной выход** шлюза (`vpn-backup`), если WARP лёг.
> 2. **Чистый выход для ИИ-сервисов** (`vpn-amz`, полоса 0x200): OpenAI и
>    Anthropic отвечают 403 на адреса Cloudflare.
> 3. **Личный VPN** для телефона и ПК вне дома.
> 4. **"Чебурнет" и "Дом"** - из-за границы заходить на российские сервисы
>    (Госуслуги, банки, доски объявлений) с **домашнего** российского IP:
>    телефон -> VPS -> шлюз дома -> интернет.
>
> **Правила для ИИ - в Части 0.** Здесь особенно: всегда называй машину
> (**VPS** / **шлюз** / **ПК**). Приватные ключи, `PresharedKey`,
> `HeaderProtectionKey` и клиентские `.conf` - никогда в чат.
>
> ⚠️ **Статус раздела.** Схема и ключевые правила сняты с работающей системы
> (октябрь 2026). Полные файлы рабочего сервера в эту редакцию не снимались,
> поэтому скрипты добавления пира и обновления списка РФ здесь написаны по
> этой схеме заново. На новом сервере проходи каждую проверку. На уже
> работающем - сверяй со своими файлами, а не заменяй их.

---

## Схема

```
 Телефон/ПК (за границей)
     │  AmneziaWG, профиль "Чебурнет" или "Дом"
     ▼
   VPS  (Нидерланды и т.п.)  awg1, подсеть 10.78.0.0/24, VPS = 10.78.0.1
     │  метка 0x300 -> таблица 300 -> обратно в awg1, к пиру шлюза
     ▼
 ШЛЮЗ дома (vpn-backup = пир 10.78.0.6)
     │  NAT: 10.78.0.0/24 -> wan
     ▼
 интернет с ДОМАШНЕГО IP
```

| Профиль | Что уходит домой | Что идёт через VPS |
|---|---|---|
| обычный VPN | ничего | всё, **кроме** российских адресов (им отказ - чтобы РФ-сервисы не видели IP VPS) |
| Чебурнет | российские адреса | остальное |
| Дом | всё | ничего |

Пример плана адресов (у каждого устройства и профиля - **свой ключ и свой
адрес**):

| Адрес | Пир |
|---|---|
| 10.78.0.1 | сам VPS |
| 10.78.0.2-.3 | ПК, телефон (обычный VPN) |
| 10.78.0.4-.7 | шлюзы: `vpn-backup` и `vpn-amz` каждого |
| 10.78.0.8-.9 | ПК, телефон - "Чебурнет" |
| 10.78.0.10-.11 | телефон, ПК - "Дом" |

---

## Шаг 6.1 - VPS и базовая защита

Требования: 1 vCPU, 1-2 ГБ ОЗУ, Ubuntu LTS. Проверь до покупки на тестовом
периоде: доступен ли сервер из дома (SSH), не в блок-листах ли адрес.

> На тестовом сервере реальная ОС оказалась не той, что обещал тариф.
> Смотри сам: `cat /etc/os-release`.

> ⚠️ **Проверь сеть адреса до покупки.** ТСПУ замораживает TCP-соединения
> (после ~16 КБ) к сетям ряда зарубежных хостингов. На ноябрь 2026 по
> замерам одного автора (Хабр, 6.11.2026) это Hetzner, OVH, DigitalOcean,
> M247, HostPapa и сети, которые у них арендуют; проходят, например, HostHatch
> и FlokiNET. Список меняется. Важна **сеть (AS)**, а не название хостинга:
> `whois IP_VPS | grep -i origin`. Туннели по UDP (AmneziaWG) это пока не
> затрагивает, а HTTPS-сайт и Immich на VPS (Часть 7) - затрагивает. Проверка на
> пробном периоде: из России **без VPN** (телефон на Wi-Fi терминала провайдера,
> мимо шлюза) скачать с VPS файл на несколько МБ - если встаёт на ~16 КБ, сеть
> заморожена. Держи запасной сервер в сети другой компании.

**На VPS** (через консоль хостера или SSH):

```
apt update && apt full-upgrade -y
```

SSH только по ключу - сначала положи свой ключ (как в Части 2, Шаг 2.16, но
пользователь `root` или свой), **проверь вход по ключу в новом окне**, потом:

```
tee /etc/ssh/sshd_config.d/hardening.conf > /dev/null <<'EOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
EOF
```

```
systemctl restart ssh
```

> Пароль root от хостера в чат не присылай. После переустановки ОС из панели
> хостера пароль сбрасывается - меняй сразу.

---

## Шаг 6.2 - AmneziaWG на VPS (Ubuntu)

По [официальной инструкции](https://docs.amnezia.org/documentation/instructions/install-amneziawg-kernel-module-linux),
**на VPS**:

```
apt install -y software-properties-common python3-launchpadlib gnupg2 linux-headers-$(uname -r)
```

```
add-apt-repository -y ppa:amnezia/ppa
```

```
apt install -y amneziawg qrencode
```

```
modinfo amneziawg | grep -E '^(filename|version)'
```

**ОЖИДАЕТСЯ:** путь и версия модуля.

**ЕСЛИ `Module amneziawg not found`** -> DKMS не собрал модуль под ядро. На
очень новых ядрах это бывает - ищи решение в issues репозитория
`amnezia-vpn/amneziawg-linux-kernel-module`. Не выдумывай патчи.

Пересылка пакетов:

```
tee /etc/sysctl.d/99-awg.conf > /dev/null <<'EOF'
net.ipv4.ip_forward=1
EOF
```

```
sysctl --system
```

---

## Шаг 6.3 - Ключи и конфиг сервера `awg1`

Имя внешнего интерфейса VPS:

```
ip -br route get 1.1.1.1
```

**ОЖИДАЕТСЯ:** после `dev` имя, например `eth0`. Дальше в тексте `eth0` - если
у тебя иначе, подставь своё.

Ключи сервера:

```
umask 077 && mkdir -p /etc/amnezia/amneziawg && cd /etc/amnezia/amneziawg && awg genkey | tee server.key | awg pubkey > server.pub
```

Конфиг. Порт - любой свободный UDP (пример `51820`). ⛔ Заполни через
`nano`: `PrivateKey` - содержимое `server.key`.

```
tee /etc/amnezia/amneziawg/awg1.conf > /dev/null <<'EOF'
[Interface]
PrivateKey = ПОДСТАВЬ_СОДЕРЖИМОЕ_server.key
Address = 10.78.0.1/24
ListenPort = 51820
# --- маскировка (обязаны совпадать у сервера и клиентов: S1-S4, H1-H4, HeaderProtectionKey) ---
Jc = 4
Jmin = 20
Jmax = 60
S1 = 33
S2 = 71
S3 = 23
S4 = 16
H1 = 1
H2 = 2
H3 = 3
H4 = 4
# --- политика "Чебурнет"/"Дом": метка 0x300 -> таблица 300 -> к пиру шлюза ---
PostUp = ip rule add fwmark 0x300 lookup 300 priority 5300
PostUp = ip route replace default dev %i table 300
PostDown = ip rule del fwmark 0x300 lookup 300 priority 5300
EOF
```

```
chmod 600 /etc/amnezia/amneziawg/awg1.conf
```

> **Параметры маскировки.** Значения выше - только пример. ⛔ **Придумай
> свои** и не копируй чужие из интернета: одинаковые `Jc/S1-S4` у многих
> серверов упрощают их распознавание. Правила - Части 5 ("Версии протокола"): `S1 + 56 != S2`, диапазоны
> `H1-H4` не пересекаются и не заходят в `1-4` (кроме варианта ровно
> `1/2/3/4`). Для протокола 3.x добавляются `HeaderProtectionKey`,
> `ContentPaddingAddition`, случайные таймеры и др. - бери их из
> документации своей версии AmneziaWG. Скрипт добавления пира (6.6) копирует
> в клиентские конфиги все такие строки из `[Interface]` сервера, так что
> они всегда совпадут.

---

## Шаг 6.4 - Firewall VPS (nftables)

⚠️ **Главная грабля VPS.** Файл `/etc/nftables.conf` начинается с
`flush ruleset`. При загрузке это нормально (Tailscale создаёт свои правила
позже). Но **применение всего файла на живом сервере** (`nft -f
/etc/nftables.conf` или `systemctl restart nftables`) **стирает правила
Tailscale** - пропадает доступ по Tailscale. На работающем сервере правки
вноси **двумя способами сразу**: живой командой `nft add/insert` и той же
строкой в файл.

**Первая настройка на новом сервере** (Tailscale ещё не стоит). Строки для
AdGuard Home, Tailscale и сайта безвредны, пока этих служб нет; ⛔ кроме
`dnat` на AdGuard Home - см. комментарий в файле. Сначала папка для
сохранённого списка `ru4` (Шаг 6.5):

```
mkdir -p /etc/nftables.d
```

Сам файл:

```
tee /etc/nftables.conf > /dev/null <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

# Имя сетевой карты в интернет (Шаг 6.3: ip route show default -> после dev)
define WAN_IF = "eth0"
define VPN_IF = { "awg1" }
define VPN_NET = 10.78.0.0/24
# Порт tailscaled (PORT в /etc/default/tailscaled)
define TS_PORT = 41641

table inet filter {
    # российские сети (наполняет ru-block-update.sh, Шаг 6.5)
    set ru4 {
        type ipv4_addr
        flags interval
        auto-merge
    }

    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        ct state invalid drop
        iif "lo" accept
        # адреса Tailscale принимаем только с его интерфейса (защита от подмены)
        ip saddr 100.64.0.0/10 iifname != "tailscale0" drop
        meta l4proto icmp accept
        meta l4proto ipv6-icmp accept
        # DHCP от хостера (адрес VPS выдаётся по DHCP)
        udp sport 67 udp dport 68 accept
        udp sport 547 udp dport 546 accept
        # SSH - только из туннеля и из Tailscale
        iifname $VPN_IF tcp dport 22 accept
        iifname "tailscale0" tcp dport 22 accept
        tcp dport 22 accept             # ⛔ временно: убрать после проверки SSH по туннелю
        udp dport 51820 accept          # AmneziaWG - порт из ListenPort (Шаг 6.3)
        # AdGuard Home: DNS только для клиентов туннеля, панель только из Tailscale
        iifname "awg1" meta l4proto { tcp, udp } th dport 53 accept
        iifname "tailscale0" tcp dport 3000 accept
        # сайт (Caddy, Часть 7): HTTP, HTTPS, HTTP/3
        tcp dport { 80, 443 } accept
        udp dport 443 accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        tcp flags syn tcp option maxseg size set rt mtu
        ct state established,related accept
        ct state invalid drop
        # ПК и телефон (.2/.3) -> SSH к шлюзам по их адресам в туннеле (запасной вход)
        iifname "awg1" oifname "awg1" ip saddr { 10.78.0.2, 10.78.0.3 } ip daddr { 10.78.0.6 } tcp dport 22 accept
        # Чебурнет (.8/.9): российские адреса - домой через шлюз
        iifname "awg1" oifname "awg1" ip saddr { 10.78.0.8, 10.78.0.9 } ip daddr @ru4 accept
        # Дом (.10/.11): весь трафик домой
        iifname "awg1" oifname "awg1" ip saddr { 10.78.0.10, 10.78.0.11 } accept
        # остальным клиентам российские адреса запрещены: РФ-приложения не
        # должны видеть IP VPS. Отказ сразу (reset), а не молчание - приложение
        # не висит на таймауте
        iifname $VPN_IF ip daddr @ru4 meta l4proto tcp counter reject with tcp reset
        iifname $VPN_IF ip daddr @ru4 counter reject with icmpx type admin-prohibited
        # не даём клиентам обойти свой DNS через DNS-over-TLS (Android "Частный DNS")
        iifname $VPN_IF tcp dport 853 counter reject with tcp reset
        iifname $VPN_IF udp dport 853 counter reject with icmpx type admin-prohibited
        # выход в интернет
        iifname $VPN_IF oifname $WAN_IF accept
    }

    # метка для профилей "Чебурнет" и "Дом" -> таблица 300 -> пир шлюза
    chain ru_home {
        type filter hook prerouting priority mangle; policy accept;
        iifname "awg1" ip saddr { 10.78.0.8, 10.78.0.9 } ip daddr @ru4 meta mark set 0x300
        iifname "awg1" ip saddr { 10.78.0.10, 10.78.0.11 } meta mark set 0x300
    }

    chain output {
        type filter hook output priority 0; policy accept;
        # Tailscale: никакого прямого WireGuard с российскими адресами, только
        # через релей (DERP) - IP сервера не светится из России как WireGuard
        udp sport $TS_PORT ip daddr @ru4 counter drop
    }
}

table ip nat {
    # Любой DNS-запрос клиента туннеля (на 1.1.1.1 и куда угодно) -> AdGuard Home.
    # ⛔ Только если AdGuard Home стоит и слушает 10.78.0.1:53 - иначе у клиентов
    # пропадёт DNS. Без AdGuard Home этот chain удали.
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname "awg1" meta l4proto { tcp, udp } th dport 53 counter dnat to 10.78.0.1
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr $VPN_NET oifname $WAN_IF masquerade
    }
}

# сохранённый список ru4 (пишет ru-block-update.sh) - после перезагрузки
# набор сразу полный, не ждёт обновления
include "/etc/nftables.d/*.nft"
EOF
```

```
nft -c -f /etc/nftables.conf && echo "СИНТАКСИС OK"
```

⛔ **СТОП:** держи открытой текущую SSH-сессию. Применить:

```
systemctl enable --now nftables
```

```
systemctl restart nftables
```

Проверь вход по SSH в **новом** окне. Не входит - консоль хостера,
`nft flush ruleset`, ищи ошибку.

> Строку `tcp dport 22 accept` (с пометкой ⛔) убери, когда убедишься, что SSH работает по
> туннелю (`ssh root@10.78.0.1` с подключённого клиента) или по Tailscale.
> Публичный порт 22 сканируют постоянно. Запасной вход - консоль в панели
> хостера.

---

## Шаг 6.5 - Список российских подсетей на VPS (`ru4`)

```
tee /usr/local/sbin/ru-block-update.sh > /dev/null <<'EOF'
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
EOF
```

```
chmod 755 /usr/local/sbin/ru-block-update.sh
```

```
/usr/local/sbin/ru-block-update.sh
```

**ОЖИДАЕТСЯ:** `ru-block: загружено N сетей (было 0)` (тысячи). Любая строка
"ничего не меняю" - защита сработала, набор остался прежним; причина - в той
же строке.

Обновление раз в неделю. После перезагрузки набор берётся из сохранённого
`/etc/nftables.d/ru4.nft`, ждать обновления не нужно:

```
tee /etc/systemd/system/ru-block-update.service > /dev/null <<'EOF'
[Unit]
Description=Update nft set ru4 (Russian IP ranges)
Wants=network-online.target
After=network-online.target nftables.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ru-block-update.sh
EOF
```

```
tee /etc/systemd/system/ru-block-update.timer > /dev/null <<'EOF'
[Unit]
Description=Weekly update of Russian IP ranges for nft set ru4

[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
```

```
systemctl daemon-reload && systemctl enable --now ru-block-update.timer
```

> Проверка "напрямую/домой" сайтом 2ip.ru не годится: он хостится вне РФ и в
> `ru4` не попадает. Проверяй по `ip.mail.ru` (российский адрес).

---

## Шаг 6.6 - Пиры: скрипт добавления и `awg-who`

Скрипт создаёт ключи клиента, **добавляет пир на живой интерфейс** (без
перезапуска - остальные клиенты не рвутся), дописывает его в `awg1.conf` и
кладёт клиентский конфиг в `/root/awg1-ИМЯ.conf`.

```
tee /usr/local/sbin/awg1-add-peer.sh > /dev/null <<'EOF'
#!/bin/bash
# awg1-add-peer.sh <имя> <адрес 10.78.0.N> <endpoint IP:порт VPS>
set -eu
NAME="$1"; ADDR="$2"; EP="$3"
CONF=/etc/amnezia/amneziawg/awg1.conf
OUT="/root/awg1-${NAME}.conf"
grep -q "AllowedIPs = ${ADDR}/32" "$CONF" && { echo "адрес $ADDR уже занят"; exit 1; }
umask 077
PRIV=$(awg genkey); PUB=$(echo "$PRIV" | awg pubkey); PSK=$(awg genpsk)
# 1. на живой интерфейс
awg set awg1 peer "$PUB" preshared-key <(echo "$PSK") allowed-ips "${ADDR}/32"
# 2. в конфиг сервера (строка "# имя" перед пиром нужна awg-who)
cat >> "$CONF" <<P

# ${NAME}
[Peer]
PublicKey = ${PUB}
PresharedKey = ${PSK}
AllowedIPs = ${ADDR}/32
P
# 3. клиентский конфиг: маскировка копируется из [Interface] сервера
{
  echo "[Interface]"
  echo "PrivateKey = ${PRIV}"
  echo "Address = ${ADDR}/32"
  echo "DNS = 1.1.1.1"
  echo "MTU = 1376"
  sed -n '/^\[Interface\]/,/^\[Peer\]/p' "$CONF" | grep -E '^[[:space:]]*(Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5]|HeaderProtectionKey|ContentPaddingAddition|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts|RandomTrailers|DisableCookies)[[:space:]]*='
  echo
  echo "[Peer]"
  echo "PublicKey = $(awg show awg1 public-key)"
  echo "PresharedKey = ${PSK}"
  echo "AllowedIPs = 0.0.0.0/0"
  echo "Endpoint = ${EP}"
  echo "PersistentKeepalive = 25"
} > "$OUT"
chmod 600 "$OUT"
echo "Пир ${NAME} (${ADDR}) добавлен. Клиентский конфиг: ${OUT}"
echo "После импорта на устройство - УДАЛИ этот файл."
EOF
```

```
chmod 700 /usr/local/sbin/awg1-add-peer.sh
```

Кто есть кто и когда подключался:

```
tee /usr/local/sbin/awg-who > /dev/null <<'EOF'
#!/bin/bash
# awg-who - имя, адрес, откуда и когда было рукопожатие у каждого пира awg1
awk -v now=$(date +%s) 'NR==FNR{ if($0~/^# /) n=substr($0,3); if($1=="PublicKey") m[$3]=n; next } FNR>1{ hs=($5==0)?"не подключался":int((now-$5)/60)" мин назад"; printf "%-16s %-26s %-24s %s\n", m[$1], $4, $3, hs }' /etc/amnezia/amneziawg/awg1.conf <(awg show awg1 dump)
EOF
```

```
chmod 755 /usr/local/sbin/awg-who
```

Запуск сервера:

```
systemctl enable --now awg-quick@awg1
```

```
awg show awg1 | head -5
```

**ОЖИДАЕТСЯ:** `interface: awg1`, `listening port: 51820`.

> Свой ПК/телефон и шлюзы - отдельные пиры. **Один ключ - одно устройство и
> один профиль.** Тариф хостинга может ограничивать число устройств - удаляй
> неиспользуемых пиров (`awg set awg1 peer КЛЮЧ remove` + удалить блок из
> `awg1.conf`).

---

## Шаг 6.7 - Пиры для шлюза (`vpn-backup` и `vpn-amz`)

**На VPS** (⛔ подставь внешний IP VPS):

```
/usr/local/sbin/awg1-add-peer.sh gw-backup 10.78.0.6 ПОДСТАВЬ_IP_VPS:51820
```

```
/usr/local/sbin/awg1-add-peer.sh gw-amz 10.78.0.7 ПОДСТАВЬ_IP_VPS:51820
```

Пиру `vpn-backup` нужен ещё и путь "домой" для Чебурнета/Дома: этому пиру
разрешаем `0.0.0.0/0`. В `awg1.conf` это делать **нельзя** (awg-quick
навесил бы маршрут на весь интернет), поэтому - строкой `PostUp`. ⛔ Ключ -
`PublicKey` пира `gw-backup` из `awg1.conf`:

```
grep -A2 '^# gw-backup' /etc/amnezia/amneziawg/awg1.conf
```

Открой `nano /etc/amnezia/amneziawg/awg1.conf` и после строк `PostUp` добавь
(ключ подставь):

```
PostUp = awg set %i peer ПОДСТАВЬ_PUBLICKEY_gw-backup allowed-ips 10.78.0.6/32,0.0.0.0/0
```

Применить на живом интерфейсе той же командой (с `awg1` вместо `%i`):

```
awg set awg1 peer ПОДСТАВЬ_PUBLICKEY_gw-backup allowed-ips 10.78.0.6/32,0.0.0.0/0
```

**Перенести конфиги на шлюз** (на **ПК**, PowerShell; адрес VPS - по Tailscale
или публичный, как настроен SSH):

```
scp root@АДРЕС_VPS:/root/awg1-gw-backup.conf $HOME\Downloads\vpn-backup.conf
```

```
scp root@АДРЕС_VPS:/root/awg1-gw-amz.conf $HOME\Downloads\vpn-amz.conf
```

```
scp $HOME\Downloads\vpn-backup.conf $HOME\Downloads\vpn-amz.conf user@АДРЕС_ШЛЮЗА:/tmp/
```

**На шлюзе:**

```
sudo mv /tmp/vpn-backup.conf /tmp/vpn-amz.conf /etc/gateway/tunnels/
```

```
sudo nano /etc/gateway/tunnels/vpn-backup.conf
```

В `[Interface]` добавь `Table = off`, удали строку `DNS`. Сохрани.

```
sudo nano /etc/gateway/tunnels/vpn-amz.conf
```

В `[Interface]` добавь `Table = 200`, удали строку `DNS`. Сохрани.

Дальше - Часть 2, Шаг 2.13 (проверки и запуск слотов).

**Убрать временные копии ключей:**
- на ПК: `Remove-Item $HOME\Downloads\vpn-backup.conf, $HOME\Downloads\vpn-amz.conf`
- на VPS: `rm /root/awg1-gw-backup.conf /root/awg1-gw-amz.conf`

**ПРОВЕРКА на VPS:**

```
awg-who
```

**ОЖИДАЕТСЯ:** `gw-backup` и `gw-amz` с рукопожатием "N мин назад".

---

## Шаг 6.8 - Личные профили: VPN, Чебурнет, Дом

**На VPS**, по пиру на устройство и профиль (⛔ IP VPS подставь):

```
/usr/local/sbin/awg1-add-peer.sh phone-vpn 10.78.0.3 ПОДСТАВЬ_IP_VPS:51820
```

```
/usr/local/sbin/awg1-add-peer.sh phone-cheburnet 10.78.0.9 ПОДСТАВЬ_IP_VPS:51820
```

```
/usr/local/sbin/awg1-add-peer.sh phone-dom 10.78.0.10 ПОДСТАВЬ_IP_VPS:51820
```

Адреса `.8-.11` должны совпадать с правилами `forward` и `ru_home` (Шаг 6.4).
Взял другие - поправь правила.

**Импорт на телефон** - QR-код прямо в терминале VPS:

```
qrencode -t ansiutf8 < /root/awg1-phone-dom.conf
```

В приложении AmneziaVPN: "Добавить" -> "QR-код", назови профиль понятно
("Дом"). Повтори для каждого профиля.

**На ПК** - файл через `scp` (как в 6.7), импорт в AmneziaVPN, затем удалить
файл из Downloads.

**Удалить клиентские конфиги с VPS** после импорта:

```
rm /root/awg1-phone-*.conf
```

> В этих файлах приватный ключ. Кто получит файл - подключится как ты, а с
> профилем "Дом" будет выходить в интернет с твоего домашнего IP. Нужна
> копия - менеджер паролей, не Downloads и не `/root`.

### Проверка профилей (на телефоне, в браузере)

| Профиль | `ip.mail.ru` | `ifconfig.me` |
|---|---|---|
| VPN | не откроется (российский адрес запрещён) | IP VPS |
| Чебурнет | **домашний IP** | IP VPS |
| Дом | **домашний IP** | **домашний IP** |

**На VPS** - какой профиль реально подключён:

```
awg-who
```

**ЕСЛИ результат не тот** -> почти всегда на устройстве включён не тот
профиль или импортирован старый конфиг. `awg-who` покажет, у какого пира
свежее рукопожатие.

Счётчики правил (растут = трафик идёт домой):

```
nft list chain inet filter ru_home
```

---

## Шаг 6.9 - Tailscale на VPS (запасной SSH)

```
curl -fsSL https://tailscale.com/install.sh | sh
```

```
tailscale up
```

Теперь SSH к VPS есть и по Tailscale, и по туннелю (`10.78.0.1`), даже если
один из них сломан.

⚠️ После этого **никогда** не применяй `/etc/nftables.conf` целиком на живом
сервере (Шаг 6.4).

---

## Шаг 6.10 - Устойчивость VPS: обновления, ядро, бэкап, подкачка

### 6.10.1 - Автообновления безопасности (ядро - отдельно)

⚠️ **Реальный случай:** в образе хостера таймеры автообновлений были
**замаскированы** - за две недели не поставилось ни одного исправления
безопасности (OpenSSH, systemd, curl, zlib...). Проверь (на **VPS**):

```
systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer
```

`masked` или `disabled` - обновления не идут.

⛔ **Сначала закрепи ядро.** Модуль AmneziaWG собирается под конкретное ядро
(DKMS). Если автообновление поставит новое ядро без заголовков, после
перезагрузки модуля не будет - VPN ляжет у всех. Ядро обновляем вручную
(6.10.2).

Какой метапакет ядра стоит:

```
dpkg -l 'linux-image-*' 'linux-generic*' | awk '/^ii/{print $2}' | grep -vE '[0-9]'
```

**ОЖИДАЕТСЯ:** `linux-image-virtual` или `linux-image-generic`. ⛔ Подставь своё:

```
apt-mark hold linux-image-virtual
```

```
apt-mark showhold
```

Остальные обновления - вручную один раз:

```
apt update
```

```
apt upgrade -y 2>&1 | tee /root/upgrade.log
```

```
systemctl --failed --no-legend
```

Включить автообновления:

```
systemctl unmask apt-daily.timer apt-daily-upgrade.timer
```

```
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
```

Пробный прогон (ничего не ставит):

```
unattended-upgrade --dry-run --debug 2>&1 | tail -15
```

**ОЖИДАЕТСЯ:** для ядра строка `adjusting candidate to version ...` с
**текущей** версией - закреплённое ядро не трогается. Сторонние репозитории
(Tailscale, Caddy, Amnezia) по умолчанию тоже не обновляются автоматически -
их обновляй руками раз в месяц.

> Если `ls /var/run/reboot-required` показывает файл - нужна перезагрузка.
> Делай её ночью (6.10.2, последний блок): VPN у всех пропадёт на минуту.

### 6.10.2 - Обновление ядра вручную (с проверкой модуля ДО перезагрузки)

Раз в 1-2 месяца или когда в `apt list --upgradable` появилось новое ядро.
⛔ Подставь номер нового ядра из этого списка (пример - `7.0.0-42`):

```
apt-mark unhold linux-image-virtual
```

```
apt install -y linux-image-virtual linux-headers-7.0.0-42-generic 2>&1 | tee /root/kernel.log
```

Главная проверка - модуль собран под новое ядро:

```
dkms status
```

```
modinfo -k 7.0.0-42-generic amneziawg | grep -E '^(filename|version)'
```

**ОЖИДАЕТСЯ:** `amneziawg/... 7.0.0-42-generic ... installed` и путь в
`/lib/modules/7.0.0-42-generic/`.

⛔ **ЕСЛИ модуля под новое ядро нет - НЕ перезагружайся.** Пришли помощнику
`tail -40 /root/kernel.log`. Старое ядро остаётся основным, пока VPS не
перезагрузится.

Если собрался - снова закрепить и перезагрузить ночью по таймеру (время
VPS обычно в UTC: 04:00 МСК = 01:00 UTC, ⛔ дату подставь):

```
apt-mark hold linux-image-virtual
```

```
systemd-run --on-calendar="2026-10-29 01:00:00 UTC" /bin/systemctl reboot
```

Утром:

```
uname -r; systemctl --failed --no-legend; systemctl is-active awg-quick@awg1 caddy tailscaled
```

> Старое ядро и его модуль остаются в системе. Если с новым что-то не так -
> в консоли хостера при загрузке выбрать предыдущее ядро.

### 6.10.3 - Бэкап VPS на шлюз (раз в неделю, автоматически)

⚠️ Хостер может заменить сломанный сервер новым - **с другим IP и пустым
диском**, переустановка ОС тоже стирает всё. Без копии ключа сервера
AmneziaWG придётся перевыпускать конфиги всем: телефонам, ПК, шлюзам.
Копии **на самом VPS** не спасают.

Схема: шлюз забирает архив по отдельному ключу. На VPS этот ключ умеет
**только одно** - отдать архив (`restrict,command=`), без консоли, и только с
адресов шлюза.

**На шлюзе** - ключ:

```
sudo ssh-keygen -t ed25519 -f /root/.ssh/vps_backup -N "" -C "gw-vps-backup"
```

```
sudo cat /root/.ssh/vps_backup.pub
```

Скопируй строку (публичный ключ, не секрет).

**На VPS** - скрипт выдачи архива:

```
cat > /usr/local/sbin/vps-backup-dump.sh <<'EOF'
#!/bin/bash
# vps-backup-dump.sh - выдаёт в stdout tar.gz с конфигурацией VPS.
# Вызывается ТОЛЬКО через ключ бэкапа (command= в authorized_keys).
# Внутри есть приватные ключи AmneziaWG - архив хранить с правами 600.
set -u
cd /
LIST=""
for p in etc/amnezia etc/nftables.conf etc/nftables-cve.nft etc/caddy var/www usr/local/sbin \
         etc/systemd/system etc/sysctl.d etc/ssh/sshd_config.d \
         etc/systemd/journald.conf.d etc/apt/apt.conf.d opt/AdGuardHome \
         root/.ssh/authorized_keys etc/hostname etc/netplan; do
    [ -e "$p" ] && LIST="$LIST $p"
done
# shellcheck disable=SC2086
tar czf - --exclude='opt/AdGuardHome/data/querylog*' --exclude='opt/AdGuardHome/data/stats.db' $LIST 2>/dev/null
EOF
```

```
chmod 700 /usr/local/sbin/vps-backup-dump.sh
```

Разрешить ключ только для этого скрипта - **в два приёма**, чтобы длинная
строка не обрезалась при вставке. ⛔ В `from=` - адреса шлюза в туннеле и его
Tailscale-адрес:

```
printf 'restrict,command="/usr/local/sbin/vps-backup-dump.sh",from="10.78.0.6,10.78.0.7,ПОДСТАВЬ_TS_ШЛЮЗА" ' >> /root/.ssh/authorized_keys
```

⛔ Вместо `ВСТАВЬ_КЛЮЧ` - строка с ключом целиком, начиная с `ssh-ed25519`:

```
echo 'ВСТАВЬ_КЛЮЧ' >> /root/.ssh/authorized_keys
```

```
tail -1 /root/.ssh/authorized_keys | awk '{print $1; print $2}' | cut -c1-60
```

**ОЖИДАЕТСЯ:** `restrict,command=...` и `ssh-ed25519`. Иначе удали строку
(`sed -i '$d' /root/.ssh/authorized_keys`) и повтори.

**На шлюзе** - принять ключ хоста VPS по обоим адресам (⛔ подставь
Tailscale-адрес VPS):

```
sudo ssh -i /root/.ssh/vps_backup -o StrictHostKeyChecking=accept-new root@10.78.0.1 > /dev/null; echo "код: $?"
```

```
sudo ssh -i /root/.ssh/vps_backup -o StrictHostKeyChecking=accept-new root@ПОДСТАВЬ_TS_VPS > /dev/null; echo "код: $?"
```

**ОЖИДАЕТСЯ:** `PTY allocation request failed` и `код: 0` - консоль ключу
недоступна (так и задумано), архив отдан.

**На шлюзе** - скрипт, который забирает архив (⛔ в `HOSTS` подставь
Tailscale-адрес VPS):

```
sudo tee /usr/local/sbin/vps-backup-pull.sh > /dev/null <<'EOF'
#!/bin/bash
# vps-backup-pull.sh - забирает бэкап конфигурации VPS на шлюз.
# Ключ /root/.ssh/vps_backup на VPS ограничен: умеет только отдать архив.
# Сначала через туннель AmneziaWG, при неудаче - через Tailscale.
set -u
HOSTS="10.78.0.1 ПОДСТАВЬ_TS_VPS"
KEY=/root/.ssh/vps_backup
DIR=/var/backups/vps
KEEP=8
LOG=/var/log/vps-backup.log
log(){ echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
tg(){ [ -x /usr/local/sbin/tg-notify.sh ] && /usr/local/sbin/tg-notify.sh "Бэкап VPS" "$1" "$2"; }
mkdir -p "$DIR"; chmod 700 "$DIR"
umask 077
OUT="$DIR/vps-$(date +%F_%H%M).tar.gz"
ok=0
for h in $HOSTS; do
    if ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=yes "root@$h" > "$OUT.part" 2>>"$LOG" \
       && [ -s "$OUT.part" ] && gzip -t "$OUT.part" 2>/dev/null; then
        ok=1; log "получен через $h"; break
    fi
    log "через $h не вышло"
done
if [ "$ok" -ne 1 ]; then
    rm -f "$OUT.part"; log "ОШИБКА: бэкап VPS не получен"
    tg "ОШИБКА: бэкап VPS не получен (лог $LOG)" warn; exit 1
fi
mv "$OUT.part" "$OUT"
grep -q 'etc/amnezia/amneziawg/awg1.conf' <(tar tzf "$OUT") || { log "ОШИБКА: в архиве нет awg1.conf"; tg "ОШИБКА: в бэкапе VPS нет awg1.conf" warn; exit 1; }
ls -1t "$DIR"/vps-*.tar.gz | tail -n +$((KEEP+1)) | xargs -r rm -f
log "готово: $(basename "$OUT"), $(du -h "$OUT" | cut -f1), хранится $(ls -1 "$DIR"/vps-*.tar.gz | wc -l)"
exit 0
EOF
```

```
sudo chmod 700 /usr/local/sbin/vps-backup-pull.sh
```

```
sudo /usr/local/sbin/vps-backup-pull.sh
```

**ОЖИДАЕТСЯ:** `получен через 10.78.0.1` и `готово: vps-...tar.gz`.

```
sudo bash -c 'tar tzf $(ls -1t /var/backups/vps/vps-*.tar.gz | head -1) | grep -E "awg1.conf$|nftables.conf|Caddyfile"'
```

Расписание - воскресенье 05:30, хранится 8 последних (два месяца):

```
sudo tee /etc/systemd/system/vps-backup.service > /dev/null <<'EOF'
[Unit]
Description=Pull VPS config backup to gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-backup-pull.sh
EOF
```

```
sudo tee /etc/systemd/system/vps-backup.timer > /dev/null <<'EOF'
[Unit]
Description=Weekly VPS config backup (Sun 05:30)

[Timer]
OnCalendar=Sun *-*-* 05:30:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
```

```
sudo systemctl daemon-reload
```

```
sudo systemctl enable --now vps-backup.timer
```

После серьёзной правки на VPS (новый пир, правила) - запусти
`sudo /usr/local/sbin/vps-backup-pull.sh` сразу.

**Восстановление на новый VPS:** поставь систему и пакеты (6.1, 6.2, Caddy,
Tailscale), затем распакуй нужные файлы из архива **по одному**, сверяя имя
сетевого интерфейса в `nftables.conf` (на новом сервере оно может быть
другим). Ключ сервера в `awg1.conf` прежний - у клиентов меняется только
адрес сервера (`Endpoint`). Если в `Endpoint` у клиентов стоит **имя**
(например, `vpn.example.com`), хватит поменять A-запись в DNS.

> Старые архивы, которые лежат на самом VPS (`/root/*backup*`), закрой:
> `chmod 600 /root/*backup*.tar.gz` - внутри ключи.

### 6.10.4 - Подкачка (страховка от нехватки памяти)

На 1-2 ГБ ОЗУ - 1 ГБ подкачки, используется только в крайнем случае:

```
fallocate -l 1G /swapfile
```

```
chmod 600 /swapfile
```

```
mkswap /swapfile
```

```
swapon /swapfile
```

```
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

```
echo 'vm.swappiness=10' > /etc/sysctl.d/90-swap.conf
```

```
sysctl -p /etc/sysctl.d/90-swap.conf
```

```
swapon --show
```

### 6.10.5 - Полезно знать про хостинг (Amnezia Hosting)

- **"Белые списки" на мобильном интернете:** при угрозе БПЛА операторы
  оставляют доступ только к разрешённым сервисам - VPS с телефона недоступен
  **любым** протоколом. Через домашний Wi-Fi работает. Ждать отмены.
- **ICMP (ping) хостер блокирует намеренно** на своих серверах. Если ping
  до VPS перестал проходить, а SSH работает - это не обрыв. Проверки
  доступности (netwatch) надёжнее делать по TCP 443.
- **Gemini** отклоняет запросы с адресов дата-центров - через VPS не
  заработает ни при каких настройках. ChatGPT и Claude работают.
- **Bad State** (сервер не реагирует на кнопки): не нажимать кнопки
  повторно, сразу тикет. Переустановка ОС и сброс пароля из панели
  поддерживаются только на серверах, выданных после 20.07.2026.
- **`H1-H4 = 1, 2, 3, 4` при включённой защите заголовков (3.1) - так и
  надо, не менять.** По документации Amnezia, при `HeaderProtectionKey` тип
  пакета шифруется (ChaCha20) и в сети не виден при любых H, а 1-4 - режим
  совместимости. Диапазоны H вместе с `RandomTrailers` сейчас даже вредны:
  известная ошибка - транспортные пакеты принимаются за рукопожатие, скорость
  падает ниже 1 Мбит/с, в журнале `invalid mac1`. Условие для защиты
  заголовков: все `S1-S4` не меньше 12.
- **Разные параметры "мусора" клиентам** (`Jc/Jmin/Jmax`) - вики хостера
  советует, официальная документация Amnezia об этом молчит. Сервер их не
  сверяет, вреда нет, но и подтверждённой пользы для личного сервера тоже.
  Если делать - только новым клиентам: `Jc` 3-7, `Jmax` заметно меньше MTU.

---

## Безопасность VPS: что светит и как проверить

- Снаружи должны быть открыты только: UDP порт AmneziaWG, UDP 41641
  (Tailscale), и 80/443, если на VPS есть сайт. AmneziaWG и Tailscale на
  скан не отвечают.
- Проверить, что о сервере знают сканеры (на ПК или VPS, ⛔ IP подставь):
  `curl -s https://internetdb.shodan.io/ПОДСТАВЬ_IP_VPS`.
- **Если VPS взломают:** у злоумышленника будут ключи пиров (он сможет
  выдавать себя за шлюз перед VPS) и выход через твой дом по профилю "Дом".
  Поэтому: SSH только по ключу, публичный 22 закрыт, лишних служб нет.
  Подозрение на взлом - переустанови VPS и перевыпусти **все** ключи.

---

### 6.10.6 - Срочная уязвимость ядра, а исправленного ядра ещё нет

Реальный случай - CVE-2026-98432 (TCP ядра, удалённая, 9.8): Debian выпустил
исправление сразу, Ubuntu - нет. VPS смотрит в интернет, поэтому до выхода
ядра ставятся обходные меры (они не заменяют новое ядро):

1. Выключить MPTCP (Caddy, AdGuard, Tailscale на Go 1.24+ включают его сами;
   при выключенном откатываются на обычный TCP):

```
echo 'net.mptcp.enabled = 0' > /etc/sysctl.d/90-cve-2026-98432.conf
```

```
sysctl -w net.mptcp.enabled=0
```

```
systemctl restart caddy AdGuardHome tailscaled
```

**ПРОВЕРКА:** `ss -Mlnp` - пусто.

2. Правило-фильтр отдельной таблицей (весь фаервол не перезагружается).
   ⚠️ Блок писать **пробелами**: табы при вставке в терминал bash принимает
   за автодополнение.

```
printf 'table ip cve_2026_98432 {\n    chain prerouting {\n        type filter hook prerouting priority -300; policy accept;\n        meta l4proto tcp ip hdrlength != 5 drop\n    }\n}\n' > /etc/nftables-cve.nft
```

```
nft -c -f /etc/nftables-cve.nft && nft -f /etc/nftables-cve.nft
```

```
echo 'include "/etc/nftables-cve.nft"' >> /etc/nftables.conf
```

**ПРОВЕРКА:** `nft -c -f /etc/nftables.conf` - без ошибок; сайт отвечает `200`.

3. Когда выйдет исправленное ядро - поставить вручную по 6.10.2 (ядро
   заморожено, проверка DKMS для `amneziawg` до перезагрузки).

---

### 6.10.7 - Переезд на другой хостинг (VPS заблокирован, удалён или взломан)

Бэкап из 6.10.3 - всё, что нужно для переезда. Время - около часа, большая
часть уходит на установку пакетов и смену адреса у клиентов.

**Сначала реши, было ли у хостера вторжение.** Если хостинг взломали (как
Beget 02.11.2026 или хостеров с VMmanager в октябре 2026), ключи AmneziaWG
из старого сервера могли утечь: при распаковке ниже добавь
`--exclude=etc/amnezia` и сделай ключи заново (Шаги 6.3, 6.6-6.8). Если
просто заблокировали адрес или удалили сервер - берём всё из архива.

**1. Новый VPS:** только Шаги 6.1 (базовая защита, вход по ключу) и 6.2
(AmneziaWG). Шаги 6.3-6.8 НЕ делаем - их заменяет архив.

**2. Шлюз** - копия последнего архива, доступная для `scp`:

```
sudo sh -c 'install -m 600 -o user "$(ls -1t /var/backups/vps/vps-*.tar.gz | head -1)" /tmp/vps-restore.tar.gz' && ls -l /tmp/vps-restore.tar.gz
```

**3. PowerShell** - забрать на ПК:

```
scp user@192.168.50.1:/tmp/vps-restore.tar.gz d:\server\
```

**4. PowerShell** - отдать на новый VPS (⛔ подставь адрес):

```
scp d:\server\vps-restore.tar.gz root@ПОДСТАВЬ_НОВЫЙ_IP:/root/
```

**5. Шлюз** - убрать временную копию (в архиве приватные ключи):

```
rm -f /tmp/vps-restore.tar.gz
```

**6. Новый VPS** - распаковать. ⛔ Сеть (`netplan`) и имя хоста от старого
сервера НЕ берём - иначе новый VPS потеряет сеть:

```
tar xzf /root/vps-restore.tar.gz -C / --exclude=etc/netplan --exclude=etc/hostname && echo OK
```

**7. Новый VPS** - имя сетевой карты. В `nftables.conf` стоит `eth0`:

```
ip -br link | grep -v -E '^(lo|awg|tailscale)'
```

Если карта называется иначе (например `ens3`):

```
sed -i 's/"eth0"/"ens3"/g' /etc/nftables.conf && grep -c ens3 /etc/nftables.conf
```

**8. Новый VPS:**

```
sysctl --system >/dev/null && nft -c -f /etc/nftables.conf && systemctl enable --now nftables && echo FW-OK
```

**9. Новый VPS** - службы из архива:

```
systemctl daemon-reload && systemctl enable --now awg-quick@awg1 ru-block-update.timer AdGuardHome && awg show awg1 | head -3
```

**10. Новый VPS** - Caddy ставится пакетом по Части 7 (конфиг и сайт уже на
месте), затем `systemctl restart caddy`. Tailscale - по Шагу 6.9 (`tailscale
up`, вход заново). Новый Tailscale-адрес VPS впиши на шлюзе в `HOSTS` в
`/usr/local/sbin/vps-backup-pull.sh`.

**11. DNS сайта** - у регистратора/DNS-хостинга смени записи `A` у домена,
`www` и `photos` на новый адрес. Сертификаты Caddy получит сам, когда DNS
обновится (от минут до пары часов, зависит от TTL).

**12. Клиенты** - заменить старый адрес на новый. Шлюз (и так же второй
шлюз, по Tailscale):

```
sudo sed -i 's/ПОДСТАВЬ_СТАРЫЙ_IP/ПОДСТАВЬ_НОВЫЙ_IP/' /etc/gateway/tunnels/vpn-backup.conf /etc/gateway/tunnels/vpn-amz.conf && grep -h Endpoint /etc/gateway/tunnels/vpn-backup.conf /etc/gateway/tunnels/vpn-amz.conf
```

```
sudo systemctl restart vpn-slot@vpn-backup vpn-slot@vpn-amz gw-routing
```

Телефоны и ПК: в приложении AmneziaVPN/AmneziaWG поменять `Endpoint` в
профиле или заново импортировать конфиг с новым адресом.

**13. Проверка** - на шлюзе команда из Части 4, раздел 5.1.1 (ожидается
"всё живо"), на VPS - `awg show awg1` (свежие handshake у клиентов), сайт
открывается.

**14. Новый VPS** - убрать архив: `rm -f /root/vps-restore.tar.gz`. На ПК
удали `d:\server\vps-restore.tar.gz`.

> Старый адрес держи в голове: если старый VPS вернётся (как сервер после
> проверки у хостера), не включай его в работу без проверки на закладки -
> `authorized_keys`, пользователи, cron, службы. Надёжнее удалить.

---

## Диагностика VPS

| Симптом | Проверка на VPS | Лечение |
|---|---|---|
| ни один клиент не подключается | `awg show awg1` (есть ли интерфейс), `ss -ulnp \| grep 51820` | `systemctl restart awg-quick@awg1` |
| пропал доступ по Tailscale после правки firewall | применили весь `nftables.conf` | `systemctl restart tailscaled` |
| клиент подключён, интернета нет | `nft list table ip nat` (masquerade на `eth0`?), `sysctl net.ipv4.ip_forward` | Шаги 6.2, 6.4 |
| "Чебурнет"/"Дом" показывают IP VPS | `awg-who` - подключён не тот профиль? | переключить профиль на устройстве |
| "Дом" подключён, интернета нет | `ip rule \| grep 5300`, `ip route show table 300`, рукопожатие `gw-backup` в `awg-who` | рестарт `awg-quick@awg1`; на шлюзе - Часть 4 |
| российские сайты не открываются в VPN | так задумано (`reject` на `ru4`) | профиль "Чебурнет" |
| `ru4` пуст после перезагрузки | `ls -l /etc/nftables.d/ru4.nft`, `grep -c include /etc/nftables.conf` | `systemctl start ru-block-update` (пишет файл заново) |
| весь VPN-провайдер блокируют волнами | - | свой адрес, протокол 3.1, держать запасной выход (WARP) |
| после перезагрузки VPS ни один клиент не подключается | `modinfo amneziawg` - `not found` | ядро обновилось без модуля: загрузить старое ядро (консоль хостера), затем 6.10.2 |
| VPS заменили / переустановили, конфигов нет | `ls /var/backups/vps/` **на шлюзе** | восстановление из бэкапа (6.10.3) |
| с телефона на мобильном VPS недоступен, через Wi-Fi работает | - | "белые списки" оператора (6.10.5), ждать |
| ping до VPS не проходит, SSH работает | - | ICMP режет хостер (6.10.5), это не обрыв |

**На шлюзе** для "Чебурнета/Дома" нужны (Часть 2): маршрут
`10.78.0.0/24 dev vpn-backup` (в `vpn-slot-up.sh`) и NAT
`oifname "wan" ip saddr 10.78.0.0/24 masquerade` (в `gwroute.nft`).
Проверка на шлюзе:

```
ip route show 10.78.0.0/24
```

```
sudo nft list chain ip gwroute nat | grep 10.78
```
