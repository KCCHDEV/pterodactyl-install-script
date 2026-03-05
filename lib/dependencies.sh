#!/usr/bin/env bash
# Pterodactyl Panel Installer - Dependencies installation
# Installs MariaDB, PHP 8.3, Nginx, Redis, Composer, Node.js

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

install_base_packages() {
    log_info "Updating system packages..."
    apt-get update -qq
    apt-get install -y -qq software-properties-common curl wget git unzip apt-transport-https ca-certificates gnupg lsb-release

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
