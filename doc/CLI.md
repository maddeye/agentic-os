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
| `agentos project ps NAME` | Prints the IDs of running commands. |
| `agentos project logs NAME ID` | Prints the journal output of a command. |
| `agentos project stop NAME [ID]` | Stops one command, or every command in the project. |
| `agentos project toolchain NAME TOOL VERSION` | Puts an installed global toolchain on the project's `PATH`. |
| `agentos project toolchain NAME TOOL --clear` | Removes that selection. |
| `agentos project delete NAME --yes` | Stops all commands and removes all project data and the identity. |

## `create` flags

| Flag | Default | Effect |
|---|---|---|
| `--cpu PERCENT` | None | `CPUQuota` for the whole project. 100 is one core. |
| `--memory-high SIZE` | `70%` | `MemoryHigh` for the whole project. |
| `--memory-max SIZE` | `80%` | `MemoryMax` for the whole project. |
| `--tasks N` | `4096` | `TasksMax` for the whole project. |

`SIZE` is a number with an optional `K`, `M`, `G`, or `T` suffix, or a percentage of RAM. All projects together are also limited by `agentos-project.slice`.

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
| 1 | `hostd` refused the request, the socket is unreachable, or the change failed. |
| 2 | Invalid usage. |
| 3 | The change is waiting for an administrator. |

## Project exit status

| Status | Meaning |
|---|---|
| Status of `COMMAND` | `run` completed the command. |
| 1 | The caller is not root. |
| 2 | Invalid usage, unknown project, an existing project or account with that name, or a process that outlives `delete`. |
| 127 | `COMMAND` is not on the project's `PATH`. |

## Command lifetime

| Event | Project data | Detached command | Foreground command |
|---|---|---|---|
| SSH connection lost | Kept | Keeps running | Lifetime not guaranteed. Check `ps`. |
| `stop` | Kept | Stopped | Stopped |
| Host reboot | Kept | Not resumed | Not resumed |
| `delete` | Removed | Stopped | Stopped |

Use `--detach` for any work that must survive a lost connection.

If `delete` fails, run it again. The name stays reserved and the project accepts no commands until a `delete` completes.

Commands in one project share a network namespace and reach each other on `127.0.0.1`. The administrator can reach a project port at the address that `inspect` prints.

A project's commands start with `HOME` set to `home/` and the working directory set to `workspace/`. The `PATH` starts with `home/.local/bin`, followed by any selected toolchains. The administrator's environment is not passed in.
