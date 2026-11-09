#!/bin/bash
# The package from upgrade to purge. tests/vm/deploy has already installed it.
source /opt/aos-tests/tests/integration/guest/lib.sh
export DEBIAN_FRONTEND=noninteractive
deb=$(echo /opt/aos-tests/.build/package/agentos_*.deb)
policy=/etc/agent-os/hostd-policy.json
conf=/etc/agent-os/storage.conf
connect="/usr/bin/python3 /opt/aos-tests/tests/isolation/guest/connect.py"
work=$(mktemp -d)
apt_install() { apt-get install -y -q --no-install-recommends "$@"; }
state() { dpkg-query -W -f="\${db:Status-Abbrev}" agentos; }
active() { systemctl is-active "$1"; }
hash_of() { sha256sum "$1" | cut -d" " -f1; }

eq "the package owns the CLI" agentos "$(dpkg -S /usr/sbin/agentos | cut -d: -f1)"
eq "the package owns the broker unit" agentos "$(dpkg -S /usr/lib/systemd/system/agentos-hostd.socket | cut -d: -f1)"
eq "the system agent exists" 0 "$(status_of id -u agentos-system)"
for unit in agentos-firewall.service agentos-hostd.socket agentos-hostd-admin.socket agentos-storage.timer; do
	eq "$unit is active" active "$(active "$unit")"
done
eq "the broker answers" 0 "$(status_of agentos system status)"

agentos project create alpha --disk 2G >/dev/null
uid=$(agentos project inspect alpha | sed -n "s/^uid=//p")
address=$(agentos project inspect alpha | sed -n "s/^address=//p")
listener=$(agentos project run --detach alpha -- python3 -m http.server --bind 0.0.0.0 45200)
sleep 1
eq "a project serves on its address" 0 "$(status_of $connect tcp "$address:45200")"

# Removal under a live project changes nothing.
eq "removal is refused while a project exists" 1 "$(status_of dpkg -r agentos)"
# dpkg records the selection before prerm refuses. The package stays installed.
eq "the package stays installed" "ri " "$(state)"
eq "the firewall stays after the refusal" 0 "$(status_of nft list table inet agentos)"
eq "the broker stays after the refusal" active "$(active agentos-hostd.socket)"
eq "the project still serves after the refusal" 0 "$(status_of $connect tcp "$address:45200")"

# An upgrade under a live project, with a new firewall rule and administrator edits.
dpkg-deb -R "$deb" "$work/next"
sed -i "s/^Version: .*/Version: 0.1.1/" "$work/next/DEBIAN/control"
sed -i "s/^table inet agentos {/&\n\tchain aos_upgrade_marker {\n\t}/" "$work/next/usr/share/agent-os/agentos.nft"
next=$work/agentos_0.1.1_amd64.deb
dpkg-deb -b "$work/next" "$next" >/dev/null
echo "# edited by the administrator" >> "$conf"
python3 -c "import json; p=json.load(open(\"$policy\")); p[\"automatic_packages\"]=[\"hello\"]; json.dump(p, open(\"$policy\", \"w\"))"
policy_hash=$(hash_of "$policy")
conf_hash=$(hash_of "$conf")
systemctl disable --now agentos-storage.timer >/dev/null 2>&1
qgroup() { btrfs qgroup show -re --raw /var/lib/agent-os | awk -v group="1/$uid" "\$1 == group { print \$4 }"; }
limit=$(qgroup)
main_pid=$(systemctl show -p MainPID --value "aos-run-$uid-$listener.service")
link=$(cat "/sys/class/net/aos-$uid/ifindex")
netns_since=$(systemctl show -p ActiveEnterTimestampMonotonic --value "agentos-netns@$uid.service")
eq "the marker starts absent" 1 "$(status_of nft list chain inet agentos aos_upgrade_marker)"

