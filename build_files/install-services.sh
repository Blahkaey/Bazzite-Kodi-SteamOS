#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

# Configuration via environment variables (can be set in systemd service)
export SKIP_DISPLAY_WAKE=${SKIP_DISPLAY_WAKE:-0}
export SKIP_VT_SWITCH=${SKIP_VT_SWITCH:-0}
export SKIP_PROCESS_CLEANUP=${SKIP_PROCESS_CLEANUP:-0}
export SKIP_DRM_WAIT=${SKIP_DRM_WAIT:-0}
export REDUCE_DELAYS=${REDUCE_DELAYS:-0}
export WAKE_METHOD=${WAKE_METHOD:-ddcutil}  # ddcutil, vt, or none
export ENABLE_HEALTH_CHECK=${ENABLE_HEALTH_CHECK:-0}

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

    # Create the optimized handler daemon
    cat > "/usr/bin/session-switch-handler" << 'EOF'
#!/bin/bash
#
# Optimized Session Switch Handler Daemon
# Watches for session switch requests and handles transitions
#

set -euo pipefail

# Configuration
TRIGGER_FILE="/var/run/session-switch-request"
STATE_FILE="/var/lib/session-state"
LOCK_FILE="/var/run/session-switch.lock"
SDDM_CONF="/etc/sddm.conf.d/zz-steamos-autologin.conf"
LOG_TAG="session-switch-handler"

# Import environment variables for configuration
SKIP_DISPLAY_WAKE=${SKIP_DISPLAY_WAKE:-0}
SKIP_VT_SWITCH=${SKIP_VT_SWITCH:-0}
SKIP_PROCESS_CLEANUP=${SKIP_PROCESS_CLEANUP:-0}
SKIP_DRM_WAIT=${SKIP_DRM_WAIT:-0}
REDUCE_DELAYS=${REDUCE_DELAYS:-0}
WAKE_METHOD=${WAKE_METHOD:-ddcutil}
ENABLE_HEALTH_CHECK=${ENABLE_HEALTH_CHECK:-0}

# Delay configuration
if [[ $REDUCE_DELAYS -eq 1 ]]; then
    DELAY_SDDM_STOP=0.5
    DELAY_KODI_START=0.5
    DELAY_KODI_STOP=0.5
    DELAY_DRM_SETTLE=0.2
    DELAY_VT_SWITCH=0.1
    DELAY_PROCESS_KILL=0.2
else
    DELAY_SDDM_STOP=3
    DELAY_KODI_START=2
    DELAY_KODI_STOP=2
    DELAY_DRM_SETTLE=1
    DELAY_VT_SWITCH=0.5
    DELAY_PROCESS_KILL=0.5
fi

# Logging functions
log_info() {
    logger -t "$LOG_TAG" -p info "$@"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $@"
}

log_error() {
    logger -t "$LOG_TAG" -p err "$@"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $@" >&2
}

# Ensure runtime directory exists
mkdir -p /var/run
mkdir -p /var/lib

# Initialize trigger file with proper permissions
touch "$TRIGGER_FILE"
chmod 666 "$TRIGGER_FILE"
echo -n "" > "$TRIGGER_FILE"

# Initialize state file
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

log_info "Session switch handler started (REDUCE_DELAYS=$REDUCE_DELAYS, WAKE_METHOD=$WAKE_METHOD)"

# Optimized display wake function
wake_display() {
    if [[ $SKIP_DISPLAY_WAKE -eq 1 ]]; then
        return 0
    fi

    case "$WAKE_METHOD" in
        none)
            return 0
            ;;
        ddcutil)
            if command -v ddcutil &>/dev/null; then
                ddcutil dpms on 2>/dev/null || true
            fi
            ;;
        vt)
            if [[ $SKIP_VT_SWITCH -eq 0 ]]; then
                local current_vt=$(fgconsole 2>/dev/null || echo "1")
                if [[ "$current_vt" != "1" ]]; then
                    chvt 1 2>/dev/null || true
                else
                    chvt 2 2>/dev/null || true
                    sleep $DELAY_VT_SWITCH
                    chvt 1 2>/dev/null || true
                fi
            fi
            ;;
    esac
}

# Optimized process cleanup
cleanup_processes() {
    if [[ $SKIP_PROCESS_CLEANUP -eq 1 ]]; then
        return 0
    fi

    local target="$1"

    case "$target" in
        kodi)
            pkill -TERM -f "kodi" 2>/dev/null || true
            ;;
        gaming)
            pkill -TERM -f "steam" 2>/dev/null || true
            pkill -TERM -f "gamescope" 2>/dev/null || true
            ;;
    esac

    # Only wait and force kill if processes remain
    sleep $DELAY_PROCESS_KILL

    case "$target" in
        kodi)
            if pgrep -f "kodi" >/dev/null; then
                pkill -KILL -f "kodi" 2>/dev/null || true
            fi
            ;;
        gaming)
            if pgrep -f "steam|gamescope" >/dev/null; then
                pkill -KILL -f "steam" 2>/dev/null || true
                pkill -KILL -f "gamescope" 2>/dev/null || true
            fi
            ;;
    esac
}

