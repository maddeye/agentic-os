# How to run the test procedure

This procedure builds the test VM, proves snapshot and reset behavior, runs the isolation and integration suites, and regenerates the baseline.

## Check the prerequisites

You need Linux with `/dev/kvm`, Docker, OpenSSH, and `curl`. The scripts run QEMU in a pinned Debian container, so you do not install QEMU. Agent OS itself does not depend on Docker.

## Build the VM

Run this command from the repository root:

```bash
tests/vm/vm build
```

The last line is `vm: baseline ready`. The command downloads the image pinned in `tests/vm/image.lock` and verifies its SHA-512 sum. It installs packages from the pinned APT snapshot. `.vm/baseline` is read-only afterward, and `.vm/baseline/packages.txt` lists every installed package and version.

To rebuild from nothing, add `--force`. Two builds on 2026-11-08 produced identical package lists.

## Use the VM

| Command | Result |
|---|---|
| `tests/vm/vm up` | Boots the VM. Does nothing if it is running. |
| `tests/vm/vm ssh [COMMAND]` | Boots if needed and connects as `admin`, which has passwordless sudo. |
| `tests/vm/vm down` | Shuts down the VM. |
| `tests/vm/vm reset` | Stops the VM and discards all changes since the baseline. |
| `tests/vm/vm kill` | Cuts the VM's power. |
| `tests/vm/vm image FILE [--no-key]` | Discards `.vm/run` and boots a copy of a built image on a 24 GiB disk. Without `--no-key`, the first boot enrolls the test key. |
| `tests/vm/vm installer ISO [--uefi] [--keep-disk] [--key FILE]` | Boots the ISO with a blank 24 GiB disk and waits at the installer's first prompt. `--uefi` uses UEFI firmware and attaches the ISO as a 17 GiB USB stick instead of a CD. `--keep-disk` keeps the disk from the last run. `--key` adds a USB stick that holds the file as `agentos-admin.pub`. Later boots of that disk keep the same firmware. |
| `tests/vm/vm boot-code` | Prints how many non-zero bytes the root disk has in its boot code. It works while the VM runs. |
| `tests/vm/vm export-data FILE` | Writes the stopped VM's data disk to a compressed qcow2 under `.vm`. `packaging/build-image` uses it. |
| `tests/vm/vm snapshot save NAME` | Stops the VM and saves both disks. |
| `tests/vm/vm snapshot restore NAME` | Stops the VM and restores both disks. |
| `tests/vm/vm snapshot list` | Lists saved snapshots. |

SSH listens on `127.0.0.1:10022` only. The VM's key and disks live in `.vm/`, which Git ignores.

## Prove the VM tooling

```bash
tests/vm/test-lifecycle
```

The last line is `PASS: snapshot restore and reset`.

## Run the isolation suite

```bash
tests/isolation/run
```

The command resets the VM, installs this checkout, creates projects `alpha` and `beta` with `agentos`, and exits non-zero on any failure. The attacker is `alpha`, and the victim is `beta`. It writes `results.tsv` and `transcript.log` to `.vm/results/isolation-TIMESTAMP/`. The transcript holds each probe's real error message.

Every row of `tests/isolation/checks.tsv` runs in two modes:

- `plain` uses only separate UIDs. It shows what the sandbox adds, and it proves that the probes can succeed.
- `restricted` runs each command through `agentos project run`.

A row passes when the attacker's result matches the expected value and the control succeeds. The control runs the same command as the legitimate owner, so a probe with a typo cannot pass as `blocked`. Exit codes for shell misuse, timeouts, missing executables, and systemd setup failures count as `error`, and `error` always fails.

## Add a check

Add a tab-separated row to `tests/isolation/checks.tsv`. Use exit 0 for "the access worked". Expect `gap` only for an access that `doc/THREAT_MODEL.md` lists as accepted.

## Prove that a sandbox setting matters

To test a setting, delete its line from `configs/systemd/native-restricted.properties`, run `tests/isolation/run`, and restore the line. The rows that fail are the ones that depend on the setting.

## Run the integration suite

```bash
tests/integration/run
```

The last line is `PASS: integration`. The command needs internet access. It tests these behaviors through the `agentos` CLI:

- Project creation, name validation, UID allocation, and command execution.
- A project-local Node.js and Pi install, with versions pinned in `tests/integration/versions.env`.
- A full Pi tool-call loop against `stub_model.py`, a local server that needs no credentials.
- CPU, memory, and task limits for one command, for several commands together, and for all projects together.
- Project network isolation, internet access, and name resolution.
- A detached command that outlives a killed SSH client.
- Data, identities, and tools across a reboot.
- Deletion with running processes, symlinks, read-only subvolumes, a failed first attempt, and concurrent command starts.
- Recovery of a crashed create, and refusal of accounts that `agentos` did not allocate.

## Run the hostd suite

```bash
tests/hostd/run
```

The last line is `PASS: hostd`. The command needs internet access. It tests these behaviors:

- The exit criterion: the system agent requests `ripgrep`, an administrator approves, and both projects run it.
- Self-approval, stale plans, republished and tampered archives, failed upgrades, rejected changes, policy limits, and hostile package names.
- Socket access, forged identity, malformed input, slow clients, full connection slots, and what the system agent cannot do.
- Two global Node.js versions selected per project, read-only access, bad digests, and failed checks.
- A broker killed during a package script and during a toolchain install, a concurrent request, and a power cut.

