# Debian baseline reference

`tests/vm/baseline` generates this file. Do not edit it by hand.

The values describe the unmodified test VM. Later phases compare against them.

- Image: `debian-13-generic-amd64-20261103-2651.qcow2`
- APT snapshot: `20261103T000000Z`
- VM: 4 vCPU, 4 GiB RAM, virtio disks, KVM, QEMU `10.0.13`
- Development machine: Intel(R) Core(TM) i9-10900K CPU @ 3.70GHz, Linux 7.3.1-1-cachyos

## Measured capabilities

| Capability | Value |
|---|---|
| debian | `13.7` |
| kernel | `6.12.115+deb13.1-amd64` |
| systemd | `257 (257.13-1~deb13u1)` |
| CONFIG_USER_NS | `y` |
| CONFIG_PID_NS | `y` |
| CONFIG_NET_NS | `y` |
| CONFIG_IPC_NS | `y` |
| CONFIG_CGROUPS | `y` |
| CONFIG_CGROUP_BPF | `y` |
| CONFIG_PSI | `y` |
| CONFIG_SECCOMP_FILTER | `y` |
| CONFIG_BTRFS_FS | `m` |
| CONFIG_SECURITY_LANDLOCK | `y` |
| CONFIG_SECURITY_APPARMOR | `y` |
| active LSMs | `lockdown,capability,landlock,yama,apparmor,tomoyo,bpf,ipe,ima,evm` |
| cgroup filesystem | `cgroup2fs` |
| cgroup controllers | `cpuset cpu io memory hugetlb pids rdma misc` |
| PSI cpu readable | `yes` |
| PSI memory readable | `yes` |
| PSI io readable | `yes` |
| sysctl kernel.unprivileged_userns_clone | `1` |
| sysctl user.max_user_namespaces | `15512` |
| sysctl kernel.yama.ptrace_scope | `0` |
| sysctl kernel.dmesg_restrict | `1` |
| sysctl kernel.perf_event_paranoid | `3` |
| sysctl kernel.unprivileged_bpf_disabled | `2` |
| sysctl fs.protected_hardlinks | `1` |
| sysctl fs.protected_symlinks | `1` |
| sysctl fs.protected_regular | `2` |
| sysctl fs.protected_fifos | `1` |
| bubblewrap candidate | `0.12.0-1~deb13u1` |
| btrfs snapshot keeps parent files | `yes` |
| btrfs snapshot includes nested subvolume files | `no` |
| btrfs qgroup limit enforced | `yes` |
| btrfs zstd compression mount | `yes` |

## Benchmarks over 3 fresh boots

Treat disk and CPU numbers as relative. They depend on the development machine.

| Metric | Median | Min | Max |
|---|---|---|---|
| Boot, kernel (s) | 2.303 | 2.275 | 2.330 |
| Boot, userspace (s) | 1.815 | 1.724 | 1.839 |
| Idle CPU, all vCPUs (%) | 0.01 | 0.00 | 0.01 |
| Idle memory used (MiB) | 305 | 304 | 314 |
| Processes at idle | 147 | 146 | 148 |
| Root disk used (MiB) | 795 | 795 | 795 |
| No-op unit, plain (ms) | 13 | 13 | 14 |
| No-op command, agentos project run (ms) | 51 | 50 | 52 |
| SHA-256, one core (MiB/s) | 603 | 602 | 607 |
| Direct write, ext4 root (MiB/s) | 461 | 442 | 469 |
| Direct write, Btrfs data (MiB/s) | 119 | 87 | 123 |
