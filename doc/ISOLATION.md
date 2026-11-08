# Native isolation design

Status: implemented by [`agentos`](CLI.md) for the `native-restricted` profile. The [test suites](TEST_PLAN.md) pass on Debian 13.7 with systemd 257.

[The threat model](THREAT_MODEL.md) records why each control exists.

## Execution model

Each project command runs as a transient systemd **system** service named `aos-run-UID-ID.service`, started with `systemd-run --uid=aos-NAME`. The service joins the slice `agentos-project-UID.slice`.

Use system services instead of user services, because systemd limits filesystem restrictions in user-managed units. A system service also survives SSH disconnects without `loginctl enable-linger`.

Resource limits belong on the slice, so that they cover all of a project's commands together. Unit names use the UID because a hyphen in a slice name means a parent slice, and project names can contain hyphens.

The hyphens in `agentos-project-UID.slice` make every project a child of `agentos-project.slice`. That parent caps all projects together at 85% of RAM and 16384 tasks, which keeps capacity for SSH and host services.

Sandbox settings have one source, [`configs/systemd/native-restricted.properties`](../configs/systemd/native-restricted.properties).

Bubblewrap is not part of this profile. systemd already builds the namespaces, so a second tool would duplicate them.

## Project identity

| Property | Value |
|---|---|
| User and group name | `aos-NAME` |
| UID and GID | Equal, allocated from 20000 to 29999 |
| Login shell | `/usr/sbin/nologin` |
| Password | None |
| Supplementary groups | None |

The range stays inside Debian's normal user range (`UID_MIN` 1000, `UID_MAX` 60000), and away from accounts that `adduser` allocates from 1000. It also stays below `SUB_UID_MIN` (100000), so a project UID cannot fall inside the subordinate range of a future rootless container.

`agentos` allocates UIDs from `metadata/next-uid` and never reuses a value. It records each allocation in `metadata/projects/NAME.creating` before it creates the account. Only a create with that record can resume, so `agentos` never adopts an unrelated `aos-NAME` account. Snapshots and backups can outlive a project, and a reused UID would own the old project's restored files.

Limit `NAME` to 28 characters so that `aos-NAME` fits the 32-character Linux user name limit.

## Project network

Each project has one network namespace, `/run/netns/aos-UID`, shared by all of its commands. `agentos-netns@UID.service` creates it on first use and again after a reboot. Commands in one project reach each other on `127.0.0.1`. Projects cannot reach each other's loopback ports or abstract sockets.

Each project owns one `/30` in `10.213.0.0/16`, calculated from its UID. The host side of the `veth` pair is `.1`, and the project is `.2`. `agentos project inspect` prints the project address.

[`configs/nftables/agentos.nft`](../configs/nftables/agentos.nft) applies this policy to IPv4 and IPv6:

| Traffic | Result |
|---|---|
| Project to the internet or LAN | Allowed, with masquerade |
| Project to another project | Dropped |
| Project to any host address | Dropped |
| Host to a project port | Allowed |
| Internet or LAN to a project | Dropped |
| Forwarding unrelated to projects | Dropped |

The firewall unit turns on `net.ipv4.ip_forward` after it loads the policy. The last rule keeps the host from acting as a router. A host that must also route other traffic, for example for rootful Docker, needs a changed policy.

Projects have no IPv6 route. DNS uses the upstream servers in `/run/systemd/resolve/resolv.conf`, because the `systemd-resolved` stub listens on the host's loopback.

## Filesystem layout

