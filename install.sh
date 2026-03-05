#!/usr/bin/env bash
# Pterodactyl Panel Auto Installer
# One-time input, then full automatic installation
# Run via: curl -sSL https://raw.githubusercontent.com/KCCHDEV/pterodactyl-install-script/refs/heads/main/install.sh | sudo bash

set -e

GITHUB_REPO="https://github.com/KCCHDEV/pterodactyl-install-script"
get_script_dir() {
    if [[ -n "${BASH_SOURCE[0]}" && -f "${BASH_SOURCE[0]}" ]]; then
        cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
    else
        echo ""
    fi
}
INSTALLER_ROOT=$(get_script_dir)
if [[ -z "$INSTALLER_ROOT" || ! -d "$INSTALLER_ROOT/lib" ]]; then
    log_bootstrap() { echo "[INFO] $*"; }
    log_bootstrap "Downloading installer from GitHub..."
    TMP_DIR=$(mktemp -d)
    curl -sSL "${GITHUB_REPO}/archive/main.tar.gz" | tar xz -C "$TMP_DIR"
    EXTRACTED=$(ls -d "$TMP_DIR"/*/ 2>/dev/null | head -1)
    if [[ -n "$EXTRACTED" && -d "$EXTRACTED" ]]; then
        exec bash "$EXTRACTED/install.sh"
    else
        echo "[ERROR] Failed to download. Clone the repo and run: sudo ./install.sh"
        exit 1
    fi
fi

for lib in common dependencies panel wings ssl cftunnel; do
    # shellcheck source=/dev/null
    source "$INSTALLER_ROOT/lib/$lib.sh"
done

# Config variables (set by prompt)
INSTALL_MODE=""
FQDN=""
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
ADMIN_USERNAME="admin"
DB_NAME="panel"
DB_USER="pterodactyl"
DB_PASSWORD=""
APP_URL=""
CF_TUNNEL_TYPE=""
FINAL_PANEL_URL=""

prompt_inputs() {
    echo ""
    echo "=============================================="
    echo "  Pterodactyl Panel Auto Installer"
    echo "=============================================="
    echo ""

    read -rp "FQDN/Domain (e.g. panel.example.com): " FQDN
    FQDN="${FQDN:-localhost}"
    if [[ "$FQDN" == "localhost" ]]; then
        log_warn "Using localhost - suitable for HTTP dev mode only"
    fi

    read -rp "Admin Email: " ADMIN_EMAIL
    while [[ -z "$ADMIN_EMAIL" ]]; do
        read -rp "Admin Email (required): " ADMIN_EMAIL
    done

    read -rsp "Admin Password: " ADMIN_PASSWORD
    echo ""
    while [[ ${#ADMIN_PASSWORD} -lt 8 ]]; do
        read -rsp "Admin Password (min 8 chars): " ADMIN_PASSWORD
        echo ""
    done

    echo ""
    echo "Install Mode:"
    echo "  1) HTTP  - Development, no SSL"
    echo "  2) HTTPS - Let's Encrypt SSL (domain must point to this server)"
    echo "  3) Cloudflare Tunnel - No port open, use trycloudflare.com or your domain"
    read -rp "Choice [1-3]: " INSTALL_MODE
    INSTALL_MODE="${INSTALL_MODE:-1}"

    if [[ "$INSTALL_MODE" == "3" ]]; then
        echo "  a) Quick Tunnel - Free, no account, get xxx.trycloudflare.com URL"
        echo "  b) Named Tunnel - Use your domain, requires Cloudflare account"
        read -rp "CF Tunnel type [a/b]: " CF_TUNNEL_TYPE
        CF_TUNNEL_TYPE="${CF_TUNNEL_TYPE:-a}"
    fi

    read -rp "DB Password for pterodactyl (or Enter to auto-generate): " DB_PASSWORD
    if [[ -z "$DB_PASSWORD" ]]; then
        DB_PASSWORD=$(generate_random_password)
        log_info "Generated DB password"
    fi

    read -rp "Install Wings (game server daemon)? [Y/n]: " INSTALL_WINGS
    INSTALL_WINGS="${INSTALL_WINGS:-Y}"

    # Set APP_URL based on mode
    case "$INSTALL_MODE" in
        1) APP_URL="http://${FQDN}" ;;
        2) APP_URL="https://${FQDN}" ;;
        3)
            if [[ "$CF_TUNNEL_TYPE" == "a" ]]; then
                APP_URL="https://placeholder.trycloudflare.com"
            else
                APP_URL="https://${FQDN}"
            fi
            ;;
        *) APP_URL="http://${FQDN}" ;;
    esac

    # Save config for lib scripts
    cat > "$INSTALLER_ROOT/.install-config" << CONFIG
export FQDN="$FQDN"
export ADMIN_EMAIL="$ADMIN_EMAIL"
export ADMIN_PASSWORD="$ADMIN_PASSWORD"
export ADMIN_USERNAME="$ADMIN_USERNAME"
export DB_NAME="$DB_NAME"
export DB_USER="$DB_USER"
export DB_PASSWORD="$DB_PASSWORD"
export APP_URL="$APP_URL"
export INSTALL_MODE="$INSTALL_MODE"
export CF_TUNNEL_TYPE="$CF_TUNNEL_TYPE"
export INSTALL_WINGS="$INSTALL_WINGS"
CONFIG
}

create_database() {
    log_info "Creating database and user..."
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;" 2>/dev/null || true
    mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';" 2>/dev/null || true
    mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1';"
    mysql -e "FLUSH PRIVILEGES;"
    log_success "Database created"
}

save_settings_json() {
    local panel_url="${1}"
    local wings_installed="${2}"
    local install_date
    install_date=$(date -Iseconds 2>/dev/null || date "+%Y-%m-%dT%H:%M:%S")
    cat > "$SETTINGS_JSON_PATH" << JSON
{
  "version": "1",
  "install_date": "$install_date",
  "fqdn": "$FQDN",
  "admin_email": "$ADMIN_EMAIL",
  "admin_username": "$ADMIN_USERNAME",
  "install_mode": "$INSTALL_MODE",
  "cf_tunnel_type": "${CF_TUNNEL_TYPE:-}",
  "db_name": "$DB_NAME",
  "db_user": "$DB_USER",
  "panel_url": "$panel_url",
  "wings_installed": $wings_installed,
  "panel_path": "$PANEL_PATH"
}
JSON
    chmod 600 "$SETTINGS_JSON_PATH"
    log_success "Settings saved to $SETTINGS_JSON_PATH"
}

save_credentials() {
    local panel_url="${1}"
    cat > "$CREDENTIALS_FILE" << CREDS
========================================
Pterodactyl Panel - Installation Complete
========================================

Panel URL: $panel_url
Admin Email: $ADMIN_EMAIL
Admin Username: $ADMIN_USERNAME
Admin Password: (the one you set)

Database:
  Name: $DB_NAME
  User: $DB_USER
  Password: $DB_PASSWORD

Node Setup (required for game servers):
  1. Login to panel
  2. Go to Nodes -> Locations -> Create (e.g. "Default")
  3. Go to Nodes -> Create Node
     - Name: Main
     - FQDN: $FQDN (or your server IP)
     - Memory/Disk: Set as needed
  4. After creating node, go to Configuration tab
  5. Run the deployment command shown there on this server

========================================
CREDS
    chmod 600 "$CREDENTIALS_FILE"
    log_success "Credentials saved to $CREDENTIALS_FILE"
}

run_install() {
    check_root
    check_os
    check_disk_space

    prompt_inputs
    # shellcheck source=/dev/null
    source "$INSTALLER_ROOT/.install-config"

    log_info "Starting installation..."

    local install_docker=1
    if [[ "$INSTALL_WINGS" != "y" && "$INSTALL_WINGS" != "Y" && "$INSTALL_WINGS" != "yes" && -n "$INSTALL_WINGS" ]]; then
        install_docker=0
    fi

    # Dependencies
    local need_ssl=0
    [[ "$INSTALL_MODE" == "2" ]] && need_ssl=1
    install_all_dependencies "$need_ssl" "$install_docker"

    # Database
    create_database

    # Panel
    install_panel "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$APP_URL" ""

    # Nginx
    case "$INSTALL_MODE" in
        1)
            create_nginx_http "$FQDN"
            FINAL_PANEL_URL="http://${FQDN}"
            ;;
        2)
            create_nginx_https "$FQDN" "$ADMIN_EMAIL"
            FINAL_PANEL_URL="https://${FQDN}"
            ;;
        3)
            create_nginx_localhost "$FQDN"
            if [[ "$CF_TUNNEL_TYPE" == "a" ]]; then
                local tunnel_url
                tunnel_url=$(setup_quick_tunnel)
                FINAL_PANEL_URL="${tunnel_url:-https://xxx.trycloudflare.com}"
                [[ -z "$tunnel_url" ]] && FINAL_PANEL_URL="(run: journalctl -u cloudflared-tunnel -f to see URL)"
            else
                setup_named_tunnel "pterodactyl-panel" "$FQDN"
                FINAL_PANEL_URL="https://${FQDN} (complete CF tunnel login first)"
            fi
            ;;
        *)
            create_nginx_http "$FQDN"
            FINAL_PANEL_URL="http://${FQDN}"
            ;;
    esac

    # Update panel .env APP_URL with final URL
    sed -i "s|APP_URL=.*|APP_URL=$FINAL_PANEL_URL|" "$PANEL_PATH/.env"

    local wings_installed=false
    if [[ "$INSTALL_WINGS" == "y" || "$INSTALL_WINGS" == "Y" || "$INSTALL_WINGS" == "yes" || -z "$INSTALL_WINGS" ]]; then
        install_wings "$FINAL_PANEL_URL" ""
        systemctl enable wings 2>/dev/null || true
        wings_installed=true
    else
        log_info "Skipping Wings installation"
    fi

    save_settings_json "$FINAL_PANEL_URL" "$wings_installed"
    save_credentials "$FINAL_PANEL_URL"

    # Copy installer to /opt for uninstall/cleaner access
    if [[ -d "$INSTALLER_ROOT/lib" ]]; then
        mkdir -p /opt/pterodactyl-install-script
        cp -r "$INSTALLER_ROOT"/* /opt/pterodactyl-install-script/ 2>/dev/null || true
        chmod +x /opt/pterodactyl-install-script/*.sh 2>/dev/null || true
    fi

    echo ""
    echo "=============================================="
    log_success "Installation complete!"
    echo "=============================================="
    echo ""
    echo "Panel URL: $FINAL_PANEL_URL"
    echo "Settings: $SETTINGS_JSON_PATH"
    echo "Uninstall: sudo /opt/pterodactyl-install-script/uninstall.sh"
    echo ""
    echo "Next steps:"
    echo "  1. Login with admin / (your password)"
    echo "  2. Create Location and Node (see $CREDENTIALS_FILE)"
    if [[ "$wings_installed" == "true" ]]; then
        echo "  3. Run the node deployment command from panel Configuration"
        echo "  4. Start Wings: systemctl start wings"
    else
        echo "  3. To install Wings later, run the installer again or use install-wings.sh"
    fi
    echo ""
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_install
fi
