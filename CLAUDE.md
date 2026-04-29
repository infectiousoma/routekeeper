# Proxy - Selective Traffic Steering via DNS + iptables + SOCKS

## Project Purpose

This project routes traffic for specific services through a remote SOCKS5 proxy over WireGuard. Only DNS-matched traffic is steered; everything else goes direct.

The primary mode is **laptop mode**: steering for the local machine via `OUTPUT` chain iptables rules.

## Architecture Overview

```
   Steered service DNS query
          |
          v
  dnsmasq (Docker, host network)
  - resolves domain
  - adds resolved IPs to kernel ipsets (via ipset= directives in dnsmasq.d/ipsets.conf)
          |
          v
  iptables rules (nat OUTPUT)
  - match dst IP against ipset -> REDIRECT TCP to 127.0.0.1:REDPORT
  - match dst IP against ipset -> REJECT UDP/443 (kill QUIC, force TCP)
  - (IPv6) match against v6 ipsets -> REJECT (force IPv4 fallback)
          |
          v
  redsocks (Docker, host network, 127.0.0.1:REDPORT)
  - transparent proxy: accepts redirected TCP
  - forwards via SOCKS5 to Dante
          |
          v  (over WireGuard wg0)
  Dante SOCKS5 (YOUR_DANTE_IP:DANTE_PORT, remote server)
  - exits traffic with remote IP
```

## Key Configuration Values

All runtime-configurable values are in **`config.env`** (copied from `config.env.example`). Two app-specific config files cannot source shell variables — if you change `DANTE_IP`, `DANTE_PORT`, or `REDPORT` in `config.env`, update these files manually to match:
- `redsocks/redsocks.conf`
- `dante/sockd.conf`

`dnsmasq/dnsmasq.conf` is **fully generated** by `proxy-on.sh` from `config.env` on every startup — do not edit it manually. Domain-to-ipset rules go in `dnsmasq/dnsmasq.d/ipsets.conf`, which is also generated from `DOMAINS_*` and `IPSET_*` variables.

| Variable | Default | Purpose |
|---|---|---|
| `DANTE_IP` | _(your value)_ | Dante SOCKS5 server IP (WireGuard peer); also in redsocks.conf, sockd.conf |
| `DANTE_PORT` | `1080` | Dante SOCKS5 port; also in redsocks.conf, sockd.conf |
| `REDHOST` | `127.0.0.1` | redsocks local bind address; also in redsocks.conf |
| `REDPORT` | `12345` | redsocks local listen port; also in redsocks.conf |
| `DNSIP_LOOP` | `127.100.53.53` | dnsmasq loopback address (written into generated dnsmasq.conf) |
| `DNSIP_BRIDGE` | `172.17.0.1` | Docker bridge IP dnsmasq also listens on (written into generated dnsmasq.conf) |
| `LAN_DNS` | _(empty)_ | Optional: route a local domain to a LAN DNS server (format: `domain/ip`) |
| `IFACE` | _(your value)_ | WiFi interface name |
| `IPSET_V4_NFX` / `IPSET_V6_NFX` | `netflix_us` / `netflix_us6` | Service group 1 ipset names |
| `IPSET_V4_SORA` / `IPSET_V6_SORA` | `openai_us` / `openai_us6` | Service group 2 ipset names |
| `IPSET_V4_XF` / `IPSET_V6_XF` | `xfinity_us` / `xfinity_us6` | Service group 3 ipset names |
| `USE_IPV6` | `1` | Add targeted IPv6 REJECT rules to force v4 fallback |
| `BLOCK_QUIC` | `true` | Block UDP/443 to force TCP fallback through redsocks |
| `SELF_DNS` | `true` | Point `$IFACE` DNS to local dnsmasq on proxy-on |
| `RESTORE_ON_OFF` | `true` | Restore firewall baseline on proxy-off |
| `BASELINE_DIR` | `~/.proxy-firewall-baseline` | Where firewall snapshots are saved |
| `DNSMASQ_DIR` | `~/proxy/dnsmasq` | Path to dnsmasq compose directory |
| `REDSOCKS_DIR` | `~/proxy/redsocks` | Path to redsocks compose directory |
| `PRIME_TRIES` | `6` | DNS priming retry count at startup |
| `DOMAINS_NFX` | _(your domains)_ | Domains for service group 1 (primed + ipset-tagged) |
| `DOMAINS_SORA` | _(your domains)_ | Domains for service group 2 |
| `DOMAINS_XF` | _(your domains)_ | Domains for service group 3 |
| `DOMAINS_FOO` + `IPSET_V4_FOO` + `IPSET_V6_FOO` | _(any suffix)_ | Pattern for adding new groups — suffix must match across all three |

## Kernel ipsets