| Path | Owner | Mode | Purpose |
|---|---|---|---|
| `/opt/agent-os/toolchains` | `root:root` | `0755` | Shared toolchains, read-only to projects |
| `/var/lib/agent-os` | `root:root` | `0711` | Btrfs mount point, no listing for projects |
| `/var/lib/agent-os/metadata` | `root:root` | `0700` | Project definitions, `hostd` changes and audit log |
| `/var/lib/agent-os/system-agent` | `agentos-system` | `0700` | System agent home |
| `/var/lib/agent-os/snapshots` | `root:root` | `0700` | Managed snapshots |
| `/var/lib/agent-os/projects` | `root:root` | `0711` | Project parent, no listing for projects |
| `projects/NAME` | `root:aos-NAME` | `0750` | Project root, a Btrfs subvolume |
| `projects/NAME/workspace` | `aos-NAME` | `0700` | Repository checkout, default working directory |
| `projects/NAME/home` | `aos-NAME` | `0700` | `HOME` and project-local tools |
| `projects/NAME/cache` | `aos-NAME` | `0700` | `XDG_CACHE_HOME`, private package caches, a nested subvolume |
| `projects/NAME/state` | `aos-NAME` | `0700` | `XDG_STATE_HOME`, agent state |
| `projects/NAME/artifacts` | `aos-NAME` | `0700` | GUI captures and test output. `artifacts/gui/` is described in [GUI.md](GUI.md). |
| `projects/NAME/tmp` | `aos-NAME` | `0700` | Bound over `/tmp` and `/var/tmp`, a nested subvolume |

Root owns `projects/NAME` so that a project cannot replace `workspace` with a symlink. `tmp` is an addition to the architecture layout. Commands in one project share `/tmp` through it, which a per-unit `PrivateTmp=` would prevent.

[STORAGE.md](STORAGE.md) describes subvolumes, snapshots, quotas, and backups.

## Sandbox settings

"Sole control" means that removing the setting made the suite fail, so no other layer covers that behavior.

| Group | Settings | Result | Removal test (2026-11-08) |
|---|---|---|---|
| Privilege | `NoNewPrivileges`, empty `CapabilityBoundingSet`, `RestrictSUIDSGID` | Setuid binaries do not raise privilege. | `NoNewPrivileges`: sole control for `setuid_binary` |
| Host paths | `ProtectSystem=strict`, `ProtectHome=yes` | System paths are read-only and homes are hidden. | Not run |
| Agent OS state | `TemporaryFileSystem=/var/lib/agent-os:ro`, `BindPaths=@ROOT@` | Other projects are absent from the mount namespace. | Suite still passes because file modes also block access. This layer is defense in depth. |
| Temporary storage | `BindPaths=@ROOT@/tmp:/tmp` and `/var/tmp` | Each project has its own temporary directories. | Holder fails to start, and the suite reports the failure |
| Shared memory | `TemporaryFileSystem=/dev/shm:mode=1777` | Each unit has a private `/dev/shm`. | Sole control for `dev_shm_cross`. `PrivateDevices` does not isolate `/dev/shm`. |
| IPC | `PrivateIPC=yes` | SysV IPC and POSIX queues are private. | Sole control for `sysv_shm_cross` and `mqueue_cross` |
| Runtime sockets | `TemporaryFileSystem=/run`, `BindReadOnlyPaths=-/run/systemd/resolve` | D-Bus, `hostd`, and host sockets are absent, and DNS still works. | Sole control for `system_bus` |
| Processes | `ProtectProc=invisible` | Other users' processes are hidden. | Sole control for `proc_visible` and `proc_cmdline` |
| Network | `NetworkNamespacePath`, `Requires`, `After` | Each project has its own interfaces and loopback. | Sole control for `abstract_socket`, `loopback_tcp`, `host_loopback_ssh`, and `host_uplink_ssh` |
| Kernel | `Protect*`, `SystemCallFilter`, `PrivateDevices` | Kernel interfaces and devices are hidden. | Not run |

`MemoryDenyWriteExecute` stays off, because JIT runtimes such as Node.js need writable and executable memory (`jit_rwx_memory`). `RestrictNamespaces` stays off, because browser sandboxes need user namespaces (`user_namespace`).

`/dev/shm` and SysV IPC are private per command. Two commands in one project cannot share them. Pi completes a full tool-call loop under this restriction. Other harnesses are untested.
