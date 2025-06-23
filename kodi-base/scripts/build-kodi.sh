#!/bin/bash
set -euo pipefail

# Configuration
KODI_VERSION="Omega"
KODI_REPO="https://github.com/xbmc/xbmc"
BUILD_DIR="/tmp/kodi-build"
SOURCE_DIR="/tmp/kodi-source"

echo "[INFO] Building Kodi ${KODI_VERSION}..."

# Clone source
echo "[INFO] Cloning Kodi repository..."
git clone --depth=1 --branch="${KODI_VERSION}" "${KODI_REPO}" "${SOURCE_DIR}"

# Create build directory
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Configure
echo "[INFO] Configuring build..."
cmake "${SOURCE_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCORE_PLATFORM_NAME=gbm \
    -DAPP_RENDER_SYSTEM=gles \
    -DENABLE_VAAPI=ON \
    -DENABLE_VDPAU=OFF \
    -DENABLE_INTERNAL_FMT=ON \
    -DENABLE_INTERNAL_SPDLOG=ON \
    -DENABLE_INTERNAL_FLATBUFFERS=ON \
    -DENABLE_INTERNAL_CROSSGUID=ON \
    -DENABLE_INTERNAL_FSTRCMP=ON \
    -DENABLE_INTERNAL_FFMPEG=ON \
    -DENABLE_INTERNAL_DAV1D=ON \
    -DENABLE_UDEV=ON \
    -DCMAKE_C_FLAGS="-O2 -pipe" \
    -DCMAKE_CXX_FLAGS="-O2 -pipe"

# Build
echo "[INFO] Building Kodi (this will take a while)..."
make -j$(nproc)

# Install
echo "[INFO] Installing Kodi..."
make install

# Update library cache
ldconfig

# Cleanup build files
cd /
rm -rf "${BUILD_DIR}" "${SOURCE_DIR}"

# Verify installation
if [[ ! -x "/usr/lib64/kodi/kodi-gbm" ]]; then
    echo "[ERROR] Kodi binary not found after installation!"
    exit 1
fi

echo "[INFO] Kodi built and installed successfully"
