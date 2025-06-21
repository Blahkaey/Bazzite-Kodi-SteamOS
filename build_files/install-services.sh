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
    log_info "Installing optimized session switch handler daemon..."

    cat > "/usr/bin/session-switch-handler" << 'EOF'
#!/bin/bash
#
# Session Switch Handler Daemon
# Watches for session switch requests and handles transitions
#

set -euo pipefail

# Configuration
TRIGGER_FILE="/var/run/session-switch-request"
STATE_FILE="/var/lib/session-state"
LOCK_FILE="/var/run/session-switch.lock"
DISPLAY_METHOD_FILE="/var/run/display-wake-method"
SDDM_CONF="/etc/sddm.conf.d/zz-steamos-autologin.conf"
LOG_TAG="session-switch-handler"

# Logging functions
log_info() {
    logger -t "$LOG_TAG" -p info "$@"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $@"
}

log_warning() {
    logger -t "$LOG_TAG" -p warning "$@"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $@" >&2
}

log_error() {
    logger -t "$LOG_TAG" -p err "$@"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $@" >&2
}

# Initialize runtime files
mkdir -p /var/run /var/lib
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

log_info "Session switch handler started"

# Function: Wait for process to exit with timeout
wait_for_process_exit() {
    local process_pattern="$1"
    local timeout="${2:-30}"  # Default 30 iterations (3 seconds)
    local count=0
    
    while pgrep -f "$process_pattern" >/dev/null && [ $count -lt $timeout ]; do
        sleep 0.1
        ((count++))
    done
    
    # Return success if process is gone
    ! pgrep -f "$process_pattern" >/dev/null
}

# Function: Wait for process to start with timeout
wait_for_process_start() {
    local process_name="$1"
    local timeout="${2:-20}"  # Default 20 iterations (2 seconds)
    local count=0
    
    while ! pgrep -x "$process_name" >/dev/null && [ $count -lt $timeout ]; do
        sleep 0.1
        ((count++))
    done
    
    # Return success if process started
    pgrep -x "$process_name" >/dev/null
}

# Function: Smart display wake with learning
wake_display() {
    log_info "Waking display..."
    
    # Check what method worked last time
    local last_method=$(cat "$DISPLAY_METHOD_FILE" 2>/dev/null || echo "unknown")
    
    # Try ddcutil first (unless we know it needs VT)
    if [[ "$last_method" != "vt_required" ]]; then
        if command -v ddcutil &>/dev/null; then
            if ddcutil dpms on 2>/dev/null; then
                echo "ddcutil" > "$DISPLAY_METHOD_FILE"
                return 0
            fi
        fi
    fi
    
    # If ddcutil failed or wasn't tried, do VT switch
    log_info "Using VT switch for display wake"
    local current_vt=$(fgconsole 2>/dev/null || echo "1")
    
    # Quick VT switch to reset display state
    chvt 2 2>/dev/null || true
    sleep 0.1
    chvt 1 2>/dev/null || true
    sleep 0.1
    
    # Try ddcutil again after VT switch
    if command -v ddcutil &>/dev/null; then
        if ddcutil dpms on 2>/dev/null; then
            echo "vt_then_ddcutil" > "$DISPLAY_METHOD_FILE"
        else
            echo "vt_required" > "$DISPLAY_METHOD_FILE"
        fi
    else
        echo "vt_only" > "$DISPLAY_METHOD_FILE"
    fi
}

# Function: Process cleanup
cleanup_processes() {
    local target="$1"
    
    case "$target" in
        kodi)
            # Try graceful termination
            pkill -TERM -f "kodi" 2>/dev/null || true
            # Short grace period
            sleep 0.2
            # Force kill if still running
            if pgrep -f "kodi" >/dev/null; then
                log_info "Force killing Kodi processes"
                pkill -KILL -f "kodi" 2>/dev/null || true
            fi
            ;;
        gaming)
            # Terminate Steam and Gamescope
            pkill -TERM -f "steam" 2>/dev/null || true
            pkill -TERM -f "gamescope" 2>/dev/null || true
            # Short grace period
            sleep 0.2
            # Force kill if needed
            if pgrep -f "steam|gamescope" >/dev/null; then
                log_info "Force killing gaming processes"
                pkill -KILL -f "steam" 2>/dev/null || true
                pkill -KILL -f "gamescope" 2>/dev/null || true
            fi
            ;;
    esac
}

