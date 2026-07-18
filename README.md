# OpenBox — Self-Hosted Privacy Stack

The easiest, most user-friendly self-hosting stack. One command to install, no API key copy-pasting.

```
curl -fsSL https://openbox.crushcodeworks.com/install.sh | bash
```

## What's Inside

40+ pre-configured modules — no config files to edit, no API keys to hunt down:

**Core Stack**
- Dashboard (port 8443)
- NPM (Nginx Proxy Manager)
- Portainer
- Monitoring (Grafana + Prometheus)

**Media Stack** *(enable with `openbox enable vpn` first)*
- Jellyfin, Sonarr, Radarr, Prowlarr, Bazarr, Lidarr
- qBittorrent, Jellyseerr
- SABnzbd (Usenet)

**Privacy & Security**
- Vaultwarden, Pi-hole, Authelia
- Cloudflare Tunnel (tailscale-free remote access)

**Apps**
- Immich, Paperless-ngx, Mealie, BookStack
- Gitea, n8n, Matrix, Navidrome
- And 25+ more

## Quick Start

```bash
# Install (VPS)
curl -fsSL https://openbox.crushcodeworks.com/install.sh | bash

# Install (UGREEN NAS)
curl -fsSL https://openbox.crushcodeworks.com/install.sh | bash -- --nas

# After install, access dashboard at:
# http://YOUR_IP:8443

# Enable a module
openbox enable media     # Enable media stack
openbox enable pihole    # Enable Pi-hole
openbox enable vaultwarden  # Enable Vaultwarden

# Check status
openbox status
openbox doctor           # Diagnose issues
```

## Documentation

- [Install Guide](docs.html)
- [Changelog](changelog.html)
- [Media Stack Setup](#) — requires VPN
- [Module Reference](#)

## Repository Structure

```
openbox-release/     → Installer binaries (install.sh, CLI, tarball)
openbox-website/     → Static website (index.html, docs, changelog)
```

The `openbox-release/` directory is what powers the one-line installer at
`https://openbox.crushcodeworks.com/install.sh`.

## Building from Source

If you want to re-package the release:

```bash
# Create release tarball
tar czf openbox.tar.gz -C openbox_release .

# The tarball must be hosted at:
# https://crushcodeworks.com/releases/latest/openbox.tar.gz
# (update OB_DOWNLOAD_URL in install.sh if hosting elsewhere)
```

## Requirements

- Ubuntu 22.04+ / Debian 12+ (or UGREEN NAS)
- Docker + Docker Compose v2
- 2GB RAM minimum (4GB+ recommended)
- 20GB disk space

## Support

- GitHub Issues: https://github.com/crushcodeworks/openbox/issues
- Documentation: https://openbox.crushcodeworks.com/docs.html