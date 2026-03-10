#!/usr/bin/env bash
# Pterodactyl Panel Auto Installer (single-file)
# Run via: curl -sSL https://raw.githubusercontent.com/KCCHDEV/pterodactyl-install-script/refs/heads/main/install.sh | sudo bash

set -e

GITHUB_REPO="https://github.com/KCCHDEV/pterodactyl-install-script"
INSTALLER_ROOT="/tmp/pterodactyl-installer"
mkdir -p "$INSTALLER_ROOT"


# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Paths
PANEL_PATH="${PANEL_PATH:-/var/www/pterodactyl}"
NGINX_AVAILABLE="/etc/nginx/sites-available/pterodactyl.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/pterodactyl.conf"
WINGS_CONFIG="/etc/pterodactyl/config.yml"
WINGS_BINARY="/usr/local/bin/wings"
CREDENTIALS_FILE="/root/pterodactyl-credentials.txt"
SETTINGS_JSON_PATH="/root/pterodactyl-settings.json"

get_settings_path() {
    echo "${SETTINGS_JSON_PATH}"
}

# Get value from JSON file (works without jq)
get_json_value() {
    local file="$1"
    local key="$2"
    if [[ -f "$file" ]]; then
        grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | sed 's/.*:[[:space:]]*"\(.*\)"/\1/' | head -1
    fi
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            ubuntu)
                if [[ "$VERSION_ID" == "22.04" ]] || [[ "$VERSION_ID" == "24.04" ]]; then
                    log_success "Detected $PRETTY_NAME - Supported"
                    return 0
                fi
                ;;
            debian)
                if [[ "$VERSION_ID" == "11" ]] || [[ "$VERSION_ID" == "12" ]] || [[ "$VERSION_ID" == "13" ]]; then
                    log_success "Detected $PRETTY_NAME - Supported"
                    return 0
                fi
                ;;
        esac
        log_warn "OS: $PRETTY_NAME - May work but not officially tested"
        return 0
    fi
    log_error "Cannot detect OS. Supported: Ubuntu 22.04/24.04, Debian 11/12/13"
    exit 1
}

check_disk_space() {
    local required_gb=5
    local available_gb
    available_gb=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    if [[ "$available_gb" -lt "$required_gb" ]]; then
        log_error "Insufficient disk space. Need at least ${required_gb}GB, have ${available_gb}GB"
        exit 1
    fi
    log_success "Disk space: ${available_gb}GB available"
}

generate_random_password() {
    tr -dc 'A-Za-z0-9!@#$%' < /dev/urandom | head -c 32
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            echo "amd64"
            log_warn "Unknown architecture, defaulting to amd64"
            ;;
    esac
}

is_installed() {
    command -v "$1" &>/dev/null
}

USE_TUI=0
TUI_CMD=""
if [[ -t 0 ]] && [[ -e /dev/tty ]] && [[ "${TERM:-}" != "dumb" ]]; then
    if command -v dialog &>/dev/null; then
        TUI_CMD="dialog"
        USE_TUI=1
    elif command -v whiptail &>/dev/null; then
        TUI_CMD="whiptail"
        USE_TUI=1
    fi
fi

ensure_tui() {
    if [[ $USE_TUI -eq 1 ]]; then return 0; fi
    [[ ! -t 0 ]] && return 1
    if apt-get install -y dialog &>/dev/null 2>&1; then
        TUI_CMD="dialog"
        USE_TUI=1
        return 0
    fi
    if apt-get install -y whiptail &>/dev/null 2>&1; then
        TUI_CMD="whiptail"
        USE_TUI=1
        return 0
    fi
    return 1
}

