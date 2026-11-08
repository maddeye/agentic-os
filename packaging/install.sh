#!/bin/sh
# Installs the Agent OS base onto a Debian host. Run as root from a checkout.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)

install -D -m 0755 "$repo/bin/agentos" /usr/local/sbin/agentos
install -D -m 0644 "$repo/configs/systemd/native-restricted.properties" /usr/share/agent-os/native-restricted.properties
install -D -m 0755 "$repo/bin/agentos-netns" /usr/local/sbin/agentos-netns
install -D -m 0644 "$repo/configs/nftables/agentos.nft" /usr/share/agent-os/agentos.nft
install -m 0644 "$repo/configs/systemd/agentos-project.slice" "$repo/configs/systemd/agentos-firewall.service" \
	"$repo/configs/systemd/agentos-netns@.service" /etc/systemd/system/

install -d -o root -g root -m 0711 /var/lib/agent-os /var/lib/agent-os/projects
install -d -o root -g root -m 0700 /var/lib/agent-os/metadata /var/lib/agent-os/metadata/projects /var/lib/agent-os/snapshots
install -d -o root -g root -m 0755 /opt/agent-os /opt/agent-os/toolchains
systemctl daemon-reload
systemctl enable --now agentos-firewall.service
