# Orchestrate projects with T3 Code

This guide sets up one [T3 Code](https://t3.codes) server on an Agent OS host that hands out work to other projects. You talk to it from the T3 Code app on your phone or PC. Each project runs its own T3 Code server as its own account, in its own sandbox, and the orchestrator links to them.

Agent OS does not depend on T3 Code. These steps use generic pieces: [project services](HOSTD.md#project-services), [project links](ISOLATION.md#project-links), and a toolchain from the catalog. The commands were tested with T3 Code 0.1.8. Steps marked **untested** were not run.

## Choose a layout

| | System agent hub | Project hub |
|---|---|---|
| Where the orchestrator runs | As `agentos-system` on the host | In a project of its own, in the sandbox |
| Who creates projects | The orchestrator, through `hostd`, up to your limit | You, by hand |
| Firewall change | None. The host reaches every project | One `agentos project link` for each project |
| If the orchestrator is compromised | It can create projects up to your limit and drive each one it links ([gap 24](THREAT_MODEL.md#accepted-gaps)) | It can drive each project you linked ([gap 23](THREAT_MODEL.md#accepted-gaps)) |
| Tested by | `tests/hostd/guest/services.sh` | `tests/integration/guest/t3code.sh` |

Pick the system agent hub if you want the orchestrator to make projects on its own. Pick the project hub if you want it sandboxed and are happy to create projects yourself.

## Before you start

- An installed host that you reach over SSH as `admin`. See [Administration](ADMINISTRATION.md).
- The T3 Code app on your phone or PC.
- For access from a phone, a Tailscale account. See [Reach the orchestrator from your devices](#reach-the-orchestrator-from-your-devices).

Every command below runs on the host as `admin`, unless the step says otherwise.

T3 Code needs two settings that this guide applies for you:

- **Linked environments** are a Labs feature in 0.1.8. Each server needs `"linkedEnvironmentsEnabled": true` in `~/.t3/userdata/settings.json`.
- **A link over plain HTTP must go to loopback.** T3 Code refuses `http://` to any other address, because the link carries credentials. The orchestrator therefore reaches each project through a `socat` relay on its own loopback. The traffic never leaves the host.

## Set up the system agent hub

### 1. Install T3 Code and socat

T3 Code is a pinned toolchain in the catalog, so the projects and the orchestrator share one copy. Each command plans a change and exits with status 3 while it waits for you. Approve and apply it with the ID it printed:

```bash
sudo agentos system toolchain install t3 0.1.8 --reason "T3 Code orchestration"
sudo agentos system change approve ID
sudo agentos system change apply ID

sudo agentos system package install socat --reason "loopback relays for T3 Code links"
sudo agentos system change approve ID
sudo agentos system change apply ID
```

The binary is now `/opt/agent-os/toolchains/t3/0.1.8/t3`.

### 2. Define the T3 Code service

A service is three scripts that run as the new project, inside its sandbox. Requests can only name the service, so these scripts are the whole of what the orchestrator can start:

```bash
sudo mkdir -p /etc/agent-os/services/t3code

sudo tee /etc/agent-os/services/t3code/setup >/dev/null <<'SH'
#!/bin/sh
set -e
mkdir -p "$HOME/.t3/userdata"
echo '{"linkedEnvironmentsEnabled":true}' > "$HOME/.t3/userdata/settings.json"
SH

sudo tee /etc/agent-os/services/t3code/start >/dev/null <<'SH'
#!/bin/sh
exec /opt/agent-os/toolchains/t3/0.1.8/t3 serve --host 0.0.0.0 --port 3773 --no-browser .
SH

sudo tee /etc/agent-os/services/t3code/credential >/dev/null <<'SH'
#!/bin/sh
exec /opt/agent-os/toolchains/t3/0.1.8/t3 auth pairing create --ttl 5m --json
SH

sudo chmod 0755 /etc/agent-os/services/t3code/*
```

`setup` overwrites the project's T3 Code settings on every start. Merge into the file instead if the project's agents change other settings.

### 3. Set how many projects may appear without you

Edit `/etc/agent-os/hostd-policy.json` and set these two fields:

```json
"automatic_project_services": ["t3code"],
"automatic_project_limit": 10
```

The limit counts every project on the host, including those you made by hand. Once the host holds that many, each new create waits for your approval with `agentos system change approve`. Leave the service off the list to approve every create yourself.

### 4. Start the orchestrator

Give the system agent its T3 Code settings, then start its server on the host's loopback:

```bash
sudo -u agentos-system mkdir -p /var/lib/agent-os/system-agent/.t3/userdata
echo '{"linkedEnvironmentsEnabled":true}' | sudo -u agentos-system tee /var/lib/agent-os/system-agent/.t3/userdata/settings.json >/dev/null

sudo systemd-run --unit=aos-t3-hub --uid=agentos-system --gid=agentos-system \
    --setenv=HOME=/var/lib/agent-os/system-agent --working-directory=/var/lib/agent-os/system-agent \
    -- /opt/agent-os/toolchains/t3/0.1.8/t3 serve --host 127.0.0.1 --port 3780 --no-browser .
```

`sudo journalctl -u aos-t3-hub` shows its pairing details. `sudo systemctl stop aos-t3-hub` stops it. The unit does not survive a reboot. Start it again afterwards, or write a permanent unit if you want the orchestrator to run all the time. That is your decision, because Agent OS keeps nothing running while idle.

Set up the providers that the orchestrator's own agents use, such as Claude Code or Codex, as `agentos-system`. The projects need their own provider setup in turn. **Untested:** Agent OS tests only Pi against a stub model.

### 5. Connect your device

Follow [Reach the orchestrator from your devices](#reach-the-orchestrator-from-your-devices) with `http://127.0.0.1:3780` as the target.

### 6. Create and link a project

The orchestrator's agent runs these as `agentos-system`, from a terminal in T3 Code. You can run them yourself after `sudo -iu agentos-system`:

```bash
agentos system project create feature-x --service t3code --reason "work on feature X"
agentos system service credential feature-x
```

The first command creates `feature-x`, runs `setup`, and starts T3 Code in it. The second prints JSON with the project's `address` and, inside `credential`, T3 Code's own JSON with a pairing `credential`. The code expires after five minutes. Then relay a free loopback port to the project and link it:

```bash
setsid -f socat TCP-LISTEN:4001,bind=127.0.0.1,fork,reuseaddr TCP:ADDRESS:3773
t3 environment link http://127.0.0.1:4001 --pairing-code CODE --access full-access
t3 environment list
```

`t3` here is `/opt/agent-os/toolchains/t3/0.1.8/t3`. `setsid -f` keeps the relay alive after the command that started it ends. **Untested:** the suite starts its relay as a systemd unit, not with `setsid`. Give each project its own relay port.

`--access` sets what the orchestrator's agents may do in the project, from `read-only` to `full-access`. Grant the least that the work needs.

### 7. After a reboot

A reboot stops every project service, every relay, and the orchestrator. The projects, their data, and their links in T3 Code stay. For each project:

```bash
agentos system service start feature-x
setsid -f socat TCP-LISTEN:4001,bind=127.0.0.1,fork,reuseaddr TCP:ADDRESS:3773
```

Then start the orchestrator as in step 4. A project's address never changes.

### 8. Remove a project

The system agent cannot delete projects. When a project's work is done, unlink it in T3 Code, stop its relay, and delete it:

```bash
sudo agentos project delete feature-x --yes
```

## Set up a project hub

The orchestrator runs in a project called `hub`, sandboxed like every other project. You create each project it drives.

1. Create the projects:

	```bash
	sudo agentos project create hub
	sudo agentos project create my-app
	```

2. In each project, install T3 Code and turn on linked environments. These commands use the [toolchain](#1-install-t3-code-and-socat). The suite instead extracts the release archive from its [releases page](https://github.com/pingdotgg/t3code/releases) into `~/.local/lib`, after checking it against the release's `SHA256SUMS`. Both work without root:

	```bash
	sudo agentos project shell my-app
	# In the project shell:
	mkdir -p ~/.local/bin ~/.t3/userdata
	ln -s /opt/agent-os/toolchains/t3/0.1.8/t3 ~/.local/bin/t3
	echo '{"linkedEnvironmentsEnabled":true}' > ~/.t3/userdata/settings.json
	exit
	```

3. Start each server on its project's address:

	```bash
	sudo agentos project run --detach my-app -- t3 serve --host 0.0.0.0 --port 3773 --no-browser .
	sudo agentos project run --detach hub -- t3 serve --host 0.0.0.0 --port 3773 --no-browser .
	```

4. Let `hub` reach the project's server. This opens one port of `my-app` to `hub` and to no other project:

	```bash
	sudo agentos project link hub my-app 3773
	```

5. Start a relay in `hub` to the project's address, which `sudo agentos project inspect my-app` prints. Install `socat` first as in step 1 above:

	```bash
	sudo agentos project run --detach hub -- socat TCP-LISTEN:4001,bind=127.0.0.1,fork,reuseaddr TCP:ADDRESS:3773
	```

6. Pair them:

	```bash
	sudo agentos project run my-app -- t3 auth pairing create --ttl 5m
	sudo agentos project run hub -- t3 environment link http://127.0.0.1:4001 --pairing-code CODE --access full-access
	```

7. Connect your device with `http://HUB_ADDRESS:3773` as the target.

After a reboot, start every server and relay again with steps 3 and 5. The links stay. `sudo agentos project unlink hub my-app 3773` cuts `hub` off at once, including open connections.

## Reach the orchestrator from your devices

**Untested.** Agent OS does not ship or test Tailscale. `tailscaled` is a root service that runs all the time, so installing it is your decision for this host.

1. Install Tailscale on the host with [its instructions for Linux](https://tailscale.com/download/linux), and log in:

	```bash
	sudo tailscale up
	```

2. Publish the orchestrator to your tailnet only. Use `http://127.0.0.1:3780` for the system agent hub, or `http://HUB_ADDRESS:3773` for a project hub. The host already reaches both, so the firewall needs no change:

	```bash
	sudo tailscale serve --bg TARGET
	```

3. Create a pairing link and open it on your device. `HOST.TAILNET.ts.net` is the name that `tailscale serve status` shows:

	```bash
	# System agent hub:
	sudo -u agentos-system env HOME=/var/lib/agent-os/system-agent /opt/agent-os/toolchains/t3/0.1.8/t3 auth pairing create --ttl 5m --base-url https://HOST.TAILNET.ts.net
	# Project hub:
	sudo agentos project run hub -- t3 auth pairing create --ttl 5m --base-url https://HOST.TAILNET.ts.net
	```

Every device in your tailnet can reach the server. The pairing code is what keeps them out. `sudo tailscale serve reset` withdraws it.

Without Tailscale, a PC can use an SSH tunnel instead. `ssh -L 3780:127.0.0.1:3780 admin@HOST` makes the system agent hub `http://127.0.0.1:3780` on the PC. For a project hub, forward to `HUB_ADDRESS:3773` instead.

## Troubleshooting

| Message or symptom | Cause | Fix |
|---|---|---|
| `Linked environments is off on this machine` | A server lacks the Labs setting | Add `"linkedEnvironmentsEnabled": true` to its settings, then restart it |
| `... is plain http, which would send the link's credentials unencrypted` | The link URL is not loopback | Link to the relay at `http://127.0.0.1:PORT` |
| `t3 environment list` shows the project unreachable | The relay or the project's service stopped, or a project hub lost its link | Run `agentos system service start NAME`, restart the relay, or check `sudo agentos project links` |
| `project create` exits with status 3 | Policy holds the create for approval | Approve it, or raise `automatic_project_limit` |
| `unknown_service` | The service directory or its `start` script is missing | Check `/etc/agent-os/services/NAME/start` |
| `no_service` on `service credential` | The project was not created with a service | Only projects that `agentos system project create` made give out credentials |
| A pairing code is refused | It expired after five minutes, or was used once already | Ask for a new credential |
