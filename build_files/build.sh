#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

install_kodi_dependencies() {
    log_subsection "Installing Kodi runtime dependencies"

    if [[ ! -f "/tmp/runtime-deps.txt" ]]; then
        log_error "Runtime dependencies file not found!"
        exit 1
    fi

    log_info "Checking which dependencies are already installed..."
    missing_deps=""

    while IFS= read -r pkg; do
        if [[ -n "$pkg" ]]; then
            if ! rpm -q "$pkg" &>/dev/null; then
                missing_deps="$missing_deps $pkg"
            else
                log_success "$pkg already installed"
            fi
        fi
    done < /tmp/runtime-deps.txt

    if [[ -n "$missing_deps" ]]; then
        log_info "Installing missing dependencies:$missing_deps"
        if ! dnf -y install $missing_deps; then
            log_warning "Failed to install some dependencies, attempting individually..."
            for pkg in $missing_deps; do
                dnf -y install "$pkg" || log_warning "Could not install $pkg"
            done
        fi
    else
        log_success "All dependencies already installed!"
    fi

    # Clean up
    rm -f /tmp/runtime-deps.txt
    ldconfig
    dnf clean all
}

# Main build process
main() {
    log_section "Bazzite-Kodi-SteamOS Build Process"

    # Install Kodi dependencies first
    install_kodi_dependencies

    # Install services
    run_stage "Setting up services" "/bin/bash /ctx/install-services.sh"

    log_success "Bazzite-Kodi-SteamOS build completed successfully!"
}

run_stage() {
    local stage_name="$1"
    local script_command="$2"

    log_subsection "$stage_name"

    if ! eval "$script_command"; then
        log_error "Stage failed: $stage_name"
        exit 1
    fi

    log_success "$stage_name completed"
}

# Run main function
main "$@"