| ipset | Family | Populated by | Purpose |
|---|---|---|---|
| `$IPSET_V4_NFX` | inet | dnsmasq ipset= lines | Service group 1 (IPv4, for REDIRECT) |
| `$IPSET_V6_NFX` | inet6 | dnsmasq ipset= lines | Service group 1 (IPv6, for REJECT) |
| `$IPSET_V4_SORA` | inet | dnsmasq ipset= lines | Service group 2 (IPv4, for REDIRECT) |
| `$IPSET_V6_SORA` | inet6 | dnsmasq ipset= lines | Service group 2 (IPv6, for REJECT) |
| `$IPSET_V4_XF` | inet | dnsmasq ipset= lines | Service group 3 (IPv4, for REDIRECT) |
| `$IPSET_V6_XF` | inet6 | dnsmasq ipset= lines | Service group 3 (IPv6, for REJECT) |

Groups are auto-discovered at runtime: any `DOMAINS_FOO` with matching `IPSET_V4_FOO` and `IPSET_V6_FOO` in `config.env` is automatically included. No script changes needed to add a new group.

## File Map

### Root

| File | Role |
|---|---|
| `README.md` | User-facing setup and usage documentation |
| `config.env.example` | **Template** — copy to `config.env` and fill in values |
| `config.env` | **Single source of truth for all runtime config** (gitignored) |
| `proxy-primer.service` | Optional systemd user service for boot auto-start |
| `CLAUDE.md` | This file — architecture reference for AI-assisted development |

### `scripts/`

| File | Role |
|---|---|
| `proxy-on.sh` | **Main enable script**: generates ipsets.conf, starts dnsmasq + redsocks, creates ipsets, primes DNS, installs iptables rules |
| `proxy-off.sh` | **Main disable script**: removes iptables rules, restores firewall baseline, destroys ipsets, stops redsocks |
| `proxy-status.sh` | Diagnostic: DNS config, container status, ipset sizes, iptables rules |

### `redsocks/`

| File | Role |
|---|---|
| `Dockerfile` | Alpine + redsocks package |
| `docker-compose.yml` | Runs redsocks in host network mode |
| `redsocks.conf` | Listens on `127.0.0.1:REDPORT`, forwards to Dante at `YOUR_DANTE_IP:DANTE_PORT` via SOCKS5 |

### `dante/`

| File | Role |
|---|---|
| `docker-compose.yml` | Runs Dante (vimagick/dante) on the **remote server** in host network mode |
| `sockd.conf` | Binds to `YOUR_DANTE_IP:DANTE_PORT`, allows WireGuard subnet, exits via WAN interface |

### `dnsmasq/`

| File | Role |
|---|---|
| `docker-compose.yml` | Runs dnsmasq (`jpillora/dnsmasq`) in host network mode with `NET_ADMIN` cap |
| `dnsmasq.conf` | **Generated on every run** by `proxy-on.sh` from `config.env` (`DNSIP_LOOP`, `DNSIP_BRIDGE`, `LAN_DNS`). Gitignored. Do not edit manually. |
| `dnsmasq.d/ipsets.conf` | **Generated at startup** by `proxy-on.sh` from `DOMAINS_*` + `IPSET_*` in `config.env`. Gitignored. |

## Dependency Graph

```
proxy-on.sh
  |-- sources: config.env
  |-- generates: dnsmasq/dnsmasq.conf  (from DNSIP_LOOP, DNSIP_BRIDGE, LAN_DNS)
  |-- generates: dnsmasq/dnsmasq.d/ipsets.conf  (from DOMAINS_* + IPSET_* vars)
  |-- starts: dnsmasq/docker-compose.yml  (container: proxy-dnsmasq)
  |       |-- uses: dnsmasq/dnsmasq.conf + dnsmasq.d/ipsets.conf
  |-- starts: redsocks/docker-compose.yml  (container: redsocks)
  |       |-- uses: redsocks/redsocks.conf -> forwards to YOUR_DANTE_IP:DANTE_PORT
  |-- creates: kernel ipsets (6 sets — 2 per service group)
  |-- modifies: iptables (nat OUTPUT REDIRECT + filter OUTPUT REJECT for QUIC/IPv6)
  |-- modifies: host DNS via detect_dns_backend() → resolvectl | nmcli | /etc/resolv.conf
  |-- saves: ~/.proxy-firewall-baseline/ (first run only)

proxy-off.sh
  |-- sources: config.env
  |-- removes: iptables rules (all 3 service groups, v4 + v6)
  |-- restores: ~/.proxy-firewall-baseline/ (iptables + ipset)
  |-- restores: host DNS via backend saved in ~/.proxy-firewall-baseline/dns.backend
  |-- destroys: kernel ipsets (all 6)
  |-- stops: redsocks container (dnsmasq stays up — DNS continues to work)

Dante (remote server)
  |-- dante/docker-compose.yml + dante/sockd.conf
  |-- listens: YOUR_DANTE_IP:DANTE_PORT (reachable via WireGuard wg0)
  |-- exits: via YOUR_WAN_INTERFACE
```

## Start/Stop Lifecycle

### Enable
```bash
~/proxy/scripts/proxy-on.sh
```

