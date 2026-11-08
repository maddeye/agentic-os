# Graphical sessions

Status: implemented for Phase 4. `tests/gui/run` passes on Debian 13.7 with kernel 6.12, Sway 1.10.1, and software rendering.

A project agent can open an off-screen Wayland desktop, run a real application in it, drive that application with a mouse and keyboard, and keep screenshots and video. Nothing graphical runs while no session exists.

## Install the packages

The GUI tools are ordinary host packages, so they go through the [`hostd`](HOSTD.md) approval path:

```bash
mapfile -t packages < /usr/share/agent-os/gui-packages
agentos system package install "${packages[@]}" --reason "graphical sessions"
agentos system change approve ID
agentos system change apply ID
```

## Commands

A project agent runs `agentos-gui` directly, from inside its sandbox. An administrator runs the same subcommands as `agentos project gui NAME SUBCOMMAND ...`.

| Command | Result |
|---|---|
| `start ID [--size WxH]` | Starts a session and returns when it is ready. The default size is `1280x720`. |
| `run ID -- COMMAND [ARG...]` | Starts an application in the session and prints its number. It uses the caller's directory and environment. |
| `wait ID --ready` | Waits for the session to be ready. |
| `wait ID --window APP_ID` | Waits for a window. `windows` prints each window's `app_id`. |
| `wait ID --app NUMBER` | Waits for an application to exit and returns its exit status. |
| `windows ID` | Prints one JSON object per window. |
| `type ID TEXT` | Types printable ASCII, newlines, and tabs. Other text is refused. |
| `key ID KEY` | Presses a key or combination, such as `Return` or `Control+a`. |
| `move ID X Y` | Moves the pointer. |
| `click ID X Y [--button left\|middle\|right]` | Clicks at a position. |
| `screenshot ID [--output FILE]` | Captures the screen and prints the path. |
| `record start ID`, `record stop ID` | Records the screen. A session keeps one recording. |
| `result ID pass\|fail [--detail TEXT]` | Stores a test result in the metadata. |
| `status ID` | Prints the metadata. |
| `view ID` | Connects standard input and output to the session's RFB viewer. |
| `list` | Prints each session's ID, state, size, and start time. |
| `stop ID` | Stops the session and prints its final state. |
| `rm ID` | Deletes a stopped session's artifacts. |

`ID` matches `^[a-z0-9][a-z0-9_-]{0,31}$`. An ID stays taken until `rm` removes it, so a new run cannot overwrite an earlier run's captures.

The `agentos-gui` exit status is 0 on success, 1 on refusal, and 2 on invalid usage. `wait --app` returns the application's status instead.

## Session lifetime

A session started with `agentos project gui NAME start` has its own systemd unit, and lasts until `stop`, `agentos project stop`, or a reboot.

A session started with `agentos-gui start` belongs to the command that started it, and ends with that command. Running `agentos project run NAME -- agentos-gui start ID` on its own therefore starts a session that ends at once. Use the `agentos project gui` form from outside a project.

| Event | Result |
|---|---|
| `stop` | Finishes any recording, stops applications, and records `stopped`. |
| `agentos project stop` or the starting command exits | The same. |
| Supervisor killed, or host reboot | The compositor dies with its supervisor. The next `list` or `start` records `orphaned` and clears the runtime directory. |
| `agentos project restore` or `delete` | Stops the session with the project's other commands. |

## Artifacts

```text
artifacts/gui/ID/
  metadata.json
  screenshots/0001.png
  recording.mkv
  inputs.jsonl
  logs/
```

`metadata.json` records the project, session, backend, resolution, state, timestamps, each application's command and exit status, every capture, the recording's codec, and the test result.

`inputs.jsonl` keeps the positions of pointer actions and the names of special keys. Typed text can be a secret, so the trace stores only its length, and a printable key in a combination appears as `<char>`.

The artifacts are part of the project's snapshots and backups. `rm` removes them from the live tree only.

## View a session remotely

`view` carries RFB over standard input and output, so OpenSSH authenticates the viewer and no port opens on the host. This command gives a local VNC client a port on `127.0.0.1:5900`:

```bash
socat TCP-LISTEN:5900,bind=127.0.0.1,reuseaddr \
	EXEC:"ssh ADMIN@HOST sudo agentos project gui NAME view ID"
```

A viewer can send input to the session.

## Design

Each session has one supervisor process, which runs as the project. It starts `dbus-daemon`, `sway`, and `wayvnc`, and it holds the session's only control socket. Every command is a request to that socket, so `metadata.json` has one writer. A session is alive exactly when its control socket answers, which the kernel settles without a PID file.

