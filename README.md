# Bazzite-Kodi-SteamOS

A custom Bazzite OS image that seamlessly integrates Kodi HDR media center with SteamOS gaming mode, allowing instant switching between entertainment and gaming experiences.

## 🎮 Overview

This project enhances Bazzite (a SteamOS-like Linux distribution) by adding:
- **Kodi HDR Support**: Full HDR media playback using GBM backend
- **Seamless Mode Switching**: Instant transitions between Kodi and Gaming modes
- **Steam Deck Integration**: DeckyLoader plugin for easy switching from Gaming Mode

## 🚀 Quick Start

### Switching Modes

**From Kodi:**
- Navigate to Favorites → "Switch To GameMode"
- Add the Favorites menu to any button in the skin for easy access

**From Gaming Mode (Steam):**
- The main navigation menu containts the kodi launch button


**From Command Line:**
```bash
# Switch to Kodi
request-kodi

# Switch to Gaming Mode
request-gamemode
```

## 🙏 Acknowledgments

- Bazzite team for the excellent gaming-focused distribution
- Kodi team for GBM/HDR implementation
- DeckyLoader community for the plugin framework
