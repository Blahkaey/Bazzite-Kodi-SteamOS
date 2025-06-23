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
