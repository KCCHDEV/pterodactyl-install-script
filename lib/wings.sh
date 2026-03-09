#!/usr/bin/env bash
# Pterodactyl Panel Installer - Wings daemon installation
# Install Wings for game server management

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

WINGS_RELEASE_URL="https://github.com/pterodactyl/wings/releases/latest/download"
WINGS_CONFIG="/etc/pterodactyl/config.yml"
WINGS_BINARY="/usr/local/bin/wings"

install_wings() {
    local panel_url="${1}"
    local wings_token="${2}"
    local backend_port="${3:-}"
    local token_id token_value

    log_info "Installing Wings..."

    mkdir -p /etc/pterodactyl
    mkdir -p /var/lib/pterodactyl

    local arch
    arch=$(detect_arch)
    log_info "Downloading Wings for $arch..."
    curl -sSL -o "$WINGS_BINARY" "${WINGS_RELEASE_URL}/wings_linux_${arch}"
    chmod +x "$WINGS_BINARY"

    # Parse token if provided (format: "token_value|token_id")
    if [[ -n "$wings_token" ]]; then
        token_value=$(echo "$wings_token" | cut -d'|' -f1)
        token_id=$(echo "$wings_token" | cut -d'|' -f2)
    else
        token_value=""
        token_id=""
    fi

    # remote: Tunnel mode (backend_port empty + panel_url https) -> use panel_url with --ignore-certificate-errors
    #         NPM/local mode -> http://127.0.0.1:port
    local remote_url
    local use_ignore_cert=false
    local api_port=8080
    if [[ -z "$backend_port" && "$panel_url" == https://* ]]; then
        remote_url="$panel_url"
        use_ignore_cert=true
        api_port=8080
        log_info "Tunnel mode: Wings will connect to Panel via $remote_url (TLS verify disabled)"
    else
        api_port="${backend_port:-80}"
        remote_url="http://127.0.0.1:$api_port"
    fi
    local ssl_enabled="false"

    log_info "Creating Wings configuration..."
    cat > "$WINGS_CONFIG" << WINGSCFG
---
debug: false
token_id: "$token_id"
token: "$token_value"
api:
  host: 127.0.0.1
  port: $api_port
  ssl:
    enabled: $ssl_enabled
  system:
    type: nginx
    ssl:
      enabled: $ssl_enabled
system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: 2022
user:
  username: pterodactyl
  groupname: pterodactyl
allowed_mounts: []
remote: $remote_url
WINGSCFG

    if ! id pterodactyl &>/dev/null; then
        useradd -r -s /bin/false -d /var/lib/pterodactyl pterodactyl
    fi
    chown -R pterodactyl:pterodactyl /var/lib/pterodactyl

    local exec_start="$WINGS_BINARY"
    [[ "$use_ignore_cert" == true ]] && exec_start="$WINGS_BINARY --ignore-certificate-errors"

    cat > /etc/systemd/system/wings.service << WINGSSVC
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=$exec_start
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
WINGSSVC

    systemctl daemon-reload
    log_success "Wings installed at $WINGS_BINARY"
}

update_wings_token() {
    local token_id="${1}"
    local token_value="${2}"
    local panel_url="${3}"
    local backend_port="${4:-}"

    if [[ ! -f "$WINGS_CONFIG" ]]; then
        log_error "Wings config not found"
        return 1
    fi

    sed -i "s/token_id: \"[^\"]*\"/token_id: \"$token_id\"/" "$WINGS_CONFIG"
    sed -i "s/token: \"[^\"]*\"/token: \"$token_value\"/" "$WINGS_CONFIG"
    local remote_url="$panel_url"
    [[ -n "$backend_port" ]] && remote_url="http://127.0.0.1:$backend_port"
    sed -i "s|remote: .*|remote: $remote_url|" "$WINGS_CONFIG"

    systemctl restart wings 2>/dev/null || true
    log_success "Wings token updated"
}

# Update Wings remote URL and ExecStart flags (for tunnel vs local mode)
# Usage: update_wings_remote panel_url backend_port
# - backend_port empty + panel_url https -> remote=panel_url, --ignore-certificate-errors
# - backend_port set -> remote=http://127.0.0.1:port, no flag
update_wings_remote() {
    local panel_url="${1}"
    local backend_port="${2:-}"

    [[ ! -f "$WINGS_CONFIG" ]] && return 0

    local remote_url
    local use_ignore_cert=false
    if [[ -z "$backend_port" && "$panel_url" == https://* ]]; then
        remote_url="$panel_url"
        use_ignore_cert=true
    else
        local port="${backend_port:-80}"
        remote_url="http://127.0.0.1:$port"
        sed -i "s/port: [0-9]*/port: $port/" "$WINGS_CONFIG" 2>/dev/null || true
    fi

    sed -i "s|remote: .*|remote: $remote_url|" "$WINGS_CONFIG"

    local exec_start="$WINGS_BINARY"
    [[ "$use_ignore_cert" == true ]] && exec_start="$WINGS_BINARY --ignore-certificate-errors"

    [[ -f /etc/systemd/system/wings.service ]] && sed -i "s|ExecStart=.*|ExecStart=$exec_start|" /etc/systemd/system/wings.service
    systemctl daemon-reload
    systemctl restart wings 2>/dev/null || true
    log_success "Wings remote updated to $remote_url"
}
