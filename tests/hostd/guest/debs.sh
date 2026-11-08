# Builds the local package repository for the hostd tests. Source this file.
repo=/opt/aos-test-repo

build_deb() { # <name> <postinst body> [path to create in the package]...
	local name=$1 body=$2 version=${DEB_VERSION:-1.0} dest=${DEB_DIR:-$repo} work extra
	shift 2
	work=$(mktemp -d)
	mkdir -p "$work/DEBIAN" "$work/usr/share/$name" "$dest"
	echo "${DEB_PAYLOAD:-payload}" > "$work/usr/share/$name/file"
	cat > "$work/DEBIAN/control" <<CONTROL
Package: $name
Version: $version
Architecture: all
Maintainer: Agent OS tests <tests@agent-os.invalid>
Description: hostd test package
CONTROL
	[[ -z "${DEB_DEPENDS:-}" ]] || echo "Depends: $DEB_DEPENDS" >> "$work/DEBIAN/control"
	printf '#!/bin/sh\n%s\nexit 0\n' "$body" > "$work/DEBIAN/postinst"
	chmod 755 "$work/DEBIAN/postinst"
	if [[ -n "${DEB_PREINST:-}" ]]; then
		printf '#!/bin/sh\n%s\n' "$DEB_PREINST" > "$work/DEBIAN/preinst"
		chmod 755 "$work/DEBIAN/preinst"
	fi
	for extra in "$@"; do
		mkdir -p "$work/$(dirname "$extra")"
		echo '[Unit]' > "$work/$extra"
	done
	[[ "$name" != aos-test-setuid ]] || install -m 4755 /usr/bin/true "$work/usr/share/$name/helper"
	dpkg-deb --root-owner-group -b "$work" "$dest/${name}_${version}_all.deb" >/dev/null
	rm -rf "$work"
}

index_repo() {
	local deb
	: > "$repo/Packages"
	for deb in "$repo"/*.deb; do
		dpkg-deb -f "$deb" >> "$repo/Packages"
		printf 'Filename: ./%s\nSize: %s\nSHA256: %s\n\n' "$(basename "$deb")" "$(stat -c %s "$deb")" "$(sha256sum "$deb" | cut -d' ' -f1)" >> "$repo/Packages"
	done
}
