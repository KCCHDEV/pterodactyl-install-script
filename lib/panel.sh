#!/usr/bin/env bash
# Pterodactyl Panel Installer - Follows official doc 100%
# https://pterodactyl.io/panel/1.0/getting_started.html

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

PANEL_RELEASE_URL="https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"

install_panel() {
    local db_name="${1:-panel}"
    local db_user="${2:-pterodactyl}"
    local db_pass="${3}"
    local app_url="${4}"
    local app_key="${5}"

    log_info "Downloading Pterodactyl Panel (official release per doc)..."
    if [[ -d "$PANEL_PATH" ]]; then
        log_warn "Panel directory exists. Backing up and removing..."
        mv "$PANEL_PATH" "${PANEL_PATH}.bak.$(date +%s)"
    fi

    mkdir -p "$PANEL_PATH"
    cd "$PANEL_PATH"
    curl -sSL -Lo panel.tar.gz "$PANEL_RELEASE_URL"
    tar -xzf panel.tar.gz
    rm -f panel.tar.gz
    chmod -R 755 storage/* bootstrap/cache/ 2>/dev/null || true

    log_info "Installing dependencies (per doc)..."
    cp .env.example .env
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
    php artisan key:generate --force

    log_info "Configuring environment (p:environment per doc)..."
    php artisan p:environment:setup \
        --author="${ADMIN_EMAIL}" \
        --url="$app_url" \
        --timezone="UTC" \
        --telemetry=false \
        --cache="redis" \
        --session="redis" \
        --queue="redis" \
        --redis-host="127.0.0.1" \
        --redis-pass="null" \
        --redis-port="6379" \
        --settings-ui=true 2>/dev/null || true

    php artisan p:environment:database \
        --host="127.0.0.1" \
        --port="3306" \
        --database="$db_name" \
        --username="$db_user" \
        --password="$db_pass" 2>/dev/null || true

    php artisan p:environment:mail --driver=mail 2>/dev/null || true

    # Ensure DB and APP settings (fallback if artisan didn't apply)
    sed -i "s|DB_HOST=.*|DB_HOST=127.0.0.1|" .env
    sed -i "s|DB_DATABASE=.*|DB_DATABASE=$db_name|" .env
    sed -i "s|DB_USERNAME=.*|DB_USERNAME=$db_user|" .env
    sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$db_pass|" .env
    sed -i "s|APP_URL=.*|APP_URL=$app_url|" .env
    sed -i "s|APP_ENV=.*|APP_ENV=production|" .env
    sed -i "s|APP_DEBUG=.*|APP_DEBUG=false|" .env

    log_info "Running migrations and seeding (Nests & Eggs per doc)..."
    if ! php artisan migrate --seed --force --no-interaction; then
        # Auto-fix: if fix_db_user exists (from install.sh), fix and retry
        if type fix_db_user &>/dev/null; then
            log_warn "Migration failed (likely Access denied), fixing database..."
            fix_db_user
            if php artisan migrate --seed --force --no-interaction; then
                log_success "Migrations completed after fix"
            else
                log_error "Migration failed. Check database credentials."
                exit 1
            fi
        else
            log_error "Migration failed. Run installer to fix database."
            exit 1
        fi
    fi

    log_info "Creating admin user (per doc)..."
    php artisan p:user:make \
        --email="${ADMIN_EMAIL}" \
        --username="${ADMIN_USERNAME:-admin}" \
        --name-first="${ADMIN_FIRST:-Admin}" \
        --name-last="${ADMIN_LAST:-User}" \
        --password="${ADMIN_PASSWORD}" \
        --admin=1 \
        --no-interaction

    log_info "Setting permissions (per doc: chown www-data)..."
    chown -R www-data:www-data "$PANEL_PATH"

    log_info "Creating storage link..."
    sudo -u www-data php artisan storage:link 2>/dev/null || true

    chmod -R 775 storage bootstrap/cache

    # Crontab (per doc: sudo crontab -e)
    log_info "Setting up crontab (per doc)..."
    (crontab -l 2>/dev/null | grep -v "artisan schedule:run"; echo "* * * * * php $PANEL_PATH/artisan schedule:run >> /dev/null 2>&1") | crontab - 2>/dev/null || true

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
ExecStart=/usr/bin/php $PANEL_PATH/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now pteroq

    log_success "Panel installed at $PANEL_PATH (100% per official doc)"
}
