#!/bin/bash
# Статический IP на LAN-карте шлюза. Маршрутизацию не трогает.
LAN=lan
ip addr replace 192.168.50.1/24 dev "$LAN"
ip link set "$LAN" up
