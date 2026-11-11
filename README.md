<p align="center"><img src="assets/hero.svg" width="880" alt="Agent OS"></p>

# Agent OS

Agent OS is a headless Debian 13 workstation built for autonomous coding agents. A system agent maintains the host through a typed, audited broker. Each project runs as its own native Linux identity, with private files, a network namespace, resource limits, snapshots, and graphical sessions that exist only on demand.

The name is provisional. The repository is `agentic-os`, and the code says `agentos`.

**Documentation: [maddeye.github.io/agentic-os](https://maddeye.github.io/agentic-os/)**

## What it does

- **Isolated projects.** `agentos project create NAME` makes an `aos-NAME` account with its own directory, systemd slice, network namespace, and CPU, memory, and process limits. Project agents get no sudo.
- **A broker instead of root.** The system agent changes the host only through `hostd`, which accepts typed operations such as APT installs and toolchain changes, checks them against policy, waits for approval, and records an audit trail.
- **Snapshots and backups.** Each project is a Btrfs subvolume with quotas, snapshots, restore, and off-host backups.
- **Graphical sessions on demand.** A project can start a headless Wayland session, drive an application with keyboard and mouse, take screenshots, and record video. Nothing graphical runs until a session starts.
- **Idle costs nothing.** `hostd` is socket-activated, the CLI has no daemon, and the OS knows nothing about a specific harness or model.

## Status

The first five roadmap phases are done: isolation, the broker, storage, graphical sessions, and an installable image. Agent OS installs from an ISO, a VM image, or a Debian package. Containers, VMs, GPU sessions, and per-project egress policies are still open. See the [roadmap](doc/ARCHITECTURE.md#12-implementation-roadmap).

Pi is the only harness tested so far. Others may work but are untested.

## Install

The [administrator guide](doc/ADMINISTRATION.md) covers installing a host from the ISO, the VM image, or the package, logging in for the first time, and creating a project.

## Develop

Building and testing need Linux with `/dev/kvm`, Docker, OpenSSH, and `curl`. Every security claim is a test that runs in a real VM against the real sandbox.

```bash
packaging/build          # build the package in the pinned container
tests/vm/vm build        # build the test VM
tests/isolation/run      # run a suite
```

[AGENTS.md](AGENTS.md) holds the conventions for changing this repository, and [the test plan](doc/TEST_PLAN.md) says what each suite proves.

The documentation site is generated from `doc/*.md` by `doc/site/build` and published on every push to `main`.
