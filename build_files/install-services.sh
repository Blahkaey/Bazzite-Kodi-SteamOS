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
systemctl --user stop gamescope-session-plus@steam.service 2>/dev/null || true

# Use a single systemctl call to avoid multiple password prompts
systemctl stop sddm.service --no-block && systemctl start kodi-gbm.service
EOF
    chmod +x "/usr/bin/switch-to-kodi"

    # Install switch-to-gamemode script
    cat > "/usr/bin/switch-to-gamemode" << 'EOF'
#!/bin/bash
# Switch from Kodi to Gaming Mode

# Stop Kodi and start SDDM
systemctl stop kodi-gbm.service --no-block && systemctl start sddm.service
EOF
    chmod +x "/usr/bin/switch-to-gamemode"

    log_success "Switching scripts installed"
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
# Modified for Bazzite GBM support

prefix="/usr"
exec_prefix="/usr"
bindir="/usr/bin"
libdir="/usr/lib64"

# Check if running on TTY (GBM mode) or under X11/Wayland
if [ "$XDG_SESSION_TYPE" = "tty" ] || [ -z "$DISPLAY" -a -z "$WAYLAND_DISPLAY" ]; then
    # GBM mode
    echo "Starting Kodi in GBM mode..."

    # Set GBM-specific environment
    export KODI_AE_SINK=PIPEWIRE  # Bazzite uses PipeWire
    export LIBVA_DRIVER_NAME=${LIBVA_DRIVER_NAME:-radeonsi}
    export GBM_BACKEND=dri

    # Use kodi-gbm binary
    APP="${libdir}/kodi/kodi-gbm $@"
else
    # X11/Wayland mode
    APP="${bindir}/kodi --standalone $@"
fi

# PipeWire check (Bazzite uses PipeWire, not PulseAudio)
if command -v pw-cli >/dev/null 2>&1; then
    # Ensure PipeWire is running
    systemctl --user is-active pipewire.service >/dev/null 2>&1 || systemctl --user start pipewire.service
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

setup_kodi_user_permissions() {
    log_info "Setting up kodi user permissions..."

    # Ensure kodi user has necessary permissions
    usermod -a -G video,audio,input,render kodi 2>/dev/null || true

    # Create kodi home directory if it doesn't exist
    mkdir -p /var/lib/kodi
    chown -R kodi:kodi /var/lib/kodi
    chmod 750 /var/lib/kodi

    # Set up DRM device permissions
    cat > "/etc/udev/rules.d/61-kodi-permissions.rules" << 'EOF'
# Allow kodi user to access DRM devices
SUBSYSTEM=="drm", KERNEL=="card[0-9]*", GROUP="video", MODE="0660"
SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", GROUP="render", MODE="0660"

# Allow kodi user to access input devices
SUBSYSTEM=="input", GROUP="input", MODE="0660"
EOF

    log_success "Kodi user permissions configured"
}

setup_selinux_contexts() {
    log_info "Setting up SELinux contexts for Kodi..."

    # Check if SELinux is enforcing
    if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
        # Set proper context for kodi home directory
        semanage fcontext -a -t user_home_dir_t "/var/lib/kodi(/.*)?" 2>/dev/null || true
        restorecon -R /var/lib/kodi 2>/dev/null || true

        # Allow kodi to access TTY
        setsebool -P login_console_enabled 1 2>/dev/null || true

        log_success "SELinux contexts configured"
    else
        log_info "SELinux is disabled, skipping context setup"
    fi
}

# Main execution
main() {
    log_subsection "Service Configuration"

    install_switching_scripts
    patch_kodi_standalone_for_gbm
    create_desktop_entry
    setup_kodi_user_permissions
    setup_selinux_contexts

    log_success "All services configured for Kodi/Bazzite switching"
}

main "$@"
