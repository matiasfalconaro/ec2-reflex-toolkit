#!/usr/bin/env bash

set -euo pipefail

backup_caddyfile() {
    local backup_dir="${1:-/etc/caddy}"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_path="$backup_dir/Caddyfile.$timestamp.bak"
    
    if [[ ! -f "/etc/caddy/Caddyfile" ]]; then
        echo "ERROR: /etc/caddy/Caddyfile does not exist" >&2
        return 1
    fi
    
    sudo cp /etc/caddy/Caddyfile "$backup_path"
    
    sudo chown caddy:caddy "$backup_path" 2>/dev/null || true
    sudo chmod 644 "$backup_path"
    
    echo "Backup: $backup_path"
    return 0
}

list_caddy_backups() {
    local backup_dir="${1:-/etc/caddy}"
    echo "Existing Caddyfile backups:"
    ls -la "$backup_dir"/Caddyfile.*.bak 2>/dev/null || echo "Backups not found"
}

restore_caddyfile() {
    local backup_file="$1"
    local dest_file="${2:-/etc/caddy/Caddyfile}"
    
    if [[ ! -f "$backup_file" ]]; then
        echo "ERROR: Backup file $backup_file does not exist" >&2
        return 1
    fi
    
    sudo cp "$backup_file" "$dest_file"
    sudo chown caddy:caddy "$dest_file"
    sudo chmod 644 "$dest_file"
    
    echo "Caddyfile restored from: $backup_file"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    backup_caddyfile "$@"
fi