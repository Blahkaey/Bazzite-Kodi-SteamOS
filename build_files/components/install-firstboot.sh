#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

install_firstboot_setup() {
    log_subsection "Installing first boot setup"

    # Install the script
    cp /ctx/components/system-scripts/first-boot-setup /usr/bin/
    chmod +x /usr/bin/first-boot-setup

    # Install systemd service
    cp /ctx/config/systemd/kodi-firstboot.service /usr/lib/systemd/system/

    # Enable the service
    systemctl enable kodi-firstboot.service

    log_success "First boot setup installed"
}

# Main execution
install_firstboot_setup