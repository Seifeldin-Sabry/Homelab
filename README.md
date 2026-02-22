# Homelab

Self-hosted media and infrastructure stack running on Proxmox VE, powered by Docker containers behind Caddy reverse proxy with CrowdSec WAF, automated TLS, private DNS filtering via AdGuard Home, WireGuard VPN tunneling, and automated backups via Borgmatic and Proxmox Backup Server.

## Architecture

```
Internet
    |
[Router 192.168.128.1]
    |
[PVE Host - 192.168.129.200] ── vmbr0 (LAN bridge)
    |           |
    |       [vmbr1 - 10.10.10.0/24] (private NAT bridge)
    |           |       |       |       |
    |       CT 101    CT 102   CT 103  CT 104
    |       AdGuard   Tailscale AdGuard PBS
    |       Primary   VPN      Replica Backup
    |       .2        .5       .3      .4
    |
[VM 100 - Docker Host - 192.168.129.10]
    |
    ├── Infra Stack
    |   ├── CrowdSec (security engine + log analysis)
    |   ├── Caddy (reverse proxy + auto TLS + CrowdSec bouncer)
    |   ├── Homepage (dashboard)
    |   ├── Uptime Kuma (monitoring)
    |   └── AdGuard Home Sync
    |
    ├── Media Stack
    |   ├── Gluetun (WireGuard VPN gateway)
    |   ├── qBittorrent (torrent client, routed through VPN)
    |   ├── Sonarr (TV show management)
    |   ├── Radarr (movie management)
    |   ├── Prowlarr (indexer management)
    |   ├── Bazarr (subtitle management)
    |   ├── Jellyfin (media streaming)
    |   ├── Jellyseerr (media requests)
    |   └── Recyclarr (quality profile sync)
    |
    └── Backup Stack
        └── Borgmatic (nightly borg backup of all Docker configs)
```

## Network Design

The ISP router enforces strict IP-MAC binding, dropping traffic from virtual MACs. To work around this:

- **vmbr0**: LAN bridge — only the PVE host and VM 100 (with a real-looking MAC) use this
- **vmbr1**: Private bridge (10.10.10.0/24) with NAT — all LXC containers live here
- **DNS forwarding**: iptables DNAT on the PVE host forwards port 53 traffic to AdGuard (CT 101)
- **AdGuard web UIs**: port-forwarded via iptables (host:3002 -> primary, host:3003 -> replica)
- **PBS web UI**: port-forwarded via iptables (host:8007 -> CT 104)

## Hardware

| Component | Spec |
|-----------|------|
| CPU | 16 cores |
| RAM | 30 GB |
| Boot SSD | 94 GB |
| VM SSD | 120 GB |
| Media HDD | 4 TB USB (NFS to VM 100, bind-mount to CT 104) |

## Services

| Service | URL | Purpose |
|---------|-----|---------|
| Homepage | `homepage.homelab.{domain}` | Dashboard with live widgets |
| Jellyfin | `jellyfin.homelab.{domain}` | Media streaming |
| Jellyseerr | `jellyseerr.homelab.{domain}` | Media request portal |
| Sonarr | `sonarr.homelab.{domain}` | TV show automation |
| Radarr | `radarr.homelab.{domain}` | Movie automation |
| Prowlarr | `prowlarr.homelab.{domain}` | Indexer management |
| Bazarr | `bazarr.homelab.{domain}` | Subtitle automation |
| qBittorrent | `qbit.homelab.{domain}` | Torrent client (VPN-routed) |
| Uptime Kuma | `status.homelab.{domain}` | Service monitoring |
| PBS | `pbs.homelab.{domain}` | Proxmox Backup Server |
| AdGuard Home | `{host}:3002` / `{host}:3003` | DNS filtering (primary + replica) |

All services use HTTPS with auto-provisioned Let's Encrypt certificates via Caddy + Cloudflare DNS challenge, protected by CrowdSec WAF.

## Backup Strategy

| What | Tool | Schedule | Target |
|------|------|----------|--------|
| Docker volume configs | Borgmatic (borg) | Daily 3:00 AM | USB HDD (`/mnt/media/backups/borg`) |
| VMs & CTs | vzdump → PBS | Daily 2:00 AM | USB HDD (`/mnt/media/pbs`) |

PBS retention: keep-daily=3, keep-weekly=2, keep-monthly=1. Borgmatic retention: keep-daily=7, keep-weekly=4, keep-monthly=6.

## Quick Start

### Prerequisites

- Proxmox VE 9.x host
- Cloudflare-managed domain
- ProtonVPN (or any WireGuard-compatible VPN)
- USB HDD for media storage and backups

### 1. PVE Network Setup

Copy `pve/interfaces` to `/etc/network/interfaces` and adjust IPs as needed.

### 2. Create LXC Containers

Use the configs in `pve/lxc/` as reference for creating containers 101-104.

### 3. Create VM 100

Use `pve/vm/100.conf` as reference. Install Debian/Ubuntu, set up Docker.

### 4. Deploy Stacks

```bash
# Copy .env.example files and fill in your secrets
cp stacks/infra/.env.example stacks/infra/.env
cp stacks/media/.env.example stacks/media/.env
cp stacks/backup/.env.example stacks/backup/.env

# Deploy
cd /opt/stacks/infra && docker compose up -d
cd /opt/stacks/media && docker compose up -d
cd /opt/stacks/backup && docker compose up -d
```

### 5. Post-Deploy Wiring

- CrowdSec: register the Caddy bouncer with `cscli bouncers add caddy-bouncer` and add the API key to `.env`
- Borgmatic: initialize the borg repo with `docker compose run --rm --entrypoint '' borgmatic borg init --encryption repokey-blake2 /mnt/borg-repo`
- PBS: install `proxmox-backup-server` in CT 104, create datastore, add as PVE storage with `pvesm add pbs`
- Recyclarr syncs quality profiles automatically
- Service interconnections (Prowlarr -> Sonarr/Radarr, etc.) need to be configured via their web UIs

## Monitoring

- `pve/scripts/homelab-health.sh` runs every minute via cron on the PVE host
- Checks: DNS (CT 101/103), container status (101-104), VM 100, USB HDD, NFS, kernel errors
- Escalating memory response: warn at 85% -> restart heaviest container at 90% -> reboot VM 100 after 5min
- Alerts via Telegram bot

## Tech Stack

`Proxmox VE` `Docker` `Caddy` `CrowdSec` `WireGuard` `AdGuard Home` `Tailscale` `Cloudflare` `Let's Encrypt` `BorgBackup` `Proxmox Backup Server`
