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

The socket is `/run/agentos/hostd.sock`, `root:agentos-system`, mode `0660`. Project sandboxes mount an empty `/run`, so a project does not see it.

The `agentos-system` account has a home at `/var/lib/agent-os/system-agent`, no sudo rights, and no group shared with any project. Start a harness under it with `sudo -iu agentos-system`.

## Service model

systemd listens on the socket and starts one `agentos-hostd@.service` instance per connection, so no broker process exists while idle. Each instance serves one request and exits. A client that disconnects does not cancel a change.

Mutating requests take an exclusive `flock`. The kernel releases it when the holder dies, so a change found in `applying` while the lock is held has no live owner.

## Requests

Send one JSON object and one newline, up to 64 KiB, within 10 seconds. The reply is one JSON object with `status` set to `ok` or `refused`.

| `request` | Fields | Effect |
|---|---|---|
| `system_status` | None | Reports dpkg consistency, changes by state, toolchains, and whether a reboot is pending. |
| `change_history` | None | Returns the last 200 audit events. |
| `change_show` | `id` | Returns one change. |
| `change_plan` | `reason`, `operation` | Computes impact, evaluates policy, and records the change. |
| `change_approve`, `change_reject` | `id` | Records the administrator's decision. |
| `change_apply` | `id` | Applies an approved change and verifies it. |
| `recover` | None | Finishes any interrupted change. Every mutating request also does this first. |

| `operation.type` | Fields |
|---|---|
| `package_install` | `names`, up to 32 |
| `package_remove` | `names`, up to 32 |
| `toolchain_install_global` | `name`, `version` |
| `toolchain_remove_global` | `name`, `version` |

`PackageUpgrade`, `ServiceEnableDisable`, `UpgradePlan`, and recovery-point operations do not exist yet. Section 12 of the architecture does not require them for Phase 2.

## Change states

```text
                +--> awaiting_approval --approve--> approved --apply--> applying --> applied | failed
change_plan ----+                          |            |
                +--> approved (policy)     reject       plan changed
                                           v            v
                                        rejected      stale
```

A plan runs `apt-get update`, simulates the transaction, downloads the packages, and lists their contents without running their scripts. It records each package action, the download size, shipped systemd units, and setuid files.

Approval covers the exact transaction. `change_apply` simulates again, and any difference moves the change to `stale`. Request a new plan in that case.

## Policy

The administrator owns `/etc/agent-os/hostd-policy.json`. An install preserves an existing file. A missing or malformed policy refuses every plan.

| Field | Meaning |
|---|---|
| `automatic_packages` | Package names that may install without approval. Empty by default. |
| `automatic_toolchains` | `name/version` entries that may install without approval. Empty by default. |
| `protected_package_prefixes` | Package name prefixes that always need approval. |

A package install is automatic only when all of these are true:

- Every requested name is on `automatic_packages`.
- The transaction changes or removes no installed package.
- No package in the transaction matches a protected prefix.
- No package ships a systemd unit or a setuid file.

Removals always need approval. Removing an essential package is refused outright. Installs pass `--no-remove`, so an install can never remove a package.

## Package names

A name must match Debian's characters, without `*`, `/`, `:`, or `=`. `.` and `+` are legal in Debian names and are also regex syntax for apt, and apt reads a `name-` suffix as a removal. A plan therefore stands only if apt acted on exactly the requested names. Anything else is refused as `unknown_package`.

Packages come only from the APT sources already on the host. No operation adds a source.

## Toolchains

Only entries in `/usr/share/agent-os/toolchains.json` can be installed. Each entry pins a URL, a SHA-256 digest, and a check command with its expected output.

An install runs these steps under `/opt/agent-os/toolchains/.staging`:

1. Download over HTTPS and compare the digest.
2. Extract without preserving owners or modes.
3. Give all files to root, remove group and other write, and clear setuid and setgid bits.
4. Run the check as `nobody` with no new privileges.
5. Rename the tree to `/opt/agent-os/toolchains/NAME/VERSION`.

The rename is the only publication step, so projects see all of a version or none of it. Each project selects versions independently with `agentos project toolchain`. A project with no selection gets no toolchain on `PATH`.

## Audit

`/var/lib/agent-os/metadata/hostd/audit.jsonl` is mode `0600`. Each line records the time, the event, and the caller's UID, PID, and name. Events also carry the change, action, decision, result, verification, and undo command where they apply.

Each event is written and synced before the step that follows it. If the write fails, the request stops, so no privileged step runs without its record. Malformed requests are recorded without their body, because a body can hold anything a caller sent.

| Event | Written when |
|---|---|
| `denied` | A caller lacks the role for a request. |
| `malformed_request` | A request cannot be parsed. |
| `plan_refused` | Validation or apt rejects a plan. |
| `planned` | A change is recorded, with its decision and impact. |
| `approved`, `rejected` | The administrator decides. |
| `apply_refused`, `stale` | A change cannot apply. |
| `applying` | A change is about to run. |
| `finished` | A change ends, with its verification and undo command. |
| `recovery` | An interrupted change is repaired. |

## Recovery

A change left in `applying` was interrupted by a crash, a kill, or power loss. The next mutating request repairs it before doing anything else. `agentos system recover` asks for this directly.

| Change | Repair | Result |
|---|---|---|
| Package | `dpkg --configure -a`, then `apt-get -f --no-remove install` | `applied` if verification passes, otherwise `failed` |
| Toolchain | Removes the staging files | `applied` if the rename happened, otherwise `failed` |

Recovery rolls forward. It does not undo a change that had already finished unpacking. Each outcome records the command that would undo the change.

An outcome of `failed` with `dpkg_consistent` false in `status` needs an administrator.
