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

  # Step 1
    cat > "/usr/bin/switch-to-kodi" << 'EOF'
#!/bin/bash
# Switch from Gaming Mode to Kodi
exec systemctl start switch-to-kodi.service
EOF
    chmod +x "/usr/bin/switch-to-kodi"

    # Step 2
    cat > "/usr/lib/systemd/system/switch-to-kodi.service" << 'EOF'
[Unit]
Description=Switch from Gaming Mode to Kodi
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

    # Step 3
    cat > "/usr/bin/switch-to-kodi-root" << 'EOF'
#!/bin/bash
set -euo pipefail

echo "Switching to Kodi HDR mode..."


systemctl stop sddm.service


systemctl start kodi-gbm.service

echo "Successfully switched to Kodi HDR"
EOF
    chmod +x "/usr/bin/switch-to-kodi-root"

    log_success "Installed switch to kodi scripts..."
}


install_switch_to_gamemode_scripts() {
    log_info "Installing switch to gamemode scripts..."

    # Step 1
    cat > "/usr/bin/switch-to-gamemode" << 'EOF'
#!/bin/bash
# Switch from Kodi to Gaming Mode
    systemctl start switch-to-gamemode.service
fi
EOF
chmod +x "/usr/bin/switch-to-gamemode"

    # Step 2
    cat > "/usr/lib/systemd/system/switch-to-gamemode.service" << 'EOF'
[Unit]
Description=Switch from Kodi to Gaming Mode
After=multi-user.target
Conflicts=kodi-gdm.service

[Service]
Type=oneshot
RemainAfterExit=no
User=root
Group=root
ExecStart=/usr/bin/switch-to-gamemode-root
StandardOutput=journal
StandardError=journal
EOF

    # Step 3
    cat > "/usr/bin/switch-to-gamemode-root" << 'EOF'
#!/bin/bash
set -euo pipefail

echo "Switching to Gaming Mode..."

IMAGE_INFO="/usr/share/ublue-os/image-info.json"
BASE_IMAGE_NAME=$(jq -r '."base-image-name"' < $IMAGE_INFO)

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

systemctl stop kodi-gbm.service
sleep 0.5
gamescope-session-plus steam
sleep 0.5

#if [[ $BASE_IMAGE_NAME = "kinoite" ]]; then
#  sudo -Eu $USER qdbus org.kde.Shutdown /Shutdown org.kde.Shutdown.logout
#elif [[ $BASE_IMAGE_NAME = "silverblue" ]]; then
#  sudo -Eu $USER gnome-session-quit --logout --no-prompt
#fi


echo "Switch initiated - services are transitioning..."
EOF
chmod +x "/usr/bin/switch-to-gamemode-root"


log_success "Installed switch to gamemode scripts..."
}

create_desktop_entry() {
    log_info "Creating desktop entry..."

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

install_kodi_gbm_service() {
    log_info "Installing kodi_gbm_service..."

    # Ensures that /dev/dma_heap/linux* and /dev/dma_heap/system devices are made accessible
    cat > "/usr/lib/udev/rules.d/99-kodi.rules" << 'EOF'
SUBSYSTEM=="dma_heap", KERNEL=="linux*", GROUP="video", MODE="0660"
SUBSYSTEM=="dma_heap", KERNEL=="system", GROUP="video", MODE="0660"
EOF

    cat > "/usr/lib/tmpfiles.d/kodi-standalone.conf" << 'EOF'
d /var/lib/kodi 0750 kodi kodi - -
Z /var/lib/kodi - kodi kodi - -
EOF

    cat > "/usr/lib/sysusers.d/kodi-standalone.conf" << 'EOF'
g kodi - -
u! kodi - "Kodi User" /var/lib/kodi
EOF

    # Run systemd-sysusers to create the kodi user
    systemd-sysusers

    # Ensure kodi account never expires
    chage -E -1 kodi
    chage -M -1 kodi
    log_success "Removed expiration from kodi user"


    # Make kodi-gbm.service
    cat > "/usr/lib/systemd/system/kodi-gbm.service" << 'EOF'
[Unit]
Description=Kodi standalone (GBM)
After=remote-fs.target systemd-user-sessions.service network-online.target nss-lookup.target sound.target bluetooth.target polkit.service upower.service
Wants=network-online.target polkit.service upower.service
Conflicts=getty@tty1.service sddm.service

[Service]
User=kodi
Group=kodi
SupplementaryGroups=audio video render input optical
PAMName=login
TTYPath=/dev/tty1
ExecStartPre=/usr/bin/chvt 1
ExecStart=/usr/bin/kodi-standalone
ExecStop=/usr/bin/killall --exact --wait kodi-gbm kodi.bin
EnvironmentFile=-/etc/conf.d/kodi-standalone
Restart=on-abort
StandardInput=tty
StandardOutput=journal
StandardError=journal

[Install]
Alias=display-manager.service
EOF

    # Disable the service (manual start via switching scripts)
    systemctl disable kodi-gbm.service 2>/dev/null || true

    log_success "Kodi_gbm_service installed"
}



# Main execution
main() {
    log_subsection "Service Configuration"

    create_polkit_rule
    install_switch_to_kodi_scripts
    install_switch_to_gamemode_scripts
    create_desktop_entry
    patch_kodi_standalone_for_gbm
    install_kodi_gbm_service


    log_success "All services configured for Kodi/Bazzite switching"
}

main "$@"
