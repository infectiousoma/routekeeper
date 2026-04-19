#!/usr/bin/env bash
# proxy-status.sh — status for proxy steering
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DNSMASQ_DIR="${DNSMASQ_DIR:-$REPO_DIR/dnsmasq}"
REDSOCKS_DIR="${REDSOCKS_DIR:-$REPO_DIR/redsocks}"
# shellcheck source=../config.env
source "$REPO_DIR/config.env"

echo "== iface DNS =="
resolvectl status "$IFACE" | sed -n '1,20p' || true
echo

echo "== dnsmasq =="
ss -lnup | awk '$5 ~ /:53$/ && $5 ~ /'"$DNSIP_LOOP"'/ {print}'
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | awk 'NR==1 || /proxy-dnsmasq/'
echo

echo "== redsocks =="
ss -ltn | awk '$4 ~ /'"$REDHOST"':'"$REDPORT"'\b/'
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | awk 'NR==1 || /redsocks/'
echo

echo "== ipset sizes =="
for S in "$IPSET_V4_NFX" "$IPSET_V6_NFX" "$IPSET_V4_SORA" "$IPSET_V6_SORA"; do
  sudo ipset list "$S" 2>/dev/null | awk 'NR==1 || /Number of entries/'
done
echo

echo "== nat OUTPUT redirects =="
sudo iptables -t nat -vnL OUTPUT 2>/dev/null | awk '/REDIRECT/ && /match-set/ && /'"$REDPORT"'/ {print}'
echo

echo "== IPv6 blocks (OUTPUT) =="
sudo ip6tables -vnL OUTPUT 2>/dev/null | awk '/match-set .*_us6/ {print}'
echo

echo "== quick end-to-end test =="
IP=$(sudo ipset list "$IPSET_V4_NFX" 2>/dev/null | awk '/^[0-9]+\./{print $1; exit}')
if [[ -n "$IP" ]]; then
  echo "TCP 443 to $IP (should hit redsocks on lo:$REDPORT)"
  sudo tcpdump -ni lo "port $REDPORT" -c 2 >/dev/null 2>&1 &
  sleep 0.3
  nc -vz "$IP" 443 || true
else
  echo "(no netflix_us entries)"
fi
