#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

# Add a trap to catch errors
trap 'log_error "Error occurred at line $LINENO in install-kodi.sh"; exit 1' ERR

# =============================================================================
# CONFIGURATION & CONSTANTS
# =============================================================================

# Versions and paths
readonly KODI_VERSION="Omega"
readonly KODI_REPO="https://github.com/xbmc/xbmc"
readonly KODI_PREFIX="/usr"

# Build directories - NOT readonly since we may change SOURCE_DIR
BUILD_DIR="/tmp/kodi-build"
SOURCE_DIR="/tmp/kodi-source"

# Cache directories (leveraging container cache mount)
readonly CACHE_BASE="/var/cache/kodi"
readonly SOURCE_CACHE_DIR="${CACHE_BASE}/sources"
CCACHE_DIR="${CACHE_BASE}/ccache"  # Not readonly, may be modified
readonly BUILD_STATE_FILE="${CACHE_BASE}/build-state"
readonly INSTALL_CACHE_DIR="${CACHE_BASE}/installed"
readonly INSTALL_MANIFEST="${CACHE_BASE}/install-manifest.txt"

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
    mkdir -p "$SOURCE_CACHE_DIR" "$CCACHE_DIR" "$INSTALL_CACHE_DIR" "$(dirname "$BUILD_STATE_FILE")"
    log_success "Cache directories initialized"
}

