#!/bin/bash
# A normal upgrade on an installed host, under a running project. The runner reboots afterward.
source /opt/aos-tests/tests/integration/guest/lib.sh
source /opt/aos-tests/tests/hostd/guest/debs.sh
repo=/opt/aos-upgrade
export DEBIAN_FRONTEND=noninteractive
as_project() { local name=$1; shift; agentos project run "$name" -- "$@"; }
uid=$(agentos project inspect alpha | sed -n 's/^uid=//p')
worker=$(agentos project run --detach alpha -- sleep 3600)
as_project alpha bash -c 'echo kept > preserved'
main_pid=$(systemctl show -p MainPID --value "aos-run-$uid-$worker.service")
snapshots=$(agentos project snapshots alpha | wc -l)
echo "$snapshots" > /root/snapshots-before

# Only the new package is on offer, so the plan does not depend on what Debian published today.
mkdir -p "$repo"
dpkg-deb -R "$(echo /opt/aos-tests/.build/package/agentos_*.deb)" "$repo/next"
sed -i "s/^Version: .*/Version: 0.1.1/" "$repo/next/DEBIAN/control"
sed -i "s/^table inet agentos {/&\n\tchain aos_upgrade_marker {\n\t}/" "$repo/next/usr/share/agent-os/agentos.nft"
dpkg-deb -b "$repo/next" "$repo/agentos_0.1.1_amd64.deb" >/dev/null
rm -rf "$repo/next"
index_repo
mv /etc/apt/sources.list.d/debian.sources /root/debian.sources
echo "deb [trusted=yes] copy:$repo ./" > /etc/apt/sources.list.d/aos-upgrade.list

rc=0
change=$(runuser -u agentos-system -- agentos system package upgrade --reason "installer test") || rc=$?
eq "the upgrade waits for the administrator" 3 "$rc"
eq "the broker's own package is flagged" 1 "$(grep -c 'agentos is a protected package' <<<"$change")"
id=$(sed -n 's/^  "id": \([0-9]*\),$/\1/p' <<<"$change")
eq "the system agent cannot approve it" 1 "$(status_of runuser -u agentos-system -- agentos system change approve "$id")"
agentos system change approve "$id" >/dev/null
eq "the approved upgrade applies" 1 "$(runuser -u agentos-system -- agentos system change apply "$id" | grep -c '^  "state": "applied"')"

eq "the new version is installed" "ii  0.1.1" "$(dpkg-query -W -f='${db:Status-Abbrev} ${Version}' agentos)"
eq "the new firewall policy is live" 0 "$(status_of nft list chain inet agentos aos_upgrade_marker)"
eq "the running project process survives" "$main_pid" "$(systemctl show -p MainPID --value "aos-run-$uid-$worker.service")"
eq "the broker still answers" 0 "$(status_of agentos system status)"
eq "no reboot is pending for a package without a kernel" 1 "$(agentos system status | grep -c '"reboot_required": false')"
sync
finish
