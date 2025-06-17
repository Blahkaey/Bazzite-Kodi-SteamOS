#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

create_polkit_rule() {
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
}

install_switch_to_kodi_scripts() {
    log_info "Installing switch to kodi scripts..."

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
sleep 0.5

# Stop SDDM and start kodi-gbm service
systemctl stop sddm.service

# Wait for SDDM to fully stop
timeout 10 bash -c 'while systemctl is-active sddm.service >/dev/null 2>&1; do sleep 0.5; done'

# Start Kodi
systemctl start kodi-gbm.service

echo "Successfully switched to Kodi HDR"
EOF
    chmod +x "/usr/bin/switch-to-kodi-root"


    cat > "/usr/bin/switch-to-kodi" << 'EOF'
#!/bin/bash
# Switch from Gaming Mode to Kodi
exec systemctl start switch-to-kodi.service
EOF
    chmod +x "/usr/bin/switch-to-kodi"

    log_success "Installed switch to kodi scripts..."
}

install_switch_to_gamemode_scripts() {
    log_info "Installing switch to gamemode scripts..."

cat > "/usr/bin/switch-to-gamemode-root" << 'EOF'
#!/bin/bash
set -euo pipefail

echo "Switching to Gaming Mode..."

# Get desktop user info
USER=$(id -nu 1000)
HOME=$(getent passwd $USER | cut -d: -f6)

# SteamOS autologin SDDM config
AUTOLOGIN_CONF='/etc/sddm.conf.d/zz-steamos-autologin.conf'

# Configure autologin if Steam has been updated
if [[ -f "$HOME/.local/share/Steam/ubuntu12_32/steamui.so" ]]; then
    cat > "$AUTOLOGIN_CONF" << CONFIG
[Autologin]
User=$USER
Session=gamescope-session.desktop
CONFIG
    echo "Updated SDDM autologin configuration"
else
    echo "Warning: Steam not found, skipping autologin configuration"
fi

# Use systemd to handle the service switch properly
# This tells systemd to stop kodi-gbm and start sddm, handling conflicts automatically
systemctl --no-block isolate graphical.target
systemctl --no-block stop kodi-gbm.service
systemctl --no-block start sddm.service

echo "Switch initiated - services are transitioning..."
EOF
chmod +x "/usr/bin/switch-to-gamemode-root"


cat > "/usr/lib/systemd/system/kodi-switch-handler.service" << 'EOF'
[Unit]
Description=Async handler for switching from Kodi
After=kodi-gbm.service

[Service]
Type=oneshot
ExecStart=/usr/bin/kodi-switch-handler
RemainAfterExit=no
EOF


cat > "/usr/bin/kodi-switch-handler" << 'EOF'
#!/bin/bash
# This script handles the switch asynchronously to avoid deadlock

# Wait a moment to let Kodi finish processing the command
sleep 1

# Now perform the actual switch
/usr/bin/switch-to-gamemode-root
EOF
chmod +x "/usr/bin/kodi-switch-handler"


cat > "/usr/bin/switch-to-gamemode" << 'EOF'
#!/bin/bash
# Switch from Kodi to Gaming Mode
    systemctl start --no-block kodi-switch-handler.service
fi
EOF
chmod +x "/usr/bin/switch-to-gamemode"

log_success "Installed switch to gamemode scripts..."
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



# Main execution
main() {
    log_subsection "Service Configuration"

    create_polkit_rule
    install_switch_to_kodi_scripts
    install_switch_to_gamemode_scripts
    create_desktop_entry
    patch_kodi_standalone_for_gbm


    log_success "All services configured for Kodi/Bazzite switching"
}

main "$@"
