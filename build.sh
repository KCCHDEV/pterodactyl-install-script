#!/usr/bin/env bash
# Build single-file install.sh from lib/*.sh + install-multi.sh + uninstall

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ ! -f install-multi.sh ]] && { echo "install-multi.sh not found"; exit 1; }

strip_lib() {
    sed -e '1d' -e '/^set -e$/d' -e '/^SCRIPT_DIR=/d' -e '/^INSTALLER_DIR=/d' \
        -e '/source ".\+common\.sh"/d' -e '/source ".\+dependencies\.sh"/d' \
        -e '/source ".\+ssl\.sh"/d' -e '/source ".\+cftunnel\.sh"/d' \
        -e '/# shellcheck source=/d' "$1"
}

common_single() {
    sed -e '1,5d' -e '/^SCRIPT_DIR=/d' -e '/^INSTALLER_DIR=/d' \
        -e 's|source "\$INSTALLER_DIR/.install-config"|source "/root/.pterodactyl-install-config"|' \
        -e 's|"\$INSTALLER_DIR/.install-config"|"/root/.pterodactyl-install-config"|' \
        lib/common.sh
}

echo "Building single-file install.sh..."

{
    cat << 'HEAD'
#!/usr/bin/env bash
# Pterodactyl Panel Auto Installer (single-file)
# Run via: curl -sSL https://raw.githubusercontent.com/KCCHDEV/pterodactyl-install-script/refs/heads/main/install.sh | sudo bash

set -e

GITHUB_REPO="https://github.com/KCCHDEV/pterodactyl-install-script"
INSTALLER_ROOT="/tmp/pterodactyl-installer"
mkdir -p "$INSTALLER_ROOT"

HEAD

    common_single
    strip_lib lib/dependencies.sh
    strip_lib lib/ssl.sh
    strip_lib lib/panel.sh
    strip_lib lib/wings.sh
    strip_lib lib/cftunnel.sh
    strip_lib lib/switch.sh

    # run_uninstall_inline (must be before run_remove which calls it)
    cat << 'UNINSTALL'
run_uninstall_inline() {
    local skip_confirm="${1:-}"
    WINGS_INSTALLED=true
    PANEL_PATH="${PANEL_PATH:-/var/www/pterodactyl}"
    [[ -f "$SETTINGS_JSON_PATH" ]] && {
        PANEL_PATH=$(get_json_value "$SETTINGS_JSON_PATH" "panel_path")
        DB_NAME=$(get_json_value "$SETTINGS_JSON_PATH" "db_name")
        DB_USER=$(get_json_value "$SETTINGS_JSON_PATH" "db_user")
        WINGS_VAL=$(grep -o '"wings_installed"[[:space:]]*:[[:space:]]*[a-z]*' "$SETTINGS_JSON_PATH" 2>/dev/null | grep -o 'true\|false' | head -1)
        [[ "$WINGS_VAL" == "false" ]] && WINGS_INSTALLED=false
    }
    PANEL_PATH="${PANEL_PATH:-/var/www/pterodactyl}"
    [[ -z "$DB_NAME" && -f "$PANEL_PATH/.env" ]] && DB_NAME=$(grep "^DB_DATABASE=" "$PANEL_PATH/.env" 2>/dev/null | cut -d= -f2)
    [[ -z "$DB_USER" && -f "$PANEL_PATH/.env" ]] && DB_USER=$(grep "^DB_USERNAME=" "$PANEL_PATH/.env" 2>/dev/null | cut -d= -f2)
    DB_NAME="${DB_NAME:-panel}"
    DB_USER="${DB_USER:-pterodactyl}"

    if [[ "$skip_confirm" != "yes" ]]; then
        echo ""; echo "=============================================="; echo "  Pterodactyl Panel UNINSTALLER"; echo "=============================================="; echo ""
        log_warn "This will PERMANENTLY remove:"
        echo "  - Panel files ($PANEL_PATH)"
        [[ "$WINGS_INSTALLED" == "true" ]] && echo "  - Wings daemon"
        echo "  - Nginx config"; echo "  - Database ($DB_NAME)"; echo "  - Cloudflare tunnel (if installed)"; echo ""
        [[ -e /dev/tty ]] && read -rp "Type 'yes' or the panel domain to confirm: " confirm < /dev/tty || read -rp "Type 'yes' or the panel domain to confirm: " confirm
        if [[ "$confirm" != "yes" && "$confirm" != "YES" ]]; then
            [[ ! -d "$PANEL_PATH" ]] && { log_error "Aborted."; exit 1; }
            [[ ! "$confirm" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ && "$confirm" != "localhost" ]] && { log_error "Confirmation failed. Aborted."; exit 1; }
        fi
        log_info "Proceeding with uninstall..."
    fi

    log_info "Stopping services..."
    systemctl stop pteroq 2>/dev/null || true
    systemctl stop wings 2>/dev/null || true
    systemctl stop cloudflared-tunnel 2>/dev/null || true
    systemctl disable pteroq 2>/dev/null || true
    systemctl disable wings 2>/dev/null || true
    systemctl disable cloudflared-tunnel 2>/dev/null || true
    pkill -f "cloudflared tunnel" 2>/dev/null || true
    log_success "Services stopped"

    [[ -d "$PANEL_PATH" ]] && { log_info "Removing panel files..."; rm -rf "$PANEL_PATH"; log_success "Panel removed"; }
    [[ -f /etc/systemd/system/pteroq.service ]] && { rm -f /etc/systemd/system/pteroq.service; systemctl daemon-reload; log_success "pteroq removed"; }

    if [[ "$WINGS_INSTALLED" == "true" ]]; then
        [[ -f "$WINGS_BINARY" ]] && { log_info "Removing Wings..."; rm -f "$WINGS_BINARY"; log_success "Wings removed"; }
        [[ -d /etc/pterodactyl ]] && { rm -rf /etc/pterodactyl; log_success "Wings config removed"; }
        [[ -d /var/lib/pterodactyl ]] && { rm -rf /var/lib/pterodactyl; log_success "Wings data removed"; }
        [[ -f /etc/systemd/system/wings.service ]] && { rm -f /etc/systemd/system/wings.service; systemctl daemon-reload; log_success "wings removed"; }
        id pterodactyl &>/dev/null && { userdel pterodactyl 2>/dev/null || true; log_success "pterodactyl user removed"; }
    fi

    [[ -f "$NGINX_ENABLED" || -L "$NGINX_ENABLED" ]] && rm -f "$NGINX_ENABLED"
    [[ -f "$NGINX_AVAILABLE" ]] && rm -f "$NGINX_AVAILABLE"
    systemctl reload nginx 2>/dev/null || true
    log_success "Nginx config removed"

    log_info "Removing database..."
    mysql -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;" 2>/dev/null || true
    mysql -e "DROP USER IF EXISTS '$DB_USER'@'127.0.0.1';" 2>/dev/null || true
    mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" 2>/dev/null || true
    mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    log_success "Database removed"

    [[ -f /etc/systemd/system/cloudflared-tunnel.service ]] && { systemctl stop cloudflared-tunnel 2>/dev/null || true; systemctl disable cloudflared-tunnel 2>/dev/null || true; rm -f /etc/systemd/system/cloudflared-tunnel.service; systemctl daemon-reload; pkill -f cloudflared 2>/dev/null || true; log_success "Cloudflare tunnel removed"; }
    [[ -f "$CREDENTIALS_FILE" ]] && { rm -f "$CREDENTIALS_FILE"; log_success "Credentials removed"; }
    [[ -f "$SETTINGS_JSON_PATH" ]] && { rm -f "$SETTINGS_JSON_PATH"; log_success "Settings removed"; }
    [[ -d /opt/pterodactyl-install-script ]] && { rm -rf /opt/pterodactyl-install-script; log_success "Installer copy removed"; }
    rm -f /root/.pterodactyl-install-config 2>/dev/null && log_success "Saved config removed" || true
    echo ""; log_success "Uninstall complete."; echo ""
}
UNINSTALL

    # Main from install-multi.sh: lines 39-247 (config through main_menu), skip run_remove/run_remove_and_install
    sed -n '39,247p' install-multi.sh

    cat << 'REMOVE'

run_remove() { run_uninstall_inline; }

run_remove_and_install() {
    if ! is_panel_installed; then
        log_info "Panel not installed. Running Fresh Install..."
        run_install
        return 0
    fi
    { echo ""; log_warn "This will REMOVE everything (panel, wings, database) then do Fresh Install."; echo ""; } >&2
    prompt_read "Continue? [y/N]: "
    if [[ "${REPLY:-n}" != "y" && "${REPLY:-n}" != "Y" ]]; then
        log_info "Cancelled."
        return 0
    fi
    run_uninstall_inline "yes"
    echo ""
    log_info "Starting Fresh Install..."
    run_install
}
REMOVE

    # run_switch_mode through save_credentials (289-475)
    sed -n '289,475p' install-multi.sh

    # run_install: 478-581 (through save_credentials), skip 583-587 (old copy block)
    sed -n '478,581p' install-multi.sh

    cat << 'COPY_OPT'

    mkdir -p /opt/pterodactyl-install-script
    if [[ -f "${BASH_SOURCE[0]}" ]]; then
        cp "${BASH_SOURCE[0]}" /opt/pterodactyl-install-script/install.sh
    else
        curl -sSL "https://raw.githubusercontent.com/KCCHDEV/pterodactyl-install-script/refs/heads/main/install.sh" -o /opt/pterodactyl-install-script/install.sh 2>/dev/null || true
    fi
    chmod +x /opt/pterodactyl-install-script/install.sh 2>/dev/null || true
COPY_OPT

    # Completion message and run_install closing brace (589-609)
    sed -n '589,609p' install-multi.sh | sed 's|Uninstall: sudo /opt/pterodactyl-install-script/uninstall.sh|Uninstall: Run script again, choose [5] Remove|'

    # run_main and entry point (611-633)
    sed -n '611,633p' install-multi.sh

    # Workaround: one extra { in inlined libs, add closing } so script parses
    echo '}'
} > install.sh
chmod +x install.sh
echo "Built: install.sh ($(wc -l < install.sh) lines)"
