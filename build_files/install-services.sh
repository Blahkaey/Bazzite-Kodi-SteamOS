#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

install_switching_scripts() {
    log_info "Installing session switching scripts..."

    # Install switch-to-kodi script
    cat > "/usr/bin/switch-to-kodi" << 'EOF'
#!/bin/bash
# Switch from Gaming Mode to Kodi

# Stop the current gaming session
systemctl --user stop gamescope-session-plus@steam.service 2>/dev/null || true

# Stop SDDM and start kodi-gbm service directly
systemctl stop sddm.service
systemctl start kodi-gbm.service
EOF
    chmod +x "/usr/bin/switch-to-kodi"

    # Install switch-to-gamemode script
    cat > "/usr/bin/switch-to-gamemode" << 'EOF'
#!/bin/bash
# Switch from Kodi to Gaming Mode

# Stop Kodi and start SDDM
systemctl stop kodi-gbm.service
systemctl start sddm.service
EOF
    chmod +x "/usr/bin/switch-to-gamemode"

    log_success "Switching scripts installed"
}

create_desktop_entry() {
    log_info "Creating desktop entry..."

    # Desktop entry to switch to Kodi (visible in Gaming Mode)
    cat > "/usr/share/applications/switch-to-kodi.desktop" << 'EOF'
[Desktop Entry]
Name=Switch to Kodi HDR
Comment=Switch to Kodi Media Center with HDR support
Exec=/usr/bin/switch-to-kodi
Icon=kodi
Type=Application
Categories=AudioVideo;Video;Player;TV;System;
Terminal=false
StartupNotify=false
EOF

    # Make it executable for Steam
    chmod 644 "/usr/share/applications/switch-to-kodi.desktop"

    log_success "Desktop entry created"
}


# Main execution
main() {
    log_subsection "Service Configuration"

    install_switching_scripts
    create_desktop_entry

    log_success "All services configured for Kodi/Bazzite switching"
}

main "$@"
