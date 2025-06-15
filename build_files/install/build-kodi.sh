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
    # "$--depth 1 -b KODI_BRANCH"
    if ! git clone "$KODI_REPO" "$SOURCE_DIR"; then
        die "Failed to clone Kodi repository"
    fi

    log_success "Source code cloned successfully"
}


debug_ffmpeg_installation() {
       # Debug: Check for pkg-config files
    log_info "Checking for FFmpeg pkg-config files..."
    find /usr -name "libavcodec.pc" 2>/dev/null || log_warning "libavcodec.pc not found"
    find /usr -name "ffmpeg.pc" 2>/dev/null || log_warning "ffmpeg.pc not found"

    # Check what ffmpeg-devel installed
    log_info "Files installed by ffmpeg-devel:"
    rpm -ql ffmpeg-devel | grep -E "(\.pc|include)" | head -20

    # Set up pkg-config path - negativo17 might use different locations
    export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"

    # If negativo17 uses a different structure, add their paths
    if [ -d "/usr/lib64/ffmpeg/pkgconfig" ]; then
        export PKG_CONFIG_PATH="/usr/lib64/ffmpeg/pkgconfig:${PKG_CONFIG_PATH}"
    fi

    # Debug: Show pkg-config search
    log_info "PKG_CONFIG_PATH: $PKG_CONFIG_PATH"
    log_info "Searching for libavcodec with pkg-config..."
    pkg-config --exists libavcodec && pkg-config --modversion libavcodec || log_warning "libavcodec not found by pkg-config"

    log_info "Finding FFmpeg headers..."
    find /usr/include -name "avcodec.h" 2>/dev/null || log_warning "avcodec.h not found in /usr/include"

    log_info "Finding FFmpeg libraries..."
    ls -la /usr/lib64/libav* 2>/dev/null | head -10


    log_info "=== FFmpeg Installation Debug ==="

    # Check what ffmpeg packages are installed
    log_info "Installed FFmpeg packages:"
    rpm -qa | grep -i ffmpeg || true

    # Find actual FFmpeg libraries (not avahi)
    log_info "Finding libavcodec libraries:"
    find /usr -name "libavcodec.so*" 2>/dev/null || log_warning "libavcodec.so not found"

    # Check library locations from rpm
    log_info "Libraries from ffmpeg package:"
    rpm -ql ffmpeg | grep -E "\.so" || true

    log_info "Libraries from ffmpeg-libs (if installed):"
    rpm -ql ffmpeg-libs 2>/dev/null | grep -E "\.so" || log_info "ffmpeg-libs not installed"

    # Check for headers in all possible locations
    log_info "All files from ffmpeg-devel containing 'avcodec':"
    rpm -ql ffmpeg-devel | grep avcodec || true

    # Check if headers are in a subdirectory
    log_info "Searching for FFmpeg headers in all of /usr:"
    find /usr -name "avcodec.h" -type f 2>/dev/null || log_warning "avcodec.h not found anywhere"

    # List all directories created by ffmpeg-devel
    log_info "Directories created by ffmpeg-devel:"
    rpm -ql ffmpeg-devel | grep -E "/$" | sort -u || true

    log_info "Checking for ffmpeg command location and libs it uses:"
    which ffmpeg
    ldd $(which ffmpeg) | grep -E "libav|libsw" || true

    log_info "=== End FFmpeg Debug ==="
}


verify_vaapi_installation() {
    log_info "Verifying VA-API installation for FFmpeg..."

    # Check where VA-API libraries are installed
    local vaapi_lib_paths=()
    local vaapi_pc_paths=()

    # Check if VA-API headers exist
    if [ -d "/usr/include/va" ]; then
        log_success "VA-API headers found in standard location: /usr/include/va"
    else
        log_error "VA-API headers not found in /usr/include/va"
        # Search for them
        find /usr -path "*/va/va.h" 2>/dev/null | head -5
    fi

    # Find libva.so
    for lib in /usr/lib64/libva.so /usr/lib/libva.so /usr/local/lib64/libva.so /usr/local/lib/libva.so; do
        if [ -f "$lib" ] || [ -L "$lib" ]; then
            vaapi_lib_paths+=("$(dirname "$lib")")
            log_info "Found libva.so in: $(dirname "$lib")"
        fi
    done

    # Find libva.pc
    for pc in /usr/lib64/pkgconfig/libva.pc /usr/lib/pkgconfig/libva.pc /usr/share/pkgconfig/libva.pc; do
        if [ -f "$pc" ]; then
            vaapi_pc_paths+=("$(dirname "$pc")")
            log_info "Found libva.pc in: $(dirname "$pc")"
        fi
    done

    # Create symlinks if needed (Bazzite might have libraries in non-standard locations)
    #if [ ${#vaapi_lib_paths[@]} -gt 0 ] && [ ! -f "/usr/lib64/libva.so" ]; then
    #    log_info "Creating compatibility symlinks for VA-API..."

        # Find the actual library
        local src_lib="${vaapi_lib_paths[0]}/libva.so"
        #if [ -L "$src_lib" ]; then
            # Follow symlink to get the actual library
            src_lib=$(readlink -f "$src_lib")
        #fi

        # Create symlinks in standard location
        #if [ -f "$src_lib" ]; then
            ln -sf "$src_lib" /usr/lib64/libva.so 2>/dev/null || true
            ln -sf "${src_lib}.2" /usr/lib64/libva.so.2 2>/dev/null || true
            log_info "Created VA-API symlinks in /usr/lib64"
        #fi
    #fi

}

