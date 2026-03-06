# Install main logic - used by build.sh to create single-file install.sh
# This file is NOT executed directly. Build concatenates: lib/* + this + uninstall

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
