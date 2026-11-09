#!/bin/bash
# What a repair keeps. The arguments are values read before the root was destroyed.
source /opt/aos-tests/tests/integration/guest/lib.sh
alpha_uid=$1 gamma_uid=$2 snapshots=$3
as_project() { local name=$1; shift; agentos project run "$name" -- "$@"; }

eq "every project is listed" "alpha beta gamma" "$(agentos project list | tail -n +2 | cut -f1 | sort | paste -sd' ')"
eq "a project keeps its UID" "$alpha_uid" "$(id -u aos-alpha)"
eq "a selected toolchain must be installed again" 1 "$(as_project alpha node --version 2>&1 | grep -c 'selects a toolchain that is not installed')"
change=$(runuser -u agentos-system -- agentos system toolchain install node 26.13.0 --reason "repair test")
id=$(sed -n 's/^  "id": \([0-9]*\),$/\1/p' <<<"$change")
agentos system change approve "$id" >/dev/null
runuser -u agentos-system -- agentos system change apply "$id" >/dev/null
eq "the reinstalled toolchain runs" v26.13.0 "$(as_project alpha node --version 2>&1)"
eq "project data survives" kept "$(as_project alpha cat preserved 2>&1)"
eq "another project still cannot read it" 1 "$(status_of as_project beta cat /var/lib/agent-os/projects/alpha/workspace/preserved)"
eq "the memory limit survives" 1073741824 "$(systemctl show -p MemoryMax --value "agentos-project-$gamma_uid.slice")"
eq "snapshots survive" "$snapshots" "$(agentos project snapshots alpha | wc -l)"
eq "the project network returns" 0 "$(status_of as_project alpha curl -fsS -m 20 -o /dev/null https://deb.debian.org/debian/dists/trixie/Release.gpg)"
eq "the system agent owns its files" agentos-system "$(stat -c %U /var/lib/agent-os/system-agent/stale-owner)"
eq "the audit log survives" 1 "$(( $(wc -l < /var/lib/agent-os/metadata/hostd/audit.jsonl) > 3 ))"
eq "the broker answers" 0 "$(status_of agentos system status)"

id=$(agentos project snapshots alpha | awk '/image-test/ { print $1 }')
as_project alpha rm marker
agentos project restore alpha --snapshot "$id" --yes >/dev/null
eq "a snapshot from before the repair restores" private "$(as_project alpha cat marker 2>&1)"

agentos project delete gamma --yes >/dev/null
eq "delete removes the limits it kept" 1 "$(status_of test -e "/var/lib/agent-os/metadata/slices/$gamma_uid")"
agentos project create delta --disk 1G >/dev/null
eq "a new project never reuses a UID" 1 "$(( $(id -u aos-delta) > gamma_uid ))"
sync
finish
