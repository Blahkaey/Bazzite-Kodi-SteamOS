#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

# Constants
readonly PACKAGE_CONFIG="/ctx/package-lists.conf"
readonly TEMP_DIR="/tmp/kodi-deps-$$"
readonly FEDORA_41_REPO="fedora-41"
readonly TERRA_MESA_REPO="terra-mesa"
readonly FEDORA_41_REPO_FILE="/etc/yum.repos.d/fedora-41.repo"
readonly FEDORA_41_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Everything/x86_64/os/"

# Simple error handler
handle_error() {
    local exit_code=$?
    log_error "Build failed with exit code: $exit_code"
    exit $exit_code
}

# Set up error trap
trap handle_error ERR

# Create Fedora 41 repository
create_fedora41_repo() {
    log_info "Creating Fedora 41 repository configuration..."

    cat > "$FEDORA_41_REPO_FILE" << EOF
[${FEDORA_41_REPO}]
name=Fedora 41 - x86_64
baseurl=${FEDORA_41_URL}
enabled=1
gpgcheck=0
priority=10
EOF

    log_success "Repository $FEDORA_41_REPO added"
}

# Package installation functions
refresh_dnf_metadata() {
    log_info "Refreshing DNF metadata..."
    dnf5 makecache --refresh || log_warning "Failed to refresh DNF cache"
}

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

    # Batch install first (faster)
    if dnf5 install -y ${pkg_array[@]} >/dev/null 2>&1; then
        log_success "Batch installed $category packages"
        return 0
    fi

    # If batch fails, try one by one for better error reporting
    log_info "Batch install failed, trying individual packages..."

    for pkg in "${pkg_array[@]}"; do
        if dnf5 install -y "$pkg" >/dev/null 2>&1; then
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

install_gbm_packages() {
    log_info "Installing GBM packages with special handling..."

    # Enable terra-mesa for mesa devel packages (already exists in Bazzite)
    log_info "Enabling terra-mesa repository..."
    dnf5 config-manager setopt "${TERRA_MESA_REPO}.enabled=1"

    # Try to install mesa devel packages from terra-mesa
    local mesa_packages=("mesa-libgbm-devel" "mesa-libEGL-devel")
    local mesa_installed=0

    for pkg in "${mesa_packages[@]}"; do
        if dnf5 install -y "$pkg" --repo "$TERRA_MESA_REPO" >/dev/null 2>&1; then
            log_success "Installed $pkg from $TERRA_MESA_REPO"
            ((mesa_installed++))
        else
            log_warning "Could not install $pkg - will check if headers exist elsewhere"
        fi
    done

    # Disable terra-mesa after use to keep final image clean
    log_info "Disabling terra-mesa repository..."
    dnf5 config-manager setopt "${TERRA_MESA_REPO}.enabled=0"

    # Install remaining GBM packages
    install_packages "GBM_DEPS" true
}

install_java11() {
    log_info "Installing Java 11 from Fedora 41 repository..."

    # Add Fedora 41 repo
    create_fedora41_repo

    # Install java-11-openjdk-headless
    if ! dnf5 install -y java-11-openjdk-headless --repo "$FEDORA_41_REPO" >/dev/null 2>&1; then
        log_error "Failed to install java-11-openjdk-headless"
        return 1
    fi

    log_success "Successfully installed java-11-openjdk-headless"

    # Disable and remove the repo to keep final image clean
    log_info "Cleaning up Fedora 41 repository..."
    dnf5 config-manager setopt "${FEDORA_41_REPO}.enabled=0"
    rm -f "$FEDORA_41_REPO_FILE"

    return 0
}

build_libva() {
    log_info "Building libva (Video Acceleration API library)..."

    local build_dir="${TEMP_DIR}/libva-build"
    mkdir -p "$build_dir"

    # Clone the repo
    if ! git clone --depth 1 https://github.com/intel/libva.git "$build_dir"; then
        die "Failed to clone libva repository"
    fi

    # Enter build dir
    cd "$build_dir" || die "Cannot cd into $build_dir"

    # Meson-based out‑of‑source build
    mkdir -p build
    cd build

    if ! meson setup .. \
        -Dprefix=/usr \
        -Dlibdir=/usr/lib64 >/dev/null; then
        die "Meson configuration for libva failed"
    fi

    if ! ninja >/dev/null 2>&1; then
        die "Failed to compile libva"
    fi

    if ! ninja install >/dev/null 2>&1; then
        die "Failed to install libva"
    fi

    # Update the system library cache
    ldconfig

    log_success "libva built and installed successfully"

    # Return to original directory
    cd - >/dev/null
}

# Main execution
main() {
    log_subsection "Package Installation for Kodi HDR/GBM Build"

    # Create temp directory
    mkdir -p "$TEMP_DIR"

    # Refresh metadata once at the start
    refresh_dnf_metadata

    # Install java 11 headless using fedora 41 repo
    install_java11 || die "Failed to install Java 11"

    # Install packages by category
    install_packages "ESSENTIAL" true || die "Failed to install essential packages"
    install_packages "CORE_DEPS" true || die "Failed to install core dependencies"
    install_gbm_packages || die "Failed to install GBM dependencies"
    install_packages "GRAPHICS" true || die "Failed to install graphics libraries"

    # Build libva
    build_libva

    # Install optional packages (don't fail on these)
    install_packages "OPTIONAL" false

    log_success "All dependencies installed successfully"
}

# Call main with all arguments
main "$@"
