#!/bin/sh
# Installs the Agent OS base onto a Debian host. Run as root from a checkout.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)

install -D -m 0755 "$repo/bin/agentos" /usr/local/sbin/agentos
install -D -m 0644 "$repo/configs/systemd/native-restricted.properties" /usr/share/agent-os/native-restricted.properties
install -m 0644 "$repo/configs/systemd/agentos-project.slice" /etc/systemd/system/agentos-project.slice

install -d -o root -g root -m 0711 /var/lib/agent-os /var/lib/agent-os/projects
install -d -o root -g root -m 0700 /var/lib/agent-os/metadata /var/lib/agent-os/metadata/projects /var/lib/agent-os/snapshots
install -d -o root -g root -m 0755 /opt/agent-os /opt/agent-os/toolchains
systemctl daemon-reload
