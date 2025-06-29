#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

setup_kodi_system_files() {
    log_subsection "Setting up Kodi system configuration"

    # Install udev rules
    cp /ctx/config/udev/99-kodi.rules /usr/lib/udev/rules.d/

    # Install tmpfiles configuration
    cp /ctx/config/tmpfiles/kodi-standalone.conf /usr/lib/tmpfiles.d/

    # Install sysusers configuration
    cp /ctx/config/sysusers/kodi-standalone.conf /usr/lib/sysusers.d/

    # Create kodi user and groups
    systemd-sysusers
    
    # Disable password expiry for kodi user
    chage -E -1 kodi
    chage -M -1 kodi

    log_success "Kodi system configuration completed"
}

install_kodi_gbm_service() {
    log_subsection "Installing kodi-gbm systemd service"

    # Install systemd service
    cp /ctx/config/systemd/kodi-gbm.service /usr/lib/systemd/system/

    # Don't enable by default
    systemctl disable kodi-gbm.service 2>/dev/null || true

    log_success "kodi-gbm service installed"
}

setup_kodi_system_files
install_kodi_gbm_service

log_success "Kodi service setup completed"