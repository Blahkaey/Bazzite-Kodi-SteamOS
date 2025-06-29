# Bazzite-Kodi-SteamOS

A custom Bazzite OS image that seamlessly integrates Kodi with Steam's Gaming Mode. Features the KodiLauncher DeckyLoader plugin which adds a dedicated Kodi button to Steam's main navigation menu, enabling users to instantly switch between Kodi and Steam's gaming UI.

## Overview

This project enhances Bazzite by adding:
- **Kodi With HDR Support**: Full HDR media playback using GBM backend
- **Seamless Mode Switching**: Instant transitions between Kodi and Gaming
- **Steam UI Integration**: DeckyLoader plugin - [KodiLauncher](https://github.com/Blahkaey/KodiLauncher) which adds a button to the main navigation menu

## Installation

### Option 1: Install the Pre-built Image

Download and install the Bazzite-Kodi-SteamOS image directly: NOT CURRENTLY AVAILABLE

### Option 2: Switch from an Existing Universal Blue System
If you're already running a Universal Blue derived image (Bazzite, Bluefin, Aurora, etc.), you can switch to this image:

```bash
sudo bootc switch ghcr.io/blahkaey/bazzite-kodi-steamos:latest
```

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

## IMPORTANT
**This project contains a modified distribution of Kodi™ Media Center. It is NOT endorsed by, affiliated with, or a product of the XBMC Foundation. Kodi® is a registered trademark of the XBMC Foundation.**

**Original Kodi source:** https://github.com/xbmc/xbmc  
**Modified source:** https://github.com/Blahkaey/xbmc (Omega branch)


## Modifications to Kodi
This distribution includes the following modifications to standard Kodi:
- Built with GBM platform and HDR support (custom CMake flags)
- Added HDMI content type setting to signal display to disable ALLM

## Support
- **For issues with this distribution**: [Issues](https://github.com/Blahkaey/Bazzite-Kodi-SteamOS/issues)
- **For general Kodi support**: https://forum.kodi.tv/

Please clearly state you're using a modified distribution when seeking help on official Kodi forums.

## Credits

- **[Bazzite](https://github.com/ublue-os/bazzite)** - The excellent gaming focused Fedora Atomic desktop this project builds upon
- **[Universal Blue](https://universal-blue.org/)** - For creating the framework that makes custom OS images like this possible
- **[Kodi/XBMC](https://kodi.tv/)** - The amazing media center at the heart of this project
- **[DeckyLoader](https://github.com/SteamDeckHomebrew/decky-loader)** - For the plugin framework that makes the KodiLauncher possible
