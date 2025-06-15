#!/bin/bash
set -euo pipefail

SCRIPT_DIR="/ctx"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logging.sh"

setup_systemd_services() {
    log_info "Configuring systemd services..."

    # Create service override for kodi-gbm
    local override_dir="/etc/systemd/system/kodi-gbm.service.d"
    ensure_dir "$override_dir"

    cat > "${override_dir}/conflicts.conf" << 'EOF'
[Unit]
Conflicts=sddm.service
After=graphical.target

[Service]
# Ensure proper GPU access for HDR
SupplementaryGroups=render video input
Environment="KODI_PLATFORM=gbm"
Environment="KODI_GL_INTERFACE=gles"
EOF

    # Create first-boot setup service
    cat > "/etc/systemd/system/hdr-kodi-firstboot.service" << 'EOF'
[Unit]
Description=HDR Kodi + Gaming Mode First Boot Setup
After=graphical.target
ConditionPathExists=!/var/lib/hdr-kodi-setup-complete

[Service]
Type=oneshot
ExecStart=/usr/bin/setup-hdr-kodi-sessions
ExecStartPost=/usr/bin/touch /var/lib/hdr-kodi-setup-complete
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
EOF

    # Enable services
    systemctl enable hdr-kodi-firstboot.service
    systemctl enable polkit.service

    log_success "Systemd services configured"
}

create_desktop_entries() {
    log_info "Creating desktop entries..."

    ensure_dir "/usr/share/applications"

    cat > "/usr/share/applications/switch-to-kodi.desktop" << 'EOF'
[Desktop Entry]
Name=Switch to Kodi HDR
Comment=Switch to Kodi with HDR support
Exec=/usr/bin/switch-to-kodi
Icon=kodi
Type=Application
Categories=AudioVideo;Video;Player;TV;
Terminal=false
StartupNotify=true
EOF

    log_success "Desktop entries created"
}

# Main execution
main() {
    log_subsection "Service Configuration"

    setup_systemd_services
    create_desktop_entries
}

main "$@"
