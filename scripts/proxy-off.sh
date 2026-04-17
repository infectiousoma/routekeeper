#!/usr/bin/env bash
# proxy-off.sh — remove rules, stop redsocks; don’t nuke DNS setup
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REDSOCKS_DIR="${REDSOCKS_DIR:-$REPO_DIR/redsocks}"
# shellcheck source=../config.env
source "$REPO_DIR/config.env"

# Remove v4 rules (quiet if missing)
for SET in "$IPSET_V4_NF" "$IPSET_V4_SO" "$IPSET_V4_XF"; do
  sudo iptables -t nat -D OUTPUT -p tcp -m set --match-set "$SET" dst -j REDIRECT --to-ports "$REDPORT" 2>/dev/null || true
  sudo iptables -D OUTPUT -p udp --dport 443 -m set --match-set "$SET" dst -j REJECT 2>/dev/null || true
done

# Remove v6 rules (quiet if missing)
for SET6 in "$IPSET_V6_NF" "$IPSET_V6_SO" "$IPSET_V6_XF"; do
  sudo ip6tables -D OUTPUT -p tcp -m set --match-set "$SET6" dst -j REJECT 2>/dev/null || true
  sudo ip6tables -D OUTPUT -p udp --dport 443 -m set --match-set "$SET6" dst -j REJECT 2>/dev/null || true
done

echo "[ok] Netflix/Sora/Xfinity redirect + QUIC/v6 rules removed"

# Restore saved firewall state if present (ignore errors if sets were removed)
if [[ -f "$BASELINE_DIR/ipset.save" ]]; then sudo ipset restore -exist < "$BASELINE_DIR/ipset.save" 2>/dev/null || true; fi
if [[ -f "$BASELINE_DIR/iptables.v4" ]]; then sudo iptables-restore < "$BASELINE_DIR/iptables.v4" 2>/dev/null || true; fi
if [[ -f "$BASELINE_DIR/ip6tables.v6" ]]; then sudo ip6tables-restore < "$BASELINE_DIR/ip6tables.v6" 2>/dev/null || true; fi
echo "[ok] firewall baseline restored (ipset/iptables/ip6tables)"

# Destroy proxy ipsets — they were created by proxy-on.sh and are not in the baseline
for SET in "$IPSET_V4_NF" "$IPSET_V6_NF" "$IPSET_V4_SO" "$IPSET_V6_SO" "$IPSET_V4_XF" "$IPSET_V6_XF"; do
  sudo ipset destroy "$SET" 2>/dev/null || true
done
echo "[ok] ipsets destroyed"

# Stop redsocks (dnsmasq can remain up for containers/host DNS)
( cd "$REDSOCKS_DIR" && docker compose down ) || true
echo "[done] Proxy DISABLED — rules cleaned, ipsets destroyed, redsocks stopped (dnsmasq left running)"
