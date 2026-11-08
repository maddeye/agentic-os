#!/bin/bash
# Prepares the project that survives the VM reset, and two crafted backups with valid checksums.
source "$(dirname "$0")/lib.sh"
agentos project create backed --disk 1G >/dev/null
agentos project delete backed --yes
root=$projects/alpha
agent alpha -- bash -c "mkdir -p $root/workspace/src; echo original > $root/workspace/src/main; echo secret > $root/home/token; chmod 600 $root/home/token; ln -s src/main $root/workspace/link; mkdir -p $root/state/agent; echo memory > $root/state/agent/log; echo gone > $root/cache/entry"
id=$(agentos project snapshot alpha --label off-host)
echo "$id" > /root/backup-snapshot
eq "project uid recorded" 1 "$(( $(id -u aos-alpha) >= 20000 ))"
id -u aos-alpha > /root/backup-uid
eq "backup refuses a terminal" 2 "$(status_of script -qec "agentos project backup alpha --snapshot $id" /dev/null)"
eq "backup rejects an unknown snapshot" 2 "$(status_of agentos project backup alpha --snapshot 20200101T000000Z-000000000)"

craft() { # <output> <uid in header> <tree owner uid>
	local work=$data/snapshots/.craft header=$(mktemp) stream=$(mktemp)
	mkdir "$work"
	btrfs -q subvolume create "$work/tree"
	chown "0:$3" "$work/tree"
	chmod 750 "$work/tree"
	install -d -o "$3" -g "$3" -m 0700 "$work/tree"/{workspace,home,state,artifacts}
	install -o 0 -g 0 -m 4755 /bin/true "$work/tree/workspace/rootshell"
	btrfs property set "$work/tree" ro true
	cat > "$header" <<HEADER
agentos-backup-1
name=crafted
uid=$2
snapshot=20261108T000000Z-000000000
kind=manual
label=x
created=2026-11-08T00:00:00Z
omitted_subvolumes=0
disk_limit_bytes=1073741824
memory_high=70%
memory_max=80%
tasks=4096
cpu=
end
HEADER
	btrfs -q send -f "$stream" "$work/tree"
	cat "$header" "$stream" > "$1"
	sha256sum "$1" | cut -c1-64 >> "$1"
	btrfs property set -f "$work/tree" ro false
	btrfs -q subvolume delete "$work/tree"
	rmdir "$work"
	rm -f "$header" "$stream"
}
craft /root/crafted.backup 28000 28000
craft /root/crafted-uid.backup 0 0
finish