# Function: Find the active HDMI connector
find_active_hdmi_connector() {
    local connector
    for connector in /sys/class/drm/card*-HDMI-*/status; do
        if [ -f "$connector" ] && [ "$(cat "$connector")" = "connected" ]; then
            echo "${connector%/status}"
            return 0
        fi
    done
    return 1
}

# Function: Set DRM content type property
set_drm_content_type() {
    local content_type=$1
    local active_connector

    # Find the active HDMI connector
    if ! active_connector=$(find_active_hdmi_connector); then
        log_error "No active HDMI connector found"
        return 1
    fi

    # Extract connector name
    local drm_device=$(basename "$(dirname "$active_connector")")
    local connector_name=$(echo "$drm_device" | sed 's/card[0-9]*-//')

    log_info "Setting content_type to $content_type on $drm_device"

    if command -v modetest >/dev/null 2>&1; then
        # Get full modetest output
        local modetest_output=$(modetest -c -p 2>/dev/null)

        # Find the connector section for HDMI
        local connector_section=$(echo "$modetest_output" | awk "/^[0-9]+.*connected.*$connector_name/{flag=1} flag && /^[0-9]+.*connected|^$/{if(p)exit; p=1} flag")

        # Extract connector ID
        local connector_id=$(echo "$connector_section" | head -1 | awk '{print $1}')

        # Find the property ID for "content type"
        local property_id=$(echo "$connector_section" | grep -E "^\s+[0-9]+\s+content type:" | awk '{print $1}')

        if [ -n "$connector_id" ] && [ -n "$property_id" ]; then
            log_info "Found connector ID: $connector_id, property ID: $property_id"

            # Set the property
            if modetest -w "${connector_id}:${property_id}:${content_type}" 2>/dev/null; then
                log_info "Content type set successfully to $content_type"

                # Verify the change
                local new_value=$(modetest -c 2>/dev/null | grep -A20 "^${connector_id}.*connected" | grep "content type:" -A1 | grep "value:" | awk '{print $2}')
                if [ "$new_value" = "$content_type" ]; then
                    log_info "Verified: content type is now $new_value"
                fi

                return 0
            else
                log_warning "Failed to set content_type via modetest"
            fi
        else
            log_error "Could not find connector ID or property ID"
        fi
    fi

    return 1
}


# Function: Switch to Kodi with retry logic
switch_to_kodi() {
    log_info "Switching to Kodi HDR mode..."
    
    # Quick check if already running
    if systemctl is-active --quiet kodi-gbm.service; then
        log_info "Already in Kodi mode"
        return 0
    fi
    
    # Update SDDM config for next boot
    mkdir -p "$(dirname "$SDDM_CONF")"
    {
        echo "[Autologin]"
        echo "Session=kodi-gbm-session.desktop"
    } > "$SDDM_CONF"
    
    # Stop SDDM if running
    if systemctl is-active --quiet sddm.service; then
        log_info "Stopping SDDM..."
        if ! systemctl stop sddm.service; then
            log_error "Failed to stop SDDM"
            return 1
        fi
        
        # Wait for gamescope to actually exit
        wait_for_process_exit "gamescope" 30 || {
            log_warning "Gamescope didn't exit cleanly, continuing anyway"
        }
    fi
    
    # Cleanup gaming processes
    cleanup_processes "gaming"

    log_info "Disabling ALLM (setting content type to Cinema)"
    # Set content type to CINEMA (3) to disable ALLM
    set_drm_content_type 3

    # Ensure on TTY1
    chvt 1 2>/dev/null || true
    
    # Wake display before starting
    wake_display
    
    # Try to start Kodi (with retry)
    local attempts=0
    local max_attempts=2
    
    while [ $attempts -lt $max_attempts ]; do
        log_info "Starting Kodi service (attempt $((attempts+1))/$max_attempts)..."
        
        if systemctl start kodi-gbm.service; then
            # Wait for Kodi to actually start
            if wait_for_process_start "kodi-gbm" 20; then
                echo "kodi" > "$STATE_FILE"
                wake_display  # Wake again after start
                log_info "Successfully switched to Kodi"
                return 0
            else
                log_error "Kodi service started but process not found"
                systemctl stop kodi-gbm.service 2>/dev/null || true
            fi
        fi
        
        ((attempts++))
        
        if [ $attempts -lt $max_attempts ]; then
            log_info "Retrying in 1 second..."
            sleep 1
        fi
    done
    
    # Attempts failed, try recovery
    log_error "Failed to start Kodi after $max_attempts attempts, attempting recovery"
    
    # Recovery: Clear any stuck state and try once more
    systemctl reset-failed kodi-gbm.service 2>/dev/null || true
    pkill -KILL -f "kodi" 2>/dev/null || true
    sleep 0.5
    
    if systemctl start kodi-gbm.service; then
        if wait_for_process_start "kodi-gbm" 20; then
            echo "kodi" > "$STATE_FILE"
            wake_display
            log_info "Recovery successful - Kodi started"
            return 0
        fi
    fi
    
    log_error "Failed to start Kodi - recovery unsuccessful"
    echo "failed" > "$STATE_FILE"
    return 1
}

