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
- Self-approval, stale plans, rejected changes, policy limits, and hostile package names.
- Socket access, forged identity, malformed input, and what the system agent cannot do.
- Two global Node.js versions selected per project, read-only access, bad digests, and failed checks.
- A broker killed during a package script and during a toolchain install, a concurrent request, and a power cut.

`packaging/build` runs the Rust unit tests and builds the binaries with Debian's compiler in a pinned container. Every VM deployment runs it, so a failing unit test stops the suites.

## Run the suites in GitHub Actions

`.github/workflows/tests.yml` runs only when you start it, because each run uses about 17 minutes of the private repository's Actions allowance. To start it, use the Actions tab or run `gh workflow run Tests --ref BRANCH`. GitHub offers both only after the workflow file is on `main`.

The `prepare` job fails if the runner has no `/dev/kvm`. It also runs the Rust unit tests. It builds the VM baseline and the two Docker images once, and stores them in the Actions cache. To rebuild them, change an input of the cache key in the workflow, such as `tests/vm/image.lock`.

Each suite then runs in its own job and its own VM, the same as a local run. One failing suite does not stop the others. Each job uploads `.vm/results/` and `.vm/serial.log` as an artifact named `SUITE-diagnostics`. A failed job adds the guest journal as `journal.log`.

To reproduce a failure, run the suite's command from the workflow matrix on a machine with `/dev/kvm`.

The integration and hostd suites download from `snapshot.debian.org`, `nodejs.org`, and the npm registry while they run. If one of them fails on a download, the log shows the failing URL. Rerun the failed job.

## Regenerate the baseline

```bash
tests/vm/baseline
```

The command writes `doc/BASELINE.md` from a capability probe and three fresh boots.

The baseline does not yet cover these items from section 8.3 of the architecture, because the components do not exist: harness startup, repository indexing, concurrent builds, global package promotion timing, snapshot and restore latency, GUI startup and capture, behavior under pressure, and recovery timing.
