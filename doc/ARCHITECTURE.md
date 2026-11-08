# Agent OS — Architecture & Implementation Reference

> **Working name only:** Agent OS is a provisional development name. The final project/product name will probably change. Do not treat this as a finalized brand, domain, executable namespace, or trademark.
>
> **Document status:** Draft architecture / implementation reference (v0.1)  
> **Last reviewed:** 2026-11-08  
> **Audience:** Coding agents and contributors implementing the distribution  
> **Implementation status:** Proposed design; the components described below are not assumed to exist.

## 0. Instructions for Coding Agents

This document is the source of architectural intent, not a claim of implemented functionality.

1. Preserve the **native-first** approach. Do not introduce a mandatory container, VM, Kubernetes, or custom agent orchestration runtime.
2. Preserve the privilege boundary between the system-maintenance agent and project-scoped agents. Never give ordinary project agents general-purpose sudo access or a privileged host socket.
3. Prefer existing kernel, systemd, and package-manager functionality over custom daemons.
4. A coding harness (Pi, Claude Code, Codex, OpenCode, etc.) must be replaceable. Do not bind the OS to a specific harness, model, or provider.
5. Project agents may use normal Linux tools and install project-scoped dependencies. The system agent may request system-wide changes through constrained, auditable authorization.
6. Keep the host headless by default; graphical environments are created on demand per project.
7. Distinguish requirements, proposals, experiments, and open decisions. Do not silently convert an open decision into a fixed design.
8. Implement in small, testable vertical slices.
9. Require a threat-model review for changes involving privilege escalation, credentials, filesystem mounts, networking, or GUI capture.
10. Record architectural changes in the decision log and revise acceptance criteria accordingly.

---

## 1. Vision

Agent OS is a **headless, remotely accessible Linux development workstation optimized for autonomous coding agents**.

The operating system can itself be maintained by a coding agent, while each project receives a native development environment with independent identity, state, limits, and permissions.

**Core principle:**

> The host is an agent-maintainable workstation; projects are agent-operated native Linux environments that do not automatically inherit host administration privileges.

Agent OS is not an AI model, coding harness, workflow orchestrator, general-purpose server platform, or permanently running graphical desktop.

### 1.1 Goals

- Run standard coding harnesses and conventional CLI tools natively.
- Allow a system agent to maintain global packages, toolchains, services, and OS configuration.
- Allow project agents to install dependencies, modify repositories, build software, and run tests within their assigned scope.
- Support multiple independent projects and agents on one machine.
- Share versioned development toolchains without forcing identical versions on every project.
- Preserve project files, agent state, caches, and persistent sessions.
- Provision on-demand graphical environments for testing native desktop applications.
- Capture screenshots, videos, application logs, and optional input-event traces.
- Support snapshots, recovery, and external backups.
- Produce installable Debian-derived OS images without building Linux from scratch.
- Maintain a low idle resource footprint.

### 1.2 Non-goals

For the initial releases:

- Creating a new Linux kernel or package manager.
- Replacing APT, Git, systemd, or SSH.
- Reimplementing agent reasoning, planning, memory, or workflow orchestration.
- Requiring a graphical desktop, web UI, or specific IDE.
- Kubernetes or multi-machine scheduling.
- Mandatory containers or virtual machines.
- Guaranteeing strong isolation through Unix identities alone.
- Full process checkpoint/restore.
- Guaranteed pixel-identical graphical rendering across different hardware.

---

## 2. Architectural Decisions

| Topic | Current decision | Status |
|---|---|---|
| Development name | Agent OS | Temporary |
| Base distribution | Debian 13 Stable (Trixie) | Preferred |
| Distribution model | Minimal Debian + custom packages | Proposed |
| Default execution | Native Linux processes | Requirement |
| Agent roles | Human admin, system agent, project agent | Requirement |
| Project isolation | Dedicated Linux identities, systemd, namespaces | Requirement |
| Containers | Optional rootless OCI runtime | Proposed |
| Virtual machines | Optional for high-risk workloads | Future |
| System packages | APT/dpkg through controlled broker | Proposed |
| Toolchains | Shared versioned tools + project-local installations | Proposed |
| Filesystem | Btrfs | Preferred |
| Remote access | OpenSSH over private networking | Proposed |
| Graphics | Ephemeral headless Wayland sessions | Requirement |
| GUI backend | Evaluate waymux, Sway, Weston | Open |
| Legacy GUI | Xvfb/X11 fallback | Proposed |
| Implementation language | Rust | Preferred |
| Interfaces | CLI first, API later | Proposed |

