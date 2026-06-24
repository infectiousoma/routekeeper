#!/usr/bin/env bash
# proxy-off.sh — remove rules, stop redsocks; don't nuke DNS setup
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REDSOCKS_DIR="${REDSOCKS_DIR:-$REPO_DIR/redsocks}"
# shellcheck source=../config.env
source "$REPO_DIR/config.env"

say(){ printf '%s\n' "$*"; }

# Detect which routing mode was active when proxy-on was run
ROUTING_MODE_ACTIVE="${ROUTING_MODE:-selective}"
if [[ -f "$BASELINE_DIR/routing.mode" ]]; then
  ROUTING_MODE_ACTIVE=$(cat "$BASELINE_DIR/routing.mode")
fi
echo "[info] disabling routing mode: $ROUTING_MODE_ACTIVE"

all_suffixes(){
  compgen -v | grep '^DOMAINS_' | sed 's/^DOMAINS_//' | sort | while read -r s; do
    local v4="IPSET_V4_${s}" v6="IPSET_V6_${s}"
    [[ -n "${!v4:-}" && -n "${!v6:-}" ]] && echo "$s"
  done
}

restore_iface_dns(){
  [[ "$SELF_DNS" == "true" ]] || return 0
  local backend_file="$BASELINE_DIR/dns.backend"
  [[ -f "$backend_file" ]] || return 0
  local backend
  backend=$(cat "$backend_file")

  case "$backend" in
    resolvectl)
      sudo resolvectl dns "$IFACE" "" || true
      sudo resolvectl flush-caches || true
      ;;
    nmcli)
      [[ -f "$BASELINE_DIR/dns.nmcli.conn" ]] || return 0
      local conn old_dns old_ignore
      conn=$(cat "$BASELINE_DIR/dns.nmcli.conn")
      old_dns=$(cat "$BASELINE_DIR/dns.nmcli.old-dns" 2>/dev/null | tr -d '\n' || echo "")
      old_ignore=$(cat "$BASELINE_DIR/dns.nmcli.old-ignore" 2>/dev/null | tr -d '\n' || echo "no")
      sudo nmcli con mod "$conn" ipv4.dns "$old_dns" ipv4.ignore-auto-dns "$old_ignore" || true
      sudo nmcli con up "$conn" || true
      ;;
    resolv.conf)
      [[ -f "$BASELINE_DIR/resolv.conf.bak" ]] && sudo cp "$BASELINE_DIR/resolv.conf.bak" /etc/resolv.conf || true
      ;;
  esac
  say "[ok] DNS on $IFACE restored (via $backend)"
}

remove_selective_rules(){
  for _s in $(all_suffixes); do
    _v4="IPSET_V4_${_s}"; _v6="IPSET_V6_${_s}"
    sudo iptables -t nat -D OUTPUT -p tcp -m set --match-set "${!_v4}" dst -j REDIRECT --to-ports "$REDPORT" 2>/dev/null || true
    sudo iptables -D OUTPUT -p udp --dport 443 -m set --match-set "${!_v4}" dst -j REJECT 2>/dev/null || true
    sudo ip6tables -D OUTPUT -p tcp -m set --match-set "${!_v6}" dst -j REJECT 2>/dev/null || true
    sudo ip6tables -D OUTPUT -p udp --dport 443 -m set --match-set "${!_v6}" dst -j REJECT 2>/dev/null || true
  done
  echo "[ok] selective proxy redirect + QUIC/v6 rules removed"
}

remove_transparent_rules(){
  # Remove the OUTPUT jump first, then flush and delete the chain
  sudo iptables -t nat -D OUTPUT -p tcp -j PROXY_REDIRECT 2>/dev/null || true
  sudo iptables -D OUTPUT -p udp --dport 443 ! -d 127.0.0.0/8 -j REJECT 2>/dev/null || true
  sudo iptables -t nat -F PROXY_REDIRECT 2>/dev/null || true
  sudo iptables -t nat -X PROXY_REDIRECT 2>/dev/null || true
  echo "[ok] transparent proxy rules removed"
}

remove_gateway_rules(){
  sudo ip route del default dev wg0 2>/dev/null || true
  echo "[ok] gateway route via wg0 removed"
}

# --- mode-specific teardown ---
case "$ROUTING_MODE_ACTIVE" in
  selective)
    remove_selective_rules
    if [[ -f "$BASELINE_DIR/ipset.save"   ]]; then sudo ipset restore -exist < "$BASELINE_DIR/ipset.save" 2>/dev/null || true; fi
    if [[ -f "$BASELINE_DIR/iptables.v4"  ]]; then sudo iptables-restore  < "$BASELINE_DIR/iptables.v4"  2>/dev/null || true; fi
    if [[ -f "$BASELINE_DIR/ip6tables.v6" ]]; then sudo ip6tables-restore < "$BASELINE_DIR/ip6tables.v6" 2>/dev/null || true; fi
    echo "[ok] firewall baseline restored"
    restore_iface_dns
    for _s in $(all_suffixes); do
      _v4="IPSET_V4_${_s}"; _v6="IPSET_V6_${_s}"
      sudo ipset destroy "${!_v4}" 2>/dev/null || true
      sudo ipset destroy "${!_v6}" 2>/dev/null || true
    done
    echo "[ok] ipsets destroyed"
    ( cd "$REDSOCKS_DIR" && docker compose down ) || true
    echo "[done] Proxy DISABLED (selective) — rules cleaned, redsocks stopped (dnsmasq left running)"
    ;;
  transparent)
    remove_transparent_rules
    if [[ -f "$BASELINE_DIR/iptables.v4"  ]]; then sudo iptables-restore  < "$BASELINE_DIR/iptables.v4"  2>/dev/null || true; fi
    if [[ -f "$BASELINE_DIR/ip6tables.v6" ]]; then sudo ip6tables-restore < "$BASELINE_DIR/ip6tables.v6" 2>/dev/null || true; fi
    echo "[ok] firewall baseline restored"
    restore_iface_dns
    ( cd "$REDSOCKS_DIR" && docker compose down ) || true
    echo "[done] Proxy DISABLED (transparent) — rules cleaned, redsocks stopped (dnsmasq left running)"
    ;;
  gateway)
    remove_gateway_rules
    restore_iface_dns
    echo "[done] Proxy DISABLED (gateway) — default route removed (dnsmasq left running)"
    ;;
esac
