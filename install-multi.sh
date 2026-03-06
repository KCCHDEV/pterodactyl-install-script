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
    # Fetch latest commit SHA to bypass CDN cache (~5 min)
    LATEST_SHA=$(curl -sSL "https://api.github.com/repos/KCCHDEV/pterodactyl-install-script/commits/main" 2>/dev/null | grep -o '"sha":[[:space:]]*"[a-f0-9]*"' | head -1 | sed 's/.*"\([a-f0-9]*\)".*/\1/')
    ARCHIVE_REF="${LATEST_SHA:-main}"
    curl -sSL -H "Cache-Control: no-cache" -H "Pragma: no-cache" "${GITHUB_REPO}/archive/${ARCHIVE_REF}.tar.gz" | tar xz -C "$TMP_DIR"
    EXTRACTED=$(ls -d "$TMP_DIR"/*/ 2>/dev/null | head -1)
    if [[ -n "$EXTRACTED" && -d "$EXTRACTED" ]]; then
        exec bash "$EXTRACTED/install.sh"
    else
        echo "[ERROR] Failed to download. Clone the repo and run: sudo ./install.sh"
        exit 1
    fi
fi

for lib in common dependencies panel wings ssl cftunnel switch; do
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
SSL_CERT_PATH=""
SSL_KEY_PATH=""
FINAL_PANEL_URL=""

PERSISTENT_CONFIG="/root/.pterodactyl-install-config"

prompt_inputs() {
    # When run via curl|bash, stdin is pipe - read from /dev/tty for user input
    prompt_read() { [[ -e /dev/tty ]] && read -rp "$1" < /dev/tty || read -rp "$1"; }
    prompt_read_s() { [[ -e /dev/tty ]] && read -rsp "$1" < /dev/tty || read -rsp "$1"; }

    echo ""
    echo "=============================================="
    echo "  Pterodactyl Panel Auto Installer"
    echo "=============================================="
    echo ""

    prompt_read "FQDN/Domain (e.g. panel.example.com): "
    FQDN="${REPLY:-localhost}"
    if [[ "$FQDN" == "localhost" ]]; then
        log_warn "Using localhost - suitable for HTTP dev mode only"
    fi

    prompt_read "Admin Email: "
    ADMIN_EMAIL="$REPLY"
    while [[ -z "$ADMIN_EMAIL" ]]; do
        prompt_read "Admin Email (required): "
        ADMIN_EMAIL="$REPLY"
    done

    prompt_read_s "Admin Password: "
    ADMIN_PASSWORD="$REPLY"
    echo ""
    while [[ ${#ADMIN_PASSWORD} -lt 8 ]]; do
        prompt_read_s "Admin Password (min 8 chars): "
        ADMIN_PASSWORD="$REPLY"
        echo ""
    done

    echo ""
    echo "Install Mode:"
    echo "  [1] Panel + Wings on Tunnel - Cloudflare (no port open)"
    echo "  [2] Panel + Wings on Nginx Proxy Manager - Add Proxy Host in NPM"
    echo "  [3] Panel + Wings on NPM + Tunnel - NPM domain + trycloudflare.com"
    prompt_read "Enter 1-3: "
    INSTALL_MODE="${REPLY:-1}"

    if [[ "$INSTALL_MODE" == "1" ]] || [[ "$INSTALL_MODE" == "3" ]]; then
        echo "  [a] Quick Tunnel - Free, no account, get xxx.trycloudflare.com URL"
        echo "  [b] Named Tunnel - Use your domain, requires Cloudflare account"
        prompt_read "Enter a or b: "
        CF_TUNNEL_TYPE=$(echo "${REPLY:-a}" | tr '[:upper:]' '[:lower:]')
        [[ "$CF_TUNNEL_TYPE" != "b" ]] && CF_TUNNEL_TYPE="a"
        if [[ "$CF_TUNNEL_TYPE" == "b" ]]; then
            log_info "Selected: Named Tunnel (your domain)"
        else
            log_info "Selected: Quick Tunnel (trycloudflare.com)"
        fi
    fi

    prompt_read "DB Password for pterodactyl (or Enter to auto-generate): "
    DB_PASSWORD="$REPLY"
    if [[ -z "$DB_PASSWORD" ]]; then
        DB_PASSWORD=$(generate_random_password)
        log_info "Generated DB password"
    fi

    prompt_read "Install Wings (game server daemon)? [Y/n]: "
    INSTALL_WINGS="${REPLY:-Y}"

    # Set APP_URL based on mode
    case "$INSTALL_MODE" in
        1)
            if [[ "$CF_TUNNEL_TYPE" == "a" ]]; then
                APP_URL="https://placeholder.trycloudflare.com"
            else
                APP_URL="https://${FQDN}"
            fi
            ;;
        2) APP_URL="https://${FQDN}" ;;
        3) APP_URL="https://${FQDN}" ;;
        *) APP_URL="https://placeholder.trycloudflare.com" ;;
    esac

    # Save config for lib scripts and persist for retry on error
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
export SSL_CERT_PATH="$SSL_CERT_PATH"
export SSL_KEY_PATH="$SSL_KEY_PATH"
export INSTALL_WINGS="$INSTALL_WINGS"
CONFIG
    cp "$INSTALLER_ROOT/.install-config" "$PERSISTENT_CONFIG" 2>/dev/null && chmod 600 "$PERSISTENT_CONFIG" || true
}

verify_db_connection() {
    mysql -u "$DB_USER" -p"$DB_PASSWORD" -h 127.0.0.1 "$DB_NAME" -e "SELECT 1;" &>/dev/null
}

fix_db_user() {
    log_info "Fixing database user (Access denied)..."
    mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" 2>/dev/null || true
    mysql -e "DROP USER IF EXISTS '$DB_USER'@'127.0.0.1';" 2>/dev/null || true
    mysql -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';"
    mysql -e "CREATE USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';"
    mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost' WITH GRANT OPTION;"
    mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1' WITH GRANT OPTION;"
    mysql -e "FLUSH PRIVILEGES;"
    log_success "Database user fixed"
}

create_database() {
    log_info "Creating database and user (per Pterodactyl doc)..."
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;" 2>/dev/null || true
    mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';" 2>/dev/null || true
    mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';" 2>/dev/null || true
    mysql -e "ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';" 2>/dev/null || true
    mysql -e "ALTER USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';" 2>/dev/null || true
    mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost' WITH GRANT OPTION;"
    mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1' WITH GRANT OPTION;"
    mysql -e "FLUSH PRIVILEGES;"

    if ! verify_db_connection; then
        fix_db_user
        verify_db_connection || { log_error "Database connection failed. Check credentials."; exit 1; }
    fi
    log_success "Database created and verified"
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
  "ssl_cert_path": "${SSL_CERT_PATH:-}",
  "ssl_key_path": "${SSL_KEY_PATH:-}",
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

is_panel_installed() {
    [[ -f "$SETTINGS_JSON_PATH" && -d "${PANEL_PATH:-/var/www/pterodactyl}" ]]
}

prompt_read() {
    [[ -e /dev/tty ]] && read -rp "$1" < /dev/tty || read -rp "$1"
}

main_menu() {
    {
        echo ""
        echo "=============================================="
        echo "  Pterodactyl Panel - Main Menu"
        echo "=============================================="
        echo ""
        echo "  [1] Fresh Install      - Full panel installation"
        echo "  [2] Switch Mode        - Change HTTP / HTTPS / CF Tunnel"
        echo "  [3] Install Wings      - Add Wings daemon (game servers)"
        echo "  [4] Fix Panel          - Fix 500 error, permissions, cache"
        echo "  [5] Remove             - Uninstall panel, wings, database"
        echo "  [6] Remove and Install - Uninstall then fresh install"
        echo "  [7] Exit"
        echo ""
    } >&2
    prompt_read "Enter 1-7: "
    echo "${REPLY:-1}"
}

run_remove() {
    if [[ -f "$INSTALLER_ROOT/uninstall.sh" ]]; then
        bash "$INSTALLER_ROOT/uninstall.sh"
    elif [[ -f /opt/pterodactyl-install-script/uninstall.sh ]]; then
        bash /opt/pterodactyl-install-script/uninstall.sh
    else
        log_error "uninstall.sh not found. Run: curl -sSL ... | sudo bash"
        exit 1
    fi
}

run_remove_and_install() {
    if ! is_panel_installed; then
        log_info "Panel not installed. Running Fresh Install..."
        run_install
        return 0
    fi
    {
        echo ""
        log_warn "This will REMOVE everything (panel, wings, database) then do Fresh Install."
        echo ""
    } >&2
    prompt_read "Continue? [y/N]: "
    if [[ "${REPLY:-n}" != "y" && "${REPLY:-n}" != "Y" ]]; then
        log_info "Cancelled."
        return 0
    fi
    local uninstall_script
    uninstall_script="$INSTALLER_ROOT/uninstall.sh"
    [[ ! -f "$uninstall_script" ]] && uninstall_script="/opt/pterodactyl-install-script/uninstall.sh"
    if [[ -f "$uninstall_script" ]]; then
        echo "yes" | bash "$uninstall_script"
    else
        run_remove
    fi
    echo ""
    log_info "Starting Fresh Install..."
    run_install
}

run_switch_mode() {
    if ! is_panel_installed; then
        log_error "Panel not installed. Run Fresh Install first."
        exit 1
    fi

    local fqdn admin_email current_mode
    fqdn=$(get_json_value "$SETTINGS_JSON_PATH" "fqdn")
    admin_email=$(get_json_value "$SETTINGS_JSON_PATH" "admin_email")
    current_mode=$(grep -o '"install_mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_JSON_PATH" 2>/dev/null | sed 's/.*"\([123]\)".*/\1/' || echo "1")

    local mode_name
    case "$current_mode" in
        1) mode_name="Tunnel" ;;
        2) mode_name="NPM" ;;
        3) mode_name="NPM+Tunnel" ;;
        *) mode_name="Unknown" ;;
    esac

    echo ""
    echo "Current mode: $mode_name | FQDN: ${fqdn:-localhost}"
    echo ""
    echo "  Switch to:"
    echo "  [1] Tunnel - Panel + Wings on Cloudflare Tunnel"
    echo "  [2] NPM - Panel + Wings on Nginx Proxy Manager"
    echo "  [3] NPM + Tunnel - Both NPM domain and trycloudflare.com"
    echo "  [4] Back to main menu"
    echo ""
    prompt_read "Enter 1-4: "
    local choice="${REPLY:-4}"

    case "$choice" in
        1)
            echo "  [a] Quick Tunnel (trycloudflare.com)"
            echo "  [b] Named Tunnel (your domain)"
            prompt_read "Enter a or b: "
            local tunnel_choice
            tunnel_choice=$(echo "${REPLY:-a}" | tr '[:upper:]' '[:lower:]')
            [[ "$tunnel_choice" != "b" ]] && tunnel_choice="a"
            if [[ "$tunnel_choice" == "b" ]]; then
                log_info "Selected: Named Tunnel (your domain)"
            else
                log_info "Selected: Quick Tunnel (trycloudflare.com)"
            fi
            switch_to_tunnel "$tunnel_choice" || { log_error "Switch failed." >&2; return 1; }
            ;;
        2) switch_to_npm || { log_error "Switch failed." >&2; return 1; } ;;
        3)
            echo "  [a] Quick Tunnel (trycloudflare.com)"
            echo "  [b] Named Tunnel (your domain)"
            prompt_read "Enter a or b: "
            local tunnel_choice
            tunnel_choice=$(echo "${REPLY:-a}" | tr '[:upper:]' '[:lower:]')
            [[ "$tunnel_choice" != "b" ]] && tunnel_choice="a"
            if [[ "$tunnel_choice" == "b" ]]; then
                log_info "Selected: Named Tunnel (your domain)"
            else
                log_info "Selected: Quick Tunnel (trycloudflare.com)"
            fi
            switch_to_npm_tunnel "$tunnel_choice" || { log_error "Switch failed." >&2; return 1; }
            ;;
        4) return 0 ;;
        *) log_error "Invalid choice"; return 1 ;;
    esac

    echo "" >&2
    echo "Switch complete. Restart Wings if needed: systemctl restart wings" >&2
    echo "" >&2
}

