#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

# =============================================================================
# CONFIGURATION & CONSTANTS
# =============================================================================

# Versions and paths
readonly KODI_VERSION="Omega"
readonly KODI_REPO="https://github.com/xbmc/xbmc"
readonly KODI_PREFIX="/usr"

# Build directories
readonly BUILD_DIR="/tmp/kodi-build"
readonly SOURCE_DIR="/tmp/kodi-source"

# Cache directories (leveraging container cache mount)
readonly CACHE_BASE="/var/cache/kodi"
readonly SOURCE_CACHE_DIR="${CACHE_BASE}/sources"
readonly CCACHE_DIR="${CACHE_BASE}/ccache"
readonly BUILD_STATE_FILE="${CACHE_BASE}/build-state"

# Build configuration
declare -A BUILD_CONFIG=(
    [CMAKE_BUILD_TYPE]="Release"
    [CORE_PLATFORM_NAME]="gbm"
    [APP_RENDER_SYSTEM]="gles"
    [ENABLE_VAAPI]="ON"
    [ENABLE_VDPAU]="OFF"
    [ENABLE_INTERNAL_FMT]="ON"
    [ENABLE_INTERNAL_SPDLOG]="ON"
    [ENABLE_INTERNAL_FLATBUFFERS]="ON"
    [ENABLE_INTERNAL_CROSSGUID]="ON"
    [ENABLE_INTERNAL_FSTRCMP]="ON"
    [ENABLE_INTERNAL_FFMPEG]="ON"
    [ENABLE_INTERNAL_DAV1D]="ON"
    [ENABLE_UDEV]="ON"
)

# =============================================================================
# CACHE MANAGEMENT
# =============================================================================

init_cache_directories() {
    log_info "Initializing cache directories..."
    mkdir -p "$SOURCE_CACHE_DIR" "$CCACHE_DIR" "$(dirname "$BUILD_STATE_FILE")"
    log_success "Cache directories initialized"
}

setup_ccache() {
    if command -v ccache >/dev/null 2>&1; then
        export CCACHE_DIR
        export CCACHE_COMPRESS=1
        export CCACHE_MAXSIZE="2G"
        export CC="ccache gcc"
        export CXX="ccache g++"

        ccache --set-config=cache_dir="$CCACHE_DIR"
        ccache --zero-stats >/dev/null 2>&1

        log_success "Ccache enabled (cache: $CCACHE_DIR)"
    else
        log_warning "Ccache not available, builds will be slower"
    fi
}

save_build_state() {
    local state="$1"
    echo "$(date -u +%Y%m%d_%H%M%S)|${KODI_VERSION}|${state}" > "$BUILD_STATE_FILE"
}

check_build_state() {
    if [[ -f "$BUILD_STATE_FILE" ]]; then
        local last_state=$(tail -1 "$BUILD_STATE_FILE" | cut -d'|' -f3)
        if [[ "$last_state" == "completed" ]]; then
            log_info "Previous successful build detected"
            return 0
        fi
    fi
    return 1
}

# =============================================================================
# SOURCE CODE MANAGEMENT
# =============================================================================

fetch_kodi_source() {
    log_info "Fetching Kodi source code..."

    local cached_source="${SOURCE_CACHE_DIR}/${KODI_VERSION}"

    # Use cached source if available
    if [[ -d "${cached_source}/.git" ]]; then
        log_info "Using cached source from ${cached_source}"
        cp -r "$cached_source" "$SOURCE_DIR"

        # Update the cached copy
        cd "$SOURCE_DIR"
        if git fetch --depth=1 origin "${KODI_VERSION}" 2>/dev/null; then
            git reset --hard "origin/${KODI_VERSION}"
            log_success "Source updated from cache"
        else
            log_info "Using existing cached source"
        fi
    else
        # Fresh clone
        log_info "Cloning fresh source..."
        if ! git clone --depth=1 --branch="${KODI_VERSION}" "$KODI_REPO" "$SOURCE_DIR"; then
            die "Failed to clone Kodi repository"
        fi

        # Cache the clone
        mkdir -p "$(dirname "$cached_source")"
        cp -r "$SOURCE_DIR" "$cached_source"
        log_success "Source cloned and cached"
    fi

    cd - >/dev/null
}

# =============================================================================
# BUILD ENVIRONMENT
# =============================================================================

setup_build_environment() {
    log_info "Setting up build environment..."

    # Set parallel jobs
    export CMAKE_BUILD_PARALLEL_LEVEL=$(nproc)

    # Ensure pkg-config can find all libraries
    export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"

    # Set up library paths
    export LD_LIBRARY_PATH="/usr/lib64:/usr/lib:${LD_LIBRARY_PATH:-}"

    log_info "Build environment configured (${CMAKE_BUILD_PARALLEL_LEVEL} parallel jobs)"
}

