# Storage design

Status: implemented by [`agentos`](CLI.md) for Phase 3. `tests/storage/run` passes on Debian 13.7 with kernel 6.12 and btrfs-progs 6.14. `/var/lib/agent-os` must be on Btrfs, and the [package](CLI.md#package) enables quotas on it.

## Subvolumes

| Path | Type | In snapshots |
|---|---|---|
| `projects/NAME` | Subvolume | Boundary of the snapshot |
| `workspace`, `home`, `state`, `artifacts` | Directories | Yes |
| `cache`, `tmp` | Nested subvolumes | No |

One snapshot of `projects/NAME` is a single point in time for everything it holds, so it does not need commands to stop. It has the state that a power loss would leave for a running command.

A Btrfs snapshot leaves out nested subvolumes, and that is how `cache` and `tmp` stay out. A subvolume that a project creates is left out in the same way. The snapshot prints a warning, and `agentos project snapshots` shows how many it omitted. After a restore, an omitted subvolume is an empty directory.

## Snapshots

Each snapshot is `snapshots/NAME/ID/`, with a read-only `tree` subvolume and a `meta` file. Renaming a staging directory into place publishes it, so a crash never leaves a partial snapshot in the list.

| Kind | Created by | Retention |
|---|---|---|
| `manual` | `agentos project snapshot` | Kept until `snapshot-delete` |
| `auto` | `--auto`, for task boundaries, and every restore | The newest `keep_automatic` per project |

## Restore

`restore` works in this order:

1. Hide the project from `run` and record the target snapshot.
2. Mask the slice and kill every process of the UID.
3. Take an automatic `pre-restore` snapshot, so that the restore can be undone.
4. Build a writable tree from the snapshot, with empty `cache` and `tmp`.
5. Swap the trees with two renames, and remove the old tree.

The set of paths that exist identifies the step that a failed restore reached, so running it again finishes the work. A rerun must name the same snapshot. Projects get an empty `cache` on purpose, because a compromised agent can poison one. The empty `cache` costs a rebuild.

## Disk pressure

| Safeguard | Trigger | Effect |
|---|---|---|
| Project limit | `--disk`, default 80% of the filesystem | Writes fail with `EDQUOT`. |
| Enrollment | Every minute | New subvolumes join their project's limit. |
| Snapshot refusal | Free space below `reserve_percent` (10) | `snapshot` fails. A restore's safety snapshot still runs. |
| Pruning | Free space below `reserve_percent` | Each project keeps one automatic snapshot. |
| Stopping | Free space below `critical_percent` (5) after pruning | The commands of the largest project stop. |

`/etc/agent-os/storage.conf` holds the three settings. The limit counts what a project references, so a snapshot does not use up its project's limit. Only the free-space checks cover snapshot growth.

## Backups

`agentos project backup` writes one stream to standard output: a text header, a `btrfs send` stream, and a SHA-256 trailer. In this prototype, another machine pulls the backup:

```bash
ssh admin@host 'sudo agentos project backup my-app --snapshot ID' | age -r RECIPIENT > my-app.backup.age
```

Pulling means that a compromised host cannot reach older backups. The stream is always full, and it needs encrypting outside `agentos`.

`agentos project recover` keeps the project's UID, limits, and toolchain selection. A selected toolchain must be installed again before commands can run. It spools the stream to disk and checks the trailer before anything parses the stream, so it needs free space for one extra copy. It refuses a name, account, or UID that is already in use.

## Measurements

From `tests/storage/benchmark` on 2026-11-08, in the [baseline](BASELINE.md) VM. The corpus has 15128 entries and 185 MiB. Each value is a median, and few snapshots exist during the runs.

| Configuration | Unpack (ms) | Copy and remove .py files (ms) | 256 MiB random, direct (ms) | Corpus on disk (MiB) |
|---|---|---|---|---|
| No quota, no compression | 426 | 939 | 688 | 211 |
| Quota, no compression | 423 | 937 | 644 | 210 |
| Quota, zstd:1 | 679 | 934 | 714 | 117 |
| No quota, zstd:1 | 670 | 938 | 734 | 117 |

| Operation on the corpus | Median (ms) |
|---|---|
| Snapshot | 44 |
| Restore, including the pre-restore snapshot | 784 |
| Backup to a file, 182 MiB | 844 |

Quotas have no measurable cost at this scale. The Btrfs documentation warns that their cost grows with the number of snapshots, and this benchmark does not cover that.

## Open decisions

| Question | Recommendation | Needed by |
|---|---|---|
| Compression | Mount with `compress=zstd:1`. It saved 44% and made unpacking about 60% slower. The mount belongs to the installer. | Phase 5 |
| Backup encryption, signing, schedule, and incremental sends | Compare restic with `btrfs send -p` once a real backup target exists. | Phase 5 |
| Automatic snapshots at task boundaries | Have a harness or the system agent call `snapshot --auto`. Nothing calls it yet. | First harness integration |
