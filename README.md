# Bazzite-Kodi-SteamOS

A custom Bazzite OS image that integrates Kodi with Steam UI, allowing instant switching between entertainment and gaming experiences.


**IMPORTANT: This is a modified distribution of Kodi™ Media Center. It is NOT endorsed by, affiliated with, or a product of the XBMC Foundation. Kodi® is a registered trademark of the XBMC Foundation.**

**Original Kodi source:** https://github.com/xbmc/xbmc  
**Modified source:** https://github.com/Blahkaey/xbmc (Omega branch)

## Overview

This project enhances Bazzite by adding:
- **Kodi With HDR Support**: Full HDR media playback using GBM backend
- **Seamless Mode Switching**: Instant transitions between Kodi and Gaming
- **Steam UI Integration**: DeckyLoader plugin - KodiLauncher which adds a button to the main navigation menu

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
- Added HDMI content type setting to signal display to disable ALLM

## Support
- **For issues with this distribution**: https://github.com/Blahkaey/Bazzite-Kodi-SteamOS/issues
- **For general Kodi support**: https://forum.kodi.tv/

Please clearly state you're using a modified distribution when seeking help on official Kodi forums.
