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
    if ! git clone "$KODI_REPO" "$SOURCE_DIR"; then
        die "Failed to clone Kodi repository"
    fi

    log_success "Source code cloned successfully"
}

debug_vaapi_setup() {
    log_info "=== VA-API Debug Information ==="

    # Test pkg-config with various paths
    log_info "Testing pkg-config paths..."

    # Test default pkg-config
    log_info "Default pkg-config test:"
    pkg-config --version || log_error "pkg-config not found!"
    pkg-config --variable pc_path pkg-config || log_error "Cannot get pkg-config paths"

    # Test with our paths
    export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
    log_info "With PKG_CONFIG_PATH=$PKG_CONFIG_PATH"

    if pkg-config --exists libva; then
        log_success "libva found by pkg-config!"
        log_info "libva version: $(pkg-config --modversion libva)"
        log_info "libva cflags: $(pkg-config --cflags libva)"
        log_info "libva libs: $(pkg-config --libs libva)"
    else
        log_error "libva NOT found by pkg-config"

        # Try to find libva.pc manually
        log_info "Searching for libva.pc files:"
        find /usr -name "libva.pc" -type f 2>/dev/null | while read pc; do
            log_info "  Found: $pc"
            log_info "  Contents:"
            cat "$pc" | head -10
        done
    fi

    # Check for VA-API headers
    log_info "Checking for VA-API headers:"
    if [ -f "/usr/include/va/va.h" ]; then
        log_success "Found /usr/include/va/va.h"
    else
        log_error "Missing /usr/include/va/va.h"
        find /usr -name "va.h" -path "*/va/*" 2>/dev/null | head -5
    fi

    # Check for VA-API libraries
    log_info "Checking for VA-API libraries:"
    for lib in /usr/lib64/libva.so /usr/lib/libva.so; do
        if [ -e "$lib" ]; then
            log_success "Found $lib"
            log_info "  Links to: $(readlink -f "$lib")"
        fi
    done

    log_info "=== End VA-API Debug ==="
}

patch_ffmpeg_cmake() {
    local cmake_file="$SOURCE_DIR/tools/depends/target/ffmpeg/CMakeLists.txt"

    if [ -f "$cmake_file" ]; then
        log_info "Patching FFmpeg CMakeLists.txt to fix VA-API detection..."

        # Create a wrapper script that will capture debug info
        local wrapper_dir="$BUILD_DIR/wrappers"
        mkdir -p "$wrapper_dir"

        # Create pkg-config wrapper
        cat > "$wrapper_dir/pkg-config" << 'EOF'
#!/bin/bash
# Debug wrapper for pkg-config
echo "[PKG-CONFIG-WRAPPER] Called with args: $@" >&2
echo "[PKG-CONFIG-WRAPPER] PKG_CONFIG_PATH: ${PKG_CONFIG_PATH}" >&2

# Set paths if not already set
if [ -z "$PKG_CONFIG_PATH" ]; then
    export PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/lib64/pkgconfig:/usr/share/pkgconfig"
    echo "[PKG-CONFIG-WRAPPER] Set PKG_CONFIG_PATH to: $PKG_CONFIG_PATH" >&2
fi

# Run the real pkg-config
exec /usr/bin/pkg-config "$@"
EOF
        chmod +x "$wrapper_dir/pkg-config"

        # Create configure wrapper to capture more debug info
        cat > "$wrapper_dir/configure-wrapper" << 'EOF'
#!/bin/bash
echo "=== FFMPEG CONFIGURE DEBUG ===" >&2
echo "Current directory: $(pwd)" >&2
echo "Configure args: $@" >&2
echo "Environment PKG_CONFIG_PATH: ${PKG_CONFIG_PATH}" >&2
echo "PATH: ${PATH}" >&2

# Ensure pkg-config can find VA-API
export PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/lib64/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH}"
echo "Set PKG_CONFIG_PATH to: ${PKG_CONFIG_PATH}" >&2

# Test VA-API before running configure
echo "Pre-configure VA-API test:" >&2
if pkg-config --exists libva; then
    echo "  VA-API found! Version: $(pkg-config --modversion libva)" >&2
    echo "  Cflags: $(pkg-config --cflags libva)" >&2
    echo "  Libs: $(pkg-config --libs libva)" >&2
else
    echo "  VA-API NOT FOUND by pkg-config!" >&2
fi

# Run configure and capture its output
echo "=== Running FFmpeg configure ===" >&2
"$1" "${@:2}" 2>&1 | tee /tmp/ffmpeg-configure.log

# Save the exit code
RESULT=$?

