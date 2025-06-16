#!/bin/bash
set -euo pipefail

SCRIPT_DIR="/ctx"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logging.sh"

install_switching_scripts() {
    log_info "Installing session switching scripts..."

    # Create the switching scripts directory
    ensure_dir "/usr/bin"

    # Install switch-to-kodi script
    cat > "/usr/bin/switch-to-kodi" << 'EOF'
#!/bin/bash
# Switch from Gaming Mode to Kodi

# Stop the current gaming session
systemctl --user stop gamescope-session-plus@steam.service 2>/dev/null || true

# Configure SDDM for Kodi session
cat > /etc/sddm.conf.d/zz-steamos-autologin.conf << AUTOEOF
[Autologin]
Session=kodi-gbm
User=kodi
AUTOEOF

# If in a graphical session, logout properly
if [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    # Try to use the desktop-specific logout command
    if command -v qdbus >/dev/null 2>&1; then
        # KDE/Plasma logout
        sudo -u $(id -nu 1000) qdbus org.kde.Shutdown /Shutdown org.kde.Shutdown.logout
    elif command -v gnome-session-quit >/dev/null 2>&1; then
        # GNOME logout
        sudo -u $(id -nu 1000) gnome-session-quit --logout --no-prompt
    else
        # Generic logout - restart display manager
        systemctl restart sddm.service
    fi
else
    # If not in graphical session, just restart the display manager
    systemctl restart sddm.service
fi
EOF
    chmod +x "/usr/bin/switch-to-kodi"

    # Install switch-to-gamemode script
    cat > "/usr/bin/switch-to-gamemode" << 'EOF'
#!/bin/bash
# Switch from Kodi to Gaming Mode

# Get the primary user (UID 1000)
PRIMARY_USER=$(id -nu 1000)
HOME_DIR=$(getent passwd $PRIMARY_USER | cut -d: -f6)

# Configure SDDM for gaming session
cat > /etc/sddm.conf.d/zz-steamos-autologin.conf << AUTOEOF
[Autologin]
Session=gamescope-session.desktop
User=$PRIMARY_USER
AUTOEOF

# Stop Kodi if it's running
systemctl stop kodi-gbm.service 2>/dev/null || true
killall -TERM kodi.bin 2>/dev/null || true

# Restart display manager to switch sessions
systemctl restart sddm.service
EOF
    chmod +x "/usr/bin/switch-to-gamemode"

    log_success "Switching scripts installed"
}

setup_systemd_services() {
    log_info "Configuring systemd services..."

    # Create service override for kodi-gbm
    local override_dir="/etc/systemd/system/kodi-gbm.service.d"
    ensure_dir "$override_dir"

    # Create comprehensive conflicts and session management
    cat > "${override_dir}/bazzite-integration.conf" << 'EOF'
[Unit]
# Conflict with Bazzite's gaming session components
Conflicts=sddm.service gamescope-session.target
After=graphical.target network-online.target

[Service]
# Ensure proper GPU access for HDR
SupplementaryGroups=render video input
Environment="KODI_PLATFORM=gbm"
Environment="KODI_GL_INTERFACE=gles"

# Session management
PAMName=login
Type=simple
Restart=on-failure
RestartSec=5

# Resource limits
LimitNOFILE=524288

[Install]
# Make this an alternative display manager
Alias=display-manager.service
EOF

    # Create SDDM session file for Kodi
    ensure_dir "/usr/share/xsessions"
    cat > "/usr/share/xsessions/kodi-gbm.desktop" << 'EOF'
[Desktop Entry]
Name=Kodi (GBM/HDR)
Comment=Kodi Media Center with HDR support
Exec=/usr/bin/kodi-standalone
TryExec=/usr/bin/kodi-standalone
Type=Application
DesktopNames=KODI
Keywords=AudioVideo;Video;Player;TV;
EOF

    # Create return-to-gamemode service for Kodi
    cat > "/etc/systemd/system/return-to-gamemode-from-kodi.service" << 'EOF'
[Unit]
Description=Return to Gaming Mode from Kodi

[Service]
Type=oneshot
ExecStart=/usr/bin/switch-to-gamemode
EOF

    # Enable polkit for Kodi session management
    systemctl enable polkit.service

    log_success "Systemd services configured"
}

create_desktop_entries() {
    log_info "Creating desktop entries..."

    ensure_dir "/usr/share/applications"

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

    # Desktop entry to return to gaming mode (visible in desktop mode if accessed)
    cat > "/usr/share/applications/return-to-gamemode.desktop" << 'EOF'
[Desktop Entry]
Name=Return to Gaming Mode
Comment=Return to Steam Gaming Mode
Exec=/usr/bin/switch-to-gamemode
Icon=steamdeck-gaming-return
Type=Application
Categories=System;
Terminal=false
StartupNotify=false
EOF

    log_success "Desktop entries created"
}

configure_kodi_power_menu() {
    log_info "Configuring Kodi power menu integration..."

    # Create a systemd drop-in for Kodi to add the switch option
    ensure_dir "/etc/systemd/system/kodi-gbm.service.d"

    # Add environment variable for custom shutdown action
    cat >> "/etc/systemd/system/kodi-gbm.service.d/bazzite-integration.conf" << 'EOF'

# Custom power options
Environment="KODI_SHUTDOWN_ACTION=/usr/bin/switch-to-gamemode"
EOF

    # Create Kodi addon directory structure for power menu customization
    local kodi_addon_dir="/var/lib/kodi/.kodi/addons/script.bazzite.power"
    ensure_dir "$kodi_addon_dir"

    # Create addon.xml for the power menu addon
    cat > "$kodi_addon_dir/addon.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<addon id="script.bazzite.power" name="Bazzite Power Options" version="1.0.0" provider-name="Bazzite">
    <requires>
        <import addon="xbmc.python" version="3.0.0"/>
    </requires>
    <extension point="xbmc.python.script" library="default.py">
        <provides>executable</provides>
    </extension>
    <extension point="xbmc.addon.metadata">
        <platform>linux</platform>
        <summary>Power options for Bazzite</summary>
        <description>Adds option to return to Gaming Mode</description>
    </extension>
</addon>
EOF

    # Create the Python script for the addon
    cat > "$kodi_addon_dir/default.py" << 'EOF'
import xbmc
import os

# Execute the switch to gamemode script
os.system('/usr/bin/switch-to-gamemode')
EOF

    # Set proper ownership
    chown -R kodi:kodi "/var/lib/kodi/.kodi" 2>/dev/null || true

    log_success "Kodi power menu configured"
}

create_first_boot_setup() {
    log_info "Creating first-boot setup..."

    # Create first-boot setup script
    cat > "/usr/bin/setup-kodi-bazzite-sessions" << 'EOF'
#!/bin/bash
# First boot setup for Kodi/Bazzite dual sessions

# Check if this is first boot
if [ -f /var/lib/kodi-bazzite-configured ]; then
    exit 0
fi

# Get primary user
PRIMARY_USER=$(id -nu 1000 2>/dev/null || echo "deck")

# Create default SDDM autologin config (default to gaming mode)
cat > /etc/sddm.conf.d/zz-steamos-autologin.conf << AUTOEOF
[Autologin]
Session=gamescope-session.desktop
User=$PRIMARY_USER
AUTOEOF

# Ensure Kodi directories exist
mkdir -p /var/lib/kodi/.kodi/{userdata,addons}
chown -R kodi:kodi /var/lib/kodi

# Mark as configured
touch /var/lib/kodi-bazzite-configured

echo "Kodi/Bazzite session switching configured successfully"
EOF
    chmod +x "/usr/bin/setup-kodi-bazzite-sessions"

    # Create first-boot service
    cat > "/etc/systemd/system/kodi-bazzite-firstboot.service" << 'EOF'
[Unit]
Description=Kodi + Bazzite Session Setup
After=graphical.target
ConditionPathExists=!/var/lib/kodi-bazzite-configured

[Service]
Type=oneshot
ExecStart=/usr/bin/setup-kodi-bazzite-sessions
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable kodi-bazzite-firstboot.service

    log_success "First-boot setup created"
}

# Main execution
main() {
    log_subsection "Service Configuration"

    install_switching_scripts
    setup_systemd_services
    create_desktop_entries
    configure_kodi_power_menu
    create_first_boot_setup

    log_success "All services configured for Kodi/Bazzite switching"
}

# main "$@"
