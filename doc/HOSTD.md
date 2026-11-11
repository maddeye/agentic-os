# Host-maintenance broker

Status: implemented by `agentos-hostd`. The [test procedure](TEST_PLAN.md) covers this contract on Debian 13.7.

`hostd` lets a non-root system agent change the host through typed, policy-checked, audited operations. It has no way to run an arbitrary command.

## Identities

| Caller | How `hostd` identifies it | Allowed requests |
|---|---|---|
| Administrator | Peer UID 0 | All |
| System agent | Peer UID of the `agentos-system` account | All except `change_approve` and `change_reject` |
| Any other UID | No match | None. The attempt is audited. |

`hostd` reads the peer UID with `SO_PEERCRED`, which the kernel records at connect time. No request field can state an identity, and any unknown field makes the request malformed.

The system agent uses `/run/agentos/hostd.sock`, `root:agentos-system`, mode `0660`, limited to 16 connections. The administrator uses `/run/agentos/hostd-admin.sock`, `root:root`, mode `0600`, limited to 4 connections, so the system agent cannot fill it. `agentos system` chooses the socket by its effective UID. Project sandboxes mount an empty `/run`, so a project sees neither.

The `agentos-system` account has a home at `/var/lib/agent-os/system-agent`, no sudo rights, and no group shared with any project. Start a harness under it with `sudo -iu agentos-system`.

## Service model

systemd listens on the socket and starts one `agentos-hostd@.service` instance per connection, so no broker process exists while idle. Each instance serves one request and exits. A client that disconnects does not cancel a change.

Mutating requests take an exclusive `flock`. The kernel releases it when the holder dies, so a change found in `applying` while the lock is held has no live owner. A request that cannot get the lock in 5 seconds is refused as `busy`. Run it again later.

## Requests

Send one JSON object and one newline, up to 64 KiB. The whole request must arrive within 10 seconds. The reply is one JSON object with `status` set to `ok` or `refused`.

| `request` | Fields | Effect |
|---|---|---|
| `system_status` | None | Reports dpkg consistency, changes by state, toolchains, and whether a reboot is pending. |
| `change_history` | None | Returns the last 200 audit events. |
| `change_show` | `id` | Returns one change. |
| `change_plan` | `reason`, `operation` | Computes impact, evaluates policy, and records the change. |
| `change_approve`, `change_reject` | `id` | Records the administrator's decision. |
| `change_apply` | `id` | Applies an approved change and verifies it. |
| `recover` | None | Finishes any interrupted change. Every mutating request also does this first. |
| `service_start` | `project` | Starts the service of a project that hostd created, unless it is running. Returns its address and `running` or `started`. |
| `service_credential` | `project` | Runs the service's `credential` script as the project and returns its output, up to 4 KiB, with the project's address. |

| `operation.type` | Fields |
|---|---|
| `package_install` | `names`, up to 32 |
| `package_remove` | `names`, up to 32 |
| `package_upgrade` | None |
| `toolchain_install_global` | `name`, `version` |
| `toolchain_remove_global` | `name`, `version` |
| `project_create` | `name`, `service` |

`ServiceEnableDisable`, `UpgradePlan`, and recovery-point operations do not exist yet.

## Change states

```text
                +--> awaiting_approval --approve--> approved --apply--> applying --> applied | failed
change_plan ----+                          |            |
                +--> approved (policy)     reject       plan changed
                                           v            v
                                        rejected      stale
```

A plan runs `apt-get update`, simulates the transaction, and downloads the packages. It copies each archive into `metadata/hostd/artifacts/ID`, then hashes and lists that copy without running its scripts. It records each package action, each archive's SHA-256 and architecture, the download size, autostart files, and setuid files.

Approval covers the exact archives. `change_apply` hashes the copies and simulates again with them. A changed file or a different transaction moves the change to `stale`. Request a new plan in that case. The install uses only those copies and downloads nothing, so a repository that republishes a version cannot change what was approved. The copies are deleted when the change ends.

For a toolchain, approval covers the whole catalog entry, including its URL, digest, and check.

A change is `applied` only if the command succeeded and every planned action reached its planned version. An upgrade also needs `ssh.service` and `agentos-firewall.service` active afterward.

An upgrade moves every installed package to its candidate and installs any new package that needs, such as a new kernel. It never removes a package. A package that apt will not move, usually because of a conflict, appears in `impact.kept_back` and in the decision's reasons. Approval still covers the exact archives, so a version published after approval does not change what applies.

`reboot_required` in `system_status` is true when a newer kernel file than the running kernel is in `/boot`. `hostd` never reboots the host.

## Policy

The administrator owns `/etc/agent-os/hostd-policy.json`. The package copies the default only when the file is absent, so an upgrade preserves it. A missing or malformed policy refuses every plan.

| Field | Meaning |
|---|---|
| `automatic_packages` | Package names that may install without approval. Empty by default. |
| `automatic_toolchains` | `name/version` entries that may install without approval. Empty by default. |
| `protected_package_prefixes` | Package name prefixes that always need approval. |
| `automatic_project_services` | Services whose projects may be created without approval. Empty by default. |
| `automatic_project_limit` | No automatic create runs once the host has this many projects, counting approved creates that have not applied. 0 by default. |

