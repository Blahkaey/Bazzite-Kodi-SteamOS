#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

# Create polkit policy for pkexec instead of rules
create_polkit_policy() {
    log_info "Creating polkit policy for session switching..."

    cat > "/usr/share/polkit-1/actions/org.bazzite.kodi-switching.policy" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
 "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <action id="org.bazzite.switch-to-kodi">
    <description>Switch to Kodi Media Center</description>
    <message>Authentication is required to switch to Kodi</message>
    <defaults>
      <allow_any>auth_admin</allow_any>
      <allow_inactive>auth_admin</allow_inactive>
      <allow_active>auth_admin_keep</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/bin/switch-to-kodi</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
  </action>

  <action id="org.bazzite.switch-to-gamemode">
    <description>Switch to Gaming Mode</description>
    <message>Authentication is required to switch to Gaming Mode</message>
    <defaults>
      <allow_any>auth_admin</allow_any>
      <allow_inactive>auth_admin</allow_inactive>
      <allow_active>auth_admin_keep</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/bin/switch-to-gamemode</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
  </action>
</policyconfig>
EOF

    log_success "Polkit policies created"
}

install_switch_to_kodi_scripts() {
    log_info "Installing enhanced switch to kodi scripts..."

    # Main user-facing script
    cat > "/usr/bin/switch-to-kodi" << 'EOF'
#!/usr/bin/bash
set -e

die() { echo >&2 "!! $*"; exit 1; }

# Configuration
IMAGE_INFO="/usr/share/ublue-os/image-info.json"
BASE_IMAGE_NAME=$(jq -r '."base-image-name"' < $IMAGE_INFO 2>/dev/null || echo "unknown")
GAMING_CONF_FILE="/etc/sddm.conf.d/zz-steamos-autologin.conf"
KODI_CONF_FILE="/etc/sddm.conf.d/zz-kodi-session.conf"
CHECK_FILE="/etc/sddm.conf.d/steamos.conf"

# Prevent root execution for initial call
if [[ -z $SENTINEL_CREATED ]] && [[ $EUID == 0 ]]; then
    die "Running $0 as root is not allowed"
fi

# Update user preference
if [[ -z $SENTINEL_CREATED ]]; then
    [[ -n ${HOME+x} ]] || die "No \$HOME variable"
    config_dir="${XDG_CONFIG_HOME:-"$HOME/.config"}"

    mkdir -p "$config_dir"
    echo "kodi-gbm" > "$config_dir/media-session-select"

    export SENTINEL_CREATED=1
    echo "Updated user session preference to Kodi"
fi

# Elevate to root if needed
if [[ $EUID != 0 ]]; then
    exec pkexec "$(realpath $0)" --sentinel-created
    exit 1
fi

echo "Switching to Kodi HDR mode..."

# Check if we're currently in a graphical session
if systemctl is-active --quiet graphical.target; then
    # Stop display manager gracefully
    if systemctl is-active --quiet sddm; then
        systemctl stop sddm
        sleep 2
    fi
fi

# Disable gaming session autologin
if [[ -f "$GAMING_CONF_FILE" ]]; then
    mv "$GAMING_CONF_FILE" "$GAMING_CONF_FILE.disabled" 2>/dev/null || true
fi

# Remove any Kodi autologin config (we want manual service start)
[[ -f "$KODI_CONF_FILE" ]] && rm -f "$KODI_CONF_FILE"

# Ensure kodi user exists and is configured
if ! id kodi &>/dev/null; then
    echo "Error: kodi user does not exist" >&2
    exit 1
fi

# Start Kodi GBM service
systemctl reset-failed kodi-gbm 2>/dev/null || true
if ! systemctl start kodi-gbm; then
    echo "Failed to start Kodi GBM service" >&2
    # Attempt to restore gaming mode
    [[ -f "$GAMING_CONF_FILE.disabled" ]] && mv "$GAMING_CONF_FILE.disabled" "$GAMING_CONF_FILE"
    systemctl start sddm
    exit 1
fi

echo "Successfully switched to Kodi HDR"
EOF
    chmod +x "/usr/bin/switch-to-kodi"

    log_success "Installed enhanced switch to kodi script"
}

install_switch_to_gamemode_scripts() {
    log_info "Installing enhanced switch to gamemode scripts..."

    cat > "/usr/bin/switch-to-gamemode" << 'EOF'
#!/usr/bin/bash
set -e

die() { echo >&2 "!! $*"; exit 1; }

# Configuration
IMAGE_INFO="/usr/share/ublue-os/image-info.json"
BASE_IMAGE_NAME=$(jq -r '."base-image-name"' < $IMAGE_INFO 2>/dev/null || echo "unknown")
GAMING_CONF_FILE="/etc/sddm.conf.d/zz-steamos-autologin.conf"
KODI_CONF_FILE="/etc/sddm.conf.d/zz-kodi-session.conf"
SENTINEL_FILE="media-session-select"

# Get the session type from argument or default
session="${1:-gamescope}"

# Prevent root execution for initial call
if [[ -z $SENTINEL_CREATED ]] && [[ $EUID == 0 ]]; then
    die "Running $0 as root is not allowed"
fi

# Update user preference
if [[ -z $SENTINEL_CREATED ]]; then
    [[ -n ${HOME+x} ]] || die "No \$HOME variable"
    config_dir="${XDG_CONFIG_HOME:-"$HOME/.config"}"

    mkdir -p "$config_dir"
    echo "$session" > "$config_dir/$SENTINEL_FILE"

    export SENTINEL_CREATED=1
    echo "Updated user session preference to $session"
fi

# Elevate to root if needed
if [[ $EUID != 0 ]]; then
    exec pkexec "$(realpath $0)" "$session" --sentinel-created
    exit 1
fi

echo "Switching to Gaming Mode ($session)..."

# Determine session launcher
case "$session" in
    plasma|desktop)
        if [[ "$BASE_IMAGE_NAME" == "kinoite" ]]; then
            session_launcher="plasma-steamos-wayland-oneshot.desktop"
        elif [[ "$BASE_IMAGE_NAME" == "silverblue" ]]; then
            session_launcher="gnome-wayland-oneshot.desktop"
        else
            # Fallback to standard desktop
            session_launcher="plasma.desktop"
        fi
        ;;
    gamescope)
        session_launcher="gamescope-session.desktop"
        ;;
    *)
        die "Unrecognized session '$session'"
        ;;
