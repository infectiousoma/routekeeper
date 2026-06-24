# Deployment Guide

This guide covers every supported deployment style: which components run where, how to set them up, and when to use each.

---

## Architecture Overview

```
  Laptop (Thailand)                      Home Server (US)
  ─────────────────                      ────────────────
  dnsmasq (Docker)                       AdGuard Home
    │  resolves HOME_DOMAIN ──────────────→ DNS queries over WireGuard
    │  resolves all other DNS ──────────────→ upstream (9.9.9.9 etc.)
    │  (selective mode) populates ipsets
    │
  iptables OUTPUT chain
    │  selective:   match ipset → REDIRECT → redsocks
    │  transparent: all TCP    → REDIRECT → redsocks
    │  gateway:     default route via wg0
    │
  redsocks (Docker)                      Dante SOCKS5 (Docker)
    └─────────────────────────────────────→ SOCKS5 over WireGuard wg0
                                               └─→ exits via server WAN IP

                              ┌── Linode Tokyo VPS (WireGuard hub) ──┐
  Laptop wg0 ─────────────────┤                                       ├──── Server wg0
                              └───────────────────────────────────────┘
```

Key points:
- WireGuard hub (Linode Tokyo) keeps both endpoints' public IPs private
- Only traffic you choose is routed through the server — local ISP handles everything else
- DNS always goes over WireGuard to AdGuard on the server (tiny overhead)
- iptables rules live on the **laptop** (OUTPUT chain), never on the server

---

## Two Axes of Configuration

### 1. Deploy mode — what DNS does

| Mode | What dnsmasq does | Dante needed? |
|---|---|---|
| `dns` | Forwards `HOME_DOMAIN` to AdGuard; upstream DNS for everything else | No (optional) |
| `proxy` | Populates ipsets for steered domains (current behaviour); no AdGuard | Yes |
| `both` | AdGuard forwarding for `HOME_DOMAIN` + ipset population for steered domains | Yes |

Set in `config.env`: `DEPLOY_MODE=dns|proxy|both`

### 2. Routing mode — how traffic is steered

| Mode | What iptables does | Dante + redsocks needed? |
|---|---|---|
| `selective` | Redirect only ipset-matched IPs to redsocks (default) | Yes |
| `transparent` | Redirect all TCP to redsocks (private nets + WireGuard peer excluded) | Yes |
| `gateway` | Add default route via wg0 — all traffic over WireGuard | No (server does NAT) |

Set in `config.env`: `ROUTING_MODE=selective|transparent|gateway`
Override per-run: `proxy-on.sh --routing transparent`

---

## Deployment Styles

### Style 1 — DNS only (no proxy)

**Use when**: You want AdGuard ad-blocking and `*.arpa.home` resolution from anywhere, but don't need to route traffic through your US server.

**What runs where**:
- Server: AdGuard Home (already running)
- Laptop: local dnsmasq → forwards `arpa.home` to AdGuard; everything else goes direct

**Config**:
```bash
DEPLOY_MODE=dns
ADGUARD_IP=<server WireGuard IP>
HOME_DOMAIN=arpa.home
```

**Setup**:
```bash
# Server (one-time)
~/proxy/scripts/server-setup.sh --mode dns

# Laptop (one-time)
~/proxy/scripts/client-setup.sh --mode dns
```

**Result**: All browsing goes over local ISP. DNS resolves via AdGuard (ad-blocked, `*.arpa.home` works). No iptables rules. No redsocks.

---

### Style 2 — DNS + explicit SOCKS5 proxy (optional)

**Use when**: You want AdGuard DNS and also want to occasionally route specific apps through your US server manually (browser proxy setting), without any automatic traffic steering.

**What runs where**:
- Server: AdGuard Home + Dante SOCKS5
- Laptop: local dnsmasq → AdGuard; no iptables; apps manually configured to use Dante

**Config**:
```bash
DEPLOY_MODE=dns
ADGUARD_IP=<server WireGuard IP>  # same as DANTE_IP
DANTE_IP=<server WireGuard IP>
DANTE_PORT=1080
HOME_DOMAIN=arpa.home
```

**Setup**:
```bash
# Server (one-time)
~/proxy/scripts/server-setup.sh --mode both   # starts both AdGuard check + Dante

# Laptop (one-time)
~/proxy/scripts/client-setup.sh --mode dns    # starts dnsmasq only
```

