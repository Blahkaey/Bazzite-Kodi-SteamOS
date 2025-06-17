#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

install_switching_scripts() {
    log_info "Installing session switching scripts..."

        # Create a polkit rule for password-less switching
    cat > "/usr/share/polkit-1/rules.d/49-kodi-switching.rules" << 'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.systemd1.manage-units") &&
        (action.lookup("unit") == "kodi-gbm.service" ||
         action.lookup("unit") == "sddm.service") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
EOF

    # Install switch-to-kodi script
    cat > "/usr/bin/switch-to-kodi" << 'EOF'
#!/bin/bash
# Switch from Gaming Mode to Kodi

# Stop the current gaming session
if systemctl --user is-active gamescope-session-plus@steam.service >/dev/null 2>&1; then
    systemctl --user stop gamescope-session-plus@steam.service 2>/dev/null || true
fi

# Stop SDDM and start kodi-gbm service directly
systemctl stop sddm.service
# Wait for SDDM to fully stop
while systemctl is-active sddm.service >/dev/null 2>&1; do
    sleep 0.5
done
systemctl start kodi-gbm.service
EOF
    chmod +x "/usr/bin/switch-to-kodi"

    # Install switch-to-gamemode script
    cat > "/usr/bin/switch-to-gamemode" << 'EOF'
#!/bin/bash
# Switch from Kodi to Gaming Mode

USER=$(id -nu 1000)
HOME=$(getent passwd $USER | cut -d: -f6)

# SteamOS autologin SDDM config
AUTOLOGIN_CONF='/etc/sddm.conf.d/zz-steamos-autologin.conf'

# Configure autologin if Steam has been updated
if [[ -f $HOME/.local/share/Steam/ubuntu12_32/steamui.so ]]; then
  {
    echo "[Autologin]"
    echo "Session=gamescope-session.desktop"
  } > "$AUTOLOGIN_CONF"
fi

# Stop Kodi and start SDDM
systemctl stop kodi-gbm.service
systemctl start sddm.service

# This might be needed?
#sudo -Eu $USER qdbus org.kde.Shutdown /Shutdown org.kde.Shutdown.logout


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

    install_switching_scripts
    create_desktop_entry
    patch_kodi_standalone_for_gbm

    log_success "All services configured for Kodi/Bazzite switching"
}

main "$@"