testing(){


    # Ensure libva.pc is accessible
    if ! pkg-config --exists libva 2>/dev/null; then
        log_warning "pkg-config cannot find libva, searching for libva.pc..."

        # Find all libva.pc files under /usr
        local pc_files
        pc_files=$(find /usr -type f -name 'libva.pc' 2>/dev/null || true)

        if [[ -n "${pc_files:-}" ]]; then
            log_info "Found libva.pc files:"
            echo "$pc_files"

            # Take the first one and add its directory to PKG_CONFIG_PATH
            local pc_path
            pc_path=$(dirname "$(printf '%s\n' "$pc_files" | head -n1)")
            export PKG_CONFIG_PATH="${pc_path}${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"

            log_info "Prepended '$pc_path' to PKG_CONFIG_PATH:"
            log_info "  PKG_CONFIG_PATH=$PKG_CONFIG_PATH"

            # Now re-check
            if pkg-config --exists libva; then
                log_info "pkg-config can now find libva."
            else
                log_warning "Still cannot find libva via pkg-config after updating PKG_CONFIG_PATH."
            fi
        else
            log_warning "No libva.pc files found under /usr "
        fi
    fi

}

patch_ffmpeg_cmake() {
    local cmake_file="$SOURCE_DIR/tools/depends/target/ffmpeg/CMakeLists.txt"

    if [ -f "$cmake_file" ]; then
        log_info "Patching FFmpeg CMakeLists.txt to fix VA-API detection..."


        # Fix the PKG_CONFIG_PATH issue
        sed -i '
        /if(ENABLE_DAV1D)/,/endif()/ {
            /set(pkgconf_path/d
        }
        /list(APPEND ffmpeg_conf ${CONFIGARCH})/i\
# Always set PKG_CONFIG_PATH for finding system libraries like VA-API\
set(pkgconf_path "PKG_CONFIG_PATH=${PKG_CONFIG_PATH}")\
' "$cmake_file"

        log_success "FFmpeg CMakeLists.txt patched"
    else
        log_error "FFmpeg CMakeLists.txt not found at expected location"
    fi
}

configure_build() {
    log_info "Configuring Kodi build for HDR support..."
    

    verify_vaapi_installation
    testing
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

    # Ensure VA-API is discoverable for internal FFmpeg
    export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"

    # IMPORTANT: Pass PKG_CONFIG_PATH to CMake so it reaches FFmpeg
    local system_pkg_config_path="$PKG_CONFIG_PATH"

    # Set up for internal FFmpeg with VA-API
    local cmake_args=("${KODI_CMAKE_ARGS[@]}")
    cmake_args+=("-DPKG_CONFIG_PATH=${system_pkg_config_path}")

    # Verify VA-API before building
    if pkg-config --exists libva libdrm; then
        log_success "VA-API dependencies found for internal FFmpeg"
        log_info "libva version: $(pkg-config --modversion libva)"
        log_info "libva cflags: $(pkg-config --cflags libva)"
        log_info "libva libs: $(pkg-config --libs libva)"
    else
        log_warning "VA-API may not be available in internal FFmpeg"
    fi

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

        log_info 'find /tmp/kodi-build -name "config.log" -path "*ffmpeg*" 2>/dev/null | xargs tail -800'
        find /tmp/kodi-build -name "config.log" -path "*ffmpeg*" 2>/dev/null | xargs tail -100

        log_info "cat /tmp/kodi-source/tools/depends/target/ffmpeg/CMakeLists.txt"
        cat /tmp/kodi-source/tools/depends/target/ffmpeg/CMakeLists.txt

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