**Configure browser/app manually**: Set SOCKS5 proxy to `<DANTE_IP>:<DANTE_PORT>` (reachable because WireGuard is always up). No redsocks needed — connect directly to Dante over the tunnel.

**Result**: All traffic goes local ISP by default. DNS via AdGuard. Specific apps routed via Dante when you configure them.

---

### Style 3 — Selective proxy (current setup, classic mode)

**Use when**: You want specific domains (Netflix, OpenAI, etc.) transparently routed through your US server without touching browser settings. Everything else goes local.

**What runs where**:
- Server: Dante SOCKS5
- Laptop: dnsmasq + ipsets + iptables + redsocks

**Config**:
```bash
DEPLOY_MODE=proxy
ROUTING_MODE=selective
DANTE_IP=<server WireGuard IP>
DOMAINS_NFX="netflix.com nflxso.net ..."
IPSET_V4_NFX=netflix_us
IPSET_V6_NFX=netflix_us6
# ... other service groups
```

**Setup**:
```bash
# Server (one-time)
~/proxy/scripts/server-setup.sh --mode proxy

# Laptop (one-time)
~/proxy/scripts/client-setup.sh --mode proxy
```

**Runtime toggle**:
```bash
~/proxy/scripts/proxy-on.sh       # enable
~/proxy/scripts/proxy-off.sh      # disable
~/proxy/scripts/proxy-status.sh   # check
```

---

### Style 4 — DNS + selective proxy (recommended full setup)

**Use when**: You want both — AdGuard DNS for ad-blocking and `*.arpa.home` access, AND selective transparent routing of specific domains.

**What runs where**:
- Server: AdGuard Home + Dante SOCKS5
- Laptop: dnsmasq (AdGuard upstream for `arpa.home` + ipsets for steered domains) + redsocks + iptables

**Config**:
```bash
DEPLOY_MODE=both
ROUTING_MODE=selective
ADGUARD_IP=<server WireGuard IP>
DANTE_IP=<server WireGuard IP>    # same host
HOME_DOMAIN=arpa.home
LAN_DNS=arpa.home/<ADGUARD_IP>   # set by client-setup.sh --mode both
DOMAINS_NFX="..."
```

**Setup**:
```bash
# Server (one-time)
~/proxy/scripts/server-setup.sh --mode both

# Laptop (one-time)
~/proxy/scripts/client-setup.sh --mode both
```

**Runtime toggle**:
```bash
~/proxy/scripts/proxy-on.sh    # starts everything: dnsmasq + redsocks + iptables
~/proxy/scripts/proxy-off.sh   # tears down rules; dnsmasq stays up
```

---

### Style 5 — Transparent proxy (all TCP via Dante)

**Use when**: You want everything to exit from your US server — not just specific domains. No per-domain config. Any site you visit appears to come from your home IP.

**What runs where**: Same as selective, but iptables redirects all TCP instead of ipset-matched IPs.

**Config**:
```bash
ROUTING_MODE=transparent
DANTE_IP=<server WireGuard IP>
TRANSPARENT_EXCLUDE=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
```

**Enable**:
```bash
~/proxy/scripts/proxy-on.sh --routing transparent
# or set ROUTING_MODE=transparent in config.env and run proxy-on.sh
```

**Disable**:
```bash
~/proxy/scripts/proxy-off.sh   # detects saved mode, cleans up correctly
```

**Note**: DNS traffic is UDP (not redirected). Local/private network traffic is excluded. The WireGuard peer IP (`DANTE_IP`) is always excluded to prevent routing loops.

---

### Style 6 — WireGuard gateway (all traffic over WireGuard)

**Use when**: You want your laptop to fully appear to be on your home network — all traffic (TCP + UDP + ICMP) exits from your home server's WAN IP. Most complete tunnel option.

**What runs where**:
- Server: must have IP forwarding enabled + iptables MASQUERADE on WAN interface
- Laptop: `ip route` default via wg0 (no redsocks needed)

**Server setup** (one-time, requires `WAN_IFACE` in config.env):
```bash
~/proxy/scripts/server-setup.sh --mode proxy --routing gateway
```

This runs on the **server**:
```bash
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -o <WAN_IFACE> -j MASQUERADE
```

Make persistent on server (add to `/etc/sysctl.conf`):
```
net.ipv4.ip_forward=1
```

