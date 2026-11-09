# Agent OS threat model

Status: Phase 5 in progress, reviewed 2026-11-09. Revise this file for every change that touches privilege escalation, credentials, filesystem mounts, networking, or GUI capture.

Check names in this document are rows in [`tests/isolation/checks.tsv`](../tests/isolation/checks.tsv). The [isolation design](ISOLATION.md) explains the controls.

## Protected assets

| ID | Asset | Why it matters |
|---|---|---|
| A1 | Project workspace, home, cache, state, and artifacts | Source code and agent memory belong to one project. |
| A2 | Project credentials: Git, registry, and API tokens | A leak acts with the project's external authority. |
| A3 | GUI sockets, recordings, screenshots, and input traces | Captures can contain secrets typed on screen. |
| A4 | Host configuration, boot files, and system services | A change here persists beyond any project. |
| A5 | APT and dpkg state, and global toolchains | Every project executes this software. |
| A6 | Administrator and system-agent credentials, and SSH host keys | These grant host control or impersonation. |
| A7 | `/var/lib/agent-os/metadata` and managed snapshots | Tampering rewrites identity mappings or recovery data. |
| A8 | Audit history | Without it, nobody can reconstruct a privileged change. |
| A9 | Host availability, including the SSH management reserve | A runaway project can lock out the administrator. |

## Attacker capabilities

| ID | Attacker | Assumed capability |
|---|---|---|
| T1 | Compromised or misaligned project agent | Runs arbitrary code as its project UID, for as long as it wants. |
| T2 | Malicious project dependency, for example an `npm` post-install script | The same capability as T1. |
| T3 | Compromised system agent | Sends any request that its identity is allowed to send to `hostd`. It has no root shell. |
| T4 | Malicious Debian or toolchain package approved by policy | Runs as root during installation. |
| T5 | Network attacker | Reaches any port that the host exposes. |
| T6 | Holder of a kernel exploit | Crosses every boundary in this document. |

A prompt-injected agent is T1 or T3. The design does not try to detect injection. It limits what the affected identity can do.

## Trust boundaries

| ID | Boundary | Enforced by | Status |
|---|---|---|---|
| B1 | Project to project | Separate UIDs, mode `0700` directories, mount, IPC, and network namespaces, `ProtectProc=invisible` | Tested |
| B2 | Project to host | No capabilities, no new privileges, read-only system paths, private `/run`, network namespace, and `nftables` input policy | Tested |
| B3 | Project to system agent | Separate UID, private `/run`, socket group, and `hostd` accepts peers by `SO_PEERCRED` | Tested |
| B4 | System agent to root | Typed `hostd` operations, policy, human approval, and audit | Tested. Package scripts remain gap 6. |
| B5 | Network to host | OpenSSH keys only, and no remote root. The VM image enforces this. Private networking is still design only | Tested for the VM image |
| B6 | Project to kernel | Seccomp filter and hidden kernel interfaces reduce exposure only | Partial by design |

## Threats and controls

