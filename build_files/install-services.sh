#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

install_switching_scripts() {
    log_info "Installing session switching scripts and services..."

    # Create polkit rule for password-less switching
    cat > "/usr/share/polkit-1/rules.d/49-kodi-switching.rules" << 'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.systemd1.manage-units") &&
        (action.lookup("unit") == "kodi-gbm.service" ||
         action.lookup("unit") == "switch-to-kodi.service" ||
         action.lookup("unit") == "switch-to-gamemode.service" ||
         action.lookup("unit") == "sddm.service") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
EOF

    # Create the switch-to-kodi SERVICE (runs as root)
    cat > "/usr/lib/systemd/system/switch-to-kodi.service" << 'EOF'
[Unit]
Description=Switch from Gaming Mode to Kodi HDR
After=multi-user.target
Conflicts=sddm.service

[Service]
Type=oneshot
RemainAfterExit=no
User=root
Group=root
ExecStart=/usr/bin/switch-to-kodi-root
StandardOutput=journal
StandardError=journal
EOF

    # Create the root-level kodi switching script
    cat > "/usr/bin/switch-to-kodi-root" << 'EOF'
#!/bin/bash
set -euo pipefail

echo "Switching to Kodi HDR mode..."

# Stop the current gaming session
if systemctl --user is-active gamescope-session-plus@steam.service >/dev/null 2>&1; then
    systemctl --user stop gamescope-session-plus@steam.service 2>/dev/null || true
fi

# Kill any remaining Steam/Gamescope processes
pkill -f gamescope || true
pkill -f steam || true
sleep 1

# Stop SDDM and start kodi-gbm service
systemctl stop sddm.service

# Wait for SDDM to fully stop
timeout 10 bash -c 'while systemctl is-active sddm.service >/dev/null 2>&1; do sleep 0.5; done'

# Start Kodi
systemctl start kodi-gbm.service

echo "Successfully switched to Kodi HDR"
EOF
    chmod +x "/usr/bin/switch-to-kodi-root"

    # Create user-facing wrapper script
    cat > "/usr/bin/switch-to-kodi" << 'EOF'
#!/bin/bash
# Switch from Gaming Mode to Kodi
exec systemctl start switch-to-kodi.service
EOF
    chmod +x "/usr/bin/switch-to-kodi"

    # Create the switch-to-gamemode SERVICE (runs as root)
    cat > "/usr/lib/systemd/system/switch-to-gamemode.service" << 'EOF'
[Unit]
Description=Switch from Kodi to Gaming Mode
After=multi-user.target
Conflicts=kodi-gbm.service

[Service]
Type=oneshot
RemainAfterExit=no
User=root
Group=root
ExecStart=/usr/bin/switch-to-gamemode-root
StandardOutput=journal
StandardError=journal
EOF

    # Create the root-level gamemode switching script
    cat > "/usr/bin/switch-to-gamemode-root" << 'EOF'
#!/bin/bash
set -euo pipefail

echo "Switching to Gaming Mode..."

# Get desktop user info
DESKTOP_USER=$(id -nu 1000)
DESKTOP_HOME=$(getent passwd $DESKTOP_USER | cut -d: -f6)

# SteamOS autologin SDDM config
AUTOLOGIN_CONF='/etc/sddm.conf.d/zz-steamos-autologin.conf'

# Configure autologin if Steam has been updated
if [[ -f "$DESKTOP_HOME/.local/share/Steam/ubuntu12_32/steamui.so" ]]; then
    cat > "$AUTOLOGIN_CONF" << CONFIG
[Autologin]
User=$DESKTOP_USER
Session=gamescope-session.desktop
CONFIG
    echo "Updated SDDM autologin configuration"
else
    echo "Warning: Steam not found, skipping autologin configuration"
fi

# Stop Kodi and start SDDM
systemctl stop kodi-gbm.service

# Wait for Kodi to fully stop
timeout 10 bash -c 'while systemctl is-active kodi-gbm.service >/dev/null 2>&1; do sleep 0.5; done'

# Start Gaming Mode
systemctl start sddm.service

echo "Successfully switched to Gaming Mode"
EOF
    chmod +x "/usr/bin/switch-to-gamemode-root"

    # Create user-facing wrapper script
    cat > "/usr/bin/switch-to-gamemode" << 'EOF'
#!/bin/bash
# Switch from Kodi to Gaming Mode
exec systemctl start switch-to-gamemode.service
EOF
    chmod +x "/usr/bin/switch-to-gamemode"

    # Don't enable these services - they're started on-demand
    log_success "Switching scripts and services installed"
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

    # Also create a desktop entry for switching back (visible in desktop mode)
    cat > "/usr/share/applications/switch-to-gamemode.desktop" << 'EOF'
[Desktop Entry]
Name=Switch to Gaming Mode
Comment=Return to Steam Gaming Mode
Exec=/usr/bin/switch-to-gamemode
Icon=steam
Type=Application
Categories=Game;System;
Terminal=false
StartupNotify=false
NoDisplay=true
EOF

    chmod 644 "/usr/share/applications/switch-to-gamemode.desktop"

    log_success "Desktop entries created"
}