### 2.1 Why Debian?

Debian Stable is preferred because the host should remain reliable during long-running autonomous development operations.

Modern development tools can be managed independently from Debian packages.

This separates:

- Stable operating system components.
- Fast-moving programming language toolchains.
- Project-specific dependencies.
- AI coding harnesses.

Arch Linux remains an alternative if newer system packages and rolling-release development become more valuable than conservative host updates.

NixOS remains technically viable but introduces compatibility considerations for arbitrary prebuilt Linux binaries and conventional installation scripts.

The distribution choice should be revisited only if benchmarks or implementation requirements justify it.

---

## 3. Trust and Execution Model

### 3.1 Human Administrator

The human administrator:

- Owns the workstation and its security policies.
- Authorizes high-risk global changes.
- Manages emergency access and recovery credentials.
- Can inspect all projects when explicitly acting as host administrator.
- Defines which system-agent operations may run autonomously.

### 3.2 System-Maintenance Agent

The system-maintenance agent:

- Runs its coding harness under a non-root Linux identity.
- Can inspect approved host state.
- Can request changes to packages, toolchains, services, and configuration.
- Uses a privileged broker for authorized modifications.
- Has no unrestricted root shell by default.
- Does not automatically inherit project credentials or write access to project data.

Its purpose is to make the OS itself maintainable through agentic coding.

### 3.3 Project Agent

A project agent:

- Runs as an unprivileged project-specific identity.
- Can read and modify its assigned project.
- Can use ordinary Linux executables, compilers, package managers, and development tools.
- Can install dependencies into project-local directories.
- Can run native applications, background processes, and GUI sessions.
- Cannot install global APT packages.
- Cannot modify global development toolchains.
- Cannot access unrelated private project files.
- Cannot invoke privileged host-maintenance operations.

A project agent may request that a dependency be promoted to global scope, but cannot authorize that promotion itself.

### 3.4 Security Invariants

The implementation must test the following:

1. Project A cannot access Project B's private state, credentials, or graphical sockets.
2. Project agents cannot modify host configuration, APT databases, system services, or boot settings.
3. Project agents cannot use privileged sockets or leaked credentials to escalate permissions.
4. The system-maintenance harness itself does not run as root.
5. Global executable directories cannot be modified by project identities.
6. GUI sessions, D-Bus sockets, recordings, and viewer access are isolated by project.
7. Resource limits are not treated as complete security isolation.
8. Kernel vulnerabilities and exposed system services remain part of the threat model.
9. Package installation scripts are recognized as potentially privileged code.
10. Approved system modifications are audited and have tested recovery procedures.

### 3.5 Execution Profiles

| Profile | Purpose | Isolation |
|---|---|---|
| `native-trusted` | Explicitly trusted interactive development | Normal unprivileged Linux process, resource limits |
| `native-restricted` | Default autonomous project execution | Project UID, systemd restrictions, namespaces, cgroups |
| `container` | Projects needing stronger dependency or process separation | Rootless OCI container |
| `vm` | Highly untrusted workloads or alternative operating systems | Separate guest kernel |

**Native-first means the agent uses the host's normal Linux userspace. It does not mean unrestricted filesystem access or administrative privileges.**

Project isolation should use Linux-native primitives before introducing additional runtimes.

Systemd filesystem restrictions have context-dependent limitations, particularly in user-managed units. All relevant restrictions must be verified with negative tests.

IPC, D-Bus, host sockets, devices, and network connectivity require separate consideration.

---

## 4. Component Architecture

```text
Remote Developer / IDE / Coding Agent
                  |
           Private Network
                  |
+------------------------------------------------+
| Agent OS                                       |
| Debian-based, headless Linux host              |
|                                                |
| System-Maintenance Agent                       |
|          |                                     |
|          v                                     |
| hostd: Privileged Host Maintenance             |
|                                                |
| workspaced: Native Project Lifecycle           |
|          |                                     |
|          +----------------------+              |
|          |                      |              |
|          v                      v              |
| Project A                  Project B           |
| Dedicated UID              Dedicated UID       |
| Native Agents              Native Agents       |
| Project Toolchains         Project Toolchains  |
| Project Workspace          Project Workspace   |
| Optional GUI               Optional GUI        |
|                                                |
| systemd + cgroups v2 + Linux namespaces        |
| Btrfs + shared read-only toolchains            |
|                                                |
| Optional OCI / VM runtimes                     |
+------------------------------------------------+
```

