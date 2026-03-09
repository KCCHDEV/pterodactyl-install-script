#!/usr/bin/env bash
# Pterodactyl Panel - Switch Mode (Tunnel / NPM / NPM+Tunnel)
# Switch between modes for existing panel installation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/dependencies.sh"
source "$SCRIPT_DIR/ssl.sh"
source "$SCRIPT_DIR/cftunnel.sh"
source "$SCRIPT_DIR/wings.sh"

# Load from settings
load_switch_context() {
    if [[ ! -f "$SETTINGS_JSON_PATH" ]]; then
        log_error "Settings not found. Run fresh install first."
        exit 1
    fi
    FQDN=$(get_json_value "$SETTINGS_JSON_PATH" "fqdn")
    ADMIN_EMAIL=$(get_json_value "$SETTINGS_JSON_PATH" "admin_email")
    PANEL_PATH=$(get_json_value "$SETTINGS_JSON_PATH" "panel_path")
    CF_TUNNEL_TYPE=$(get_json_value "$SETTINGS_JSON_PATH" "cf_tunnel_type")
    SSL_CERT_PATH=$(get_json_value "$SETTINGS_JSON_PATH" "ssl_cert_path")
    SSL_KEY_PATH=$(get_json_value "$SETTINGS_JSON_PATH" "ssl_key_path")
    PANEL_PATH="${PANEL_PATH:-/var/www/pterodactyl}"

    # Get current install_mode (1=Tunnel, 2=NPM, 3=NPM+Tunnel)
    local mode_line
    mode_line=$(grep -o '"install_mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_JSON_PATH" 2>/dev/null | head -1)
    CURRENT_MODE=$(echo "$mode_line" | sed 's/.*:[[:space:]]*"\(.*\)"/\1/')
    CURRENT_MODE="${CURRENT_MODE:-1}"

    [[ -z "$FQDN" ]] && FQDN="localhost"
    [[ -z "$ADMIN_EMAIL" ]] && ADMIN_EMAIL="admin@localhost"
}

stop_cloudflared_if_active() {
    if systemctl is-active cloudflared-tunnel &>/dev/null; then
        log_info "Stopping Cloudflare tunnel..."
        stop_cloudflared_tunnel
    fi
}

update_wings_api_port() {
    local port="${1:-80}"
    [[ ! -f "$WINGS_CONFIG" ]] && return 0
    sed -i "s/port: [0-9]*/port: $port/" "$WINGS_CONFIG" 2>/dev/null || true
    systemctl restart wings 2>/dev/null || true
}

switch_to_tunnel() {
    local cf_type domain_override
    cf_type=$(echo "${1:-a}" | tr '[:upper:]' '[:lower:]')
    [[ "$cf_type" != "b" ]] && cf_type="a"
    domain_override="${2:-}"
    load_switch_context
    CF_TUNNEL_TYPE="$cf_type"
    [[ -n "$domain_override" ]] && FQDN="$domain_override"

    # Stop old tunnel when reconfiguring (from mode 1 or 3)
    [[ "$CURRENT_MODE" == "1" || "$CURRENT_MODE" == "3" ]] && stop_cloudflared_if_active

    log_info "Switching to Cloudflare Tunnel mode..." >&2
    create_nginx_localhost "$FQDN"

    if [[ "$CF_TUNNEL_TYPE" == "b" ]]; then
        NAMED_TUNNEL_READY=0
        setup_named_tunnel "pterodactyl-panel" "$FQDN"
        local new_url="https://${FQDN}"
        sed -i "s|APP_URL=.*|APP_URL=$new_url|" "$PANEL_PATH/.env" 2>/dev/null || true
        update_settings_mode "1" "$new_url" "b" "" "" "$FQDN"
        update_wings_remote "$new_url" ""
        sudo -u www-data php "$PANEL_PATH/artisan" config:clear 2>/dev/null || true
        if [[ "${NAMED_TUNNEL_READY:-0}" == "1" ]]; then
            log_success "Named tunnel. Panel URL: $new_url"
        else
            log_warn "Complete the 5 steps above before the panel will be reachable"
            log_info "Panel URL (after completing steps): $new_url"
        fi
    else
        local tunnel_url
        tunnel_url=$(setup_quick_tunnel)
        local new_url="${tunnel_url:-https://xxx.trycloudflare.com}"
        sed -i "s|APP_URL=.*|APP_URL=$new_url|" "$PANEL_PATH/.env" 2>/dev/null || true
        update_settings_mode "1" "$new_url" "a"
        update_wings_remote "$new_url" ""
        sudo -u www-data php "$PANEL_PATH/artisan" config:clear 2>/dev/null || true
        log_success "Quick Tunnel: $new_url"
    fi
}

switch_to_cftunnel() {
    switch_to_tunnel "$@"
}

switch_to_npm() {
    load_switch_context
    log_info "Switching to Nginx Proxy Manager mode..." >&2
    stop_cloudflared_if_active
    create_nginx_npm_backend "$FQDN" "8080"
    local new_url="https://${FQDN}"
    sed -i "s|APP_URL=.*|APP_URL=$new_url|" "$PANEL_PATH/.env"
    grep -q "^TRUSTED_PROXIES=" "$PANEL_PATH/.env" 2>/dev/null || echo "TRUSTED_PROXIES=127.0.0.1" >> "$PANEL_PATH/.env"
    sed -i 's|^TRUSTED_PROXIES=.*|TRUSTED_PROXIES=127.0.0.1|' "$PANEL_PATH/.env" 2>/dev/null || true
    update_settings_mode "2" "$new_url" ""
    update_wings_remote "$new_url" "8080"
    sudo -u www-data php "$PANEL_PATH/artisan" config:clear 2>/dev/null || true
    log_success "NPM mode. Add Proxy Host: $FQDN -> 127.0.0.1:8080"
}

switch_to_npm_tunnel() {
    local cf_type domain_override
    cf_type=$(echo "${1:-a}" | tr '[:upper:]' '[:lower:]')
    [[ "$cf_type" != "b" ]] && cf_type="a"
    domain_override="${2:-}"
    load_switch_context
    CF_TUNNEL_TYPE="$cf_type"
    [[ -n "$domain_override" ]] && FQDN="$domain_override"

    log_info "Switching to NPM + Tunnel mode..." >&2
    stop_cloudflared_if_active
    create_nginx_npm_backend "$FQDN" "8080"
    grep -q "^TRUSTED_PROXIES=" "$PANEL_PATH/.env" 2>/dev/null || echo "TRUSTED_PROXIES=127.0.0.1" >> "$PANEL_PATH/.env"
    sed -i 's|^TRUSTED_PROXIES=.*|TRUSTED_PROXIES=127.0.0.1|' "$PANEL_PATH/.env" 2>/dev/null || true

    if [[ "$CF_TUNNEL_TYPE" == "b" ]]; then
        NAMED_TUNNEL_READY=0
        setup_named_tunnel "pterodactyl-panel" "$FQDN" "8080"
        local new_url="https://${FQDN} (NPM + CF tunnel)"
        sed -i "s|APP_URL=.*|APP_URL=$new_url|" "$PANEL_PATH/.env" 2>/dev/null || true
        update_settings_mode "3" "$new_url" "b" "" "" "$FQDN"
        update_wings_remote "https://${FQDN}" "8080"
        if [[ "${NAMED_TUNNEL_READY:-0}" == "1" ]]; then
            log_success "Named tunnel + NPM. Panel URL: $new_url"
        else
            log_warn "Complete the 5 steps above before the panel will be reachable"
            log_info "Panel URL (after completing steps): $new_url"
        fi
    else
        local tunnel_url
        tunnel_url=$(setup_quick_tunnel_to_port "8080")
        local new_url="https://${FQDN} (NPM) + ${tunnel_url:-https://xxx.trycloudflare.com} (Tunnel)"
        [[ -z "$tunnel_url" ]] && new_url="https://${FQDN} (NPM) + (journalctl -u cloudflared-tunnel -f for Tunnel)"
        sed -i "s|APP_URL=.*|APP_URL=$new_url|" "$PANEL_PATH/.env" 2>/dev/null || true
        update_settings_mode "3" "$new_url" "a"
        update_wings_remote "https://${FQDN}" "8080"
        log_success "NPM + Quick Tunnel: $new_url"
    fi
    sudo -u www-data php "$PANEL_PATH/artisan" config:clear 2>/dev/null || true
}

show_wings_next_steps() {
    local mode="${1:-1}"
    local fqdn="${2:-localhost}"
    local panel_url="${3:-}"

    echo "" >&2
    echo "==============================================" >&2
    echo "  Next Steps for Wings (Mode $mode)" >&2
    echo "==============================================" >&2
    echo "" >&2
    case "$mode" in
        1)
            log_info "Mode 1: Tunnel (Cloudflare)" >&2
            echo "  - Panel + Wings API: no ports (Tunnel handles Panel)" >&2
            echo "  - Start Wings: systemctl start wings" >&2
            echo "  - Access Panel: $panel_url" >&2
            ;;
        2)
            log_info "Mode 2: Nginx Proxy Manager" >&2
            echo "  - Add Proxy Host in NPM: $fqdn -> 127.0.0.1:8080" >&2
            echo "  - Wings API connects to panel at 127.0.0.1:8080" >&2
            echo "  - Start Wings: systemctl start wings" >&2
            echo "  - Access Panel: https://${fqdn}" >&2
            ;;
        3)
            log_info "Mode 3: NPM + Tunnel" >&2
            echo "  - Add Proxy Host in NPM: $fqdn -> 127.0.0.1:8080" >&2
            echo "  - Optional: Cloudflare Tunnel for external access" >&2
            echo "  - Start Wings: systemctl start wings" >&2
            echo "  - Access Panel: https://${fqdn} or trycloudflare URL" >&2
            ;;
        *)
            echo "  - Start Wings: systemctl start wings" >&2
            echo "  - Access Panel: $panel_url" >&2
            ;;
    esac
    echo "" >&2
    echo "  Required ports (open in firewall):" >&2
    echo "    - 2022/tcp  SFTP (file uploads) - cannot use Cloudflare proxy" >&2
    echo "    - Game ports from Panel Allocations (e.g. 25565, 27015)" >&2
    echo "  Example: ufw allow 2022/tcp && ufw allow 25565/tcp && ufw reload" >&2
    echo "  Node settings in Panel: FQDN=$fqdn, Behind Proxy=Yes, Use SSL=Yes" >&2
    if [[ "$mode" == "1" ]]; then
        echo "  Wings connects to Panel via Tunnel URL (HTTPS, TLS verify disabled)" >&2
    else
        echo "  Wings connects to Panel at http://127.0.0.1 (local - no TLS verify needed)" >&2
    fi
    echo "" >&2
}