**Sequence**: save firewall baseline → clean stale nft rules → **create ipsets** → **generate dnsmasq/dnsmasq.conf** → **generate dnsmasq/dnsmasq.d/ipsets.conf** → start dnsmasq container → detect DNS backend + set host DNS to `$DNSIP_LOOP` → **prime DNS lookups** → print ipset counts → verify first ipset non-empty → start redsocks container → install iptables rules → Dante connectivity test

### Priming explained

Priming is the startup phase between dnsmasq coming up and iptables rules going in. It has two parts:

**1. Ipset creation (`ensure_sets`)** — runs *before* dnsmasq starts. Critical: if dnsmasq starts and tries to write to a set that doesn't exist, it silently disables writes to that set for the lifetime of the process. The sets must exist first.

**2. DNS lookups (`prime_sets`)** — runs *after* dnsmasq is up. `dig` queries are sent directly to `$DNSIP_LOOP` (bypassing the system resolver) for every domain in all `DOMAINS_*` groups. Each query causes dnsmasq to resolve the domain and add the returned IPs to the matching kernel ipset. This pre-populates the sets so iptables rules have entries to match against immediately on startup.

After priming, entry counts for all sets are printed. If the first ipset is still empty, the script aborts — this catches misconfigurations.

### Disable
```bash
~/proxy/scripts/proxy-off.sh
```

**Sequence**: remove iptables rules (all 3 groups) → restore baseline firewall → **restore host DNS** (via saved backend) → **destroy all 6 proxy ipsets** → stop redsocks (dnsmasq left running)

### Auto-start on boot
```bash
mkdir -p ~/.config/systemd/user
cp ~/proxy/proxy-primer.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable proxy-primer.service
```

## Quirks and Assumptions

1. **DNS backend detection**: `set_iface_dns` auto-detects the resolver in use via `detect_dns_backend()`: tries `resolvectl` (systemd-resolved) first, falls back to `nmcli` (NetworkManager), then falls back to direct `/etc/resolv.conf` edit. The chosen backend is saved to `$BASELINE_DIR/dns.backend` so `proxy-off.sh` can restore using the same method. This makes the scripts portable across Debian/Ubuntu/Arch systems where systemd-resolved may not be installed or active.

2. **Generated dnsmasq config**: Both `dnsmasq/dnsmasq.conf` and `dnsmasq/dnsmasq.d/ipsets.conf` are generated fresh on every `proxy-on.sh` run from `config.env`. Both are gitignored. Do not edit `dnsmasq.conf` manually — changes will be overwritten at next startup.

3. **IPv6 strategy**: Rather than proxying IPv6, the system **blocks** IPv6 for steered services (REJECT in ip6tables OUTPUT) to force applications to fall back to IPv4, which then gets caught by the NAT REDIRECT. Global `filter-aaaa` in dnsmasq breaks other services (Jellyfin, YouTube, etc.) — do not use it.

4. **QUIC must be blocked**: Streaming and other services will use QUIC (UDP/443) if available, which bypasses the TCP-only redsocks redirect. The REJECT rule forces TCP fallback.

5. **DoH/DoT bypasses everything**: If a browser uses DNS-over-HTTPS, queries never hit dnsmasq, ipsets stay empty, and nothing gets redirected. Users must disable Secure DNS in their browser.

6. **dnsmasq stays running on proxy-off**: By design, so the host still has local DNS caching after the proxy is disabled. Only redsocks is stopped.

7. **Baseline firewall snapshots are write-once**: Saved on first `proxy-on.sh` run. To update after changing your normal firewall, manually re-save:
   ```bash
   sudo iptables-save  > ~/.proxy-firewall-baseline/iptables.v4
   sudo ip6tables-save > ~/.proxy-firewall-baseline/ip6tables.v6
   sudo ipset save     > ~/.proxy-firewall-baseline/ipset.save
   ```

8. **dnsmasq force-recreates on every proxy-on**: The container is always recreated (`--force-recreate`) to ensure it loads the freshly generated `ipsets.conf`. This adds ~2 seconds to startup.

9. **config.env is shell-only**: `redsocks/redsocks.conf` and `dante/sockd.conf` use app-specific formats and cannot source shell variables. If you change `DANTE_IP`, `DANTE_PORT`, or `REDPORT` in `config.env`, update those two files manually to match. `dnsmasq/dnsmasq.conf` is fully generated by `proxy-on.sh` from `config.env` — no manual sync needed.

## Common Operations

```bash
# Verify Dante is reachable
curl --max-time 5 --socks5 "$DANTE_IP:$DANTE_PORT" https://api.ipify.org

# Check ipset contents
sudo ipset list "$IPSET_V4_NFX" | tail -20

# Check iptables rules
sudo iptables -t nat -vnL OUTPUT
sudo ip6tables -vnL OUTPUT

# View generated dnsmasq ipset rules
cat ~/proxy/dnsmasq/dnsmasq.d/ipsets.conf

# Prime ipsets manually
dig +short @"$DNSIP_LOOP" A yourservice.example.com

# View dnsmasq logs
docker logs --tail=100 proxy-dnsmasq

# Restart dnsmasq after config change
cd ~/proxy/dnsmasq && docker compose up -d --force-recreate
```
