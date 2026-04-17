#!/usr/bin/env bash
# proxy-on.sh — dnsmasq+ipset+redsocks (Netflix+Sora), "self-healing"
set -Eeuo pipefail

# Derive repo root from script location so this works from any clone path.
# Set path vars before sourcing config.env — the ${VAR:-default} in that file
# will not override values that are already set.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DNSMASQ_DIR="${DNSMASQ_DIR:-$REPO_DIR/dnsmasq}"
REDSOCKS_DIR="${REDSOCKS_DIR:-$REPO_DIR/redsocks}"
echo "[info] repo root: $REPO_DIR"
# shellcheck source=../config.env
source "$REPO_DIR/config.env"

DNS_SNAPSHOT="${BASELINE_DIR}/dns.${IFACE}.before"
mkdir -p "$BASELINE_DIR"

say(){ printf '%s\n' "$*"; }
wait_for(){ # wait_for "desc" cmd...
  local d="$1"; shift
  for i in {1..40}; do "$@" >/dev/null 2>&1 && return 0; sleep 0.25; done
  say "[warn] timeout: $d"; return 1
}

ensure_alias(){
  # make loopback alias portable; we don’t need a LAN alias anymore
  : # using 127.100.53.53 (no ip addr add needed)
}

generate_ipsets_conf(){
  # Write dnsmasq ipset= rules from config.env into dnsmasq.d/ipsets.conf.
  # This runs before the container starts so dnsmasq picks them up at launch.
  local dir="$DNSMASQ_DIR/dnsmasq.d"
  local out="$dir/ipsets.conf"
  mkdir -p "$dir"
  : > "$out"
  for d in $DOMAINS_NFX;  do printf 'ipset=/%s/%s,%s\n' "$d" "$IPSET_V4_NF" "$IPSET_V6_NF"; done >> "$out"
  for d in $DOMAINS_SORA; do printf 'ipset=/%s/%s,%s\n' "$d" "$IPSET_V4_SO" "$IPSET_V6_SO"; done >> "$out"
  for d in $DOMAINS_XF;   do printf 'ipset=/%s/%s,%s\n' "$d" "$IPSET_V4_XF" "$IPSET_V6_XF"; done >> "$out"
  say "[ok] generated $out ($(wc -l < "$out") ipset rules)"
}

dnsmasq_up(){
  # force-recreate so the container always loads the freshly generated ipsets.conf
  ( cd "$DNSMASQ_DIR" && docker compose up -d --force-recreate )
  wait_for "dnsmasq $DNSIP_LOOP:53"   bash -lc "ss -lnup | grep -q '$DNSIP_LOOP:53'"
  wait_for "dnsmasq $DNSIP_BRIDGE:53" bash -lc "ss -lnup | grep -q '$DNSIP_BRIDGE:53'"
}

set_iface_dns(){
  [[ -f "$DNS_SNAPSHOT" ]] || touch "$DNS_SNAPSHOT"
  sudo resolvectl dns "$IFACE" "$DNSIP_LOOP" || true
  sudo resolvectl flush-caches || true
  wait_for "resolvectl shows $DNSIP_LOOP" bash -lc "resolvectl status $IFACE | grep -q 'DNS Servers:.*$DNSIP_LOOP'"
  say "[ok] DNS on $IFACE → $DNSIP_LOOP"
}

ensure_sets(){
  sudo ipset create "$IPSET_V4_NF" hash:ip              -exist || { say "[err] failed to create ipset $IPSET_V4_NF — check: sudo modprobe ip_set"; exit 1; }
  sudo ipset create "$IPSET_V4_SO" hash:ip              -exist || { say "[err] failed to create ipset $IPSET_V4_SO — check: sudo modprobe ip_set"; exit 1; }
  sudo ipset create "$IPSET_V4_XF" hash:ip              -exist || { say "[err] failed to create ipset $IPSET_V4_XF — check: sudo modprobe ip_set"; exit 1; }
  if [[ "$USE_IPV6" == "1" ]]; then
    sudo ipset create "$IPSET_V6_NF" hash:ip family inet6 -exist || { say "[err] failed to create ipset $IPSET_V6_NF"; exit 1; }
    sudo ipset create "$IPSET_V6_SO" hash:ip family inet6 -exist || { say "[err] failed to create ipset $IPSET_V6_SO"; exit 1; }
    sudo ipset create "$IPSET_V6_XF" hash:ip family inet6 -exist || { say "[err] failed to create ipset $IPSET_V6_XF"; exit 1; }
  fi
}

prime_sets(){
  # Actively "tickle" dnsmasq so it fills the ipsets before rules go in.
  local dns="$DNSIP_LOOP"

  for _ in $(seq 1 $PRIME_TRIES); do
    for d in $DOMAINS_NFX $DOMAINS_SORA $DOMAINS_XF; do
      dig +short @"$dns" A "$d" >/dev/null 2>&1 || true
      [[ "$USE_IPV6" == "1" ]] && dig +short @"$dns" AAAA "$d" >/dev/null 2>&1 || true
    done
    sleep 0.2
    NFX=$(sudo ipset list "$IPSET_V4_NF" 2>/dev/null | awk '/Number of entries/{print $4}')
    [[ -n "${NFX:-}" && "$NFX" -gt 0 ]] && break
  done
}

