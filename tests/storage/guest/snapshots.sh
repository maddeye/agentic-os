#!/bin/bash
source "$(dirname "$0")/lib.sh"
root=$projects/alpha
agent alpha -- bash -c "echo w > $root/workspace/f; echo h > $root/home/f; echo s > $root/state/f; echo a > $root/artifacts/f; echo c > $root/cache/f; echo t > /tmp/f"
id=$(agentos project snapshot alpha --label before-refactor)
[[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]{9}$ ]] && report ok "snapshot prints an id" || report FAIL "snapshot prints an id" "$id"
tree=$snapshots/alpha/$id/tree
eq "listing shows the snapshot" "$id manual 0 before-refactor" "$(agentos project snapshots alpha | sed -n 2p | awk -F'\t' '{print $1, $2, $4, $5}')"
eq "inspect counts it" 1 "$(field alpha snapshots)"
for child in workspace home state artifacts; do
	eq "captures $child" 1 "$(cat "$tree/$child/f" | wc -l)"
done
eq "leaves out cache" 1 "$(status_of test -e "$tree/cache/f")"
eq "leaves out tmp" 1 "$(status_of test -e "$tree/tmp/f")"
eq "snapshot is read-only" ro=true "$(btrfs property get "$tree" ro)"
eq "snapshots stay private" 700 "$(stat -c %a "$snapshots/alpha")"
eq "project cannot see snapshots" 2 "$(status_of agent alpha -- ls "$snapshots/alpha")"
eq "rejects a bad label" 2 "$(status_of agentos project snapshot alpha --label 'a b')"
eq "rejects a bad name" 2 "$(status_of agentos project snapshot ../alpha)"
eq "rejects an unknown project" 2 "$(status_of agentos project snapshot nobody)"
eq "rejects listing a bad name" 2 "$(status_of agentos project snapshots ../alpha)"

# A snapshot works during running commands. It has the state a power loss would
# leave, so the writer replaces the file with a rename, as a careful program does.
agentos project run --detach alpha -- bash -c "while :; do date +%s%N > $root/workspace/a.new; mv $root/workspace/a.new $root/workspace/a; sleep 0.01; done" >/dev/null
sleep 1
live=$(agentos project snapshot alpha --auto --label running)
agentos project stop alpha
eq "snapshot of a busy project has data" 0 "$(status_of test -s "$snapshots/alpha/$live/tree/workspace/a")"
agentos project snapshot-delete alpha "$live" --yes

# Retention prunes only automatic snapshots, oldest first.
sed -i 's/^keep_automatic=.*/keep_automatic=2/' "$conf"
for n in 1 2 3 4; do
	automatic[n]=$(agentos project snapshot alpha --auto --label "auto-$n")
done
eq "retention keeps the newest automatic" "auto=2 manual=1 " "$(kinds alpha)"
eq "oldest automatic is gone" 1 "$(status_of test -e "$snapshots/alpha/${automatic[1]}")"
eq "newest automatic is kept" 0 "$(status_of test -e "$snapshots/alpha/${automatic[4]}/tree")"
eq "manual snapshot is kept" 0 "$(status_of test -e "$tree")"
sed -i 's/^keep_automatic=.*/keep_automatic=10/' "$conf"

# A running backup holds a shared lock on the snapshot.
flock -s "$snapshots/alpha/${automatic[4]}/meta" sleep 30 &
holder=$!
sleep 0.5
eq "delete refuses a snapshot being backed up" 2 "$(status_of agentos project snapshot-delete alpha "${automatic[4]}" --yes)"
agentos project prune alpha --keep 0 2>/dev/null
eq "prune skips a snapshot being backed up" "auto=1 manual=1 " "$(kinds alpha)"
pkill -P "$holder" sleep
wait "$holder" 2>/dev/null
agentos project prune alpha --keep 0
eq "prune removes automatic snapshots" "manual=1 " "$(kinds alpha)"
eq "prune rejects a bad count" 2 "$(status_of agentos project prune alpha --keep x)"

# An interrupted snapshot leaves work that the next one removes, and it is never listed.
mkdir "$snapshots/alpha/.new-20200101T000000Z-000000000"
btrfs -q subvolume snapshot -r "$root" "$snapshots/alpha/.new-20200101T000000Z-000000000/tree"
eq "interrupted snapshot is not listed" 1 "$(snapshot_count alpha)"
other=$(agentos project snapshot alpha)
eq "next snapshot clears interrupted work" 1 "$(status_of test -e "$snapshots/alpha/.new-20200101T000000Z-000000000")"
eq "delete needs confirmation" 2 "$(status_of agentos project snapshot-delete alpha "$other")"
eq "delete rejects an unknown id" 2 "$(status_of agentos project snapshot-delete alpha 20200101T000000Z-000000000 --yes)"
eq "delete rejects a bad id" 2 "$(status_of agentos project snapshot-delete alpha '../x' --yes)"
eq "delete removes the snapshot" 0 "$(status_of agentos project snapshot-delete alpha "$other" --yes)"
eq "one snapshot remains" 1 "$(snapshot_count alpha)"

# Subvolumes that a project creates are outside the snapshot, and the snapshot says so.
agent alpha -- bash -c "btrfs subvolume create $root/workspace/nested >/dev/null; echo inner > $root/workspace/nested/f"
warning=$(agentos project snapshot alpha --label nested 2>&1 >/dev/null)
[[ "$warning" == *"omits 1 subvolume"* ]] && report ok "snapshot warns about a nested subvolume" || report FAIL "snapshot warns about a nested subvolume" "$warning"
nested=$(agentos project snapshots alpha | awk -F'\t' '$5 == "nested" { print $1 }')
eq "listing records the omission" 1 "$(agentos project snapshots alpha | awk -F'\t' '$5 == "nested" { print $4 }')"
eq "nested contents are not captured" 1 "$(status_of test -e "$snapshots/alpha/$nested/tree/workspace/nested/f")"
agent alpha -- bash -c "rm $root/workspace/nested/f; rmdir $root/workspace/nested"
finish