| Threat | Attacker | Assets | Control | Evidence |
|---|---|---|---|---|
| Read another project's files | T1, T2 | A1, A2 | B1 file modes | `home_read`, `workspace_read` |
| Discover or reuse data in shared temporary storage | T1, T2 | A1, A2 | Per-project `/tmp`, per-unit `/dev/shm` | `tmp_cross`, `var_tmp_cross`, `dev_shm_cross` |
| Read another project's IPC objects | T1, T2 | A1 | `PrivateIPC=yes` | `sysv_shm_cross`, `mqueue_cross` |
| Inspect or signal another project's processes | T1, T2 | A1, A2 | `ProtectProc=invisible`, UID checks | `proc_visible`, `proc_cmdline`, `proc_environ`, `signal` |
| Connect to another project's GUI socket | T1, T2 | A3 | Sockets live in a mode `0700` directory under the project's own `/tmp` | `gui_socket`, `tests/gui/guest/isolation.sh` |
| Connect to another project's X11 display through its abstract socket | T1, T2 | A3 | Abstract sockets belong to the network namespace | `tests/gui/guest/isolation.sh` |
| Log in to a new image with a shipped credential | T5 | A6 | The image has no password and no key, and the first key arrives as a boot credential | `tests/image/run` |
| Log in to a newly installed host with a shipped credential | T5 | A6 | The ISO holds no password or key. The installer refuses to go on without a valid public key | `tests/installer/run` |
| Impersonate a newly installed host on its first connection | T5 | A6 | The installer generates host keys and shows the fingerprint on the console | `tests/installer/run` |
| Keep a stale credential or host key through a repair | T5 | A6 | A repair enrolls the key typed at the console and generates new host keys | `tests/installer/run` |
| Guess a password, or log in remotely as root | T5 | A6 | `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no` | `tests/image/guest/first_boot.sh` |
| Impersonate another machine built from the same image | T5 | A6 | The image ships no host keys or machine ID, and each first boot generates its own | `tests/image/run` |
| Read another project's screenshots, recordings, or input traces | T1, T2 | A3 | Project directory modes, mode `0600` files | `tests/gui/guest/isolation.sh` |
| Reach a GUI viewer over the network | T5 | A3 | The viewer binds only a project-private Unix socket, and remote use goes through SSH and root | `tests/gui/run` |
| Trick root into opening a project path through a GUI session | T1, T2 | A4 | `agentos project gui` only starts commands as the project, and root opens no project file | `tests/gui/guest/cleanup.sh` |
| Keep a graphical process after a session ends | T1, T2 | A9 | Applications run in the supervisor's process groups, and the compositor dies with its supervisor | `tests/gui/guest/cleanup.sh` |
| Keep typed secrets in the input trace | T1, T2 | A3 | The trace stores the length of typed text, and `<char>` for printable keys | `tests/gui/guest/agent.sh` |
| Reach another project's sockets or ports | T1, T2 | A1, A3 | Per-project network namespace, `nftables` forward policy | `abstract_socket`, `loopback_tcp`, `tests/integration/guest/network.sh` |
| Reach services on the host, or change the project network | T1, T2 | A4, A6 | Network namespace, `nftables` input policy, no capabilities | `host_loopback_ssh`, `host_uplink_ssh`, `net_admin`, `tests/integration/guest/network.sh` |
| Modify host files or packages | T1, T2 | A4, A5 | `ProtectSystem=strict`, file modes | `etc_write`, `usr_write`, `boot_write`, `dpkg_db_write`, `apt_install`, `toolchain_write` |
| Escalate through setuid, sudo, or D-Bus | T1, T2 | A4, A6 | `NoNewPrivileges=yes`, private `/run` | `setuid_binary`, `sudo`, `system_bus`, `capabilities`, `service_start` |
| Trick root tooling with a swapped project path | T1, T2 | A4, A7 | Root owns each project directory | `replace_own_project_dir` |
| Run the administrator CLI from a project | T1, T2 | A4, A7 | Root check, no setuid, no sudo | `agentos_cli` |
| Inject through names or sizes given to the root CLI | T1, T2 through a relayed request | A4 | Strict patterns before any use | `tests/integration/guest/lifecycle.sh` |
| Keep files or processes after delete, or redirect it with symlinks and subvolumes | T1, T2 | A1, A4 | Mask the slice, stop it, kill the UID, confirm no process remains, remove with no symlink following | `tests/integration/guest/delete.sh` |
| Inherit another account by name collision | Administrator error | A4 | `create` refuses any account that it did not record allocating | `tests/integration/guest/delete.sh` |
| Read host credentials or metadata | T1, T2 | A6, A7 | File modes, `ProtectHome=yes`, masked `/var/lib/agent-os` | `shadow`, `ssh_host_key`, `admin_ssh_keys`, `metadata_read`, `snapshots_list` |
| Change kernel state | T1, T2 | A4, A9 | `Protect*` settings, no capabilities | `dmesg`, `sysctl_write`, `cgroup_write`, `mount_tmpfs`, `block_device` |
| Exhaust host memory or tasks | T1, T2 | A9 | Per-project slice limits | `memory_limit`, `tasks_limit` |
| Call `hostd` or read its state from a project | T1, T2 | A4, A5, A8 | Private `/run`, socket mode, `SO_PEERCRED`, file modes | `hostd_socket`, `hostd_client`, `hostd_state_read`, `tests/hostd/guest/privileges.sh` |
| Impersonate the system agent or administrator | T1, T2, T3 | A4, A5 | Identity comes only from the kernel, and unknown fields are rejected | `tests/hostd/guest/privileges.sh` |
| Approve one's own change | T3 | A4, A5 | Only peer UID 0 can decide | `tests/hostd/guest/packages.sh` |
| Remove the broker's own package | T3 | A4, A5, A9 | Removal always needs human approval, `agentos` is a protected package, and `prerm` refuses while any project exists | `tests/hostd/guest/packages.sh`, `tests/packaging/guest/lifecycle.sh` |
| Leave the host forwarding packets after Agent OS is removed | T5 | A4 | Stopping the firewall turns forwarding off before it deletes the policy | `tests/packaging/guest/lifecycle.sh` |
| Change the transaction or package contents after approval | T3, T4 | A4, A5 | Apply installs only the hashed archives kept by the plan, and compares a new simulation | `tests/hostd/guest/packages.sh`, `tests/hostd/guest/toolchains.sh` |
| Fill the broker's connection slots | T3 | A9 | One time limit per request, refused lock waits, separate administrator socket | `tests/hostd/guest/privileges.sh` |
| Smuggle apt options, paths, regexes, or removal suffixes through a name | T3 | A4, A5 | Character check, and apt must act on exactly the requested names | `tests/hostd/guest/packages.sh` |
| Get a risky package through the automatic list | T3 | A4, A5 | Automatic only for clean installs with no unit, setuid file, or protected name | `tests/hostd/guest/packages.sh` |
| Publish a tampered or partial toolchain | T3, T4 | A5 | Catalog digest, staged check as `nobody`, one rename | `tests/hostd/guest/toolchains.sh`, `tests/hostd/guest/interrupt.sh` |
| Replace a shared toolchain from a project | T1, T2 | A5 | `ProtectSystem=strict`, root-owned files | `toolchain_write`, `tests/hostd/guest/toolchains.sh` |
| Read project data as the system agent | T3 | A1, A2 | Project modes, and broker instances and their package scripts have no project data mounted | `tests/hostd/guest/privileges.sh`, `tests/hostd/guest/interrupt.sh` |
| Upgrade the host without a human, or widen an approved upgrade afterward | T3, T4 | A4, A5 | `package_upgrade` always needs approval, applies only the hashed archives, and fails if SSH or the firewall is down afterward | `tests/hostd/guest/upgrade.sh` |
| Hide a privileged change | T3 | A8 | Root-only log, synced before each privileged step | `tests/hostd/guest/packages.sh` |
| Leave the host broken by interrupting a transaction | T3, power loss | A5, A9 | Durable `applying` record, repair before the next change | `tests/hostd/guest/interrupt.sh`, `tests/hostd/guest/after_power_loss.sh` |
| Read or change managed snapshots | T1, T2 | A1, A7 | Mode `0700`, masked `/var/lib/agent-os`, read-only subvolumes | `snapshots_list`, `tests/storage/guest/snapshots.sh` |
| Fill the disk past a project's limit | T1, T2 | A9 | One qgroup per project, and no capability to change it | `tests/storage/guest/layout.sh` |
| Escape the limit with a new subvolume | T1, T2 | A9 | The storage check enrolls new subvolumes every minute | `tests/storage/guest/layout.sh` |
| Forge `btrfs` output with a crafted subvolume name, to affect another project | T1, T2 | A9 | The kernel confirms each ID's path, and parsed output holds no project names | `tests/storage/guest/layout.sh` |
| Survive a restore through a poisoned cache or a running process | T1, T2 | A1 | Restore kills the UID's processes and gives empty `cache` and `tmp` | `tests/storage/guest/restore.sh` |
| Use a damaged or crafted backup to gain root or take over a UID | Holder of the backup store | A1, A4 | Checksum before parsing, strict header, `btrfs receive --chroot`, UID range and collision checks, and refusal of foreign owners, setuid files, and device nodes | `tests/storage/run` |

