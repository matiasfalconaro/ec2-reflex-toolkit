#!/usr/bin/env bash

set -euo pipefail

CADDYFILE_PATH="${CADDYFILE_PATH:-infra/config/caddy/Caddyfile}"
CADDY_UNIT_PATH="${CADDY_UNIT_PATH:-infra/config/systemd/caddy.service}"

update_system() {
    echo "Updating system packages..."
    sudo dnf -y update
}

setup_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "Installing Docker..."
        if ! sudo dnf -y install docker; then
            echo "ERROR: Failed to install Docker" >&2
            return 1
        fi
    fi
    
    echo "Enabling and starting Docker service..."
    sudo systemctl enable --now docker
    
    if [ "$(id -u)" != "0" ]; then
        echo "Adding $(whoami) to docker group..."
        sudo usermod -aG docker "$(whoami)"
    else
        echo "Running as root, skipping user addition to docker group"
    fi

    echo "Verifying Docker installation..."
    if sudo docker info >/dev/null 2>&1; then
        echo "Docker installed and accessible with sudo"
    else
        echo "WARNING: Docker installed but may require logout/login for full access"
    fi
}

setup_caddy_user() {
    echo "Setting up Caddy user and group..."
    sudo groupadd --system caddy || true
    
    if ! id -u caddy &>/dev/null; then
        sudo useradd --system --gid caddy --create-home --home-dir /var/lib/caddy \
            --shell /usr/sbin/nologin --comment "Caddy web server" caddy
    fi
    
    sudo mkdir -p /etc/caddy
    sudo chown -R caddy:caddy /etc/caddy /var/lib/caddy
}

setup_logging() {
    echo "Setting up Caddy logging..."
    sudo mkdir -p /var/log/caddy
    sudo chown -R caddy:caddy /var/log/caddy
    sudo chmod 0750 /var/log/caddy
    
    echo 'd /var/log/caddy 0750 caddy caddy -' | sudo tee /etc/tmpfiles.d/caddy-logs.conf >/dev/null
    sudo systemd-tmpfiles --create /etc/tmpfiles.d/caddy-logs.conf
    
    sudo rm -f /var/log/caddy/access.json
    sudo -u caddy install -o caddy -g caddy -m 0640 /dev/null /var/log/caddy/access.json
    
    # SELinux configuration if enabled
    if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
        echo "Configuring SELinux for Caddy..."
        sudo semanage fcontext -a -t var_log_t '/var/log/caddy(/.*)?' 2>/dev/null || true
        sudo restorecon -Rv /var/log/caddy
    fi
}

install_caddy() {
    echo "Downloading and installing Caddy..."
    cd ~
    curl -LO https://github.com/caddyserver/caddy/releases/download/v2.10.0/caddy_2.10.0_linux_amd64.tar.gz
    tar xzvf caddy_2.10.0_linux_amd64.tar.gz
    sudo mv -f caddy /usr/local/bin/
    sudo chmod +x /usr/local/bin/caddy
    sudo setcap cap_net_bind_service=+ep /usr/local/bin/caddy
}

setup_caddy_service() {
    if [[ ! -f "$CADDY_UNIT_PATH" ]]; then
        echo "ERROR: Unit file not found in $CADDY_UNIT_PATH" >&2
        return 1
    fi
    
    echo "Installing Caddy unit from $CADDY_UNIT_PATH"
    sudo install -m 0644 "$CADDY_UNIT_PATH" /etc/systemd/system/caddy.service
    
    # Set ACME email environment variable if provided
    if [[ -n "${ACME_EMAIL:-}" ]]; then
        echo "Configuring ACME email environment..."
        sudo mkdir -p /etc/systemd/system/caddy.service.d
        sudo tee /etc/systemd/system/caddy.service.d/env.conf >/dev/null <<EOF
[Service]
Environment="ACME_EMAIL=${ACME_EMAIL}"
EOF
    fi
    
    sudo systemctl daemon-reload
}

setup_caddyfile() {
    if [[ ! -f "$CADDYFILE_PATH" ]]; then
        echo "ERROR: Caddyfile not found in $CADDYFILE_PATH" >&2
        return 1
    fi
    
    echo "Installing Caddyfile from $CADDYFILE_PATH"
    sudo install -o caddy -g caddy -m 0644 "$CADDYFILE_PATH" /etc/caddy/Caddyfile
    
    sudo /usr/local/bin/caddy fmt --overwrite /etc/caddy/Caddyfile || true
}

configure_network() {
    echo "Configuring network settings for QUIC..."
    sudo tee /etc/sysctl.d/99-quic.conf >/dev/null <<EOF
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
EOF
    sudo sysctl --system
}

start_caddy() {
    echo "Validating Caddy configuration..."
    sudo /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile
    
    echo "Enabling and starting Caddy service..."
    sudo systemctl enable --now caddy
    
    echo "Reloading Caddy configuration..."
    sudo systemctl reload caddy || sudo systemctl restart caddy
    
    echo "Showing recent Caddy logs:"
    sudo journalctl -u caddy -n 30 --no-pager
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Starting Caddy setup process..."
    
    update_system
    setup_docker
    setup_caddy_user
    setup_logging
    install_caddy
    setup_caddy_service || exit 1
    setup_caddyfile || exit 1
    configure_network
    start_caddy
    
    echo "Caddy setup completed successfully!"
fi
