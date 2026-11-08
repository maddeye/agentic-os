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

source "$(dirname "$0")/debs.sh"
mkdir -p "$repo"
build_deb aos-test-hang 'while [ -e /run/aos-test-hang ]; do sleep 0.2; done'
build_deb aos-test-power 'while [ -e /run/aos-test-power ]; do sleep 0.2; done'
build_deb aos-test-service ':' usr/lib/systemd/system/aos-test-svc.service
build_deb aos-test-setuid ':'
build_deb aos-test-fails 'exit 7'
build_deb aos-test-clean ':'

build_deb aos-test-path ':' usr/lib/systemd/system/aos-test-x.path
build_deb aos-test-pinned ':'
build_deb aos-test-tamper ':'
# Version 2 cannot unpack, so the upgrade fails and version 1 stays installed.
DEB_DIR=$repo/old build_deb aos-test-upgrade ':'
DEB_VERSION=2.0 DEB_PREINST='exit 1' build_deb aos-test-upgrade ':'
dpkg -i "$repo/old/aos-test-upgrade_1.0_all.deb" >/dev/null
DEB_DIR=$repo/old DEB_DEPENDS=hello build_deb aos-test-broken ':'
index_repo
echo "deb [trusted=yes] copy:$repo ./" > /etc/apt/sources.list.d/aos-test.list