Runtime sockets live in `/tmp/gui/ID`, which is the project's own `/tmp`, mode `0700`, and left out of snapshots. Applications run in their own process groups as children of the supervisor.

Root never opens a project path. `agentos project gui` only starts `agentos-gui` as the project, by the same path as `agentos project run`.

The supervisor keeps one RFB connection to `wayvnc` open for the life of the session. Sway's headless seat reports no pointer or keyboard until a virtual device attaches, so a client without one gets no input at all. Tools that create a device per action, such as `wtype`, also lose the first key while the application loads the new keymap. One long-lived connection removes both problems.

`wf-recorder` writes the complete file on `SIGINT`, and then waits for one more compositor frame before it exits. On a static screen that frame never arrives. `record stop` moves the pointer by one pixel to produce it, and kills the recorder after five seconds if it still has not exited.

## Backend evaluation

Each candidate ran in a project sandbox on the test VM, with no GPU.

| Requirement | Sway 1.10.1 | waymux 0.2.0-dev (2026-07-04) | Weston 14.0.2 |
|---|---|---|---|
| Debian package | Yes | No | Yes |
| Starts in the sandbox | Yes | Yes | Yes |
| Lists a GTK3 window | Yes | No, the window list stayed empty | Not tested |
| Screenshot | Yes, `grim` | No, it reported no windows | No, `grim` needs `wlr-screencopy` |
| Video | Yes, `wf-recorder` | No, stop wrote no file | Not tested |
| Input | Yes, with a virtual device | Not reached | No, `wayvnc` needs the virtual pointer protocol |
| Viewer without a GPU | Yes, `wayvnc` | The default viewer needs a GPU, by its documentation | No |

Sway is the backend because every tool comes from the Debian archive and every requirement passed. The cause of waymux's empty window list is unknown. waymux needs Rust 1.88, newer than Debian's compiler, and has no committed `Cargo.lock` or GitHub release. Its built-in capture and input would remove the viewer connection and the recorder workaround, so reevaluate it once it publishes releases.

XWayland runs inside each Sway session, and the suite runs a GTK application through it. That covers the Xvfb fallback's purpose, so Xvfb is not used.

## Software rendering benchmark

`tests/gui/benchmark` printed these values on 2026-11-08, on a 4-vCPU KVM guest with 4 GiB of RAM and `WLR_RENDERER=pixman`.

| Metric | 1280x720 | 1920x1080 |
|---|---|---|
| Session start | 239 ms | 236 ms |
| GTK window after `run` | 175 ms | 177 ms |
| Idle CPU, one window | 0% of one core | 0% of one core |
| Session memory, RSS | 86 MiB | 100 MiB |
| Screenshot | 59 ms | 87 ms |
| Recording, 40-pixel moving bar: frames per second | 31 | 31 |
| Recording, 40-pixel moving bar: CPU of one core | 25% | 53% |
| Recording, 40-pixel moving bar: KiB per minute | 257 | 279 |
| Recording, every pixel changing: frames per second | 31 | 30 |
| Recording, every pixel changing: CPU of one core | 46% | 100% |
| Recording, every pixel changing: KiB per minute | 18042 | 40882 |

The test application animates at 30 frames per second, so those rows show that recording kept up at that rate, on an otherwise idle guest. A loaded host or a faster application can drop frames. CPU counts every process in the session, including the application.

## Optional GPU acceleration

This is a requirements list. No part of it has been tested.

- The `native-restricted` profile sets `PrivateDevices=yes`, which hides `/dev/dri`. A GPU session needs a profile that exposes one render node, with `DeviceAllow=` and access through the `render` group.
- A shared GPU does not isolate one project's memory from another's the way separate UIDs do. Exposing it adds kernel and driver attack surface, so it needs a threat-model revision before it ships.
- The supervisor sets `WLR_RENDERER=pixman` and `LIBGL_ALWAYS_SOFTWARE=1`. A GPU backend must remove both.
- `wf-recorder` encodes with `libx264` on the CPU. Hardware encoding needs a VA-API driver for the GPU, and a codec that the driver supports.

## Limits

- `type` covers the US layout only, because `wayvnc` maps key symbols through that layout.
- `run` starts applications with no accessibility bus, so accessibility-tree automation is not available.
- Only application mode exists. Desktop and isolated session modes remain optional work.
- [The threat model](THREAT_MODEL.md) lists the accepted gaps for captures and viewers.