### 4.1 `workspaced`

Proposed service responsible for native project lifecycle management.

Responsibilities:

- Create, list, inspect, and delete projects.
- Allocate and manage project Linux identities.
- Configure ownership and private project directories.
- Create project homes, workspaces, caches, artifacts, and state directories.
- Start ordinary Linux commands and coding harnesses.
- Configure systemd execution units and cgroup resource limits.
- Persist project metadata.
- Manage lifecycle state across disconnections and restarts.
- Coordinate filesystem snapshots.
- Authorize project-owned graphical sessions.

It should use existing Linux facilities instead of implementing its own process supervisor.

A dedicated Rust daemon should only be introduced when shell scripts and systemd units no longer provide a sufficient interface.

### 4.2 `hostd`

Proposed privileged host-maintenance broker.

It should:

- Operate as a narrowly scoped root-owned service.
- Authenticate requests using local OS identities.
- Expose a permission-restricted Unix socket.
- Accept typed operations rather than arbitrary shell strings.
- Evaluate authorization policies.
- Record every privileged change.
- Execute verification and recovery steps.

Potential operations:

```text
PackageInstall
PackageRemove
PackageUpgrade

ToolchainInstallGlobal
ToolchainRemoveGlobal

ServiceEnableDisable

SystemStatus
UpgradePlan
ChangeHistory

CreateRecoveryPoint
RestoreRecoveryPoint
```

The ordinary API must not include unrestricted commands equivalent to:

```text
run_as_root(command: string)
```

Such functionality would undermine the agent trust boundaries.

### 4.3 Authorization Levels

**Automatic**

Allowlisted low-risk operations with bounded impact, such as selected Debian package installations.

**Approval required**

Kernel upgrades, bootloader changes, firewall or SSH modifications, new package repositories, privileged services, and arbitrary global binary installations.

**Denied**

Unauthorized project-agent host changes, attempts to bypass policy, and access to unrelated project or host credentials.

### 4.4 Storage Module

Initially implemented as a library rather than an independent service.

Responsibilities:

- Btrfs subvolume creation and deletion.
- Snapshot creation and restoration.
- Retention policies.
- Path validation.
- Space accounting.
- Backup integration.
- Safe coordination with running processes.

### 4.5 Proposed CLI

The following commands are illustrative and do not yet exist.

```bash
agentos project create my-app
agentos project shell my-app
agentos project run my-app -- pi

agentos project snapshot my-app --label before-refactor
agentos project restore my-app --snapshot SNAPSHOT_ID

agentos system package install ripgrep
agentos system change history

agentos desktop create my-app --resolution 1920x1080
agentos desktop run my-app -- ./target/debug/my-app
agentos desktop screenshot my-app --output ui.png

agentos desktop record start my-app
agentos desktop record stop my-app
agentos desktop stop my-app
```

The exact CLI and service names are provisional because the project name is not finalized.

---

## 5. Package and Toolchain Management

Agent OS has three software installation scopes.

| Scope | Location | Maintainer |
|---|---|---|
| Host OS | `/usr`, `/etc`, system directories | System agent through broker |
| Shared toolchains | `/opt/agent-os/toolchains` | System agent through broker |
| Project tools | Project home and workspace | Project agent |

### 5.1 Host Packages

APT and dpkg remain the host package management system.

The system agent can request installations, upgrades, and removals through `hostd`.

Project agents cannot directly modify the host package database.

### 5.2 Shared Toolchains

Example layout:

```text
/opt/agent-os/
  toolchains/
    node/
      24/
      26/
    java/
      21/
      25/
    python/
      3.13/
      3.14/
    rust/
```

Global toolchains must be:

- Versioned.
- Shared across projects.
- Readable and executable by authorized projects.
- Not writable by project agents.
- Installed through a staged verification process.
- Selectable independently for each project.

Use existing tooling such as mise, rustup, uv, SDKMAN, or vendor-provided installers where appropriate.

Do not develop a completely new language package manager.

### 5.3 Project-Specific Tools

Project agents can install and manage tools inside their own scope.

Examples:

```bash
npm install
uv sync
cargo install --root "$HOME/.local" just
mise use node@24
```

Project-local installations should never require global host privileges.