setup_ccache() {
    if command -v ccache >/dev/null 2>&1; then
        export CCACHE_DIR
        export CCACHE_COMPRESS=1
        export CCACHE_MAXSIZE="2G"

        # Don't override CC/CXX - let CMake handle it
        # Just ensure ccache is configured
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

# =============================================================================
# INSTALLATION CACHE MANAGEMENT
# =============================================================================

save_installed_files() {
    log_info "Caching installed files..."

    mkdir -p "$INSTALL_CACHE_DIR"

    # Save list of installed files
    find /usr/lib64/kodi /usr/bin/kodi* /usr/share/kodi -type f 2>/dev/null > "$INSTALL_MANIFEST" || true

    # Create a tarball of installed files
    if [[ -s "$INSTALL_MANIFEST" ]]; then
        tar -czf "${INSTALL_CACHE_DIR}/kodi-install.tar.gz" \
            --files-from="$INSTALL_MANIFEST" 2>/dev/null || {
            log_warning "Failed to create install cache"
            return 1
        }
        log_success "Installed files cached"
    else
        log_warning "No files found to cache"
        return 1
    fi
}

restore_installed_files() {
    log_info "Checking for cached installation..."

    if [[ -f "${INSTALL_CACHE_DIR}/kodi-install.tar.gz" ]]; then
        log_info "Restoring cached installation..."

        # Extract the cached files
        if tar -xzf "${INSTALL_CACHE_DIR}/kodi-install.tar.gz" -C / 2>/dev/null; then
            # Update library cache
            ldconfig
            log_success "Cached installation restored"
            return 0
        else
            log_warning "Failed to restore cached installation"
            rm -f "${INSTALL_CACHE_DIR}/kodi-install.tar.gz"
            return 1
        fi
    fi

    return 1
}

check_build_state() {
    if [[ -f "$BUILD_STATE_FILE" ]]; then
        local last_state=$(tail -1 "$BUILD_STATE_FILE" 2>/dev/null | cut -d'|' -f3)
        local last_version=$(tail -1 "$BUILD_STATE_FILE" 2>/dev/null | cut -d'|' -f2)

        if [[ "$last_state" == "completed" ]] && [[ "$last_version" == "$KODI_VERSION" ]]; then
            # Try to restore cached installation
            if restore_installed_files; then
                # Verify the binary exists after restore
                if [[ -x "/usr/lib64/kodi/kodi-gbm" ]]; then
                    log_info "Previous successful build restored from cache"
                    return 0
                fi
            fi
            log_warning "Build state shows completed but could not restore installation"
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

    # Check if we can use the cached source directly
    if [[ -d "${cached_source}/.git" ]]; then
        log_info "Found cached source at ${cached_source}"

        # Use the cached source directly instead of copying
        SOURCE_DIR="$cached_source"

        cd "$SOURCE_DIR"

        # Try to update, but don't fail if offline
        if git fetch --depth=1 origin "${KODI_VERSION}" 2>/dev/null; then
            if git rev-parse --verify "origin/${KODI_VERSION}" >/dev/null 2>&1; then
                git reset --hard "origin/${KODI_VERSION}"
                log_success "Source updated from remote"
            fi
        else
            log_info "Could not fetch updates, using existing cached source"
        fi
    else
        # Fresh clone directly to cache location
        log_info "Cloning fresh source..."
        mkdir -p "$(dirname "$cached_source")"

        if ! git clone --depth=1 --branch="${KODI_VERSION}" "$KODI_REPO" "$cached_source"; then
            die "Failed to clone Kodi repository"
        fi

        SOURCE_DIR="$cached_source"
        log_success "Source cloned to cache"
    fi

    # Verify source directory
    if [[ ! -f "$SOURCE_DIR/CMakeLists.txt" ]]; then
        die "Source directory is invalid: $SOURCE_DIR"
    fi
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

    # Use ccache via CMAKE_*_COMPILER_LAUNCHER instead of wrapping
    if command -v ccache >/dev/null 2>&1; then
        cmake_args+=("-DCMAKE_C_COMPILER_LAUNCHER=ccache")
        cmake_args+=("-DCMAKE_CXX_COMPILER_LAUNCHER=ccache")
    fi

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

    # Check if already configured
    if [[ -f "CMakeCache.txt" ]] && [[ -f "build.ninja" || -f "Makefile" ]]; then
        log_info "Build directory already configured, checking if reconfiguration needed..."

        # Check if source directory in cache matches
        local cached_source_dir=$(grep "CMAKE_HOME_DIRECTORY:" CMakeCache.txt | cut -d= -f2)
        if [[ "$cached_source_dir" == "$SOURCE_DIR" ]]; then
            log_info "Using existing build configuration"
            return 0
        else
            log_info "Source directory changed, reconfiguring..."
            rm -rf "$BUILD_DIR"/*
        fi
    fi

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

    # Show ccache stats before build (with error handling)
    if command -v ccache >/dev/null 2>&1; then
        log_info "Ccache stats before build:"
        if ! ccache --show-stats 2>/dev/null | grep -E "hit rate|cache size" | sed 's/^/  /'; then
            log_warning "Could not get ccache stats, continuing anyway"
        fi
    fi

    # Ensure CMAKE_BUILD_PARALLEL_LEVEL is set and valid
    if [[ -z "$CMAKE_BUILD_PARALLEL_LEVEL" ]] || [[ "$CMAKE_BUILD_PARALLEL_LEVEL" -eq 0 ]]; then
        CMAKE_BUILD_PARALLEL_LEVEL=$(nproc)
        log_warning "CMAKE_BUILD_PARALLEL_LEVEL was not set properly, using: $CMAKE_BUILD_PARALLEL_LEVEL"
    fi

    log_info "Starting build with $CMAKE_BUILD_PARALLEL_LEVEL parallel jobs..."

    # Build with better error handling and output
    if ! cmake --build . --parallel "$CMAKE_BUILD_PARALLEL_LEVEL" 2>&1 | tee build.log; then
        log_error "Build failed"

        # Show last 50 lines of build log for debugging
        log_error "Last 50 lines of build output:"
        tail -50 build.log | sed 's/^/  /'

        # Save failed state
        save_build_state "failed"

        die "Compilation failed"
    fi

    # Show ccache stats after build (with error handling)
    if command -v ccache >/dev/null 2>&1; then
        log_info "Ccache stats after build:"
        ccache --show-stats 2>/dev/null | grep -E "hit rate|cache size" | sed 's/^/  /' || true
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

    # Save installed files to cache
    save_installed_files

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
    log_info "Initializing cache directories..."
    init_cache_directories || { log_error "Failed to initialize cache directories"; exit 1; }

    log_info "Setting up ccache..."
    setup_ccache || { log_error "Failed to setup ccache"; exit 1; }

    log_info "Setting up build environment..."
    setup_build_environment || { log_error "Failed to setup build environment"; exit 1; }

    # Debug cache status at start (make it always run for now)
    log_info "Checking cache status..."
    debug_cache_info

    # Check if already built
    log_info "Checking build state..."
    if check_build_state; then
        if [[ -x "/usr/lib64/kodi/kodi-gbm" ]]; then
            log_info "Kodi already built and installed"
            log_info "To force rebuild, remove: $BUILD_STATE_FILE"
            return 0
        else
            log_warning "Build state indicates completion but binary missing, continuing with build..."
        fi
    else
        log_info "No previous successful build found, proceeding with build..."
    fi

    # Verify dependencies
    log_info "Verifying dependencies..."
    verify_dependencies || { log_error "Dependency verification failed"; exit 1; }

    # Build process
    log_info "Fetching source code..."
    fetch_kodi_source || { log_error "Failed to fetch source"; exit 1; }

    log_info "Configuring build..."
    configure_build || { log_error "Failed to configure build"; exit 1; }

    log_info "Starting build..."
    build_kodi || { log_error "Build failed"; exit 1; }

    log_info "Installing..."
    install_kodi || { log_error "Installation failed"; exit 1; }

    # Cleanup
    cleanup_build_artifacts

    log_success "Kodi HDR/GBM build completed successfully!"
}

# Execute main function with error handling
if ! main "$@"; then
    log_error "Kodi build process failed"
    exit 1
fi
