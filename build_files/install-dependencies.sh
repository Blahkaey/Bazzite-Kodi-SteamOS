#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

# Constants
readonly PACKAGE_CONFIG="/ctx/package-lists.conf"
readonly TEMP_DIR="/tmp/kodi-deps-$$"
readonly FEDORA_41_REPO="fedora-41"
readonly TERRA_MESA_REPO="terra-mesa"
readonly FEDORA_41_REPO_FILE="${TEMP_DIR}/fedora-41.repo"

# Repository URLs and keys
readonly FEDORA_41_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Everything/x86_64/os/"
readonly FEDORA_GPG_KEY="https://getfedora.org/static/fedora.gpg"

# Track repositories we've added/modified
declare -a ADDED_REPOS=()
declare -a ENABLED_REPOS=()

# Ensure GPG directory exists
mkdir -p /root/.gnupg
chmod 700 /root/.gnupg

# Cleanup function
cleanup() {
    local exit_code=$?

    log_info "Running cleanup..."

    # Remove temp directory
    if [ -d "$TEMP_DIR" ]; then
        log_debug "Removing temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi

    # Disable any repos we enabled
    for repo in "${ENABLED_REPOS[@]}"; do
        log_debug "Disabling repository: $repo"
        dnf5 config-manager setopt "${repo}.enabled=0" 2>/dev/null || true
    done

    # Remove any repos we added
    for repo in "${ADDED_REPOS[@]}"; do
        log_debug "Removing repository: $repo"
        dnf5 config-manager --remove-repo "$repo" 2>/dev/null || true
    done

    # Remove any other temp files
    rm -f /tmp/libva-build 2>/dev/null || true

    log_info "Cleanup completed"
    exit $exit_code
}

# Set up cleanup trap
trap cleanup EXIT INT TERM

# Repository management functions
repo_exists() {
    local repo_name="$1"
    dnf5 repolist --repo "$repo_name" 2>/dev/null | grep -q "$repo_name"
}

repo_is_enabled() {
    local repo_name="$1"
    dnf5 repolist --enabled --repo "$repo_name" 2>/dev/null | grep -q "$repo_name"
}

enable_repo() {
    local repo_name="$1"

    if ! repo_exists "$repo_name"; then
        log_error "Repository $repo_name does not exist"
        return 1
    fi

    if repo_is_enabled "$repo_name"; then
        log_debug "Repository $repo_name already enabled"
        return 0
    fi

    log_info "Enabling repository: $repo_name"
    if dnf5 config-manager setopt "${repo_name}.enabled=1"; then
        ENABLED_REPOS+=("$repo_name")
        return 0
    else
        log_error "Failed to enable repository: $repo_name"
        return 1
    fi
}

disable_repo() {
    local repo_name="$1"

    if ! repo_exists "$repo_name"; then
        log_debug "Repository $repo_name does not exist, skipping disable"
        return 0
    fi

    log_info "Disabling repository: $repo_name"
    dnf5 config-manager setopt "${repo_name}.enabled=0" || true

    # Remove from enabled list if present
    ENABLED_REPOS=("${ENABLED_REPOS[@]/$repo_name/}")
}

add_repo() {
    local repo_name="$1"
    local repo_file="$2"

    if repo_exists "$repo_name"; then
        log_info "Repository $repo_name already exists"
        return 0
    fi

    log_info "Adding repository: $repo_name"
    if dnf5 config-manager addrepo --from-repofile="$repo_file"; then
        ADDED_REPOS+=("$repo_name")
        log_success "Repository $repo_name added"
        return 0
    else
        log_error "Failed to add repository: $repo_name"
        return 1
    fi
}

create_fedora41_repo() {
    log_info "Creating Fedora 41 repository configuration..."

    cat > "$FEDORA_41_REPO_FILE" << EOF
[${FEDORA_41_REPO}]
name=Fedora 41 - x86_64
baseurl=${FEDORA_41_URL}
enabled=1
gpgcheck=0
gpgkey=${FEDORA_GPG_KEY}
priority=10
EOF

    add_repo "$FEDORA_41_REPO" "$FEDORA_41_REPO_FILE"
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

install_gbm_packages() {
    log_info "Installing GBM packages with special handling..."

    # Enable terra-mesa for mesa devel packages
    enable_repo "$TERRA_MESA_REPO" || log_warning "Could not enable $TERRA_MESA_REPO"

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

    # Disable terra-mesa after use
    disable_repo "$TERRA_MESA_REPO"

    # Install remaining GBM packages
    install_packages "GBM_DEPS" true
}

install_java11() {
    log_info "Installing Java 11 from Fedora 41 repository..."

    # Add Fedora 41 repo
    create_fedora41_repo

    # Install java-11-openjdk-headless
    if ! dnf5 install -y java-11-openjdk-headless --repo "$FEDORA_41_REPO" ; then
        log_error "Failed to install java-11-openjdk-headless"
        dnf5 search java-11-openjdk-headless || true
        return 1
    fi

    log_success "Successfully installed java-11-openjdk-headless"

    # Disable the repo after use
    disable_repo "$FEDORA_41_REPO"

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

    log_success "libva built and installed successfully"

    # Return to original directory
    cd - >/dev/null
}


# Main execution
main() {
    log_subsection "Package Installation for Kodi HDR/GBM Build"

    # Create temp directory
    mkdir -p "$TEMP_DIR"

    # Check if package config exists
    if [ ! -f "$PACKAGE_CONFIG" ]; then
        die "Package configuration not found: $PACKAGE_CONFIG"
    fi

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