# Function: Switch to gaming mode with retry logic
switch_to_gamemode() {
    log_info "Switching to Gaming mode..."
    
    # Quick check if already running
    if systemctl is-active --quiet sddm.service; then
        log_info "Already in Gaming mode"
        return 0
    fi
    
    # Update SDDM config
    mkdir -p "$(dirname "$SDDM_CONF")"
    {
        echo "[Autologin]"
        echo "Session=gamescope-session.desktop"
    } > "$SDDM_CONF"
    
    # Stop Kodi if running
    if systemctl is-active --quiet kodi-gbm.service; then
        log_info "Stopping Kodi service..."
        systemctl stop kodi-gbm.service || true
        
        # Wait for Kodi to exit
        wait_for_process_exit "kodi-gbm" 20 || {
            log_warning "Kodi didn't exit cleanly, continuing anyway"
        }
    fi
    
    # Cleanup Kodi processes
    cleanup_processes "kodi"
    
    # Ensure on TTY1
    #chvt 1 2>/dev/null || true
    
    # Wake display
    #wake_display
    
    # Try to start SDDM (with retry)
    local attempts=0
    local max_attempts=2
    
    while [ $attempts -lt $max_attempts ]; do
        log_info "Starting SDDM (attempt $((attempts+1))/$max_attempts)..."
        
        # Reset failed state
        systemctl reset-failed sddm.service 2>/dev/null || true
        
        if systemctl start sddm.service; then
            # Give SDDM a moment to initialize
            sleep 0.5
            
            if systemctl is-active --quiet sddm.service; then
                echo "gamemode" > "$STATE_FILE"
                log_info "Successfully switched to Gaming mode"
                return 0
            fi
        fi
        
        ((attempts++))
        
        if [ $attempts -lt $max_attempts ]; then
            log_info "Retrying in 1 second..."
            sleep 1
        fi
    done
    
    # Recovery attempt
    log_error "Failed to start SDDM after $max_attempts attempts, attempting recovery"
    
    # Kill any stuck processes
    pkill -KILL -f "sddm" 2>/dev/null || true
    sleep 0.5
    
    systemctl reset-failed sddm.service 2>/dev/null || true
    
    if systemctl start sddm.service; then
        echo "gamemode" > "$STATE_FILE"
        log_info "Recovery successful - SDDM started"
        return 0
    fi
    
    log_error "Failed to start SDDM - recovery unsuccessful"
    echo "failed" > "$STATE_FILE"
    return 1
}

# Main loop
log_info "Entering main loop, watching $TRIGGER_FILE"

while true; do
    # Wait for trigger file modification
    if inotifywait -e modify,create "$TRIGGER_FILE" 2>/dev/null; then
        # Lock to prevent concurrent switches
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
done
EOF
    chmod +x "/usr/bin/session-switch-handler"

    cat > "/usr/lib/systemd/system/session-switch-handler.service" << 'EOF'
[Unit]
Description=Optimized Session Switch Handler
After=multi-user.target
Before=sddm.service kodi-gbm.service

[Service]
Type=simple
ExecStart=/usr/bin/session-switch-handler
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

User=root
Group=root
SupplementaryGroups=wheel

LimitNOFILE=4096
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable session-switch-handler.service

    log_success "Session switch handler installed"
}

