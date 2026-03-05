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

    # API config - panel on same machine
    local api_port="80"
    local ssl_enabled="false"
    if [[ "$panel_url" == https://* ]]; then
        api_port="443"
        ssl_enabled="true"
    fi

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
remote: $panel_url
WINGSCFG

    if ! id pterodactyl &>/dev/null; then
        useradd -r -s /bin/false -d /var/lib/pterodactyl pterodactyl
    fi
    chown -R pterodactyl:pterodactyl /var/lib/pterodactyl

    cat > /etc/systemd/system/wings.service << WINGSSVC
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=$WINGS_BINARY
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

    if [[ ! -f "$WINGS_CONFIG" ]]; then
        log_error "Wings config not found"
        return 1
    fi

    sed -i "s/token_id: \"[^\"]*\"/token_id: \"$token_id\"/" "$WINGS_CONFIG"
    sed -i "s/token: \"[^\"]*\"/token: \"$token_value\"/" "$WINGS_CONFIG"
    sed -i "s|remote: .*|remote: $panel_url|" "$WINGS_CONFIG"

    systemctl restart wings 2>/dev/null || true
    log_success "Wings token updated"
}
