#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

create_polkit_rule() {
    log_info "Creating polkit rules for service management..."

    cat > "/usr/share/polkit-1/rules.d/49-kodi-switching.rules" << 'EOF'
// Allow wheel group to manage specific systemd services without password
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.systemd1.manage-units") &&
        (action.lookup("unit") == "kodi-gbm.service" ||
         action.lookup("unit") == "sddm.service" ||
         action.lookup("unit") == "session-switch-handler.service") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});

// Allow kodi user to restart the session-switch-handler service
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.systemd1.manage-units") &&
        (action.lookup("unit") == "session-switch-handler.service") &&
        subject.user == "kodi") {
        return polkit.Result.YES;
    }
});
EOF

    log_success "Polkit rules created"
}

install_session_switch_handler() {
    log_info "Installing session switch handler daemon..."

    # Create the handler daemon
    cat > "/usr/bin/session-switch-handler" << 'EOF'
#!/bin/bash
# /usr/bin/session-switch-handler-minimal
# Minimal version to identify critical components

set -euo pipefail

# Configuration
TRIGGER_FILE="/var/run/session-switch-request"
STATE_FILE="/var/lib/session-state"
LOCK_FILE="/var/run/session-switch.lock"
SDDM_CONF="/etc/sddm.conf.d/zz-steamos-autologin.conf"
LOG_TAG="session-switch-handler"

# Logging functions
log_info() {
    logger -t "$LOG_TAG" -p info "$@"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $@"
}

log_error() {
    logger -t "$LOG_TAG" -p err "$@"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $@" >&2
}

# Initialize
mkdir -p /var/run /var/lib
touch "$TRIGGER_FILE"
chmod 666 "$TRIGGER_FILE"
echo -n "" > "$TRIGGER_FILE"

if [[ ! -f "$STATE_FILE" ]]; then
    if systemctl is-active --quiet kodi-gbm.service; then
        echo "kodi" > "$STATE_FILE"
    elif systemctl is-active --quiet sddm.service; then
        echo "gamemode" > "$STATE_FILE"
    else
        echo "unknown" > "$STATE_FILE"
    fi
fi
chmod 644 "$STATE_FILE"

log_info "Session switch handler started (minimal version)"

# CRITICAL FUNCTION 1: Wait for DRM
ensure_drm_ready() {
    log_info "TEST: Waiting for DRM..."
    local count=0
    while [ ! -e /dev/dri/card0 ] && [ $count -lt 20 ]; do
        sleep 0.2
        ((count++))
    done

    if [ ! -e /dev/dri/card0 ]; then
        log_error "DRM device not found"
        return 1
    fi

    # TEST: Is this delay needed?
    log_info "TEST: DRM sleep 1s"
    sleep 1
}

# CRITICAL FUNCTION 2: Display detection
force_display_detection() {
    log_info "TEST: Force display detection"

    # TEST: Is reading status helpful?
    if [ -f /sys/class/drm/card0-HDMI-A-1/status ]; then
        cat /sys/class/drm/card0-HDMI-A-1/status >/dev/null 2>&1 || true
        log_info "TEST: Read HDMI status"
    fi
}

# TEST FUNCTION: Simple VT switch
simple_wake() {
    log_info "TEST: Simple VT switch"
    chvt 2 2>/dev/null || true
    sleep 0.2
    chvt 1 2>/dev/null || true
}

switch_to_kodi() {
    log_info "Switching to Kodi..."

    # Skip if already in Kodi
    current_state=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")
    if [[ "$current_state" == "kodi" ]] && systemctl is-active --quiet kodi-gbm.service; then
        log_info "Already in Kodi mode"
        return 0
    fi

    # Update SDDM config
    mkdir -p "$(dirname "$SDDM_CONF")"
    {
        echo "[Autologin]"
        echo "Session=kodi-gbm-session.desktop"
    } > "$SDDM_CONF"

    # Stop SDDM
    if systemctl is-active --quiet sddm.service; then
        log_info "Stopping SDDM..."
        systemctl stop sddm.service || return 1

        # TEST: Is 3s wait needed?
        log_info "TEST: Post-SDDM wait 3s"
        sleep 3
    fi

    # Cleanup
    pkill -f "steam" 2>/dev/null || true
    pkill -f "gamescope" 2>/dev/null || true

    # CRITICAL: DRM ready check
    ensure_drm_ready

    # TEST: Display detection before Kodi
    force_display_detection

    # Ensure TTY1
    log_info "TEST: Switch to TTY1"
    chvt 1 2>/dev/null || true
    sleep 0.5

    # TEST: Wake before Kodi
    simple_wake

    # Start Kodi
    log_info "Starting Kodi..."
    if systemctl start kodi-gbm.service; then
        echo "kodi" > "$STATE_FILE"

        # TEST: Post-Kodi wait
        log_info "TEST: Post-Kodi wait 2s"
        sleep 2

        # TEST: Wake after Kodi
        simple_wake

        log_info "Successfully switched to Kodi"
        return 0
    else
        log_error "Failed to start Kodi"
        return 1
    fi
}

switch_to_gamemode() {
    log_info "Switching to Gaming mode..."

    current_state=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")
    if [[ "$current_state" == "gamemode" ]] && systemctl is-active --quiet sddm.service; then
        log_info "Already in Gaming mode"
        return 0
    fi

    mkdir -p "$(dirname "$SDDM_CONF")"
    {
        echo "[Autologin]"
        echo "Session=gamescope-session.desktop"
    } > "$SDDM_CONF"

    if systemctl is-active --quiet kodi-gbm.service; then
        log_info "Stopping Kodi..."
        systemctl stop kodi-gbm.service || true
        sleep 2
        pkill -KILL -f "kodi" 2>/dev/null || true
    fi

    ensure_drm_ready
    chvt 1 2>/dev/null || true
    simple_wake

    systemctl reset-failed sddm.service 2>/dev/null || true

    if systemctl start sddm.service; then
        echo "gamemode" > "$STATE_FILE"
        log_info "Successfully switched to Gaming mode"
        return 0
    else
        log_error "Failed to start SDDM"
        return 1
    fi
}

# Main loop
log_info "Entering main loop"

while true; do
    if inotifywait -t 60 -e modify,create "$TRIGGER_FILE" 2>/dev/null; then
        exec 200>"$LOCK_FILE"
        if ! flock -n 200; then
            continue
        fi

        REQUEST=$(cat "$TRIGGER_FILE" 2>/dev/null | tr -d '\n' | tr -d ' ')
        echo -n "" > "$TRIGGER_FILE"

        case "$REQUEST" in
            "kodi")
                switch_to_kodi
                ;;
            "gamemode"|"gaming")
                switch_to_gamemode
                ;;
        esac

        flock -u 200
    fi

    # Health check (FIXED: no 'local' outside function)
    current_state=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")
    if [[ "$current_state" == "kodi" ]] && ! systemctl is-active --quiet kodi-gbm.service; then
        echo "unknown" > "$STATE_FILE"
    elif [[ "$current_state" == "gamemode" ]] && ! systemctl is-active --quiet sddm.service; then
        echo "unknown" > "$STATE_FILE"
    fi
