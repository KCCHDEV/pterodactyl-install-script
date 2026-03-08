#!/usr/bin/env bash
# Pterodactyl Panel Installer - Common functions
# Part of the auto installer suite

set -e

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(dirname "$SCRIPT_DIR")"

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

# TUI support (dialog or whiptail) - use when TTY available
USE_TUI=0
TUI_CMD=""
if [[ -t 0 ]] && [[ -e /dev/tty ]]; then
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

tui_password() {
    local title="$1" msg="$2"
    if [[ $USE_TUI -eq 1 && -n "$TUI_CMD" ]]; then
        if [[ "$TUI_CMD" == "dialog" ]]; then
            $TUI_CMD --stdout --no-shadow --insecure --title "$title" --passwordbox "$msg" 10 60 2>/dev/tty
        else
            $TUI_CMD --title "$title" --passwordbox "$msg" 10 60 3>&1 1>&2 2>&3
        fi
    else
        return 1
    fi
}

tui_yesno() {
    local title="$1" msg="$2" default="${3:-yes}"
    if [[ $USE_TUI -eq 1 && -n "$TUI_CMD" ]]; then
        if [[ "$TUI_CMD" == "dialog" ]]; then
            $TUI_CMD --no-shadow --title "$title" --yesno "$msg" 8 60 2>/dev/tty
        else
            $TUI_CMD --title "$title" --yesno "$msg" 8 60 2>/dev/tty
        fi
    else
        return 1
    fi
}

tui_msgbox() {
    local title="$1" msg="$2"
    if [[ $USE_TUI -eq 1 && -n "$TUI_CMD" ]]; then
        $TUI_CMD --title "$title" --msgbox "$msg" 10 60 2>/dev/tty
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
    if [[ -f "$INSTALLER_DIR/.install-config" ]]; then
        # shellcheck source=/dev/null
        source "$INSTALLER_DIR/.install-config"
        return 0
    fi
    return 1
}
