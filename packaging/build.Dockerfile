# Builds Agent OS binaries against the Debian 13 userspace that runs them.
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
ARG APT_SNAPSHOT
RUN printf 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/%s/ trixie main\n' "$APT_SNAPSHOT" > /etc/apt/sources.list \
 && rm -f /etc/apt/sources.list.d/debian.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends cargo rustc ca-certificates build-essential debhelper \
 && rm -rf /var/lib/apt/lists/*
