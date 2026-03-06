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
    local cf_type
    cf_type=$(echo "${1:-a}" | tr '[:upper:]' '[:lower:]')
    [[ "$cf_type" != "b" ]] && cf_type="a"
    load_switch_context
    CF_TUNNEL_TYPE="$cf_type"

    # Stop old tunnel when reconfiguring (from mode 1 or 3)
    [[ "$CURRENT_MODE" == "1" || "$CURRENT_MODE" == "3" ]] && stop_cloudflared_if_active

    log_info "Switching to Cloudflare Tunnel mode..." >&2
    create_nginx_localhost "$FQDN"

    if [[ "$CF_TUNNEL_TYPE" == "b" ]]; then
        setup_named_tunnel "pterodactyl-panel" "$FQDN"
        local new_url="https://${FQDN}"
        sed -i "s|APP_URL=.*|APP_URL=$new_url|" "$PANEL_PATH/.env" 2>/dev/null || true
        update_settings_mode "1" "$new_url" "b"
        update_wings_api_port "80"
        sudo -u www-data php "$PANEL_PATH/artisan" config:clear 2>/dev/null || true
        log_success "Named tunnel. Panel URL: $new_url"
    else
        local tunnel_url
        tunnel_url=$(setup_quick_tunnel)
        local new_url="${tunnel_url:-https://xxx.trycloudflare.com}"
        sed -i "s|APP_URL=.*|APP_URL=$new_url|" "$PANEL_PATH/.env" 2>/dev/null || true
        update_settings_mode "1" "$new_url" "a"
        update_wings_api_port "80"
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
    update_wings_api_port "8080"
    sudo -u www-data php "$PANEL_PATH/artisan" config:clear 2>/dev/null || true
    log_success "NPM mode. Add Proxy Host: $FQDN -> 127.0.0.1:8080"
}

switch_to_npm_tunnel() {
    local cf_type
    cf_type=$(echo "${1:-a}" | tr '[:upper:]' '[:lower:]')
    [[ "$cf_type" != "b" ]] && cf_type="a"
    load_switch_context
    CF_TUNNEL_TYPE="$cf_type"

    log_info "Switching to NPM + Tunnel mode..." >&2
    stop_cloudflared_if_active
    create_nginx_npm_backend "$FQDN" "8080"
    grep -q "^TRUSTED_PROXIES=" "$PANEL_PATH/.env" 2>/dev/null || echo "TRUSTED_PROXIES=127.0.0.1" >> "$PANEL_PATH/.env"
    sed -i 's|^TRUSTED_PROXIES=.*|TRUSTED_PROXIES=127.0.0.1|' "$PANEL_PATH/.env" 2>/dev/null || true

    if [[ "$CF_TUNNEL_TYPE" == "b" ]]; then
        setup_named_tunnel "pterodactyl-panel" "$FQDN" "8080"
        local new_url="https://${FQDN} (NPM + CF tunnel)"
        sed -i "s|APP_URL=.*|APP_URL=$new_url|" "$PANEL_PATH/.env" 2>/dev/null || true
        update_settings_mode "3" "$new_url" "b"
        update_wings_api_port "8080"
        log_success "Named tunnel + NPM. Panel URL: $new_url"
    else
        local tunnel_url
        tunnel_url=$(setup_quick_tunnel_to_port "8080")
        local new_url="https://${FQDN} (NPM) + ${tunnel_url:-https://xxx.trycloudflare.com} (Tunnel)"
        [[ -z "$tunnel_url" ]] && new_url="https://${FQDN} (NPM) + (journalctl -u cloudflared-tunnel -f for Tunnel)"
        sed -i "s|APP_URL=.*|APP_URL=$new_url|" "$PANEL_PATH/.env" 2>/dev/null || true
        update_settings_mode "3" "$new_url" "a"
        update_wings_api_port "8080"
        log_success "NPM + Quick Tunnel: $new_url"
    fi
    sudo -u www-data php "$PANEL_PATH/artisan" config:clear 2>/dev/null || true
}

update_settings_mode() {
    local mode="$1"
    local panel_url="$2"
    local cf_type="${3:-}"
    local cert_path="${4:-}"
    local key_path="${5:-}"

    if [[ ! -f "$SETTINGS_JSON_PATH" ]]; then
        return 0
    fi

    # Update install_mode and panel_url in JSON (simple sed replacement)
    sed -i "s|\"install_mode\":[[:space:]]*\"[^\"]*\"|\"install_mode\": \"$mode\"|" "$SETTINGS_JSON_PATH"
    sed -i "s|\"panel_url\":[[:space:]]*\"[^\"]*\"|\"panel_url\": \"$panel_url\"|" "$SETTINGS_JSON_PATH"
    # Always update cf_tunnel_type (empty string for NPM mode 2)
    sed -i "s|\"cf_tunnel_type\":[[:space:]]*\"[^\"]*\"|\"cf_tunnel_type\": \"$cf_type\"|" "$SETTINGS_JSON_PATH" 2>/dev/null || true
    if [[ -n "$cert_path" ]] && grep -q '"ssl_cert_path"' "$SETTINGS_JSON_PATH" 2>/dev/null; then
        sed -i "s|\"ssl_cert_path\":[[:space:]]*\"[^\"]*\"|\"ssl_cert_path\": \"$(echo "$cert_path" | sed 's/\\/\\\\/g; s/"/\\"/g')\"|" "$SETTINGS_JSON_PATH"
    fi
    if [[ -n "$key_path" ]] && grep -q '"ssl_key_path"' "$SETTINGS_JSON_PATH" 2>/dev/null; then
        sed -i "s|\"ssl_key_path\":[[:space:]]*\"[^\"]*\"|\"ssl_key_path\": \"$(echo "$key_path" | sed 's/\\/\\\\/g; s/"/\\"/g')\"|" "$SETTINGS_JSON_PATH"
    fi
}