patch_kodi_standalone_for_gbm() {
    log_info "Patching kodi-standalone for GBM support..."

    # Only patch if the file exists
    if [ -f "/usr/bin/kodi-standalone" ]; then
        # Backup original
        cp /usr/bin/kodi-standalone /usr/bin/kodi-standalone.orig
        log_info "Backed up original kodi-standalone"
    fi

    # Create new version that supports GBM
    cat > "/usr/bin/kodi-standalone" << 'EOF'
#!/bin/sh
prefix="/usr"
exec_prefix="/usr"
bindir="/usr/bin"
libdir="/usr/lib64"

APP="${libdir}/kodi/kodi-gbm $@"

PULSE_START="$(command -v start-pulseaudio-x11)"
if [ -n "$PULSE_START" ]; then
  $PULSE_START
fi

LOOP=1
CRASHCOUNT=0
LASTSUCCESSFULSTART=$(date +%s)

while [ $LOOP -eq 1 ]
do
  $APP
  RET=$?
  NOW=$(date +%s)
  if [ $RET -ge 64 ] && [ $RET -le 66 ] || [ $RET -eq 0 ]; then # clean exit
    LOOP=0
  else # crash
    DIFF=$((NOW-LASTSUCCESSFULSTART))
    if [ $DIFF -gt 60 ]; then # Not on startup, ignore
      LASTSUCESSFULSTART=$NOW
      CRASHCOUNT=0
    else # at startup, look sharp
      CRASHCOUNT=$((CRASHCOUNT+1))
      if [ $CRASHCOUNT -ge 3 ]; then # Too many, bail out
        LOOP=0
        echo "${APP} has exited in an unclean state 3 times in the last ${DIFF} seconds."
        echo "Something is probably wrong"
      fi
    fi
  fi
done
EOF
    chmod +x /usr/bin/kodi-standalone
    log_success "kodi-standalone patched for GBM support"
}

create_kodi_utilities() {
    log_info "Creating Kodi utility scripts..."

    # Create a session status checker
    cat > "/usr/bin/kodi-session-status" << 'EOF'
#!/bin/bash
if systemctl is-active kodi-gbm.service >/dev/null 2>&1; then
    echo "Active: Kodi HDR Mode"
    exit 0
elif systemctl is-active sddm.service >/dev/null 2>&1; then
    echo "Active: Gaming/Desktop Mode"
    exit 1
else
    echo "Status: Unknown"
    exit 2
fi
EOF
    chmod +x "/usr/bin/kodi-session-status"

    # Create a log viewer helper
    cat > "/usr/bin/kodi-logs" << 'EOF'
#!/bin/bash
case "${1:-kodi}" in
    kodi)
        journalctl -u kodi-gbm.service -f
        ;;
    switch)
        journalctl -u switch-to-kodi.service -u switch-to-gamemode.service -f
        ;;
    all)
        journalctl -u kodi-gbm.service -u switch-to-kodi.service -u switch-to-gamemode.service -u sddm.service -f
        ;;
    *)
        echo "Usage: kodi-logs [kodi|switch|all]"
        exit 1
        ;;
esac
EOF
    chmod +x "/usr/bin/kodi-logs"

    log_success "Utility scripts created"
}

# Main execution
main() {
    log_subsection "Service Configuration"

    install_switching_scripts
    create_desktop_entry
    patch_kodi_standalone_for_gbm
    create_kodi_utilities

    log_success "All services configured for Kodi/Bazzite switching"
}

main "$@"