tui_menu() {
    local title="$1" msg="$2" h="${3:-15}" w="${4:-60}"
    shift 4
    local tags=() items=()
    while [[ $# -ge 2 ]]; do
        tags+=("$1")
        items+=("$2")
        shift 2
    done
    local mh=$((${#tags[@]}))
    [[ $mh -lt 5 ]] && mh=5
    if [[ $USE_TUI -eq 1 && -n "$TUI_CMD" ]]; then
        local args=()
        for i in "${!tags[@]}"; do
            args+=("${tags[$i]}" "${items[$i]}")
        done
        if [[ "$TUI_CMD" == "dialog" ]]; then
            $TUI_CMD --stdout --no-shadow --title "$title" --menu "$msg" "$h" "$w" "$mh" "${args[@]}" 2>/dev/tty
        else
            $TUI_CMD --title "$title" --menu "$msg" "$h" "$w" "$mh" "${args[@]}" 3>&1 1>&2 2>&3
        fi
    else
        return 1
    fi
}

tui_input() {
    local title="$1" msg="$2" default="${3:-}"
    if [[ $USE_TUI -eq 1 && -n "$TUI_CMD" ]]; then
        if [[ "$TUI_CMD" == "dialog" ]]; then
            $TUI_CMD --stdout --no-shadow --title "$title" --inputbox "$msg" 10 60 "$default" 2>/dev/tty
        else
            $TUI_CMD --title "$title" --inputbox "$msg" 10 60 "$default" 3>&1 1>&2 2>&3
        fi
    else
        return 1
    fi
}

ensure_directory() {
    local dir="$1"
    local perm="${2:-755}"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        chmod "$perm" "$dir"
        log_info "Created directory: $dir"
    fi
}

# Load config if exists (set by install.sh)
load_install_config() {
    if [[ -f "/root/.pterodactyl-install-config" ]]; then
        # shellcheck source=/dev/null
        source "/root/.pterodactyl-install-config"
        return 0
    fi
    return 1
}
# Pterodactyl Panel Installer - Dependencies installation
# Installs MariaDB, PHP 8.3, Nginx, Redis, Composer, Node.js



install_base_packages() {
    log_info "Updating system packages..."
    apt-get update -qq
    apt-get install -y -qq software-properties-common curl wget git unzip apt-transport-https ca-certificates gnupg lsb-release dialog

    log_info "Installing base dependencies..."
    apt-get install -y -qq build-essential
}

install_php() {
    log_info "Installing PHP 8.3 and extensions..."
    if [[ -f /etc/debian_version ]] && grep -qE "^(11|12)" /etc/debian_version 2>/dev/null; then
        # Debian - use Sury repo
        apt-get install -y -qq apt-transport-https lsb-release ca-certificates wget
        wget -qO /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
        echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
    else
        # Ubuntu - use ondrej PPA
        add-apt-repository -y ppa:ondrej/php
    fi
    apt-get update -qq
    apt-get install -y -qq \
        php8.3-fpm \
        php8.3-cli \
        php8.3-common \
        php8.3-mysql \
        php8.3-zip \
        php8.3-gd \
        php8.3-mbstring \
        php8.3-curl \
        php8.3-xml \
        php8.3-bcmath \
        php8.3-intl \
        php8.3-redis

    # Set PHP 8.3 as default
    update-alternatives --set php /usr/bin/php8.3 2>/dev/null || true

    # PHP config for Pterodactyl
    local php_ini
    php_ini=$(php -i | grep "Loaded Configuration File" | awk '{print $5}')
    if [[ -n "$php_ini" && -f "$php_ini" ]]; then
        sed -i 's/;max_input_vars = 1000/max_input_vars = 10000/' "$php_ini" 2>/dev/null || true
        sed -i 's/upload_max_filesize = .*/upload_max_filesize = 100M/' "$php_ini" 2>/dev/null || true
        sed -i 's/post_max_size = .*/post_max_size = 100M/' "$php_ini" 2>/dev/null || true
        sed -i 's/memory_limit = .*/memory_limit = 512M/' "$php_ini" 2>/dev/null || true
    fi

    systemctl enable php8.3-fpm
    systemctl restart php8.3-fpm
    log_success "PHP 8.3 installed"
}

install_mariadb() {
    log_info "Installing MariaDB..."
    apt-get install -y -qq mariadb-server mariadb-client

    systemctl enable mariadb
    systemctl start mariadb

    # Secure MariaDB (minimal - no interactive prompts)
    mysql -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
    mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" 2>/dev/null || true
    mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true

    log_success "MariaDB installed"
}

install_nginx() {
    log_info "Installing Nginx..."
    apt-get install -y -qq nginx

    systemctl enable nginx
    log_success "Nginx installed"
}

install_redis() {
    log_info "Installing Redis (official repo per Pterodactyl doc)..."
    local redis_dist
    redis_dist=$(lsb_release -cs 2>/dev/null || echo "bookworm")
    [[ "$redis_dist" == "trixie" ]] && redis_dist="bookworm"
    curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg 2>/dev/null || true
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $redis_dist main" | tee /etc/apt/sources.list.d/redis.list >/dev/null
    apt-get update -qq
    apt-get install -y -qq redis-server

    systemctl enable redis-server
    systemctl start redis-server
    log_success "Redis installed"
}

install_composer() {
    log_info "Installing Composer..."
    if ! is_installed composer; then
        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
        log_success "Composer installed"
    else
        log_success "Composer already installed"
    fi
}

install_nodejs() {
    log_info "Installing Node.js and Yarn..."
    if ! is_installed node; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y -qq nodejs
    fi
    if ! is_installed yarn; then
        npm install -g yarn 2>/dev/null || corepack enable && corepack prepare yarn@stable --activate
    fi
    log_success "Node.js $(node -v) installed"
}

install_certbot() {
    log_info "Installing Certbot..."
    apt-get install -y -qq certbot python3-certbot-nginx
    log_success "Certbot installed"
}

install_docker() {
    log_info "Installing Docker..."
    if ! is_installed docker; then
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
        log_success "Docker installed"
    else
        log_success "Docker already installed"
    fi
}

install_all_dependencies() {
    local need_ssl="${1:-0}"
    local need_docker="${2:-1}"

    install_base_packages
    install_php
    install_mariadb
    install_nginx
    install_redis
    install_composer
    install_nodejs

    if [[ "$need_ssl" == "1" ]]; then
        install_certbot
    fi

    if [[ "$need_docker" == "1" ]]; then
        install_docker
    fi

    log_success "All dependencies installed"
}
# Pterodactyl Panel Installer - Nginx HTTP/HTTPS configuration
# Creates Nginx config for HTTP, HTTPS (Let's Encrypt), Cloudflare Proxy (Origin SSL), or localhost-only (CF Tunnel)



PANEL_PATH="${PANEL_PATH:-/var/www/pterodactyl}"
NGINX_AVAILABLE="/etc/nginx/sites-available/pterodactyl.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/pterodactyl.conf"

# Generate self-signed SSL certificate (for testing or Cloudflare Proxy)
# Usage: generate_self_signed_ssl cert_path key_path [cn]
generate_self_signed_ssl() {
    local cert_path="${1}"
    local key_path="${2}"
    local cn="${3:-Generic SSL Certificate}"

    local dir
    dir=$(dirname "$cert_path")
    mkdir -p "$dir"
    dir=$(dirname "$key_path")
    mkdir -p "$dir"

    log_info "Generating self-signed SSL certificate (CN=$cn, 10 years)..."
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/C=NA/ST=NA/L=NA/O=NA/CN=$cn" \
        -keyout "$key_path" -out "$cert_path" 2>/dev/null
    chmod 600 "$key_path"
    chmod 644 "$cert_path"
    log_success "Self-signed certificate: $cert_path"
}

create_nginx_http() {
    local domain="${1}"
    log_info "Creating Nginx HTTP config for $domain..."

    cat > "$NGINX_AVAILABLE" << NGINXHTTP
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    root $PANEL_PATH/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINXHTTP

    ln -sf "$NGINX_AVAILABLE" "$NGINX_ENABLED"
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    nginx -t
    systemctl reload nginx
    log_success "Nginx HTTP config created"
}

create_nginx_https() {
    local domain="${1}"
    local email="${2}"
    log_info "Creating Nginx HTTPS config for $domain..."

    # First create HTTP config for certbot challenge
    create_nginx_http "$domain"

    log_info "Obtaining SSL certificate..."
    certbot --nginx -d "$domain" --non-interactive --agree-tos --email "$email"

    # Certbot modifies the config, but we ensure it's correct
    nginx -t
    systemctl reload nginx
    log_success "Nginx HTTPS config created with Let's Encrypt"
}

create_nginx_cloudflare_proxy() {
    # Cloudflare Proxy: domain points to server IP, orange cloud, Origin SSL
    # cert_path/key_path can be Cloudflare Origin cert, Let's Encrypt, or any valid cert
    local domain="${1}"
    local cert_path="${2:-/etc/ssl/cert.pem}"
    local key_path="${3:-/etc/ssl/key.pem}"

    if [[ ! -f "$cert_path" ]]; then
        log_error "SSL certificate not found: $cert_path"
        exit 1
    fi
    if [[ ! -f "$key_path" ]]; then
        log_error "SSL key not found: $key_path"
        exit 1
    fi

    log_info "Creating Nginx Cloudflare Proxy config for $domain (Origin SSL)..."

    cat > "$NGINX_AVAILABLE" << NGINXCFPROXY
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $domain;

    root $PANEL_PATH/public;
    index index.php;

    ssl_certificate $cert_path;
    ssl_certificate_key $key_path;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINXCFPROXY

    ln -sf "$NGINX_AVAILABLE" "$NGINX_ENABLED"
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    nginx -t
    systemctl reload nginx
    log_success "Nginx Cloudflare Proxy config created (SSL from $cert_path)"
}

create_nginx_localhost() {
    # For Cloudflare Tunnel - only listen on localhost
    local domain="${1:-localhost}"
    log_info "Creating Nginx localhost-only config (for CF Tunnel)..." >&2

    cat > "$NGINX_AVAILABLE" << NGINXLOCAL
server {
    listen 127.0.0.1:80;
    server_name $domain localhost;

    root $PANEL_PATH/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINXLOCAL

    ln -sf "$NGINX_AVAILABLE" "$NGINX_ENABLED"
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    nginx -t
    systemctl reload nginx
    log_success "Nginx localhost config created (CF Tunnel mode)" >&2
}

create_nginx_npm_backend() {
    # For Nginx Proxy Manager - listen on 127.0.0.1:8080 only
    # NPM proxies to this backend (add Proxy Host: domain -> 127.0.0.1:8080)
    local domain="${1:-localhost}"
    local port="${2:-8080}"
    log_info "Creating Nginx backend for NPM (127.0.0.1:$port)..." >&2

    cat > "$NGINX_AVAILABLE" << NGINXNPM
server {
    listen 127.0.0.1:$port;
    server_name $domain localhost;

    root $PANEL_PATH/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINXNPM

    ln -sf "$NGINX_AVAILABLE" "$NGINX_ENABLED"
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    nginx -t
    systemctl reload nginx
    log_success "Nginx NPM backend created (127.0.0.1:$port)" >&2
}
# Pterodactyl Panel Installer - Follows official doc 100%
# https://pterodactyl.io/panel/1.0/getting_started.html



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
# Pterodactyl Panel Installer - Wings daemon installation
# Install Wings for game server management



WINGS_RELEASE_URL="https://github.com/pterodactyl/wings/releases/latest/download"
WINGS_CONFIG="/etc/pterodactyl/config.yml"
WINGS_BINARY="/usr/local/bin/wings"

install_wings() {
    local panel_url="${1}"
    local wings_token="${2}"
    local backend_port="${3:-}"
    local token_id token_value

    log_info "Installing Wings..."

    mkdir -p /etc/pterodactyl
    mkdir -p /var/lib/pterodactyl

    local arch
    arch=$(detect_arch)
    log_info "Downloading Wings for $arch..."
    curl -sSL -o "$WINGS_BINARY" "${WINGS_RELEASE_URL}/wings_linux_${arch}"
    chmod +x "$WINGS_BINARY"

    # Parse token if provided (format: "token_value|token_id")
    if [[ -n "$wings_token" ]]; then
        token_value=$(echo "$wings_token" | cut -d'|' -f1)
        token_id=$(echo "$wings_token" | cut -d'|' -f2)
    else
        token_value=""
        token_id=""
    fi

    # remote: Tunnel mode (backend_port empty + panel_url https) -> use panel_url with --ignore-certificate-errors
    #         NPM/local mode -> http://127.0.0.1:port
    local remote_url
    local use_ignore_cert=false
    local api_port=8080
    if [[ -z "$backend_port" && "$panel_url" == https://* ]]; then
        remote_url="$panel_url"
        use_ignore_cert=true
        api_port=8080
        log_info "Tunnel mode: Wings will connect to Panel via $remote_url (TLS verify disabled)"
    else
        api_port="${backend_port:-80}"
        remote_url="http://127.0.0.1:$api_port"
    fi

    local ssl_enabled="false"

    log_info "Creating Wings configuration..."
    cat > "$WINGS_CONFIG" << WINGSCFG
---
debug: false
token_id: "$token_id"
token: "$token_value"
api:
  host: 127.0.0.1
  port: $api_port
  ssl:
    enabled: $ssl_enabled
  system:
    type: nginx
    ssl:
      enabled: $ssl_enabled
system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: 2022
user:
  username: pterodactyl
  groupname: pterodactyl
allowed_mounts: []
remote: $remote_url
WINGSCFG

    if ! id pterodactyl &>/dev/null; then
        useradd -r -s /bin/false -d /var/lib/pterodactyl pterodactyl
    fi
    chown -R pterodactyl:pterodactyl /var/lib/pterodactyl

    local exec_start="$WINGS_BINARY"
    [[ "$use_ignore_cert" == true ]] && exec_start="$WINGS_BINARY --ignore-certificate-errors"

    cat > /etc/systemd/system/wings.service << WINGSSVC
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=$exec_start
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
WINGSSVC

    systemctl daemon-reload
    log_success "Wings installed at $WINGS_BINARY"
}

update_wings_token() {
    local token_id="${1}"
    local token_value="${2}"
    local panel_url="${3}"
    local backend_port="${4:-}"

    if [[ ! -f "$WINGS_CONFIG" ]]; then
        log_error "Wings config not found"
        return 1
    fi

    sed -i "s/token_id: \"[^\"]*\"/token_id: \"$token_id\"/" "$WINGS_CONFIG"
    sed -i "s/token: \"[^\"]*\"/token: \"$token_value\"/" "$WINGS_CONFIG"
    local remote_url="$panel_url"
    [[ -n "$backend_port" ]] && remote_url="http://127.0.0.1:$backend_port"
    sed -i "s|remote: .*|remote: $remote_url|" "$WINGS_CONFIG"

    systemctl restart wings 2>/dev/null || true
    log_success "Wings token updated"
}

update_wings_remote() {
    local panel_url="${1}"
    local backend_port="${2:-}"
    [[ ! -f "$WINGS_CONFIG" ]] && return 0
    local remote_url use_ignore_cert=false
    if [[ -z "$backend_port" && "$panel_url" == https://* ]]; then
        remote_url="$panel_url"
        use_ignore_cert=true
    else
        local port="${backend_port:-80}"
        remote_url="http://127.0.0.1:$port"
        sed -i "s/port: [0-9]*/port: $port/" "$WINGS_CONFIG" 2>/dev/null || true
    fi
    sed -i "s|remote: .*|remote: $remote_url|" "$WINGS_CONFIG"
    local exec_start="$WINGS_BINARY"
    [[ "$use_ignore_cert" == true ]] && exec_start="$WINGS_BINARY --ignore-certificate-errors"
    [[ -f /etc/systemd/system/wings.service ]] && sed -i "s|ExecStart=.*|ExecStart=$exec_start|" /etc/systemd/system/wings.service
    systemctl daemon-reload
    systemctl restart wings 2>/dev/null || true
    log_success "Wings remote updated to $remote_url"
}
# Pterodactyl Panel Installer - Cloudflare Tunnel setup
# Supports Quick Tunnel and Named Tunnel



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

    # Auto-setup: if user has logged in, run create + route dns automatically
    local cert_locations=("/root/.cloudflared/cert.pem" "/etc/cloudflared/cert.pem")
    local has_login=""
    for c in "${cert_locations[@]}"; do
        [[ -f "$c" ]] && has_login=1 && break
    done
    # Also treat as logged in if tunnel list works (proves auth)
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
            if cloudflared tunnel route dns "$tunnel_name" "$domain"; then
                log_success "DNS route created: $domain -> $tunnel_name"
            else
                if cloudflared tunnel route dns "$tunnel_name" "$domain" --overwrite-dns; then
                    log_success "DNS route created: $domain -> $tunnel_name"
                else
                    log_warn "Auto-setup: route dns failed. Ensure domain $domain is in Cloudflare."
                fi
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
# Pterodactyl Panel - Switch Mode (Tunnel / NPM / NPM+Tunnel)
# Switch between modes for existing panel installation



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
    prompt_read() { if [[ -e /dev/tty ]]; then read -rp "$1" < /dev/tty || true; else read -rp "$1" || true; fi; }
    prompt_read_s() { if [[ -e /dev/tty ]]; then read -rsp "$1" < /dev/tty || true; else read -rsp "$1" || true; fi; }

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
            if [[ "$FQDN" == "localhost" || "$FQDN" == "127.0.0.1" || -z "$FQDN" ]]; then
                while [[ "$FQDN" == "localhost" || "$FQDN" == "127.0.0.1" || -z "$FQDN" ]]; do
                    prompt_read "Named Tunnel requires a domain. Enter domain (e.g. panel.example.com): "
                    FQDN="${REPLY:-}"
                    [[ -z "$FQDN" ]] && log_warn "Domain is required for Named Tunnel"
                done
            fi
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
    if [[ -e /dev/tty ]]; then
        read -rp "$1" < /dev/tty || true
    else
        read -rp "$1" || true
    fi
}

main_menu() {
    local choice
    if choice=$(tui_menu "Pterodactyl Panel" "Select an option:" 18 70 \
        "1" "Fresh Install - Full panel installation" \
        "2" "Switch Mode - Change HTTP / HTTPS / CF Tunnel" \
        "3" "Install Wings - Add Wings daemon (game servers)" \
        "4" "Fix Panel - Fix 500 error, permissions, cache" \
        "5" "Remove - Uninstall panel, wings, database" \
        "6" "Remove and Install - Uninstall then fresh install" \
        "7" "Configure Wings - Apply deployment config from Panel" \
        "8" "Exit") && [[ -n "$choice" ]]; then
        echo "$choice"
        return 0
    fi
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
        echo "  [7] Configure Wings     - Apply deployment config from Panel"
        echo "  [8] Exit"
        echo ""
    } >&2
    prompt_read "Enter 1-8: "
    echo "${REPLY:-1}"
}

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

    local choice
    if choice=$(tui_menu "Switch Mode" "Current: $mode_name | FQDN: ${fqdn:-localhost}\n\nSelect mode:" 14 65 \
        "1" "Tunnel - Panel + Wings on Cloudflare Tunnel" \
        "2" "NPM - Panel + Wings on Nginx Proxy Manager" \
        "3" "NPM + Tunnel - Both NPM domain and trycloudflare.com" \
        "4" "Back to main menu") && [[ -n "$choice" ]]; then
        :
    else
        {
            echo ""
            echo "Current mode: $mode_name | FQDN: ${fqdn:-localhost}"
            echo ""
            echo "  Switch to:"
            echo "  [1] Tunnel - Panel + Wings on Cloudflare Tunnel"
            echo "  [2] NPM - Panel + Wings on Nginx Proxy Manager"
            echo "  [3] NPM + Tunnel - Both NPM domain and trycloudflare.com"
            echo "  [4] Back to main menu"
            echo ""
        } >&2
        prompt_read "Enter 1-4: "
        choice="${REPLY:-4}"
    fi

    local tunnel_choice domain_override
    case "$choice" in
        1)
            if tunnel_choice=$(tui_menu "Tunnel Type" "Select tunnel type:" 10 55 \
                "a" "Quick Tunnel (trycloudflare.com)" \
                "b" "Named Tunnel (your domain)") && [[ -n "$tunnel_choice" ]]; then
                :
            else
                { echo "  [a] Quick Tunnel (trycloudflare.com)"; echo "  [b] Named Tunnel (your domain)"; } >&2
                prompt_read "Enter a or b: "
                tunnel_choice=$(echo "${REPLY:-a}" | tr '[:upper:]' '[:lower:]')
            fi
            [[ "$tunnel_choice" != "b" ]] && tunnel_choice="a"
            if [[ "$tunnel_choice" == "b" ]]; then
                log_info "Selected: Named Tunnel (your domain)" >&2
                if [[ "${fqdn:-localhost}" == "localhost" || "${fqdn:-}" == "127.0.0.1" || -z "${fqdn:-}" ]]; then
                    domain_override=$(tui_input "Named Tunnel" "Enter your domain (e.g. panel.example.com):" "") || true
                    [[ -z "$domain_override" ]] && { prompt_read "Enter your domain (e.g. panel.example.com): "; domain_override="${REPLY:-}"; }
                    [[ -z "$domain_override" ]] && { log_error "Domain required for Named Tunnel." >&2; return 1; }
                fi
            fi
            switch_to_tunnel "$tunnel_choice" "${domain_override:-}" || { log_error "Switch failed." >&2; return 1; }
            ;;
        2) switch_to_npm || { log_error "Switch failed." >&2; return 1; } ;;
        3)
            if tunnel_choice=$(tui_menu "Tunnel Type" "Select tunnel type:" 10 55 \
                "a" "Quick Tunnel (trycloudflare.com)" \
                "b" "Named Tunnel (your domain)") && [[ -n "$tunnel_choice" ]]; then
                :
            else
                { echo "  [a] Quick Tunnel (trycloudflare.com)"; echo "  [b] Named Tunnel (your domain)"; } >&2
                prompt_read "Enter a or b: "
                tunnel_choice=$(echo "${REPLY:-a}" | tr '[:upper:]' '[:lower:]')
            fi
            [[ "$tunnel_choice" != "b" ]] && tunnel_choice="a"
            if [[ "$tunnel_choice" == "b" ]]; then
                log_info "Selected: Named Tunnel (your domain)" >&2
                if [[ "${fqdn:-localhost}" == "localhost" || "${fqdn:-}" == "127.0.0.1" || -z "${fqdn:-}" ]]; then
                    domain_override=$(tui_input "Named Tunnel" "Enter your domain (e.g. panel.example.com):" "") || true
                    [[ -z "$domain_override" ]] && { prompt_read "Enter your domain (e.g. panel.example.com): "; domain_override="${REPLY:-}"; }
                    [[ -z "$domain_override" ]] && { log_error "Domain required for Named Tunnel." >&2; return 1; }
                fi
            fi
            switch_to_npm_tunnel "$tunnel_choice" "${domain_override:-}" || { log_error "Switch failed." >&2; return 1; }
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
    # Mode 1 (Tunnel): empty backend_port = use tunnel URL + --ignore-certificate-errors
    # Mode 2, 3: use 127.0.0.1:8080
    if [[ "$mode" == "2" || "$mode" == "3" ]]; then
        backend_port="8080"
    else
        backend_port=""
    fi
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
    echo "" >&2
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
    [[ -z "$FQDN" ]] && FQDN=$(get_json_value "$SETTINGS_JSON_PATH" "fqdn")
    [[ -z "$FQDN" ]] && FQDN="localhost"
    local mode
    mode=$(grep -o '"install_mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_JSON_PATH" 2>/dev/null | sed 's/.*"\([123]\)".*/\1/' || echo "1")
    local panel_url
    panel_url=$(get_json_value "$SETTINGS_JSON_PATH" "panel_url")
    panel_url="${panel_url:-https://${FQDN}}"

    local input
    input=$(tui_input "Configure Wings" "1. Login to Panel: $panel_url\n2. Nodes -> Create Node (or select existing)\n3. Configuration tab -> Copy the deployment command\n\nPaste the deployment URL or full command:" "") || true
    if [[ -z "$input" ]]; then
        {
            echo ""
            echo "=============================================="
            echo "  Configure Wings from Panel"
            echo "=============================================="
            echo ""
            echo "1. Login to Panel: $panel_url"
            echo "2. Nodes -> Create Node (or select existing)"
            echo "3. Configuration tab -> Copy the deployment command"
            echo ""
            log_info "Paste the deployment URL (e.g. https://panel.example.com/api/application/nodes/1/configuration)"
            log_info "Or paste the full command (we will extract the URL)"
            echo ""
        } >&2
        prompt_read "Deployment URL or command: "
        input="${REPLY:-}"
    fi
    input=$(echo "$input" | xargs)
    [[ -z "$input" ]] && { log_error "Empty input. Aborted."; return 1; }

    local url="$input"
    if [[ "$input" == curl* ]]; then
        url=$(echo "$input" | grep -oE 'https?://[^|[:space:]]+' | head -1)
    fi
    [[ -z "$url" ]] && { log_error "Could not extract URL. Paste the deployment URL."; return 1; }

    log_info "Fetching and applying Wings config from Panel..."
    if curl -sSL "$url" | sudo -E bash; then
        log_success "Deployment script executed"
    else
        log_error "Deployment failed. Check the URL and Panel accessibility."
        return 1
    fi

    [[ ! -f "$WINGS_CONFIG" ]] && { log_error "Wings config not found at $WINGS_CONFIG"; return 1; }

    local backend_port=""
    [[ "$mode" == "2" || "$mode" == "3" ]] && backend_port="8080"
    if [[ -n "$backend_port" ]]; then
        log_info "Adjusting Wings for Mode $mode (127.0.0.1:$backend_port)..."
    else
        log_info "Adjusting Wings for Mode $mode (Tunnel URL + TLS verify disabled)..."
    fi
    sed -i 's/host:[[:space:]]*[^[:space:]]*/host: 127.0.0.1/' "$WINGS_CONFIG" 2>/dev/null || true
    update_wings_remote "$panel_url" "$backend_port"
    sed -i 's/"wings_installed":[[:space:]]*false/"wings_installed": true/' "$SETTINGS_JSON_PATH" 2>/dev/null || true
    log_success "Wings config applied"

    show_wings_next_steps "$mode" "$FQDN" "$panel_url"
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
     - FQDN: $FQDN (or your panel domain)
     - Behind Proxy: Yes, Use SSL: Yes
     - Memory/Disk: Set as needed
  4. After creating node, go to Configuration tab
  5. Run the deployment command shown there on this server
     (or use menu [7] Configure Wings in the script and paste the deployment URL)

Required ports (open in firewall - cannot use Cloudflare proxy):
  - 2022/tcp   SFTP (file uploads to game servers)
  - Game ports from Allocations (e.g. 25565 Minecraft, 27015 Source)
  Example: ufw allow 2022/tcp && ufw allow 25565/tcp && ufw reload

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
                NAMED_TUNNEL_READY=0
                setup_named_tunnel "pterodactyl-panel" "$FQDN"
                if [[ "${NAMED_TUNNEL_READY:-0}" == "1" ]]; then
                    FINAL_PANEL_URL="https://${FQDN}"
                else
                    FINAL_PANEL_URL="https://${FQDN} (after completing steps)"
                fi
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
                NAMED_TUNNEL_READY=0
                setup_named_tunnel "pterodactyl-panel" "$FQDN" "8080"
                if [[ "${NAMED_TUNNEL_READY:-0}" == "1" ]]; then
                    FINAL_PANEL_URL="https://${FQDN} (NPM + CF tunnel)"
                else
                    FINAL_PANEL_URL="https://${FQDN} (NPM + CF tunnel, after completing steps)"
                fi
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
        # Mode 1 (Tunnel): empty backend_port = use tunnel URL (HTTPS) + --ignore-certificate-errors
        # Mode 2, 3: use 127.0.0.1:8080
        if [[ "$INSTALL_MODE" == "1" ]]; then
            install_wings "$wings_remote_url" "" ""
        else
            install_wings "$wings_remote_url" "" "$WINGS_API_PORT"
        fi
        systemctl enable wings 2>/dev/null || true
        wings_installed=true
    else
        log_info "Skipping Wings installation"
    fi

    save_settings_json "$FINAL_PANEL_URL" "$wings_installed"
    save_credentials "$FINAL_PANEL_URL"

        mkdir -p /opt/pterodactyl-install-script
    if [[ -f "${BASH_SOURCE[0]}" ]]; then
        cp "${BASH_SOURCE[0]}" /opt/pterodactyl-install-script/install.sh
    else
        curl -sSL "https://raw.githubusercontent.com/KCCHDEV/pterodactyl-install-script/refs/heads/main/install.sh" -o /opt/pterodactyl-install-script/install.sh 2>/dev/null || true
    fi
    chmod +x /opt/pterodactyl-install-script/install.sh 2>/dev/null || true

    echo ""
    echo "=============================================="
    log_success "Installation complete!"
    echo "=============================================="
    echo ""
    echo "Panel URL: $FINAL_PANEL_URL"
    echo "Settings: $SETTINGS_JSON_PATH"
    echo "Uninstall: Run script again, choose [5] Remove"
    echo ""
    echo "Next steps:"
    echo "  1. Login with admin / (your password)"
    echo "  2. Create Location and Node (see $CREDENTIALS_FILE)"
    if [[ "$wings_installed" == "true" ]]; then
        echo "  3. Run the node deployment command from panel Configuration (or use menu [7] Configure Wings)"
        echo "  4. Start Wings: systemctl start wings"
        echo "  5. Open firewall: ufw allow 2022/tcp (SFTP) and game ports from Allocations"
    else
        echo "  3. To install Wings later, run the installer again or use install-wings.sh"
    fi
    echo ""
}
run_main() {
    check_root
    if [[ ! -t 0 ]] && [[ ! -e /dev/tty ]]; then
        log_error "This script requires an interactive terminal. Run: sudo bash install.sh"
        exit 1
    fi
    ensure_tui 2>/dev/null || true
    local choice
    while true; do
        choice=$(main_menu) || choice=""
        [[ -z "$choice" ]] && continue
        case "$choice" in
            1) run_install; break ;;
            2) run_switch_mode ;;
            3) run_install_wings_only; break ;;
            4) run_fix_panel ;;
            5) run_remove; break ;;
            6) run_remove_and_install; break ;;
            7) run_configure_wings ;;
            8) log_info "Exit"; exit 0 ;;
            *) run_install; break ;;  # Default for invalid input
        esac
    done
}

# Run when executed (file or curl|bash pipe)
# - File: BASH_SOURCE[0]==$0
# - Pipe: BASH_SOURCE empty, or stdin not a TTY
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]] || [[ -z "${BASH_SOURCE[0]:-}" ]] || [[ ! -t 0 ]]; then
    run_main
fi
