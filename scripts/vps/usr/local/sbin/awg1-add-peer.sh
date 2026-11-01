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