### 5.4 Dependency Promotion

A project agent may identify a tool that would be useful globally.

The expected workflow is:

```text
Project discovers dependency
          |
          v
Project requests global installation
          |
          v
System agent evaluates request
          |
          v
hostd checks policy
          |
          v
Install, verify, publish, audit
```

A global tool should become available to projects without exposing the toolchain directory for modification.

Privileged executable search paths must never include project-writable directories.

---

## 6. Filesystem and Persistence

### 6.1 Preferred Filesystem

Btrfs is the preferred starting point.

Reasons:

- Copy-on-write snapshots.
- Subvolumes.
- Transparent compression.
- Efficient project cloning.
- Native Linux kernel integration.
- Send/receive for replication.

The exact quota, compression, and retention strategy needs benchmarking.

### 6.2 Proposed Layout

```text
/
  Host operating system

/opt/agent-os/
  toolchains/
    Root-owned shared development tools

/var/lib/agent-os/
  metadata/
    Project definitions and host management state

  projects/
    project-a/
      workspace/
      home/
      cache/
      state/
      artifacts/

    project-b/
      workspace/
      home/
      cache/
      state/
      artifacts/

  snapshots/
    Managed recovery snapshots
```

Workspace directories should use explicit subvolumes where lifecycle management requires them.

Nested Btrfs subvolumes are not automatically included recursively in parent snapshots. Snapshot boundaries must therefore be planned and tested.

### 6.3 Snapshot Requirements

- Support manual snapshots.
- Support snapshots at approved task boundaries.
- Support snapshots before destructive changes.
- Avoid snapshots after every shell command.
- Track disk consumption.
- Apply retention limits.
- Stop relevant processes before restoring active filesystems.
- Preserve project metadata necessary to restore workspace state.

### 6.4 Backups

Snapshots are not backups.

Implement an independent external backup mechanism.

Potential technologies include Btrfs send/receive and restic.

A restore test on a fresh VM must be part of the acceptance suite.

### 6.5 Host Recovery

Do not assume Btrfs root snapshots automatically restore the bootloader, kernel, initramfs, EFI partition, or independently mounted persistent directories.

Host rollback requires an explicitly designed boot and recovery process.

For v1, prioritize:

- Audited change history.
- Configuration backups.
- Tested rescue procedures.
- Known-good installation images.
- Safe package transaction recovery.

Full bootable rollback can follow after proving it works across OS updates.

---

## 7. On-Demand Graphical Testing

Agent OS remains headless when idle.

Project agents can create temporary graphical environments without installing or launching a permanent host desktop.

### 7.1 Required Capabilities

- Start and stop multiple named graphical sessions.
- Associate each session with a project.
- Configure virtual display resolution.
- Launch native GUI applications.
- Support Wayland and, where compatible, XWayland.
- Provide keyboard and mouse input automation.
- Capture screenshots.
- Record videos.
- Provide optional remote live viewing.
- Store artifacts and metadata within the project.
- Clean up orphaned sessions.
- Work without a physical GPU.
- Add GPU acceleration later where supported.

### 7.2 Session Modes

**Application mode — Default**

Launch an individual application with a minimal compositor.

Targets include GTK, Qt, Tauri, Electron, Slint, browsers, and similar applications.

**Desktop mode — Optional**

Launch a lightweight or complete desktop environment for integration testing involving notifications, window management, settings, or multiple applications.

**Isolated mode — Optional**

Use an OCI container or VM for applications requiring stronger isolation or a different userspace.

### 7.3 GUI Backend Candidates

**waymux**

First experiment.

Its published functionality includes headless Wayland sessions, capture, input automation, live viewing, and agent-oriented interfaces.

Packaging, reliability, and API stability must be evaluated before making it a dependency.

**Headless Sway**

Alternative based on the wlroots ecosystem.

Potential companion tools include grim, wf-recorder, wtype, and wayvnc.

**Weston**

Alternative compositor with headless and remote backend options.

**Xvfb**

Fallback for legacy X11 applications.

No backend should become mandatory before testing real applications.

### 7.4 GUI Artifact Layout

```text
artifacts/gui/
  session-id/
    metadata.json

    screenshots/
      0001.png
      0002.png

    recording.mkv
    inputs.jsonl

    logs/
```

Metadata should describe:

- Project and session ID.
- Application command.
- Display backend.
- Resolution.
- Capture timestamps.
- Recording codec.
- Process exit status.
- Test result if available.

