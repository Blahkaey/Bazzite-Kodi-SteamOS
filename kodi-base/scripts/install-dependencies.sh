#!/bin/bash
set -euo pipefail

echo "[INFO] Installing Kodi build dependencies..."

DNF_CMD="dnf5 -y --setopt=fastestmirror=1 --setopt=max_parallel_downloads=10 --setopt=install_weak_deps=0 "


$DNF_CMD install git cmake gcc gcc-c++ make ninja-build autoconf automake libtool gettext gettext-devel pkgconf-pkg-config nasm yasm gperf swig python3-devel python3-pillow meson patch alsa-lib-devel avahi-compat-libdns_sd-devel avahi-devel bzip2-devel curl dbus-devel fontconfig-devel freetype-devel fribidi-devel gawk giflib-devel gtest-devel libao-devel libass-devel libcap-devel libcdio-devel libcurl-devel libidn2-devel libjpeg-turbo-devel lcms2-devel libmicrohttpd-devel libmpc-devel libogg-devel libpng12-devel libsmbclient-devel libtool-ltdl-devel libudev-devel libunistring libunistring-devel libusb1-devel libuuid-devel libvorbis-devel libxkbcommon-devel libxml2-devel libXmu-devel libXrandr-devel libxslt-devel libXt-devel lzo-devel mariadb-devel openssl-devel pcre-devel pcre2-devel pulseaudio-libs-devel sqlite-devel taglib-devel tinyxml-devel tinyxml2-devel trousers-devel uuid-devel zlib-devel rapidjson-devel hwdata-devel libdisplay-info libdisplay-info-devel libinput-devel mesa-libGLES-devel mesa-libgbm-devel mesa-libEGL-devel libdrm-devel libbluray-devel libcec-devel libnfs-devel libplist-devel shairplay-devel flatbuffers flatbuffers-devel fmt-devel fstrcmp-devel spdlog-devel jre bluez-libs-devel bluez-libs-devel json-devel libva-devel libvdpau-devel lirc-devel mesa-libGL-devel mesa-libGLU-devel mesa-libGLw-devel mesa-libOSMesa-devel openssl-libs exiv2-devel

echo "[INFO] Dependencies installed successfully"
