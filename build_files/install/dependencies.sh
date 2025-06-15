#!/bin/bash
set -euo pipefail

# Use absolute paths for containerized environment
SCRIPT_DIR="/ctx"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logging.sh"

# Load package lists from container mount
PACKAGE_CONFIG="${SCRIPT_DIR}/assets/package-lists.conf"

install_packages() {
    local category="$1"
    local required="$2"

    # Read packages from config
    local packages=$(grep "^${category}|" "$PACKAGE_CONFIG" 2>/dev/null | cut -d'|' -f2)

    if [ -z "$packages" ]; then
        log_warning "No packages defined for category: $category"
        return 1
    fi

    log_info "Installing $category packages..."

    # Convert to array
    local pkg_array=($packages)
    local failed_packages=()
    local installed_packages=()

    # Special handling for GBM_DEPS on Bazzite
    if [ "$category" = "GBM_DEPS" ]; then
        log_info "Attempting to install mesa devel packages from terra-mesa..."

        # Try to install mesa devel packages from COPR
        for pkg in mesa-libgbm-devel mesa-libEGL-devel; do
            if dnf5 install -y "$pkg" --repo "terra-mesa" >/dev/null 2>&1; then
                log_success "Installed $pkg from terra-mesa"
                installed_packages+=("$pkg")
            else
                log_warning "Could not install $pkg - will check if headers exist elsewhere"
            fi

        dnf5 config-manager setopt terra-mesa.enabled=0
        done
    fi

    # Batch install first (faster)
    if dnf5 install -y ${pkg_array[@]} >/dev/null 2>&1; then
        log_success "Batch installed $category packages"
        return 0
    fi

    # If batch fails, try one by one
    log_info "Batch install failed, trying individual packages..."

    for pkg in "${pkg_array[@]}"; do
        if rpm -q "$pkg" >/dev/null 2>&1; then
            log_debug "$pkg already installed"
            installed_packages+=("$pkg")
        elif dnf5 install -y "$pkg" >/dev/null 2>&1; then
            log_success "Installed $pkg"
            installed_packages+=("$pkg")
        else
            log_warning "Failed to install $pkg"
            failed_packages+=("$pkg")
        fi
    done

    # Report results
    log_info "Installation summary for $category:"
    log_info "  Installed: ${#installed_packages[@]} packages"
    log_info "  Failed: ${#failed_packages[@]} packages"

    # If required packages failed, abort
    if [ "$required" = "true" ] && [ ${#failed_packages[@]} -gt 0 ]; then
        log_error "Required packages failed to install:"
        printf '%s\n' "${failed_packages[@]}" | sed 's/^/  - /'
        return 1
    fi

    return 0
}


add_java11() {
    log_info "Adding Fedora 41 repository..."

    # Create a temporary repo file for Fedora 41
    cat > /tmp/fedora-41.repo << 'EOF'
[fedora-41]
name=Fedora 41 - x86_64
baseurl=https://download.fedoraproject.org/pub/fedora/linux/releases/41/Everything/x86_64/os/
enabled=1
gpgcheck=1
gpgkey=https://getfedora.org/static/fedora.gpg
priority=10
EOF

    dnf5 config-manager addrepo --from-repofile=/tmp/fedora-41.repo

    log_success "Fedora 41 repository added"

    if !dnf5 install -y java-11-openjdk-headless --repo fedora-41 >/dev/null 2>&1; then
        dnf5 search java-11-openjdk-headless
        die "Failed to java-11-openjdk-headless"
    fi

    dnf5 config-manager setopt fedora-41.enabled=0
    log_success "Java installed"
    log_success "Fedora 41 repository disabled"
}

verify_hdr_requirements() {
    log_info "Verifying HDR build requirements..."

    local missing_requirements=()

    # Check for GBM - Bazzite might not have the header in standard location
    if ! pkg-config --exists gbm 2>/dev/null; then
        # Check if mesa-libgbm is installed (runtime is sufficient for Bazzite)
        if ! rpm -q mesa-libgbm >/dev/null 2>&1; then
            missing_requirements+=("GBM library (mesa-libgbm)")
        else
            log_info "GBM runtime library found - headers may be bundled differently in Bazzite"
        fi
    fi

    # Check for GLES
    if [ ! -f "/usr/lib64/libGLESv2.so" ] && [ ! -f "/usr/lib/libGLESv2.so" ]; then
        # Check if it's in the mesa package
        if ! rpm -ql mesa-libGL | grep -q libGLES >/dev/null 2>&1; then
            missing_requirements+=("GLES libraries")
        fi
    fi

    # Check for libinput (required for GBM)
    if ! pkg-config --exists libinput 2>/dev/null; then
        missing_requirements+=("libinput development files")
    fi

    # Check for DRM - libdrm-devel should install normally
    if ! pkg-config --exists libdrm 2>/dev/null; then
        if [ ! -f "/usr/include/xf86drm.h" ] && [ ! -f "/usr/include/libdrm/drm.h" ]; then
            missing_requirements+=("DRM development files (libdrm-devel)")
        fi
    fi

    # Check for VA-API
    if ! pkg-config --exists libva 2>/dev/null && [ ! -f "/usr/include/va/va.h" ]; then
        log_warning "VA-API not found - HDR will work but without hardware acceleration"
    fi

    # Check for EGL (often bundled with mesa)
    if [ ! -f "/usr/include/EGL/egl.h" ]; then
        missing_requirements+=("EGL headers")
    fi

    if [ ${#missing_requirements[@]} -gt 0 ]; then
        log_error "Missing HDR requirements:"
        printf '%s\n' "${missing_requirements[@]}" | sed 's/^/  - /'
        log_info "Note: Bazzite uses custom mesa packages. Some headers may be bundled differently."
        log_info "Attempting to proceed with available libraries..."

        # Only fail if critical runtime libraries are missing
        if rpm -q mesa-libgbm mesa-libEGL >/dev/null 2>&1; then
            log_warning "Runtime libraries present - proceeding with build"
            return 0
        else
            return 1
        fi
    fi

    log_success "All HDR requirements verified"
    return 0
}

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



# Main execution
main() {
    log_subsection "Package Installation for Kodi HDR/GBM Build"

    # Check if package config exists
    if [ ! -f "$PACKAGE_CONFIG" ]; then
        die "Package configuration not found: $PACKAGE_CONFIG"
    fi

    dnf5 config-manager setopt "terra-mesa".enabled=1
    dnf5 repolist

    # Install java 11 headless using fedora 41 repo
    add_java11

    # Install packages by category
    install_packages "ESSENTIAL" true || die "Failed to install essential packages"
    install_packages "CORE_DEPS" true || die "Failed to install core dependencies"
    install_packages "GBM_DEPS" true || die "Failed to install GBM dependencies"
    install_packages "GRAPHICS" true || die "Failed to install graphics libraries"
    install_packages "VAAPI" true || die "Failed to install VA-API packages"
    install_packages "OPTIONAL" false  # Optional, don't fail
    install_packages "SERVICE" true || die "Failed to install service packages"

    ffmpeg -version
    dnf5 repolist

    dnf5 install https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm

    dnf5 install https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
    dnf5 repolist

    dnf5 swap ffmpeg-free ffmpeg --allowerasing
    dnf5 swap ffmpeg-free-devel ffmpeg-devel --allowerasing

    ffmpeg -version

    # Verify HDR requirements
    verify_hdr_requirements || die "HDR requirement verification failed"

    # Detect system capabilities
    SYSTEM_FEATURES=$(detect_system_capabilities)
    log_info "Detected system features: $SYSTEM_FEATURES"

    # Export for use by build script
    echo "$SYSTEM_FEATURES" > /tmp/kodi-build-features.tmp
}

# Call main with all arguments
main "$@"
