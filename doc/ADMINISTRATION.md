# How to install and maintain an Agent OS host

This guide is for the administrator, the human with root on a host. It lists the steps for each task and links to the reference pages for details.

## Install a host

Choose one way to install:

| You have | Use |
|---|---|
| A physical machine, or a VM that boots from a CD or USB stick | The [installer ISO](CLI.md#installer-iso) |
| A hypervisor that boots a qcow2 disk | The [VM image](CLI.md#vm-image) |
| A running Debian 13 with `/var/lib/agent-os` on Btrfs | The [package](CLI.md#package) |

To install from the ISO:

1. Put your SSH public key in a file named `agentos-admin.pub` on a second USB stick, or keep it ready to paste. The installer does not look for the key on its own medium.
2. Run `tests/vm/vm build` and then `packaging/build-iso` on a build machine, and write the ISO from `.build/installer/` to a USB stick.
3. Turn off Secure Boot, and boot the machine from the stick.
4. Press Enter on the console you use, and answer the installer's prompts. It asks for the key and the disk, and then for the disk's name again to confirm.
5. Copy the host key fingerprint from the installer's report.
6. When the installer asks, remove the stick and press Enter to restart.

The install erases the whole disk.

## Log in for the first time

1. Connect as `admin` with the enrolled key:

	```bash
	ssh admin@HOST
	```

2. Compare the fingerprint that SSH shows with the one from the installer's report. If they differ, disconnect and reinstall.
3. Run the first checks:

	```bash
	systemctl --failed
	sudo agentos system status
	```

`systemctl --failed` lists no unit on a healthy host. In the `status` reply, `dpkg_consistent` is true.

## Create a project and start an agent

1. Create the project:

	```bash
	sudo agentos project create my-app
	```

2. Install the harness inside the project. The project has network access and needs no root:

	```bash
	sudo agentos project shell my-app
	```

3. Start the harness with `--detach`, so that it keeps running after your SSH connection ends:

	```bash
	sudo agentos project run --detach my-app -- COMMAND
	```

4. Read its output with the ID that the command printed:

	```bash
	sudo agentos project logs my-app ID
	```

A reboot does not resume commands. Start them again after each reboot. [Command lifetime](CLI.md#command-lifetime) lists what each event does.

To limit a project, pass `--cpu`, `--memory-max`, `--tasks`, or `--disk` to `create`. Agent OS has no command that changes the limits of an existing project.

## Approve a system agent's change

A system agent runs under the `agentos-system` account. Start a harness there with `sudo -iu agentos-system`. Its host changes go through `hostd`, and most of them wait for you.

1. Read the plan:

	```bash
	sudo agentos system change show ID
	```

2. Check the `reason` and the `impact`. Reject the change if you do not expect it:

	```bash
	sudo agentos system change reject ID
	```

3. To accept the change, approve and apply it:

	```bash
	sudo agentos system change approve ID
	sudo agentos system change apply ID
	```

If `apply` reports `stale`, the packages changed after the plan. Request a new plan. `agentos system change history` prints the audit trail.

To let a package or toolchain install without approval, add it to `/etc/agent-os/hostd-policy.json`. [Policy](HOSTD.md#policy) lists the conditions.

## Upgrade the host

1. Plan the upgrade. The command exits with status 3 because the upgrade waits for approval:

	```bash
	sudo agentos system package upgrade --reason "monthly upgrade"
	```

2. Approve and apply the change with the ID that the plan printed.
3. Run `sudo agentos system status`. If `reboot_required` is true, stop your project commands, reboot the host, and start the commands again. `hostd` never reboots the host.

Running projects keep running through an upgrade. A package that apt holds back appears in `impact.kept_back`.

Agent OS has no published APT repository, so a Debian upgrade does not bring a new `agentos` version. To upgrade Agent OS itself, copy a newer `.deb` to the host and install it:

```bash
sudo apt-get install ./agentos_VERSION_amd64.deb
```

The upgrade keeps `hostd-policy.json` and `storage.conf`. New defaults in those files reach only fresh installs.

## Finish an interrupted operation

| What was interrupted | Command |
|---|---|
| A `hostd` change | `sudo agentos system recover` |
| A direct install or upgrade of the package | `sudo dpkg --configure -a` |
| `agentos project delete` | Run the same command again. |
| `agentos project restore` | Run the same command again, with the same snapshot. |
| `agentos project recover` | Run the same command again, with the same backup. |
| A fresh install from the installer | Boot the medium, and run the installer again. |
| A repair from the installer | Boot the medium, and type `repair` again. Pressing Enter at that prompt erases the whole disk. |

If `status` shows a `failed` change and `dpkg_consistent` is false, repair `dpkg` by hand.

## Undo damage in a project

1. Find a snapshot from before the damage:

	```bash
	sudo agentos project snapshots my-app
	```

2. Restore it. The restore stops all commands in the project and prints the ID of a new `pre-restore` snapshot, which undoes the restore:

	```bash
	sudo agentos project restore my-app --snapshot ID --yes
	```

Only `restore` takes a snapshot on its own. Run `agentos project snapshot NAME` before risky work, or add `--auto` for one that retention can remove. The `cache` and `tmp` directories are empty after a restore.

## Back up a project

Run the backup from another machine, so that a compromised host cannot reach older backups. Agent OS does not encrypt or schedule backups.

1. Take a snapshot, and note its ID:

	```bash
	ssh admin@HOST 'sudo agentos project snapshot my-app --label backup'
	```

2. Pull the backup, and encrypt it on the other machine:

	```bash
	set -o pipefail
	ssh admin@HOST 'sudo agentos project backup my-app --snapshot ID' | age -r RECIPIENT > my-app.backup.age.tmp \
		&& mv my-app.backup.age.tmp my-app.backup.age
	```

	Without `pipefail`, a dropped connection or a failed backup still leaves a file that looks complete. The rename happens only after the whole pipeline succeeds.

To restore on a new host, decrypt the backup and pipe it to `sudo agentos project recover`. The host needs free space for one extra copy of the backup. If the project selected a toolchain, install that toolchain again.

## Repair a broken host

A repair replaces the root and the boot loader, and keeps the data partition. Every project, snapshot, and audit record stays. Before you need a repair, keep copies of `/etc/agent-os/hostd-policy.json` and `/etc/agent-os/storage.conf` off the host, because the repair resets both.

1. Boot the install medium, give the administrator's key, and choose the disk.
2. Type `repair` at the prompt, and then the disk's name to confirm. Pressing Enter at the `repair` prompt erases the whole disk.
3. Log in as `admin`. The host has new host keys, so remove its old entry from your `known_hosts`, and compare the new fingerprint with the report.
4. Copy back your `hostd-policy.json` and `storage.conf`.
5. Install each toolchain again that a project selected:

	```bash
	sudo agentos system toolchain install NAME VERSION --reason "after repair"
	```

6. Approve and apply each toolchain change, then start your project commands.

The repaired host has the ISO's Agent OS version. If that version is older than the one you ran, [upgrade Agent OS](#upgrade-the-host) again.

## Respond to low disk space

Agent OS acts on its own when free space runs low. [Disk pressure](STORAGE.md#disk-pressure) lists the thresholds. Below 10% free, each project keeps one automatic snapshot. If free space is still below 5%, the commands of the largest project stop. The check repeats every minute, so a command you start in that project stops again until space is free.

To free space:

1. Run `sudo agentos project inspect NAME` for each project, and compare `disk_used_bytes`. It counts what the project references now, so it does not show what deleting a snapshot would free.
2. Remove snapshots you no longer need with `sudo agentos project snapshot-delete NAME ID --yes`.
3. If you need more, remove each project's last automatic snapshot with `sudo agentos project prune NAME --keep 0`. That snapshot may be the `pre-restore` one that undoes a restore.
4. Once free space is above 5%, start the stopped commands again.
