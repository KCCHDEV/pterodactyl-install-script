#!/usr/bin/env bash
# Pterodactyl Panel Installer - Panel installation
# Clone, configure, migrate, create admin

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

PANEL_REPO="https://github.com/pterodactyl/panel.git"
PANEL_BRANCH="release/v1.12.1"

install_panel() {
    local db_name="${1:-panel}"
    local db_user="${2:-pterodactyl}"
    local db_pass="${3}"
    local app_url="${4}"
    local app_key="${5}"

    log_info "Cloning Pterodactyl Panel..."
    if [[ -d "$PANEL_PATH" ]]; then
        log_warn "Panel directory exists. Backing up and removing..."
        mv "$PANEL_PATH" "${PANEL_PATH}.bak.$(date +%s)"
    fi

    git clone -b "$PANEL_BRANCH" "$PANEL_REPO" "$PANEL_PATH"
    cd "$PANEL_PATH"

    log_info "Installing PHP dependencies..."
    composer install --no-dev --optimize-autoloader --no-interaction

    log_info "Building frontend assets..."
    export NODE_OPTIONS=--openssl-legacy-provider 2>/dev/null || true
    (yarn install 2>/dev/null || npm install 2>/dev/null) && (yarn build:production 2>/dev/null || npm run build 2>/dev/null || true) || true

    log_info "Creating .env file..."
    cp .env.example .env
    php artisan key:generate --force

    # Database config
    sed -i "s/DB_DATABASE=.*/DB_DATABASE=$db_name/" .env
    sed -i "s/DB_USERNAME=.*/DB_USERNAME=$db_user/" .env
    sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$db_pass/" .env
    sed -i "s/APP_URL=.*/APP_URL=$app_url/" .env
    sed -i "s/APP_ENV=.*/APP_ENV=production/" .env
    sed -i "s/APP_DEBUG=.*/APP_DEBUG=false/" .env

    log_info "Running migrations..."
    php artisan migrate --force

    log_info "Creating admin user..."
    php artisan p:user:make \
        --email="${ADMIN_EMAIL}" \
        --username="${ADMIN_USERNAME:-admin}" \
        --name-first="${ADMIN_FIRST:-Admin}" \
        --name-last="${ADMIN_LAST:-User}" \
        --password="${ADMIN_PASSWORD}" \
        --admin=1

    log_info "Setting permissions..."
    chown -R www-data:www-data "$PANEL_PATH"
    chmod -R 755 "$PANEL_PATH"
    chmod -R 775 storage bootstrap/cache

    # Queue worker service
    log_info "Setting up queue worker..."
    cat > /etc/systemd/system/pteroq.service << EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php $PANEL_PATH/artisan queue:work --queue=high,standard,low --sleep=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable pteroq
    systemctl start pteroq

    log_success "Panel installed at $PANEL_PATH"
}