Input traces may include sensitive information and require redaction and retention controls.

### 7.5 GUI Security

- Sessions must run under project identities.
- Wayland sockets must not be shared across unrelated projects.
- D-Bus and desktop IPC should be appropriately isolated.
- Remote viewers must be authenticated.
- No public viewer binding by default.
- Recordings and screenshots remain project-private.
- A graphical session is not a security sandbox.

### 7.6 Rendering and Performance

Software rendering must work on CPU-only systems.

GPU acceleration should be optional.

Do not assume that software-rendered recording can reliably sustain 30 or 60 FPS.

Benchmark real capture throughput, latency, memory use, and CPU load.

Pixel-perfect reproducibility is not guaranteed across different hardware, fonts, compositors, and GPU drivers.

---

## 8. Resource Management and Performance

Use existing Linux mechanisms wherever possible.

### 8.1 Execution Controls

- systemd services and scopes.
- cgroups v2.
- CPU quotas and weights.
- MemoryHigh and MemoryMax.
- Process count limits.
- I/O weighting.
- PSI-based resource pressure monitoring.

Reserve enough resources for host administration and SSH access even during heavy project builds.

### 8.2 Cache Strategy

Support:

- Shared read-only toolchains.
- Project-private writable package caches.
- Safe compiler caches.
- Persistent project-specific language-server state.
- Selective cache reuse when ownership and integrity are controlled.

Do not blindly expose shared writable caches across security boundaries.

### 8.3 Benchmark Requirements

Measure:

1. Idle OS CPU and memory consumption.
2. Cold and warm project startup.
3. Coding harness startup.
4. Repository indexing.
5. Concurrent builds and tests.
6. Local toolchain installation.
7. Global package promotion.
8. Snapshot and restore latency.
9. GUI session startup.
10. Screenshot latency and video throughput.
11. Host responsiveness under resource pressure.
12. Recovery after reboot, process failure, SSH disconnect, and interrupted package changes.

Compare against a minimal Debian baseline using equivalent development tooling.

Do not claim performance improvements without measurements.

---

## 9. Networking and Credential Management

### 9.1 Remote Access

Use OpenSSH with key-based authentication.

Prefer private networking such as WireGuard or Tailscale.

Hardened deployment defaults:

- Disable password authentication.
- Disable remote root login.
- Restrict public ingress.
- Explicitly expose development servers when necessary.
- Keep administrative interfaces private.

### 9.2 Project Networking

Projects may need local servers, databases, browsers, and external development services.

Future capabilities should include:

- Per-project port allocation.
- Port collision management.
- Network restrictions for autonomous operations.
- Controlled access to development services.
- Optional per-project network namespaces.

### 9.3 Credentials

Separate:

- Host administrator credentials.
- System-agent credentials.
- Project credentials.
- Git credentials.
- Package registry credentials.
- Optional external service credentials.

Avoid distributing permanent unrestricted host secrets to project agents.

Use scoped or short-lived credentials where practical.

A secret delivered to an agent process must be treated as visible to that process.

### 9.4 Auditing

Record privileged host operations with:

- Requesting identity.
- Requested action.
- Authorization decision.
- Time.
- Result.
- Verification.
- Recovery reference where applicable.

Avoid logging secret values and unnecessary sensitive terminal input.

---

## 10. Distribution Build and Update Strategy

### 10.1 Initial Target

- Debian 13 Stable.
- AMD64 first.
- QEMU/KVM testing.
- Minimal headless system.
- Custom Agent OS packages.
- Installer ISO after the core runtime is validated.

### 10.2 Build Process

1. Construct a minimal Debian environment using standard Debian tooling.
2. Package Agent OS components as `.deb` packages.
3. Maintain custom systemd units and policy configuration.
4. Produce a VM image.
5. Validate boot, networking, and isolation.
6. Build an installer or live image using an evaluated Debian image workflow.
7. Test clean installation, upgrades, and recovery.
8. Publish versioned, documented build artifacts.

Avoid maintaining a fork of the entire Debian package repository.

### 10.3 Update Strategy

System updates must be controlled through `hostd`.

Requirements:

- Generate upgrade plans.
- Detect package conflicts.
- Identify affected services.
- Create appropriate recovery points.
- Request approval for high-risk operations.
- Apply updates.
- Validate host health.
- Reboot only according to policy.
- Record the result.