`packaging/build` runs the Rust unit tests and builds the binaries and the `agentos` package with Debian's toolchain in a pinned container. Every VM deployment runs it, so a failing unit test stops the suites.

## Run the storage suite

```bash
tests/storage/run
```

The last line is `PASS: storage`. It tests these behaviors:

- Subvolume layout, per-project disk limits, and subvolumes that try to escape a limit or forge `btrfs` output.
- Snapshot contents, listing, retention, snapshots of a busy project, and interrupted snapshots.
- Recovery after a destructive edit, undoing a restore, and a restore that fails before and after the swap.
- Refusing snapshots, pruning, and stopping the largest project under disk pressure.
- The exit criterion: a backup leaves the VM through standard output, the VM resets, and `recover` rebuilds the project.
- Refusal of truncated, corrupted, and crafted backups, with nothing left behind.

`tests/storage/benchmark` prints the measurements that [STORAGE.md](STORAGE.md) records.

## Run the GUI suite

```bash
tests/gui/run
```

The last line is `PASS: gui`. The command needs internet access, because it installs the GUI packages and Chromium through `hostd`. It tests these behaviors:

- The exit criterion: a project agent starts a session, drives a real GTK application with the mouse and keyboard, captures screenshots and video, and stops the session.
- Chromium inside a session, with its own user namespace sandbox.
- Two projects with the same session name, Wayland, compositor, viewer, bus, and X11 sockets, and no TCP listener.
- Remote viewing through SSH, a refused SSH key, and another project's view of the session.
- Each way that a session ends: `stop`, `agentos project stop`, the starting command exiting, a killed supervisor, and `delete`.

`tests/gui/benchmark` prints the measurements that [GUI.md](GUI.md#software-rendering-benchmark) records.

## Run the packaging suite

```bash
tests/packaging/run
```

The last line is `PASS: packaging`. `tests/vm/deploy` already installs the package for every suite, and this one tests the package itself through `dpkg` and `apt-get`:

- A refused removal while a project exists.
- An upgrade under a live project, which keeps its process, network, disk limit, administrator edits, and disabled units, and still applies a new firewall policy.
- A `configure` killed partway through, then finished by `dpkg --configure -a`.
- Remove, reinstall, and purge, including that a UID is not reused and the firewall is gone.
- A refused install off Btrfs that unpacks nothing, with an install on Btrfs as its control.

## Run the image suite

```bash
tests/image/run
```

The last line is `PASS: image`. It builds the image, then boots the file that `packaging/build-image` published, with nothing installed first:

- A first boot without a key, where nobody can log in.
- A first boot with a key, on a disk larger than the image. The system has no failed unit, the data filesystem has grown, and only keys and no root login are accepted.
- Two projects that run, stay apart, reach the internet, and restore a snapshot.
- A power cut, after which the data, the network, and the login are still there.
- A second machine from the same image, with its own host key and machine ID.

## Run the installer suite

```bash
tests/installer/run
```

The last line is `PASS: installer`. It builds the ISO and answers the installer on the serial console. The VM's serial port accepts input on `127.0.0.1:10023`. Only what the installer wrote boots afterward:

- Under BIOS from a CD, with the key pasted. A value that is not a public key, a private key, and a disk that is not listed are all refused.
- A refused confirmation that leaves the installed boot code alone.
- A power cut in the middle of a reinstall, which leaves no boot code, then a run that finishes.
- The host key fingerprint in the report matches the one the machine serves, and a key that was not enrolled cannot log in.
- `tests/image/guest/first_boot.sh` on the installed machine, the same acceptance steps as the image.
- An upgrade of `agentos` through `hostd`, under a running project, then a reboot. Project data, snapshots, toolchains, and the network survive.
- A destroyed root, a power cut during its repair, and a repair that finishes. Accounts, UIDs, limits, data, snapshots, and the audit log survive, and the toolchain installs again. A repair of an unreadable data partition stops without changing anything.
- Under UEFI from a USB stick, with the key read from a second stick. The medium is large enough to qualify and still is not offered, and neither stick can be chosen.

## Run the suites in GitHub Actions

`.github/workflows/tests.yml` runs only when you start it, because each run uses about 29 minutes of the private repository's Actions allowance. To start it, use the Actions tab or run `gh workflow run Tests --ref BRANCH`. GitHub offers both only after the workflow file is on `main`.

The `prepare` job fails if the runner has no `/dev/kvm`. It also runs the Rust unit tests. It builds the VM baseline and the two Docker images once, and stores them in the Actions cache. To rebuild them, change an input of the cache key in the workflow, such as `tests/vm/image.lock`.

Each suite then runs in its own job and its own VM, the same as a local run. One failing suite does not stop the others. Each job uploads `.vm/results/` and `.vm/serial.log` as an artifact named `SUITE-diagnostics`. A failed job adds the guest journal as `journal.log`.

To reproduce a failure, run the suite's command from the workflow matrix on a machine with `/dev/kvm`.

The integration and hostd suites download from `snapshot.debian.org`, `nodejs.org`, and the npm registry while they run. If one of them fails on a download, the log shows the failing URL. Rerun the failed job.

## Regenerate the baseline

```bash
tests/vm/baseline
```

The command writes `doc/BASELINE.md` from a capability probe and three fresh boots.

The baseline does not yet cover these items from section 8.3 of the architecture, because the components do not exist: harness startup, repository indexing, concurrent builds, global package promotion timing, behavior under pressure, and recovery timing. GUI startup and capture are in [GUI.md](GUI.md#software-rendering-benchmark).
