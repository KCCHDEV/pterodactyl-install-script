#!/usr/bin/env bash
# Pterodactyl Panel - Switch Mode (HTTP / HTTPS / CF Tunnel)
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

    # Get current install_mode (1=HTTP, 2=HTTPS, 3=CF, 4=CF Proxy)
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

switch_to_http() {
    load_switch_context
    log_info "Switching to HTTP mode..."
    stop_cloudflared_if_active
    create_nginx_http "$FQDN"
    local new_url="http://${FQDN}"
    sed -i "s|APP_URL=.*|APP_URL=$new_url|" "$PANEL_PATH/.env"
    update_settings_mode "1" "$new_url" ""
    log_success "Switched to HTTP. Panel URL: $new_url"
}

switch_to_https() {
    load_switch_context
    log_info "Switching to HTTPS mode (Let's Encrypt)..."
    install_certbot 2>/dev/null || true
    stop_cloudflared_if_active
    create_nginx_https "$FQDN" "$ADMIN_EMAIL"
    local new_url="https://${FQDN}"
    sed -i "s|APP_URL=.*|APP_URL=$new_url|" "$PANEL_PATH/.env"
    update_settings_mode "2" "$new_url" ""
    log_success "Switched to HTTPS. Panel URL: $new_url"
}

switch_to_cloudflare_proxy() {
    load_switch_context
    log_info "Switching to Cloudflare Proxy mode..."

    local cert_path="${SSL_CERT_PATH:-/etc/ssl/cert.pem}"
    local key_path="${SSL_KEY_PATH:-/etc/ssl/key.pem}"

    if [[ -e /dev/tty ]]; then
        read -rp "SSL cert path [$cert_path]: " < /dev/tty || true
        [[ -n "$REPLY" ]] && cert_path="$REPLY"
        read -rp "SSL key path [$key_path]: " < /dev/tty || true
        [[ -n "$REPLY" ]] && key_path="$REPLY"
        if [[ ! -f "$cert_path" ]] || [[ ! -f "$key_path" ]]; then
            read -rp "Certificate not found. Generate self-signed SSL? [Y/n]: " < /dev/tty || true
            if [[ "${REPLY:-Y}" =~ ^[yY] ]]; then
                generate_self_signed_ssl "$cert_path" "$key_path" "$FQDN"
            fi
        fi
    fi

    stop_cloudflared_if_active
    create_nginx_cloudflare_proxy "$FQDN" "$cert_path" "$key_path"

    local new_url="https://${FQDN}"
    sed -i "s|APP_URL=.*|APP_URL=$new_url|" "$PANEL_PATH/.env"
    update_settings_mode "4" "$new_url" "" "$cert_path" "$key_path"
    log_success "Switched to Cloudflare Proxy. Panel URL: $new_url"
}

switch_to_cftunnel() {
    local cf_type
    cf_type=$(echo "${1:-a}" | tr '[:upper:]' '[:lower:]')
    [[ "$cf_type" != "b" ]] && cf_type="a"
    load_switch_context
    CF_TUNNEL_TYPE="$cf_type"

    log_info "Switching to Cloudflare Tunnel mode..."
    create_nginx_localhost "$FQDN"

    if [[ "$CF_TUNNEL_TYPE" == "b" ]]; then
        setup_named_tunnel "pterodactyl-panel" "$FQDN"
        local new_url="https://${FQDN}"
        sed -i "s|APP_URL=.*|APP_URL=$new_url|" "$PANEL_PATH/.env" 2>/dev/null || true
        update_settings_mode "3" "$new_url" "b"
        sudo -u www-data php "$PANEL_PATH/artisan" config:clear 2>/dev/null || true
        log_success "Named tunnel. Panel URL: $new_url"
    else
        local tunnel_url
        tunnel_url=$(setup_quick_tunnel)
        local new_url="${tunnel_url:-https://xxx.trycloudflare.com}"
        sed -i "s|APP_URL=.*|APP_URL=$new_url|" "$PANEL_PATH/.env" 2>/dev/null || true
        update_settings_mode "3" "$new_url" "a"
        sudo -u www-data php "$PANEL_PATH/artisan" config:clear 2>/dev/null || true
        log_success "Quick Tunnel: $new_url"
    fi
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
    if [[ -n "$cf_type" ]]; then
        sed -i "s|\"cf_tunnel_type\":[[:space:]]*\"[^\"]*\"|\"cf_tunnel_type\": \"$cf_type\"|" "$SETTINGS_JSON_PATH" 2>/dev/null || true
    fi
    if [[ -n "$cert_path" ]] && grep -q '"ssl_cert_path"' "$SETTINGS_JSON_PATH" 2>/dev/null; then
        sed -i "s|\"ssl_cert_path\":[[:space:]]*\"[^\"]*\"|\"ssl_cert_path\": \"$(echo "$cert_path" | sed 's/\\/\\\\/g; s/"/\\"/g')\"|" "$SETTINGS_JSON_PATH"
    fi
    if [[ -n "$key_path" ]] && grep -q '"ssl_key_path"' "$SETTINGS_JSON_PATH" 2>/dev/null; then
        sed -i "s|\"ssl_key_path\":[[:space:]]*\"[^\"]*\"|\"ssl_key_path\": \"$(echo "$key_path" | sed 's/\\/\\\\/g; s/"/\\"/g')\"|" "$SETTINGS_JSON_PATH"
    fi
}