A successful APT operation does not guarantee a bootable recovery state.

### 10.4 Proposed Repository

```text
agent-os/
  README.md

  docs/
    ARCHITECTURE.md
    THREAT_MODEL.md
    DECISIONS.md
    TEST_PLAN.md

  packaging/
    debian/
    images/
    manifests/

  crates/
    agentos-cli/
    workspaced/
    hostd/
    storage/
    gui-backend/

  configs/
    systemd/
    policies/
    toolchains/

  tests/
    integration/
    vm/
    isolation/
    gui/

  examples/
    project-config.yaml
    system-change.yaml
```

Do not scaffold components merely because they appear in this conceptual structure. Create them when implementation requires them.

---

## 11. Proposed Configuration Contracts

These examples are conceptual and are not yet implemented.

### 11.1 Project Definition

```yaml
apiVersion: agentos.dev/v1alpha1
kind: Project

metadata:
  name: desktop-app

spec:
  execution:
    mode: native-restricted
    harness: pi

  resources:
    cpuQuotaPercent: 300
    memoryHigh: 6Gi
    memoryMax: 8Gi

  storage:
    persistent: true
    snapshots: manual-and-boundary

  toolchains:
    node: "24"

  graphics:
    enabled: true
    backend: auto
    resolution: 1920x1080
    softwareRenderingAllowed: true

  network:
    policy: standard-development
```

The harness field is optional and must not couple the OS to one agent implementation.

### 11.2 System Change

```yaml
apiVersion: agentos.dev/v1alpha1
kind: SystemChange

metadata:
  reason: "Make ripgrep available to all projects"

spec:
  operations:
    - type: package.install
      source: debian-stable
      name: ripgrep

  verification:
    - type: executable.version
      name: rg

  authorization:
    policy: evaluate
```

Avoid accepting unrestricted shell commands in a privileged verification executor.

Use typed checks or unprivileged execution whenever possible.

---

## 12. Implementation Roadmap

### Phase 0 — Research and Threat Model

- [x] Document protected assets, trust boundaries, and attacker capabilities.
- [x] Determine the exact native isolation design.
- [x] Verify Debian kernel and systemd capabilities.
- [x] Establish a reproducible VM development environment.
- [x] Implement test VM snapshot/reset tooling.
- [x] Define project filesystem layout and UID ownership.
- [x] Benchmark minimal Debian as a reference.

**Exit criterion:** documented threat model, baseline VM, and reproducible isolation test procedure.

### Phase 1 — Native Project Environments

- [x] Create two independent project identities.
- [x] Provision private project homes and workspaces.
- [x] Execute arbitrary native commands as each project identity.
- [x] Launch at least one supported coding harness.
- [x] Install a development tool within a project without root.
- [x] Enforce CPU, memory, and process limits.
- [x] Implement basic project CLI lifecycle operations.
- [x] Test filesystem, credential, IPC, and host restrictions.
- [x] Test persistence after SSH disconnect.
- [x] Test project cleanup and deletion.

**Exit criterion:** two project agents can operate independently, and neither can read the other's private workspace or alter host packages through normal access paths.

### Phase 2 — System Agent and Global Packages

- [x] Define typed `hostd` operation contracts.
- [x] Implement authenticated caller identity checks.
- [x] Separate project-agent and system-agent privileges.
- [x] Execute an approved APT installation.
- [x] Add change planning and impact reporting.
- [x] Add authorization and audit logging.
- [x] Implement global versioned toolchains.
- [x] Validate project read-only access to global tools.
- [x] Prove project agents cannot call privileged operations.
- [x] Test interrupted package transactions.

**Exit criterion:** the system agent can request and perform an approved global `ripgrep` installation, all projects can use the result, and project agents cannot impersonate the system agent.

### Phase 3 — Btrfs Workspace Lifecycle

- [ ] Implement project subvolume creation.
- [ ] Implement project snapshots.
- [ ] Implement snapshot listing and retention.
- [ ] Implement safe restoration.
- [ ] Validate nested subvolume handling.
- [ ] Add disk-pressure safeguards.
- [ ] Test recovery after destructive edits.
- [ ] Implement an off-host backup prototype.
- [ ] Restore from backup on a fresh VM.

**Exit criterion:** a project can be restored from a local snapshot and independently recovered from external backup.

### Phase 4 — On-Demand Graphical Testing

