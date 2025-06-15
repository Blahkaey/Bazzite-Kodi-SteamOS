#!/bin/bash
set -euo pipefail

SCRIPT_DIR="/ctx"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logging.sh"

# Load detected features
[ -f /tmp/kodi-build-features.tmp ] && SYSTEM_FEATURES=$(cat /tmp/kodi-build-features.tmp)

prepare_build_environment() {
    log_info "Preparing build environment..."

    cleanup_dir "$SOURCE_DIR"
    cleanup_dir "$BUILD_DIR"
    ensure_dir "$BUILD_DIR"
}

clone_kodi_source() {
    log_info "Cloning Kodi source code..."

    if ! git clone --depth 1 -b "$KODI_BRANCH" "$KODI_REPO" "$SOURCE_DIR"; then
        die "Failed to clone Kodi repository"
    fi

    log_success "Source code cloned successfully"
}

configure_build() {
    log_info "Configuring Kodi build for HDR support..."
    
    # Set up pkg-config path for FFmpeg to find VA-API
    export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:/usr/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    
    # Ensure VA-API is discoverable
    if pkg-config --exists libva; then
        log_info "VA-API found via pkg-config"
        pkg-config --modversion libva
    else
        log_warning "VA-API not found via pkg-config"
    fi
    
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Verify GBM support before proceeding
    if [[ "$SYSTEM_FEATURES" != *"gbm"* ]]; then
        die "GBM support is required for HDR but was not detected"
    fi

    if [[ "$SYSTEM_FEATURES" != *"gles"* ]]; then
        die "GLES support is required for HDR but was not detected"
    fi

    # Use the HDR-specific CMake arguments (no modifications)
    local cmake_args=("${KODI_CMAKE_ARGS[@]}")

    # Log configuration for HDR
    log_info "Building with HDR-optimized configuration:"
    log_info "  Platform: GBM (required for HDR)"
    log_info "  Render system: GLES (required for HDR passthrough)"
    log_info "  VA-API: Enabled (hardware acceleration)"
    log_info "  VDPAU: Disabled (incompatible with HDR)"

    log_info "CMake arguments:"
    printf '%s\n' "${cmake_args[@]}" | sed 's/^/  /'

    # Run cmake - NO FALLBACKS
    if ! cmake "$SOURCE_DIR" "${cmake_args[@]}"; then
        log_error "CMake configuration failed"
        log_error "This is a strict HDR build - no fallbacks available"
        die "Cannot proceed without HDR configuration"
    fi

    log_info "Verifying CMake configuration..."

    # Check GBM platform - match any cache entry type
    if ! grep -q -E "^CORE_PLATFORM_NAME:[A-Z]+=gbm" CMakeCache.txt; then
        log_error "GBM platform not found in CMakeCache.txt"
        log_error "Looking for: CORE_PLATFORM_NAME:*=gbm"
        log_error "Found:"
        grep "CORE_PLATFORM_NAME" CMakeCache.txt || echo "  (not found)"
        die "Build misconfigured: GBM platform not set"
    else
        log_success "GBM platform verified"
    fi

    # Check GLES render system - match any cache entry type
    if ! grep -q -E "^APP_RENDER_SYSTEM:[A-Z]+=gles" CMakeCache.txt; then
        log_error "GLES render system not found in CMakeCache.txt"
        log_error "Looking for: APP_RENDER_SYSTEM:*=gles"
        log_error "Found:"
        grep "APP_RENDER_SYSTEM" CMakeCache.txt || echo "  (not found)"
        die "Build misconfigured: GLES render system not set"
    else
        log_success "GLES render system verified"
    fi

    # Optional: Log what we actually found for debugging
    log_info "Build configuration confirmed:"
    grep -E "^(CORE_PLATFORM_NAME|APP_RENDER_SYSTEM):" CMakeCache.txt | sed 's/^/  /'

    BUILD_FEATURES="gbm gles vaapi hdr"
    echo "$BUILD_FEATURES" > /tmp/kodi-build-features-final.tmp

    log_success "HDR build configured successfully"
}

build_kodi() {
    log_info "Building Kodi with HDR support..."

    cd "$BUILD_DIR"

    local num_cores=$(nproc)
    log_info "Building with $num_cores parallel jobs..."

    if ! cmake --build . --parallel "$num_cores"; then
        die "Build failed - HDR build requirements not met"
    fi

    log_success "HDR build completed successfully"
}

install_kodi() {
    log_info "Installing HDR-enabled Kodi..."

    cd "$BUILD_DIR"

    if ! make install; then
        die "Installation failed"
    fi

    # Verify HDR-capable binary was installed
    if [ ! -f "${KODI_PREFIX}/bin/kodi-gbm" ]; then
        die "kodi-gbm binary not found - HDR build failed"
    fi

    log_success "HDR-enabled Kodi installed to ${KODI_PREFIX}"
}

setup_kodi_user() {
    log_info "Setting up Kodi user for HDR..."

    # Create kodi user if it doesn't exist
    if ! id "$KODI_USER" >/dev/null 2>&1; then
        useradd -r -d "$KODI_HOME" -s /bin/bash "$KODI_USER"
        log_success "Created user: $KODI_USER"
    fi

    # Add to required groups for HDR/DRM access
    usermod -a -G render,video,input,audio "$KODI_USER"

    # Create home directory
    ensure_dir "$KODI_HOME"
    chown -R "$KODI_USER:$KODI_USER" "$KODI_HOME"
}

install_kodi_standalone_service() {
    log_info "Installing kodi-standalone-service for HDR support..."

    local service_dir="/tmp/kodi-standalone-service"
    cleanup_dir "$service_dir"

    if ! git clone --depth 1 https://github.com/graysky2/kodi-standalone-service.git "$service_dir"; then
        die "Failed to clone kodi-standalone-service"
    fi

    cd "$service_dir"
    if ! make install; then
        die "Failed to install kodi-standalone-service"
    fi

    # Run required commands
    systemd-sysusers
    systemd-tmpfiles --create

    cleanup_dir "$service_dir"
    log_success "kodi-standalone-service installed"
}

# Main execution
main() {
    log_subsection "Building Kodi with HDR Support (GBM+GLES+VA-API)"

    #prepare_build_environment
    clone_kodi_source
    configure_build
    build_kodi
    install_kodi
    setup_kodi_user
    install_kodi_standalone_service

    # Cleanup
    log_info "Cleaning up build artifacts..."
    cleanup_dir "$SOURCE_DIR"
    cleanup_dir "$BUILD_DIR"
    rm -f /tmp/kodi-build-*.tmp

    log_success "HDR-enabled Kodi build complete"
    log_info "Build configuration: GBM + GLES + VA-API (HDR-capable)"
}

main "$@"
