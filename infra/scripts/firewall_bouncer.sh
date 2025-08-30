#!/usr/bin/env bash
# firewall_bouncer.sh — Caddy JSON logs + CrowdSec engine + nftables bouncer
# Use:
#   sudo HOOK_FORWARD=0 ./firewall_bouncer.sh      # (default) INPUT only
#   sudo HOOK_FORWARD=1 ./firewall_bouncer.sh      # also FORWARD (if roted)
#   # API key taken from $CROWDSEC_BOUNCER_API_KEY (inyected by run.sh from .run.local.env)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CADDY_LOG_DIR="/var/log/caddy"
CADDY_LOG_FILE="${CADDY_LOG_DIR}/access.json"
ACQUIS_FILE="/etc/crowdsec/acquis.yaml"
BOUNCER_YAML="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
HOOK_FORWARD="${HOOK_FORWARD:-0}"
BOUNCER_API_KEY="${CROWDSEC_BOUNCER_API_KEY:-}"
PKG="dnf"; command -v dnf >/dev/null 2>&1 || PKG="yum"
LAPI_URL="${LAPI_URL:-http://127.0.0.1:8080/}"
LOCAL_CREDS="/etc/crowdsec/local_api_credentials.yaml"

log()  { printf "\n\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31m[ERROR]\033[0m %s\n" "$*"; exit 1; }
escape_sed() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }

wait_for_lapi_ready() {
  log "Waiting CrowdSec LAPI (Up to 60s)..."
  systemctl start crowdsec || true

  for i in {1..10}; do
    if ss -lntp 2>/dev/null | grep -qE '127\.0\.0\.1:8080 .*crowdsec'; then
      break
    fi
    sleep 1
  done

  for i in {1..50}; do
    if cscli lapi status -o raw 2>/dev/null | grep -qx 'OK'; then
      log "LAPI OK (cscli lapi status)."
      return 0
    fi
    sleep 1
  done

  warn "LAPI is listening but the machine is not registered yet (or there is no credentials)."
  ss -lntp | grep ':8080' || true
  journalctl -u crowdsec -n 100 --no-pager || true

  # If 8080 is in use by other process, move LAPI and bouncer to 8081
  if ss -lntp | grep ':8080' | grep -vq 'crowdsec'; then
    warn "Port 8080 occupied by another process. Reconfiguring LAPI and bouncer to 8081."
    sed -i -E 's|(^[[:space:]]*listen_uri:[[:space:]]*).*$|\1127.0.0.1:8081|' /etc/crowdsec/config.yaml
    sed -i -E 's|(^[[:space:]]*api_url:[[:space:]]*).*$|\1http://127.0.0.1:8081/|' "${BOUNCER_YAML}"
    systemctl restart crowdsec
  fi

  return 1  # Not fatal; the machine registry is made later.
}

ensure_machine_registration() {
  log "Registering this machine upon the LAPI..."

  if cscli lapi status -o raw 2>/dev/null | grep -qx 'OK'; then
    log "Machine is registered (lapi status: OK)."
    return 0
  fi

  if [ -f "$LOCAL_CREDS" ]; then
    warn " $LOCAL_CREDS not found; backed up and new one generated."
    mv "$LOCAL_CREDS" "${LOCAL_CREDS}.bak.$(date +%F-%H%M%S)"
  fi

  local NAME="host-$(hostname -s)-$(date +%s)"
  local PASS

  if [ -n "$CROWDSEC_PASSWORD" ]; then
    PASS="$CROWDSEC_PASSWORD"
    log "Using CROWDSEC_PASSWORD defined by environment."
  else
    PASS="$(openssl rand -hex 16)"
    log "Generating random password for machine: $PASS"
  fi

  cscli machines add "$NAME" --password "$PASS" >/tmp/cs_add.log 2>&1 || {
    cat /tmp/cs_add.log
    fail "The machine could not be created in LAPI."
  }

  cscli machines validate -m "$NAME" 2>/dev/null || cscli machines validate "$NAME" || \
    fail "The machine could not be validated in LAPI."

  if [[ ! -f "$LOCAL_CREDS" ]]; then
    fail "Credentials file $LOCAL_CREDS not created successfully"
  fi

  cscli lapi status || fail "LAPI register still not OK after registration."
  log "LAPI OK and machine registered."
}


