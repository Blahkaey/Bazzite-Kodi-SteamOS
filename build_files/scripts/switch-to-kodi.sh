#!/bin/bash
# Switch from Gaming Mode to Kodi

# Stop the current gaming session
systemctl --user stop gamescope-session-plus@steam.service 2>/dev/null || true

# Configure SDDM for Kodi session
cat > /etc/sddm.conf.d/zz-steamos-autologin.conf << EOF
[Autologin]
Session=kodi-gbm
User=kodi
EOF

# If in a graphical session, logout properly
if [[ -n "$DISPLAY" ]] || [[ -n "$WAYLAND_DISPLAY" ]]; then
    # Try to use the desktop-specific logout command
    if command -v qdbus >/dev/null 2>&1; then
        # KDE/Plasma logout
        qdbus org.kde.Shutdown /Shutdown org.kde.Shutdown.logout
    elif command -v gnome-session-quit >/dev/null 2>&1; then
        # GNOME logout
        gnome-session-quit --logout --no-prompt
    else
        # Generic logout - restart display manager
        systemctl restart sddm.service
    fi
else
    # If not in graphical session, just restart the display manager
    systemctl restart sddm.service
fi
