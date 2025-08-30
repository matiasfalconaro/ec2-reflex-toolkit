#!/usr/bin/env bash

set -euo pipefail

CADDY_BIN="${CADDY_BIN:-/usr/local/bin/caddy}"

validate_prerequisites() {
    if ! command -v "$CADDY_BIN" >/dev/null; then
        echo "Caddy not found in $CADDY_BIN" >&2
        return 1
    fi
    
    if [[ ! -f "${SRC:-}" ]]; then
        echo "No Caddyfile specified or it does not exist: ${SRC:-}" >&2
        return 1
    fi
    
    return 0
}

setup_logging() {
    echo "Setting up Caddy logging directory..."
    sudo mkdir -p /var/log/caddy
    sudo chown -R caddy:caddy /var/log/caddy
    sudo chmod 750 /var/log/caddy
    sudo -u caddy install -o caddy -g caddy -m 0640 /dev/null /var/log/caddy/access.json || true
    
    echo 'd /var/log/caddy 0750 caddy caddy -' | sudo tee /etc/tmpfiles.d/caddy-logs.conf >/dev/null
    sudo systemd-tmpfiles --create /etc/tmpfiles.d/caddy-logs.conf
    
    if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
        echo "Configuring SELinux for Caddy logs..."
        sudo semanage fcontext -a -t var_log_t '/var/log/caddy(/.*)?' 2>/dev/null || true
        sudo restorecon -Rv /var/log/caddy
    fi
}

install_caddyfile() {
    echo "Installing and validating Caddyfile from $SRC..."
    sudo install -o caddy -g caddy -m 0644 "$SRC" /etc/caddy/Caddyfile
    sudo "$CADDY_BIN" fmt --overwrite /etc/caddy/Caddyfile || true
    sudo "$CADDY_BIN" validate --config /etc/caddy/Caddyfile
}

manage_caddy_service() {
    if systemctl is-active --quiet caddy; then
        echo "Reloading Caddy configuration..."
        sudo systemctl reload caddy || {
            echo "Reload failed, restarting Caddy..."
            sudo systemctl restart caddy
        }
    else
        if systemctl is-enabled --quiet caddy; then
            echo "Starting Caddy service..."
            sudo systemctl start caddy
        else
            echo "The caddy service is not enabled. Run bootstrap first." >&2
            return 1
        fi
    fi
}

show_logs() {
    echo "Showing recent Caddy logs:"
    sudo journalctl -u caddy -n 20 --no-pager
}

update_caddy_config() {
    local source_file="${1:-}"
    [[ -z "$source_file" ]] && return 1
    
    SRC="$source_file"
    validate_prerequisites || return 1
    setup_logging
    install_caddyfile
    manage_caddy_service
    show_logs
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 <caddyfile-source>"
        exit 1
    fi
    SRC="$1"
    validate_prerequisites || exit 1
    setup_logging
    install_caddyfile
    manage_caddy_service || exit 1
    show_logs
fi
