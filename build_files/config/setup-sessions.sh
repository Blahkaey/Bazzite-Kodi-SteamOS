#!/bin/bash
set -euo pipefail

SCRIPT_DIR="/ctx"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logging.sh"

setup_hdr_environment() {
    log_info "Setting up HDR-specific environment..."

    ensure_dir "/etc/conf.d"

    # Environment variables specifically for HDR with GBM
    cat > "/etc/conf.d/kodi-standalone" << 'EOF'
# HDR-specific environment variables for Kodi on GBM

# Force VA-API for hardware acceleration (required for HDR)
KODI_VAAPI=1

# Force GBM backend (required for HDR)
KODI_PLATFORM=gbm

# Force GLES rendering (required for HDR passthrough)
KODI_GL_INTERFACE=gles

# Disable any X11/Wayland detection
DISPLAY=
WAYLAND_DISPLAY=

# GPU driver optimizations for HDR
MESA_LOADER_DRIVER_OVERRIDE=radeonsi
RADV_PERFTEST=gpl

# Force proper GLES context for HDR
MESA_GL_VERSION_OVERRIDE=3.3
MESA_GLES_VERSION_OVERRIDE=3.2

# Enable HDR in Mesa/Vulkan
ENABLE_HDR_WSI=1
DXVK_HDR=1

# Required for proper HDR passthrough
GAMESCOPE_NV12_COLORSPACE=k_EStreamColorspace_BT601
VKD3D_SWAPCHAIN_LATENCY_FRAMES=3

# Disable compositor bypass (can interfere with HDR)
KODI_COMPOSITOR_BYPASS=0
EOF

    log_success "HDR environment configured"
}
