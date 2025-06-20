#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

export KODI_PREFIX="/usr"
export BUILD_DIR="/tmp/kodi-build"
export SOURCE_DIR="/tmp/kodi-source"

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
    "-DENABLE_INTERNAL_FFMPEG=ON"
    "-DENABLE_INTERNAL_DAV1D=ON"
    "-DENABLE_UDEV=ON"
)

clone_kodi_source() {
    log_info "Cloning Kodi source code..."
    if ! git clone --depth 1 -b "Omega" "https://github.com/xbmc/xbmc" "$SOURCE_DIR"; then
        die "Failed to clone Kodi repository"
    fi

    log_success "Source code cloned successfully"
}

patch_ffmpeg_cmake() {
    local cmake_file="$SOURCE_DIR/tools/depends/target/ffmpeg/CMakeLists.txt"

    if [ -f "$cmake_file" ]; then
        log_info "Patching FFmpeg CMakeLists.txt to fix VA-API detection..."

        # Create a wrapper script that will capture debug info
        local wrapper_dir="$BUILD_DIR/wrappers"
        mkdir -p "$wrapper_dir"

        # Create enhanced pkg-config wrapper that logs both calls AND output
        cat > "$wrapper_dir/pkg-config" << 'EOF'
#!/bin/bash
# Enhanced debug wrapper for pkg-config

# Set paths if not already set
if [ -z "$PKG_CONFIG_PATH" ]; then
    export PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/lib64/pkgconfig:/usr/share/pkgconfig"
fi

# For debugging VA-API specifically
if [[ "$*" == *"libva"* ]]; then
    echo "[PKG-CONFIG-WRAPPER] VA-API query: $@" >&2
    echo "[PKG-CONFIG-WRAPPER] PKG_CONFIG_PATH: ${PKG_CONFIG_PATH}" >&2

    # Run the command and capture output
    OUTPUT=$(/usr/bin/pkg-config "$@" 2>&1)
    EXITCODE=$?

    echo "[PKG-CONFIG-WRAPPER] Exit code: $EXITCODE" >&2
    echo "[PKG-CONFIG-WRAPPER] Output: '$OUTPUT'" >&2

    # Also test if libva exists
    if /usr/bin/pkg-config --exists libva; then
        echo "[PKG-CONFIG-WRAPPER] libva exists check: PASSED" >&2
    else
        echo "[PKG-CONFIG-WRAPPER] libva exists check: FAILED" >&2
    fi

    # Output the result
    echo "$OUTPUT"
    exit $EXITCODE
else
    # For non-VA-API queries, just pass through
    exec /usr/bin/pkg-config "$@"
fi
EOF
        chmod +x "$wrapper_dir/pkg-config"

        # Create enhanced configure wrapper
        cat > "$wrapper_dir/configure-wrapper" << 'EOF'
#!/bin/bash
echo "=== FFMPEG CONFIGURE DEBUG ===" >&2
echo "Current directory: $(pwd)" >&2
echo "Configure args: $@" >&2

# Ensure pkg-config can find VA-API
export PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/lib64/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH}"
echo "PKG_CONFIG_PATH: ${PKG_CONFIG_PATH}" >&2

# Test VA-API detection manually
echo "=== Manual VA-API detection test ===" >&2
echo "which pkg-config: $(which pkg-config)" >&2

# Test with the actual pkg-config binary
echo "Testing with /usr/bin/pkg-config directly:" >&2
if /usr/bin/pkg-config --exists libva; then
    echo "  libva exists: YES" >&2
    echo "  version: $(/usr/bin/pkg-config --modversion libva)" >&2
    echo "  cflags: $(/usr/bin/pkg-config --cflags libva)" >&2
    echo "  libs: $(/usr/bin/pkg-config --libs libva)" >&2
else
    echo "  libva exists: NO" >&2
fi

