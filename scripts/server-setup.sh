#!/usr/bin/env bash
# server-setup.sh — one-time server-side installer/verifier
# Runs on the home server directly or via SSH.
# Requires: config.env populated with DANTE_IP, ADGUARD_IP, ADGUARD_PORT, DEPLOY_MODE
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$REPO_DIR/config.env"

say(){ printf '%s\n' "$*"; }

usage(){
  say "Usage: $0 [--mode dns|proxy|both] [--routing selective|transparent|gateway]"
  say ""
  say "  --mode dns        Verify AdGuard Home reachable. No Dante."
  say "  --mode proxy      Start Dante SOCKS5 container and verify."
  say "  --mode both       Verify AdGuard + start Dante."
  say ""
  say "  --routing gateway Enable IP forwarding + NAT MASQUERADE for WireGuard gateway mode."
  say "                    Use when clients run: proxy-on.sh --routing gateway"
  say ""
  say "Defaults to DEPLOY_MODE from config.env (currently: ${DEPLOY_MODE:-proxy})"
  exit 1
}

MODE="${DEPLOY_MODE:-proxy}"
ROUTING=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)    MODE="$2";    shift 2 ;;
    --routing) ROUTING="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) say "[err] Unknown arg: $1"; usage ;;
  esac
done

[[ "$MODE" =~ ^(dns|proxy|both)$ ]] || { say "[err] --mode must be dns, proxy, or both"; usage; }
[[ -z "$ROUTING" || "$ROUTING" =~ ^(selective|transparent|gateway)$ ]] \
  || { say "[err] --routing must be selective, transparent, or gateway"; usage; }

verify_wireguard(){
  if ! ip link show wg0 &>/dev/null; then
    say "[err] WireGuard interface wg0 not found — ensure WireGuard is configured and running"
    exit 1
  fi
  if ip link show wg0 | grep -q 'state UP'; then
    say "[ok] WireGuard wg0 is up"
  else
    say "[warn] wg0 exists but state is not UP — check: wg show"
  fi
}

verify_adguard(){
  local ag_ip="${ADGUARD_IP:-}" ag_port="${ADGUARD_PORT:-53}"
  [[ -z "$ag_ip" ]] && { say "[err] ADGUARD_IP not set in config.env"; exit 1; }
  say "[info] Checking AdGuard Home at ${ag_ip}:${ag_port} ..."
  if dig +short +timeout=3 "@${ag_ip}" -p "${ag_port}" version.bind CHAOS TXT &>/dev/null \
     || nc -zu -w3 "${ag_ip}" "${ag_port}" &>/dev/null 2>&1; then
    say "[ok] AdGuard DNS reachable at ${ag_ip}:${ag_port}"
  else
    say "[warn] Cannot reach AdGuard at ${ag_ip}:${ag_port}"
    say "       Ensure WireGuard is up and AdGuard is listening on the WireGuard interface"
  fi
}

setup_dante(){
  say "[info] Starting Dante SOCKS5 server ..."
  if ! [[ -d "$REPO_DIR/dante" ]]; then
    say "[err] dante/ directory not found at $REPO_DIR/dante"
    exit 1
  fi
  if docker ps --filter "name=dante-socks" --filter "status=running" --format '{{.Names}}' | grep -q dante-socks; then
    say "[ok] Dante container already running"
  else
    ( cd "$REPO_DIR/dante" && docker compose up -d )
    say "[ok] Dante container started"
  fi
  say "[info] Verifying Dante connectivity at ${DANTE_IP}:${DANTE_PORT} ..."
  if curl --max-time 5 --silent --socks5 "${DANTE_IP}:${DANTE_PORT}" https://api.ipify.org &>/dev/null; then
    say "[ok] Dante SOCKS5 reachable at ${DANTE_IP}:${DANTE_PORT}"
  else
    say "[warn] Dante not reachable at ${DANTE_IP}:${DANTE_PORT}"
    say "       Check dante/sockd.conf and WireGuard connectivity"
  fi
}

setup_gateway(){
  local wan="${WAN_IFACE:-}"
  [[ -z "$wan" ]] && { say "[err] WAN_IFACE not set in config.env — needed for MASQUERADE"; exit 1; }
  say "[info] Enabling IP forwarding + NAT MASQUERADE on $wan ..."
  sudo sysctl -w net.ipv4.ip_forward=1
  sudo iptables -t nat -C POSTROUTING -o "$wan" -j MASQUERADE 2>/dev/null \
    || sudo iptables -t nat -A POSTROUTING -o "$wan" -j MASQUERADE
  say "[ok] Gateway mode: WireGuard clients can now route all traffic through this server"
  say "[warn] Make ip_forward persistent: add 'net.ipv4.ip_forward=1' to /etc/sysctl.conf"
}

say "[info] Server setup — mode: $MODE${ROUTING:+ routing: $ROUTING}"
verify_wireguard

case "$MODE" in
  dns)
    verify_adguard
    say "[done] DNS mode: AdGuard verified at ${ADGUARD_IP:-}:${ADGUARD_PORT:-53}"
    ;;
  proxy)
    setup_dante
    say "[done] Proxy mode: Dante at ${DANTE_IP}:${DANTE_PORT}"
    ;;
  both)
    verify_adguard
    setup_dante
    say "[done] Both modes configured"
    ;;
esac

if [[ "$ROUTING" == "gateway" ]]; then
  setup_gateway
  say "[done] Gateway routing enabled — clients can use: proxy-on.sh --routing gateway"
fi
