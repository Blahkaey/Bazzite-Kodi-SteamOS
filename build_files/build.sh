#!/bin/bash
set -euo pipefail

SCRIPT_DIR="/ctx"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/system.sh"

# Main build process
main() {
    log_section "Kodi HDR Build Process"

    # Execute build stages with bash explicitly
    run_stage "Installing dependencies" "/bin/bash ${SCRIPT_DIR}/install/dependencies.sh"
    run_stage "Building Kodi from source" "/bin/bash ${SCRIPT_DIR}/install/build-kodi.sh"
    #run_stage "Setting up services" "/bin/bash ${SCRIPT_DIR}/config/setup-services.sh"
    #run_stage "Configuring sessions" "/bin/bash ${SCRIPT_DIR}/config/setup-sessions.sh"

    # Install runtime scripts
    #log_info "Installing runtime scripts..."
    #install_runtime_scripts

    log_section "Build Complete"
    log_success "Kodi HDR build completed successfully!"
    print_summary
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


install_runtime_scripts() {
    local runtime_dir="${SCRIPT_DIR}/runtime"

    for script in "$runtime_dir"/*; do
        [ -f "$script" ] || continue
        local script_name=$(basename "$script")
        log_info "Installing $script_name..."
        install -m 755 "$script" "/usr/bin/$script_name"
    done
}


# Run main function
main "$@"
