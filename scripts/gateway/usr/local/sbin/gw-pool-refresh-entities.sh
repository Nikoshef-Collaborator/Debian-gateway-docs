#!/bin/bash
# список конфигов пула для выпадающих списков панели (JSON Lines)
OUT="/etc/OliveTin/entities/poolfiles.json"
mkdir -p "$(dirname "$OUT")"; : > "$OUT"
for f in /etc/gateway/pool/*.conf; do
    [ -e "$f" ] && printf '{"name": "%s"}\n' "$(basename "$f")" >> "$OUT"
done
exit 0
