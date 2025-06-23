# Pre-built Kodi base image
ARG KODI_BASE_IMAGE=ghcr.io/blahkaey/kodi-base:latest

# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /

# Import pre-built Kodi
FROM ${KODI_BASE_IMAGE} AS kodi-artifacts

# Base Image
FROM ghcr.io/ublue-os/bazzite-deck:stable

# Copy pre-built Kodi binaries and files
COPY --from=kodi-artifacts /usr/lib64/kodi /usr/lib64/kodi
COPY --from=kodi-artifacts /usr/bin/kodi* /usr/bin/
COPY --from=kodi-artifacts /usr/share/kodi /usr/share/kodi
COPY --from=kodi-artifacts /usr/share/applications/*kodi* /usr/share/applications/
COPY --from=kodi-artifacts /usr/share/icons /usr/share/icons
COPY --from=kodi-artifacts /usr/share/xsessions /usr/share/xsessions
COPY --from=kodi-artifacts /runtime-deps.txt /tmp/

# Install only Kodi runtime dependencies (much faster than building)
RUN dnf -y install $(cat /tmp/runtime-deps.txt | xargs) && \
    rm /tmp/runtime-deps.txt && \
    ldconfig && \
    dnf clean all

### MODIFICATIONS
## make modifications desired in your image and install packages by modifying the build.sh script
## the following RUN directive does all the things required to run "build.sh" as recommended.

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh && \
    ostree container commit

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
