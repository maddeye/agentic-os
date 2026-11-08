#!/bin/bash
# Proves the exit criterion on a VM that has never seen this project.
source "$(dirname "$0")/lib.sh"
id=$1
root=$projects/alpha
uid=$(id -u aos-alpha)
eq "recovered workspace" original "$(cat "$root/workspace/src/main")"
eq "recovered secret" secret "$(cat "$root/home/token")"
eq "recovered mode" "aos-alpha 600" "$(stat -c '%U %a' "$root/home/token")"
eq "recovered symlink" src/main "$(readlink "$root/workspace/link")"
eq "recovered state" memory "$(cat "$root/state/agent/log")"
eq "cache is not in the backup" 1 "$(status_of test -e "$root/cache/entry")"
eq "root ownership" "root:aos-alpha 750" "$(stat -c '%U:%G %a' "$root")"
eq "root is a subvolume" 256 "$(inode "$root")"
eq "cache is a subvolume" 256 "$(inode "$root/cache")"
eq "runs as the project" aos-alpha "$(agent alpha -- id -un)"
eq "project can read its data" original "$(agent alpha -- cat "$root/workspace/src/main")"
eq "project can write" 0 "$(status_of agent alpha -- touch "$root/workspace/after")"
eq "disk limit is recovered" 209715200 "$(field alpha disk_limit_bytes)"
eq "backup snapshot is listed" "$id" "$(agentos project snapshots alpha | sed -n 2p | cut -f1)"
eq "label is recovered" off-host "$(agentos project snapshots alpha | sed -n 2p | cut -f5)"
settle
eq "disk limit is enforced" 1 "$(write_mib alpha "$root/workspace/big" 250)"
agent alpha -- rm -f "$root/workspace/big"
sync
agentos project create fresh >/dev/null
eq "UID is not reused after recovery" 1 "$(( $(id -u aos-fresh) > uid ))"
agent alpha -- rm -f "$root/workspace/src/main"
agentos project restore alpha --snapshot "$id" --yes >/dev/null
eq "recovered snapshot restores locally" original "$(cat "$root/workspace/src/main")"
finish
