#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Cache directories (leveraging container cache mount)
readonly CACHE_BASE="/var/cache/dependencies"
readonly LIBVA_CACHE="${CACHE_BASE}/libva"
readonly INSTALL_STATE="${CACHE_BASE}/install-state"

# Repository configurations
readonly FEDORA_41_REPO="fedora-41"
readonly FEDORA_41_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Everything/x86_64/os/"
readonly TERRA_MESA_REPO="terra-mesa"  # Pre-exists in Bazzite

# Package definitions (inline for simplicity)
declare -A PACKAGE_GROUPS=(
    [ESSENTIAL]="git cmake gcc gcc-c++ make ninja-build autoconf automake libtool gettext gettext-devel pkgconf-pkg-config nasm yasm gperf swig python3-devel python3-pillow"

    [CORE_DEPS]="alsa-lib-devel avahi-compat-libdns_sd-devel avahi-devel bzip2-devel curl dbus-devel fontconfig-devel freetype-devel fribidi-devel gawk giflib-devel gtest-devel libao-devel libass-devel libcap-devel libcdio-devel libcurl-devel libidn2-devel libjpeg-turbo-devel lcms2-devel libmicrohttpd-devel libmpc-devel libogg-devel libpng-devel libsmbclient-devel libtool-ltdl-devel libudev-devel libunistring libunistring-devel libusb1-devel libuuid-devel libvorbis-devel libxkbcommon-devel libxml2-devel libXmu-devel libXrandr-devel libxslt-devel libXt-devel lzo-devel mariadb-devel openssl-devel openssl-libs patch pcre-devel pcre2-devel pulseaudio-libs-devel sqlite-devel taglib-devel tinyxml-devel tinyxml2-devel trousers-devel uuid-devel zlib zlib-static zlib-devel systemd polkit rapidjson-devel hwdata hwdata-devel jre exiv2-devel json-devel meson ninja-build inotify-tools"

    [GBM_DEPS]="libinput-devel libxkbcommon-devel mesa-libGLES-devel libdrm-devel"

    [GRAPHICS]="mesa-libGLES mesa-libgbm mesa-va-drivers mesa-libEGL libdrm libdisplay-info libdisplay-info-devel drm-utils"

    [OPTIONAL]="libbluray-devel libcec-devel libnfs-devel libplist-devel shairplay-devel flatbuffers flatbuffers-devel fmt-devel fstrcmp-devel spdlog-devel lirc-devel"
)

# Special packages that need specific repo handling
declare -A SPECIAL_PACKAGES=(
    [java-11-openjdk-headless]="$FEDORA_41_REPO"
    [mesa-libgbm-devel]="$TERRA_MESA_REPO"
    [mesa-libEGL-devel]="$TERRA_MESA_REPO"
)

# =============================================================================
# CACHE & STATE MANAGEMENT
# =============================================================================

init_cache() {
    log_info "Initializing dependency cache..."
    mkdir -p "$CACHE_BASE" "$LIBVA_CACHE" "$(dirname "$INSTALL_STATE")"
}

save_install_state() {
    local group="$1"
    local status="$2"
    echo "$(date -u +%Y%m%d_%H%M%S)|${group}|${status}" >> "$INSTALL_STATE"
}

check_install_state() {
    local group="$1"
    if [[ -f "$INSTALL_STATE" ]] && grep -q "|${group}|success" "$INSTALL_STATE"; then
        return 0
    fi
    return 1
}

# =============================================================================
# DNF OPTIMIZATION
# =============================================================================

configure_dnf_performance() {
    log_info "Optimizing DNF performance..."

    # Configure DNF for faster operations
    cat > /etc/dnf/dnf.conf.d/99-build-optimization.conf << 'EOF'
[main]
fastestmirror=True
max_parallel_downloads=10
keepcache=True
install_weak_deps=False
EOF

    # Single metadata refresh at start
    dnf5 makecache --refresh >/dev/null 2>&1 || log_warning "Failed to refresh DNF cache"
}

# =============================================================================
# REPOSITORY MANAGEMENT
# =============================================================================

add_temp_repo() {
    local repo_name="$1"
    local repo_url="$2"

    log_info "Adding temporary repository: $repo_name"

    # Use DNF config-manager instead of creating files
    dnf5 config-manager addrepo \
        --id="$repo_name" \
        --set="name='Temporary $repo_name'" \
        --set="baseurl=$repo_url" \
        --set="enabled=1" \
        --set="gpgcheck=0" \
        --set="priority=10" \
        >/dev/null 2>&1
}

