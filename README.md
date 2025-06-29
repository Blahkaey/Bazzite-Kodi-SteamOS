# Bazzite-Kodi-SteamOS

A custom Bazzite OS image that integrates Kodi with Steam UI, allowing instant switching between entertainment and gaming experiences.

## Important Notice

This is a modified distribution of Kodi™ Media Center. It is not affiliated with, endorsed by, or supported by the XBMC Foundation. Kodi® is a registered trademark of the XBMC Foundation.

## Overview

This project enhances Bazzite by adding:
- **Kodi With HDR Support**: Full HDR media playback using GBM backend
- **Seamless Mode Switching**: Instant transitions between Kodi and Gaming
- **Steam Deck Integration**: DeckyLoader plugin for easy switching from Gaming Mode

## Quick Start

### Switching Modes

**From Kodi:**
- Navigate to Favorites → "Switch To GameMode"
- Add the Favorites menu to any button in the skin for easy access

**From Gaming Mode (Steam):**
- The main navigation menu contains the kodi launch button


**From Command Line:**
```bash
# Switch to Kodi
request-kodi

# Switch to Gaming Mode
request-gamemode
```

## Modifications to Kodi

This distribution includes the following modifications to standard Kodi:
- Built with GBM platform and HDR support (custom CMake flags)
- Added HDMI content type setting for proper HDR signaling

Modified Kodi source available at: https://github.com/Blahkaey/xbmc (Omega branch)

## Support

- **For issues with this distribution**: https://github.com/Blahkaey/Bazzite-Kodi-SteamOS/issues
- **For general Kodi support**: https://forum.kodi.tv/

Please clearly state you're using a modified distribution when seeking help on official Kodi forums.
