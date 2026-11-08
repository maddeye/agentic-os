#!/bin/bash
source "$(dirname "$0")/lib.sh"
agent() { agentos project run "$@"; }
owned_files() { find / /var/lib/agent-os -xdev -uid "$1" -not -path '/proc/*' 2>/dev/null | wc -l; }

agentos project create target >/dev/null
uid=$(id -u aos-target)
root=$projects/target
agent target -- bash -c '
	ln -s /etc etc-link
	ln -s /etc/hostname file-link
	echo data > file
	btrfs subvolume create nested-subvolume >/dev/null
	echo data > nested-subvolume/file
	btrfs subvolume snapshot -r nested-subvolume read-only-subvolume >/dev/null
'
eq "project created a nested subvolume" "file" "$(ls "$root/workspace/nested-subvolume")"
agentos project run --detach target -- sleep 600 >/dev/null
hostname_before=$(cat /etc/hostname)
agent beta -- bash -c 'echo kept > ~/keep'

eq "delete needs confirmation" 2 "$(status_of agentos project delete target)"
eq "unconfirmed delete keeps data" data "$(cat "$root/workspace/file")"
eq "delete refuses a bad name" 2 "$(status_of agentos project delete '../beta' --yes)"

agentos project delete target --yes
eq "delete succeeds" 0 "$?"
eq "project directory is gone" 1 "$(status_of test -e "$root")"
eq "identity is gone" 2 "$(status_of getent passwd aos-target)"
eq "processes are gone" 1 "$(status_of pgrep -U "$uid")"
eq "slice is gone" 1 "$(status_of test -e "/etc/systemd/system/agentos-project-$uid.slice")"
eq "no file keeps the UID" 0 "$(owned_files "$uid")"
eq "symlink targets survive" "$hostname_before" "$(cat /etc/hostname)"
eq "other project data survives" kept "$(agent beta -- bash -c 'cat ~/keep')"
eq "deleted project cannot run" 2 "$(status_of agent target -- true)"
eq "delete of missing project fails" 2 "$(status_of agentos project delete target --yes)"

agentos project create target >/dev/null
new_uid=$(id -u aos-target)
eq "UID is not reused" 1 "$(( new_uid > uid ))"
eq "new project starts empty" "" "$(ls "$projects/target/workspace")"

useradd --non-unique --uid 0 --no-create-home --shell /usr/sbin/nologin aos-evil
eq "create refuses a user outside the UID range" 2 "$(status_of agentos project create evil)"
eq "refused create leaves no project" 1 "$(status_of test -e "$projects/evil")"
userdel aos-evil

# A delete interrupted after removing the identity must still complete.
userdel aos-target
eq "interrupted delete can finish" 0 "$(status_of agentos project delete target --yes)"
eq "interrupted delete removed the data" 1 "$(status_of test -e "$projects/target")"
finish
