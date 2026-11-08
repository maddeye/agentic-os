#!/bin/bash
# Prints each configuration's cost as a Markdown table. Runs as root.
set -euo pipefail
data=/var/lib/agent-os
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
median() { sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'; }
used_mib() { sync; btrfs filesystem sync "$data"; df -BM --output=used "$data" | tail -1 | tr -dc 0-9; }
timed() { local start; start=$(now_ms); "$@" >/dev/null; echo $(( $(now_ms) - start )); }

# The corpus stands in for a source tree: text and small binaries in many files.
corpus=/root/corpus.tar
tar -cf "$corpus" -C / usr/share usr/lib/python3 usr/include 2>/dev/null || true
files=$(tar -tf "$corpus" | wc -l)
mib=$(( $(stat -c %s "$corpus") / 1048576 ))

measure() { # <label>
	local work=$data/bench before after unpack compile rand
	mkdir "$work"
	before=$(used_mib)
	unpack=$( for _ in 1 2 3; do
		rm -rf "$work/tree"
		mkdir "$work/tree"
		sync
		timed tar -xf "$corpus" -C "$work/tree"
	done | median )
	sync
	after=$(used_mib)
	compile=$( for _ in 1 2 3; do
		timed find "$work/tree" -type f -name '*.py' -exec sh -c 'for f; do cp "$f" "$f.copy"; rm "$f.copy"; done' sh {} +
	done | median )
	rand=$( for _ in 1 2 3; do
		timed dd if=/dev/urandom of="$work/rand" bs=1M count=256 oflag=direct status=none
		rm -f "$work/rand"
	done | median )
	printf '| %s | %s | %s | %s | %s |\n' "$1" "$unpack" "$compile" "$rand" "$(( after - before ))"
	rm -rf "$work"
	sync
	btrfs subvolume sync "$data" >/dev/null 2>&1 || true
}

echo "Corpus: $files entries, $mib MiB"
echo
echo "| Configuration | Unpack (ms) | Copy and remove .py files (ms) | 256 MiB random, direct (ms) | Corpus on disk (MiB) |"
echo "|---|---|---|---|---|"
btrfs quota disable "$data"
measure "No quota, no compression"
btrfs quota enable "$data"
btrfs quota rescan -w "$data" >/dev/null
measure "Quota, no compression"
mount -o remount,compress=zstd:1 "$data"
measure "Quota, zstd:1"
btrfs quota disable "$data"
measure "No quota, zstd:1"
mount -o remount,compress=no "$data"
btrfs quota enable "$data"
btrfs quota rescan -w "$data" >/dev/null

echo
agentos project create bench >/dev/null
root=$data/projects/bench
tar -xf "$corpus" -C "$root/workspace" --no-same-owner
chown -R aos-bench:aos-bench "$root/workspace"
sync
snapshot_ms=$( for _ in 1 2 3 4 5; do
	timed agentos project snapshot bench
done | median )
id=$(agentos project snapshots bench | sed -n 2p | cut -f1)
restore_ms=$( for _ in 1 2 3; do
	timed agentos project restore bench --snapshot "$id" --yes
done | median )
sync
backup_ms=$(timed bash -c "agentos project backup bench --snapshot $id > /root/bench.backup")
echo "| Operation on the corpus | Median (ms) |"
echo "|---|---|"
echo "| Snapshot | $snapshot_ms |"
echo "| Restore, including the pre-restore snapshot | $restore_ms |"
echo "| Backup to a file, $(( $(stat -c %s /root/bench.backup) / 1048576 )) MiB | $backup_ms |"
