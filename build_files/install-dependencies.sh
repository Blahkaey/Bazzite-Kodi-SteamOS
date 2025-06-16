#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"
PACKAGE_CONFIG="/ctx/package-lists.conf"

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
    log_success "Successfully installed java-11-openjdk-headless"
    log_success "Fedora 41 repository disabled"
}

build_libva() {
    log_info "Building libva (Video Acceleration API library)..."

    local build_dir="/tmp/libva-build"
    mkdir "$build_dir"

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
        -Dlibdir=/usr/lib64; then
        die "Meson configuration for libva failed"
    fi

    if ! ninja; then
        die "Failed to compile libva"
    fi

    if ! ninja install; then
        die "Failed to install libva"
    fi

    # Update the system library cache
    ldconfig

    # Clean up after ourselves
    cleanup_dir "$build_dir"
    log_success "libva built and installed successfully"
}


# Main execution
main() {
    log_subsection "Package Installation for Kodi HDR/GBM Build"

    # Check if package config exists
    if [ ! -f "$PACKAGE_CONFIG" ]; then
        die "Package configuration not found: $PACKAGE_CONFIG"
    fi

    dnf5 config-manager setopt "terra-mesa".enabled=1

    # Install java 11 headless using fedora 41 repo
    add_java11

    # Install packages by category
    install_packages "ESSENTIAL" true || die "Failed to install essential packages"
    install_packages "CORE_DEPS" true || die "Failed to install core dependencies"
    install_packages "GBM_DEPS" true || die "Failed to install GBM dependencies"
    install_packages "GRAPHICS" true || die "Failed to install graphics libraries"
    build_libva
    install_packages "OPTIONAL" false  # Optional, don't fail
    install_packages "SERVICE" true || die "Failed to install service packages"
}

# Call main with all arguments
main "$@"
