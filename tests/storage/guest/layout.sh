#!/bin/bash
source "$(dirname "$0")/lib.sh"
# The other steps stop the timer when they need a fixed sequence of checks.
eq "timer is active" active "$(systemctl is-active agentos-storage.timer)"
eq "create alpha" alpha "$(agentos project create alpha --disk 200M)"
eq "create beta" beta "$(agentos project create beta)"
root=$projects/alpha
eq "project root is a subvolume" 256 "$(inode "$root")"
eq "cache is a subvolume" 256 "$(inode "$root/cache")"
eq "tmp is a subvolume" 256 "$(inode "$root/tmp")"
for child in workspace home state artifacts; do
	eq "$child stays in the project subvolume" 1 "$(( $(inode "$root/$child") != 256 ))"
done
eq "disk limit recorded" 209715200 "$(field alpha disk_limit_bytes)"
total=$(( $(stat -f -c '%b * %S' "$data") ))
eq "default disk limit is 80%" $(( total * 80 / 100 )) "$(field beta disk_limit_bytes)"
eq "rejects a bad disk size" 2 "$(status_of agentos project create x2 --disk '1G; rm')"
eq "no snapshots yet" 0 "$(field alpha snapshots)"

# The limit covers all of the project's subvolumes together.
eq "write inside the limit" 0 "$(write_mib alpha "$root/workspace/one" 120)"
sync
eq "cache counts against the same limit" 1 "$(write_mib alpha "$root/cache/two" 120)"
agent alpha -- rm -f "$root/cache/two"
sync
between "used bytes are reported" 125000000 135000000 "$(field alpha disk_used_bytes)"
eq "another project is not limited" 0 "$(write_mib beta "$projects/beta/workspace/big" 250)"
agent beta -- rm -f "$projects/beta/workspace/big"
eq "project cannot raise its limit" 1 "$(status_of agent alpha -- btrfs qgroup limit none "1/$(id -u aos-alpha)" "$root")"
agent alpha -- rm -f "$root/workspace/one"
sync

# A subvolume that a project creates starts outside the limit, until the check enrolls it.
systemctl stop agentos-storage.timer
agent alpha -- btrfs subvolume create "$root/workspace/escape" >/dev/null
eq "new subvolume starts outside the limit" 0 "$(write_mib alpha "$root/workspace/escape/a" 250)"
agentos project snapshot alpha --label probe >/dev/null 2>&1
sync
agentos storage check >/dev/null
eq "enrolled subvolume is over the limit" 1 "$(write_mib alpha "$root/workspace/escape/b" 20)"
agent alpha -- rm -rf "$root/workspace/escape/a"
sync
agent alpha -- rmdir "$root/workspace/escape"
agentos project snapshot-delete alpha "$(agentos project snapshots alpha | sed -n 2p | cut -f1)" --yes

# A newline in a subvolume name can forge a line of `btrfs subvolume list`.
beta_id=$(btrfs inspect-internal rootid "$projects/beta/workspace")
forged=$'x\nID '$beta_id$' gen 1 top level 5 path y'
agent alpha -- btrfs subvolume create "$root/workspace/$forged" >/dev/null
sync
agentos storage check >/dev/null
parents=$(btrfs qgroup show -F -p --raw "$projects/beta" 2>/dev/null | awk -v q="0/$beta_id" '$1 == q { print $4 }')
eq "forged name cannot enroll another project" "1/$(id -u aos-beta)" "$parents"
agent alpha -- rmdir "$root/workspace/$forged"
systemctl start agentos-storage.timer
finish
