![AWS EC2](https://img.shields.io/badge/AWS-EC2-232F3E?logo=amazonaws&logoColor=white&style=for-the-badge)
![Docker](https://img.shields.io/badge/Docker-Container-2496ED?logo=docker&logoColor=white&style=for-the-badge)
![Caddy](https://img.shields.io/badge/Caddy-Reverse_Proxy-2BA24C?style=for-the-badge)
![Reflex](https://img.shields.io/badge/Reflex-Python_App-3776AB?logo=python&logoColor=white&style=for-the-badge)
![ASGI/FastAPI](https://img.shields.io/badge/ASGI-FastAPI-009688?logo=fastapi&logoColor=white&style=for-the-badge)
![WebSockets](https://img.shields.io/badge/WebSockets-Engine.IO-2C3E50?style=for-the-badge)
[![CrowdSec Protected](https://img.shields.io/badge/protected%20by-CrowdSec-6c3eff?logo=crowdsource&logoColor=white&style=for-the-badge)](https://www.crowdsec.net/)

![TLS Let's Encrypt](https://img.shields.io/badge/TLS-Let%27s%20Encrypt-003A70?logo=letsencrypt&logoColor=white&style=for-the-badge)
![Security CSP/HSTS](https://img.shields.io/badge/Security-CSP_%2F_HSTS-6E56CF?style=for-the-badge)
![Amazon Linux 2023](https://img.shields.io/badge/Linux-Amazon%20Linux%202023-FCC624?logo=linux&logoColor=black&style=for-the-badge)
![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white&style=for-the-badge)



# EC2-REFLEX-TOOLKIT
![Version](https://img.shields.io/badge/version-1.4.0-blue)

Automation toolkit to set up a production-ready AWS EC2 instance and deploy a Reflex app in Docker with Caddy as a reverse proxy.


# Motivation
PaaS platforms often break Reflex apps due to opaque proxy and security policies. Common symptoms:

| Problem                                            | Symptom                                 |
|----------------------------------------------------|-----------------------------------------|
| WS route not proxied (`/_event`, `/socket.io`)     | 404 / HTML instead of handshake (101)   |
| Missing upgrade/headers between proxies (H2→H1)    | 400/403 or “closed before connection”   |
| CSP without `connect-src ws`                       | Browser console blocking                |
| Timeouts/PaaS policies for long-lived connections  | Connection drop after N seconds/minutes |

# Utilities

| Utility                     | Action                                                          |
|-----------------------------|-----------------------------------------------------------------|
| Install Docker              | Install and enable Docker daemon                                |
| Install Caddy               | Download binary, create systemd unit and keep it active         |
| Automatic HTTPS (Caddyfile) | Configure TLS/ACME (Let’s Encrypt) and redirects                |
| WebSockets                  | Dedicated proxy for `/_event`/`/socket.io` with WS upgrade      |
| Static cache                | `Cache-Control: public, max-age=31536000, immutable` for assets |
| Image deployment            | `docker pull/run` or build from repo and `Dockerfile`           |
| Basic hardening             | HSTS, CSP, secure headers, IMDSv2 required                      |
| Host firewall (nftables)    | Lockdown inbound                                                |
| AWS Security Group          | Only `443/TCP` public                                           |
| Caddy access log (JSON)     | Log with rotation; base for analytics/security                  |
| CrowdSec (engine/LAPI)      | Ingest `sshd` (journald) + Caddy JSON; collections/parsers      |
| Firewall-bouncer (nftables) | Apply bans in `nftables`                                        |
| AWS Session Manager         | Instance access without SSH (SSM agent/role)                    |
| Smoke tests                 | HTTP checks and WS handshake (curl with `Upgrade: websocket`)   |
| Rollback                    | Redeploy to previous tag and restore Caddyfile if applicable    |

# Architecture
![Arquitectura](infra/docs/architecture_1.4.0.svg)

# Prerequisites - AWS

| Category                   | Requirements / Actions                                                                      | Optional |
|----------------------------|---------------------------------------------------------------------------------------------|----------|
| EC2                        | Amazon Linux 2023/2 with **Elastic IP**                                                     | No       |
| Security Group             | Open **TCP 80** and **TCP 443** to `0.0.0.0/0`                                              | No       |
| Elastic IP                 |                                                                                             | No       |
| Route 53                   | **A** records (apex and `www`) pointing to the **Elastic IP**                               | No       |
| Instance role (for SSM)    | Create **EC2-ImdsAdminMinimal** EC2 role with trust to `ec2.amazonaws.com`                  | No       |
| Instance role (for SSM)    | Attach **AmazonSSMManagedInstanceCore** to **EC2-ImdsAdminMinimal**                         | No       |
| Instance role (for SSM)    | Associate **EC2-ImdsAdminMinimal** with the instance and restart it                         | No       |
| Machine access (IAM)       | Create **group** and **user**; attach **EC2-ImdsAdminMinimal** policy to the group          | Yes      |
| Basic operations (IAM)     | Attach **EC2-InstanceBasicOps** to the group if you want start/stop/reboot/describe via IAM | Yes      |
| Session Manager checklist  | **SSM Agent** installed/active (included by default in AL2023)                              | No       |
| Session Manager checklist  | Outbound Internet access or **VPC endpoints** for SSM/SSM Messages                          | No       |
| Session Manager checklist  | Connect from *Systems Manager → Session Manager* (or *EC2 → Connect → Session Manager*)     | No       |
| Instance restart           | Enable connection with Session Manager                                                      | No       |

# Setup
```
sudo dnf -y update
sudo su - ec2-user
cd ~
sudo dnf -y install git
git clone https://github.com/<GITHUB_USER>/<REPO_NAME>.git
cd <REPO_NAME> 
```
In `Caddyfile`:
- Change ACME email `dev@example.com`
- Change domain name `company.com`
```
cp run.local.env.template .run.local.env && nano .run.local.env
chmod +x run.sh infra/scripts/*.sh
```

# Important Variables and Paths

| Variable          | Description                          | Default                                            |
|-------------------|--------------------------------------|----------------------------------------------------|
| `IMAGE`           | Docker image to deploy               | `<REGISTRY>/<NAMESPACE>/<APP>:<TAG>`               |
| `DOMAIN`          | Primary domain                       | `<DOMAIN_NAME>`                                    |
| `CADDYFILE_PATH`  | Versioned Caddyfile                  | `infra/config/caddy/Caddyfile`                     |
| `CADDY_UNIT_PATH` | Caddy unit file (systemd)            | `infra/config/systemd/caddy.service`               |
| `REPO_URL`        | Private app repository               | `https://github.com/<GITHUB_USER>/<REPO_NAME>.git` |
| `REPO_REF`        | Branch/tag/commit to use             | `main`                                             |
| `DOCKERFILE_PATH` | Dockerfile within the app repository | `Dockerfile`                                       |

# Usage
## Case 1 [Complete execution]
bootstrap (Docker + Caddy) → apply Caddyfile → container deployment.
```
./run.sh
```
>  For complete logs, see [infra/docs/run.log](infra/docs/run.log)

## Case 2
Build from repository via HTTPS (tarball) and deploy
```
export GITHUB_TOKEN=ghp_xxx # If the repo is private
./run.sh --build-from-archive \
  --repo-url <REPO_URL> \
  --ref main \
  --dockerfile Dockerfile \
  --image <REGISTRY>/<NAMESPACE>/<APP>:<TAG>
```
Optionally, to push the image after building
```
... --push
```

## Case 3
Execute only one stage
```
./run.sh --only bootstrap  # Install Docker/Caddy and set everything up
./run.sh --only caddy      # Only update Caddyfile and reload the service
./run.sh --only deploy     # Only container redeployment
```

## Case 4
Skip bootstrap (if already done)
```
./run.sh --skip-bootstrap
```

## Case 5
Change the image/tag to deploy
```
./run.sh --image <REGISTRY>/<NAMESPACE>/<APP>:<VERSION>
```

# Origin and Installation Scope

| Component                    | Origin (repo)                                        | Destination/Runtime                                                                                |
|------------------------------|------------------------------------------------------|----------------------------------------------------------------------------------------------------|
| Caddyfile                    | `infra/config/caddy/Caddyfile`                       | `/etc/caddy/Caddyfile`                                                                             |
| systemd unit (caddy.service) | `infra/config/systemd/caddy.service`                 | `/etc/systemd/system/caddy.service (enabled)                                                       |
| App container                | `IMAGE` or built from `REPO_URL` + `DOCKERFILE_PATH` | Docker (default bridge); FE `127.0.0.1:13000`, BE `127.0.0.1:18000`                                |
| Host firewall (nftables)     | `infra/scripts/nftables.sh`                          | Generates `/etc/nftables.conf` and enables `nftables` service `table inet host/chain input (DROP)` |
| Caddy access log (JSON)      | (configured in `Caddyfile`)                          | `/var/log/caddy/access.log` (rotating) creates dir and `chown caddy:caddy`                         |
| CrowdSec (engine/LAPI)       | `infra/scripts/firewall_bouncer.sh`                  | `crowdsec` package + `crowdsec.service` reads `sshd` (journald) and Caddy access log               |
| Firewall bouncer (nftables)  |`infra/scripts/firewall_bouncer.sh`                   | `crowdsec-firewall-bouncer-nftables` package; `crowdsec-firewall-bouncer.service` (hooks INPUT)    |
| Bouncer config (template)    | `crowdsec-firewall-bouncer.yaml.tmpl`                | `crowdsec-firewall-bouncer.yaml` (injects `CROWDSEC_BOUNCER_API_KEY`)                              |
| Acquisition file (CrowdSec)  | (written by script)                                  | `acquis.yaml` (sshd block + Caddy JSON block)                                                      |

> Caddy automatically issues and renews SSL if DNS points to the instance and ports `80`/`443` are open.

# Smoke tests
```
# HTTP(S)
curl -I https://<DOMAIN>
curl -sS https://<DOMAIN> | head

# Caddy and container
sudo journalctl -u caddy -n 50 --no-pager
docker ps --filter name=<CONTAINER_NAME>

# (Optional) WebSocket (requires node)
# npx wscat -c "wss://<DOMAIN>/_event/?EIO=4&transport=websocket"
```

# Rollback
Revert to a stable app version:
```
./run.sh --only deploy --image <REGISTRY>/<NAMESPACE>/<APP>:<VERSION>
```
Restore Caddyfile (if manual backup exists):
```
sudo cp /etc/caddy/Caddyfile.YYYYmmdd-HHMMSS.bak /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

# Troubleshooting

| Symptom        | Probable Cause                       | Quick Fix                                            |
|----------------|--------------------------------------|------------------------------------------------------|
| 502 from Caddy | App on :3000 not up yet              | Wait/retry; check container logs (`docker logs`)     |
| 403/400 WS     | Missing H1 upgrade or proxy headers  | Use provided Caddyfile; force HTTP/1.1 if applicable |
| 404 on /_event | Missing WS matcher                   | Keep `@event path /_event/* /socket.io/*`            |
| CSP blocking   | Missing `connect-src 'self' wss:`    | Adjust CSP in Caddyfile                              |
| ACME failure   | DNS/ports 80–443 or SG misconfigured | Check Route53/SG; `journalctl -u caddy -f`           |
