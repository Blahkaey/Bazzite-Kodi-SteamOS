#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

# DNF5 command with optimizations
readonly DNF5_CMD="dnf5 --setopt=fastestmirror=1 --setopt=max_parallel_downloads=10 --setopt=install_weak_deps=0 --nogpgcheck"

# Repository configurations
readonly FEDORA_41_REPO="fedora-41"
readonly FEDORA_41_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Everything/x86_64/os/"
readonly TERRA_MESA_REPO="terra-mesa"  # Pre-exists in Bazzite

# Package definitions
declare -A PACKAGE_GROUPS=(
    [ESSENTIAL]="git cmake gcc gcc-c++ make ninja-build autoconf automake libtool gettext gettext-devel pkgconf-pkg-config nasm yasm gperf swig python3-devel python3-pillow ccache"

    [CORE_DEPS]="alsa-lib-devel avahi-compat-libdns_sd-devel avahi-devel bzip2-devel curl dbus-devel fontconfig-devel freetype-devel fribidi-devel gawk giflib-devel gtest-devel libao-devel libass-devel libcap-devel libcdio-devel libcurl-devel libidn2-devel libjpeg-turbo-devel lcms2-devel libmicrohttpd-devel libmpc-devel libogg-devel libpng-devel libsmbclient-devel libtool-ltdl-devel libudev-devel libunistring libunistring-devel libusb1-devel libuuid-devel libvorbis-devel libxkbcommon-devel libxml2-devel libXmu-devel libXrandr-devel libxslt-devel libXt-devel lzo-devel mariadb-devel openssl-devel openssl-libs patch pcre-devel pcre2-devel pulseaudio-libs-devel sqlite-devel taglib-devel tinyxml-devel tinyxml2-devel trousers-devel uuid-devel zlib zlib-static zlib-devel systemd polkit rapidjson-devel hwdata hwdata-devel jre exiv2-devel json-devel meson ninja-build inotify-tools"

    [GBM_DEPS]="libinput-devel libxkbcommon-devel mesa-libGLES-devel libdrm-devel"

    [GRAPHICS]="mesa-libGLES mesa-libgbm mesa-va-drivers mesa-libEGL libdrm libdisplay-info libdisplay-info-devel drm-utils"

    [OPTIONAL]="libbluray-devel libcec-devel libnfs-devel libplist-devel shairplay-devel flatbuffers flatbuffers-devel fmt-devel fstrcmp-devel spdlog-devel lirc-devel"
)


# =============================================================================
# REPOSITORY MANAGEMENT
# =============================================================================

add_temp_repo() {
    local repo_name="$1"
    local repo_url="$2"

    log_info "Adding temporary repository: $repo_name"

    # Create a temporary repo file instead of using config-manager addrepo
    # This is more reliable for temporary repos in container builds
    cat > "/etc/yum.repos.d/${repo_name}.repo" << EOF
[${repo_name}]
name=Temporary ${repo_name}
baseurl=${repo_url}
enabled=1
gpgcheck=0
priority=10
EOF

    # Refresh just this repo's metadata
    $DNF5_CMD makecache --repo="${repo_name}" || log_warning "Failed to refresh ${repo_name} metadata"
}

remove_temp_repo() {
    local repo_name="$1"
    log_info "Removing temporary repository: $repo_name"

    # Remove the repo file
    rm -f "/etc/yum.repos.d/${repo_name}.repo"
}

enable_existing_repo() {
    local repo_name="$1"
    log_info "Enabling repository: $repo_name"

    # Use config-manager with correct syntax
    dnf5 config-manager setopt "${repo_name}.enabled=1" || {
        log_warning "Could not enable repo via config-manager, trying alternative method"
        # Alternative: modify the repo file directly
        local repo_files=("/etc/yum.repos.d/${repo_name}.repo" "/etc/yum.repos.d/"*".repo")
        for repo_file in "${repo_files[@]}"; do
            if [[ -f "$repo_file" ]] && grep -q "^\[${repo_name}\]" "$repo_file"; then
                sed -i "/^\[${repo_name}\]/,/^\[/ s/enabled=0/enabled=1/" "$repo_file"
                break
            fi
        done
    }
}