done
EOF
    chmod +x "/usr/bin/session-switch-handler"

    # Create systemd service
    cat > "/usr/lib/systemd/system/session-switch-handler.service" << 'EOF'
[Unit]
Description=Session Switch Handler for Kodi/GameMode
After=multi-user.target
Before=sddm.service kodi-gbm.service

[Service]
Type=simple
ExecStart=/usr/bin/session-switch-handler
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

# Run as root for system control
User=root
Group=root

# Ensure the service can control system services
SupplementaryGroups=wheel

# Resource limits
LimitNOFILE=4096

# Kill only the main process
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    # Enable the service
    systemctl enable session-switch-handler.service

    log_success "Session switch handler installed and enabled"
}

install_session_request_scripts() {
    log_info "Installing session request scripts..."

    # Simple script to request Kodi
    cat > "/usr/bin/request-kodi" << 'EOF'
#!/bin/bash
# Request switch to Kodi mode
echo "kodi" > /var/run/session-switch-request
echo "Requested switch to Kodi mode"
EOF
    chmod +x "/usr/bin/request-kodi"

    # Simple script to request gaming mode
    cat > "/usr/bin/request-gamemode" << 'EOF'
#!/bin/bash
# Request switch to Gaming mode
echo "gamemode" > /var/run/session-switch-request
echo "Requested switch to Gaming mode"
EOF
    chmod +x "/usr/bin/request-gamemode"

    # Kodi-specific wrapper (for calling from within Kodi UI)
    cat > "/usr/bin/kodi-request-gamemode" << 'EOF'
#!/bin/bash
# Kodi UI-friendly wrapper for requesting gaming mode
# This can be called from Kodi's shutdown menu or mapped to a button

# Write the request
echo "gamemode" > /var/run/session-switch-request

# Give visual feedback if running in a terminal
if [ -t 1 ]; then
    echo "Switching to Gaming Mode..."
    echo "Please wait..."
fi

# Exit successfully so Kodi knows the command worked
exit 0
EOF
    chmod +x "/usr/bin/kodi-request-gamemode"

    log_success "Session request scripts installed"
}

