#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

install_polkit_rules() {
    log_subsection "Installing polkit rules for service management"

    # Copy polkit rules
    cp /ctx/config/polkit/49-kodi-switching.rules /usr/share/polkit-1/rules.d/

    log_success "Polkit rules installed"
}

# Main execution
install_polkit_rules