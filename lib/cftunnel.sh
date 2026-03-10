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

    get_tunnel_id() {
        local tn="$1"
        local cp="${2:-/etc/cloudflared/${tn}.json}"
        local tid
        tid=$(cloudflared tunnel list 2>/dev/null | grep -w "$tn" | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' | head -1)
        [[ -z "$tid" && -f "$cp" ]] && tid=$(grep -oE '"TunnelID"[[:space:]]*:[[:space:]]*"[^"]*"|"t"[[:space:]]*:[[:space:]]*"[^"]*"' "$cp" 2>/dev/null | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' | head -1)
        echo "$tid"
    }
    run_route_dns() {
        local tunnel="$1" hostname="$2"
        cloudflared tunnel route dns "$tunnel" "$hostname" 2>/dev/null && return 0
        cloudflared tunnel route dns "$tunnel" "$hostname" --overwrite-dns 2>/dev/null && return 0
        cloudflared tunnel route dns "$tunnel" "$hostname" -f 2>/dev/null && return 0
        local tid
        tid=$(get_tunnel_id "$tunnel")
        if [[ -n "$tid" ]]; then
            cloudflared tunnel route dns "$tid" "$hostname" 2>/dev/null && return 0
            cloudflared tunnel route dns "$tid" "$hostname" --overwrite-dns 2>/dev/null && return 0
        fi
        cloudflared route dns "$tunnel" "$hostname" 2>/dev/null && return 0
        return 1
    }

    # Auto-setup: if user has logged in, run create + route dns automatically
    local cert_locations=("/root/.cloudflared/cert.pem" "/etc/cloudflared/cert.pem")
    local has_login=""
    for c in "${cert_locations[@]}"; do
        [[ -f "$c" ]] && has_login=1 && break
    done
    [[ -z "$has_login" ]] && cloudflared tunnel list &>/dev/null && has_login=1
    if [[ -z "$has_login" ]] && [[ ! -f "$credentials_path" ]]; then
        log_info "Auto-setup skipped: run 'cloudflared tunnel login' first"
    fi
    if [[ -n "$has_login" ]] && [[ ! -f "$credentials_path" ]]; then
        log_info "Cloudflare login detected. Creating tunnel and DNS route automatically..."
        local create_out
        create_out=$(cloudflared tunnel create "$tunnel_name" 2>&1) || true
        local tunnel_id
        tunnel_id=$(cloudflared tunnel list 2>/dev/null | grep -w "$tunnel_name" | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' | head -1)
        if [[ -n "$tunnel_id" && -f "/root/.cloudflared/${tunnel_id}.json" ]]; then
            cp "/root/.cloudflared/${tunnel_id}.json" "$credentials_path"
            log_success "Tunnel created"
        else
            for f in /root/.cloudflared/*.json; do
                [[ -f "$f" ]] || continue
                cp "$f" "$credentials_path" 2>/dev/null && log_success "Tunnel created" && break
            done
        fi
        if [[ ! -f "$credentials_path" ]]; then
            log_warn "Auto-setup: tunnel create failed. Run manual steps above."
            [[ -n "$create_out" ]] && echo "$create_out" | head -5
        fi
        if [[ -f "$credentials_path" ]]; then
            if run_route_dns "$tunnel_name" "$domain"; then
                log_success "DNS route created: $domain -> $tunnel_name"
            else
                log_warn "DNS failed. Try: cloudflared tunnel route dns $tunnel_name $domain"
            fi
        fi
    fi

    # Auto-detect credentials: cloudflared creates ~/.cloudflared/<UUID>.json
    if [[ ! -f "$credentials_path" && -d /root/.cloudflared ]]; then
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
        log_info "  1. cloudflared tunnel login     (opens browser, creates cert.pem for tunnel list/create)"
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
        log_info "  1. cloudflared tunnel login     (opens browser, creates cert.pem for tunnel list/create)" >&2
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
