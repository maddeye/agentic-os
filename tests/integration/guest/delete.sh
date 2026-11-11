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
agentos project link target beta 45100
agentos project link beta target 45101
target_address=$(agentos project inspect target | sed -n 's/^address=//p')
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
eq "network namespace is gone" 1 "$(status_of test -e "/run/netns/aos-$uid")"
eq "host interface is gone" 1 "$(status_of ip link show "aos-$uid")"
eq "links are gone" "FROM TO PORT alpha beta 45100" "$(agentos project links | xargs)"
eq "firewall holds no link of the project" 0 "$(nft list set inet agentos links | grep -c -e "aos-$uid" -e "$target_address ")"
eq "no file keeps the UID" 0 "$(owned_files "$uid")"
eq "symlink targets survive" "$hostname_before" "$(cat /etc/hostname)"
eq "other project data survives" kept "$(agent beta -- bash -c 'cat ~/keep')"
eq "deleted project cannot run" 2 "$(status_of agent target -- true)"
eq "delete of missing project fails" 2 "$(status_of agentos project delete target --yes)"

agentos project create target >/dev/null
new_uid=$(id -u aos-target)
eq "UID is not reused" 1 "$(( new_uid > uid ))"
eq "new project starts empty" "" "$(ls "$projects/target/workspace")"

registry=/var/lib/agent-os/metadata/projects
useradd --non-unique --uid 0 --no-create-home --shell /usr/sbin/nologin aos-evil
eq "create refuses an existing root account" 2 "$(status_of agentos project create evil)"
eq "refused create leaves no project" 1 "$(status_of test -e "$projects/evil")"
# A UID 0 alias shares PID 1, so userdel needs --force.
userdel --force aos-evil
useradd --uid 25000 --no-create-home --shell /bin/bash aos-demo
eq "create refuses an existing in-range account" 2 "$(status_of agentos project create demo)"
eq "refused create leaves the account shell" /bin/bash "$(getent passwd aos-demo | cut -d: -f7)"
userdel aos-demo

# A create that crashed after recording its UID must resume with that UID.
echo uid=26000 > "$registry/resumed.creating"
useradd --uid 26000 --user-group --no-create-home --shell /usr/sbin/nologin aos-resumed
eq "crashed create resumes" resumed "$(agentos project create resumed)"
eq "resumed create keeps its UID" 26000 "$(id -u aos-resumed)"
eq "resumed create clears its record" 1 "$(status_of test -e "$registry/resumed.creating")"
agentos project delete resumed --yes

# A failed counter write must stop the create before any account exists.
mkdir /var/lib/agent-os/metadata/next-uid.tmp
eq "create fails when the counter cannot be saved" 1 "$(status_of agentos project create nocounter)"
eq "failed counter write creates no account" 1 "$(status_of id aos-nocounter)"
rmdir /var/lib/agent-os/metadata/next-uid.tmp

# A delete that fails partway keeps its tombstone, and a rerun finishes it.
shim=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$shim/userdel"
chmod +x "$shim/userdel"
eq "delete reports a failed account removal" 1 "$(status_of env PATH="$shim:$PATH" agentos project delete target --yes)"
eq "failed delete keeps its tombstone" 0 "$(status_of test -f "$registry/target.deleting")"
eq "failed delete blocks recreation" 2 "$(status_of agentos project create target)"
eq "failed delete blocks new commands" 2 "$(status_of agent target -- true)"
rm -r "$shim"
eq "rerun finishes the delete" 0 "$(status_of agentos project delete target --yes)"
eq "finished delete removed the account" 1 "$(status_of id aos-target)"
eq "finished delete removed the tombstone" 1 "$(status_of test -e "$registry/target.deleting")"

# Commands submitted during a delete, as a paused `run` would, must not survive it.
agentos project create racer >/dev/null
uid=$(id -u aos-racer)
while :; do
	systemd-run --collect --quiet --slice="agentos-project-$uid.slice" --uid=aos-racer --gid=aos-racer -- /usr/bin/sleep 600
done >/dev/null 2>&1 &
hammer=$!
sleep 1
eq "delete wins against concurrent starts" 0 "$(status_of agentos project delete racer --yes)"
kill "$hammer"
wait "$hammer" 2>/dev/null
sleep 1
eq "no concurrent start survived" 1 "$(status_of pgrep -U "$uid")"
finish
