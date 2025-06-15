#!/bin/bash

# Common variables for containerized build
export KODI_PREFIX="/usr/local"
export KODI_USER="kodi"
export KODI_HOME="/var/lib/kodi"
export BUILD_DIR="/tmp/kodi-build"
export SOURCE_DIR="/tmp/kodi-source"

export KODI_REPO="https://github.com/xbmc/xbmc"
export KODI_BRANCH="Omega"

# Container-specific paths
export SCRIPTS_DIR="/ctx"
export ASSETS_DIR="/ctx/assets"

# HDR-specific build configuration (NO FALLBACKS)
export KODI_CMAKE_ARGS=(
    "-DCMAKE_INSTALL_PREFIX=${KODI_PREFIX}"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DCORE_PLATFORM_NAME=gbm"
    "-DAPP_RENDER_SYSTEM=gles"
    "-DENABLE_VAAPI=ON"
    "-DENABLE_VDPAU=OFF"
    "-DENABLE_INTERNAL_FMT=ON"
    "-DENABLE_INTERNAL_SPDLOG=ON"
    "-DENABLE_INTERNAL_FLATBUFFERS=ON"
    "-DENABLE_INTERNAL_CROSSGUID=ON"
    "-DENABLE_INTERNAL_FSTRCMP=ON"
    "-DENABLE_UDEV=ON"
)
#"-DENABLE_INTERNAL_DAV1D=ON"
#"-DENABLE_INTERNAL_FFMPEG=ON"

# Feature detection results
export SYSTEM_FEATURES=""
export BUILD_FEATURES=""

# Utility functions
die() {
    echo "[ERROR] $@" >&2
    exit 1
}

ensure_dir() {
    local dir="$1"
    mkdir -p "$dir" || die "Failed to create directory: $dir"
}

cleanup_dir() {
    local dir="$1"
    [ -d "$dir" ] && rm -rf "$dir"
}

# Logging functions if not sourced from logging.sh
if ! type log_error >/dev/null 2>&1; then
    log_error() { echo "[ERROR] $@" >&2; }
    log_info() { echo "[INFO] $@"; }
    log_success() { echo "[SUCCESS] $@"; }
fi
