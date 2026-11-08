#!/bin/sh
# Installs the Agent OS base onto a Debian host. Run as root from a checkout.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)

# The name cannot collide with a project account, which always starts with aos-.
id -u agentos-system >/dev/null 2>&1 || useradd --system --user-group --no-create-home \
	--home-dir /var/lib/agent-os/system-agent --shell /bin/bash agentos-system

install -D -m 0755 "$repo/bin/agentos" /usr/local/sbin/agentos
install -D -m 0644 "$repo/configs/systemd/native-restricted.properties" /usr/share/agent-os/native-restricted.properties
install -D -m 0755 "$repo/bin/agentos-netns" /usr/local/sbin/agentos-netns
install -D -m 0644 "$repo/configs/nftables/agentos.nft" /usr/share/agent-os/agentos.nft
install -m 0755 "$repo/.build/bin/agentos-hostd" "$repo/.build/bin/agentos-hostctl" /usr/local/sbin/
install -D -m 0644 "$repo/configs/toolchains/catalog.json" /usr/share/agent-os/toolchains.json
# The administrator owns the policy after the first install.
[ -e /etc/agent-os/hostd-policy.json ] || install -D -m 0644 "$repo/configs/policies/hostd-policy.json" /etc/agent-os/hostd-policy.json
install -m 0644 "$repo/configs/systemd/agentos-project.slice" "$repo/configs/systemd/agentos-firewall.service" \
	"$repo/configs/systemd/agentos-netns@.service" "$repo/configs/systemd/agentos-hostd.socket" \
	"$repo/configs/systemd/agentos-hostd@.service" "$repo/configs/systemd/agentos-hostd-admin.socket" \
	"$repo/configs/systemd/agentos-hostd-admin@.service" /etc/systemd/system/

install -d -o root -g root -m 0711 /var/lib/agent-os /var/lib/agent-os/projects
install -d -o root -g root -m 0700 /var/lib/agent-os/metadata /var/lib/agent-os/metadata/projects /var/lib/agent-os/snapshots \
	/var/lib/agent-os/metadata/hostd /var/lib/agent-os/metadata/hostd/changes
install -d -o agentos-system -g agentos-system -m 0700 /var/lib/agent-os/system-agent
install -d -o root -g root -m 0755 /opt/agent-os /opt/agent-os/toolchains
systemctl daemon-reload
systemctl enable --now agentos-firewall.service agentos-hostd.socket agentos-hostd-admin.socket