Also make the MASQUERADE rule persistent (via iptables-persistent or your distro's firewall tool).

**WireGuard config**: Your laptop's `[Peer]` section in `wg0.conf` must include `0.0.0.0/0` in `AllowedIPs`:
```ini
[Peer]
PublicKey = <server public key>
Endpoint = <linode-hub>:51820
AllowedIPs = 0.0.0.0/0, ::/0
```

**Enable**:
```bash
~/proxy/scripts/proxy-on.sh --routing gateway
```

**Disable**:
```bash
~/proxy/scripts/proxy-off.sh   # removes the default route via wg0
```

---

## Quick Reference

### Routing mode comparison

| | Selective | Transparent | Gateway |
|---|---|---|---|
| What's routed | Specific domains only | All TCP | Everything |
| Requires redsocks | Yes | Yes | No |
| Requires server NAT | No | No | Yes |
| Per-domain config needed | Yes | No | No |
| UDP routed | No | No | Yes |
| QUIC blocked | Optional | Optional | N/A |

### One-off routing mode override

You can override `ROUTING_MODE` for a single session without changing `config.env`:

```bash
# Route everything this session
~/proxy/scripts/proxy-on.sh --routing transparent

# Use gateway mode this session
~/proxy/scripts/proxy-on.sh --routing gateway

# Back to selective
~/proxy/scripts/proxy-off.sh
~/proxy/scripts/proxy-on.sh --routing selective
```

`proxy-off.sh` always reads the mode that was saved at `proxy-on.sh` time, so teardown is always correct regardless of which flag was used.

---

## Configuration Reference

| Variable | Default | Purpose |
|---|---|---|
| `DEPLOY_MODE` | `proxy` | Default for setup scripts: `dns`, `proxy`, `both` |
| `ROUTING_MODE` | `selective` | Traffic steering: `selective`, `transparent`, `gateway` |
| `ADGUARD_IP` | _(your value)_ | AdGuard Home server WireGuard IP (typically same as `DANTE_IP`) |
| `ADGUARD_PORT` | `53` | AdGuard DNS port |
| `HOME_DOMAIN` | `arpa.home` | Local domain AdGuard is authoritative for |
| `DANTE_IP` | _(your value)_ | Dante SOCKS5 server WireGuard IP |
| `DANTE_PORT` | `1080` | Dante SOCKS5 port |
| `TRANSPARENT_EXCLUDE` | `10.0.0.0/8,...` | Nets excluded from transparent mode redirect |
| `WAN_IFACE` | _(your value)_ | Server WAN interface for gateway mode MASQUERADE |
| `DOMAINS_*` | _(your domains)_ | Domain lists for selective routing service groups |
| `IPSET_V4_*` / `IPSET_V6_*` | _(your names)_ | Kernel ipset names per service group |
| `DNSIP_LOOP` | `127.100.53.53` | dnsmasq loopback address |
| `IFACE` | _(your value)_ | Laptop WiFi/primary interface |
| `LAN_DNS` | _(empty)_ | dnsmasq server override: `domain/ip` (set by client-setup --mode both) |

---

## Troubleshooting

**DNS for `*.arpa.home` not resolving**
- Check WireGuard is up: `wg show`
- Check AdGuard reachable: `dig +short @$ADGUARD_IP -p $ADGUARD_PORT version.bind CHAOS TXT`
- Check dnsmasq forwarding: `dig +short @$DNSIP_LOOP arpa.home NS`
- Check dnsmasq logs: `docker logs --tail=50 proxy-dnsmasq`

**Transparent mode: local network broken**
- Your local subnet must be in `TRANSPARENT_EXCLUDE`
- Default excludes RFC1918 (`10/8`, `172.16/12`, `192.168/16`); add your specific subnet if different

**Gateway mode: no internet after enabling**
- Check WireGuard `AllowedIPs` includes `0.0.0.0/0`
- Check server has `ip_forward=1`: `sysctl net.ipv4.ip_forward`
- Check server MASQUERADE rule: `sudo iptables -t nat -vnL POSTROUTING`
- Check default route: `ip route show default`

**Selective mode: sites still appearing as local IP**
- Browser DNS-over-HTTPS bypasses dnsmasq — disable Secure DNS in browser settings
- Check ipsets populated: `sudo ipset list $IPSET_V4_NFX | awk '/Number of entries/{print}'`
- Check iptables rule: `sudo iptables -t nat -vnL OUTPUT | grep REDIRECT`
