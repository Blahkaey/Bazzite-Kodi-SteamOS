# Bazzite-Kodi-SteamOS

A custom Bazzite OS image that seamlessly integrates Kodi HDR media center with SteamOS gaming mode, allowing instant switching between entertainment and gaming experiences.

## 🎮 Overview

This project enhances Bazzite (a SteamOS-like Linux distribution) by adding:
- **Kodi HDR Support**: Full HDR10 media playback using GBM/DRM backend
- **Seamless Mode Switching**: Instant transitions between Kodi and Gaming modes
- **Unified Experience**: Single system for both media consumption and gaming
- **Steam Deck Integration**: DeckyLoader plugin for easy switching from Gaming Mode

## ✨ Features

- **HDR Media Playback**: Native HDR support through Kodi's GBM implementation
- **Zero-Downtime Switching**: Clean session transitions without system restarts
- **Crash Protection**: Automatic recovery with intelligent restart limits
- **Multiple Switch Methods**:
  - Command line tools
  - Kodi favorites menu integration
  - DeckyLoader plugin for Steam UI
- **Display Management**: Automatic display wake and VT switching
- **Process Safety**: Graceful shutdown with fallback mechanisms
- **First-Boot Setup**: Automatic configuration and plugin installation

## 🚀 Quick Start

### Switching Modes

**From Command Line:**
```bash
# Switch to Kodi
request-kodi

# Switch to Gaming Mode
request-gamemode
```

**From Kodi:**
- Navigate to Favorites → "Switch To GameMode"

**From Gaming Mode (Steam):**
- Use the KodiLauncher DeckyLoader plugin

## 🏗️ Architecture

### Core Components

1. **Session Switch Handler** (`session-switch-handler`)
   - Background daemon monitoring mode change requests
   - Manages service transitions and process cleanup
   - Handles display initialization and wake sequences

2. **Kodi GBM Service** (`kodi-gbm.service`)
   - Runs Kodi with direct DRM/KMS access for HDR
   - Configured for TTY1 with proper device permissions
   - Auto-restart capability with crash detection

3. **Mode Request System**
   - File-based IPC using `/var/run/session-switch-request`
   - Atomic operations with file locking
   - State tracking in `/var/lib/session-state`

### Session Flow

```
Gaming Mode (SDDM/Gamescope)
    ↓ request-kodi
[Session Handler] → Stop SDDM → Cleanup → Wake Display → Start Kodi
    ↓ kodi-request-gamemode
[Session Handler] → Stop Kodi → Cleanup → Start SDDM → Gaming Mode
```

## 📁 File Structure

```
/usr/bin/
├── session-switch-handler      # Main daemon
├── request-kodi               # CLI: switch to Kodi
├── request-gamemode           # CLI: switch to gaming
├── kodi-request-gamemode      # Called from Kodi UI
├── kodi-standalone            # Enhanced Kodi launcher
└── first-boot-setup           # Initial configuration

/usr/lib/systemd/system/
├── session-switch-handler.service
├── kodi-gbm.service
└── kodi-firstboot.service

/usr/share/polkit-1/rules.d/
└── 49-kodi-switching.rules    # Permission management

/var/lib/kodi/.kodi/
├── userdata/favourites.xml    # Kodi shortcuts
└── userdata/scripts/          # Python switching script
```

## 🔧 Technical Details

### Display Management
- Uses VT switching for display pipeline initialization
- DPMS control via `modetest` for reliable wake
- Tracks initialization state to optimize subsequent switches

### Process Management
- Graceful SIGTERM with 200ms grace period
- SIGKILL fallback for stuck processes
- Service state verification before transitions

### HDR Configuration
- Direct DRM/KMS access through GBM backend
- Proper udev rules for DMA heap access
- Hardware acceleration support

### Security
- Polkit rules for passwordless service management (wheel group)
- Kodi user with minimal privileges
- Proper device access through udev tagging

## 🛠️ Troubleshooting

### Kodi Won't Start
```bash
# Check service status
systemctl status kodi-gbm.service

# View logs
journalctl -u kodi-gbm.service -n 50

# Reset failed state
systemctl reset-failed kodi-gbm.service
```

### Switching Fails
```bash
# Check handler logs
journalctl -u session-switch-handler -f

# Verify state file
cat /var/lib/session-state

# Clear lock if stuck
rm -f /var/run/session-switch.lock
```

### Display Issues
```bash
# Force display wake
modetest -c  # Check connected displays

# Reset VT state
rm -f /var/run/display-vt-initialized
```

## 🔍 Advanced Usage

### Manual Service Control
```bash
# Stop all services
systemctl stop session-switch-handler kodi-gbm sddm

# Start specific mode
systemctl start kodi-gbm.service  # Kodi mode
systemctl start sddm.service       # Gaming mode
```

### State Management
```bash
# Check current mode
cat /var/lib/session-state

# Monitor switch requests
tail -f /var/run/session-switch-request
```

## 📋 Requirements

- Bazzite OS (or similar Fedora-based gaming distribution)
- GPU with HDR support
- Kodi compiled with GBM support
- systemd-based init system

## 🤝 Contributing

Contributions are welcome! Please consider:
- Testing on different hardware configurations
- Improving error handling and recovery
- Adding new switching methods
- Enhancing HDR profile management

## 📝 License

[Specify your license here]

## 🙏 Acknowledgments

- Bazzite team for the excellent gaming-focused distribution
- Kodi team for GBM/HDR implementation
- DeckyLoader community for the plugin framework