# Optimized DRM readiness check
ensure_drm_ready() {
    if [[ $SKIP_DRM_WAIT -eq 1 ]]; then
        return 0
    fi

    local count=0
    while [ ! -e /dev/dri/card0 ] && [ $count -lt 10 ]; do
        sleep 0.1
        ((count++))
    done

    if [ ! -e /dev/dri/card0 ]; then
        log_error "DRM device not found after waiting"
        return 1
    fi

    sleep $DELAY_DRM_SETTLE
    return 0
}

# Optimized switch to Kodi
switch_to_kodi() {
    log_info "Switching to Kodi HDR mode..."

    # Quick check if already in Kodi mode
    if systemctl is-active --quiet kodi-gbm.service; then
        log_info "Already in Kodi mode"
        return 0
    fi

    # Update SDDM configuration for next boot
    mkdir -p "$(dirname "$SDDM_CONF")"
    {
        echo "[Autologin]"
        echo "Session=kodi-gbm-session.desktop"
    } > "$SDDM_CONF"

    # Stop display manager if running
    if systemctl is-active --quiet sddm.service; then
        log_info "Stopping SDDM..."
        systemctl stop sddm.service || {
            log_error "Failed to stop SDDM"
            return 1
        }
        sleep $DELAY_SDDM_STOP
    fi

    # Clean up gaming processes
    cleanup_processes "gaming"

    # Ensure DRM is ready
    ensure_drm_ready

    # VT switch if enabled
    if [[ $SKIP_VT_SWITCH -eq 0 ]]; then
        chvt 1 2>/dev/null || true
        sleep $DELAY_VT_SWITCH
    fi

    # Wake display before starting
    wake_display

    # Start Kodi
    log_info "Starting Kodi service..."
    if systemctl start kodi-gbm.service; then
        echo "kodi" > "$STATE_FILE"
        sleep $DELAY_KODI_START

        # Optional second wake attempt
        if [[ "$WAKE_METHOD" != "none" ]]; then
            wake_display
        fi

        log_info "Successfully switched to Kodi"
        return 0
    else
        log_error "Failed to start Kodi service"
        return 1
    fi
}

# Optimized switch to gaming mode
switch_to_gamemode() {
    log_info "Switching to Gaming mode..."

    # Quick check if already in gaming mode
    if systemctl is-active --quiet sddm.service; then
        log_info "Already in Gaming mode"
        return 0
    fi

    # Update SDDM configuration
    mkdir -p "$(dirname "$SDDM_CONF")"
    {
        echo "[Autologin]"
        echo "Session=gamescope-session.desktop"
    } > "$SDDM_CONF"

    # Stop Kodi if running
    if systemctl is-active --quiet kodi-gbm.service; then
        log_info "Stopping Kodi service..."
        systemctl stop kodi-gbm.service || true
        sleep $DELAY_KODI_STOP
        cleanup_processes "kodi"
    fi

    # Ensure DRM is ready
    ensure_drm_ready

    # VT switch if enabled
    if [[ $SKIP_VT_SWITCH -eq 0 ]]; then
        chvt 1 2>/dev/null || true
    fi

    # Wake display
    wake_display

    # Reset any failed services
    systemctl reset-failed sddm.service 2>/dev/null || true

    # Start SDDM
    log_info "Starting SDDM..."
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
log_info "Entering main loop, watching $TRIGGER_FILE"

while true; do
    # Wait for file change
    if [[ $ENABLE_HEALTH_CHECK -eq 1 ]]; then
        timeout_arg="-t 60"
    else
        timeout_arg=""
    fi

    if inotifywait $timeout_arg -e modify,create "$TRIGGER_FILE" 2>/dev/null; then
        # Lock to prevent concurrent processing
        exec 200>"$LOCK_FILE"
        if ! flock -n 200; then
            log_info "Another switch operation in progress, skipping..."
            continue
        fi

        # Read and clear the request
        REQUEST=$(cat "$TRIGGER_FILE" 2>/dev/null | tr -d '\n' | tr -d ' ')
        echo -n "" > "$TRIGGER_FILE"

        # Process the request
        case "$REQUEST" in
            "kodi")
                switch_to_kodi
                ;;
            "gamemode"|"gaming")
                switch_to_gamemode
                ;;
            "")
                # Empty request, ignore
                ;;
            *)
                log_error "Unknown request: $REQUEST"
                ;;
        esac

        # Release lock
        flock -u 200
    fi

    # Optional health check
    if [[ $ENABLE_HEALTH_CHECK -eq 1 ]]; then
        current_state=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")
        if [[ "$current_state" == "kodi" ]] && ! systemctl is-active --quiet kodi-gbm.service; then
            log_info "State mismatch detected: state=kodi but service not running"
            echo "unknown" > "$STATE_FILE"
        elif [[ "$current_state" == "gamemode" ]] && ! systemctl is-active --quiet sddm.service; then
            log_info "State mismatch detected: state=gamemode but SDDM not running"
            echo "unknown" > "$STATE_FILE"
        fi
    fi
