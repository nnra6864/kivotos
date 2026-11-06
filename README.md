# restic-containers

Daily [restic](https://restic.net) backup of `~/Containers`, which sits on the SSD (ext4) and so gets no ZFS snapshots.
Everything on `/tank` is covered by sanoid snapshots instead (see `/etc/sanoid/sanoid.conf`).

## Install / update

```sh
sudo sh ~/Packages/restic-containers/install.sh
```

You can run it again at any time. It copies the script, the excludes and the units into place, and enables the timer.
It never overwrites the password or a repo that the password can open.
**Run it again after every change in this folder.** The live copies are the ones in `/usr/local/bin` and `/etc`, not the files here.

| File | Installed to |
|---|---|
| `restic-containers` | `/usr/local/bin/restic-containers` |
| `containers.env` | `/etc/restic/containers.env` (repo path, password file, cache dir) |
| `containers.exclude` | `/etc/restic/containers.exclude` |
| `restic-containers.{service,timer}` | `/etc/systemd/system/` |
| generated on first install | `/etc/restic/containers.password`. **Keep a copy in your password manager.** Without it the backups can't be opened. |

The repo lives at `/tank/backups/containers/restic`, and sanoid snapshots it daily as part of `tank/backups`.

## What a run does

The timer fires daily at about 04:30 (`Persistent=true`, so a run that was missed while the machine was off happens after the next boot).

1. **Minecraft (`nn-survival`)**: `rcon-cli save-off` and `save-all flush`, so the world on disk is consistent. Saving is turned back on right after the copy, even if the backup fails.
2. **`~/Containers`**: backed up, minus `containers.exclude`. Tag `containers`.
3. **Postgres (`postgres-db`)**: `pg_dumpall` is streamed into the repo as `postgres-all.sql`. Tag `postgres`.
   The live data dir is excluded, because a copy taken while the database is running may not restore.
4. **Retention**: keeps 7 daily, 4 weekly and 6 monthly per tag, prunes the rest, then runs `restic check`.

Stopped containers are skipped without an error. If any step fails, the service fails and sema's global `OnFailure=` hook sends a Matrix alert.

## Everyday commands

`sudo restic-containers` with no arguments takes a backup. With arguments, it runs restic against the repo with the right password and paths:

```sh
sudo systemctl start restic-containers         # back up now, the same as the timer (logs: journalctl -u restic-containers)
systemctl list-timers restic-containers        # next and last run
sudo restic-containers snapshots               # list backups
sudo restic-containers ls latest --tag containers /home/nn/Containers/NetBird
sudo restic-containers diff <id1> <id2>        # what changed between two backups
sudo restic-containers stats --mode raw-data   # actual space used by the repo
```

## Restoring

Stop the container first: `cd ~/Containers/<svc> && podman compose down`.

```sh
# One service, restored in place (files come back with their original subuid owners)
sudo restic-containers restore latest --tag containers --target / --include /home/nn/Containers/NetBird

# Or restore somewhere else to look around first
sudo restic-containers restore latest --tag containers --target /tmp/restore --include /home/nn/Containers/NetBird

# Browse a backup as a filesystem (Ctrl-C to unmount)
sudo mkdir -p /mnt/restic && sudo restic-containers mount /mnt/restic
```

Postgres, from the dump (the DB user is `nn`). Use this on an empty or fresh cluster. On an existing one, roles and databases that are already there will error out:

```sh
sudo restic-containers dump latest postgres-all.sql --tag postgres > ~/postgres-all.sql
podman exec -i postgres-db psql -U nn -d postgres < ~/postgres-all.sql
```

## Adding new containers

**Nothing to do in most cases.** The whole `~/Containers` dir is backed up, so a new `~/Containers/foo/` with bind mounts under it is included automatically.

You only need to touch this setup when the new service:

- **Keeps data outside `~/Containers`.** If it's under `/tank/services/...`, sanoid covers it, and new child datasets inherit the `services` template (`recursive = yes`).
  Anything else (named podman volumes in `~/.local/share/containers`, `/srv/...`) is **not** backed up. Prefer bind mounts into `~/Containers/foo/` or `/tank/services/foo`.
- **Has big rebuildable junk** (caches, downloaded images, build dirs). Add the path to `containers.exclude` and re-run `install.sh`.
- **Has a database** (see below).

## Containers with their own database

Copying a database's files while it's writing to them can give a backup that won't open. How much that matters depends on the database:

| Kind | Examples here | What to do |
|---|---|---|
| Postgres / MySQL / MariaDB | `postgres-db` | Dump it (already done for `postgres-db`). Add a dump step for any new DB server. |
| SQLite | grafana, NetBird, n8n, minecraft's `banhammer-sqlite.db` | Fine for small apps that rarely write: SQLite usually recovers from a live copy. For anything important, add a `.backup` step. |
| RocksDB / LevelDB / embedded KV | tuwunel (on `/tank`, so covered by sanoid) | Stop the container briefly, or rely on ZFS snapshots, which are atomic. |
| Redis / Valkey | `searxng-valkey` (cache only) | Usually not worth it. Otherwise `redis-cli SAVE` before the backup. |

A **ZFS snapshot is atomic**, so it's as good as pulling the power cord: databases are built to recover from that.
That's why a database that's important and busy is best kept on `/tank/services/<svc>`.

To add a dump step, copy the Postgres block in `restic-containers` and change the command. Each one becomes its own snapshot with its own tag, and gets retention automatically:

```bash
# MariaDB / MySQL
if running foo-db; then
    restic backup --tag foo-db --stdin-filename foo.sql --stdin-from-command -- \
        runuser -u nn -- env XDG_RUNTIME_DIR=/run/user/1000 \
        podman exec foo-db sh -c 'mariadb-dump --all-databases -uroot -p"$MARIADB_ROOT_PASSWORD"'
fi

# SQLite (needs sqlite3 inside the container; if it isn't there, stop the container around the backup instead)
if running foo; then
    restic backup --tag foo-db --stdin-filename foo.db --stdin-from-command -- \
        runuser -u nn -- env XDG_RUNTIME_DIR=/run/user/1000 \
        podman exec foo sh -c 'sqlite3 /data/foo.db ".backup /tmp/b.db" && cat /tmp/b.db && rm /tmp/b.db'
fi
```

If you dump a database, also exclude its raw files in `containers.exclude`, so you don't store them twice. Then re-run `install.sh`.

## Off-site copy (later)

The repo is on the same single HDD as `/tank`, so it covers losing the SSD but not losing the HDD.
To add a second copy, create a repo elsewhere (USB disk, B2, Hetzner Storage Box, another box over NetBird).
Then copy snapshots into it, for example as a step at the end of `restic-containers`:

```sh
restic -r <new-repo> --password-file <new-password-file> init
restic -r <new-repo> --password-file <new-password-file> copy \
    --from-repo /tank/backups/containers/restic --from-password-file /etc/restic/containers.password
```

The repo is encrypted, so an untrusted host is fine.
