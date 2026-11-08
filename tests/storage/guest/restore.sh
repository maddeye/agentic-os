#!/bin/bash
source "$(dirname "$0")/lib.sh"
root=$projects/alpha
uid=$(id -u aos-alpha)
agent alpha -- bash -c "mkdir -p $root/workspace/src; echo v1 > $root/workspace/src/main; echo v1 > $root/home/config; echo kept > $root/cache/entry"
good=$(agentos project snapshot alpha --label good)
max_before=$(field alpha limit.MemoryMax)

# The destructive edit.
agent alpha -- bash -c "rm -rf $root/workspace/src; echo junk > $root/workspace/junk; echo v2 > $root/home/config; ln -s /etc/shadow $root/workspace/link"
agentos project run --detach alpha -- sleep 600 >/dev/null
eq "restore needs confirmation" 2 "$(status_of agentos project restore alpha --snapshot "$good")"
eq "unconfirmed restore keeps data" junk "$(cat "$root/workspace/junk")"
eq "unconfirmed restore keeps commands" 1 "$(agentos project ps alpha | wc -l)"
eq "restore needs a snapshot" 2 "$(status_of agentos project restore alpha --yes)"
eq "restore rejects a bad id" 2 "$(status_of agentos project restore alpha --snapshot ../x --yes)"
eq "restore rejects an unknown id" 2 "$(status_of agentos project restore alpha --snapshot 20200101T000000Z-000000000 --yes)"
eq "refused restore keeps the project usable" 0 "$(status_of agent alpha -- true)"

safety=$(agentos project restore alpha --snapshot "$good" --yes)
eq "restore succeeds" 0 "$?"
eq "restored workspace" v1 "$(cat "$root/workspace/src/main")"
eq "restored home" v1 "$(cat "$root/home/config")"
eq "edit is gone" 1 "$(status_of test -e "$root/workspace/junk")"
eq "planted symlink is gone" 1 "$(status_of test -L "$root/workspace/link")"
eq "commands were stopped" 0 "$(agentos project ps alpha | wc -l)"
eq "no process survives" 1 "$(status_of pgrep -U "$uid")"
eq "restored root is a subvolume" 256 "$(inode "$root")"
eq "root ownership" "root:aos-alpha 750" "$(stat -c '%U:%G %a' "$root")"
eq "workspace is writable" 0 "$(status_of agent alpha -- touch "$root/workspace/after")"
eq "cache starts empty" 1 "$(status_of test -e "$root/cache/entry")"
eq "cache is a subvolume" 256 "$(inode "$root/cache")"
eq "cache ownership" "aos-alpha:aos-alpha 700" "$(stat -c '%U:%G %a' "$root/cache")"
eq "tmp is a subvolume" 256 "$(inode "$root/tmp")"
eq "tmp works" 0 "$(status_of agent alpha -- touch /tmp/after)"
eq "limits survive" "$max_before" "$(field alpha limit.MemoryMax)"
eq "slice is unmasked" 1 "$(status_of test -L "/etc/systemd/system/agentos-project-$uid.slice")"
eq "registry entry is back" 0 "$(status_of test -f "$registry/alpha")"
eq "no staging remains" 1 "$(status_of test -e "$snapshots/alpha/.incoming" -o -e "$snapshots/alpha/.outgoing")"
eq "other project unaffected" 0 "$(status_of agent beta -- true)"

# The limit still holds on the new subvolumes.
settle
eq "limit holds after restore" 1 "$(write_mib alpha "$root/workspace/big" 250)"
agent alpha -- rm -f "$root/workspace/big"
sync

# The automatic snapshot makes the restore reversible.
eq "pre-restore snapshot is automatic" "auto pre-restore" "$(agentos project snapshots alpha | awk -F'\t' -v id="$safety" '$1 == id { print $2, $5 }')"
agentos project restore alpha --snapshot "$safety" --yes >/dev/null
eq "restore can be undone" junk "$(cat "$root/workspace/junk")"
eq "undo brings back the edit" v2 "$(cat "$root/home/config")"
agentos project restore alpha --snapshot "$good" --yes >/dev/null

# A restore that fails at any step blocks commands and finishes when it is run again.
shim=$(mktemp -d)
real_mv=$(command -v mv)
cat > "$shim/mv" <<SHIM
#!/bin/bash
[[ "\$*" == *.incoming*$root* ]] && exit 1
exec $real_mv "\$@"
SHIM
chmod +x "$shim/mv"
agent alpha -- bash -c "echo broken > $root/workspace/broken"
other=$(agentos project snapshot alpha --label other)
eq "failure before the swap is reported" 1 "$(status_of env PATH="$shim:$PATH" agentos project restore alpha --snapshot "$good" --yes)"
eq "failed restore blocks commands" 2 "$(status_of agent alpha -- true)"
eq "failed restore hides the project" 2 "$(status_of agentos project inspect alpha)"
eq "failed restore blocks a new project with the name" 2 "$(status_of agentos project create alpha)"
eq "rerun cannot change the target" 2 "$(status_of agentos project restore alpha --snapshot "$other" --yes)"
eq "rerun finishes the restore" 0 "$(status_of agentos project restore alpha --snapshot "$good" --yes)"
eq "finished restore has the snapshot data" v1 "$(cat "$root/workspace/src/main")"
eq "finished restore dropped the edit" 1 "$(status_of test -e "$root/workspace/broken")"
eq "finished restore accepts commands" 0 "$(status_of agent alpha -- true)"
rm "$shim/mv"
printf '#!/bin/sh\nexit 1\n' > "$shim/rm"
chmod +x "$shim/rm"
agent alpha -- bash -c "echo broken > $root/workspace/broken"
eq "failure after the swap is reported" 1 "$(status_of env PATH="$shim:$PATH" agentos project restore alpha --snapshot "$good" --yes)"
eq "swap already happened" 1 "$(status_of test -e "$root/workspace/broken")"
eq "rerun removes the old tree" 0 "$(status_of agentos project restore alpha --snapshot "$good" --yes)"
eq "old tree is gone" 1 "$(status_of test -e "$snapshots/alpha/.outgoing")"
rm -r "$shim"

# Delete removes snapshots and the qgroup, also from an interrupted restore.
agentos project create gone --disk 100M >/dev/null
gone_uid=$(id -u aos-gone)
agent gone -- touch "$projects/gone/workspace/f"
gone_id=$(agentos project snapshot gone)
shim=$(mktemp -d)
cat > "$shim/mv" <<SHIM
#!/bin/bash
[[ "\$*" == *.incoming* ]] && exit 1
exec $real_mv "\$@"
SHIM
chmod +x "$shim/mv"
eq "interrupted restore for delete" 1 "$(status_of env PATH="$shim:$PATH" agentos project restore gone --snapshot "$gone_id" --yes)"
rm -r "$shim"
eq "delete finishes an interrupted restore" 0 "$(status_of agentos project delete gone --yes)"
eq "delete removes snapshots" 1 "$(status_of test -e "$snapshots/gone")"
eq "delete leaves no restore records" 0 "$(ls "$registry" | grep -c '^gone')"
eq "delete removes the qgroup" 0 "$(btrfs qgroup show --raw "$data" | awk -v q="1/$gone_uid" '$1 == q' | wc -l)"
finish