run_configure_wings() {
    if ! is_panel_installed; then
        log_error "Panel not installed. Run Fresh Install first."
        exit 1
    fi
    load_switch_context
    [[ -z "$FQDN" ]] && FQDN="localhost"
    local mode
    mode=$(grep -o '"install_mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_JSON_PATH" 2>/dev/null | sed 's/.*"\([123]\)".*/\1/' || echo "1")
    local panel_url
    panel_url=$(get_json_value "$SETTINGS_JSON_PATH" "panel_url")
    panel_url="${panel_url:-https://${FQDN}}"

    echo "" >&2
    echo "==============================================" >&2
    echo "  Configure Wings from Panel" >&2
    echo "==============================================" >&2
    echo "" >&2
    echo "1. Login to Panel: $panel_url" >&2
    echo "2. Nodes -> Create Node (or select existing)" >&2
    echo "3. Configuration tab -> Copy the deployment command" >&2
    echo "" >&2
    local input
    input=$(tui_input "Configure Wings" "Paste deployment URL or full command:\n\nPanel: $panel_url\n\nURL or command:" "") 2>/dev/null || true
    if [[ -z "$input" ]]; then
        log_info "Paste the deployment URL (e.g. https://panel.example.com/api/application/nodes/1/configuration)" >&2
        log_info "Or paste the full command (we will extract the URL)" >&2
        echo "" >&2
        prompt_read "Deployment URL or command: "
        input="${REPLY:-}"
    fi
    input=$(echo "$input" | xargs)
    [[ -z "$input" ]] && { log_error "Empty input. Aborted." >&2; return 1; }

    local url="$input"
    if [[ "$input" == curl* ]]; then
        url=$(echo "$input" | grep -oE 'https?://[^|[:space:]]+' | head -1)
    fi
    [[ -z "$url" ]] && { log_error "Could not extract URL. Paste the deployment URL." >&2; return 1; }

    log_info "Fetching and applying Wings config from Panel..." >&2
    if curl -sSL "$url" | sudo -E bash; then
        log_success "Deployment script executed" >&2
    else
        log_error "Deployment failed. Check the URL and Panel accessibility." >&2
        return 1
    fi

    [[ ! -f "$WINGS_CONFIG" ]] && { log_error "Wings config not found at $WINGS_CONFIG" >&2; return 1; }

    local backend_port=""
    [[ "$mode" == "2" || "$mode" == "3" ]] && backend_port="8080"
    if [[ -n "$backend_port" ]]; then
        log_info "Adjusting Wings for Mode $mode (127.0.0.1:$backend_port)..." >&2
    else
        log_info "Adjusting Wings for Mode $mode (Tunnel URL + TLS verify disabled)..." >&2
    fi
    sed -i 's/host:[[:space:]]*[^[:space:]]*/host: 127.0.0.1/' "$WINGS_CONFIG" 2>/dev/null || true
    update_wings_remote "$panel_url" "$backend_port"
    sed -i 's/"wings_installed":[[:space:]]*false/"wings_installed": true/' "$SETTINGS_JSON_PATH" 2>/dev/null || true
    log_success "Wings config applied" >&2

    show_wings_next_steps "$mode" "$FQDN" "$panel_url"
}

update_settings_mode() {
    local mode="$1"
    local panel_url="$2"
    local cf_type="${3:-}"
    local cert_path="${4:-}"
    local key_path="${5:-}"
    local fqdn_override="${6:-}"

    if [[ ! -f "$SETTINGS_JSON_PATH" ]]; then
        return 0
    fi

    # Update install_mode and panel_url in JSON (simple sed replacement)
    sed -i "s|\"install_mode\":[[:space:]]*\"[^\"]*\"|\"install_mode\": \"$mode\"|" "$SETTINGS_JSON_PATH"
    sed -i "s|\"panel_url\":[[:space:]]*\"[^\"]*\"|\"panel_url\": \"$panel_url\"|" "$SETTINGS_JSON_PATH"
    [[ -n "$fqdn_override" ]] && sed -i "s|\"fqdn\":[[:space:]]*\"[^\"]*\"|\"fqdn\": \"$fqdn_override\"|" "$SETTINGS_JSON_PATH" 2>/dev/null || true
    sed -i "s|\"cf_tunnel_type\":[[:space:]]*\"[^\"]*\"|\"cf_tunnel_type\": \"$cf_type\"|" "$SETTINGS_JSON_PATH" 2>/dev/null || true
    if [[ -n "$cert_path" ]] && grep -q '"ssl_cert_path"' "$SETTINGS_JSON_PATH" 2>/dev/null; then
        sed -i "s|\"ssl_cert_path\":[[:space:]]*\"[^\"]*\"|\"ssl_cert_path\": \"$(echo "$cert_path" | sed 's/\\/\\\\/g; s/"/\\"/g')\"|" "$SETTINGS_JSON_PATH"
    fi
    if [[ -n "$key_path" ]] && grep -q '"ssl_key_path"' "$SETTINGS_JSON_PATH" 2>/dev/null; then
        sed -i "s|\"ssl_key_path\":[[:space:]]*\"[^\"]*\"|\"ssl_key_path\": \"$(echo "$key_path" | sed 's/\\/\\\\/g; s/"/\\"/g')\"|" "$SETTINGS_JSON_PATH"
    fi
}