eq "the upgrade succeeds" 0 "$(status_of apt_install "$next")"
eq "the new version is installed" 0.1.1 "$(dpkg-query -W -f="\${Version}" agentos)"
eq "the new firewall policy is live" 0 "$(status_of nft list chain inet agentos aos_upgrade_marker)"
eq "the namespace unit did not restart" "$netns_since" "$(systemctl show -p ActiveEnterTimestampMonotonic --value "agentos-netns@$uid.service")"
eq "the veth pair survived" "$link" "$(cat "/sys/class/net/aos-$uid/ifindex")"
eq "the project process survived" "$main_pid" "$(systemctl show -p MainPID --value "aos-run-$uid-$listener.service")"
eq "the project still serves after the upgrade" 0 "$(status_of $connect tcp "$address:45200")"
eq "the policy keeps the administrator edit" "$policy_hash" "$(hash_of "$policy")"
eq "storage.conf keeps the administrator edit" "$conf_hash" "$(hash_of "$conf")"
eq "a disabled timer stays disabled" disabled "$(systemctl is-enabled agentos-storage.timer)"
eq "the project limit is unchanged" "$limit" "$(qgroup)"
systemctl enable --now agentos-storage.timer >/dev/null 2>&1

# A kill during configure, then the next run.
mkdir "$work/kill"
printf "#!/bin/sh\nkill -9 \$PPID\n" > "$work/kill/btrfs"
chmod 0755 "$work/kill/btrfs"
eq "a killed configure fails" 1 "$(status_of env PATH="$work/kill:$PATH" dpkg -i "$next")"
eq "the package records the unfinished configure" "iF " "$(state)"
eq "dpkg finishes the configure" 0 "$(status_of dpkg --configure -a)"
eq "the package is configured after the retry" "ii " "$(state)"
eq "the project still serves after the retry" 0 "$(status_of $connect tcp "$address:45200")"

# Remove keeps data and configuration, and undoes everything that runs.
agentos project delete alpha --yes >/dev/null
eq "removal succeeds with no projects" 0 "$(status_of apt-get remove -y -q agentos)"
eq "only configuration remains" "rc " "$(state)"
eq "the CLI is gone" 1 "$(status_of test -e /usr/sbin/agentos)"
eq "the units are gone" 1 "$(status_of test -e /usr/lib/systemd/system/agentos-hostd.socket)"
eq "the broker socket is closed" 1 "$(status_of test -e /run/agentos/hostd.sock)"
eq "the firewall is gone" 1 "$(status_of nft list table inet agentos)"
eq "forwarding is off" 0 "$(sysctl -n net.ipv4.ip_forward)"
eq "remove keeps the policy" "$policy_hash" "$(hash_of "$policy")"
eq "remove keeps the UID counter" 0 "$(status_of test -e /var/lib/agent-os/metadata/next-uid)"

apt_install "$deb" >/dev/null 2>&1
eq "a reinstall keeps the policy" "$policy_hash" "$(hash_of "$policy")"
eq "a reinstall opens the broker" active "$(active agentos-hostd.socket)"
agentos project create beta >/dev/null
eq "a reinstall does not reuse a UID" 1 "$(( $(agentos project inspect beta | sed -n "s/^uid=//p") > uid ))"
agentos project delete beta --yes >/dev/null

# Purge removes configuration only.
eq "purge succeeds" 0 "$(status_of apt-get purge -y -q agentos)"
eq "the package is gone" 1 "$(status_of dpkg -s agentos)"
eq "purge removes the configuration" 1 "$(status_of test -e /etc/agent-os)"
eq "purge keeps the UID counter" 0 "$(status_of test -e /var/lib/agent-os/metadata/next-uid)"

# The refusal unpacks nothing. The install after it is the control.
umount /var/lib/agent-os
eq "installing off Btrfs is refused" 1 "$(status_of dpkg -i "$deb")"
eq "the refusal unpacks nothing" 1 "$(status_of test -e /usr/sbin/agentos)"
eq "the refusal leaves no package" "in " "$(state)"
mount /var/lib/agent-os
eq "installing on Btrfs succeeds" 0 "$(status_of apt_install "$deb")"
eq "a clean install restores the default policy" 1 "$(grep -c "\"agentos\"" "$policy")"
agentos project create gamma >/dev/null
eq "a project runs after the clean install" 0 "$(status_of agentos project run gamma -- true)"
agentos project delete gamma --yes >/dev/null
finish