## Accepted gaps

Each gap stays open until a later change closes it. The suite marks the first one as `gap`, so it fails when the behavior changes.

1. **`/etc/passwd` reveals project names.** `passwd_project_names` proves the access. Project names must not contain secrets.
2. **Network egress is unrestricted.** T1 can send any readable project data to the internet. NAT also lets it reach the LAN and cloud metadata addresses. Per-project egress policy is future work.
3. **User namespaces stay enabled.** `user_namespace` requires them, because Chromium and Electron sandboxes need them in Phase 4. They add kernel attack surface for T6.
4. **The kernel is shared.** T6 defeats the design. Use the `vm` execution profile for workloads that warrant a separate kernel.
5. **Same-project processes are not isolated from each other.** An agent can read every credential that its project holds. A secret delivered to a project is visible to all of that project's code.
6. **Package installation scripts run as root.** T4 has full control during installation. Policy and approval reduce the chance of T4, and they do not contain it. A script can also add file capabilities, which the content scan cannot see.
7. **Projects can still fill the shared Btrfs filesystem together.** The default limit is 80% for each project, so several projects can exceed the disk. A project can also write outside its limit in the time before the storage check enrolls a new subvolume, at most one minute. Under critical pressure the check stops the largest project, which can be the wrong one. Snapshots are not counted against a project's limit.
8. **A project can create its own Btrfs subvolumes.** systemd cannot filter `ioctl` arguments, so the sandbox cannot stop this. Snapshots omit their contents, and the snapshot reports how many it omitted. A project that creates shared subvolumes also forces quota rescans, and limits are not exact during a rescan.
9. **Project output can contain terminal escape sequences.** `run`, `shell`, and `logs` pass the output to the administrator's terminal unfiltered.
10. **Project output goes to the host journal.** journald's size limits apply, and the journal keeps secrets that a project prints. A project can also push out older host log entries.
11. **The system agent can grow the audit log.** T3 can send refused requests until the data disk fills. Log rotation does not exist yet. Projects cannot reach this path.
14. **A busy lock can delay the administrator.** T3 can keep requesting long plans, so an administrator's change can be refused as `busy`. Stopping `agentos-hostd.socket` ends this.
12. **A human approves what `change show` displays.** The plan lists actions, units, and setuid files. It cannot judge whether a package is trustworthy.
15. **Backups are not encrypted or signed.** A stream holds every project secret. The checksum catches damage, and someone who can rewrite the backup can also rewrite the checksum. The checks at `recover` limit what a forged backup can do, but the forged project data is still restored. Encrypt and authenticate the stream outside `agentos`.
16. **`agentos` does not schedule or rotate backups.** The operator pulls them. A backup is always a full stream.
17. **A GUI capture holds whatever was on screen.** Screenshots and recordings stay in the project and enter its snapshots and backups. `agentos-gui rm` removes them from the live tree only, and nothing expires them automatically.
18. **Graphical sessions do not contain the applications in them.** Applications in one session can capture each other and inject input through the compositor. A process that leaves its process group stays alive after `stop`, until its project command ends.
19. **A viewer can send input.** An administrator who opens `view` can click and type in the session, like the project itself can.
13. **A leaked connection keeps its identity.** `SO_PEERCRED` describes who connected. If the system agent passes an open socket to another process, that process acts as the system agent.

20. **The first boot trusts whoever supplies the boot credential.** Until an administrator key exists, anyone who controls the hypervisor can enroll one. That party can already read the disk, and the file is never overwritten once it exists. An installed host already has a key, so this applies to the VM image.
21. **The `admin` account has passwordless sudo.** A stolen administrator key is root on the host. The account has no password to type, and the image relies on the key alone.
22. **The installer ISO is not signed.** Its checksum catches damage, and someone who can replace the ISO can replace the checksum too. Secure Boot must be off to start it. The installer also runs as root on the console, so anyone at the console before the disk is chosen can install their own key.

## Rules for later phases

- `hostd` listens only on a Unix socket. File ownership and `SO_PEERCRED` cannot check a network peer.
- Root-run tooling must not open a project path through a systemd `StandardOutput=file:` setting. PID 1 would follow a symlink that the project planted.
- Host services must not trust a connection because it came from `127.0.0.1`.
- Root-run tooling must not follow symlinks inside a project directory.
- Bind any GUI viewer to a project-private socket, never to a host port by default.
