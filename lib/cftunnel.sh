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

    # Add Cloudflare package repository (per current Cloudflare docs)
    mkdir -p /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main" | tee /etc/apt/sources.list.d/cloudflared.list
    apt-get update -qq
    apt-get install -y -qq cloudflared

    log_success "cloudflared installed"
}

setup_quick_tunnel() {
    # Quick tunnel - no Cloudflare account needed
    # Returns URL like https://xxx.trycloudflare.com
    # Progress to stderr so it's visible when output is captured by tunnel_url=$(...)
    local tunnel_url=""
    {
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
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:80
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
CFTUNNEL

    systemctl daemon-reload
    systemctl enable cloudflared-tunnel
    systemctl start cloudflared-tunnel

    log_info "Waiting for tunnel URL..."
    for _ in 1 2 3 4 5; do
        sleep 3
        tunnel_url=$(journalctl -u cloudflared-tunnel -n 100 --no-pager 2>/dev/null | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1)
        [[ -n "$tunnel_url" ]] && break
    done

    if [[ -n "$tunnel_url" ]]; then
        log_success "Quick Tunnel: $tunnel_url"
    else
        log_warn "Run 'journalctl -u cloudflared-tunnel -f' to see your tunnel URL"
    fi
    } >&2
    [[ -n "$tunnel_url" ]] && echo "$tunnel_url"
}

setup_quick_tunnel_to_port() {
    # Quick tunnel pointing to custom port (e.g. 8080 for NPM backend)
    local port="${1:-80}"
    local tunnel_url=""
    {
    log_info "Starting Quick Tunnel to 127.0.0.1:$port..."

    install_cloudflared

    pkill -f "cloudflared tunnel" 2>/dev/null || true
    sleep 1

    rm -f /etc/cloudflared/config.yml /root/.cloudflared/config.yml 2>/dev/null
    mkdir -p /etc/cloudflared

    cat > "$CLOUDFLARED_SERVICE" << CFTUNNEL
[Unit]
Description=Cloudflare Quick Tunnel for Pterodactyl (port $port)
After=network.target nginx.service

[Service]
Type=simple
WorkingDirectory=/tmp
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:$port
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
CFTUNNEL

    systemctl daemon-reload
    systemctl enable cloudflared-tunnel
    systemctl start cloudflared-tunnel

    log_info "Waiting for tunnel URL..."
    for _ in 1 2 3 4 5; do
        sleep 3
        tunnel_url=$(journalctl -u cloudflared-tunnel -n 100 --no-pager 2>/dev/null | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1)
        [[ -n "$tunnel_url" ]] && break
    done

    if [[ -n "$tunnel_url" ]]; then
        log_success "Quick Tunnel: $tunnel_url"
    else
        log_warn "Run 'journalctl -u cloudflared-tunnel -f' to see your tunnel URL"
    fi
    } >&2
    [[ -n "$tunnel_url" ]] && echo "$tunnel_url"
}

setup_named_tunnel() {
    local tunnel_name="${1:-pterodactyl-panel}"
    local domain="${2}"
    local port="${3:-80}"
    local credentials_path="/etc/cloudflared/${tunnel_name}.json"

    log_info "Setting up Named Tunnel: $tunnel_name for $domain (->127.0.0.1:$port)..."

    install_cloudflared

    mkdir -p /etc/cloudflared

    # Auto-detect credentials: cloudflared creates ~/.cloudflared/<UUID>.json
    if [[ -d /root/.cloudflared ]]; then
        local creds_found=""
        for f in /root/.cloudflared/*.json; do
            [[ -f "$f" ]] || continue
            cp "$f" "$credentials_path" 2>/dev/null && creds_found=1 && log_info "Copied credentials to $credentials_path" && break
        done
        [[ -z "$creds_found" ]] && credentials_path=""
    fi

    if [[ ! -f "$credentials_path" ]]; then
        credentials_path="/etc/cloudflared/${tunnel_name}.json"
        log_info "Named tunnel - run these steps:"
        log_info "  1. cloudflared tunnel login     (opens browser)"
        log_info "  2. cloudflared tunnel create $tunnel_name"
        log_info "  3. cloudflared tunnel route dns $tunnel_name $domain"
        log_info "  4. cp /root/.cloudflared/*.json $credentials_path"
        log_info "  5. systemctl start cloudflared-tunnel"
    fi

    cat > "$CLOUDFLARED_CONFIG" << EOF
tunnel: $tunnel_name
credentials-file: $credentials_path

ingress:
  - hostname: $domain
    service: http://127.0.0.1:$port
  - service: http_status:404
EOF

    cat > "$CLOUDFLARED_SERVICE" << EOF
[Unit]
Description=Cloudflare Tunnel for Pterodactyl Panel
After=network.target nginx.service

[Service]
Type=simple
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --config /etc/cloudflared/config.yml run $tunnel_name
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable cloudflared-tunnel 2>/dev/null || true
    if [[ -f "$credentials_path" ]]; then
        systemctl start cloudflared-tunnel 2>/dev/null || true
        log_success "Named tunnel started. Panel URL: https://${domain}"
        NAMED_TUNNEL_READY=1
    else
        log_warn "Complete the 5 steps above before the panel will be reachable"
        log_warn "Domain must be added to Cloudflare. Run steps 1-5 in order."
        log_info "Panel URL (after completing steps): https://${domain}"
        echo "" >&2
        log_info "Required steps (run in order):" >&2
        log_info "  1. cloudflared tunnel login     (opens browser)" >&2
        log_info "  2. cloudflared tunnel create $tunnel_name" >&2
        log_info "  3. cloudflared tunnel route dns $tunnel_name $domain" >&2
        log_info "  4. cp /root/.cloudflared/*.json $credentials_path" >&2
        log_info "  5. systemctl start cloudflared-tunnel" >&2
        log_info "Config saved to $CLOUDFLARED_CONFIG" >&2
        NAMED_TUNNEL_READY=0
    fi
}

stop_cloudflared_tunnel() {
    systemctl stop cloudflared-tunnel 2>/dev/null || true
    systemctl disable cloudflared-tunnel 2>/dev/null || true
    rm -f "$CLOUDFLARED_SERVICE"
    pkill -f "cloudflared tunnel" 2>/dev/null || true
    log_info "Cloudflared tunnel stopped"
}
