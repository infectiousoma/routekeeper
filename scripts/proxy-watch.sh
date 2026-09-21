#!/usr/bin/env bash
# proxy-watch.sh — re-establish proxy steering after WireGuard / network outages
#   proxy-watch.sh          run forever (systemd: proxy-watch.service)
#   proxy-watch.sh --once   check for drift once, repair if needed, exit
#
# Kernel ipsets, iptables rules and both containers normally survive a WireGuard
# drop, so this does NOT blindly re-run proxy-on.sh. It probes Dante, and on
# recovery (and every WATCH_RECONCILE_EVERY seconds) checks that each piece is
# still in place. Only if something drifted does it re-run proxy-on.sh.
# Does nothing while the proxy is disabled (no $BASELINE_DIR/enabled marker).
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# systemd system units may not set HOME, and config.env expands it under set -u
: "${HOME:=$(getent passwd "$(id -u)" | cut -d: -f6)}"; export HOME
# shellcheck source=../config.env
source "$REPO_DIR/config.env"

WATCH_INTERVAL="${WATCH_INTERVAL:-5}"                   # seconds between Dante probes
WATCH_FAIL_THRESHOLD="${WATCH_FAIL_THRESHOLD:-3}"       # consecutive failed probes = down
WATCH_RECONCILE_EVERY="${WATCH_RECONCILE_EVERY:-30}"    # drift check period while up

ONCE=0
case "${1:-}" in
  --once) ONCE=1 ;;
  "")     ;;
  *)      echo "usage: ${0##*/} [--once]" >&2; exit 2 ;;
esac

log(){ printf '[watch] %s\n' "$*"; }   # journald adds timestamps

# Same discovery rule as proxy-on.sh / proxy-off.sh
all_suffixes(){
  compgen -v | grep '^DOMAINS_' | sed 's/^DOMAINS_//' | sort | while read -r s; do
    local v4="IPSET_V4_${s}" v6="IPSET_V6_${s}"
    [[ -n "${!v4:-}" && -n "${!v6:-}" ]] && echo "$s"
  done
}

dante_up(){ timeout 3 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$DANTE_IP" "$DANTE_PORT" 2>/dev/null; }
container_up(){ [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == true ]]; }
listening(){ ss -ln"$1"H | awk -v a="$2" '$4==a{f=1} END{exit !f}'; }   # listening t|u addr:port

dns_ok(){
  case "$(cat "$BASELINE_DIR/dns.backend" 2>/dev/null)" in
    resolvectl) resolvectl dns "$IFACE" 2>/dev/null | grep -qF "$DNSIP_LOOP" ;;
    nmcli)      nmcli -g ipv4.dns con show "$(cat "$BASELINE_DIR/dns.nmcli.conn")" 2>/dev/null | grep -qF "$DNSIP_LOOP" ;;
    *)          grep -qF "$DNSIP_LOOP" /etc/resolv.conf ;;
  esac
}

# Prints the first thing that is missing and returns 0; returns 1 if all is in place.
find_problem(){
  local mode s v4 v6
  mode=$(<"$BASELINE_DIR/routing.mode")

  container_up proxy-dnsmasq && listening u "$DNSIP_LOOP:53" \
    || { echo "dnsmasq not running on $DNSIP_LOOP:53"; return 0; }
  if [[ "$SELF_DNS" == "true" ]] && ! dns_ok; then
    echo "$IFACE DNS no longer points at $DNSIP_LOOP"; return 0
  fi

  if [[ "$mode" != "gateway" ]]; then
    container_up redsocks && listening t "$REDHOST:$REDPORT" \
      || { echo "redsocks not running on $REDHOST:$REDPORT"; return 0; }
  fi

  case "$mode" in
    selective)
      for s in $(all_suffixes); do
        v4="IPSET_V4_${s}"; v6="IPSET_V6_${s}"
        sudo ipset list -t "${!v4}" >/dev/null 2>&1 \
          || { echo "ipset ${!v4} missing"; return 0; }
        [[ "$USE_IPV6" == "1" ]] && ! sudo ipset list -t "${!v6}" >/dev/null 2>&1 \
          && { echo "ipset ${!v6} missing"; return 0; }
        sudo iptables -t nat -C OUTPUT -p tcp -m set --match-set "${!v4}" dst -j REDIRECT --to-ports "$REDPORT" 2>/dev/null \
          || { echo "REDIRECT rule for ${!v4} missing"; return 0; }
      done ;;
    transparent)
      sudo iptables -t nat -C OUTPUT -p tcp -j PROXY_REDIRECT 2>/dev/null \
        || { echo "PROXY_REDIRECT jump missing"; return 0; } ;;
    gateway)
      [[ -n "$(ip route show default dev wg0 2>/dev/null)" ]] \
        || { echo "default route via wg0 missing"; return 0; } ;;
  esac
  return 1
}

reconcile(){
  if [[ ! -f "$BASELINE_DIR/enabled" ]]; then
    if [[ $ONCE == 1 ]]; then log "proxy not enabled (run proxy-on.sh first)"; fi
    return 0
  fi
  local why mode
  if why=$(find_problem); then
    mode=$(<"$BASELINE_DIR/routing.mode")
    log "drift: $why — re-running proxy-on.sh ($mode)"
    "$REPO_DIR/scripts/proxy-on.sh" --if-enabled --routing "$mode" \
      || log "proxy-on.sh failed (rc=$?); will retry"
  elif [[ $ONCE == 1 ]]; then
    log "no drift"
  fi
}

sudo -n true 2>/dev/null || { log "must run as root or with passwordless sudo (see proxy-watch.service)"; exit 1; }

if [[ $ONCE == 1 ]]; then reconcile; exit 0; fi

trap 'exit 0' TERM INT
[[ -f "$BASELINE_DIR/enabled" ]] || log "proxy not enabled yet; idle until proxy-on.sh runs"
log "watching $DANTE_IP:$DANTE_PORT every ${WATCH_INTERVAL}s"

state=up fails=0 last=0
while :; do
  printf -v now '%(%s)T' -1
  if dante_up; then
    fails=0
    if [[ $state == down ]]; then
      log "Dante reachable again"
      state=up; last=$now
      reconcile
    elif (( now - last >= WATCH_RECONCILE_EVERY )); then
      last=$now
      reconcile
    fi
  elif [[ $state == up ]] && (( ++fails >= WATCH_FAIL_THRESHOLD )); then
    log "Dante unreachable after $fails probes; waiting for recovery"
    state=down
  fi
  sleep "$WATCH_INTERVAL" & wait $!
done
