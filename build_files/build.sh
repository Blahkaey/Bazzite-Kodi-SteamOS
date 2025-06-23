#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

# Main build process
main() {
    log_section "Bazzite-Kodi-SteamOS Build Process"

    # Kodi is already installed from the base image
    log_success "Using pre-built Kodi from base image"

    # Verify Kodi installation
    if [[ -x "/usr/lib64/kodi/kodi-gbm" ]]; then
        log_success "Kodi binary verified at /usr/lib64/kodi/kodi-gbm"
    else
        log_error "Kodi binary not found! Base image may be corrupted."
        exit 1
    fi

    # Only install services now
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
