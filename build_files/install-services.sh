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
# /usr/bin/session-switch-handler
#
# Session Switch Handler Daemon
# Watches for session switch requests and handles transitions cleanly
#

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

# Ensure runtime directory exists
mkdir -p /var/run
mkdir -p /var/lib

# Initialize trigger file with proper permissions
touch "$TRIGGER_FILE"
chmod 666 "$TRIGGER_FILE"
echo -n "" > "$TRIGGER_FILE"

# Initialize state file
if [[ ! -f "$STATE_FILE" ]]; then
    # Try to detect current state
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

# Function to force display wake
wake_display() {
    log_info "Waking display..."
    
    # Method 1: Force DPMS on for all connected displays
    for dpms_file in /sys/class/drm/card*/*/dpms; do
        if [[ -f "$dpms_file" ]]; then
            echo "On" > "$dpms_file" 2>/dev/null || true
        fi
    done
    
    # Method 2: Use vbetool if available (fallback)
    if command -v vbetool &>/dev/null; then
        vbetool dpms on 2>/dev/null || true
    fi
    
    # Method 3: Force a VT switch to wake the display
    local current_vt=$(fgconsole 2>/dev/null || echo "1")
    chvt 7 2>/dev/null || true
    sleep 0.1
    chvt "$current_vt" 2>/dev/null || true
}

# Function to clean up Kodi processes
cleanup_kodi() {
    log_info "Cleaning up Kodi processes..."
    
    # First try graceful termination
    pkill -TERM -f "kodi" 2>/dev/null || true
    
    # Give processes time to exit cleanly
    local count=0
    while pgrep -f "kodi" >/dev/null && [ $count -lt 10 ]; do
        sleep 0.5
        ((count++))
    done
    
    # Force kill if still running
    if pgrep -f "kodi" >/dev/null; then
        log_info "Force killing remaining Kodi processes..."
        pkill -KILL -f "kodi" 2>/dev/null || true
    fi
}

# Function to ensure DRM is ready
ensure_drm_ready() {
    log_info "Ensuring DRM is ready..."
    
    # Wait for DRM device to be accessible
    local count=0
    while [ ! -r /dev/dri/card0 ] && [ $count -lt 10 ]; do
        sleep 0.2
        ((count++))
    done
    
    # Give DRM a moment to settle
    sleep 0.5
}

# Function to switch to Kodi
switch_to_kodi() {
    log_info "Switching to Kodi HDR mode..."
    
    # Check if already in Kodi mode
    local current_state=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")
    if [[ "$current_state" == "kodi" ]] && systemctl is-active --quiet kodi-gbm.service; then
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
        
        # Wait for gamescope to fully stop
        sleep 3
    fi
    
    # Clean up any gaming processes
    pkill -f "steam" 2>/dev/null || true
    pkill -f "gamescope" 2>/dev/null || true
    
    # Clean up zombie processes
    log_info "Cleaning up zombie processes..."
    pkill -9 -f "SteamGridDB" 2>/dev/null || true
    pkill -9 -f "Kodi Launcher" 2>/dev/null || true
    
    # Ensure DRM is ready
    ensure_drm_ready
    
    # Ensure we're on TTY1
    chvt 1 2>/dev/null || true
    sleep 0.2
    
    # Wake the display BEFORE starting Kodi
    wake_display
    
    # Start Kodi
    log_info "Starting Kodi service..."
    if systemctl start kodi-gbm.service; then
        echo "kodi" > "$STATE_FILE"
        
        # Give Kodi a moment to initialize
        sleep 1
        
        # Wake display again after Kodi starts
        wake_display
        
        log_info "Successfully switched to Kodi"
        return 0
    else
        log_error "Failed to start Kodi service"
        return 1
    fi
}

# Function to switch to gaming mode
switch_to_gamemode() {
    log_info "Switching to Gaming mode..."
    
    # Check if already in gaming mode
    local current_state=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")
    if [[ "$current_state" == "gamemode" ]] && systemctl is-active --quiet sddm.service; then
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
        
        # Wait a moment for clean shutdown
        sleep 2
        
        # Force cleanup any remaining processes
        cleanup_kodi
    fi
    
    # Ensure DRM is ready
    ensure_drm_ready
    
    # Ensure we're on TTY1
    chvt 1 2>/dev/null || true
    
    # Wake display before starting SDDM
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
    # Wait for file change or timeout every 60 seconds for health check
    if inotifywait -t 60 -e modify,create "$TRIGGER_FILE" 2>/dev/null; then
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
    
    # Health check - ensure state file matches reality
    local current_state=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")
    if [[ "$current_state" == "kodi" ]] && ! systemctl is-active --quiet kodi-gbm.service; then
        log_info "State mismatch detected: state=kodi but service not running"
        echo "unknown" > "$STATE_FILE"
    elif [[ "$current_state" == "gamemode" ]] && ! systemctl is-active --quiet sddm.service; then
        log_info "State mismatch detected: state=gamemode but SDDM not running"
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

install_session_query_script() {
    log_info "Installing session query utility..."

    cat > "/usr/bin/current-session-mode" << 'EOF'
#!/bin/bash
# Query current session mode

STATE_FILE="/var/lib/session-state"
TRIGGER_FILE="/var/run/session-switch-request"

# Check system state first
if [[ -f "$STATE_FILE" ]]; then
    CURRENT=$(cat "$STATE_FILE")
    echo "Current mode: $CURRENT"
else
    # Fallback: check what's actually running
    if systemctl is-active --quiet kodi-gbm.service; then
        echo "Current mode: kodi"
    elif systemctl is-active --quiet sddm.service; then
        echo "Current mode: gamemode"
    else
        echo "Current mode: unknown"
    fi
fi

# Check for pending requests
if [[ -f "$TRIGGER_FILE" ]] && [[ -s "$TRIGGER_FILE" ]]; then
    REQUEST=$(cat "$TRIGGER_FILE" 2>/dev/null)
    if [[ -n "$REQUEST" ]]; then
        echo "Pending switch to: $REQUEST"
    fi
fi

# Show service status
echo ""
echo "Service status:"
systemctl is-active kodi-gbm.service >/dev/null 2>&1 && echo "  kodi-gbm: active" || echo "  kodi-gbm: inactive"
systemctl is-active sddm.service >/dev/null 2>&1 && echo "  sddm: active" || echo "  sddm: inactive"
systemctl is-active session-switch-handler.service >/dev/null 2>&1 && echo "  switch-handler: active" || echo "  switch-handler: inactive"
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


testing() {

        cat > "/usr/bin/diagnose-session-switch" << 'EOF'
#!/bin/bash
# /usr/bin/diagnose-session-switch
# Comprehensive diagnostic tool for session switching issues

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Diagnostic output file
DIAG_FILE="/tmp/session-switch-diagnostic-$(date +%Y%m%d-%H%M%S).log"

# Functions
log_section() {
    echo -e "\n${BLUE}==== $1 ====${NC}" | tee -a "$DIAG_FILE"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$DIAG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$DIAG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$DIAG_FILE"
}

# Start diagnostic
echo "Session Switch Diagnostic Tool" | tee "$DIAG_FILE"
echo "=============================" | tee -a "$DIAG_FILE"
echo "Date: $(date)" | tee -a "$DIAG_FILE"
echo "Diagnostic output will be saved to: $DIAG_FILE"

# Basic system info
log_section "System Information"
uname -a | tee -a "$DIAG_FILE"
echo "Current user: $(whoami)" | tee -a "$DIAG_FILE"
echo "Current TTY: $(tty 2>/dev/null || echo 'unknown')" | tee -a "$DIAG_FILE"

# Session state
log_section "Session State"
if [[ -f /var/lib/session-state ]]; then
    echo "Session state file: $(cat /var/lib/session-state)" | tee -a "$DIAG_FILE"
else
    log_warning "Session state file not found"
fi

if [[ -f /var/run/session-switch-request ]]; then
    REQUEST=$(cat /var/run/session-switch-request 2>/dev/null || echo "empty")
    echo "Pending request: '$REQUEST'" | tee -a "$DIAG_FILE"
else
    echo "No pending request" | tee -a "$DIAG_FILE"
fi

# Service status
log_section "Service Status"
for service in session-switch-handler kodi-gbm sddm gamescope-session; do
    STATUS=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")
    if [[ "$STATUS" == "active" ]]; then
        log_info "$service: $STATUS"
    else
        log_warning "$service: $STATUS"
    fi

    # Get last 5 log lines for failed services
    if [[ "$STATUS" == "failed" ]]; then
        echo "Last logs for $service:" | tee -a "$DIAG_FILE"
        journalctl -u "$service" -n 5 --no-pager 2>/dev/null | tee -a "$DIAG_FILE" || true
    fi
done

# Process check
log_section "Running Processes"
echo "Kodi processes:" | tee -a "$DIAG_FILE"
pgrep -la kodi 2>/dev/null | tee -a "$DIAG_FILE" || echo "  None found" | tee -a "$DIAG_FILE"

echo -e "\nGamescope processes:" | tee -a "$DIAG_FILE"
pgrep -la gamescope 2>/dev/null | tee -a "$DIAG_FILE" || echo "  None found" | tee -a "$DIAG_FILE"

echo -e "\nSteam processes:" | tee -a "$DIAG_FILE"
pgrep -la steam 2>/dev/null | head -5 | tee -a "$DIAG_FILE" || echo "  None found" | tee -a "$DIAG_FILE"

echo -e "\nSDDM processes:" | tee -a "$DIAG_FILE"
pgrep -la sddm 2>/dev/null | tee -a "$DIAG_FILE" || echo "  None found" | tee -a "$DIAG_FILE"

# TTY and VT information
log_section "TTY/VT State"
echo "Active VT: $(cat /sys/class/tty/tty0/active 2>/dev/null || echo 'unknown')" | tee -a "$DIAG_FILE"
echo "TTY1 processes:" | tee -a "$DIAG_FILE"
ps aux | grep -E "tty1|TTY1" | grep -v grep | tee -a "$DIAG_FILE" || echo "  None found" | tee -a "$DIAG_FILE"

# Check who owns TTY1
echo -e "\nTTY1 ownership:" | tee -a "$DIAG_FILE"
ls -la /dev/tty1 2>/dev/null | tee -a "$DIAG_FILE" || echo "  Cannot check" | tee -a "$DIAG_FILE"

# GPU/DRM information
log_section "GPU/DRM State"
echo "DRM devices:" | tee -a "$DIAG_FILE"
ls -la /dev/dri/ 2>/dev/null | tee -a "$DIAG_FILE" || echo "  Cannot list" | tee -a "$DIAG_FILE"

echo -e "\nDRM master status:" | tee -a "$DIAG_FILE"
for card in /dev/dri/card*; do
    if [[ -e "$card" ]]; then
        echo "  $card:" | tee -a "$DIAG_FILE"
        # Check if any process has it open
        lsof "$card" 2>/dev/null | head -5 | tee -a "$DIAG_FILE" || echo "    No processes found" | tee -a "$DIAG_FILE"
    fi
done

echo -e "\nGPU driver:" | tee -a "$DIAG_FILE"
lspci -k | grep -A 3 -E "VGA|3D|Display" | tee -a "$DIAG_FILE"

# Display/monitor state
log_section "Display State"
echo "Connected displays (via DRM):" | tee -a "$DIAG_FILE"
for card in /sys/class/drm/card*; do
    if [[ -d "$card" ]]; then
        CARD_NAME=$(basename "$card")
        for connector in "$card"/*-*/status; do
            if [[ -f "$connector" ]]; then
                CONN_NAME=$(basename $(dirname "$connector"))
                STATUS=$(cat "$connector" 2>/dev/null)
                echo "  $CARD_NAME/$CONN_NAME: $STATUS" | tee -a "$DIAG_FILE"
            fi
        done
    fi
done

# Check for display power management
echo -e "\nDisplay power state:" | tee -a "$DIAG_FILE"
for dpms in /sys/class/drm/card*/*/dpms; do
    if [[ -f "$dpms" ]]; then
        CONN=$(basename $(dirname "$dpms"))
        STATE=$(cat "$dpms" 2>/dev/null || echo "unknown")
        echo "  $CONN: $STATE" | tee -a "$DIAG_FILE"
    fi
done

# Session handler logs
log_section "Session Handler Logs (last 20 lines)"
journalctl -u session-switch-handler -n 20 --no-pager 2>/dev/null | tee -a "$DIAG_FILE" || \
    log_warning "Could not retrieve session handler logs"

# Kodi service logs
log_section "Kodi Service Logs (last 20 lines)"
journalctl -u kodi-gbm -n 20 --no-pager 2>/dev/null | tee -a "$DIAG_FILE" || \
    log_warning "Could not retrieve Kodi logs"

# SDDM logs
log_section "SDDM Logs (last 10 lines)"
journalctl -u sddm -n 10 --no-pager 2>/dev/null | tee -a "$DIAG_FILE" || \
    log_warning "Could not retrieve SDDM logs"

# Check for common issues
log_section "Common Issues Check"

# Check if kodi user exists and has proper groups
if id kodi &>/dev/null; then
    log_info "Kodi user exists"
    echo "  Groups: $(groups kodi)" | tee -a "$DIAG_FILE"
else
    log_error "Kodi user does not exist!"
fi

# Check if session-switch-handler is enabled
if systemctl is-enabled session-switch-handler &>/dev/null; then
    log_info "Session switch handler is enabled"
else
    log_error "Session switch handler is not enabled!"
fi

# Check permissions on key files
echo -e "\nFile permissions:" | tee -a "$DIAG_FILE"
ls -la /var/run/session-switch-request 2>/dev/null | tee -a "$DIAG_FILE" || echo "  Trigger file missing" | tee -a "$DIAG_FILE"
ls -la /var/lib/session-state 2>/dev/null | tee -a "$DIAG_FILE" || echo "  State file missing" | tee -a "$DIAG_FILE"

# Check for zombie processes
log_section "Zombie/Defunct Processes"
ZOMBIES=$(ps aux | grep -E "\<defunct\>" | grep -v grep)
if [[ -n "$ZOMBIES" ]]; then
    log_warning "Found zombie processes:"
    echo "$ZOMBIES" | tee -a "$DIAG_FILE"
else
    log_info "No zombie processes found"
fi

# Memory and resource usage
log_section "Resource Usage"
echo "Memory usage:" | tee -a "$DIAG_FILE"
free -h | tee -a "$DIAG_FILE"

echo -e "\nTop 5 CPU consumers:" | tee -a "$DIAG_FILE"
ps aux --sort=-%cpu | head -6 | tee -a "$DIAG_FILE"

# Attempt to gather timing information
log_section "Recent Session Switch Attempts"
echo "Last 10 session-related journal entries:" | tee -a "$DIAG_FILE"
journalctl -n 50 | grep -E "session-switch|kodi-gbm|sddm|gamescope|Switching to" | tail -10 | tee -a "$DIAG_FILE" || \
    echo "No recent session switch entries found" | tee -a "$DIAG_FILE"

# Test scenarios
log_section "Diagnostic Tests"

# Test 1: Can we access TTY1?
echo -n "Testing TTY1 access: " | tee -a "$DIAG_FILE"
if echo "test" > /dev/tty1 2>/dev/null; then
    log_info "SUCCESS - Can write to TTY1"
else
    log_warning "FAILED - Cannot write to TTY1"
fi

# Test 2: Is DRM master available?
echo -n "Testing DRM card0 access: " | tee -a "$DIAG_FILE"
if [[ -r /dev/dri/card0 ]]; then
    log_info "SUCCESS - Can read card0"
else
    log_warning "FAILED - Cannot read card0"
fi

# Summary and recommendations
log_section "Summary and Recommendations"

# Analyze common failure patterns
if pgrep gamescope &>/dev/null && ! pgrep kodi &>/dev/null; then
    log_warning "Gamescope is still running but Kodi is not"
    echo "  → Gamescope may not be releasing resources properly" | tee -a "$DIAG_FILE"
fi

if ! systemctl is-active --quiet session-switch-handler; then
    log_error "Session switch handler is not running!"
    echo "  → Try: sudo systemctl restart session-switch-handler" | tee -a "$DIAG_FILE"
fi

ACTIVE_VT=$(cat /sys/class/tty/tty0/active 2>/dev/null)
if [[ "$ACTIVE_VT" != "tty1" ]]; then
    log_warning "Not on TTY1 (current: $ACTIVE_VT)"
    echo "  → TTY switching may be failing" | tee -a "$DIAG_FILE"
fi

# Final message
echo -e "\n${GREEN}Diagnostic complete!${NC}"
echo "Full output saved to: $DIAG_FILE"
echo -e "\nTo share this diagnostic, run:"
echo "  cat $DIAG_FILE | nc termbin.com 9999"
EOF
    chmod +x "/usr/bin/diagnose-session-switch"




    cat > "/usr/bin/monitor-session-switch" << 'EOF'
#!/bin/bash
# /usr/bin/monitor-session-switch
# Real-time monitoring of session switch process

echo "Monitoring session switch in real-time..."
echo "Press Ctrl+C to stop"
echo "================================"

# Monitor multiple sources simultaneously
tail -f /var/log/messages \
    <(journalctl -u session-switch-handler -f 2>/dev/null) \
    <(journalctl -u kodi-gbm -f 2>/dev/null) \
    <(journalctl -u sddm -f 2>/dev/null) \
    2>/dev/null | while read line; do

    # Highlight important lines
    if echo "$line" | grep -qE "ERROR|error|failed|Failed"; then
        echo -e "\033[0;31m$line\033[0m"  # Red
    elif echo "$line" | grep -qE "Switching to|Starting|Stopping"; then
        echo -e "\033[0;34m$line\033[0m"  # Blue
    elif echo "$line" | grep -qE "Successfully|started|active"; then
        echo -e "\033[0;32m$line\033[0m"  # Green
    elif echo "$line" | grep -qE "kodi|gamescope|sddm|session-switch"; then
        echo -e "\033[1;33m$line\033[0m"  # Yellow
    else
        echo "$line"
    fi
done
EOF
    chmod +x "/usr/bin/monitor-session-switch"


}


# Main execution
main() {
    log_subsection "Session Management Service Configuration"

    create_polkit_rule
    install_session_switch_handler
    install_session_request_scripts
    create_desktop_entries
    install_session_query_script
    patch_kodi_standalone_for_gbm
    install_kodi_gbm_service
    testing





    log_success "Session management configured with file-watch handler"
    log_info "Usage:"
    log_info "  - Check status: current-session-mode"
    log_info "  - Switch to Kodi: request-kodi"
    log_info "  - Switch to Gaming: request-gamemode"
    log_info "  - From Kodi UI: run kodi-request-gamemode"
    log_info ""
    log_info "The session-switch-handler service will manage all transitions"
}

main "$@"
