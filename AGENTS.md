# Agent OS

Agent OS is a headless Debian 13 workstation built for autonomous coding agents. A system agent maintains the host through a typed, audited broker. Each project runs as its own native Linux identity, with private files, a network namespace, resource limits, snapshots, and graphical sessions that exist only on demand.

The name is provisional. The repository is `agentic-os`, and the code says `agentos`.

## What we never compromise on

1. **Native first.** Projects run as ordinary Linux processes on the host's userspace. Containers and VMs stay optional profiles for workloads that ask for them.
2. **The privilege boundary holds.** Project agents get no sudo and no privileged socket. The system agent gets no root shell, and its host changes go through `hostd` as typed operations with policy, approval, and audit.
3. **No harness lock-in.** The OS knows nothing about a specific harness, model, or provider. Pi is the only harness tested so far, so treat the others as untested rather than supported.
4. **Idle costs nothing.** `hostd` is socket-activated per connection, `agentos` is a CLI with no daemon, and no graphical process exists until a session starts. A new always-running process needs a decision log entry explaining why systemd could not do the job.
5. **Every operation survives interruption.** Assume a kill or power cut at the worst line. The next run finishes the work or refuses cleanly, and it never leaves half a project behind.
6. **A control counts only when a test goes red without it.** Security claims here are negative tests that ran, in a real VM, against the real sandbox.

## How to think here

Reach for the kernel, systemd, and APT before writing a daemon. Build the smallest vertical slice that proves the behavior, then stop. Scaffold a component when implementation needs it, even if the architecture document draws it.

Keep open decisions open. `doc/ARCHITECTURE.md` separates requirements, proposals, and open questions, and a convenient implementation does not promote a proposal to a requirement.

Treat everything below as strong defaults. The developer's instructions override them.

## Glossary

- **you** means the agent reading this file and changing this repository.
- **developer** means the person directing that work.
- **dev machine** means the computer you run on. It is often not Debian, and it is not an Agent OS host.
- **host** means a machine running Agent OS. In tests, that is the VM. Test scripts call it the **guest**.
- **administrator** means the human with root on a host.
- **system agent** means a harness running as the `agentos-system` account. It maintains the host through `hostd`.
- **project** means one isolated environment: an `aos-NAME` account, a directory under `/var/lib/agent-os/projects`, a slice, and a network namespace.
- **project agent** means a harness running as a project's account. The threat model assumes it is compromised.
- **harness** means the coding agent program itself, such as Pi or Claude Code.
- **change** means one `hostd` record that moves from plan through approval to apply.
- **toolchain** means a versioned global tool under `/opt/agent-os/toolchains`, which projects select individually.
- **session** means one on-demand headless graphical environment inside a project.
- **gap** means a weakness that `doc/THREAT_MODEL.md` accepts on purpose.

## Where privilege lives

| Path | What it is | Runs as |
|---|---|---|
| `bin/agentos`, `bin/agentos-netns` | Administrator CLI and namespace helper, in Bash | root |
| `crates/hostd` | The broker, in Rust, and its client `agentos-hostctl` | broker as root, client as its caller |
| `bin/agentos-gui` | Graphical sessions, in Python | the project, inside its sandbox |
| `configs/systemd/native-restricted.properties` | The only source of sandbox settings | applied by systemd |

Bash suits root-run orchestration of existing tools. Rust is here because a root service that parses requests needs typed input. Python is here because the GUI code speaks a binary protocol and owns JSON state, and it runs unprivileged.

## The ways to hurt yourself

