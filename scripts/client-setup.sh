#!/usr/bin/env bash
# client-setup.sh — one-time client-side installer/configurator
# Runs on the laptop. Requires WireGuard already configured and connected.
# Requires: config.env populated (copy from config.env.example).
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DNSMASQ_DIR="${DNSMASQ_DIR:-$REPO_DIR/dnsmasq}"

if [[ ! -f "$REPO_DIR/config.env" ]]; then
  printf '[err] config.env not found. Create it first:\n  cp %s/config.env.example %s/config.env\n' \
    "$REPO_DIR" "$REPO_DIR"
  exit 1
fi
# shellcheck source=../config.env
source "$REPO_DIR/config.env"

say(){ printf '%s\n' "$*"; }

usage(){
  say "Usage: $0 [--mode dns|proxy|both]"
  say ""
  say "  dns    Start local dnsmasq forwarding HOME_DOMAIN to AdGuard."
  say "         No proxy. All traffic goes via local ISP."
  say "  proxy  Configure SOCKS5 proxy steering (existing behaviour)."
  say "         Use proxy-on.sh / proxy-off.sh to toggle at runtime."
  say "  both   DNS forwarding + proxy steering. proxy-on.sh manages runtime toggle."
  say ""
  say "Defaults to DEPLOY_MODE from config.env (currently: ${DEPLOY_MODE:-proxy})"
  exit 1
}

MODE="${DEPLOY_MODE:-proxy}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) say "[err] Unknown arg: $1"; usage ;;
  esac
done

[[ "$MODE" =~ ^(dns|proxy|both)$ ]] || { say "[err] --mode must be dns, proxy, or both"; usage; }

# --- helpers ---

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

verify_prereqs(){
  local missing=()
  for cmd in docker dig; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ "$MODE" != "dns" ]]; then
    for cmd in ipset iptables curl; do
      command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    say "[err] Missing required commands: ${missing[*]}"
    exit 1
  fi
  say "[ok] Prerequisites satisfied"
}

# append_var KEY DEFAULT — appends KEY="DEFAULT" to config.env if KEY not already present
append_var(){
  local key="$1" val="$2" env_file="$REPO_DIR/config.env"
  if ! grep -qE "^${key}=" "$env_file"; then
    printf '%s="%s"\n' "$key" "$val" >> "$env_file"
    say "[ok] Added ${key} to config.env"
  fi
}

backup_and_update_config(){
  local env_file="$REPO_DIR/config.env"
  local bak="${env_file}.bak.$(date +%Y%m%d_%H%M%S)"
  cp "$env_file" "$bak"
  say "[ok] config.env backed up → $(basename "$bak")"

  append_var "ADGUARD_IP"   "${DANTE_IP:-YOUR_ADGUARD_WG_IP}"
  append_var "ADGUARD_PORT" "53"
  append_var "HOME_DOMAIN"  "arpa.home"
  append_var "DEPLOY_MODE"  "$MODE"

  if [[ "$MODE" == "both" ]]; then
    # Reload so we pick up any vars just appended above
    source "$env_file"
    local ag_ip="${ADGUARD_IP:-}" home_dom="${HOME_DOMAIN:-arpa.home}"
    [[ -z "$ag_ip" ]] && { say "[err] ADGUARD_IP not set — fill it in config.env"; exit 1; }
    local lan_val="${home_dom}/${ag_ip}"
    # Set LAN_DNS only if currently empty or using the default placeholder
    local cur_lan
    cur_lan=$(grep -E '^LAN_DNS=' "$env_file" | head -1 | sed 's/^LAN_DNS=//' | tr -d '"' || true)
    cur_lan="${cur_lan#\$\{LAN_DNS:-\}}"  # strip shell default syntax if present
    if [[ -z "$cur_lan" || "$cur_lan" == '${LAN_DNS:-}' ]]; then
      sed -i "s|^LAN_DNS=.*|LAN_DNS=\"${lan_val}\"|" "$env_file"
      say "[ok] Set LAN_DNS=${lan_val} in config.env"
      say "     proxy-on.sh will forward ${home_dom} to AdGuard at ${ag_ip}"
    else
      say "[ok] LAN_DNS already set (${cur_lan}) — not overwriting"
    fi
  fi

  # Reload with all updated values
  source "$env_file"
}

