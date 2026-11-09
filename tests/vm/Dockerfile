# QEMU toolbox for the test VM. Only the development machine uses this image.
# Agent OS itself has no container dependency.
# The slim image has no CA bundle, so apt uses http. apt still verifies signatures.
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
ARG APT_SNAPSHOT
RUN printf 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/%s/ trixie main\n' "$APT_SNAPSHOT" > /etc/apt/sources.list \
 && rm -f /etc/apt/sources.list.d/debian.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends qemu-system-x86 qemu-utils cloud-image-utils ovmf dosfstools mtools \
 && rm -rf /var/lib/apt/lists/*
