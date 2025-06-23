#!/bin/bash
set -euo pipefail

echo "[INFO] Installing Kodi build dependencies..."

# DNF optimization
DNF_CMD="dnf -y --setopt=fastestmirror=1 --setopt=max_parallel_downloads=10"

# Core build tools
$DNF_CMD install \
    git cmake gcc gcc-c++ make ninja-build \
    autoconf automake libtool gettext gettext-devel \
    pkgconf-pkg-config nasm yasm gperf swig \
    python3-devel python3-pillow meson patch

# Kodi dependencies
$DNF_CMD install \
    alsa-lib-devel avahi-compat-libdns_sd-devel avahi-devel \
    bzip2-devel curl dbus-devel fontconfig-devel \
    freetype-devel fribidi-devel gawk giflib-devel \
    gtest-devel libao-devel libass-devel libcap-devel \
    libcdio-devel libcurl-devel libidn2-devel \
    libjpeg-turbo-devel lcms2-devel libmicrohttpd-devel \
    libmpc-devel libogg-devel libpng-devel \
    libsmbclient-devel libtool-ltdl-devel libudev-devel \
    libunistring libunistring-devel libusb1-devel \
    libuuid-devel libvorbis-devel libxkbcommon-devel \
    libxml2-devel libXmu-devel libXrandr-devel \
    libxslt-devel libXt-devel lzo-devel mariadb-devel \
    openssl-devel pcre-devel pcre2-devel \
    pulseaudio-libs-devel sqlite-devel taglib-devel \
    tinyxml-devel tinyxml2-devel trousers-devel \
    uuid-devel zlib-devel rapidjson-devel hwdata-devel

# GBM/Graphics dependencies
$DNF_CMD install \
    libinput-devel mesa-libGLES-devel mesa-libgbm-devel \
    mesa-libEGL-devel libdrm-devel

# Optional dependencies
$DNF_CMD install \
    libbluray-devel libcec-devel libnfs-devel \
    libplist-devel shairplay-devel flatbuffers-devel \
    fmt-devel fstrcmp-devel spdlog-devel || true

# Build libva from source
echo "[INFO] Building libva from source..."
cd /tmp
git clone --depth=1 https://github.com/intel/libva.git
cd libva
meson setup build --prefix=/usr --libdir=/usr/lib64 --buildtype=release
ninja -C build
ninja -C build install
ldconfig
cd /
rm -rf /tmp/libva

echo "[INFO] Dependencies installed successfully"