install_session_request_scripts() {
    log_info "Installing session request scripts..."

    cat > "/usr/bin/request-kodi" << 'EOF'
#!/bin/bash
echo "kodi" > /var/run/session-switch-request
echo "Requested switch to Kodi mode"
EOF
    chmod +x "/usr/bin/request-kodi"

    cat > "/usr/bin/request-gamemode" << 'EOF'
#!/bin/bash
echo "gamemode" > /var/run/session-switch-request
echo "Requested switch to Gaming mode"
EOF
    chmod +x "/usr/bin/request-gamemode"

    cat > "/usr/bin/kodi-request-gamemode" << 'EOF'
#!/bin/bash
# For calling from within Kodi UI
echo "gamemode" > /var/run/session-switch-request
if [ -t 1 ]; then
    echo "Switching to Gaming Mode..."
fi
exit 0
EOF
    chmod +x "/usr/bin/kodi-request-gamemode"

    log_success "Session request scripts installed"
}

create_desktop_entries() {
    log_info "Creating desktop entries..."

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

    if [ -f "/usr/bin/kodi-standalone" ]; then
        cp /usr/bin/kodi-standalone /usr/bin/kodi-standalone.orig
    fi

    cat > "/usr/bin/kodi-standalone" << 'EOF'
#!/bin/sh
#
# Optimized Kodi standalone startup script
#

APP="/usr/lib64/kodi/kodi-gbm"

# Start PulseAudio if needed
if command -v start-pulseaudio-x11 >/dev/null 2>&1; then
    if ! pgrep -x pulseaudio >/dev/null 2>&1; then
        start-pulseaudio-x11 2>/dev/null || true
    fi
fi

# Simple crash recovery
LOOP=1
CRASHCOUNT=0
LASTSUCCESSFULSTART=$(date +%s)

while [ $LOOP -eq 1 ]
do
    $APP "$@"
    RET=$?
    NOW=$(date +%s)

    if [ $RET -ge 64 ] && [ $RET -le 66 ] || [ $RET -eq 0 ]; then
        LOOP=0
    else
        DIFF=$((NOW-LASTSUCCESSFULSTART))
        if [ $DIFF -gt 60 ]; then
            LASTSUCCESSFULSTART=$NOW
            CRASHCOUNT=0
        else
            CRASHCOUNT=$((CRASHCOUNT+1))
            if [ $CRASHCOUNT -ge 3 ]; then
                LOOP=0
                echo "Kodi crashed 3 times in ${DIFF} seconds. Giving up." >&2
            fi
        fi
    fi
done
EOF
    chmod +x /usr/bin/kodi-standalone

    log_success "kodi-standalone patched"
}

install_kodi_gbm_service() {
    log_info "Installing kodi-gbm service..."

    cat > "/usr/lib/udev/rules.d/99-kodi.rules" << 'EOF'
SUBSYSTEM=="dma_heap", KERNEL=="linux*", GROUP="video", MODE="0660"
SUBSYSTEM=="dma_heap", KERNEL=="system", GROUP="video", MODE="0660"
SUBSYSTEM=="input", GROUP="input", MODE="0660"
EOF

    cat > "/usr/lib/tmpfiles.d/kodi-standalone.conf" << 'EOF'
d /var/lib/kodi 0750 kodi kodi - -
Z /var/lib/kodi - kodi kodi - -
f /var/lib/session-state 0644 root root - -
f /var/run/session-switch-request 0666 root root - -
EOF

    cat > "/usr/lib/sysusers.d/kodi-standalone.conf" << 'EOF'
g kodi - -
u kodi - "Kodi User" /var/lib/kodi
EOF

    systemd-sysusers

    usermod -a -G audio,video,render,input,optical kodi 2>/dev/null || true
    chage -E -1 kodi
    chage -M -1 kodi

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

Environment="HOME=/var/lib/kodi"
Restart=on-failure
RestartSec=5s
TimeoutStopSec=10

LimitNOFILE=65536

StandardInput=tty
StandardOutput=journal
StandardError=journal

[Install]
Alias=display-manager.service
EOF

    systemctl disable kodi-gbm.service 2>/dev/null || true

    log_success "kodi-gbm service installed"
}

# Main execution
main() {
    log_subsection "Installing Optimized Session Management"

    create_polkit_rule
    install_session_switch_handler
    install_session_request_scripts
    create_desktop_entries
    patch_kodi_standalone_for_gbm
    install_kodi_gbm_service

    log_success "Optimized session management installed"
    log_info ""
    log_info "Usage:"
    log_info "  - Switch to Kodi: request-kodi"
    log_info "  - Switch to Gaming: request-gamemode"
    log_info "  - From Kodi UI: run kodi-request-gamemode"
}

main "$@"