# Test for specific VA-API components that FFmpeg might need
for valib in libva libva-drm libva-x11; do
    echo "Testing $valib:" >&2
    if /usr/bin/pkg-config --exists $valib 2>/dev/null; then
        echo "  $valib: FOUND (version: $(/usr/bin/pkg-config --modversion $valib 2>/dev/null))" >&2
    else
        echo "  $valib: NOT FOUND" >&2
    fi
done

# Check for VA-API headers directly
echo "Checking VA-API headers:" >&2
for header in /usr/include/va/va.h /usr/include/va/va_version.h; do
    if [ -f "$header" ]; then
        echo "  $header: EXISTS" >&2
    else
        echo "  $header: MISSING" >&2
    fi
done

# Check for libva libraries
echo "Checking libva libraries:" >&2
for lib in /usr/lib64/libva.so /usr/lib/libva.so /usr/lib64/libva.so.2 /usr/lib/libva.so.2; do
    if [ -e "$lib" ]; then
        echo "  $lib: EXISTS" >&2
    fi
done

echo "=== Running FFmpeg configure ===" >&2

# Create a temporary script to intercept config.log
ORIG_DIR=$(pwd)
"$1" "${@:2}" 2>&1 | tee /tmp/ffmpeg-configure.log
RESULT=${PIPESTATUS[0]}

# If configure failed, show the VA-API specific parts of config.log
if [ $RESULT -ne 0 ]; then
    echo "=== Configure failed with exit code $RESULT ===" >&2

    # Find and display config.log
    for log in ffbuild/config.log config.log; do
        if [ -f "$log" ]; then
            echo "=== Showing VA-API checks from $log ===" >&2
            # Look for VA-API related checks
            grep -A 20 -B 5 "vaapi\|libva\|va\.h\|va_drm\|va_x11" "$log" 2>/dev/null | tail -500 >&2

            # Also show the last 100 lines
            echo "=== Last 100 lines of $log ===" >&2
            tail -100 "$log" >&2
            break
        fi
    done
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

        # Additionally, let's try adding explicit paths for VA-API
        sed -i "/list(APPEND ffmpeg_conf \${CONFIGARCH})/a\\
\\
# Add explicit paths for VA-API on Bazzite\\
if(NOT CROSSCOMPILING AND ENABLE_VAAPI)\\
  # Bazzite might have VA-API in /usr/lib instead of /usr/lib64\\
  list(APPEND ffmpeg_conf --extra-cflags=-I/usr/include)\\
  list(APPEND ffmpeg_conf --extra-ldflags=-L/usr/lib)\\
endif()\\
" "$cmake_file"

        log_success "FFmpeg CMakeLists.txt patched with enhanced debug wrappers"
    else
        log_error "FFmpeg CMakeLists.txt not found at expected location"
    fi
}

configure_build() {
    log_info "Configuring Kodi build..."

    # Apply the patch
    patch_ffmpeg_cmake

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"


    # Use the HDR-specific CMake arguments (no modifications)
    local cmake_args=("${KODI_CMAKE_ARGS[@]}")

    # Ensure VA-API is discoverable
    export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"

    log_info "PKG_CONFIG_PATH for build: $PKG_CONFIG_PATH"

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

    log_success "Kodi build configured successfully"
}


build_kodi() {
    log_info "Building Kodi..."

    cd "$BUILD_DIR"

    local num_cores=$(nproc)
    log_info "Building with $num_cores parallel jobs..."

    if ! cmake --build . --parallel "$num_cores"; then
        die "Build failed"
    fi

    log_success "Build completed successfully"
}

install_kodi() {
    log_info "Installing Kodi..."

    cd "$BUILD_DIR"

    # Fixes missing dir error
    mkdir -p /usr/lib64/kodi/addons

    if ! make install; then
        die "Installation failed"
    fi

    log_success "Kodi installed"
}

# Main execution
main() {
    clone_kodi_source
    configure_build
    build_kodi
    install_kodi


    log_success "Kodi build file complete"

}

main "$@"