verify_adguard(){
  local ag_ip="${ADGUARD_IP:-}" ag_port="${ADGUARD_PORT:-53}"
  [[ -z "$ag_ip" ]] && { say "[err] ADGUARD_IP not set in config.env"; exit 1; }
  say "[info] Checking AdGuard at ${ag_ip}:${ag_port} ..."
  if dig +short +timeout=3 "@${ag_ip}" -p "${ag_port}" version.bind CHAOS TXT &>/dev/null \
     || nc -zu -w3 "${ag_ip}" "${ag_port}" &>/dev/null 2>&1; then
    say "[ok] AdGuard DNS reachable at ${ag_ip}:${ag_port}"
  else
    say "[warn] Cannot reach AdGuard at ${ag_ip}:${ag_port}"
    say "       Ensure WireGuard is up and AdGuard is listening on the WireGuard interface"
  fi
}

detect_dns_backend(){
  if command -v resolvectl &>/dev/null && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    echo "resolvectl"
  elif command -v nmcli &>/dev/null && nmcli -g GENERAL.CONNECTION device show "$IFACE" &>/dev/null 2>&1; then
    echo "nmcli"
  else
    echo "resolv.conf"
  fi
}

wait_for(){
  local d="$1"; shift
  for _ in {1..40}; do "$@" >/dev/null 2>&1 && return 0; sleep 0.25; done
  say "[warn] timeout: $d"; return 1
}

generate_dnsmasq_conf_dns(){
  local out="$DNSMASQ_DIR/dnsmasq.conf"
  local ag_ip="${ADGUARD_IP:-}" ag_port="${ADGUARD_PORT:-53}"
  local home_dom="${HOME_DOMAIN:-arpa.home}"
  [[ -z "$ag_ip" ]] && { say "[err] ADGUARD_IP not set in config.env"; exit 1; }

  # dnsmasq server= port syntax: bare IP for port 53, IP#port for non-standard
  local ag_addr="$ag_ip"
  [[ "$ag_port" != "53" ]] && ag_addr="${ag_ip}#${ag_port}"

  {
    printf '# Generated by client-setup.sh (dns mode) — do not edit; configure via config.env\n'
    printf 'no-resolv\n'
    printf 'server=/%s/%s\n' "$home_dom" "$ag_addr"
    printf 'server=%s\n'     "${DNS_UPSTREAM:-9.9.9.9}"
    printf 'server=%s\n'     "${DNS_FALLBACK:-149.112.112.112}"
    printf 'bind-interfaces\n'
    printf 'listen-address=%s,%s\n' "$DNSIP_LOOP" "$DNSIP_BRIDGE"
    printf 'cache-size=1000\n'
    printf 'log-queries\n'
    printf 'log-facility=-\n'
    printf 'conf-dir=/etc/dnsmasq.d/,*.conf\n'
  } > "$out"
  say "[ok] Generated $(basename "$out") — ${home_dom} → AdGuard@${ag_addr}"
}

start_dnsmasq(){
  mkdir -p "$DNSMASQ_DIR/dnsmasq.d"
  ( cd "$DNSMASQ_DIR" && docker compose up -d --force-recreate )
  wait_for "dnsmasq ${DNSIP_LOOP}:53"   bash -lc "ss -lnup | grep -q '${DNSIP_LOOP}:53'"
  wait_for "dnsmasq ${DNSIP_BRIDGE}:53" bash -lc "ss -lnup | grep -q '${DNSIP_BRIDGE}:53'"
  say "[ok] dnsmasq running"
}

