# `agentos` command reference

`agentos project` is the administrator CLI for project lifecycle. It runs as root. Project agents cannot run it. `packaging/install.sh` installs it to `/usr/local/sbin/agentos`.

`agentos system` is the client for [`hostd`](HOSTD.md). The administrator and the system agent can use it.

The command and service names are provisional.

## Commands

| Command | Result |
|---|---|
| `agentos project create NAME [flags]` | Creates the identity, directories, and slice. Prints `NAME`. |
| `agentos project list` | Prints name, UID, running command count, and creation time. |
| `agentos project inspect NAME` | Prints metadata, disk use, command count, and limits as `key=value` lines. |
| `agentos project run NAME -- COMMAND [ARG...]` | Runs a command in the sandbox and waits. Returns its exit status. |
| `agentos project run --detach NAME -- COMMAND [ARG...]` | Starts a command in the background and prints its 8-character ID. |
| `agentos project shell NAME` | Opens an interactive login shell in the sandbox. |
| `agentos project gui NAME SUBCOMMAND ...` | Runs an `agentos-gui` subcommand as the project. [GUI.md](GUI.md) lists them. |
| `agentos project ps NAME` | Prints the IDs of running commands. |
| `agentos project logs NAME ID` | Prints the journal output of a command. |
| `agentos project stop NAME [ID]` | Stops one command, or every command in the project. |
| `agentos project toolchain NAME TOOL VERSION` | Puts an installed global toolchain on the project's `PATH`. |
| `agentos project toolchain NAME TOOL --clear` | Removes that selection. |
| `agentos project snapshot NAME [--label LABEL] [--auto]` | Takes a read-only snapshot and prints its ID. `--auto` makes it subject to retention. |
| `agentos project snapshots NAME` | Prints ID, kind, creation time, omitted subvolume count, and label. |
| `agentos project snapshot-delete NAME ID --yes` | Removes one snapshot. |
| `agentos project prune NAME [--keep N]` | Removes the oldest automatic snapshots, beyond the newest `N`. |
| `agentos project restore NAME --snapshot ID --yes` | Stops all commands, replaces the project's data, and prints the ID of the automatic pre-restore snapshot. |
| `agentos project backup NAME --snapshot ID` | Writes a backup stream to standard output. |
| `agentos project recover` | Recreates a project from a backup stream on standard input. Prints `NAME`. |
| `agentos project delete NAME --yes` | Stops all commands and removes all project data, its local snapshots, and the identity. |
| `agentos storage check` | Runs the storage check at once. `agentos-storage.timer` runs it every minute. |

## `create` flags

| Flag | Default | Effect |
|---|---|---|
| `--cpu PERCENT` | None | `CPUQuota` for the whole project. 100 is one core. |
| `--memory-high SIZE` | `70%` | `MemoryHigh` for the whole project. |
| `--memory-max SIZE` | `80%` | `MemoryMax` for the whole project. |
| `--tasks N` | `4096` | `TasksMax` for the whole project. |
| `--disk SIZE` | `80%` | Limit on all of the project's subvolumes together. A percentage means a share of the filesystem. |

`SIZE` is a number with an optional `K`, `M`, `G`, or `T` suffix, or a percentage. Memory percentages mean a share of RAM. All projects together are also limited by `agentos-project.slice`.

`NAME` matches `^[a-z]([a-z0-9-]{0,26}[a-z0-9])?$`.

## System commands

Replies are JSON on standard output. Refusals go to standard error.

| Command | Result |
|---|---|
| `agentos system status` | Reports host package state, changes by state, and toolchains. |
| `agentos system package install NAME... --reason TEXT` | Plans an install. Applies it at once if policy allows. |
| `agentos system package remove NAME... --reason TEXT` | Plans a removal. |
| `agentos system toolchain install NAME VERSION --reason TEXT` | Plans a global toolchain install from the catalog. |
| `agentos system toolchain remove NAME VERSION --reason TEXT` | Plans a global toolchain removal. |
| `agentos system change show ID` | Prints one change. |
| `agentos system change approve ID` | Approves a change. Administrator only. |
| `agentos system change reject ID` | Rejects a change. Administrator only. |
| `agentos system change apply ID` | Applies an approved change and verifies it. |
| `agentos system change history` | Prints the last 200 audit events. |
| `agentos system recover` | Finishes any interrupted change. |

| Status | Meaning |
|---|---|
| 0 | The request succeeded. |
| 1 | `hostd` refused the request, another change is running (`busy`), the socket is unreachable, or the change failed. |
| 2 | Invalid usage. |
| 3 | The change is waiting for an administrator. |

## Project exit status

| Status | Meaning |
|---|---|
| Status of `COMMAND` | `run` completed the command. |
| 1 | The caller is not root. |
| 2 | Invalid usage, unknown project or snapshot, an existing project or account with that name, a refused backup, too little free disk space for a snapshot, or a process that outlives `delete` or `restore`. |
| 127 | `COMMAND` is not on the project's `PATH`. |

## Command lifetime

| Event | Project data | Detached command | Foreground command |
|---|---|---|---|
| SSH connection lost | Kept | Keeps running | Lifetime not guaranteed. Check `ps`. |
| `stop` | Kept | Stopped | Stopped |
| Host reboot | Kept | Not resumed | Not resumed |
| `restore` | Replaced | Stopped | Stopped |
| `delete` | Removed | Stopped | Stopped |

Use `--detach` for any work that must survive a lost connection.

If `delete` fails, run it again. The name stays reserved and the project accepts no commands until a `delete` completes.

If `restore` fails, run it again with the same snapshot, or run `delete`. The project accepts no commands until one of them completes. If `recover` fails, run it again with the same backup.

Commands in one project share a network namespace and reach each other on `127.0.0.1`. The administrator can reach a project port at the address that `inspect` prints.

A graphical session that `agentos project gui NAME start` created lasts until `stop`, `agentos project stop`, or a reboot. A session that a project command started with `agentos-gui start` ends with that command.

A project's commands start with `HOME` set to `home/` and the working directory set to `workspace/`. The `PATH` starts with `home/.local/bin`, followed by any selected toolchains. The administrator's environment is not passed in.
