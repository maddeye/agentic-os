# Helpers shared by the storage steps. Source this file.
source /opt/aos-tests/tests/integration/guest/lib.sh
snapshots=/var/lib/agent-os/snapshots
registry=/var/lib/agent-os/metadata/projects
data=/var/lib/agent-os
conf=/etc/agent-os/storage.conf
agent() { agentos project run "$@"; }
inode() { stat -c %i "$1"; }
field() { # <name> <key> from agentos project inspect
	agentos project inspect "$1" | sed -n "s/^$2=//p"
}
snapshot_count() { # <name>
	agentos project snapshots "$1" | tail -n +2 | wc -l
}
kinds() { # <name>
	agentos project snapshots "$1" | tail -n +2 | cut -f2 | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}'
}
write_mib() { # <project> <path> <MiB>, prints the exit status
	agent "$1" -- dd if=/dev/urandom of="$2" bs=1M count="$3" status=none >/dev/null 2>&1
	echo $?
}
settle() { sync; btrfs quota rescan -w "$data" >/dev/null 2>&1; }