remove_temp_repo() {
    local repo_name="$1"
    log_info "Removing temporary repository: $repo_name"
    dnf5 config-manager setopt "${repo_name}.enabled=0" >/dev/null 2>&1 || true
}

enable_existing_repo() {
    local repo_name="$1"
    log_info "Enabling repository: $repo_name"
    dnf5 config-manager setopt "${repo_name}.enabled=1" >/dev/null 2>&1
}

disable_existing_repo() {
    local repo_name="$1"
    log_info "Disabling repository: $repo_name"
    dnf5 config-manager setopt "${repo_name}.enabled=0" >/dev/null 2>&1
}

# =============================================================================
# PACKAGE INSTALLATION
# =============================================================================

install_package_group() {
    local group_name="$1"
    local required="${2:-true}"

    # Check if already installed
    if check_install_state "$group_name"; then
        log_info "Package group '$group_name' already installed, skipping"
        return 0
    fi

    # Get packages for this group
    local packages="${PACKAGE_GROUPS[$group_name]:-}"
    if [[ -z "$packages" ]]; then
        log_warning "No packages defined for group: $group_name"
        return 1
    fi

    log_info "Installing $group_name packages..."

    # Convert to array and filter out already installed packages
    local -a pkg_array=($packages)
    local -a to_install=()

    # Quick check for already installed packages
    for pkg in "${pkg_array[@]}"; do
        if ! rpm -q "$pkg" >/dev/null 2>&1; then
            to_install+=("$pkg")
        fi
    done

    if [[ ${#to_install[@]} -eq 0 ]]; then
        log_success "All $group_name packages already installed"
        save_install_state "$group_name" "success"
        return 0
    fi

    log_info "Need to install ${#to_install[@]} packages for $group_name"

    # Try batch installation with better error handling
    local install_cmd="dnf5 install -y --setopt=strict=0"

    if $install_cmd "${to_install[@]}" >/dev/null 2>&1; then
        log_success "Successfully installed $group_name packages"
        save_install_state "$group_name" "success"
        return 0
    fi

    # If batch failed and packages are required, try to identify which failed
    if [[ "$required" == "true" ]]; then
        log_error "Failed to install some $group_name packages"

        # Quick check to identify missing packages
        local -a failed=()
        for pkg in "${to_install[@]}"; do
            if ! rpm -q "$pkg" >/dev/null 2>&1; then
                failed+=("$pkg")
            fi
        done

        if [[ ${#failed[@]} -gt 0 ]]; then
            log_error "Failed packages:"
            printf '%s\n' "${failed[@]}" | sed 's/^/  - /'
            return 1
        fi
    else
        log_warning "Some optional packages in $group_name may have failed"
        save_install_state "$group_name" "partial"
    fi

    return 0
}

install_special_packages() {
    log_info "Installing special packages with repository handling..."

    # Install Java 11 from Fedora 41
    if ! rpm -q java-11-openjdk-headless >/dev/null 2>&1; then
        add_temp_repo "$FEDORA_41_REPO" "$FEDORA_41_URL"

        if dnf5 install -y java-11-openjdk-headless --repo "$FEDORA_41_REPO" >/dev/null 2>&1; then
            log_success "Installed java-11-openjdk-headless"
        else
            log_error "Failed to install java-11-openjdk-headless"
            remove_temp_repo "$FEDORA_41_REPO"
            return 1
        fi

        remove_temp_repo "$FEDORA_41_REPO"
    else
        log_info "java-11-openjdk-headless already installed"
    fi

    # Install Mesa development packages from terra-mesa
    enable_existing_repo "$TERRA_MESA_REPO"

    local mesa_packages=("mesa-libgbm-devel" "mesa-libEGL-devel")
    for pkg in "${mesa_packages[@]}"; do
        if ! rpm -q "$pkg" >/dev/null 2>&1; then
            if dnf5 install -y "$pkg" --repo "$TERRA_MESA_REPO" >/dev/null 2>&1; then
                log_success "Installed $pkg from $TERRA_MESA_REPO"
            else
                log_warning "Could not install $pkg"
            fi
        fi
    done

    disable_existing_repo "$TERRA_MESA_REPO"

    return 0
}

# =============================================================================
# LIBVA BUILD
# =============================================================================

check_libva_installed() {
    # Check if libva is already installed and recent
    if pkg-config --exists libva && [[ -f "/usr/lib64/libva.so" ]]; then
        local installed_version=$(pkg-config --modversion libva 2>/dev/null || echo "0.0.0")
        log_info "Found existing libva version: $installed_version"

        # Check if version is recent enough (2.20+)
        local major=$(echo "$installed_version" | cut -d. -f1)
        local minor=$(echo "$installed_version" | cut -d. -f2)

        if [[ "$major" -gt 2 ]] || [[ "$major" -eq 2 && "$minor" -ge 20 ]]; then
            log_success "libva $installed_version is recent enough, skipping build"
            return 0
        fi
    fi

    return 1
}

build_libva_cached() {
    log_info "Building libva from source..."

    # Check if already built
    if check_libva_installed; then
        return 0
    fi

    # Check cache for previous build
    local cache_marker="${LIBVA_CACHE}/build-complete"
    if [[ -f "$cache_marker" ]]; then
        log_info "Found cached libva build, installing..."
        cd "$LIBVA_CACHE"
        if ninja -C build install >/dev/null 2>&1; then
            ldconfig
            log_success "Installed libva from cache"
            return 0
        fi
    fi

    # Fresh build
    log_info "Building libva (this may take a few minutes)..."

    # Clean and prepare cache directory
    rm -rf "$LIBVA_CACHE"
    mkdir -p "$LIBVA_CACHE"
    cd "$LIBVA_CACHE"

    # Clone repository
    if ! git clone --depth=1 https://github.com/intel/libva.git . >/dev/null 2>&1; then
        log_error "Failed to clone libva repository"
        return 1
    fi

    # Configure build
    if ! meson setup build \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --buildtype=release \
        -Ddefault_library=shared \
        >/dev/null 2>&1; then
        log_error "Failed to configure libva build"
        return 1
    fi

    # Build
    if ! ninja -C build >/dev/null 2>&1; then
        log_error "Failed to compile libva"
        return 1
    fi

    # Install
    if ! ninja -C build install >/dev/null 2>&1; then
        log_error "Failed to install libva"
        return 1
    fi

    # Update library cache
    ldconfig

    # Mark build as complete
    touch "$cache_marker"

    log_success "libva built and installed successfully"
    cd - >/dev/null

    return 0
}

# =============================================================================
# VERIFICATION
# =============================================================================

verify_critical_dependencies() {
    log_info "Verifying critical dependencies..."

    local -a missing=()

    # Check critical commands
    local -a required_cmds=(
        "gcc:gcc"
        "g++:gcc-c++"
        "cmake:cmake"
        "ninja:ninja-build"
        "pkg-config:pkgconf-pkg-config"
        "meson:meson"
    )

    for cmd_info in "${required_cmds[@]}"; do
        local cmd="${cmd_info%%:*}"
        local pkg="${cmd_info##*:}"

        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd (package: $pkg)")
        fi
    done

    # Check critical headers
    local -a required_headers=(
        "/usr/include/gbm.h:mesa-libgbm-devel"
        "/usr/include/EGL/egl.h:mesa-libEGL-devel"
        "/usr/include/va/va.h:libva"
    )

    for header_info in "${required_headers[@]}"; do
        local header="${header_info%%:*}"
        local pkg="${header_info##*:}"

        if [[ ! -f "$header" ]]; then
            missing+=("$header (package: $pkg)")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing critical dependencies:"
        printf '%s\n' "${missing[@]}" | sed 's/^/  - /'
        return 1
    fi

    log_success "All critical dependencies verified"
    return 0
}

# =============================================================================
# CLEANUP
# =============================================================================

cleanup_package_cache() {
    log_info "Cleaning up package cache..."

    # Clean DNF cache (but keep the metadata)
    dnf5 clean packages >/dev/null 2>&1

    # Remove temporary repo configs
    rm -f /etc/dnf/dnf.conf.d/99-build-optimization.conf

    log_success "Package cache cleaned"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    log_section "Installing Kodi Build Dependencies"

    # Initialize
    init_cache
    configure_dnf_performance

    # Install packages by group
    install_special_packages || die "Failed to install special packages"

    install_package_group "ESSENTIAL" true || die "Failed to install essential packages"
    install_package_group "CORE_DEPS" true || die "Failed to install core dependencies"
    install_package_group "GBM_DEPS" true || die "Failed to install GBM dependencies"
    install_package_group "GRAPHICS" true || die "Failed to install graphics libraries"

    # Build libva if needed
    build_libva_cached || die "Failed to build/install libva"

    # Install optional packages (don't fail on these)
    install_package_group "OPTIONAL" false

    # Verify everything is in place
    verify_critical_dependencies || die "Critical dependencies missing after installation"

    # Cleanup
    cleanup_package_cache

    log_success "All dependencies installed successfully"
}

# Execute
main "$@"