disable_existing_repo() {
    local repo_name="$1"
    log_info "Disabling repository: $repo_name"

    # Use config-manager with correct syntax
    dnf5 config-manager setopt "${repo_name}.enabled=0" || {
        log_warning "Could not disable repo via config-manager, trying alternative method"
        # Alternative: modify the repo file directly
        local repo_files=("/etc/yum.repos.d/${repo_name}.repo" "/etc/yum.repos.d/"*".repo")
        for repo_file in "${repo_files[@]}"; do
            if [[ -f "$repo_file" ]] && grep -q "^\[${repo_name}\]" "$repo_file"; then
                sed -i "/^\[${repo_name}\]/,/^\[/ s/enabled=1/enabled=0/" "$repo_file"
                break
            fi
        done
    }
}

# =============================================================================
# PACKAGE INSTALLATION
# =============================================================================

install_package_group() {
    local group_name="$1"
    local required="${2:-true}"

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
        if ! rpm -q "$pkg" &>/dev/null; then
            to_install+=("$pkg")
        fi
    done

    if [[ ${#to_install[@]} -eq 0 ]]; then
        log_success "All $group_name packages already installed"
        return 0
    fi

    log_info "Need to install ${#to_install[@]} packages for $group_name"

    # Try batch installation
    # Note: --setopt=strict=0 allows some packages to fail in a group
    if $DNF5_CMD install -y --setopt=strict=0 "${to_install[@]}" >/dev/null 2>&1; then
        log_success "Successfully installed $group_name packages"
        return 0
    fi

    # If batch failed and packages are required, check what's missing
    if [[ "$required" == "true" ]]; then
        log_error "Failed to install some $group_name packages"

        # Identify which packages are still missing
        local -a failed=()
        for pkg in "${to_install[@]}"; do
            if ! rpm -q "$pkg" &>/dev/null; then
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
    fi

    return 0
}

install_special_packages() {
    log_info "Installing special packages with repository handling..."

    # Install Java 11 from Fedora 41
    if ! rpm -q java-11-openjdk-headless &>/dev/null; then
        add_temp_repo "$FEDORA_41_REPO" "$FEDORA_41_URL"

        if $DNF5_CMD install -y java-11-openjdk-headless --repo "$FEDORA_41_REPO" >/dev/null 2>&1; then
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
        if ! rpm -q "$pkg" &>/dev/null; then
            if $DNF5_CMD install -y "$pkg" --repo "$TERRA_MESA_REPO" >/dev/null 2>&1; then
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


build_libva() {
    log_info "Building libva from source..."

    # Disable ccache for meson builds to avoid conflicts
    export CCACHE_DISABLE=1

    # Create temporary build directory
    local build_dir="/tmp/libva-build"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cd "$build_dir"

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

    # Cleanup
    cd /
    rm -rf "$build_dir"

    # Re-enable ccache
    unset CCACHE_DISABLE

    log_success "libva built and installed successfully"
    return 0
}


# =============================================================================
# CLEANUP
# =============================================================================

cleanup_package_cache() {
    log_info "Cleaning up package cache..."

    # Clean DNF cache (but keep the metadata)
    $DNF5_CMD clean packages || log_warning "Failed to clean package cache"

    log_success "Package cache cleaned"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    log_section "Installing Kodi Build Dependencies"

    $DNF5_CMD makecache --refresh || log_warning "Failed to refresh DNF cache"

    # Install packages by group
    install_special_packages || die "Failed to install special packages"

    install_package_group "ESSENTIAL" true || die "Failed to install essential packages"
    install_package_group "CORE_DEPS" true || die "Failed to install core dependencies"
    install_package_group "GBM_DEPS" true || die "Failed to install GBM dependencies"
    install_package_group "GRAPHICS" true || die "Failed to install graphics libraries"

    # Build libva if needed
    build_libva || die "Failed to build/install libva"

    # Install optional packages (don't fail on these)
    install_package_group "OPTIONAL" false

    # Cleanup
    cleanup_package_cache

    log_success "All dependencies installed successfully"
}

# Execute
main "$@"