run_install_wings_only() {
    if ! is_panel_installed; then
        log_error "Panel not installed. Run Fresh Install first."
        exit 1
    fi

    local panel_url backend_port
    panel_url=$(get_json_value "$SETTINGS_JSON_PATH" "panel_url")
    panel_url="${panel_url:-http://localhost}"

    # Use correct API port and URL by install_mode
    local mode fqdn
    mode=$(grep -o '"install_mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_JSON_PATH" 2>/dev/null | sed 's/.*"\([123]\)".*/\1/' || echo "1")
    [[ "$mode" == "2" || "$mode" == "3" ]] && backend_port="8080" || backend_port="80"
    # Mode 3: use clean FQDN as panel URL (not the combined NPM+Tunnel string)
    if [[ "$mode" == "3" ]]; then
        fqdn=$(get_json_value "$SETTINGS_JSON_PATH" "fqdn")
        [[ -n "$fqdn" ]] && panel_url="https://${fqdn}"
    fi

    if [[ -x "$WINGS_BINARY" ]]; then
        log_warn "Wings already installed at $WINGS_BINARY"
        prompt_read "Reinstall? [y/N]: "
        [[ "${REPLY:-n}" != "y" && "${REPLY:-n}" != "Y" ]] && return 0
    fi

    log_info "Installing Wings..."
    install_wings "$panel_url" "" "$backend_port"
    systemctl enable wings 2>/dev/null || true
    systemctl start wings 2>/dev/null || true

    # Update settings
    if [[ -f "$SETTINGS_JSON_PATH" ]]; then
        sed -i 's/"wings_installed":[[:space:]]*false/"wings_installed": true/' "$SETTINGS_JSON_PATH" 2>/dev/null || true
    fi

    log_success "Wings installed. Configure node in Panel -> Configuration"
    echo ""
}

run_fix_panel() {
    if ! is_panel_installed; then
        log_error "Panel not installed. Run Fresh Install first."
        exit 1
    fi

    local panel_path
    panel_path=$(get_json_value "$SETTINGS_JSON_PATH" "panel_path")
    panel_path="${panel_path:-/var/www/pterodactyl}"

    if [[ ! -d "$panel_path" ]]; then
        log_error "Panel path not found: $panel_path"
        exit 1
    fi

    log_info "Fixing panel (500 error, permissions, cache)..."

    cd "$panel_path" || exit 1

    log_info "Setting permissions..."
    chown -R www-data:www-data "$panel_path"
    chmod -R 755 "$panel_path"
    chmod -R 775 storage bootstrap/cache 2>/dev/null || true

    log_info "Clearing cache..."
    sudo -u www-data php artisan config:clear 2>/dev/null || true
    sudo -u www-data php artisan cache:clear 2>/dev/null || true
    sudo -u www-data php artisan view:clear 2>/dev/null || true

    log_info "Creating storage link..."
    sudo -u www-data php artisan storage:link 2>/dev/null || true

    log_info "Restarting services..."
    systemctl restart pteroq 2>/dev/null || true
    systemctl restart nginx 2>/dev/null || true

    log_success "Panel fixed. Try refreshing the page."
    echo ""
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

    if [[ -f "$PERSISTENT_CONFIG" ]]; then
        if [[ -e /dev/tty ]]; then
            read -rp "Use saved config from previous run? [Y/n]: " < /dev/tty || true
        else
            read -rp "Use saved config from previous run? [Y/n]: " || true
        fi
        use_saved="${REPLY:-Y}"
        if [[ "$use_saved" == "y" || "$use_saved" == "Y" || "$use_saved" == "yes" || -z "$use_saved" ]]; then
            cp "$PERSISTENT_CONFIG" "$INSTALLER_ROOT/.install-config"
            log_info "Using saved config"
        else
            prompt_inputs
        fi
    else
        prompt_inputs
    fi

    # shellcheck source=/dev/null
    source "$INSTALLER_ROOT/.install-config"

    log_info "Starting installation..."

    local install_docker=1
    if [[ "$INSTALL_WINGS" != "y" && "$INSTALL_WINGS" != "Y" && "$INSTALL_WINGS" != "yes" && -n "$INSTALL_WINGS" ]]; then
        install_docker=0
    fi

    # Dependencies (no certbot for new modes - NPM/Tunnel handle SSL)
    install_all_dependencies "0" "$install_docker"

    # Database
    create_database

    # Panel
    install_panel "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$APP_URL" ""

    # Nginx + Tunnel
    local WINGS_API_PORT="80"
    case "$INSTALL_MODE" in
        1)
            create_nginx_localhost "$FQDN"
            if [[ "$CF_TUNNEL_TYPE" == "a" ]]; then
                local tunnel_url
                tunnel_url=$(setup_quick_tunnel)
                FINAL_PANEL_URL="${tunnel_url:-https://placeholder.trycloudflare.com}"
                [[ -z "$tunnel_url" ]] && log_warn "Run 'journalctl -u cloudflared-tunnel -f' to see your tunnel URL"
            else
                setup_named_tunnel "pterodactyl-panel" "$FQDN"
                FINAL_PANEL_URL="https://${FQDN} (complete CF tunnel login first)"
            fi
            ;;
        2)
            create_nginx_npm_backend "$FQDN" "8080"
            FINAL_PANEL_URL="https://${FQDN}"
            WINGS_API_PORT="8080"
            # Add TRUSTED_PROXIES for NPM
            grep -q "^TRUSTED_PROXIES=" "$PANEL_PATH/.env" 2>/dev/null || echo "TRUSTED_PROXIES=127.0.0.1" >> "$PANEL_PATH/.env"
            sed -i 's|^TRUSTED_PROXIES=.*|TRUSTED_PROXIES=127.0.0.1|' "$PANEL_PATH/.env" 2>/dev/null || true
            log_info "Add Proxy Host in NPM: $FQDN -> 127.0.0.1:8080"
            ;;
        3)
            create_nginx_npm_backend "$FQDN" "8080"
            WINGS_API_PORT="8080"
            grep -q "^TRUSTED_PROXIES=" "$PANEL_PATH/.env" 2>/dev/null || echo "TRUSTED_PROXIES=127.0.0.1" >> "$PANEL_PATH/.env"
            sed -i 's|^TRUSTED_PROXIES=.*|TRUSTED_PROXIES=127.0.0.1|' "$PANEL_PATH/.env" 2>/dev/null || true
            if [[ "$CF_TUNNEL_TYPE" == "a" ]]; then
                local tunnel_url
                tunnel_url=$(setup_quick_tunnel_to_port "8080")
                FINAL_PANEL_URL="https://${FQDN} (NPM) + ${tunnel_url:-https://xxx.trycloudflare.com} (Tunnel)"
                [[ -z "$tunnel_url" ]] && FINAL_PANEL_URL="https://${FQDN} (NPM) + (run: journalctl -u cloudflared-tunnel -f for Tunnel URL)"
            else
                setup_named_tunnel "pterodactyl-panel" "$FQDN" "8080"
                FINAL_PANEL_URL="https://${FQDN} (NPM + CF tunnel)"
            fi
            ;;
        *)
            create_nginx_localhost "$FQDN"
            local tunnel_url
            tunnel_url=$(setup_quick_tunnel)
            FINAL_PANEL_URL="${tunnel_url:-https://xxx.trycloudflare.com}"
            ;;
    esac

    # Update panel .env APP_URL with final URL
    sed -i "s|APP_URL=.*|APP_URL=$FINAL_PANEL_URL|" "$PANEL_PATH/.env"

    local wings_installed=false
    if [[ "$INSTALL_WINGS" == "y" || "$INSTALL_WINGS" == "Y" || "$INSTALL_WINGS" == "yes" || -z "$INSTALL_WINGS" ]]; then
        local wings_remote_url="$FINAL_PANEL_URL"
        [[ "$INSTALL_MODE" == "3" ]] && wings_remote_url="https://${FQDN}"
        install_wings "$wings_remote_url" "" "$WINGS_API_PORT"
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

run_main() {
    check_root
    local choice
    while true; do
        choice=$(main_menu)
        case "$choice" in
            1) run_install; break ;;
            2) run_switch_mode ;;
            3) run_install_wings_only; break ;;
            4) run_fix_panel ;;
            5) run_remove; break ;;
            6) run_remove_and_install; break ;;
            7) log_info "Exit"; exit 0 ;;
            *) run_install; break ;;  # Default to fresh install for non-interactive
        esac
    done
}

# Run when executed (file or curl|bash pipe)
# When piped, BASH_SOURCE may be empty so we must run main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] || [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    run_main
fi
