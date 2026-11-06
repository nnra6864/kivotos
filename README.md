# kivotos

kivotos (Κιβωτός) - the ark keeping things safe through the flood

> [!WARNING]
> This was made with Claude Opus 5.5 mostly for personal use.

Restic backups of service directories. Each service's backup rules live next to it in a `kivotos.toml`,
so a service directory carries its own backup rules wherever you move it.
Right now it backs up `~/Containers`, which sits on the SSD (ext4) and so gets no ZFS snapshots.
Everything on `/tank` is covered by sanoid instead (`/etc/sanoid/sanoid.conf`).

One Python file, standard library only. It needs restic ≥ 0.17 and Python ≥ 3.11.

## Install / update

```sh
sudo sh ~/Packages/kivotos/install.sh
```

The first run installs `/usr/local/bin/kivotos` and writes `/etc/kivotos/config.toml`, with `user` set to whoever ran sudo. Then it stops.
Check the repository and the sources (`sudoedit /etc/kivotos/config.toml`), then run it again.
The second run creates the password and the repo, and writes the systemd service and timer from the config.

You can run it again at any time, and you should **after changing the program in this folder**. It never overwrites the config, the password or a repo it can open.

| What | Where | Owner |
|---|---|---|
| Program | `/usr/local/bin/kivotos` | root |
| Host settings (repo, schedule, retention, sources) | `/etc/kivotos/config.toml` | root |
| Repo password | `/etc/kivotos/password` (**keep a copy in your password manager**) | root, 600 |
| Repo | `repository` in the config, e.g. `/tank/backups/kivotos` (a ZFS dataset there can also be snapshotted by sanoid) | root |
| Per-service rules | `~/Containers/<svc>/kivotos.toml` | you |

## Usage

```sh
kivotos plan                         # what a run would do, per service (no sudo needed)
sudo systemctl start kivotos         # back up now, the same as the timer (logs: journalctl -u kivotos)
sudo kivotos run NetBird Postgres    # back up only these services (no retention or check)
sudo kivotos run --dry-run           # what restic would back up; no hooks, dumps or stopping
systemctl list-timers kivotos        # next and last run
sudo kivotos restic <anything>       # any restic command against the repo, for example:
sudo kivotos restic snapshots --tag NetBird
sudo kivotos restic ls latest --path ~/Containers/NetBird
sudo kivotos restic stats --mode raw-data
```

Change the schedule in `/etc/kivotos/config.toml` (`sudoedit` it), then run `sudo kivotos units` to rewrite the units.

## What a run does

Every **directory directly inside a source** (`~/Containers/*`) is a service, and each one gets its **own snapshot**.
Snapshots are tagged with the source and the service name, for example `containers,NetBird`.
Loose files at the top (`AGENTS.md`, `TODO.md`, ...) go in one extra snapshot tagged `_files`.
Symlinked directories are ignored.

For each service, in this order:

1. **Dumps** run while everything is still up. Each one is streamed straight into the repo, with no temp files, as `<svc>/<file>`, tagged `dump`.
2. **`before` hook**, then **stop** the listed containers.
3. **Back up the directory**, minus its excludes.
4. **Start** the stopped containers again, then the **`after` hook**. These always run, even if the backup failed.

Then comes **retention** (per backed-up path: 7 daily, 4 weekly, 6 monthly by default), then `restic check`.

kivotos doesn't stop at the first problem: it carries on and backs up everything else.
Afterwards it lists every problem and exits with 1, so `kivotos.service` fails.
Examples of problems: a failed hook or dump, a broken `kivotos.toml`, or an unreadable file.

To be alerted, hang an `OnFailure=` on the service with `sudo systemctl edit kivotos.service`.
That drop-in survives `kivotos units`, which only rewrites the unit files themselves.
[sema](../../../sema) does this for every system service and sends the alert to Matrix, so with its `onfailure` module on, there's nothing to set up here.
A container that isn't running is not an error. Its dumps and `if_running` hooks are just skipped.

## Per-service rules: `kivotos.toml`

**No file means the whole directory is backed up as is.** So a new service needs nothing, as long as its data is in bind mounts under its directory.
Add a `kivotos.toml` only for special cases. Every key is optional:

```toml
# "./name" or "a/b" is relative to this dir, a bare "name" matches at any depth.
# No '!' negation, no '..' and no leading '/'. Patterns can't reach outside the service dir.
exclude = ["./cache", "data/dind", "node_modules"]

skip = false                  # true: don't back up this service at all

stop = ["foo", "foo-worker"]  # stopped for this service's backup (only if running), started again after

[hooks]                       # shell commands, run as the configured `user` in this service's dir
if_running = "foo"            # only run the hooks while this container is up
before = "podman exec foo some-flush-command"
after  = "podman exec foo some-resume-command"

[[dump]]                      # as many as you like
name      = "foo-db"          # letters, digits, . _ -
container = "foo-db"          # run with `podman exec` in this container; leave it out to run on the host as `user`
command   = "pg_dumpall -U postgres"   # stdout is what gets stored
file      = "foo.sql"         # stored as <svc>/foo.sql (default: <name>.dump)
```

### Security