create_desktop_entries() {
    log_info "Creating desktop entries..."

    # Request Kodi desktop entry
    cat > "/usr/share/applications/request-kodi.desktop" << 'EOF'
[Desktop Entry]
Name=Switch to Kodi HDR
Comment=Switch to Kodi Media Center with HDR support
Exec=/usr/bin/request-kodi
Icon=kodi
Type=Application
Categories=AudioVideo;Video;Player;TV;System;
Terminal=false
StartupNotify=false
EOF

    # Request Gaming Mode desktop entry
    cat > "/usr/share/applications/request-gamemode.desktop" << 'EOF'
[Desktop Entry]
Name=Switch to Gaming Mode
Comment=Switch back to Gaming Mode
Exec=/usr/bin/request-gamemode
Icon=steam
Type=Application
Categories=Game;System;
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

    chmod 644 /usr/share/applications/*.desktop
    chmod 644 /usr/share/xsessions/*.desktop 2>/dev/null || true

    log_success "Desktop entries created"
}


patch_kodi_standalone_for_gbm() {
    log_info "Patching kodi-standalone for GBM support..."

    # Backup original if exists
    if [ -f "/usr/bin/kodi-standalone" ]; then
        cp /usr/bin/kodi-standalone /usr/bin/kodi-standalone.orig
        log_info "Backed up original kodi-standalone"
    fi

    # Create GBM-aware version without switch-to-gamemode calls
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
        # Note: User can manually switch back using request-gamemode
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
f /var/lib/session-state 0644 root root - -
f /var/run/session-switch-request 0666 root root - -
EOF

    # sysusers configuration
    cat > "/usr/lib/sysusers.d/kodi-standalone.conf" << 'EOF'
g kodi - -
u kodi - "Kodi User" /var/lib/kodi
EOF

    # Create kodi user
    systemd-sysusers

    # Add kodi to necessary groups
    usermod -a -G audio,video,render,input,optical kodi 2>/dev/null || true

    # Remove password expiration
    chage -E -1 kodi
    chage -M -1 kodi

    # Simplified kodi-gbm.service
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

ExecStartPre=/usr/bin/chvt 1
ExecStart=/usr/bin/kodi-standalone
ExecStop=-/usr/bin/killall --exact kodi-gbm

# Environment
EnvironmentFile=-/etc/conf.d/kodi-standalone
Environment="HOME=/var/lib/kodi"

# Session management
Restart=on-failure
RestartSec=5s
TimeoutStopSec=10

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
    log_subsection "Session Management Service Configuration"

    create_polkit_rule
    install_session_switch_handler
    install_session_request_scripts
    create_desktop_entries
    patch_kodi_standalone_for_gbm
    install_kodi_gbm_service

    log_success "Session management configured with file-watch handler"
    log_info "Usage:"
    log_info "  - Switch to Kodi: request-kodi"
    log_info "  - Switch to Gaming: request-gamemode"
    log_info "  - From Kodi UI: run kodi-request-gamemode"
    log_info ""
    log_info "The session-switch-handler service will manage all transitions"
}

main "$@"
