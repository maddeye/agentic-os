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

`agentos` allocates UIDs from `metadata/next-uid` and never reuses a value. Snapshots and backups can outlive a project, and a reused UID would own the old project's restored files.

Limit `NAME` to 28 characters so that `aos-NAME` fits the 32-character Linux user name limit.

## Filesystem layout

| Path | Owner | Mode | Purpose |
|---|---|---|---|
| `/opt/agent-os/toolchains` | `root:root` | `0755` | Shared toolchains, read-only to projects |
| `/var/lib/agent-os` | `root:root` | `0711` | Btrfs mount point, no listing for projects |
| `/var/lib/agent-os/metadata` | `root:root` | `0700` | Project definitions and host state |
| `/var/lib/agent-os/snapshots` | `root:root` | `0700` | Managed snapshots |
| `/var/lib/agent-os/projects` | `root:root` | `0711` | Project parent, no listing for projects |
| `projects/NAME` | `root:aos-NAME` | `0750` | Project root |
| `projects/NAME/workspace` | `aos-NAME` | `0700` | Repository checkout, default working directory |
| `projects/NAME/home` | `aos-NAME` | `0700` | `HOME` and project-local tools |
| `projects/NAME/cache` | `aos-NAME` | `0700` | `XDG_CACHE_HOME`, private package caches |
| `projects/NAME/state` | `aos-NAME` | `0700` | `XDG_STATE_HOME`, agent state and GUI sockets |
| `projects/NAME/artifacts` | `aos-NAME` | `0700` | GUI captures and test output |
| `projects/NAME/tmp` | `aos-NAME` | `0700` | Bound over `/tmp` and `/var/tmp` |

Root owns `projects/NAME` so that a project cannot replace `workspace` with a symlink. `tmp` is an addition to the architecture layout. Commands in one project share `/tmp` through it, which a per-unit `PrivateTmp=` would prevent.

The Btrfs subvolume hierarchy stays open until Phase 3. The measured behavior limits it: a snapshot of a parent subvolume omits files inside nested subvolumes ([baseline](BASELINE.md)). Making `cache` a nested subvolume would therefore keep it out of project snapshots.

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
| Runtime sockets | `TemporaryFileSystem=/run`, `BindReadOnlyPaths=-/run/systemd/resolve` | D-Bus and host sockets are absent, and DNS still works. | Sole control for `system_bus` |
| Processes | `ProtectProc=invisible` | Other users' processes are hidden. | Sole control for `proc_visible` and `proc_cmdline` |
| Kernel | `Protect*`, `SystemCallFilter`, `PrivateDevices` | Kernel interfaces and devices are hidden. | Not run |

`MemoryDenyWriteExecute` stays off, because JIT runtimes such as Node.js need writable and executable memory (`jit_rwx_memory`). `RestrictNamespaces` stays off, because browser sandboxes need user namespaces (`user_namespace`).

`/dev/shm` and SysV IPC are private per command. Two commands in one project cannot share them. Pi completes a full tool-call loop under this restriction. Other harnesses are untested.

## Decisions still open

These need a decision before the phase named.

| Question | Recommendation | Needed by |
|---|---|---|
| Per-project network namespaces | Adopt them. They close accepted gaps 1 and 2, but need `veth` and NAT setup and a port-forwarding design. | Phase 4, or the first host that runs mutually untrusted projects |
| Btrfs subvolume hierarchy, compression, and quotas | Benchmark in Phase 3. | Phase 3 |
