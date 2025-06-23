#!/bin/bash

# Color codes
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    PURPLE=''
    CYAN=''
    BOLD=''
    NC=''
fi

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_section() {
    echo
    echo -e "${PURPLE}${BOLD}==== $* ====${NC}"
    echo
}

log_subsection() {
    echo
    echo -e "${CYAN}-- $* --${NC}"
}

log_debug() {
    [ "${DEBUG:-0}" = "1" ] && echo -e "${YELLOW}[DEBUG]${NC} $*"
}

die() {
    echo "[ERROR] $@" >&2
    exit 1
}

cleanup_dir() {
    local dir="$1"
    [ -d "$dir" ] && rm -rf "$dir"
}

debug_cache_info() {
    log_debug "=== Cache Debug Info ==="

    # Show all cache base directories
    log_debug "Cache structure:"
    find /var/cache -maxdepth 2 -type d \( -name "*kodi*" -o -name "*dependencies*" -o -name "*ccache*" \) 2>/dev/null | sort | sed 's/^/  /'

    # Dependencies cache info
    if [[ -d "/var/cache/dependencies" ]]; then
        log_debug "Dependencies cache:"
        du -sh /var/cache/dependencies/* 2>/dev/null | sed 's/^/  /'

        # Show install states
        if [[ -f "/var/cache/dependencies/install-state" ]]; then
            log_debug "Recent install states:"
            tail -10 /var/cache/dependencies/install-state 2>/dev/null | sed 's/^/  /'
        fi

        # LibVA cache info
        if [[ -d "/var/cache/dependencies/libva" ]]; then
            log_debug "LibVA cache contents:"
            ls -la /var/cache/dependencies/libva/ 2>/dev/null | head -5 | sed 's/^/  /'
        fi
    fi

    # Kodi cache info
    if [[ -d "/var/cache/kodi" ]]; then
        log_debug "Kodi cache:"
        du -sh /var/cache/kodi/* 2>/dev/null | sed 's/^/  /'

        # Show build state
        if [[ -f "/var/cache/kodi/build-state" ]]; then
            log_debug "Kodi build state:"
            tail -5 /var/cache/kodi/build-state 2>/dev/null | sed 's/^/  /'
        fi
    fi

    # Ccache stats if available
    if command -v ccache >/dev/null 2>&1 && [[ -d "/var/cache/kodi/ccache" ]]; then
        log_debug "Ccache stats:"
        CCACHE_DIR="/var/cache/kodi/ccache" ccache -s 2>/dev/null | grep -E "cache directory|cache size|hits|misses" | sed 's/^/  /'
    fi

    log_debug "===================="
}