done
EOF
    chmod +x "/usr/bin/session-switch-handler"

    # Create systemd service with environment file support
    cat > "/usr/lib/systemd/system/session-switch-handler.service" << 'EOF'
[Unit]
Description=Optimized Session Switch Handler for Kodi/GameMode
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

# Environment configuration
EnvironmentFile=-/etc/sysconfig/session-switch-handler

[Install]
WantedBy=multi-user.target
EOF

    # Create default environment file
    cat > "/etc/sysconfig/session-switch-handler" << 'EOF'
# Session Switch Handler Configuration
# Modify these values based on your testing results

# Skip display wake attempts (0=enabled, 1=disabled)
SKIP_DISPLAY_WAKE=0

# Skip VT switching (0=enabled, 1=disabled)
SKIP_VT_SWITCH=0

# Skip process cleanup (0=enabled, 1=disabled)
SKIP_PROCESS_CLEANUP=0

# Skip DRM readiness check (0=enabled, 1=disabled)
SKIP_DRM_WAIT=0

# Use reduced delays for faster switching (0=normal, 1=fast)
REDUCE_DELAYS=0

# Display wake method (none, ddcutil, vt)
WAKE_METHOD=ddcutil

# Enable health check (0=disabled, 1=enabled)
ENABLE_HEALTH_CHECK=0
EOF

    # Enable the service
    systemctl enable session-switch-handler.service

    log_success "Optimized session switch handler installed and enabled"
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

    # Create optimized GBM-aware version
    cat > "/usr/bin/kodi-standalone" << 'EOF'
#!/bin/sh
#
# Optimized Kodi standalone startup script for GBM/HDR mode
#

prefix="/usr"
exec_prefix="/usr"
bindir="/usr/bin"
libdir="/usr/lib64"

# Kodi GBM binary
APP="${libdir}/kodi/kodi-gbm"

# Start PulseAudio if available and not already running
if command -v start-pulseaudio-x11 >/dev/null 2>&1; then
    if ! pgrep -x pulseaudio >/dev/null 2>&1; then
        start-pulseaudio-x11 2>/dev/null || true
    fi
fi

# Crash recovery loop with faster recovery
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

    # Optimized kodi-gbm.service
    cat > "/usr/lib/systemd/system/kodi-gbm.service" << 'EOF'
[Unit]
Description=Kodi standalone (GBM/HDR)
After=remote-fs.target systemd-user-sessions.service network-online.target sound.target bluetooth.target polkit.service upower.service
Wants=network-online.target polkit.service upower.service
Conflicts=getty@tty1.service sddm.service

[Service]
User=kodi
Group=kodi
SupplementaryGroups=audio video render input optical
PAMName=login
TTYPath=/dev/tty1

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

# Create configuration helper script
create_config_helper() {
    log_info "Creating configuration helper..."

    cat > "/usr/bin/session-switch-config" << 'EOF'
#!/bin/bash
# Helper script to configure session switch optimization

CONFIG_FILE="/etc/sysconfig/session-switch-handler"

echo "Session Switch Configuration Helper"
echo "=================================="
echo ""
echo "Current configuration:"
cat "$CONFIG_FILE" | grep -E "^[^#].*=" | sed 's/^/  /'
echo ""

echo "To apply optimized settings based on testing, edit:"
echo "  $CONFIG_FILE"
echo ""
echo "Then restart the service:"
echo "  sudo systemctl restart session-switch-handler"
echo ""
echo "Example fast configuration:"
echo "  REDUCE_DELAYS=1"
echo "  SKIP_DISPLAY_WAKE=1  # if display wake not needed"
echo "  WAKE_METHOD=none     # or ddcutil if wake is needed"
EOF
    chmod +x "/usr/bin/session-switch-config"
}

# Main execution
main() {
    log_subsection "Optimized Session Management Service Configuration"

    create_polkit_rule
    install_session_switch_handler
    install_session_request_scripts
    create_desktop_entries
    patch_kodi_standalone_for_gbm
    install_kodi_gbm_service
    create_config_helper

    log_success "Optimized session management configured"
    log_info ""
    log_info "Configuration:"
    log_info "  - Edit /etc/sysconfig/session-switch-handler to optimize based on testing"
    log_info "  - Use session-switch-config to view current settings"
    log_info ""
    log_info "Usage:"
    log_info "  - Switch to Kodi: request-kodi"
    log_info "  - Switch to Gaming: request-gamemode"
    log_info "  - From Kodi UI: run kodi-request-gamemode"
    log_info ""
    log_info "Testing:"
    log_info "  - Run benchmarks with: session-switch-benchmark"
    log_info "  - Analyze results with: session-switch-analyze report"
    log_info "  - Apply optimal config to /etc/sysconfig/session-switch-handler"
}

main "$@"
