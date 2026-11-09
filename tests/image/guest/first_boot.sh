#!/bin/bash
# The first boot of the built image, with an administrator enrolled.
source /opt/aos-tests/tests/integration/guest/lib.sh
work=$(mktemp -d)
active() { systemctl is-active "$1"; }
as_project() { local name=$1; shift; agentos project run "$name" -- "$@"; }

eq "the machine ID is generated" 0 "$(status_of grep -Eqx "[0-9a-f]{32}" /etc/machine-id)"
eq "the system is running with no failed unit" running "$(systemctl is-system-running --wait)"

eq "the package is configured" "ii " "$(dpkg-query -W -f="\${db:Status-Abbrev}" agentos)"
eq "every dependency is satisfied" 0 "$(status_of apt-get check)"
eq "the image has no cloud-init" 1 "$(status_of dpkg -s cloud-init)"
eq "the image has no compositor" 1 "$(status_of dpkg -s sway)"
for unit in agentos-firewall.service agentos-hostd.socket agentos-hostd-admin.socket agentos-storage.timer ssh.service; do
	eq "$unit is active" active "$(active "$unit")"
done

eq "no broker runs while idle" 1 "$(status_of pgrep -x agentos-hostd)"
eq "the broker answers" 0 "$(status_of agentos system status)"

eq "the root is on ext4" ext2/ext3 "$(stat -f -c %T /)"
eq "project data is on Btrfs" btrfs "$(stat -f -c %T /var/lib/agent-os)"
between "the data filesystem grew into the disk, in GiB" 15 16 "$(df -BG --output=size /var/lib/agent-os | tail -1 | tr -dc 0-9)"

eq "the image names no build snapshot" 0 "$(grep -c snapshot.debian.org /etc/apt/sources.list.d/debian.sources)"
eq "the live archive answers" 0 "$(status_of apt-get update -q)"

# A throwaway key is authorized for both accounts, so only the account differs.
ssh-keygen -q -t ed25519 -N "" -f "$work/key"
install -d -m 0700 /root/.ssh
cat "$work/key.pub" | tee -a /root/.ssh/authorized_keys >> /home/admin/.ssh/authorized_keys
ssh_opts=(-i "$work/key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
eq "the administrator logs in with a key" 0 "$(status_of ssh "${ssh_opts[@]}" -o BatchMode=yes admin@127.0.0.1 true)"
eq "the administrator can use sudo" 0 "$(status_of ssh "${ssh_opts[@]}" -o BatchMode=yes admin@127.0.0.1 sudo -n true)"
eq "root cannot log in, even with a key" 255 "$(status_of ssh "${ssh_opts[@]}" -o BatchMode=yes root@127.0.0.1 true)"
methods=$(ssh "${ssh_opts[@]}" -o PreferredAuthentications=password -o NumberOfPasswordPrompts=0 admin@127.0.0.1 true 2>&1 | grep -o "(.*)")
eq "the server offers only public keys" "(publickey)" "$methods"
sed -i "\|$(cut -d" " -f2 "$work/key.pub")|d" /root/.ssh/authorized_keys /home/admin/.ssh/authorized_keys

agentos project create alpha --disk 2G >/dev/null
agentos project create beta --disk 2G >/dev/null
eq "a project runs as its own account" "$(agentos project inspect alpha | sed -n "s/^uid=//p")" "$(as_project alpha id -u)"
as_project alpha bash -c 'echo private > marker'
eq "the owner reads its file" private "$(as_project alpha cat /var/lib/agent-os/projects/alpha/workspace/marker 2>&1)"
eq "another project cannot read it" 1 "$(status_of as_project beta cat /var/lib/agent-os/projects/alpha/workspace/marker)"
eq "a project resolves names and reaches the internet" 0 "$(status_of as_project alpha curl -fsS -m 20 -o /dev/null https://deb.debian.org/debian/dists/trixie/Release.gpg)"

# The catalog's Node needs libatomic, which a minimal system lacks unless the package depends on it.
change=$(runuser -u agentos-system -- agentos system toolchain install node 26.13.0 --reason "image test")
id=$(sed -n 's/^  "id": \([0-9]*\),$/\1/p' <<<"$change")
agentos system change approve "$id" >/dev/null
eq "the catalog toolchain applies" 1 "$(runuser -u agentos-system -- agentos system change apply "$id" | grep -c '^  "state": "applied"')"
agentos project toolchain alpha node 26.13.0
eq "a project runs a catalog toolchain" v26.13.0 "$(as_project alpha node --version 2>&1)"

snapshot=$(agentos project snapshot alpha --label image-test)
as_project alpha rm marker
agentos project restore alpha --snapshot "$snapshot" --yes >/dev/null
eq "a snapshot restores a deleted file" private "$(as_project alpha cat marker 2>&1)"
sync
finish