ensure_root() {
  [[ $EUID -eq 0 ]] || fail "Execute as root."
}

restart_bouncer_or_dump() {
  if ! systemctl restart crowdsec-firewall-bouncer; then
    systemctl --no-pager --full status crowdsec-firewall-bouncer || true
    journalctl -u crowdsec-firewall-bouncer -n 200 --no-pager || true
    fail "crowdsec-firewall-bouncer could not be restarted."
  fi
}

verify_stream_and_fix() {
  log "Checking bouncer conectivity to LAPI (decisions stream)"
  [[ -f "${BOUNCER_YAML}" ]] || fail "${BOUNCER_YAML} do not exist"
  local BKEY_CUR
  BKEY_CUR="$(awk -F': *' '$1=="api_key"{print $2; exit}' "${BOUNCER_YAML}" | tr -d '[:space:]')"
  [[ -n "${BKEY_CUR}" ]] || fail "api_key missing in ${BOUNCER_YAML}"

  local STREAM_URL="http://127.0.0.1:8080/v1/decisions/stream?startup=true"
  local HTTP_CODE
  if ! HTTP_CODE=$(curl -sS -o /tmp/cs_stream_probe.json -w '%{http_code}' \
      -H "X-Api-Key: ${BKEY_CUR}" "${STREAM_URL}"); then
    HTTP_CODE="000"
  fi

  case "${HTTP_CODE}" in
    200|204)
      log "LAPI OK (${HTTP_CODE}). Stream accesible with  actual API key."
      ;;
    401|403)
      warn "LAPI response: ${HTTP_CODE} (not autorized). Regenerating API key and inyecting it in ${BOUNCER_YAML}."
      local NEWKEY
      NEWKEY="$(cscli bouncers add "cs-nftables-$(date +%s)" -o raw | tail -1 | tr -d '[:space:]')"
      if [[ -z "${NEWKEY}" ]]; then
        NEWKEY="$(cscli bouncers add "cs-nftables-$(date +%s)" -o json | jq -r '.api_key // empty')"
      fi
      [[ -n "${NEWKEY}" ]] || fail "Failed to obtain a new API key from cscli."
      sed -i "s#^api_key:.*#api_key: ${NEWKEY}#" "${BOUNCER_YAML}"
      chmod 600 "${BOUNCER_YAML}"
      if ! HTTP_CODE=$(curl -sS -o /tmp/cs_stream_probe.json -w '%{http_code}' \
          -H "X-Api-Key: ${NEWKEY}" "${STREAM_URL}"); then
        HTTP_CODE="000"
      fi
      [[ "${HTTP_CODE}" =~ ^(200|204)$ ]] || fail "Stream is still failing (${HTTP_CODE}) after regenerating the key."
      ;;
    000|5*)
      warn "I could not contact the LAPI (HTTP ${HTTP_CODE}). Latest crowdsec logs:"
      journalctl -u crowdsec -n 100 --no-pager || true
      fail "The LAPI is not accessible; check crowdsec.service."
      ;;
    *)
      warn "Unexpected response from the LAPI (HTTP ${HTTP_CODE}). Payload saved in /tmp/cs_stream_probe.json"
      ;;
  esac
}

