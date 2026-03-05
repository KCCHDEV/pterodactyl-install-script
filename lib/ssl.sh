#!/usr/bin/env bash
# Pterodactyl Panel Installer - Nginx HTTP/HTTPS configuration
# Creates Nginx config for HTTP, HTTPS (Let's Encrypt), or localhost-only (CF Tunnel)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

PANEL_PATH="${PANEL_PATH:-/var/www/pterodactyl}"
NGINX_AVAILABLE="/etc/nginx/sites-available/pterodactyl.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/pterodactyl.conf"

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

create_nginx_localhost() {
    # For Cloudflare Tunnel - only listen on localhost
    local domain="${1:-localhost}"
    log_info "Creating Nginx localhost-only config (for CF Tunnel)..."

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
    log_success "Nginx localhost config created (CF Tunnel mode)"
}
