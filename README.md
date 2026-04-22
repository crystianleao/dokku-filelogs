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

## Requirements

- Dokku with Vector log-shipping support (0.30+).
- systemd (for the GC timer). Without systemd, you can run
  `dokku filelogs:gc` manually or from cron.
- `gzip`, `gunzip`, `find`, `stat`, `du` — all standard on Linux hosts.

## Installation

```bash
sudo dokku plugin:install https://github.com/<you>/dokku-filelogs.git filelogs
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
| `filelogs:tail <app> [--date YYYY-MM-DD] [--lines N] [--follow]` | Tail the daily file. Transparently reads `.log` or `.log.gz`. |

## Configuration keys

| Key | Scope | Default | Notes |
|---|---|---|---|
| `retention-days` | per-app / global | `14` | Files older than this are deleted. |
| `max-app-bytes` | per-app / global | `1G` | Per-app disk cap. Accepts `N`, `NK`, `NM`, `NG`. |
| `max-total-bytes` | **global only** | `10G` | Plugin-wide cap, enforced last. |
| `format` | per-app / global | `json` | `json` or `text`. Maps to Vector `encoding[codec]`. |
| `compress` | per-app / global | `true` | gzip rotated (non-today) logs. |
| `auto-enable` | **global only** | `false` | If `true`, every new app gets `filelogs:enable` on `post-app-create`. |

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
- If `systemctl` is not available, the installer skips the timer and
  the plugin degrades to manual `filelogs:gc` runs.

## Tuning

| Env var | Default | Meaning |
|---|---|---|
| `FILELOGS_LOG_ROOT` | `/var/log/dokku/apps` | Where daily logs are written. |
| `FILELOGS_CONFIG_ROOT` | `/var/lib/dokku/services/filelogs` | Persistent config store. |
| `FILELOGS_GC_GRACE_MINUTES` | `120` | Minutes a non-today `.log` must be untouched before it's eligible for compression. |

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

## License

MIT.