- [ ] Evaluate waymux on Debian.
- [ ] Evaluate headless Sway or Weston as fallback.
- [ ] Start a GUI session under a project identity.
- [ ] Launch a real GTK, Qt, Tauri, or Electron application.
- [ ] Support keyboard and mouse automation.
- [ ] Capture screenshots.
- [ ] Record video.
- [ ] Save capture metadata.
- [ ] Test graphical session isolation.
- [ ] Test authenticated remote viewing.
- [ ] Test session cleanup.
- [ ] Benchmark software rendering.
- [ ] Document optional GPU requirements.

**Exit criterion:** a project agent can test a real graphical application, capture screenshots and video, and stop the session without affecting another project.

### Phase 5 — Distribution Packaging

- [ ] Package Agent OS services and configuration as `.deb` packages.
- [ ] Build a VM image.
- [ ] Automate boot and installation tests.
- [ ] Create a bootable installer ISO.
- [ ] Implement secure administrator enrollment.
- [ ] Test clean installation.
- [ ] Test normal upgrades.
- [ ] Test system recovery.
- [ ] Test preservation of persistent project data.
- [ ] Document installation and maintenance.
- [ ] Run extended unattended tests with multiple project agents.

**Exit criterion:** Agent OS can be installed, administered remotely, and used for its core workflows without manual post-install workarounds.

### Future Work

- [ ] Container-on-demand execution.
- [ ] VM-on-demand execution.
- [ ] GPU-accelerated graphical sessions.
- [ ] Full GNOME/KDE integration testing.
- [ ] Per-project network egress policies.
- [ ] Full bootable system rollback.
- [ ] Web management UI.
- [ ] Remote management API.
- [ ] Multi-host administration.

Agent workflow scheduling is intentionally outside the OS core.

---

## 13. Definition of Done — First Usable Release

A clean installation must demonstrate:

1. **Headless operation:** System boots without a desktop and supports secure SSH administration.
2. **Native execution:** Two independently managed projects can launch coding agents.
3. **Project isolation:** Project A cannot access Project B's private files, IPC resources, or credentials under the tested threat model.
4. **Project freedom:** A project agent installs its own development tools and builds software without root.
5. **Agent-maintained host:** A system agent requests an approved global package installation through `hostd`.
6. **Global visibility:** Newly installed shared packages become available to authorized projects.
7. **Toolchain independence:** Projects can use different language versions without modifying each other's environments.
8. **Resource protection:** Runaway project workloads cannot exhaust the host management reserve under the tested scenarios.
9. **Snapshot recovery:** A project can recover from destructive modifications.
10. **Backup recovery:** Project data can be restored on a new VM.
11. **Graphical testing:** An agent can create an off-screen desktop, launch an application, interact with it, capture screenshots and video, and close the session.
12. **Persistence:** Project data survives reboot, with process/session recovery following documented lifecycle rules.
13. **Repeatability:** A newly installed VM passes the same automated acceptance tests.

---

## 14. Open Architecture Questions

These decisions must be resolved through prototyping, investigation, or explicit architectural review.

### Host

- Final Debian image construction process.
- Installer implementation.
- System configuration model.
- Bootloader and recovery strategy.
- Debian versus Arch if future requirements change.

### Native Execution

- Persistent project UID allocation and recycling.
- Exact systemd service and scope model.
- Required namespace boundaries.
- Whether bubblewrap should be used for restricted native execution.
- IPC and D-Bus isolation.
- Network policies for autonomous agents.

### Packages and Credentials

- Project-scoped alternatives for installers expecting APT.
- Global toolchain verification and atomic publication.
- Credential brokering and expiration.
- Per-project Git and registry authentication.
- System-agent approval interface.
- Rules governing autonomous global modifications.

### Filesystem

- Btrfs subvolume hierarchy.
- Compression configuration.
- Quota strategy.
- Cache exclusions.
- Snapshot retention.
- Backup mechanism.
- Host rollback implementation.

### Graphics

- waymux stability and packaging.
- Sway/Weston compatibility.
- GUI accessibility automation.
- Video codec availability.
- GPU permissions and isolation.
- Recording retention and sensitive-data protection.

### Product

- Final product name.
- CLI namespace.
- Service and package naming.
- Scope of future management UI.

---

