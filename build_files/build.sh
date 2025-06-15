#!/bin/bash
set -euo pipefail

SCRIPT_DIR="/ctx"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logging.sh"

# Main build process
main() {
    log_section "Kodi HDR Build Process"

    ls -l /usr
    ls -l /usr/local
    ls -l /usr/local/lib64

    # Execute build stages with bash explicitly
    run_stage "Installing dependencies" "/bin/bash ${SCRIPT_DIR}/install/dependencies.sh"
    run_stage "Building Kodi from source" "/bin/bash ${SCRIPT_DIR}/install/build-kodi.sh"
    run_stage "Setting up services" "/bin/bash ${SCRIPT_DIR}/config/setup-services.sh"


    log_section "Build Complete"
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
