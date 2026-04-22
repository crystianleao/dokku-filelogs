# dokku-filelogs

A [Dokku](https://github.com/dokku/dokku) plugin that persists each app's
logs to daily-rotated text files on disk and enforces per-app + global
disk caps via a systemd-scheduled garbage collector.

Built on top of Dokku's native [Vector integration](https://dokku.com/docs/deployment/logs/)
— the plugin configures Vector's `file` sink for you and adds the
rotation/retention/cap layer Vector doesn't provide out of the box.

## Why

Dokku 0.30+ ships with Vector for log shipping and supports a `file`
sink, but:

- `/var/log/dokku/apps` has **no rotation** configured by default.
- There is **no disk cap** — a noisy app can fill your volume.
- There is **no convenient CLI** to tail yesterday's logs.

This plugin covers those gaps without replacing Vector, Docker logging,
or introducing a sidecar.

## Features

- Writes one file per app per UTC day: `/var/log/dokku/apps/<app>/YYYY-MM-DD.log`
- Rotates daily via Vector's strftime-templated path — no cron needed
  for rotation.
- Compresses yesterday's and older logs to `.log.gz` automatically.
- Enforces a **per-app** size cap (`max-app-bytes`) and a **global**
  size cap (`max-total-bytes`) — oldest rotated files are deleted first.
- Configurable retention in days.
- JSON or plain text encoding.
- Optional `auto-enable` for new apps.
- `dokku filelogs:tail <app>` convenience command, with `--date` and
  `--lines`.
- **S3 archival** to Amazon S3 or any S3-compatible service (MinIO,
  Cloudflare R2, Backblaze B2, DigitalOcean Spaces). Incremental
  sync of rotated `.log.gz` files; current open file is never touched.

## Requirements

- Dokku with Vector log-shipping support (0.30+).
- systemd (for the GC timer). Without systemd, you can run
  `dokku filelogs:gc` manually or from cron.
- `gzip`, `gunzip`, `find`, `stat`, `du` — all standard on Linux hosts.
- **Optional**: AWS CLI v2 (for S3 backup) — install from
  <https://aws.amazon.com/cli/>. Cron must be available for scheduled
  backups.

## Installation

```bash
sudo dokku plugin:install https://github.com/crystianleao/dokku-filelogs.git filelogs
```

The installer:

- Creates `/var/log/dokku/apps` and `/var/lib/dokku/services/filelogs`
  (owned by `dokku:dokku`).
- Templates and installs `dokku-filelogs.service` +
  `dokku-filelogs.timer` into `/etc/systemd/system/`.
- Enables and starts the timer (GC runs every 5 minutes).

## Quick start

```bash
# Enable for one app
dokku filelogs:enable my-app

# Set global disk cap and retention
dokku filelogs:set --global max-total-bytes 20G
dokku filelogs:set --global retention-days 30

# Override per-app
dokku filelogs:set my-app max-app-bytes 500M
dokku filelogs:set my-app format text

# Auto-enable for newly-created apps
dokku filelogs:set --global auto-enable true

# Switch a noisy app to hourly rotation (shrinks unbounded window from
# 24h to 1h so the disk watchdog has finer-grained files to reclaim)
dokku filelogs:set noisy-app rotation hourly

# See what's going on
dokku filelogs:report
dokku filelogs:report my-app

# Tail today's log
dokku filelogs:tail my-app --lines 100

# Tail a past day (works on .log.gz)
dokku filelogs:tail my-app --date 2026-04-15
```

## Commands

| Command | Description |
|---|---|
| `filelogs:enable <app>` | Point Vector's file sink at `/var/log/dokku/apps/<app>/%Y-%m-%d.log`. |
| `filelogs:disable <app>` | Clear the Vector sink. Log files are kept on disk. |
| `filelogs:set <app\|--global> <key> <value>` | Persist a config value. Validates. |
| `filelogs:report [<app>]` | Show global or per-app configuration + current disk usage. |
| `filelogs:gc` | Run GC immediately (bypass the 5-minute timer). |
| `filelogs:tail <app> [--date YYYY-MM-DD] [--at YYYY-MM-DDTHH] [--lines N] [--follow]` | Tail logs. `--date` concatenates all files of that day (daily + all hourly files). `--at` reads one specific hour. Transparently reads `.log` and `.log.gz`. |
| `filelogs:backup <app>\|--all [--bucket <b>] [--prefix <p>]` | Sync rotated logs (`.log.gz` only) to S3. Never uploads the current open file. |
| `filelogs:backup-auth <key> <secret> [region] [endpoint]` | Store S3 credentials (file mode 0600). `endpoint` enables S3-compatible backends. |
| `filelogs:backup-deauth` | Remove stored credentials. |
| `filelogs:backup-schedule "<cron>" --bucket <b> [--prefix <p>]` | Write `/etc/cron.d/dokku-filelogs-backup` to run `backup --all` on a cron schedule. |
| `filelogs:backup-unschedule` | Remove the cron file. |
| `filelogs:backup-report` | Show backup configuration + last run. |

## Configuration keys

| Key | Scope | Default | Notes |
|---|---|---|---|
| `retention-days` | per-app / global | `14` | Files older than this are deleted. |
| `max-app-bytes` | per-app / global | `1G` | Per-app disk cap. Accepts `N`, `NK`, `NM`, `NG`. |
| `max-total-bytes` | **global only** | `10G` | Plugin-wide cap, enforced last. |
| `format` | per-app / global | `json` | `json` or `text`. Maps to Vector `encoding[codec]`. |
| `compress` | per-app / global | `true` | gzip rotated (non-today) logs. |
| `auto-enable` | **global only** | `false` | If `true`, every new app gets `filelogs:enable` on `post-app-create`. |
| `min-free-disk-percent` | **global only** | `10` | If free disk on the log volume drops below this, GC aggressively deletes rotated files (oldest first, never today's). Set to `0` to disable the watchdog. |
| `rotation` | per-app / global | `daily` | `daily` → one file per UTC day (`YYYY-MM-DD.log`). `hourly` → one file per UTC hour (`YYYY-MM-DDTHH.log`). Use `hourly` for very chatty apps so the watchdog has finer-grained rotated files to reclaim. Changing this on an already-enabled app auto-refreshes the Vector sink. |
| `backup-exclude` | per-app | `false` | If `true`, `filelogs:backup --all` skips this app. |

Per-app values override global values, which override built-in defaults.

## Architecture

```
┌─────────┐   stdout   ┌─────────┐  file sink   ┌──────────────────────────────┐
│ app     │ ─────────> │ Vector  │ ──────────>  │ /var/log/dokku/apps/<app>/   │
└─────────┘            └─────────┘              │   YYYY-MM-DD.log             │
                                                └──────────────────────────────┘
                                                              ▲
                                                              │ every 5 min
                                                     ┌────────┴────────┐
                                                     │ gc.sh           │
                                                     │  - gzip old     │
                                                     │  - retention    │
                                                     │  - per-app cap  │
                                                     │  - global cap   │
                                                     └─────────────────┘
```

Rotation is done by Vector's strftime path template — no logrotate or
custom cron. The GC daemon only handles compression and
retention/caps; it never touches the currently-open `YYYY-MM-DD.log`
for the current day.

## Safety

- `post-delete` removes only paths under `$FILELOGS_LOG_ROOT` and
  `$FILELOGS_CONFIG_ROOT/apps/<app>`. The guard is explicit.
- GC never deletes today's open log file. A grace window
  (`FILELOGS_GC_GRACE_MINUTES`, default 120) prevents racing Vector's
  midnight rollover.
- A **disk-pressure watchdog** runs after every GC cycle. If free space
  on the log volume falls below `min-free-disk-percent` (default 10%),
  the watchdog deletes rotated files (oldest first, across all apps)
  until either the threshold is met or nothing else can be trimmed.
  `filelogs:report` surfaces free-disk state with an `ok` / `LOW`
  status line.
- If `systemctl` is not available, the installer skips the timer and
  the plugin degrades to manual `filelogs:gc` runs.

### Known limitation: today's open log

The watchdog only trims **rotated** files — it never touches the
currently-open log for the active rotation window, to avoid racing
Vector's file descriptor. **A single chatty app can therefore still
fill the disk within one rotation window.** Mitigations available to you:

1. **Switch that app to hourly rotation**:
   `dokku filelogs:set <app> rotation hourly`. The rotation window shrinks
   from 24h to 1h, so the watchdog can reclaim all but the current hour's
   file — 24× finer-grained recovery.
2. Put `/var/log/dokku/apps` on a dedicated volume sized with headroom.
3. Lower `retention-days` and `max-app-bytes` so less headroom is
   consumed by rotations.
4. Keep `min-free-disk-percent` high (e.g., 20%) so the watchdog
   reclaims aggressively before pressure turns into an outage.
5. Use application-level rate-limiting for noisy loggers.

## Tuning

| Env var | Default | Meaning |
|---|---|---|
| `FILELOGS_LOG_ROOT` | `/var/log/dokku/apps` | Where daily logs are written. |
| `FILELOGS_CONFIG_ROOT` | `/var/lib/dokku/services/filelogs` | Persistent config store. |
| `FILELOGS_GC_GRACE_MINUTES` | `120` | Minutes a non-today `.log` must be untouched before it's eligible for compression. |
| `FILELOGS_FAKE_FREE_PERCENT` | _(unset)_ | Test-only override for `df`-backed free-percent detection. Takes precedence over real `df`. |

Set these in `/etc/default/dokku-filelogs` if you need to relocate the
log root (e.g., to a dedicated volume) and reference it from the
systemd unit.

## Uninstall

```bash
sudo dokku plugin:uninstall filelogs
```

This disables and removes the systemd timer. **Log files under
`/var/log/dokku/apps` are left intact** — remove them manually if
desired.

## Development

```bash
# Install dev deps (bats + shellcheck)
make ci-dependencies

# Run lint + tests
make test

# Individually
make lint
make unit-tests
```

- `shellcheck` is run against every script listed in the `SCRIPTS`
  variable in the Makefile.
- `bats` covers 63 cases across subcommands, triggers, helpers, and the
  GC daemon. Tests stub out the `dokku` command on `PATH` and run
  against a per-test tmp directory — no Dokku install required.

### Project conventions

See [CLAUDE.md](./CLAUDE.md) for the full set of conventions (bash 3.2
portability, test structure, safety guarantees).

## S3 backup

Back up rotated log files to Amazon S3 or any S3-compatible service.
The current open `.log` is never uploaded — only rotated `.log.gz`
files, via `aws s3 sync` with size/etag-based deduplication.

### Setup

```bash
# 1. Install AWS CLI v2 on the Dokku host.

# 2. Store credentials once (file mode 0600, owner dokku).
dokku filelogs:backup-auth AKIA... SECRET... us-east-1

# For S3-compatible services (MinIO, R2, Spaces, B2), pass endpoint:
dokku filelogs:backup-auth KEY SECRET auto https://my-bucket.r2.cloudflarestorage.com

# 3. Schedule recurring backups (example: daily at 03:00 UTC).
dokku filelogs:backup-schedule "0 3 * * *" --bucket my-logs
# Or with a prefix:
dokku filelogs:backup-schedule "*/30 * * * *" --bucket my-logs --prefix archive

# 4. Or run ad-hoc.
dokku filelogs:backup my-app --bucket my-logs
dokku filelogs:backup --all --bucket my-logs

# 5. Inspect.
dokku filelogs:backup-report
```

### On-disk layout on S3

```
s3://<bucket>/<prefix>/<app>/2026-04-21.log.gz
s3://<bucket>/<prefix>/<app>/2026-04-22T00.log.gz    # if rotation=hourly
s3://<bucket>/<prefix>/<app>/2026-04-22T01.log.gz
...
```

### Per-app opt-out

```bash
dokku filelogs:set quiet-app backup-exclude true
```

### Relationship to GC

Backup is **best-effort**, independent of GC. The GC watchdog still
deletes files by retention and disk-pressure. If you need guaranteed
archival, schedule backup at least as frequently as retention — e.g.,
`retention-days=14` with a daily backup leaves a 13-day safety window.

### Compatibility

Anything that speaks the S3 API and works with `aws --endpoint-url`:

- Amazon S3 (no endpoint flag)
- Cloudflare R2
- MinIO / MinIO Server
- Backblaze B2 (S3-compatible endpoint)
- DigitalOcean Spaces
- Wasabi
- Ceph RADOS Gateway

## License

MIT. See [LICENSE.txt](./LICENSE.txt).
