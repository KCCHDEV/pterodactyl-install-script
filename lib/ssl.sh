#!/usr/bin/env bash
# Pterodactyl Panel Installer - Nginx HTTP/HTTPS configuration
# Creates Nginx config for HTTP, HTTPS (Let's Encrypt), Cloudflare Proxy (Origin SSL), or localhost-only (CF Tunnel)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

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
