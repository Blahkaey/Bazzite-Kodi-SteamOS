#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

create_polkit_rule() {
    log_info "Creating polkit rules for passwordless switching..."

    cat > "/usr/share/polkit-1/rules.d/49-kodi-switching.rules" << 'EOF'
// Allow wheel group to manage specific systemd services without password
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

// Allow kodi user to switch sessions without authentication
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.policykit.exec" ||
         action.id == "org.freedesktop.systemd1.manage-units") &&
        subject.user == "kodi") {
        return polkit.Result.YES;
    }
});

// Allow passwordless execution of switch scripts
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec") {
        var program = action.lookup("program");
        if ((program == "/usr/bin/switch-to-kodi" ||
             program == "/usr/bin/switch-to-gamemode" ||
             program.indexOf("switch-to-kodi") !== -1 ||
             program.indexOf("switch-to-gamemode") !== -1) &&
            (subject.isInGroup("wheel") || subject.user == "kodi")) {
            return polkit.Result.YES;
        }
    }
});
EOF

    log_success "Polkit rules created for passwordless switching"
}

install_switch_to_kodi_scripts() {
    log_info "Installing improved switch to kodi scripts..."

    # Main user-facing script
    cat > "/usr/bin/switch-to-kodi" << 'EOF'
#!/bin/bash
set -e

die() { echo >&2 "!! $*"; exit 1; }

# Configuration
CONF_FILE="/etc/sddm.conf.d/zz-steamos-autologin.conf"
SENTINEL_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/session-select"
STATE_FILE="/var/lib/kodi-session-state"

# Stage 1: User execution - update user preference
if [[ $EUID != 0 ]]; then
    [[ -n ${HOME+x} ]] || die "No \$HOME variable"

    # Check current state
    if [[ -f "$STATE_FILE" ]] && [[ "$(cat "$STATE_FILE" 2>/dev/null)" == "kodi" ]]; then
        echo "Already in Kodi mode"
        exit 0
    fi

    # Update user sentinel
    mkdir -p "$(dirname "$SENTINEL_FILE")"
    echo "kodi" > "$SENTINEL_FILE"
    echo "Updated user session preference to Kodi"

    # Re-execute as root with pkexec
    export SENTINEL_CREATED=1
    exec pkexec "$(realpath $0)" --elevated
    exit 1
fi

# Stage 2: Root execution - perform the switch
[[ "$1" == "--elevated" ]] || die "This stage must be run via pkexec"

echo "Switching to Kodi HDR mode..."

# Update state file
mkdir -p "$(dirname "$STATE_FILE")"
echo "kodi" > "$STATE_FILE"

# Stop SDDM if running (this will cleanly stop gamescope session)
if systemctl is-active --quiet sddm.service; then
    echo "Stopping display manager..."
    systemctl stop sddm.service
    sleep 2  # Give processes time to clean up
fi

# Ensure any hanging game processes are cleaned up
pkill -f "steam" 2>/dev/null || true
pkill -f "gamescope" 2>/dev/null || true

# Configure SDDM for next boot (in case of reboot while in Kodi)
{
    echo "[Autologin]"
    echo "Session=kodi-gbm-session.desktop"
} > "$CONF_FILE"

# Start Kodi
if ! systemctl start kodi-gbm.service; then
    die "Failed to start Kodi service"
fi

echo "Successfully switched to Kodi HDR mode"
EOF
    chmod +x "/usr/bin/switch-to-kodi"

    # Systemd service (simplified, just calls the script)
    cat > "/usr/lib/systemd/system/switch-to-kodi.service" << 'EOF'
[Unit]
Description=Switch to Kodi HDR Mode
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/switch-to-kodi --elevated
RemainAfterExit=no
StandardOutput=journal
StandardError=journal
EOF

    log_success "Installed improved switch to kodi scripts"
}

