#!/bin/bash
# ru-block-update.sh - наполнить набор inet filter ru4 российскими подсетями.
# Набор очищается только после успешной загрузки списка.
set -u
URL="https://www.ipdeny.com/ipblocks/data/countries/ru.zone"
tmp=$(mktemp); d=$(mktemp -d)
curl -fsS --max-time 60 "$URL" -o "$tmp" || { logger -t ru-block "ERROR: не скачать"; exit 1; }
n=$(grep -cE '^[0-9]+\.' "$tmp")
[ "$n" -gt 1000 ] || { logger -t ru-block "ERROR: мало подсетей ($n), не применяю"; exit 1; }
grep -E '^[0-9]+\.' "$tmp" | split -l 500 - "$d/c_"
nft flush set inet filter ru4
for f in "$d"/c_*; do nft add element inet filter ru4 "{ $(paste -sd, "$f") }"; done
rm -rf "$tmp" "$d"
logger -t ru-block "ru4: $n подсетей"