# If configure failed, show the relevant part of config.log
if [ $RESULT -ne 0 ]; then
    echo "=== Configure failed, showing config.log ===" >&2
    if [ -f "ffbuild/config.log" ]; then
        echo "=== Last 200 lines of config.log ===" >&2
        tail -200 ffbuild/config.log >&2

        echo "=== VA-API specific checks from config.log ===" >&2
        grep -A 10 -B 10 -i vaapi ffbuild/config.log >&2 || true
    fi
fi

exit $RESULT
EOF
        chmod +x "$wrapper_dir/configure-wrapper"

        # Now patch the CMakeLists.txt
        # First, add the wrapper directory to PATH for the build
        sed -i "/include(ExternalProject)/i\\
# Add wrapper directory to PATH for debugging\\
set(ENV{PATH} \"$wrapper_dir:\$ENV{PATH}\")\\
" "$cmake_file"

        # Replace the configure command to use our wrapper
        sed -i "s|<SOURCE_DIR>/configure|$wrapper_dir/configure-wrapper <SOURCE_DIR>/configure|g" "$cmake_file"

        # Also ensure pkg-config wrapper is used
        sed -i "/list(APPEND ffmpeg_conf \${CONFIGARCH})/a\\
\\
# Ensure pkg-config can find system libraries\\
if(NOT CROSSCOMPILING)\\
  list(APPEND ffmpeg_conf --pkg-config=$wrapper_dir/pkg-config)\\
endif()\\
" "$cmake_file"

        log_success "FFmpeg CMakeLists.txt patched with debug wrappers"
    else
        log_error "FFmpeg CMakeLists.txt not found at expected location"
    fi
}

configure_build() {
    log_info "Configuring Kodi build for HDR support..."

    # Debug VA-API setup before starting
    debug_vaapi_setup

    # Apply the patch
    patch_ffmpeg_cmake

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

    # Ensure VA-API is discoverable
    export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"

    log_info "PKG_CONFIG_PATH for build: $PKG_CONFIG_PATH"

    # Log configuration for HDR
    log_info "Building with HDR-optimized configuration:"
    log_info "  Platform: GBM (required for HDR)"
    log_info "  Render system: GLES (required for HDR passthrough)"
    log_info "  VA-API: Enabled (hardware acceleration)"
    log_info "  VDPAU: Disabled (incompatible with HDR)"

    log_info "CMake arguments:"
    printf '%s\n' "${cmake_args[@]}" | sed 's/^/  /'

    # Run cmake
    if ! cmake "$SOURCE_DIR" "${cmake_args[@]}"; then
        log_error "CMake configuration failed"
        die "Cannot proceed without HDR configuration"
    fi

    log_info "Verifying CMake configuration..."

    # Check GBM platform
    if ! grep -q -E "^CORE_PLATFORM_NAME:[A-Z]+=gbm" CMakeCache.txt; then
        log_error "GBM platform not configured correctly"
        die "Build misconfigured: GBM platform not set"
    else
        log_success "GBM platform verified"
    fi

    # Check GLES render system
    if ! grep -q -E "^APP_RENDER_SYSTEM:[A-Z]+=gles" CMakeCache.txt; then
        log_error "GLES render system not configured correctly"
        die "Build misconfigured: GLES render system not set"
    else
        log_success "GLES render system verified"
    fi

    BUILD_FEATURES="gbm gles vaapi hdr"
    echo "$BUILD_FEATURES" > /tmp/kodi-build-features-final.tmp

    log_success "HDR build configured successfully"
}

# Rest of the functions remain the same...
build_kodi() {
    log_info "Building Kodi with HDR support..."

    cd "$BUILD_DIR"

    local num_cores=$(nproc)
    log_info "Building with $num_cores parallel jobs..."

    if ! cmake --build . --parallel "$num_cores"; then
        # If build fails, try to show any captured logs
        if [ -f "/tmp/ffmpeg-configure.log" ]; then
            log_error "FFmpeg configure output:"
            cat /tmp/ffmpeg-configure.log
        fi

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

    if [ ! -f "${KODI_PREFIX}/bin/kodi-gbm" ]; then
        die "kodi-gbm binary not found - HDR build failed"
    fi

    log_success "HDR-enabled Kodi installed to ${KODI_PREFIX}"
}

setup_kodi_user() {
    log_info "Setting up Kodi user for HDR..."

    if ! id "$KODI_USER" >/dev/null 2>&1; then
        useradd -r -d "$KODI_HOME" -s /bin/bash "$KODI_USER"
        log_success "Created user: $KODI_USER"
    fi

    usermod -a -G render,video,input,audio "$KODI_USER"

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

    systemd-sysusers
    systemd-tmpfiles --create

    cleanup_dir "$service_dir"
    log_success "kodi-standalone-service installed"
}

# Main execution
main() {
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
