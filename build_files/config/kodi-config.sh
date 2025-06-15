#!/bin/bash
set -euo pipefail

SCRIPT_DIR="/ctx"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logging.sh"


# Load build features if available
BUILD_FEATURES=""
[ -f /tmp/kodi-build-features-final.tmp ] && BUILD_FEATURES=$(cat /tmp/kodi-build-features-final.tmp)

create_kodi_directories() {
    log_info "Creating Kodi directories..."

    local dirs=(
        "${KODI_HOME}/.kodi/userdata"
        "${KODI_HOME}/.kodi/userdata/keymaps"
        "${KODI_HOME}/.kodi/addons"
        "${KODI_HOME}/.kodi/media"
    )

    for dir in "${dirs[@]}"; do
        ensure_dir "$dir"
    done

    # Set ownership
    chown -R "$KODI_USER:$KODI_USER" "${KODI_HOME}/.kodi"
}

install_kodi_configs() {
    log_info "Installing Kodi configuration files..."

    # Advanced settings for HDR
    cp "${SCRIPT_DIR}/../assets/kodi-advancedsettings.xml" \
       "${KODI_HOME}/.kodi/userdata/advancedsettings.xml"

    # Keymap for session switching
    cp "${SCRIPT_DIR}/../assets/gaming-mode-keymap.xml" \
       "${KODI_HOME}/.kodi/userdata/keymaps/gaming-mode.xml"

    # Set ownership
    chown -R "$KODI_USER:$KODI_USER" "${KODI_HOME}/.kodi"

    log_success "Kodi configuration files installed"
}

create_hdr_profile() {
    log_info "Creating HDR display profile..."

    # Create a profile that enables HDR features
    cat > "${KODI_HOME}/.kodi/userdata/profiles.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<profiles>
    <lastloaded>0</lastloaded>
    <useloginscreen>false</useloginscreen>
    <autologin>true</autologin>
    <profile>
        <id>0</id>
        <name>HDR Profile</name>
        <directory>special://masterprofile/</directory>
        <thumbnail></thumbnail>
        <hasdatabases>true</hasdatabases>
        <canwritedatabases>true</canwritedatabases>
        <hassources>true</hassources>
        <canwritesources>true</canwritesources>
        <lockmode>0</lockmode>
    </profile>
</profiles>
EOF

    chown "$KODI_USER:$KODI_USER" "${KODI_HOME}/.kodi/userdata/profiles.xml"
}

# Main execution
main() {
    log_subsection "Kodi Configuration"

    create_kodi_directories
    install_kodi_configs
    create_hdr_profile

    # Report configuration based on build features
    log_info "Kodi HDR configuration summary:"
    log_info "  Platform: GBM (HDR capable)"
    log_info "  Render system: GLES (HDR passthrough)"

    if [[ "$BUILD_FEATURES" == *"vaapi"* ]]; then
        log_info "  Hardware acceleration: VA-API enabled"
    else
        log_info "  Hardware acceleration: Software decoding"
    fi
}

main "$@"
