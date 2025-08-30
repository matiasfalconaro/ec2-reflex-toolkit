#!/usr/bin/env bash
# =========[ Host lockdown with nftables (443 TCP/UDP only) + hooks CrowdSec ]=========

set -euo pipefail

readonly PKG="$(command -v dnf >/dev/null 2>&1 && echo "dnf" || echo "yum")"
readonly TS="$(date +%F-%H%M%S)"
readonly NFT_CONF="/etc/nftables.conf"
readonly NFT_SYSCONF="/etc/sysconfig/nftables.conf"
readonly NFT_RULES_FILE="/root/host-lockdown.nft"


check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Run as root."
        exit 1
    fi
}

install_nftables() {
    echo "Installing nftables..."
    ${PKG} -y install nftables >/dev/null
    systemctl enable --now nftables
}

backup_current_rules() {
    echo "Backing up current rules..."
    nft list ruleset | tee "/root/nft-pre-change-${TS}.conf" >/dev/null || true
    cp -f "/root/nft-pre-change-${TS}.conf" /root/nft-pre-change.conf || true
}

get_ssh_rules() {
    local allow_ssh="${1:-0}"
    local ssh_ip="${2:-}"
    local ssh_ip6="${3:-}"
    
    local ssh_rule=""
    local ssh_rule6=""
    
    if [[ "${allow_ssh}" == "1" ]]; then
        if [[ -n "${ssh_ip}" && "${ssh_ip}" != *:* ]]; then
            ssh_rule="ip saddr ${ssh_ip}/32 tcp dport 22 accept"
            echo "Temporary SSH enabled (IPv4) only from ${ssh_ip}"
        fi
        
        if [[ -n "${ssh_ip6}" ]]; then
            ssh_rule6="ip6 saddr ${ssh_ip6}/128 tcp dport 22 accept"
            echo "Temporary SSH enabled (IPv6) only from ${ssh_ip6}"
        fi
        
        if [[ -z "${ssh_rule}" && -z "${ssh_rule6}" ]]; then
            echo "ALLOW_SSH=1 but no IP detected; SSH exception was not added."
        fi
    fi
    
    echo "${ssh_rule}|${ssh_rule6}"
}

create_nft_rules() {
    local ssh_rules="${1}"
    local ssh_rule=$(echo "${ssh_rules}" | cut -d'|' -f1)
    local ssh_rule6=$(echo "${ssh_rules}" | cut -d'|' -f2)
    
    echo "Creating nftables rules..."
    
    cat > "${NFT_RULES_FILE}" << EOF
table inet host {
  # Sets that the CrowdSec bouncer will use
  set crowdsec-blacklists { type ipv4_addr; flags interval; }
  set crowdsec6-blacklists { type ipv6_addr; flags interval; }

  chain input {
    type filter hook input priority 0;
    policy drop;

    iif lo accept
    ct state invalid drop

    # Banned by CrowdSec first (cuts established connections)
    ip  saddr @crowdsec-blacklists  drop
    ip6 saddr @crowdsec6-blacklists drop

    ct state established,related accept

    ${ssh_rule}
    ${ssh_rule6}

    # HTTPS only
    tcp dport 443 accept
    udp dport 443 accept

    # Useful ICMP/ICMPv6 (PMTU, ND)
    ip  protocol icmp accept
    ip6 nexthdr ipv6-icmp accept
  }
}
EOF
}

validate_nft_rules() {
    echo "Validating rule syntax..."
    if ! nft -c -f "${NFT_RULES_FILE}"; then
        echo "nft: syntax error"
        sed -n '1,160p' "${NFT_RULES_FILE}"
        exit 1
    fi
}

apply_nft_rules_with_rollback() {
    echo "Applying rules with rollback mechanism...."
    
    (sleep 120; nft -f /root/nft-pre-change.conf) & 
    echo $! > /run/nft-rollback.pid || true
    
    nft -f "${NFT_RULES_FILE}"
    
    if [[ -s /run/nft-rollback.pid ]]; then
        kill "$(cat /run/nft-rollback.pid)" 2>/dev/null || true
        rm -f /run/nft-rollback.pid
    fi
}

configure_persistent_rules() {
    echo "Configuring persistent rules..."
    
    local target_conf="${NFT_CONF}"
    if systemctl cat nftables | grep -q "${NFT_SYSCONF}"; then
        target_conf="${NFT_SYSCONF}"
    fi
    
    install -m 600 "${NFT_RULES_FILE}" "${target_conf}"
    systemctl restart nftables
}

restart_related_services() {
    echo "Restarting related services..."
    
    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
        systemctl restart docker
    fi
    
    if systemctl list-unit-files | grep -q '^crowdsec-firewall-bouncer'; then
        systemctl restart crowdsec-firewall-bouncer || true
    fi
}

show_current_config() {
    echo "=== host/input ==="
    nft list chain inet host input || true
    echo "=== sets crowdsec ==="
    nft list set inet host crowdsec-blacklists || true
    nft list set inet host crowdsec6-blacklists || true
}

main_nftables() {
    local allow_ssh="${ALLOW_SSH:-0}"
    local ssh_ip="${SSH_IP:-${SSH_CONNECTION:-}}"
    ssh_ip="$(printf '%s' "$ssh_ip" | awk '{print $1}')"
    local ssh_ip6="${SSH_IP6:-}"
    
    check_root
    install_nftables
    backup_current_rules
    
    local ssh_rules=$(get_ssh_rules "${allow_ssh}" "${ssh_ip}" "${ssh_ip6}")
    create_nft_rules "${ssh_rules}"
    validate_nft_rules
    apply_nft_rules_with_rollback
    configure_persistent_rules
    restart_related_services
    show_current_config
    
    echo "Done. Remember to open UDP 443 in the Security Group if you want HTTP/3."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_nftables "$@"
fi