verify_dependencies() {
    log_info "Verifying build dependencies..."

    local missing_deps=()

    # Check for critical headers
    local required_headers=(
        "/usr/include/va/va.h"
        "/usr/include/gbm.h"
        "/usr/include/EGL/egl.h"
        "/usr/include/GLES2/gl2.h"
    )

    for header in "${required_headers[@]}"; do
        if [[ ! -f "$header" ]]; then
            missing_deps+=("Header: $header")
        fi
    done

    # Check for critical libraries using pkg-config
    local required_libs=("libva" "gbm" "egl" "glesv2")

    for lib in "${required_libs[@]}"; do
        if ! pkg-config --exists "$lib" 2>/dev/null; then
            missing_deps+=("Library: $lib")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing dependencies:"
        printf '%s\n' "${missing_deps[@]}" | sed 's/^/  - /'
        die "Cannot proceed without required dependencies"
    fi

    log_success "All dependencies verified"
}

# =============================================================================
# CMAKE CONFIGURATION
# =============================================================================

generate_cmake_args() {
    local -a cmake_args=()

    # Add install prefix
    cmake_args+=("-DCMAKE_INSTALL_PREFIX=${KODI_PREFIX}")

    # Add all build configuration options
    for key in "${!BUILD_CONFIG[@]}"; do
        cmake_args+=("-D${key}=${BUILD_CONFIG[$key]}")
    done

    # Export for use in other functions
    CMAKE_ARGS=("${cmake_args[@]}")
}

configure_build() {
    log_info "Configuring Kodi build..."

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    generate_cmake_args

    log_info "CMake arguments:"
    printf '%s\n' "${CMAKE_ARGS[@]}" | sed 's/^/  /'

    if ! cmake "$SOURCE_DIR" "${CMAKE_ARGS[@]}"; then
        log_error "CMake configuration failed"

        # Provide helpful error information
        if [[ -f "CMakeFiles/CMakeError.log" ]]; then
            log_info "Last 50 lines of CMakeError.log:"
            tail -50 CMakeFiles/CMakeError.log | sed 's/^/  /'
        fi

        die "Build configuration failed"
    fi

    # Verify critical options
    verify_cmake_cache

    log_success "Build configured successfully"
}

verify_cmake_cache() {
    log_info "Verifying CMake configuration..."

    local cache_file="$BUILD_DIR/CMakeCache.txt"
    local errors=()

    # Check GBM platform
    if ! grep -q "CORE_PLATFORM_NAME:.*=gbm" "$cache_file"; then
        errors+=("GBM platform not configured")
    fi

    # Check GLES render system
    if ! grep -q "APP_RENDER_SYSTEM:.*=gles" "$cache_file"; then
        errors+=("GLES render system not configured")
    fi

    # Check VA-API
    if grep -q "ENABLE_VAAPI:.*=OFF" "$cache_file"; then
        errors+=("VA-API is disabled")
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        log_error "Configuration errors detected:"
        printf '%s\n' "${errors[@]}" | sed 's/^/  - /'
        die "Invalid build configuration"
    fi

    log_success "Configuration verified"
}

# =============================================================================
# BUILD & COMPILATION
# =============================================================================

build_kodi() {
    log_info "Building Kodi..."

    cd "$BUILD_DIR"

    # Show ccache stats before build
    if command -v ccache >/dev/null 2>&1; then
        log_info "Ccache stats before build:"
        ccache --show-stats | grep -E "hit rate|cache size" | sed 's/^/  /'
    fi

    # Build with error handling
    if ! cmake --build . --parallel "$CMAKE_BUILD_PARALLEL_LEVEL"; then
        log_error "Build failed"

        # Save failed state
        save_build_state "failed"

        die "Compilation failed"
    fi

    # Show ccache stats after build
    if command -v ccache >/dev/null 2>&1; then
        log_info "Ccache stats after build:"
        ccache --show-stats | grep -E "hit rate|cache size" | sed 's/^/  /'
    fi

    log_success "Build completed successfully"
}

# =============================================================================
# INSTALLATION
# =============================================================================

install_kodi() {
    log_info "Installing Kodi..."

    cd "$BUILD_DIR"

    # Create required directories
    mkdir -p /usr/lib64/kodi/addons

    # Install
    if ! make install; then
        save_build_state "install_failed"
        die "Installation failed"
    fi

    # Verify installation
    if [[ ! -x "/usr/lib64/kodi/kodi-gbm" ]]; then
        log_error "Kodi binary not found after installation"
        die "Installation verification failed"
    fi

    # Update library cache
    ldconfig

    save_build_state "completed"
    log_success "Kodi installed successfully"
}

cleanup_build_artifacts() {
    log_info "Cleaning up build artifacts..."

    # Remove build directory (source is cached)
    rm -rf "$BUILD_DIR"

    # Keep source dir for cache
    log_success "Build artifacts cleaned"
}

# =============================================================================
# MAIN ORCHESTRATION
# =============================================================================

main() {
    log_section "Kodi HDR/GBM Build Process"

    # Initialize
    init_cache_directories
    setup_ccache
    setup_build_environment

    # Check if already built
    if check_build_state && [[ -x "/usr/lib64/kodi/kodi-gbm" ]]; then
        log_info "Kodi already built and installed"
        log_info "To force rebuild, remove: $BUILD_STATE_FILE"
        return 0
    fi

    # Verify dependencies
    verify_dependencies

    # Build process
    fetch_kodi_source
    configure_build
    build_kodi
    install_kodi

    # Cleanup
    cleanup_build_artifacts

    log_success "Kodi HDR/GBM build completed successfully!"
}

# Execute main function
main "$@"