generate_redsocks_conf(){
  cat > "$REDSOCKS_DIR/redsocks.conf" <<EOF
base {
  log_debug = off;
  log_info  = on;
  daemon    = off;
  redirector = iptables;
}
redsocks {
  local_ip   = $REDHOST;
  local_port = $REDPORT;

  ip   = $DANTE_IP;
  port = $DANTE_PORT;
  type = socks5;
}
EOF
  say "[ok] generated $REDSOCKS_DIR/redsocks.conf ($DANTE_IP:$DANTE_PORT)"
}

ensure_redsocks(){
  ( cd "$REDSOCKS_DIR" && docker compose up -d --force-recreate )
  wait_for "redsocks $REDHOST:$REDPORT" bash -lc "ss -ltn | grep -q '${REDHOST//./\\.}:$REDPORT\\b'"
}

install_rules(){
  # v4 → redsocks (Netflix + Sora)
  for SET in "$IPSET_V4_NF" "$IPSET_V4_SO" "$IPSET_V4_XF"; do
    sudo iptables -t nat -C OUTPUT -p tcp -m set --match-set "$SET" dst -j REDIRECT --to-ports "$REDPORT" 2>/dev/null \
      || sudo iptables -t nat -I OUTPUT 1 -p tcp -m set --match-set "$SET" dst -j REDIRECT --to-ports "$REDPORT"
    if [[ "$BLOCK_QUIC" == "true" ]]; then
      sudo iptables -C OUTPUT -p udp --dport 443 -m set --match-set "$SET" dst -j REJECT 2>/dev/null \
        || sudo iptables -I OUTPUT 1 -p udp --dport 443 -m set --match-set "$SET" dst -j REJECT
    fi
  done

  # v6: only block Netflix/Sora (forces v4 fallback just for them; YouTube untouched)
  if [[ "$USE_IPV6" == "1" ]]; then
    for SET6 in "$IPSET_V6_NF" "$IPSET_V6_SO" "$IPSET_V6_XF"; do
      sudo ip6tables -C OUTPUT -p tcp -m set --match-set "$SET6" dst -j REJECT 2>/dev/null \
        || sudo ip6tables -I OUTPUT 1 -p tcp -m set --match-set "$SET6" dst -j REJECT
      sudo ip6tables -C OUTPUT -p udp --dport 443 -m set --match-set "$SET6" dst -j REJECT 2>/dev/null \
        || sudo ip6tables -I OUTPUT 1 -p udp --dport 443 -m set --match-set "$SET6" dst -j REJECT
    done
  fi
}

save_baseline_once(){
  if [[ "$RESTORE_ON_OFF" == "true" ]]; then
    [[ -f "$BASELINE_DIR/iptables.v4"  ]] || sudo iptables-save  > "$BASELINE_DIR/iptables.v4"
    [[ -f "$BASELINE_DIR/ip6tables.v6" ]] || sudo ip6tables-save > "$BASELINE_DIR/ip6tables.v6"
    [[ -f "$BASELINE_DIR/ipset.save"   ]] || sudo ipset save     > "$BASELINE_DIR/ipset.save" || true
  fi
}

# ----------------- bring-up sequence -----------------
save_baseline_once
# clean stale nft rules that may reference old set names (safe no-op)
sudo nft -a list ruleset 2>/dev/null \
| awk -v pat="($IPSET_V4_NF|$IPSET_V4_SO|$IPSET_V4_XF)" '
  $1=="table"{fam=$2;tab=$3}
  $1=="chain"{chn=$2}
  $0 ~ pat { for(i=1;i<=NF;i++) if($i=="handle") h=$(i+1); if(h) print "nft delete rule",fam,tab,chn,"handle",h; h="" }
' | sudo sh 2>/dev/null || true

ensure_alias
ensure_sets
generate_ipsets_conf
dnsmasq_up
[[ "$SELF_DNS" == "true" ]] && set_iface_dns
prime_sets

# print ipset population counts for all 6 sets
say "[ok] ipset population after priming:"
for S in "$IPSET_V4_NF" "$IPSET_V6_NF" "$IPSET_V4_SO" "$IPSET_V6_SO" "$IPSET_V4_XF" "$IPSET_V6_XF"; do
  cnt=$(sudo ipset list "$S" 2>/dev/null | awk '/Number of entries/{print $4}')
  say "  $S: ${cnt:-0} entries"
done

# refuse to continue if Netflix set is still empty (misconfig)
NFX=$(sudo ipset list "$IPSET_V4_NF" 2>/dev/null | awk '/Number of entries/{print $4}')
if [[ -z "${NFX:-}" || "$NFX" -eq 0 ]]; then
  say "[err] $IPSET_V4_NF is empty — check dnsmasq ipset= lines & host DNS ($DNSIP_LOOP)"
  exit 1
fi

generate_redsocks_conf
ensure_redsocks
install_rules

echo "[ok] redsocks @ $(ss -ltn | awk '/'"$REDHOST"':'"$REDPORT"'/{print $4}')"
echo "[ok] nat OUTPUT redirects:"
sudo iptables -t nat -vnL OUTPUT | awk '/REDIRECT/ && /'"$REDPORT"'/ && /match-set/ {print}'
echo "[ok] Dante SOCKS test:"
( curl --max-time 5 --socks5 "$DANTE_IP:$DANTE_PORT" https://api.ipify.org && echo ) || echo "(Dante unreachable; rules still installed)"
echo "[done] Proxy ENABLED (Netflix + Sora)"
