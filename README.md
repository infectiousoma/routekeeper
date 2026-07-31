# Selective Traffic Steering via DNS + iptables + SOCKS5

Routes traffic for specific services through a remote SOCKS5 proxy over WireGuard. Everything else goes direct.

**How it works:**
- **dnsmasq** (Docker) resolves configured domains and tags their IPs into kernel ipsets
- **iptables** redirects TCP to those IPs → **redsocks** (local) → **Dante** SOCKS5 (remote, via WireGuard `wg0`)
- IPv6 for steered services is blocked (REJECT), forcing IPv4 fallback through the proxy
- UDP/443 (QUIC) for steered services is blocked, forcing TCP fallback through redsocks

> Nothing else is tunneled. Only IPs in the configured ipsets are steered through the proxy.

---

## Deployment modes

Three modes are supported. Choose one based on what you need:

| Mode | What it does |
|---|---|
| **dns** | Local dnsmasq forwards `HOME_DOMAIN` (e.g. `arpa.home`) to AdGuard Home on your server. All traffic goes via local ISP. No proxy. |
| **proxy** | Selective traffic steering via SOCKS5 proxy (existing behaviour). |
| **both** | DNS forwarding to AdGuard + proxy steering for configured domains. |

## Setup

```bash
# 1. Clone the repo
git clone <repo-url> ~/proxy
cd ~/proxy

# 2. Create your config
cp config.env.example config.env
# Edit config.env — set DANTE_IP / ADGUARD_IP, IFACE, DEPLOY_MODE, and your DOMAINS_*

# 3. Run server setup on your home server (once)
~/proxy/scripts/server-setup.sh --mode dns   # or proxy or both

# 4. Run client setup on your laptop (once)
~/proxy/scripts/client-setup.sh --mode dns   # or proxy or both
```

### Manual setup (proxy mode only, existing behaviour)

```bash
# Update dante/sockd.conf on your remote server with your WireGuard IP, WAN interface, subnet
# Then enable:
~/proxy/scripts/proxy-on.sh
```

---

## Daily use

```bash
# Enable
~/proxy/scripts/proxy-on.sh

# Status
~/proxy/scripts/proxy-status.sh

# Disable
~/proxy/scripts/proxy-off.sh
```

After `proxy-off.sh`: dnsmasq stays running so DNS continues to work. Only the iptables rules, ipsets, and redsocks are torn down.

---

## Configuration

All runtime values are in **`~/proxy/config.env`** (copied from `config.env.example`). Key values:

| Setting | Purpose |
|---|---|
| `DANTE_IP` / `DANTE_PORT` | Dante SOCKS5 server (remote, via WireGuard) |
| `REDPORT` | redsocks local listener port |
| `DNSIP_LOOP` | dnsmasq loopback address |
| `IFACE` | WiFi interface name |
| `DNS_UPSTREAM` / `DNS_FALLBACK` | Upstream resolvers dnsmasq forwards to |
| `DOMAINS_NFX` / `DOMAINS_SORA` / `DOMAINS_XF` | Domain lists for the built-in service groups |

Only one config file requires manual editing — `dante/sockd.conf` on your remote server (it needs your WireGuard IP, WAN interface, and subnet, which vary per machine).

`redsocks/redsocks.conf`, `dnsmasq/dnsmasq.conf`, and `dnsmasq/dnsmasq.d/ipsets.conf` are all generated automatically from `config.env` each time `proxy-on.sh` runs. You never edit them directly.

To route a local domain through your LAN DNS server (e.g. for `.home.arpa` hostnames), set `LAN_DNS` in `config.env`:
```
LAN_DNS="home.arpa/192.168.0.99"
```

### Choosing an upstream resolver

dnsmasq must stay in the resolution path (it populates the ipsets), but where it forwards queries is up to you via `DNS_UPSTREAM` / `DNS_FALLBACK`:

- **Public resolver** (default): `DNS_UPSTREAM=9.9.9.9` — plain DNS to Quad9.
- **AdGuard Home over WireGuard**: point at your server's WireGuard IP (e.g. `DNS_UPSTREAM=10.0.2.7`). Filtered, but every lookup rides the tunnel.
- **AdGuard DNS (the hosted service) via AdGuardDNSCLI**: run AdGuard's official client daemon locally and use it as dnsmasq's upstream. Queries go out encrypted (DoH) directly over your WAN — no WireGuard dependency for DNS. See below.

dnsmasq accepts `IP#port` syntax in these variables (e.g. `DNS_UPSTREAM=127.0.0.153#5353`) if your upstream listens on a non-standard port.

### Using AdGuard DNS via AdGuardDNSCLI

