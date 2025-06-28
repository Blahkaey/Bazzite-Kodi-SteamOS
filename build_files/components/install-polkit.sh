#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

log_subsection "Installing polkit rules for service management"

cp /ctx/config/polkit/49-kodi-switching.rules /usr/share/polkit-1/rules.d/

log_success "Polkit rules installed"