prepare_caddy_logs() {
  log "Preparing Caddy log directory: ${CADDY_LOG_DIR}"
  mkdir -p "${CADDY_LOG_DIR}"
  chown -R caddy:caddy "${CADDY_LOG_DIR}" 2>/dev/null || true
  chmod 750 "${CADDY_LOG_DIR}" || true

  if [[ ! -f "${CADDY_LOG_FILE}" ]]; then
    install -o caddy -g crowdsec -m 0640 /dev/null "${CADDY_LOG_FILE}" 2>/dev/null || true
  else
    chown caddy:crowdsec "${CADDY_LOG_FILE}" 2>/dev/null || true
    chmod 0640 "${CADDY_LOG_FILE}" || true
  fi
}

reload_caddy_if_valid() {
  if command -v caddy >/dev/null 2>&1; then
    if caddy validate --config /etc/caddy/Caddyfile; then
      systemctl reload caddy || warn "Could not reload Caddy (check journalctl -xeu caddy.service)"
    else
      warn "Invalid Caddyfile; continuing anyway, but make sure you have the 'log' block in the site."
    fi
  else
    warn "Caddy is not in PATH; skipping reload."
  fi
}

install_crowdsec_core() {
  log "Installing CrowdSec (repository and packages)"
  if ! command -v curl >/dev/null 2>&1; then
    ${PKG} -y install curl-minimal >/dev/null 2>&1 || ${PKG} -y install curl >/dev/null 2>&1 || true
  fi
  curl -s https://install.crowdsec.net | bash
  ${PKG} -y install crowdsec >/dev/null

  if ! command -v jq >/dev/null 2>&1; then
    ${PKG} -y install jq >/dev/null 2>&1 || true
  fi
}

ensure_crowdsec_user_and_groups() {
  if ! getent group crowdsec >/dev/null; then groupadd --system crowdsec || true; fi
  if ! id -u crowdsec >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /sbin/nologin --gid crowdsec crowdsec || true
  fi
  usermod -a -G caddy crowdsec || true
}

enable_start_crowdsec() {
  systemctl enable --now crowdsec
}

install_bouncer_pkg_and_unit() {
  ${PKG} -y install crowdsec-firewall-bouncer-nftables >/dev/null || {
    warn "Bouncer package not available in the local repository; retrying after adding packagecloud."
    curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.rpm.sh | bash
    ${PKG} -y install crowdsec-firewall-bouncer-nftables
  }

  install -d -m 0755 /etc/systemd/system/crowdsec-firewall-bouncer.service.d
  cat > /etc/systemd/system/crowdsec-firewall-bouncer.service.d/override.conf <<'EOF'
[Unit]
After=network-online.target crowdsec.service
Wants=network-online.target crowdsec.service

[Service]
Restart=on-failure
RestartSec=3s
EOF
  systemctl daemon-reload
  systemctl enable crowdsec-firewall-bouncer
}

provision_bouncer_yaml() {
  log "Creating/updating ${BOUNCER_YAML}"
  local BKEY="${BOUNCER_API_KEY:-}"
  if [[ -z "$BKEY" ]]; then
    cscli bouncers list -o raw 2>/dev/null | grep -q . || true
    BKEY="$(cscli bouncers add "cs-nftables-$(date +%s)" -o raw | tail -1 | tr -d '[:space:]')"
    if [[ -z "$BKEY" ]]; then
      BKEY="$(cscli bouncers add "cs-nftables-$(date +%s)" -o json | jq -r '.api_key // empty')"
    fi
    [[ -n "$BKEY" ]] || fail "I could not get an API key from cscli."
  fi

  install -d -m 0750 /etc/crowdsec/bouncers
  cp -a "${BOUNCER_YAML}" "${BOUNCER_YAML}.bak.$(date +%F-%H%M%S)" 2>/dev/null || true

  cat > "${BOUNCER_YAML}" <<EOF
mode: nftables
api_url: ${LAPI_URL}
api_key: ${BKEY}
retry_initial_connect: true

nftables:
  inet_family: inet
  ipv4:
    enabled: true
    table: host
    chain: input
    set-only: true
    blacklist_name: crowdsec-blacklists
  ipv6:
    enabled: true
    table: host
    chain: input
    set-only: true
    blacklist_name: crowdsec6-blacklists

nftables_hooks:
  - input
EOF

  [[ "${HOOK_FORWARD}" -eq 1 ]] && sed -i '/^nftables_hooks:/a\  - forward' "${BOUNCER_YAML}"
  chmod 600 "${BOUNCER_YAML}"
}

