#!/usr/bin/env bash
# Pterodactyl Panel Cleaner
# Cleans logs, cache, temp files

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Load panel_path from settings JSON if exists
if [[ -f "$SETTINGS_JSON_PATH" ]]; then
    PANEL_PATH=$(get_json_value "$SETTINGS_JSON_PATH" "panel_path")
fi
PANEL_PATH="${PANEL_PATH:-/var/www/pterodactyl}"
DRY_RUN=0
KEEP_DAYS=7

usage() {
    echo "Usage: $0 [mode] [options]"
    echo ""
    echo "Modes:"
    echo "  logs   - Remove Laravel, Nginx, and old system logs"
    echo "  cache  - Clear Laravel cache, Composer cache (optional: Redis)"
    echo "  temp   - Remove temp files, expired sessions"
    echo "  all    - Run all modes above"
    echo ""
    echo "Options:"
    echo "  --dry-run       Show what would be deleted without deleting"
    echo "  --keep-days N   Keep logs newer than N days (default: 7)"
    echo ""
}

parse_args() {
    MODE=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --keep-days)
                KEEP_DAYS="${2:-7}"
                shift 2
                ;;
            logs|cache|temp|all)
                MODE="$1"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [[ -z "$MODE" ]]; then
        log_error "No mode specified"
        usage
        exit 1
    fi
}

safe_rm() {
    local path="$1"
    if [[ "$DRY_RUN" == 1 ]]; then
        if [[ -e "$path" ]]; then
            echo "  [DRY-RUN] Would remove: $path"
        fi
    else
        if [[ -e "$path" ]]; then
            rm -rf "$path"
            log_info "Removed: $path"
        fi
    fi
}

clean_logs() {
    log_info "Cleaning logs (keeping last ${KEEP_DAYS} days)..."
    if [[ -d "$PANEL_PATH/storage/logs" ]]; then
        if [[ "$DRY_RUN" == 1 ]]; then
            find "$PANEL_PATH/storage/logs" -name "*.log" -mtime +$KEEP_DAYS -print 2>/dev/null | while read -r f; do
                echo "  [DRY-RUN] Would remove: $f"
            done
        else
            find "$PANEL_PATH/storage/logs" -name "*.log" -mtime +$KEEP_DAYS -delete 2>/dev/null
        fi
    fi
    if [[ -d /var/log/nginx ]]; then
        if [[ "$DRY_RUN" == 1 ]]; then
            find /var/log/nginx -name "*.log" -mtime +$KEEP_DAYS -print 2>/dev/null | while read -r f; do
                echo "  [DRY-RUN] Would remove: $f"
            done
        else
            find /var/log/nginx -name "*.log.*" -mtime +$KEEP_DAYS -delete 2>/dev/null
        fi
    fi
    log_success "Logs cleaned"
}

clean_cache() {
    log_info "Cleaning cache..."
    if [[ -d "$PANEL_PATH" ]]; then
        if [[ "$DRY_RUN" == 1 ]]; then
            echo "  [DRY-RUN] Would run: php artisan cache:clear"
            echo "  [DRY-RUN] Would run: php artisan view:clear"
            echo "  [DRY-RUN] Would run: php artisan config:clear"
        else
            cd "$PANEL_PATH"
            php artisan cache:clear 2>/dev/null || true
            php artisan view:clear 2>/dev/null || true
            php artisan config:clear 2>/dev/null || true
        fi
    fi
    if [[ -d ~/.composer/cache ]]; then
        safe_rm ~/.composer/cache
    fi
    if [[ -d /root/.composer/cache ]]; then
        safe_rm /root/.composer/cache
    fi
    log_success "Cache cleaned"
}

clean_temp() {
    log_info "Cleaning temp files..."
    if [[ -d "$PANEL_PATH/storage/framework/sessions" ]]; then
        if [[ "$DRY_RUN" == 1 ]]; then
            echo "  [DRY-RUN] Would clean Laravel sessions"
        else
            find "$PANEL_PATH/storage/framework/sessions" -type f -mtime +1 -delete 2>/dev/null
        fi
    fi
    if [[ -d /tmp ]]; then
        if [[ "$DRY_RUN" == 1 ]]; then
            echo "  [DRY-RUN] Would clean old /tmp files"
        else
            find /tmp -type f -atime +7 -delete 2>/dev/null || true
        fi
    fi
    log_success "Temp cleaned"
}

run_cleaner() {
    parse_args "$@"

    check_root

    case "$MODE" in
        logs)
            clean_logs
            ;;
        cache)
            clean_cache
            ;;
        temp)
            clean_temp
            ;;
        all)
            clean_logs
            clean_cache
            clean_temp
            ;;
        *)
            log_error "Unknown mode: $MODE"
            exit 1
            ;;
    esac

    log_success "Cleaner finished."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_cleaner "$@"
fi