1. **Running the product on the dev machine.** The `agentos` package and `bin/agentos` create accounts, enable services, and load a firewall whose forward chain ends in `drop`, which cuts off Docker's bridge traffic. Run them only in the VM, where `tests/vm/deploy` installs the package and `tests/vm/vm ssh` reaches them.
2. **Colliding on the VM.** Every checkout shares the container name `agentos-test-vm` and SSH port 10022, and booting force-removes that container. A VM started from one worktree kills one running from another. Run `docker ps` first, run one suite at a time per machine, and stop the VM with `tests/vm/vm down`. Kill only processes you started, by the PID you captured.
3. **Trusting what a project wrote.** Treat every path, name, file, and backup a project can touch as attacker-controlled. Root-run code stays out of project directories: it starts a command as the project instead, as `agentos project gui` does. [Rules for later phases](doc/THREAT_MODEL.md#rules-for-later-phases) lists the specific traps, and it is required reading before changing root-run code.
4. **Building outside the pinned container.** Use `packaging/build`. It compiles with Debian's toolchain against the glibc that runs the binaries. A bare `cargo` on the dev machine links the wrong libraries and litters `crates/hostd/target`, which Git does not ignore.

## Walk every path

A feature here is rarely one code path. Before calling work done, walk this list and say which entries applied:

- **Callers.** Decide what the administrator, the system agent, and a project agent may each do, then test the refusals. `hostd` identifies callers only by `SO_PEERCRED`, never by a request field.
- **Project lifecycle.** New per-project state needs an answer at create, reboot, stop, snapshot, restore, backup, recover, and delete. `captured_children` and `excluded_children` in `bin/agentos` decide what a snapshot carries.
- **Interruptions.** Cover a kill mid-operation, a power cut, a failed first attempt, and a concurrent start.
- **The way back.** Delete removes everything create made. Restore keeps a `pre-restore` snapshot. A `hostd` outcome records its undo command. Give anything new the same exit.
- **Sandbox.** Run the feature under `native-restricted`, where `/run` is empty and `/dev/shm` is private to each command. If it needs a new opening, that is a threat-model change.
- **Install path.** `packaging/debian/agentos.install` names every file the package ships, and `packaging/build` copies only `bin`, `configs`, and `packaging/debian` into the package source. A new file reaches the VM once both know about it. A new state or service needs an answer at upgrade, remove, and purge in the maintainer scripts next to that file.
- **Administrator-owned config.** The package copies `hostd-policy.json` and `storage.conf` only when they are absent, so a changed default reaches fresh installs only.
- **CI.** A new suite needs a row in the matrix in `.github/workflows/tests.yml`. A new VM build input needs adding to the cache key there.
- **Docs and threat model.** See [Docs](#docs).

## Verifying

Needs Linux with `/dev/kvm`, Docker, OpenSSH, and `curl`. A fresh worktree has no `.vm/`, so run `tests/vm/vm build` first.

Iterate in the tight loop. `packaging/build` runs the Rust unit tests. For behavior, deploy and run the guest steps you care about, in the order the suite's `run` script lists them. Deploying resets the VM and installs your working tree, uncommitted edits included.

```bash
tests/vm/deploy
tests/vm/vm ssh 'sudo /opt/aos-tests/tests/hostd/guest/setup.sh'
tests/vm/vm ssh 'sudo /opt/aos-tests/tests/hostd/guest/packages.sh'
```

Finish with every full suite your change touches:

| You changed | Run | Minutes in CI |
|---|---|---|
| Sandbox settings, firewall, namespaces, identities | `tests/isolation/run` and `tests/integration/run` | 2 and 9 |
| `bin/agentos` project commands | `tests/integration/run` | 9 |
| Snapshots, restore, quotas, backups | `tests/storage/run` | 4 |
| `crates/hostd`, policy, toolchain catalog | `tests/hostd/run` | 4 |
| `bin/agentos-gui`, `configs/gui/packages` | `tests/gui/run` | 5 |
| `packaging/` | `tests/packaging/run` | 3 |
| `packaging/image`, `packaging/build-image`, the `vm image` verb | `tests/image/run` | 5 |
| `packaging/image`, `packaging/build-iso`, the `vm installer` verb | `tests/installer/run` | 10 |
| Anything that can affect long-running projects | `tests/soak/run` (one hour) or `tests/soak/run 360` | 12 |
| `tests/vm/` | `tests/vm/test-lifecycle` | 2 |

Most of these outlast a default command timeout, so run them in the background. A suite is done when it exits 0. All except isolation also end on a `PASS:` line.

When one fails:

- Read `.vm/results/` and `.vm/serial.log`. A failed suite usually leaves the VM up, and its disks stay until the next reset, so `tests/vm/vm ssh` can inspect the wreck.
- Check the log for a failed URL. The integration, hostd, GUI, and soak suites download while they run, and a download failure means rerun.
- Use `tests/vm/vm build --force` to rebuild the baseline. `.vm/baseline` is read-only by design.

No linter or formatter exists for this repo. Run `bash -n` on shell you touch and match the code around it, including tabs in shell.

Writing tests:

- **Test through the real CLI, in the VM, as the identity under test.** Mocks cannot tell you what systemd or the kernel will refuse.
- **Pair each `blocked` result with a control.** A row in `tests/isolation/checks.tsv` runs the same command as the legitimate owner, so a typo cannot pass as blocked. Keep that property in anything new.
- **Prove each new control.** Remove it, watch a check go red, restore it, and report that you did. [The test plan](doc/TEST_PLAN.md#prove-that-a-sandbox-setting-matters) shows the procedure for sandbox settings.
- **Extend before you add.** Add a row to `checks.tsv` or an assertion to an existing guest step. `tests/integration/guest/lib.sh` has `eq`, `between`, `status_of`, and `finish`.
- **Expect `gap` only for an accepted gap.** That row then fails when the behavior changes, which is the point.
- **Keep suites free of credentials.** `tests/integration/guest/stub_model.py` drives a full Pi tool-call loop against a local server.

## Code conventions

- **Pin every outside input.** Images use digests, GitHub Actions use commit SHAs, and downloads carry a hash. `tests/vm/image.lock`, `tests/integration/versions.env`, and `configs/toolchains/catalog.json` are the places to look.
- **Validate before use.** `bin/agentos` checks every name, ID, and label against a strict pattern before it reaches a command or a path.
- **Keep dependencies few.** `agentos-gui` uses only the Python standard library, and `hostd` has three crates. A new dependency in a root service needs a reason in the PR. Rust code has to compile with Debian's `rustc`, which lags upstream.
- **Keep `hostd` closed.** It listens only on Unix sockets, accepts typed operations, and has no way to run an arbitrary command. Unknown request fields are malformed.

## Docs

Read the one that covers your change before you edit:

- [ARCHITECTURE.md](doc/ARCHITECTURE.md) holds intent, not inventory. Components like `workspaced` and the repository tree in section 10.4 are proposals, so trust the code and the docs below for what exists. The first unchecked phase in section 12 is the current work, and section 14 lists open questions.
- [THREAT_MODEL.md](doc/THREAT_MODEL.md) covers assets, attackers, boundaries, and accepted gaps.
- [ISOLATION.md](doc/ISOLATION.md) covers identities, directory layout, networking, and each sandbox setting.
- [HOSTD.md](doc/HOSTD.md) covers the broker's protocol, change states, policy, audit, and recovery.
- [STORAGE.md](doc/STORAGE.md) covers subvolumes, snapshots, quotas, and backups.
- [GUI.md](doc/GUI.md) covers graphical sessions, capture, and remote viewing.
- [CLI.md](doc/CLI.md) covers `agentos` commands.
- [ADMINISTRATION.md](doc/ADMINISTRATION.md) covers installing and maintaining a host.
- [TEST_PLAN.md](doc/TEST_PLAN.md) covers VM commands and what each suite proves.

Keep them true in the same change:

- A change touching privilege escalation, credentials, filesystem mounts, networking, or GUI capture revises `doc/THREAT_MODEL.md`, naming the check that proves each new control.
- An architectural change adds a row to the decision log in section 15 of the architecture document, and a finished roadmap item gets its checkbox.
- Gap numbers in the threat model are permanent, because PRs cite them. Give a new gap the next unused number.
- `tests/vm/baseline` generates `doc/BASELINE.md`, so regenerate it to change it.
- `doc/site/build` generates the site in `docs/` from `doc/*.md`, and GitHub Pages serves that directory. Run it after every edit under `doc/` and commit the result. `doc/site/build --check` exits 1 while `docs/` is stale. Edit the Markdown for content and `docs/assets` for the theme. A new page needs a row in `PAGES` in that script.
- Record measurements only from runs you made, with the conditions that produced them.

## Commits and pull requests

- Write subjects in the imperative. Use the body for why and for the decisions a reader would question.
- Keep one phase or vertical slice per PR.
- State verification as what ran and what it reported: suites, check counts, and a link to the workflow run. Add a known-limits section naming what stayed untested.
- Pull requests get no automatic checks. Each workflow run uses about 60 minutes of the private repository's Actions allowance, so start it once, when the branch is ready to merge.

```bash
gh workflow run Tests --ref BRANCH
```