configure_acquis() {
  log "Configuring ${ACQUIS_FILE} (sshd journald + Caddy access.json)"
  mkdir -p "$(dirname "${ACQUIS_FILE}")"
  [[ -f "${ACQUIS_FILE}" ]] && cp -a "${ACQUIS_FILE}" "${ACQUIS_FILE}.bak.$(date +%F-%H%M%S)" || true

  if ! grep -q "${CADDY_LOG_FILE}" "${ACQUIS_FILE}" 2>/dev/null; then
    if ! grep -q "_SYSTEMD_UNIT=sshd.service" "${ACQUIS_FILE}" 2>/dev/null; then
      cat > "${ACQUIS_FILE}" <<EOF
# SSH via journald
source: journalctl
journalctl_filter:
  - _SYSTEMD_UNIT=sshd.service
labels:
  type: syslog
EOF
    fi
    cat >> "${ACQUIS_FILE}" <<EOF

---
# Caddy access log (JSON)
filenames:
  - ${CADDY_LOG_FILE}
labels:
  type: caddy
EOF
  else
    log "Caddy block already present in acquis.yaml, ok."
  fi
}

install_http_caddy_collections() {
  log "Installing HTTP/Caddy collections/parsers"
  cscli collections install crowdsecurity/caddy || true
  cscli collections install crowdsecurity/http-cve || true
  cscli parsers install crowdsecurity/caddy-logs || true
}

ensure_nftables_baseline() {
  # Base table/chain
  if ! nft list table inet host >/dev/null 2>&1; then
    warn "Table 'inet host' does not exist; creating it."
    nft add table inet host || true
  fi
  if ! nft list chain inet host input >/dev/null 2>&1; then
    nft add chain inet host input '{ type filter hook input priority 0; policy accept; }' || true
  fi
}

ensure_crowdsec_sets() {
  nft list set inet host crowdsec-blacklists >/dev/null 2>&1 || \
    nft add set inet host crowdsec-blacklists '{ type ipv4_addr; flags interval; }'
  nft list set inet host crowdsec6-blacklists >/dev/null 2>&1 || \
    nft add set inet host crowdsec6-blacklists '{ type ipv6_addr; flags interval; }'
}

restart_and_verify() {
  systemctl restart crowdsec
  verify_stream_and_fix
  restart_bouncer_or_dump

  log "Checking ingestion and decisions"
  cscli metrics || true
  cscli decisions list || true

  log "Looking for crowdsec chains/sets in nftables"
  nft list ruleset | grep -i crowdsec -n || true

  log "Services status"
  systemctl --no-pager --full status crowdsec || true
  systemctl --no-pager --full status crowdsec-firewall-bouncer || true
}

main_bouncer() {
  ensure_root

  install_crowdsec_core
  ensure_crowdsec_user_and_groups
  prepare_caddy_logs
  reload_caddy_if_valid

  enable_start_crowdsec
  install_bouncer_pkg_and_unit

  wait_for_lapi_ready || true
  ensure_machine_registration

  provision_bouncer_yaml
  verify_stream_and_fix
  restart_bouncer_or_dump

  configure_acquis
  install_http_caddy_collections

  ensure_nftables_baseline
  ensure_crowdsec_sets

  restart_and_verify

  log "Done. CrowdSec is reading sshd + Caddy and applying bans via nftables."
  echo "Notes:"
  echo " - If Caddy logs to a different path, update ${ACQUIS_FILE}."
  echo " - Test ban: cscli decisions add -i 203.0.113.1 -t ban -d 5m"
}

main_bouncer "$@"
