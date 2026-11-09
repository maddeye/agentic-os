#!/bin/bash
# The installed host after the upgrade and a reboot.
source /opt/aos-tests/tests/integration/guest/lib.sh
as_project() { local name=$1; shift; agentos project run "$name" -- "$@"; }
rm /etc/apt/sources.list.d/aos-upgrade.list
mv /root/debian.sources /etc/apt/sources.list.d/debian.sources

eq "the system is running with no failed unit" running "$(systemctl is-system-running --wait)"
eq "the upgrade survives the reboot" 0.1.1 "$(dpkg-query -W -f='${Version}' agentos)"
eq "dpkg is consistent" 0 "$(status_of apt-get check)"
eq "project data survives" kept "$(as_project alpha cat preserved 2>&1)"
eq "project snapshots survive" "$(cat /root/snapshots-before)" "$(agentos project snapshots alpha | wc -l)"
eq "the project toolchain survives" v26.13.0 "$(as_project alpha node --version 2>&1)"
eq "the project network returns" 0 "$(status_of as_project alpha curl -fsS -m 20 -o /dev/null https://deb.debian.org/debian/dists/trixie/Release.gpg)"
eq "the broker still answers" 0 "$(status_of agentos system status)"
eq "the live archive answers again" 0 "$(status_of apt-get update -q)"
finish
