#!/usr/bin/env bash
# Pterodactyl Panel Installer - Cloudflare Tunnel setup
# Supports Quick Tunnel and Named Tunnel

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

CLOUDFLARED_SERVICE="/etc/systemd/system/cloudflared-tunnel.service"
CLOUDFLARED_CONFIG="/etc/cloudflared/config.yml"

install_cloudflared() {
    log_info "Installing cloudflared..."

    if is_installed cloudflared; then
        log_success "cloudflared already installed"
        return 0
    fi

    # Add Cloudflare package repository
    mkdir -p /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflared.list
    apt-get update -qq
    apt-get install -y -qq cloudflared

    log_success "cloudflared installed"
}

setup_quick_tunnel() {
    # Quick tunnel - no Cloudflare account needed
    # Returns URL like https://xxx.trycloudflare.com
    log_info "Starting Quick Tunnel (trycloudflare.com)..."

    install_cloudflared

    pkill -f "cloudflared tunnel" 2>/dev/null || true
    sleep 1

    # Quick tunnel fails if config exists in .cloudflared (per Cloudflare docs)
    rm -f /etc/cloudflared/config.yml /root/.cloudflared/config.yml 2>/dev/null
    mkdir -p /etc/cloudflared

    cat > "$CLOUDFLARED_SERVICE" << 'CFTUNNEL'
[Unit]
Description=Cloudflare Quick Tunnel for Pterodactyl
After=network.target nginx.service

[Service]
Type=simple
WorkingDirectory=/tmp
ExecStart=/usr/bin/cloudflared tunnel --url http://127.0.0.1:80
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
CFTUNNEL

    systemctl daemon-reload
    systemctl enable cloudflared-tunnel
    systemctl start cloudflared-tunnel

    log_info "Waiting for tunnel URL..."
    sleep 8
    local tunnel_url
    tunnel_url=$(journalctl -u cloudflared-tunnel -n 100 --no-pager 2>/dev/null | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1)

    if [[ -n "$tunnel_url" ]]; then
        log_success "Quick Tunnel: $tunnel_url"
        echo "$tunnel_url"
    else
        log_warn "Run 'journalctl -u cloudflared-tunnel -f' to see your tunnel URL"
    fi
}

setup_named_tunnel() {
    local tunnel_name="${1:-pterodactyl-panel}"
    local domain="${2}"
    log_info "Setting up Named Tunnel: $tunnel_name for $domain..."

    install_cloudflared

    # User must run: cloudflared tunnel login
    # Then: cloudflared tunnel create $tunnel_name
    # And route DNS: cloudflared tunnel route dns $tunnel_name $domain
    mkdir -p /etc/cloudflared

    cat > "$CLOUDFLARED_CONFIG" << EOF
tunnel: $tunnel_name
credentials-file: /etc/cloudflared/${tunnel_name}.json

ingress:
  - hostname: $domain
    service: http://127.0.0.1:80
  - service: http_status:404
EOF

    log_info "Named tunnel config created. You need to:"
    log_info "1. Run: cloudflared tunnel login"
    log_info "2. Run: cloudflared tunnel create $tunnel_name"
    log_info "3. Run: cloudflared tunnel route dns $tunnel_name $domain"
    log_info "4. Copy credentials to /etc/cloudflared/${tunnel_name}.json"

    cat > "$CLOUDFLARED_SERVICE" << EOF
[Unit]
Description=Cloudflare Tunnel for Pterodactyl Panel
After=network.target nginx.service

[Service]
Type=simple
ExecStart=/usr/bin/cloudflared tunnel run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_success "Named tunnel config ready at $CLOUDFLARED_CONFIG"
}

stop_cloudflared_tunnel() {
    systemctl stop cloudflared-tunnel 2>/dev/null || true
    systemctl disable cloudflared-tunnel 2>/dev/null || true
    rm -f "$CLOUDFLARED_SERVICE"
    pkill -f "cloudflared tunnel" 2>/dev/null || true
    log_info "Cloudflared tunnel stopped"
}
