#!/bin/bash
# Prints what the Debian kernel and systemd provide, as key<TAB>value lines. Runs as root.
set -euo pipefail
row() { printf '%s\t%s\n' "$1" "$2"; }
sysctl_row() { row "sysctl $1" "$(sysctl -n "$1" 2>/dev/null || echo absent)"; }

row "debian" "$(cat /etc/debian_version)"
row "kernel" "$(uname -r)"
row "systemd" "$(systemctl --version | sed -n '1s/^systemd //p')"
for option in USER_NS PID_NS NET_NS IPC_NS CGROUPS CGROUP_BPF PSI SECCOMP_FILTER BTRFS_FS SECURITY_LANDLOCK SECURITY_APPARMOR; do
	row "CONFIG_$option" "$(sed -n "s/^CONFIG_$option=//p" "/boot/config-$(uname -r)" | grep . || echo unset)"
done
row "active LSMs" "$(cat /sys/kernel/security/lsm)"
row "cgroup filesystem" "$(stat -fc %T /sys/fs/cgroup)"
row "cgroup controllers" "$(cat /sys/fs/cgroup/cgroup.controllers)"
for resource in cpu memory io; do
	row "PSI $resource readable" "$(test -r "/proc/pressure/$resource" && echo yes || echo no)"
done
for name in kernel.unprivileged_userns_clone user.max_user_namespaces kernel.yama.ptrace_scope \
	kernel.dmesg_restrict kernel.perf_event_paranoid kernel.unprivileged_bpf_disabled \
	fs.protected_hardlinks fs.protected_symlinks fs.protected_regular fs.protected_fifos; do
	sysctl_row "$name"
done
row "bubblewrap candidate" "$(apt-cache policy bubblewrap | sed -n 's/ *Candidate: //p')"

scratch=/var/lib/agent-os/.probe
btrfs subvolume create "$scratch" >/dev/null
btrfs subvolume create "$scratch/nested" >/dev/null
echo parent > "$scratch/in-parent"
echo nested > "$scratch/nested/in-nested"
btrfs subvolume snapshot -r "$scratch" "$scratch-snap" >/dev/null
row "btrfs snapshot keeps parent files" "$(test -f "$scratch-snap/in-parent" && echo yes || echo no)"
row "btrfs snapshot includes nested subvolume files" "$(test -f "$scratch-snap/nested/in-nested" && echo yes || echo no)"
btrfs quota enable /var/lib/agent-os
btrfs quota rescan -w /var/lib/agent-os >/dev/null
btrfs qgroup limit 16M "$scratch"
if dd if=/dev/urandom of="$scratch/big" bs=1M count=64 oflag=sync status=none 2>/dev/null; then
	row "btrfs qgroup limit enforced" no
else
	row "btrfs qgroup limit enforced" yes
fi
rm -f "$scratch/big"
btrfs quota disable /var/lib/agent-os
row "btrfs zstd compression mount" "$(mount -o remount,compress=zstd:1 /var/lib/agent-os && echo yes || echo no)"
mount -o remount,compress=no /var/lib/agent-os
btrfs subvolume delete "$scratch-snap" "$scratch/nested" "$scratch" >/dev/null
