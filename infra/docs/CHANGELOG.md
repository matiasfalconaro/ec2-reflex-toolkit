# CHANGELOG

# v0.1.0 — 2025-08-09
Initial reverse proxy (Nginx)
- Added reverse proxy:
    - `/` → `127.0.0.1:3000` (frontend)
    - `/api` → `127.0.0.1:8000` (backend)
    - Forwarded `Host` y `X-Real-IP`.
- Cosmetic: removed trailing space in `log_format`.
- Kept default error pages, placed after proxy rules.

# v0.2.0 — 2025-08-11
HTTPS & security on Nginx; Introduced Caddy
- Enforced HTTPS:
    - Port 80 → 301 redirect to HTTPS (rate-limited).
    - HTTPS on 443 with HTTP/2, Let’s Encrypt paths, TLS 1.2/1.3, HSTS.
- Security rules:
    - Loaded `/etc/nginx/conf.d/security.conf` (rate limits, UA blocking, headers).
    - Basic SQLi/XSS patterns → `403`.
- Split proxy routes:
    - `/` (frontend) with moderate limits.
    - `/api` (backend) with stricter limits.
    - Forwarded headers, forced `X-Forwarded-Proto=https`, tuned timeouts.
- Introduced Caddy (automatic HTTPS with `{ email mlfalconaro@gmail.com }`):
    - Canonical redirect `www → https://root`.
    - Reverse proxy: `/api/*` → `127.0.0.1:8000`, catch-all → `127.0.0.1:3000`.
    - Compression `encode zstd gzip`; static caching matcher `@static`.
    - Security headers + baseline CSP.
    - New `systemd` unit for Caddy; enabled at boot.
- Deprecation: Nginx stack marked deprecated in favor of Caddy.

# v0.3.0 — 2025-08-15
Caddyfile refinements
- CSP: temporarily allow inline scripts (`'unsafe-inline'`) for frontend stabilization.
- WebSocket/Engine.IO:
    - Added matcher `@event` (`/_event/*`, `/socket.io/*`) → backend.
    - Placed before catch-all to fix WS routing.
- Explicit route ordering: `@event` → `/api/*` → catch-all.
- Minor docs/formatting cleanup.

# v0.4.0 — 2025-08-20
Host hardening + CrowdSec + deploy flow
- Host firewall (nftables) lockdown:
    - `table inet host` with `input` policy `drop`.
    - Rules: `iif lo accept`, `ct state invalid drop`, `ct state established,related accept`,
    - allow `tcp dport 443` (HTTPS), udp dport 443 (HTTP/3), ICMP/ICMPv6 (PMTU/ND).
    - Safety: 120s auto-rollback + pre-change backup; persisted en `/etc/nftables.conf`.
- If Docker is active, restart to regenerate `ip nat`/`ip filter`.
- AWS Security Group hardened:
    - Removed inbound TCP 80.
    - Kept TCP 443; UDP 443 optional para HTTP/3.
- Caddy logging for security analytics:
    - Access log JSON en `/var/log/caddy/access.log` (rolling).
- CrowdSec integration:
    - Installed engine + nftables firewall-bouncer.
    - `acquis.yaml`: keep `sshd` via journald + add Caddy JSON access log.
    - Installed collections/parsers: `crowdsecurity/caddy`, `crowdsecurity/http-cve`, `crowdsecurity/caddy-logs`, etc.
    - Bouncer config templated (`api_key: <API_KEY>`); key injected from env `CROWDSEC_BOUNCER_API_KEY` (o auto-generada con `cscli`).
    - Default hook: INPUT (enable `FORWARD` with `HOOK_FORWARD=1`).
- Deploy flow updates (`run.sh`):
    - Order: `do_bootstrap` → `do_nftables` → `do_caddy` → `do_bouncer` → (optional build) → `do_deploy`.
    - Flags: `--only {bootstrap|nftables|caddy|bouncer|deploy}`, `--skip-bouncer`.
    - Reads `CROWDSEC_BOUNCER_API_KEY` from `.run.local.env`.

# v0.5.0 - 2025-08-25