A package install is automatic only when all of these are true:

- Every requested name is on `automatic_packages`.
- The transaction changes or removes no installed package.
- No package in the transaction matches a protected prefix.
- No package ships a setuid file, or any file in a systemd unit or generator directory or `/etc/init.d`.

Upgrades and removals always need approval. Removing an essential package is refused outright. Installs pass `--no-remove`, so an install can never remove a package.

Every create needs approval unless its service is on `automatic_project_services` and the count is below `automatic_project_limit`. A policy written before these fields existed allows no automatic create.

## Project services

The system agent can ask for a new project that runs a service. The administrator defines each service as a directory under `/etc/agent-os/services`, and a request names a directory and nothing more. The package creates the empty directory.

| Script | Required | Runs |
|---|---|---|
| `start` | Yes | As the project's long-running service, in the unit `aos-svc-UID.service`. |
| `setup` | No | Before each start, as the project, and waits. It must be safe to run again. |
| `credential` | No | On `service_credential`, as the project. Its output goes to the caller. |

All three run as the project under `native-restricted`, like `agentos project run`. hostd cannot see project data, so it runs `agentos project create NAME --service SERVICE` and `agentos project service NAME start` in transient units of their own.

Only a project whose registry entry names a service accepts `service_start` and `service_credential`, so the system agent cannot reach into a project that the administrator created by hand. The audit records each request and its result, never the credential. The output comes from the project, so hostd passes it on as text and parses none of it.

The undo command of a create is `agentos project delete NAME --yes`. The system agent cannot delete a project. A reboot stops every service, and `service_start` brings one back. `restore` keeps the service. `recover` brings a project back from a backup without it, so the system agent gets no credential for what a backup holds.

## Package names

The default `protected_package_prefixes` includes `agentos`, so a plan that changes the broker's own package always names it as protected. An approved removal still fails while any project exists, because the package's `prerm` script refuses it.


A name must match Debian's characters, without `*`, `/`, `:`, or `=`. `.` and `+` are legal in Debian names and are also regex syntax for apt, and apt reads a `name-` suffix as a removal. A plan therefore stands only if apt acted on exactly the requested names. Anything else is refused as `unknown_package`.

Packages come only from the APT sources already on the host. No operation adds a source.

## Toolchains

Only entries in `/usr/share/agent-os/toolchains.json` can be installed. Each entry pins a URL, a SHA-256 digest, and a check command with its expected output.

An install runs these steps under `/opt/agent-os/toolchains/.staging`:

1. Download over HTTPS and compare the digest.
2. Extract without preserving owners or modes.
3. Give all files to root, remove group and other write, and clear setuid and setgid bits.
4. Run the check as `nobody` with no new privileges.
5. Sync the filesystem, so the files are on disk before they can be published.
6. Rename the tree to `/opt/agent-os/toolchains/NAME/VERSION`.

The rename is the only publication step, so projects see all of a version or none of it. Each project selects versions independently with `agentos project toolchain`. A project with no selection gets no toolchain on `PATH`.

## Audit

`/var/lib/agent-os/metadata/hostd/audit.jsonl` is mode `0600`. Each line records the time, the event, and the caller's UID, PID, and name. Events also carry the change, action, decision, result, verification, and undo command where they apply.

Each event is written and synced before the step it describes or the step that follows it. Planning and repair run privileged tools, so `planning` and `recovery_started` come first. If a write fails, the request stops, so no privileged step runs without its record. Malformed requests are recorded without their body, because a body can hold anything a caller sent.

| Event | Written when |
|---|---|
| `denied` | A caller lacks the role for a request. |
| `malformed_request` | A request cannot be parsed. |
| `plan_refused` | Validation or apt rejects a plan. |
| `planning` | A plan is about to run apt. |
| `planned` | A change is recorded, with its decision and impact. |
| `approved`, `rejected` | The administrator decides. |
| `apply_refused`, `stale` | A change cannot apply. |
| `applying` | A change is about to run. |
| `finished` | A change ends, with its verification and undo command. |
| `recovery_started` | A repair is about to run. |
| `recovery` | A repair has run, with its result. |
| `service_start`, `service_credential` | The caller asked for a project's service, with the result. |

## Recovery

A change left in `applying` was interrupted by a crash, a kill, or power loss. The next mutating request repairs it before doing anything else. `agentos system recover` asks for this directly.

| Change | Repair | Result |
|---|---|---|
| Package | `dpkg --configure -a`, then `apt-get -f --no-remove --no-download install` if it touches only approved packages | `applied` if verification passes, otherwise `failed` |
| Toolchain | Removes the staging files | `applied` if the rename happened, otherwise `failed` |
| Project | Runs the create and the service start again. A finished step is skipped | `applied` if the service runs, otherwise `failed` |

Recovery rolls forward. It does not undo a change that had already finished unpacking. Each outcome records the command that would undo the change.

An outcome of `failed` with `dpkg_consistent` false in `status` needs an administrator.