esac

# Stop Kodi if running
if systemctl is-active --quiet kodi-gbm; then
    echo "Stopping Kodi..."
    systemctl stop kodi-gbm
    sleep 2
fi

# Clean up Kodi session config
[[ -f "$KODI_CONF_FILE" ]] && rm -f "$KODI_CONF_FILE"

# Get the primary user (usually UID 1000)
PRIMARY_USER=$(id -nu 1000 2>/dev/null || echo "deck")
PRIMARY_HOME=$(getent passwd $PRIMARY_USER | cut -d: -f6)

# Check if Steam is installed and create/restore autologin config
if [[ -f "$PRIMARY_HOME/.local/share/Steam/ubuntu12_32/steamui.so" ]] || [[ -f "$GAMING_CONF_FILE.disabled" ]]; then
    if [[ -f "$GAMING_CONF_FILE.disabled" ]]; then
        # Restore saved config
        mv "$GAMING_CONF_FILE.disabled" "$GAMING_CONF_FILE"
    else
        # Create new autologin config
        {
            echo "[Autologin]"
            echo "Session=$session_launcher"
            echo "User=$PRIMARY_USER"
        } > "$GAMING_CONF_FILE"
    fi
    echo "Configured autologin for $PRIMARY_USER with $session_launcher"
fi

# Restart display manager
systemctl reset-failed sddm 2>/dev/null || true
systemctl restart sddm

echo "Successfully switched to Gaming Mode"
EOF
    chmod +x "/usr/bin/switch-to-gamemode"

    log_success "Installed enhanced switch to gamemode script"
}

create_desktop_entries() {
    log_info "Creating desktop entries..."

    # Kodi switch desktop entry
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
Keywords=media;center;tv;movies;shows;pvr;
EOF

    # Gaming mode switch desktop entries
    cat > "/usr/share/applications/switch-to-gamemode.desktop" << 'EOF'
[Desktop Entry]
Name=Return to Gaming Mode
Comment=Switch back to Gaming Mode (Big Picture)
Exec=/usr/bin/switch-to-gamemode gamescope
Icon=steam
Type=Application
Categories=Game;System;
Terminal=false
StartupNotify=false
Keywords=steam;gaming;bigpicture;gamemode;
EOF

    cat > "/usr/share/applications/switch-to-desktop.desktop" << 'EOF'
[Desktop Entry]
Name=Switch to Desktop
Comment=Switch to regular desktop session
Exec=/usr/bin/switch-to-gamemode desktop
Icon=desktop
Type=Application
Categories=System;
Terminal=false
StartupNotify=false
Keywords=desktop;plasma;gnome;kde;
EOF

    chmod 644 /usr/share/applications/switch-to-*.desktop

    log_success "Desktop entries created"
}

# Create a session check utility
create_session_utilities() {
    log_info "Creating session utility scripts..."

    # Session check script
    cat > "/usr/bin/media-session-check" << 'EOF'
#!/bin/bash
# Check current media session status

if systemctl is-active --quiet kodi-gbm; then
    echo "Active session: Kodi HDR (GBM)"
    echo "Status: Running"
elif systemctl is-active --quiet sddm; then
    echo "Active session: Gaming/Desktop Mode"
    echo "Display Manager: SDDM"
    if [[ -f /etc/sddm.conf.d/zz-steamos-autologin.conf ]]; then
        session=$(grep "Session=" /etc/sddm.conf.d/zz-steamos-autologin.conf | cut -d= -f2)
        echo "Autologin Session: $session"
    fi
else
    echo "No active media session detected"
fi

# Check user preference
if [[ -f "$HOME/.config/media-session-select" ]]; then
    pref=$(cat "$HOME/.config/media-session-select")
    echo "User Preference: $pref"
fi
EOF
    chmod +x "/usr/bin/media-session-check"

    log_success "Session utilities created"
}

# Keep the existing functions that don't need changes
patch_kodi_standalone_for_gbm() {
    log_info "Patching kodi-standalone for GBM support..."

    if [ -f "/usr/bin/kodi-standalone" ]; then
        cp /usr/bin/kodi-standalone /usr/bin/kodi-standalone.orig
        log_info "Backed up original kodi-standalone"
    fi

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
u kodi - "Kodi User" /var/lib/kodi
EOF

    systemd-sysusers
    chage -E -1 kodi
    chage -M -1 kodi

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

    systemctl disable kodi-gbm.service 2>/dev/null || true

    log_success "Kodi_gbm_service installed"
}

# Main execution
main() {
    log_subsection "Enhanced Service Configuration with SteamOS Patterns"

    create_polkit_policy
    install_switch_to_kodi_scripts
    install_switch_to_gamemode_scripts
    create_desktop_entries
    create_session_utilities
    patch_kodi_standalone_for_gbm
    install_kodi_gbm_service

    log_success "All services configured with enhanced Bazzite/SteamOS integration"
}

main "$@"
