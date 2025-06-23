#!/bin/bash
set -euo pipefail

echo "[INFO] Installing Kodi build dependencies..."
readonly FEDORA_41_REPO="fedora-41"
readonly FEDORA_41_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Everything/x86_64/os/"
DNF_CMD="dnf5 -y --setopt=fastestmirror=1 --setopt=max_parallel_downloads=10 --setopt=install_weak_deps=0 "

add_temp_repo() {
    local repo_name="$1"
    local repo_url="$2"

    log_info "Adding temporary repository: $repo_name"

    # Create a temporary repo file instead of using config-manager addrepo
    # This is more reliable for temporary repos in container builds
    cat > "/etc/yum.repos.d/${repo_name}.repo" << EOF
[${repo_name}]
name=Temporary ${repo_name}
baseurl=${repo_url}
enabled=1
gpgcheck=0
priority=10
EOF

    # Refresh just this repo's metadata
    $DNF_CMD makecache --repo="${repo_name}" || log_warning "Failed to refresh ${repo_name} metadata"
}

remove_temp_repo() {
    local repo_name="$1"
    log_info "Removing temporary repository: $repo_name"

    # Remove the repo file
    rm -f "/etc/yum.repos.d/${repo_name}.repo"
}



$DNF_CMD install git cmake gcc gcc-c++ make ninja-build autoconf automake libtool gettext gettext-devel pkgconf-pkg-config nasm yasm gperf swig python3-devel python3-pillow meson patch alsa-lib-devel avahi-compat-libdns_sd-devel avahi-devel bzip2-devel curl dbus-devel fontconfig-devel freetype-devel fribidi-devel gawk giflib-devel gtest-devel libao-devel libass-devel libcap-devel libcdio-devel libcurl-devel libidn2-devel libjpeg-turbo-devel lcms2-devel libmicrohttpd-devel libmpc-devel libogg-devel libpng12-devel libsmbclient-devel libtool-ltdl-devel libudev-devel libunistring libunistring-devel libusb1-devel libuuid-devel libvorbis-devel libxkbcommon-devel libxml2-devel libXmu-devel libXrandr-devel libxslt-devel libXt-devel lzo-devel mariadb-devel openssl-devel pcre-devel pcre2-devel pulseaudio-libs-devel sqlite-devel taglib-devel tinyxml-devel tinyxml2-devel trousers-devel uuid-devel zlib-devel rapidjson-devel hwdata-devel libdisplay-info libdisplay-info-devel libinput-devel mesa-libGLES-devel mesa-libgbm-devel mesa-libEGL-devel libdrm-devel libbluray-devel libcec-devel libnfs-devel libplist-devel shairplay-devel flatbuffers flatbuffers-devel fmt-devel fstrcmp-devel spdlog-devel java-11-openjdk-headless jre bluez-libs-devel bluez-libs-devel json-devel libva-devel libvdpau-devel lirc-devel mesa-libGL-devel mesa-libGLU-devel mesa-libGLw-devel mesa-libOSMesa-devel openssl-libs
add_temp_repo "$FEDORA_41_REPO" "$FEDORA_41_URL"


$DNF_CMD install -y java-11-openjdk-headless --repo "$FEDORA_41_REPO" >/dev/null 2>&1; then

remove_temp_repo "$FEDORA_41_REPO"
echo "[INFO] Dependencies installed successfully"
