# Kodi Base Image Builder
FROM registry.fedoraproject.org/fedora:40 AS builder

# Install build dependencies
COPY scripts/install-dependencies.sh /tmp/
RUN chmod +x /tmp/install-dependencies.sh && \
    /tmp/install-dependencies.sh && \
    dnf clean all

# Build Kodi
COPY scripts/build-kodi.sh /tmp/
RUN chmod +x /tmp/build-kodi.sh && \
    /tmp/build-kodi.sh

# Create runtime dependencies list
RUN dnf list --installed | grep -E "(mesa-libGL|mesa-libgbm|libva|libinput|libxkbcommon|libdrm|pulseaudio-libs)" | awk '{print $1}' > /runtime-deps.txt

# Final minimal image with just Kodi binaries
FROM scratch AS final

# Copy Kodi installation
COPY --from=builder /usr/lib64/kodi /usr/lib64/kodi
COPY --from=builder /usr/bin/kodi* /usr/bin/
COPY --from=builder /usr/share/kodi /usr/share/kodi
COPY --from=builder /usr/share/applications/*kodi* /usr/share/applications/
COPY --from=builder /usr/share/icons/hicolor/*/apps/kodi.png /usr/share/icons/hicolor/
COPY --from=builder /usr/share/xsessions/kodi* /usr/share/xsessions/
COPY --from=builder /runtime-deps.txt /

# Metadata
LABEL org.opencontainers.image.title="Kodi GBM/HDR Base"
LABEL org.opencontainers.image.description="Pre-built Kodi with GBM and HDR support"
