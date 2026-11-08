#!/bin/bash
# Creates the projects and a local package repository with controlled behavior.
source "$(dirname "$0")/lib.sh"
set -e
export DEBIAN_FRONTEND=noninteractive
agentos project create alpha >/dev/null
agentos project create beta >/dev/null
echo private-to-alpha > "$projects/alpha/home/secret"
chown aos-alpha:aos-alpha "$projects/alpha/home/secret"
chmod 600 "$projects/alpha/home/secret"

repo=/opt/aos-test-repo
mkdir -p "$repo"
build_deb() { # <name> <postinst body> [path to create in the package]...
	local name=$1 body=$2 work
	shift 2
	work=$(mktemp -d)
	mkdir -p "$work/DEBIAN" "$work/usr/share/$name"
	echo payload > "$work/usr/share/$name/file"
	cat > "$work/DEBIAN/control" <<CONTROL
Package: $name
Version: 1.0
Architecture: all
Maintainer: Agent OS tests <tests@agent-os.invalid>
Description: hostd test package
CONTROL
	printf '#!/bin/sh\n%s\nexit 0\n' "$body" > "$work/DEBIAN/postinst"
	chmod 755 "$work/DEBIAN/postinst"
	local extra
	for extra in "$@"; do
		mkdir -p "$work/$(dirname "$extra")"
		echo '[Service]' > "$work/$extra"
	done
	[[ "$name" != aos-test-setuid ]] || install -m 4755 /usr/bin/true "$work/usr/share/$name/helper"
	dpkg-deb --root-owner-group -b "$work" "$repo/${name}_1.0_all.deb" >/dev/null
	rm -rf "$work"
}
build_deb aos-test-hang 'while [ -e /run/aos-test-hang ]; do sleep 0.2; done'
build_deb aos-test-power 'while [ -e /run/aos-test-power ]; do sleep 0.2; done'
build_deb aos-test-service ':' usr/lib/systemd/system/aos-test-svc.service
build_deb aos-test-setuid ':'
build_deb aos-test-fails 'exit 7'
build_deb aos-test-clean ':'

: > "$repo/Packages"
for deb in "$repo"/*.deb; do
	dpkg-deb -f "$deb" >> "$repo/Packages"
	printf 'Filename: ./%s\nSize: %s\nSHA256: %s\n\n' "$(basename "$deb")" "$(stat -c %s "$deb")" "$(sha256sum "$deb" | cut -d' ' -f1)" >> "$repo/Packages"
done
echo "deb [trusted=yes] copy:$repo ./" > /etc/apt/sources.list.d/aos-test.list
