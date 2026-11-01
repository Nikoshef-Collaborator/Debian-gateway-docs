#!/bin/bash
# gw-feeder.sh - обновление community-списков (РФ напрямую, голос через VPS).
set -u
source /etc/gateway/gateway.conf 2>/dev/null || true
LOG_TAG="gw-feeder"
DOMAINS_OUT="/etc/dnsmasq.d/ru-inside.conf"
TABLE="gwroute"

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

# заливка CIDR пачками по 500: одной командой 17К+ подсетей не влезает
# ("Argument list too long"), построчно - долго и грузит CPU
load_cidr() {  # $1=файл со списком, $2=набор
    local cidr_tmp cf elems
    cidr_tmp=$(mktemp -d)
    grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' "$1" | split -l 500 - "$cidr_tmp/c_"
    nft flush set ip "$TABLE" "$2" 2>/dev/null
    for cf in "$cidr_tmp"/c_*; do
        [ -e "$cf" ] || continue
        elems=$(paste -sd, "$cf")
        nft add element ip "$TABLE" "$2" "{ $elems }" 2>/dev/null
    done
    rm -rf "$cidr_tmp"
    nft list set ip "$TABLE" "$2" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | wc -l
}

# --- РФ-домены -> ru-inside.conf (ru_direct) ---
if [ -n "${RU_DOMAINS_URL:-}" ]; then
    tmp=$(mktemp)
    if fetch "$RU_DOMAINS_URL" "$tmp"; then
        {
            echo "# AUTO: РФ-домены (напрямую). Источник: $RU_DOMAINS_URL"
            grep -oE 'nftset=/[^/]+/' "$tmp" | sed -E 's#nftset=/##; s#/##' | \
                while IFS= read -r d; do
                    [ -z "$d" ] && continue
                    echo "nftset=/${d}/4#ip#${TABLE}#ru_direct"
                done
        } > "${DOMAINS_OUT}.new"
        cnt=$(grep -c '^nftset=' "${DOMAINS_OUT}.new")
        if [ "$cnt" -gt 20 ]; then
            mv "${DOMAINS_OUT}.new" "$DOMAINS_OUT"
            dnsmasq --test 2>&1 | grep -qi 'syntax check OK' && systemctl restart dnsmasq
            logger -t "$LOG_TAG" "РФ-домены: $cnt применено"
        else
            logger -t "$LOG_TAG" "РФ-домены: подозрительно мало ($cnt), не применяю"
            rm -f "${DOMAINS_OUT}.new"
        fi
    else
        logger -t "$LOG_TAG" "ERROR: не скачать РФ-домены"
    fi
    rm -f "$tmp"
fi

# --- РФ-подсети -> ru_cidr ---
if [ -n "${RU_CIDR_URL:-}" ]; then
    tmp=$(mktemp)
    if fetch "$RU_CIDR_URL" "$tmp" && [ "$(grep -c . "$tmp")" -gt 100 ]; then
        cnt=$(load_cidr "$tmp" ru_cidr)
        logger -t "$LOG_TAG" "РФ-CIDR: $cnt подсетей"
    else
        logger -t "$LOG_TAG" "ERROR: РФ-CIDR не скачан или мал, набор не трогаю"
    fi
    rm -f "$tmp"
fi

# --- голосовые подсети -> voice_direct ---
if [ -n "${VOICE_CIDR_URLS:-}" ]; then
    tmp=$(mktemp); ok=1
    for url in $VOICE_CIDR_URLS; do { fetch "$url" "$tmp.part" && cat "$tmp.part" >> "$tmp"; } || ok=0; done; rm -f "$tmp.part"
    if [ "$ok" -eq 1 ] && [ "$(grep -c . "$tmp")" -gt 20 ]; then
        cnt=$(load_cidr "$tmp" voice_direct)
        logger -t "$LOG_TAG" "voice-CIDR: $cnt подсетей"
    else
        logger -t "$LOG_TAG" "ERROR: не скачать voice-CIDR, набор не трогаю"
    fi
    rm -f "$tmp"
fi

# --- группы доменов для gw-domain-move ---
if [ -n "${SERVICE_GROUP_URLS:-}" ]; then
    GROUPS_DIR="/etc/gateway/service-groups"
    mkdir -p "$GROUPS_DIR"
    for pair in $SERVICE_GROUP_URLS; do
        name="${pair%%:*}"; url="${pair#*:}"; tmp=$(mktemp)
        if fetch "$url" "$tmp"; then
            grep -oE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' "$tmp" > "$GROUPS_DIR/${name}.txt.new"
            if [ "$(wc -l < "$GROUPS_DIR/${name}.txt.new")" -gt 3 ]; then
                mv "$GROUPS_DIR/${name}.txt.new" "$GROUPS_DIR/${name}.txt"
            else
                rm -f "$GROUPS_DIR/${name}.txt.new"
            fi
        fi
        rm -f "$tmp"
    done
    [ -x /usr/local/sbin/gw-domain-rebuild.sh ] && /usr/local/sbin/gw-domain-rebuild.sh >/dev/null
fi
