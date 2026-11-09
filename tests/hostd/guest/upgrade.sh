#!/bin/bash
# `package upgrade`: approval, the exact archives, what apt holds back, and a kill in the middle.
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/debs.sh"
export DEBIAN_FRONTEND=noninteractive
version() { dpkg-query -W -f='${Version}' "$1"; }
actions() { python3 -c 'import json,sys; print(" ".join(f"{a["target"]}:{a["kind"]}:{a["to"]}" for a in json.load(sys.stdin)))'; }
auto() { apt-mark showauto | grep -qx "$1"; }

# The failing upgrade from the packages step would otherwise join every plan below.
dpkg --purge aos-test-upgrade >/dev/null
rm -f "$repo"/aos-test-upgrade_*
for name in aos-test-up aos-test-upauto aos-test-upheld aos-test-uphang; do
	DEB_DIR=$repo/old build_deb "$name" ':'
	dpkg -i "$repo/old/${name}_1.0_all.deb" >/dev/null
done
apt-mark auto aos-test-upauto >/dev/null
DEB_VERSION=2.0 DEB_DEPENDS=aos-test-upnew build_deb aos-test-up ':'
build_deb aos-test-upnew ':'
DEB_VERSION=2.0 build_deb aos-test-upauto ':'
DEB_VERSION=2.0 DEB_DEPENDS=aos-test-missing build_deb aos-test-upheld ':'
index_repo

plan 3 package upgrade
id=$(field id <<<"$change")
eq "an upgrade waits for approval" awaiting_approval "$(field state <<<"$change")"
eq "the plan names each upgrade and each new dependency" "aos-test-up:upgrade:2.0 aos-test-upauto:upgrade:2.0 aos-test-upnew:install:1.0" "$(field impact.actions <<<"$change" | actions)"
eq "the plan names what apt kept back" '["aos-test-upheld"]' "$(field impact.kept_back <<<"$change")"
eq "the decision says what apt kept back" 1 "$(field decision.reasons <<<"$change" | grep -c 'apt kept back aos-test-upheld')"
eq "planning changes nothing" 1.0 "$(version aos-test-up)"

eq "applying before approval is refused" 1 "$(status_of hostctl_ change apply "$id")"
eq "the system agent cannot approve its own upgrade" 1 "$(status_of hostctl_ change approve "$id")"
agentos system change approve "$id" >/dev/null
# A newer version after approval must not change what applies.
DEB_VERSION=3.0 DEB_DEPENDS=aos-test-upnew build_deb aos-test-up ':'
index_repo
applied=$(hostctl_ change apply "$id")
eq "the approved upgrade applies" applied "$(field state <<<"$applied")"
eq "it is verified" True "$(field outcome.verified <<<"$applied")"
eq "the outcome says how to find the old versions" 1 "$(field outcome.recovery <<<"$applied" | grep -c 'impact.actions')"
eq "the approved version is what installed" 2.0 "$(version aos-test-up)"
installed aos-test-upnew; eq "a new dependency arrives" 0 $?
eq "a kept-back package does not move" 1.0 "$(version aos-test-upheld)"
auto aos-test-upauto; eq "an automatic package stays automatic" 0 $?
auto aos-test-upnew; eq "a new dependency is automatic" 0 $?
auto aos-test-up; eq "a manual package stays manual" 1 $?
eq "the upgrade is audited" 1 "$(audited planned '"type":"package_upgrade"')"
eq "the result is audited" 1 "$(audited finished "\"change\":$id")"
rm -f "$repo"/aos-test-up_3.0_all.deb

# A kill in the middle rolls forward, and only the approved packages move.
DEB_VERSION=2.0 build_deb aos-test-uphang 'while [ -e /run/aos-test-hang ]; do sleep 0.2; done'
index_repo
touch /run/aos-test-hang
plan 3 package upgrade
id=$(field id <<<"$change")
eq "only the new version is planned" "aos-test-uphang:upgrade:2.0" "$(field impact.actions <<<"$change" | actions)"
agentos system change approve "$id" >/dev/null
hostctl_ change apply "$id" >/dev/null 2>&1 &
client=$!
wait_for hanging; eq "the upgrade reaches the package script" 0 $?
kill_broker
wait "$client" 2>/dev/null
eq "a killed upgrade is left applying" applying "$(hostctl_ change show "$id" | field state)"
rm /run/aos-test-hang
hostctl_ recover >/dev/null
eq "a killed upgrade rolls forward" applied "$(hostctl_ change show "$id" | field state)"
eq "dpkg is consistent after recovery" True "$(hostctl_ status | field dpkg_consistent)"
eq "the upgraded version is installed" 2.0 "$(version aos-test-uphang)"

# An upgrade that leaves SSH down is not a success, even when every package moved.
systemctl stop ssh.service
plan 3 package upgrade
id=$(field id <<<"$change")
eq "nothing is left to upgrade" "" "$(field impact.actions <<<"$change" | actions)"
agentos system change approve "$id" >/dev/null
eq "a change that leaves SSH down fails" 1 "$(status_of hostctl_ change apply "$id")"
eq "the failure names the service" 1 "$(hostctl_ change show "$id" | field outcome.detail | grep -c 'ssh.service is not active')"
systemctl start ssh.service
plan 3 package upgrade
id=$(field id <<<"$change")
agentos system change approve "$id" >/dev/null
eq "an empty upgrade applies" applied "$(hostctl_ change apply "$id" | field state)"

eq "no reboot is pending at the running kernel" False "$(hostctl_ status | field reboot_required)"
touch -d '+1 day' /boot/vmlinuz-aos-test
eq "a newer kernel file asks for a reboot" True "$(hostctl_ status | field reboot_required)"
rm /boot/vmlinuz-aos-test

for name in aos-test-up aos-test-upauto aos-test-upnew aos-test-upheld aos-test-uphang; do
	dpkg --purge "$name" >/dev/null
	rm -f "$repo/${name}"_*
done
index_repo
apt-get update -q >/dev/null
finish