[AdGuardDNSCLI](https://adguard-dns.io/kb/) is AdGuard's client daemon for connecting a device to your AdGuard DNS account. The chain becomes:

```
apps → dnsmasq (ipset tagging) → AdGuardDNSCLI (127.0.0.153:53) → AdGuard DNS (DoH)
```

1. In the AdGuard DNS dashboard, add a device and copy its **DNS-over-HTTPS** address — it looks like `https://d.adguard-dns.com/dns-query/<device_id>`. (The dashboard also lists DoT `tls://<id>.d.adguard-dns.com` and DoQ `quic://<id>.d.adguard-dns.com` addresses for the same device; any of them works in the config below, DoH is the safe default.)

2. Download and unpack the CLI from its releases page, then install it as a service:
   ```bash
   ./adguarddns-cli -s install -v
   ```

3. Edit its `config.yaml`:
   - `dns.server.listen_addresses`: replace the auto-generated list (it binds every interface and will collide with dnsmasq on `172.17.0.1:53` and anything else on port 53) with a single dedicated loopback:
     ```yaml
     listen_addresses:
         - address: 127.0.0.153:53
     ```
   - `dns.upstream.groups.default.address`: your device's DoH address from step 1.

4. Start it and verify:
   ```bash
   ./adguarddns-cli -s start -v
   nslookup example.com 127.0.0.153
   ```

5. In `config.env`:
   ```env
   DNS_UPSTREAM=127.0.0.153
   DNS_FALLBACK=9.9.9.9
   ```
   With a public fallback, DNS keeps working if the daemon dies — but those queries leak unfiltered. Set `DNS_FALLBACK=127.0.0.153` instead to hard-fail.

6. Re-run `~/proxy/scripts/proxy-on.sh` to regenerate `dnsmasq.conf`. Lookups should now appear under your device in the AdGuard DNS dashboard.

Notes: `LAN_DNS` still routes your home domain wherever you point it — only the default upstream changes. dnsmasq's cache sits in front of the daemon, which also keeps you further under the plan's monthly query cap.

### Adding a new service group

Add three lines to `config.env` — the suffix must match across all three:

```env
DOMAINS_FOO="${DOMAINS_FOO:-example.com api.example.com}"
IPSET_V4_FOO="${IPSET_V4_FOO:-foo_us}"
IPSET_V6_FOO="${IPSET_V6_FOO:-foo_us6}"
```

That's it. `proxy-on.sh` auto-discovers any `DOMAINS_*` variable that has matching `IPSET_V4_*` and `IPSET_V6_*` variables (same suffix). No script changes needed.

---

## Ipsets

| Ipset | Family | Content |
|---|---|---|
| `netflix_us` / `netflix_us6` | inet / inet6 | Service group 1 (DOMAINS_NFX) |
| `openai_us` / `openai_us6` | inet / inet6 | Service group 2 (DOMAINS_SORA) |
| `xfinity_us` / `xfinity_us6` | inet / inet6 | Service group 3 (DOMAINS_XF) |

Names are configurable via `IPSET_V4_NFX`, `IPSET_V4_SORA`, `IPSET_V4_XF` (and their `_V6_` counterparts) in `config.env`. Additional groups can be added — see [Adding a new service group](#adding-a-new-service-group) above.

---

## Startup sequence

`proxy-on.sh` does the following in order:

1. Saves firewall baseline (write-once: `~/.proxy-firewall-baseline/`)
2. Cleans stale nft rules referencing old ipset names
3. **Creates ipsets** (before dnsmasq starts — critical ordering)
4. **Generates `dnsmasq/dnsmasq.conf`** from `config.env` (`DNSIP_LOOP`, `DNSIP_BRIDGE`, `LAN_DNS`)
5. **Generates `dnsmasq/dnsmasq.d/ipsets.conf`** from `DOMAINS_*` and `IPSET_*` in `config.env`
6. Starts dnsmasq container (picks up both generated files)
7. **Points `$IFACE` DNS to local dnsmasq** — auto-detects resolver: `resolvectl` (systemd-resolved) → `nmcli` (NetworkManager) → `/etc/resolv.conf`
8. **Primes ipsets** — runs `dig` against dnsmasq for every domain in all `DOMAINS_*` groups to pre-populate the sets
9. Prints entry counts for all sets; aborts if the first ipset is still empty
10. Starts redsocks container
11. Installs iptables rules (NAT REDIRECT + QUIC block + IPv6 REJECT)
12. Runs a Dante connectivity test

---

## Verify the proxy is working

```bash
# Dante is reachable over WireGuard
curl --max-time 5 --socks5 YOUR_DANTE_IP:1080 https://api.ipify.org; echo   # should show remote IP

# Ipsets are populated
sudo ipset list netflix_us | awk '/Number of entries/{print}'
sudo ipset list openai_us  | awk '/Number of entries/{print}'
sudo ipset list xfinity_us | awk '/Number of entries/{print}'

# Redirect rules are installed
sudo iptables -t nat -vnL OUTPUT | grep "$REDPORT"

# Traffic is flowing over wg0
sudo tcpdump -ni wg0 port 1080 -c 10
```

---

## Troubleshooting

**1. Ipsets empty after proxy-on**

Ipsets must exist before dnsmasq starts — if the sets were missing at startup, dnsmasq silently disables writes to them for the lifetime of the process. Stop the proxy, run `proxy-on.sh` again (it recreates everything in the correct order).

Check dnsmasq is answering:
```bash
dig +short @127.100.53.53 A yourservice.example.com
```

Check dnsmasq logs:
```bash
docker logs --tail=100 proxy-dnsmasq
```

Check generated ipset rules:
```bash
cat ~/proxy/dnsmasq/dnsmasq.d/ipsets.conf
```

**2. Still seeing home IP for steered services**

- **DNS-over-HTTPS in browser** — bypasses dnsmasq entirely; ipsets never get populated. Disable Secure DNS in Chrome/Edge/Firefox.
- **IPv6 fallback not blocked** — check ip6tables has REJECT rules:
  ```bash
  sudo ip6tables -vnL OUTPUT | grep match-set
  ```
- **QUIC not blocked** — check the UDP/443 REJECT rule:
  ```bash
  sudo iptables -vnL OUTPUT | grep 443
  ```

**3. Redirect rule not matching**

The NAT REDIRECT must be near the top of the OUTPUT chain. `proxy-on.sh` inserts with `-I OUTPUT 1`. Check:
```bash
sudo iptables -t nat -vnL OUTPUT --line-numbers | head -20
```

**4. redsocks not listening**

```bash
ss -ltnp | grep "$REDPORT"
docker logs --tail=50 redsocks
```
Most common cause: syntax error in `redsocks/redsocks.conf` (no inline `#` comments allowed in redsocks config format).

**5. `resolvectl: command not found`**

`resolvectl` requires `systemd-resolved`, which isn't installed by default on all distros (e.g. Debian). The scripts auto-detect the resolver — if `systemd-resolved` isn't running it falls back to `nmcli` (NetworkManager), then to editing `/etc/resolv.conf` directly. No action needed; set `SELF_DNS=true` in `config.env` and the right backend will be used automatically.

---

**6. Jellyfin or YouTube broke**

Do **not** add `filter-aaaa` to dnsmasq.conf — it strips AAAA records globally and breaks IPv6-dependent services. The targeted ip6tables REJECT approach (used here) blocks only steered service IPs and leaves everything else on normal IPv6.

---

## Managing the firewall baseline

The first time `proxy-on.sh` runs, it saves your current firewall to:
```
~/.proxy-firewall-baseline/iptables.v4
~/.proxy-firewall-baseline/ip6tables.v6
~/.proxy-firewall-baseline/ipset.save
```

`proxy-off.sh` restores from these. The snapshots are **write-once** — if you change your normal firewall later, re-save manually:
```bash
sudo iptables-save  > ~/.proxy-firewall-baseline/iptables.v4
sudo ip6tables-save > ~/.proxy-firewall-baseline/ip6tables.v6
sudo ipset save     > ~/.proxy-firewall-baseline/ipset.save
```

---

## Auto-start on boot (optional)

```bash
mkdir -p ~/.config/systemd/user
cp ~/proxy/proxy-primer.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable proxy-primer.service
```

---

## Files

```
config.env.example          # template — copy to config.env and fill in values
config.env                  # your real config (gitignored)
proxy-primer.service        # optional systemd user service for boot auto-start
scripts/
  server-setup.sh           # one-time server installer (--mode dns|proxy|both)
  client-setup.sh           # one-time client installer (--mode dns|proxy|both)
  proxy-on.sh               # enable proxy (runtime toggle)
  proxy-off.sh              # disable proxy (runtime toggle)
  proxy-status.sh           # diagnostics
dnsmasq/
  docker-compose.yml        # runs proxy-dnsmasq container
  dnsmasq.conf              # generated at startup by proxy-on.sh (gitignored)
  dnsmasq.d/
    ipsets.conf             # generated at startup by proxy-on.sh (gitignored)
redsocks/
  docker-compose.yml        # runs redsocks container
  redsocks.conf.example     # format reference (real redsocks.conf is generated at startup)
  redsocks.conf             # generated at startup by proxy-on.sh (gitignored)
dante/
  docker-compose.yml        # runs Dante on your remote server
  sockd.conf                # listens on YOUR_DANTE_IP, exits via YOUR_WAN_INTERFACE
```
