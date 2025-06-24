# Kodi Base Image Builder
FROM registry.fedoraproject.org/fedora:42 AS builder

# Install build dependencies
COPY scripts/install-dependencies.sh /tmp/
RUN chmod +x /tmp/install-dependencies.sh && \
    /tmp/install-dependencies.sh && \
    dnf clean all

# Build Kodi
COPY scripts/build-kodi.sh /tmp/
RUN chmod +x /tmp/build-kodi.sh && \
    /tmp/build-kodi.sh

# Create runtime dependencies list using only ldd
RUN dnf install -y dnf-utils && \
    echo "Discovering runtime dependencies using ldd..." && \
    { \
        # Find all Kodi binaries and libraries
        find /usr/bin -name "kodi*" -type f -executable -print0 | \
            xargs -0 -I {} ldd {} 2>/dev/null | grep "=>" | awk '{print $3}' | sort -u; \
        find /usr/lib64/kodi -type f \( -name "*.so" -o -perm -111 \) -print0 | \
            xargs -0 -I {} ldd {} 2>/dev/null | grep "=>" | awk '{print $3}' | sort -u; \
        find /usr/share/kodi -type f -name "*.so" -print0 | \
            xargs -0 -I {} ldd {} 2>/dev/null | grep "=>" | awk '{print $3}' | sort -u; \
    } | sort -u | \
    while read lib; do \
        rpm -qf "$lib" 2>/dev/null || true; \
    done | \
    grep -v "file.*not owned" | \
    sort -u > /runtime-deps.txt && \
    echo "Found $(wc -l < /runtime-deps.txt) runtime dependencies:" && \
    cat /runtime-deps.txt


# Final minimal image with just Kodi binaries
FROM scratch AS final

# Copy Kodi installation
COPY --from=builder /usr/lib64/kodi /usr/lib64/kodi
COPY --from=builder /usr/lib/kodi /usr/lib/kodi
COPY --from=builder /usr/bin/kodi* /usr/bin/
COPY --from=builder /usr/share/kodi /usr/share/kodi
COPY --from=builder /usr/share/applications/*kodi* /usr/share/applications/
COPY --from=builder /usr/share/xsessions/*kodi* /usr/share/xsessions/
COPY --from=builder /usr/share/icons/hicolor/*/apps/kodi* /usr/share/icons/hicolor/
COPY --from=builder /usr/share/metainfo/*kodi* /usr/share/metainfo/
COPY --from=builder /usr/lib/firewalld/services/*kodi* /usr/lib/firewalld/services/

# Copy runtime dependencies list
COPY --from=builder /runtime-deps.txt /


# Metadata
LABEL org.opencontainers.image.title="Kodi GBM/HDR Base"
LABEL org.opencontainers.image.description="Pre-built Kodi with GBM and HDR support"
LABEL org.opencontainers.image.vendor="Blahkaey"