set_iface_dns(){
  local backend
  backend=$(detect_dns_backend)
  mkdir -p "$BASELINE_DIR"
  echo "$backend" > "$BASELINE_DIR/dns.backend"

  case "$backend" in
    resolvectl)
      sudo resolvectl dns "$IFACE" "$DNSIP_LOOP" || true
      sudo resolvectl flush-caches || true
      ;;
    nmcli)
      local conn
      conn=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null)
      echo "$conn" > "$BASELINE_DIR/dns.nmcli.conn"
      nmcli -g ipv4.dns con show "$conn" 2>/dev/null > "$BASELINE_DIR/dns.nmcli.old-dns" || true
      nmcli -g ipv4.ignore-auto-dns con show "$conn" 2>/dev/null > "$BASELINE_DIR/dns.nmcli.old-ignore" || true
      sudo nmcli con mod "$conn" ipv4.dns "$DNSIP_LOOP" ipv4.ignore-auto-dns yes
      sudo nmcli con up "$conn"
      ;;
    resolv.conf)
      cp /etc/resolv.conf "$BASELINE_DIR/resolv.conf.bak" 2>/dev/null || true
      { printf 'nameserver %s\n' "$DNSIP_LOOP"; cat /etc/resolv.conf; } | sudo tee /etc/resolv.conf > /dev/null
      ;;
  esac
  say "[ok] DNS on $IFACE → $DNSIP_LOOP (via $backend)"
}

install_systemd_service(){
  local svc_src="$REPO_DIR/proxy-primer.service"
  local svc_dir="$HOME/.config/systemd/user"
  local svc_dst="$svc_dir/proxy-primer.service"

  if [[ ! -f "$svc_src" ]]; then
    say "[warn] proxy-primer.service not found in repo root — skipping systemd install"
    return
  fi

  mkdir -p "$svc_dir"
  cp "$svc_src" "$svc_dst"
  systemctl --user daemon-reload
  systemctl --user enable proxy-primer.service
  say "[ok] proxy-primer.service installed and enabled for boot auto-start"
}

prompt_yn(){
  local prompt="$1"
  printf '%s [y/N] ' "$prompt"
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# --- mode handlers ---

configure_dns(){
  say "[info] Configuring DNS-only mode ..."
  verify_wireguard
  verify_prereqs
  backup_and_update_config
  verify_adguard
  generate_dnsmasq_conf_dns
  start_dnsmasq
  [[ "${SELF_DNS:-true}" == "true" ]] && set_iface_dns
  say ""
  say "[done] DNS mode active:"
  say "  $IFACE → $DNSIP_LOOP (local dnsmasq)"
  say "  ${HOME_DOMAIN:-arpa.home} → AdGuard @ ${ADGUARD_IP:-} (over WireGuard)"
  say "  All other DNS → ${DNS_UPSTREAM:-9.9.9.9}"
  say "  All traffic via local ISP — no proxy"
  say ""
  say "  To stop: docker stop proxy-dnsmasq"
}

configure_proxy(){
  say "[info] Configuring proxy mode ..."
  verify_wireguard
  verify_prereqs
  backup_and_update_config
  say ""
  say "[done] Proxy mode ready."
  say "  Enable:  $REPO_DIR/scripts/proxy-on.sh"
  say "  Disable: $REPO_DIR/scripts/proxy-off.sh"
  say "  Status:  $REPO_DIR/scripts/proxy-status.sh"
  say ""
  if prompt_yn "Install boot auto-start via systemd?"; then
    install_systemd_service
  fi
  if prompt_yn "Enable proxy now?"; then
    "$REPO_DIR/scripts/proxy-on.sh"
  fi
}

configure_both(){
  say "[info] Configuring both modes (DNS forwarding + proxy steering) ..."
  verify_wireguard
  verify_prereqs
  backup_and_update_config   # also sets LAN_DNS=$HOME_DOMAIN/$ADGUARD_IP in config.env
  verify_adguard
  say ""
  say "[done] Both mode configured."
  say "  LAN_DNS set in config.env — proxy-on.sh will forward ${HOME_DOMAIN:-arpa.home}"
  say "  to AdGuard @ ${ADGUARD_IP:-} when the proxy is active."
  say ""
  say "  Enable:  $REPO_DIR/scripts/proxy-on.sh"
  say "  Disable: $REPO_DIR/scripts/proxy-off.sh"
  say ""
  if prompt_yn "Install boot auto-start via systemd?"; then
    install_systemd_service
  fi
  if prompt_yn "Enable proxy now?"; then
    "$REPO_DIR/scripts/proxy-on.sh"
  fi
}

# --- main ---
say "[info] Client setup — mode: $MODE"

case "$MODE" in
  dns)   configure_dns ;;
  proxy) configure_proxy ;;
  both)  configure_both ;;
esac
