#!/bin/bash
# Switch from Kodi to Gaming Mode

# Get the primary user (UID 1000)
PRIMARY_USER=$(id -nu 1000)
HOME_DIR=$(getent passwd $PRIMARY_USER | cut -d: -f6)

# Configure SDDM for gaming session
cat > /etc/sddm.conf.d/zz-steamos-autologin.conf << EOF
[Autologin]
Session=gamescope-session.desktop
User=$PRIMARY_USER
EOF

# Stop Kodi if it's running
systemctl stop kodi-gbm.service 2>/dev/null || true
killall -TERM kodi.bin 2>/dev/null || true

# Restart display manager to switch sessions
systemctl restart sddm.service