## 15. Decision Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-11-08 | Agent OS is a temporary name | Avoid premature branding |
| 2026-11-08 | Remote coding workstation | Prioritize agentic development rather than generic servers |
| 2026-11-08 | Native-first execution | Preserve conventional Linux compatibility |
| 2026-11-08 | Separate system and project agents | Enable host maintenance without giving projects root privileges |
| 2026-11-08 | Debian Stable preferred | Conservative host updates and independent toolchains |
| 2026-11-08 | Btrfs preferred | Efficient snapshots and workspace lifecycle |
| 2026-11-08 | On-demand graphical sessions | Support GUI testing without a permanent desktop |
| 2026-11-08 | Evaluate existing GUI runtimes | Avoid reimplementing compositors and capture systems |
| 2026-11-08 | `native-restricted` uses transient systemd system services in per-project slices, without bubblewrap | User managers lack filesystem restrictions, and systemd already builds the namespaces. See `doc/ISOLATION.md`. |
| 2026-11-08 | Project UIDs come from 20000 to 29999 and are never reused | Stays clear of `adduser` and subordinate UID ranges. Snapshots can outlive a project. |
| 2026-11-08 | Root owns each project directory, and a per-project `tmp` directory backs `/tmp` | Blocks symlink swaps against root tooling. Commands in one project share `/tmp`. |
| 2026-11-08 | Development tests run QEMU from a pinned Docker toolbox | Pins the VM tooling without host packages. Agent OS itself still needs no container. |
| 2026-11-08 | Cross-project abstract sockets and loopback remain accepted gaps | Per-project network namespaces are unresolved. See `doc/THREAT_MODEL.md`. |
| 2026-11-08 | `agentos` is a root-only shell CLI with no daemon | Section 4.1 defers a daemon until scripts and systemd units are not enough. systemd already supervises the commands. |
| 2026-11-08 | Systemd units are named by project UID | Project names can contain hyphens, which mean hierarchy in slice names. |
| 2026-11-08 | `agentos-project.slice` caps all projects at 85% of RAM and 16384 tasks | Keeps capacity for SSH and host services under project load. |
| 2026-11-08 | Each project gets a network namespace with `veth`, NAT, and an `nftables` policy | Supersedes the accepted loopback and abstract socket gaps. Egress policy remains future work. See `doc/ISOLATION.md`. |
| 2026-11-08 | `hostd` is written in Rust and socket-activated per connection | A root service that parses requests needs typed input handling. systemd supplies supervision, and no process exists while idle. See `doc/HOSTD.md`. |
| 2026-11-08 | Rust binaries build with Debian's compiler in a container pinned to the APT snapshot | Matches the target's glibc and adds no new toolchain source. |
| 2026-11-08 | The system agent is the `agentos-system` account, outside the `aos-` namespace | No project name can collide with it. |
| 2026-11-08 | Nothing is automatic by default, and approval binds to one exact transaction | The administrator decides what runs unattended. Later package changes cannot widen an approval. |
| 2026-11-08 | Global toolchains come only from a pinned catalog and publish with one rename | Removes arbitrary global binaries from the API. Projects never see a partial version. |
| 2026-11-08 | Only `--detach` commands are guaranteed to survive a lost connection, and nothing resumes after reboot | Transient units are not persistent. Data survives. See `doc/CLI.md`. |

---

## 16. Upstream Technical References

These are starting points for implementation research, not claims that all proposed Agent OS capabilities already exist.

- [Debian Releases](https://www.debian.org/releases/)
- [Debian 13 Trixie](https://www.debian.org/releases/trixie/)
- [Debian Live Manual](https://live-team.pages.debian.net/live-manual/html/live-manual.en.html)
- [Debian debootstrap](https://wiki.debian.org/Debootstrap)
- [systemd Execution and Sandboxing](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html)
- [systemd Resource Control](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html)
- [Bubblewrap](https://wiki.debian.org/Bubblewrap)
- [Btrfs Documentation](https://btrfs.readthedocs.io/en/latest/Subvolumes.html)
- [waymux](https://waymux.dev/)
- [waymux Source](https://github.com/tek-cat/waymux)
- [waymux Architecture](https://waymux.dev/architecture.html)
- [Arch Linux System Maintenance](https://wiki.archlinux.org/title/System_maintenance)

---

## Implementation Reminder

Build the smallest working native, isolated project execution prototype first.

Do not begin by implementing a general agent orchestrator, custom package manager, or custom graphical compositor.

The defining capability of Agent OS is:

**An agent-maintainable Linux workstation with controlled host privileges, native project-isolated execution, and on-demand graphical testing.**