install_switch_to_gamemode_scripts() {
    log_info "Installing improved switch to gamemode scripts..."

    # Main user-facing script
    cat > "/usr/bin/switch-to-gamemode" << 'EOF'
#!/bin/bash
set -e

die() { echo >&2 "!! $*"; exit 1; }

# Configuration
CONF_FILE="/etc/sddm.conf.d/zz-steamos-autologin.conf"
SENTINEL_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/session-select"
STATE_FILE="/var/lib/kodi-session-state"
IMAGE_INFO="/usr/share/ublue-os/image-info.json"

# Detect if we're running from within Kodi session
detect_kodi_session() {
    # Check if we're the kodi user or if kodi-gbm is our parent
    if [[ "$USER" == "kodi" ]] || [[ "$(whoami)" == "kodi" ]]; then
        return 0
    fi

    # Check if kodi-gbm service is active and we're on tty1
    if systemctl is-active --quiet kodi-gbm.service && [[ "$(tty 2>/dev/null)" == "/dev/tty1" ]]; then
        return 0
    fi

    return 1
}

# Stage 1: User execution - update user preference
if [[ $EUID != 0 ]]; then
    # If running from within Kodi, skip user preference update
    if detect_kodi_session; then
        echo "Running from Kodi session, switching directly..."
        exec sudo "$(realpath $0)" --elevated-from-kodi
    fi

    [[ -n ${HOME+x} ]] || die "No \$HOME variable"

    # Check current state
    if [[ -f "$STATE_FILE" ]] && [[ "$(cat "$STATE_FILE" 2>/dev/null)" == "gamescope" ]]; then
        echo "Already in Gaming mode"
        exit 0
    fi

    # Update user sentinel
    mkdir -p "$(dirname "$SENTINEL_FILE")"
    echo "gamescope" > "$SENTINEL_FILE"
    echo "Updated user session preference to Gaming Mode"

    # Re-execute as root with pkexec
    export SENTINEL_CREATED=1
    exec pkexec "$(realpath $0)" --elevated
    exit 1
fi

# Stage 2: Root execution - perform the switch
[[ "$1" == "--elevated" || "$1" == "--elevated-from-kodi" ]] || die "This stage must be run via pkexec or sudo"

echo "Switching to Gaming Mode..."

# Update state file with proper permissions
mkdir -p "$(dirname "$STATE_FILE")"
echo "gamescope" > "$STATE_FILE"
chmod 666 "$STATE_FILE"

# Check if Steam is available
USER=$(id -nu 1000 2>/dev/null || echo "")
if [[ -n "$USER" ]]; then
    HOME=$(getent passwd $USER | cut -d: -f6)
    if [[ ! -f "$HOME/.local/share/Steam/ubuntu12_32/steamui.so" ]] && \
       [[ ! -f "/usr/bin/steam" ]]; then
        echo "Warning: Steam installation not detected"
    fi
fi

# Update SDDM autologin configuration
{
    echo "[Autologin]"
    echo "Session=gamescope-session.desktop"
} > "$CONF_FILE"

# Stop Kodi if running - with force cleanup
if systemctl is-active --quiet kodi-gbm.service; then
    echo "Stopping Kodi..."

    # First try graceful stop
    systemctl stop kodi-gbm.service || true

    # Give it a moment
    sleep 2

    # Force kill any remaining kodi processes
    echo "Cleaning up Kodi processes..."
    pkill -TERM -f "kodi" 2>/dev/null || true
    sleep 1
    pkill -KILL -f "kodi" 2>/dev/null || true

    # Clean up any hanging polkit authentication
    pkill -f "polkit-agent-helper" 2>/dev/null || true

    # Ensure TTY1 is released
    if [[ "$1" == "--elevated-from-kodi" ]]; then
        # If we're running from Kodi, we need to switch away from TTY1 first
        chvt 2 2>/dev/null || true
        sleep 0.5
    fi

    # Final cleanup
    timeout 3 bash -c 'while pgrep -x "kodi-gbm" > /dev/null; do sleep 0.5; done' || \
        pkill -9 -f "kodi" 2>/dev/null || true
fi

# Reset any failed services
systemctl reset-failed sddm.service 2>/dev/null || true
systemctl reset-failed kodi-gbm.service 2>/dev/null || true

# Ensure we're on TTY1 for SDDM
chvt 1 2>/dev/null || true

# Start SDDM (which will auto-start gamescope session)
echo "Starting display manager..."
if ! systemctl restart sddm.service; then
    # If restart fails, try stop then start
    systemctl stop sddm.service 2>/dev/null || true
    sleep 1
    if ! systemctl start sddm.service; then
        die "Failed to start display manager"
    fi
fi

echo "Successfully switched to Gaming Mode"
EOF
    chmod +x "/usr/bin/switch-to-gamemode"


    cat > "/usr/bin/kodi-exit" << 'EOF'
#!/bin/bash
# This script is designed to be called from within Kodi

# Write a flag file that Kodi can check on next startup
echo "gamemode" > /var/lib/kodi/switch-request

# Use systemctl without sudo - polkit should handle auth
/usr/bin/systemctl stop kodi-gbm.service &

# The service stop will kill this script, but the switch will complete
exit 0
EOF
    chmod +x "/usr/bin/kodi-exit"

    log_success "Installed improved switch to gamemode scripts"
}

