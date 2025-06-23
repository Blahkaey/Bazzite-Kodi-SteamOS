#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

# Main build process
main() {
    log_section "Kodi Build Process"

    # Execute build stages with bash explicitly
    run_stage "Installing dependencies" "/bin/bash /ctx/install-dependencies.sh"
    run_stage "Building Kodi from source" "/bin/bash /ctx/install-kodi.sh"
    run_stage "Setting up services" "/bin/bash /ctx/install-services.sh"


    log_success "Bazzite-Kodi-SteamOS build completed successfully!"
    log_section "Image build Complete"
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
