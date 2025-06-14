#!/bin/bash

# System detection and capability checking

detect_system_capabilities() {
    local capabilities=""

    # Check for VA-API
    if pkg-config --exists libva 2>/dev/null || [ -f "/usr/include/va/va.h" ]; then
        capabilities="${capabilities} vaapi"
    elif rpm -q mesa-va-drivers >/dev/null 2>&1; then
        # Bazzite might have VA-API support without headers
        capabilities="${capabilities} vaapi"
    fi

    # Check for OpenGL/EGL
    if [ -d "/usr/include/EGL" ] || [ -f "/usr/lib64/libEGL.so" ]; then
        capabilities="${capabilities} egl"
    elif rpm -q mesa-libEGL >/dev/null 2>&1; then
        # Bazzite has EGL runtime without headers
        capabilities="${capabilities} egl"
    fi

    # Check for GLES
    if [ -d "/usr/include/GLES2" ] || [ -f "/usr/lib64/libGLESv2.so" ]; then
        capabilities="${capabilities} gles"
    elif rpm -q mesa-libGL >/dev/null 2>&1; then
        # Bazzite bundles GLES with GL
        capabilities="${capabilities} gles"
    fi

    # Check for GBM
    if pkg-config --exists gbm 2>/dev/null || [ -f "/usr/include/gbm.h" ]; then
        capabilities="${capabilities} gbm"
    elif rpm -q mesa-libgbm >/dev/null 2>&1; then
        # Bazzite has GBM runtime without headers
        capabilities="${capabilities} gbm"
    fi

    # Check for systemd
    if command -v systemctl >/dev/null 2>&1; then
        capabilities="${capabilities} systemd"
    fi

    # Check for Wayland
    if pkg-config --exists wayland-client 2>/dev/null; then
        capabilities="${capabilities} wayland"
    fi

    # Check for libdrm
    if pkg-config --exists libdrm 2>/dev/null || rpm -q libdrm >/dev/null 2>&1; then
        capabilities="${capabilities} drm"
    fi

    echo "$capabilities"
}

get_primary_user() {
    # Get the user who owns the most recent home directory
    # Avoid hardcoding UID 1000
    local primary_user=""

    # First try: get user from the newest non-root home directory
    primary_user=$(stat -c '%U %Y' /home/* 2>/dev/null | sort -k2 -nr | head -1 | cut -d' ' -f1)

    # Fallback: get first user with UID >= 1000
    if [ -z "$primary_user" ]; then
        primary_user=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd)
    fi

    # Final fallback
    [ -z "$primary_user" ] && primary_user="user"

    echo "$primary_user"
}

get_enabled_features() {
    echo "$BUILD_FEATURES"
}

check_gpu_vendor() {
    # Detect GPU vendor
    if lspci | grep -qi "amd\|ati\|radeon"; then
        echo "amd"
    elif lspci | grep -qi "intel"; then
        echo "intel"
    elif lspci | grep -qi "nvidia"; then
        echo "nvidia"
    else
        echo "unknown"
    fi
}

# Check if we're running on Bazzite
is_bazzite() {
    if [ -f "/usr/lib/os-release" ]; then
        grep -qi "bazzite" /usr/lib/os-release && return 0
    fi
    if [ -f "/etc/os-release" ]; then
        grep -qi "bazzite" /etc/os-release && return 0
    fi
    # Check for Bazzite-specific packages
    rpm -q bazzite-desktop >/dev/null 2>&1 || rpm -q bazzite-deck >/dev/null 2>&1
}

# Get Mesa version for matching devel packages
get_mesa_version() {
    rpm -q mesa-libGL --queryformat '%{VERSION}-%{RELEASE}\n' 2>/dev/null | head -1
}
