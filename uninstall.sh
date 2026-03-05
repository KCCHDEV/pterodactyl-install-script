#!/usr/bin/env bash
# Pterodactyl Panel Uninstaller
# Removes panel, wings, nginx config, database, CF tunnel

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/lib/common.sh"

PANEL_PATH="${PANEL_PATH:-/var/www/pterodactyl}"
NGINX_AVAILABLE="/etc/nginx/sites-available/pterodactyl.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/pterodactyl.conf"
WINGS_CONFIG="/etc/pterodactyl/config.yml"
WINGS_BINARY="/usr/local/bin/wings"
CREDENTIALS_FILE="/root/pterodactyl-credentials.txt"
WINGS_INSTALLED=true

# Load from settings JSON if exists
if [[ -f "$SETTINGS_JSON_PATH" ]]; then
    PANEL_PATH=$(get_json_value "$SETTINGS_JSON_PATH" "panel_path")
    DB_NAME=$(get_json_value "$SETTINGS_JSON_PATH" "db_name")
    DB_USER=$(get_json_value "$SETTINGS_JSON_PATH" "db_user")
    WINGS_VAL=$(grep -o '"wings_installed"[[:space:]]*:[[:space:]]*[a-z]*' "$SETTINGS_JSON_PATH" 2>/dev/null | grep -o 'true\|false' | head -1)
    [[ "$WINGS_VAL" == "false" ]] && WINGS_INSTALLED=false
fi
PANEL_PATH="${PANEL_PATH:-/var/www/pterodactyl}"
# Fallback to .env if JSON didn't have DB info
if [[ -z "$DB_NAME" && -f "$PANEL_PATH/.env" ]]; then
    DB_NAME=$(grep "^DB_DATABASE=" "$PANEL_PATH/.env" 2>/dev/null | cut -d= -f2)
fi
if [[ -z "$DB_USER" && -f "$PANEL_PATH/.env" ]]; then
    DB_USER=$(grep "^DB_USERNAME=" "$PANEL_PATH/.env" 2>/dev/null | cut -d= -f2)
fi
DB_NAME="${DB_NAME:-panel}"
DB_USER="${DB_USER:-pterodactyl}"

confirm_uninstall() {
    echo ""
    echo "=============================================="
    echo "  Pterodactyl Panel UNINSTALLER"
    echo "=============================================="
    echo ""
    log_warn "This will PERMANENTLY remove:"
    echo "  - Panel files ($PANEL_PATH)"
    [[ "$WINGS_INSTALLED" == "true" ]] && echo "  - Wings daemon"
    echo "  - Nginx config"
    echo "  - Database ($DB_NAME)"
    echo "  - Cloudflare tunnel (if installed)"
    echo ""
    read -rp "Type 'yes' or the panel domain to confirm: " confirm
    if [[ "$confirm" != "yes" ]] && [[ "$confirm" != "YES" ]]; then
        # Allow domain as confirmation
        if [[ ! -d "$PANEL_PATH" ]]; then
            log_error "Aborted."
            exit 1
        fi
        # Check if input matches common domain patterns
        if [[ ! "$confirm" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && [[ "$confirm" != "localhost" ]]; then
            log_error "Confirmation failed. Aborted."
            exit 1
        fi
    fi
    log_info "Proceeding with uninstall..."
}

stop_services() {
    log_info "Stopping services..."
    systemctl stop pteroq 2>/dev/null || true
    systemctl stop wings 2>/dev/null || true
    systemctl stop cloudflared-tunnel 2>/dev/null || true
    systemctl disable pteroq 2>/dev/null || true
    systemctl disable wings 2>/dev/null || true
    systemctl disable cloudflared-tunnel 2>/dev/null || true
    pkill -f "cloudflared tunnel" 2>/dev/null || true
    log_success "Services stopped"
}

remove_panel() {
    if [[ -d "$PANEL_PATH" ]]; then
        log_info "Removing panel files..."
        rm -rf "$PANEL_PATH"
        log_success "Panel removed"
    fi

    if [[ -f /etc/systemd/system/pteroq.service ]]; then
        rm -f /etc/systemd/system/pteroq.service
        systemctl daemon-reload
        log_success "pteroq service removed"
    fi
}

remove_wings() {
    if [[ -f "$WINGS_BINARY" ]]; then
        log_info "Removing Wings..."
        rm -f "$WINGS_BINARY"
        log_success "Wings binary removed"
    fi

    if [[ -d /etc/pterodactyl ]]; then
        rm -rf /etc/pterodactyl
        log_success "Wings config removed"
    fi

    if [[ -d /var/lib/pterodactyl ]]; then
        rm -rf /var/lib/pterodactyl
        log_success "Wings data removed"
    fi

    if [[ -f /etc/systemd/system/wings.service ]]; then
        rm -f /etc/systemd/system/wings.service
        systemctl daemon-reload
        log_success "wings service removed"
    fi

    if id pterodactyl &>/dev/null; then
        userdel pterodactyl 2>/dev/null || true
        log_success "pterodactyl user removed"
    fi
}

remove_nginx() {
    if [[ -f "$NGINX_ENABLED" ]] || [[ -L "$NGINX_ENABLED" ]]; then
        log_info "Removing Nginx config..."
        rm -f "$NGINX_ENABLED"
    fi
    if [[ -f "$NGINX_AVAILABLE" ]]; then
        rm -f "$NGINX_AVAILABLE"
    fi
    systemctl reload nginx 2>/dev/null || true
    log_success "Nginx config removed"
}

remove_database() {
    log_info "Removing database..."
    mysql -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;" 2>/dev/null || true
    mysql -e "DROP USER IF EXISTS '$DB_USER'@'127.0.0.1';" 2>/dev/null || true
    mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    log_success "Database removed"
}

remove_cloudflared() {
    if [[ -f /etc/systemd/system/cloudflared-tunnel.service ]]; then
        log_info "Removing Cloudflare tunnel..."
        systemctl stop cloudflared-tunnel 2>/dev/null || true
        systemctl disable cloudflared-tunnel 2>/dev/null || true
        rm -f /etc/systemd/system/cloudflared-tunnel.service
        systemctl daemon-reload
        pkill -f "cloudflared" 2>/dev/null || true
        log_success "Cloudflare tunnel removed"
    fi
}

remove_credentials() {
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        rm -f "$CREDENTIALS_FILE"
        log_success "Credentials file removed"
    fi
}

remove_settings_json() {
    if [[ -f "$SETTINGS_JSON_PATH" ]]; then
        rm -f "$SETTINGS_JSON_PATH"
        log_success "Settings file removed"
    fi
}

remove_installer_copy() {
    if [[ -d /opt/pterodactyl-install-script ]]; then
        rm -rf /opt/pterodactyl-install-script
        log_success "Installer copy removed from /opt"
    fi
}

remove_saved_config() {
    rm -f /root/.pterodactyl-install-config 2>/dev/null && log_success "Saved install config removed" || true
}

run_uninstall() {
    check_root
    confirm_uninstall

    stop_services
    remove_panel
    [[ "$WINGS_INSTALLED" == "true" ]] && remove_wings
    remove_nginx
    remove_database
    remove_cloudflared
    remove_credentials
    remove_settings_json
    remove_installer_copy
    remove_saved_config

    echo ""
    log_success "Uninstall complete."
    echo ""
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_uninstall
fi