create_desktop_entries() {
    log_info "Creating desktop entries..."

    # Switch to Kodi desktop entry
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

    # Create kodi-gbm-session.desktop for SDDM
    cat > "/usr/share/xsessions/kodi-gbm-session.desktop" << 'EOF'
[Desktop Entry]
Name=Kodi GBM Session
Comment=Kodi Media Center (GBM/HDR)
Exec=/usr/bin/kodi-standalone
Icon=kodi
Type=Application
EOF

    # Optional: Add a Gaming Mode switcher to Kodi's menu
    # This would need to be configured within Kodi's skin/addon system

    chmod 644 /usr/share/applications/*.desktop
    chmod 644 /usr/share/xsessions/*.desktop 2>/dev/null || true

    log_success "Desktop entries created"
}

install_session_query_script() {
    log_info "Installing session query utility..."

    cat > "/usr/bin/current-session-mode" << 'EOF'
#!/bin/bash
# Query current session mode

STATE_FILE="/var/lib/kodi-session-state"
SENTINEL_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/session-select"

# Check system state first
if [[ -f "$STATE_FILE" ]]; then
    echo "Current mode: $(cat "$STATE_FILE")"
else
    # Fallback: check what's actually running
    if systemctl is-active --quiet kodi-gbm.service; then
        echo "Current mode: kodi"
    elif systemctl is-active --quiet sddm.service; then
        echo "Current mode: gamescope"
    else
        echo "Current mode: unknown"
    fi
fi

# Show user preference if different
if [[ -f "$SENTINEL_FILE" ]]; then
    USER_PREF=$(cat "$SENTINEL_FILE")
    CURRENT=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")
    if [[ "$USER_PREF" != "$CURRENT" ]]; then
        echo "User preference: $USER_PREF (switch required)"
    fi
fi
EOF
    chmod +x "/usr/bin/current-session-mode"

    log_success "Session query utility installed"
}

patch_kodi_standalone_for_gbm() {
    log_info "Patching kodi-standalone for GBM support..."

    # Backup original if exists
    if [ -f "/usr/bin/kodi-standalone" ]; then
        cp /usr/bin/kodi-standalone /usr/bin/kodi-standalone.orig
        log_info "Backed up original kodi-standalone"
    fi

    # Create GBM-aware version with session management
    cat > "/usr/bin/kodi-standalone" << 'EOF'
#!/bin/sh
#
# Kodi standalone startup script for GBM/HDR mode
#

prefix="/usr"
exec_prefix="/usr"
bindir="/usr/bin"
libdir="/usr/lib64"

# Kodi GBM binary
APP="${libdir}/kodi/kodi-gbm"

# Session management
STATE_FILE="/var/lib/kodi-session-state"
echo "kodi" > "$STATE_FILE" 2>/dev/null || true

# Start PulseAudio if available
PULSE_START="$(command -v start-pulseaudio-x11)"
if [ -n "$PULSE_START" ]; then
  $PULSE_START
fi

# Crash recovery loop
LOOP=1
CRASHCOUNT=0
LASTSUCCESSFULSTART=$(date +%s)

while [ $LOOP -eq 1 ]
do
  # Run Kodi with all arguments
  $APP "$@"
  RET=$?
  NOW=$(date +%s)

  if [ $RET -ge 64 ] && [ $RET -le 66 ] || [ $RET -eq 0 ]; then
    # Clean exit
    LOOP=0
  else
    # Crash handling
    DIFF=$((NOW-LASTSUCCESSFULSTART))
    if [ $DIFF -gt 60 ]; then
      # Not a startup crash, reset counter
      LASTSUCCESSFULSTART=$NOW
      CRASHCOUNT=0
    else
      # Startup crash, increment counter
      CRASHCOUNT=$((CRASHCOUNT+1))
      if [ $CRASHCOUNT -ge 3 ]; then
        # Too many crashes, bail out
        LOOP=0
        echo "Kodi crashed 3 times in ${DIFF} seconds. Giving up." >&2

        # Optionally switch back to gaming mode on repeated crashes
        if command -v switch-to-gamemode >/dev/null 2>&1; then
            echo "Attempting to switch back to Gaming Mode..."
            switch-to-gamemode
        fi
      fi
    fi
  fi
done
EOF
    chmod +x /usr/bin/kodi-standalone

    log_success "kodi-standalone patched for GBM support"
}

install_kodi_gbm_service() {
    log_info "Installing kodi-gbm service..."

    # udev rules for DMA heap access
    cat > "/usr/lib/udev/rules.d/99-kodi.rules" << 'EOF'
# DMA heap access for hardware video acceleration
SUBSYSTEM=="dma_heap", KERNEL=="linux*", GROUP="video", MODE="0660"
SUBSYSTEM=="dma_heap", KERNEL=="system", GROUP="video", MODE="0660"

# Input device access for Kodi
SUBSYSTEM=="input", GROUP="input", MODE="0660"
EOF

    # tmpfiles configuration
    cat > "/usr/lib/tmpfiles.d/kodi-standalone.conf" << 'EOF'
d /var/lib/kodi 0750 kodi kodi - -
Z /var/lib/kodi - kodi kodi - -
f /var/lib/kodi-session-state 0666 root root - -
EOF

    # sysusers configuration
    cat > "/usr/lib/sysusers.d/kodi-standalone.conf" << 'EOF'
g kodi - -
u kodi - "Kodi User" /var/lib/kodi
EOF

    # Create kodi user
    systemd-sysusers

    # Remove password expiration
    chage -E -1 kodi
    chage -M -1 kodi

    # Enhanced kodi-gbm.service with better session management
    cat > "/usr/lib/systemd/system/kodi-gbm.service" << 'EOF'
[Unit]
Description=Kodi standalone (GBM/HDR)
After=remote-fs.target systemd-user-sessions.service network-online.target nss-lookup.target sound.target bluetooth.target polkit.service upower.service
Wants=network-online.target polkit.service upower.service
Conflicts=getty@tty1.service sddm.service

[Service]
User=kodi
Group=kodi
SupplementaryGroups=audio video render input optical
PAMName=login
TTYPath=/dev/tty1

# Pre-start: ensure we're on TTY1
ExecStartPre=/usr/bin/chvt 1

# Check for switch request
ExecStartPre=/bin/bash -c 'if [ -f /tmp/kodi-switch-request ] && [ "$(cat /tmp/kodi-switch-request)" == "gamemode" ]; then rm -f /tmp/kodi-switch-request; /usr/bin/switch-to-gamemode --elevated-from-kodi; exit 1; fi'

# Main process
ExecStart=/usr/bin/kodi-standalone

# Post-stop: if there's a switch request, execute it
ExecStopPost=/bin/bash -c 'if [ -f /var/lib/kodi/switch-request ]; then rm -f /var/lib/kodi/switch-request; fi; /usr/bin/switch-to-gamemode --elevated-from-kodi'

# Clean stop
ExecStop=/usr/bin/killall --exact --wait kodi-gbm kodi.bin

# Environment
EnvironmentFile=-/etc/conf.d/kodi-standalone
Environment="HOME=/var/lib/kodi"

# Session management
Restart=on-failure
RestartSec=5s

# Resource limits
LimitNOFILE=65536

# Standard IO
StandardInput=tty
StandardOutput=journal
StandardError=journal

[Install]
Alias=display-manager.service
EOF

    # Disable auto-start (manual switching only)
    systemctl disable kodi-gbm.service 2>/dev/null || true

    log_success "kodi-gbm service installed"
}

# Main execution
main() {
    log_subsection "Enhanced Service Configuration"

    create_polkit_rule
    install_switch_to_kodi_scripts
    install_switch_to_gamemode_scripts
    create_desktop_entries
    install_session_query_script
    patch_kodi_standalone_for_gbm
    install_kodi_gbm_service

    log_success "All services configured with improved session management"
    log_info "Use 'current-session-mode' to check active session"
    log_info "Use 'switch-to-kodi' or 'switch-to-gamemode' to change modes"
}

main "$@"