kivotos runs as **root**, for two reasons. It has to read files owned by container subuids, and the repo must be out of reach of your user, so ransomware running as your user can't touch it.
`kivotos.toml` files belong to your user, so root treats them strictly as **data**:

- Hooks, dump commands and every `podman` call run as the source's `user`, through `runuser` with a clean environment. **Nothing from a `kivotos.toml` is ever executed as root.** Root only stores the output.
- A `kivotos.toml` is only honoured if it's owned by that `user` or by root. Anything else (another user's file, a file a container wrote with its subuid) is ignored and reported, and the service is backed up with no rules. So nobody can get commands run as someone else.
- Excludes are anchored inside the service directory. `..` and `!` are rejected.
- Symlinked service dirs and a symlinked `kivotos.toml` are refused. Root never follows them out of the tree.
- The worst a tampered `kivotos.toml` can do is skip or exclude its own service's data. A `*` exclude is reported as a problem. `kivotos plan` shows everything that's set.

Keep hook scripts next to `compose.yaml`, **never inside a directory that's mounted into a container**.
Otherwise a compromised container could rewrite what runs as your user.

## Databases in services

Copying a database's files while it's writing to them can give a backup that won't open:

| Kind | Examples here | What to do |
|---|---|---|
| Postgres / MySQL / MariaDB | `postgres-db` | Add a `[[dump]]`, and exclude the raw data dir |
| SQLite | Grafana, NetBird, n8n | Fine for small apps that rarely write. For important ones, use the SQLite `[[dump]]` recipe below if the image has sqlite3, or use `stop` |
| RocksDB / LevelDB / embedded KV | tuwunel (on `/tank`) | `stop` the container, or keep the data on `/tank`: ZFS snapshots are atomic, like a power cut, which databases are built to survive |
| Redis / Valkey | `searxng-valkey` (cache) | Usually not worth it. Otherwise use a `before` hook with `redis-cli SAVE` |

Recipes:

```toml
[[dump]]   # MariaDB / MySQL
name      = "mariadb"
container = "foo-db"
command   = 'mariadb-dump --all-databases -uroot -p"$MARIADB_ROOT_PASSWORD"'
file      = "mariadb.sql"

[[dump]]   # SQLite, if the image has sqlite3
name      = "app-db"
container = "foo"
command   = "sqlite3 /data/app.db '.backup /tmp/kivotos.db' && cat /tmp/kivotos.db && rm /tmp/kivotos.db"
file      = "app.db"
```

Rule of thumb: a busy, important database goes on `/tank/services/<svc>`. A small app database can stay in `~/Containers`. A database server gets a `[[dump]]`.

## Restoring

Stop the service first: `cd ~/Containers/<svc> && podman compose down`.

```sh
# One service, in place. Files come back with their original subuid owners.
sudo kivotos restic restore latest --path ~/Containers/NetBird --target /

# Somewhere else first, to look around
sudo kivotos restic restore latest --path ~/Containers/NetBird --target /tmp/restore

# A single file or folder from an older snapshot
sudo kivotos restic snapshots --tag NetBird
sudo kivotos restic restore <id> --target /tmp/restore --include ~/Containers/NetBird/config.yaml

# Browse everything as a filesystem (Ctrl-C to unmount)
sudo mkdir -p /mnt/kivotos && sudo kivotos restic mount /mnt/kivotos
```

Postgres from the dump (`<db-user>` is your `POSTGRES_USER`). Use it on an empty or fresh cluster, because roles and databases that already exist will error:

```sh
sudo kivotos restic dump latest Postgres/postgres-all.sql --path /Postgres/postgres-all.sql > ~/postgres-all.sql
podman exec -i postgres-db psql -U <db-user> -d postgres < ~/postgres-all.sql
```

## Adding a source

To back up another tree of services, add a `[[source]]` block to `/etc/kivotos/config.toml`, then run `sudo kivotos units`:

```toml
[[source]]
name = "projects"
path = "~/Projects"           # ~ is the home of this source's user
exclude = ["node_modules", "target", ".venv"]   # applied inside every service of this source
```

### Several users

Each source can have its own `user`, which defaults to the top-level one.
Rootless podman is per user, so a source's hooks and dumps have to run as the user who owns its containers:

```toml
[[source]]
name = "trowe"
path = "~/Containers"         # ~ is this source's user, so /home/trowe/Containers. "~nn/x" names a user explicitly.
user = "trowe"
```

All sources share one repo. Only root can read it, so users can't see each other's backups, and deduplication works across everyone.
The flip side is that only root can restore. Snapshots carry the source name as a tag (`--tag trowe`).

# ☦

```
   Ὤ
 Ὁ   Ν
Ι̅Ϲ̅ │ Χ̅Ϲ̅
───┼───
ΝΙ │ ΚΑ
   ☦
```

Εἰς δόξαν τοῦ Θεοῦ<br>
*To the glory of God*

Τῇ Ὑπεραγίᾳ Θεοτόκῳ δόξα<br>
*Glory to the Most Holy Theotokos*

Δόξα τῷ Θεῷ πάντων ἕνεκεν<br>
*Glory to God for all things*

ΑΜΗΝ

☦
