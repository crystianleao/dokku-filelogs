# CLAUDE.md — dokku-filelogs project rules

Rules for future Claude sessions working on this plugin.

## What this is

A Dokku plugin that persists per-app logs to daily-rotated files on disk and
enforces per-app + global disk caps via a systemd-scheduled GC daemon. It
layers on top of Dokku's built-in Vector integration (uses `dokku logs:set
<app> vector-sink file://...`); it does **not** replace Vector or Docker
logging.

## Repository layout

```
commands                CLI help dispatcher
config                  defaults (paths, retention, caps). Space-separated
                        strings, NOT bash arrays (see "bash 3.2 quirks").
functions               shared helpers. Safe to source multiple times.
install / uninstall     lifecycle — install drops systemd units into
                        /etc/systemd/system/.
post-app-create         auto-enable hook (reads global auto-enable flag).
post-app-rename         moves log/config dirs, re-issues vector-sink.
post-delete             removes app log + config dirs. Guarded to only
                        delete under $FILELOGS_LOG_ROOT.
subcommands/*           one file per `filelogs:<cmd>`. Each is executable.
gc/gc.sh                GC daemon. Compresses, applies retention, enforces
                        per-app and global caps. Never touches today's
                        currently-open .log file.
systemd/*.tmpl          templated unit files. `install` sed-replaces
                        __PLUGIN_ROOT__, __OWNER__, __GROUP__.
tests/                  bats suite + test_helper.bash.
Makefile                `make test` = lint + unit-tests.
```

## Development workflow

- `make test` — runs shellcheck + bats. Must pass before any commit.
- `make lint` — shellcheck only.
- `make unit-tests` — bats only.
- `make ci-dependencies` — installs bats + shellcheck (apt or brew).

Dev machine is macOS (bash 3.2, BSD find/stat/du). CI/prod is Linux
(bash 4+, GNU find/stat/du). Code must work on both.

## Hard rules

### Portability

- **bash 3.2 compatible**. macOS ships 3.2 and `#!/usr/bin/env bash` picks
  it up. Do not use `mapfile`, associative arrays, `${var,,}`, or any
  bash-4-only feature.
- **Do not put bash arrays in `config`**. Bash 3.2 has a known bug where an
  array declared inside a file that is sourced from within a function is
  dropped when the function returns. `config` is sourced from `setup()` in
  bats, so any array there ends up empty. Use space-separated strings and
  iterate with `for k in $STRING; do`. This is load-bearing — the bats
  suite caught it during build.
- **Do not use `find -printf`**. GNU-only, breaks on BSD find (macOS).
  Use `filelogs_oldest_file` / `filelogs_oldest_file_recursive` helpers,
  which use portable `stat` (GNU `-c` with BSD `-f` fallback).
- **Do not use `du -sb`**. BSD du has no `-b`. `filelogs_dir_bytes`
  already handles the fallback.
- **Do not use `zcat`**. Some macOS versions only accept `.Z` files.
  Use `gunzip -c`.
- **`touch -t YYYYMMDDHHMM.SS`** is the portable form. GNU `date -d "N days
  ago"` and BSD `date -v-Nd` diverge — `touch_days_ago` in `test_helper.bash`
  picks the right one.

### Bash style

- Every executable script starts with:
  ```bash
  #!/usr/bin/env bash
  set -eo pipefail
  [[ $DOKKU_TRACE ]] && set -x
  ```
- Do **not** use `set -u`. Dokku triggers pass optional args; empty vars
  are expected.
- Prefer `if/then/else` over `A && B || C`. shellcheck SC2015 fires on
  the latter.
- Source relative to the script:
  ```bash
  PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$PLUGIN_ROOT/config"
  source "$PLUGIN_ROOT/functions"
  ```
- All functions and variables related to this plugin are prefixed
  `filelogs_` / `FILELOGS_`.

### Safety

- **`post-delete` must never `rm -rf` outside `$FILELOGS_LOG_ROOT`**. The
  current guard (`case "$FILELOGS_LOG_ROOT/$APP"` whitelist) is intentional.
  If the trigger arg is empty, the script exits early.
- `gc.sh` must never delete a file named `$(filelogs_today).log`. Vector
  holds an open fd for it; deleting would break logging. All three GC
  loops (`gc_apply_retention`, `gc_enforce_cap`, `gc_global`) filter it.
- Compression of a non-today `.log` only happens after
  `FILELOGS_GC_GRACE_MINUTES` (default 120) since its last mtime, so
  Vector has had time to close the fd after midnight rollover. Tests set
  this to 0 so compression is exercised immediately.
- **Today's open log is never deleted, even under disk pressure.** The
  `gc_disk_pressure` watchdog only trims rotated files
  (`.log.gz` + old `.log`). The plugin does not truncate or copytruncate
  Vector's open fd — that would race the Vector process and risk sparse
  files. Instead, oversized current logs are mitigated by **rotation
  downgrade**: when `pressure-auto-downgrade=true` (global, default
  `false`), the GC switches offending apps from `daily` to `hourly`,
  re-issuing `dokku logs:set vector-sink` so Vector closes the oversized
  daily fd and opens a new hourly file. The closed daily file then
  becomes eligible for normal compression/retention on the next tick.
  Trigger points:
    - **per-app size cap:** `max-current-log-bytes` (default `500M`).
      Checked in `gc_check_current_log_size` at the start of `gc_app`.
      Warns on breach; acts only if the global flag is on.
    - **global watchdog fallback:** after `gc_disk_pressure` exhausts
      rotated files and free% is still below threshold, downgrades every
      daily app (flag-gated).
  Rationale for the flag gate: `logs:set vector-sink` briefly churns
  Vector's sink config, which can drop buffered events. Operators who
  prefer log gaps over disk-fills opt in; everyone else keeps the old
  known-gap behavior.

### Rotation modes

- `rotation` key accepts `daily` (default) or `hourly`. It maps to the
  strftime fragment Vector uses in the file-sink path:
  - `daily`  → `%Y-%m-%d`       → `2026-04-22.log`
  - `hourly` → `%Y-%m-%dT%H`    → `2026-04-22T15.log`
- Helpers `filelogs_rotation_pattern <app>` and
  `filelogs_current_log_name <app>` centralize this mapping; do not
  scatter strftime strings across subcommands.
- GC functions protect **both** the daily and hourly current filenames
  in every exclusion, regardless of the app's configured rotation. This
  costs nothing and makes mid-flight rotation switches safe.
- `tail` accepts `--date YYYY-MM-DD` (matches daily file and all 24
  hourly files for that date) and `--at YYYY-MM-DDTHH` (exact hour).
  Sorting by filename gives chronological order because the strftime
  patterns are zero-padded.
- `set rotation <v>` auto-re-runs `enable` for an already-enabled app so
  Vector picks up the new DSN. Global rotation changes only affect
  newly-enabled apps; the set subcommand prints an advisory.

### S3 backup

- Auth is **global**, not per-app. One set of credentials per plugin
  install. Lives at `$FILELOGS_CONFIG_ROOT/backup/credentials`,
  mode `0600`, key=value format (sourceable via `set -a; source ...`).
- Keys: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
  `AWS_DEFAULT_REGION`, `FILELOGS_S3_ENDPOINT` (empty for default AWS).
- Bucket / prefix / schedule live next to credentials as plain files:
  `backup/bucket`, `backup/prefix`, `backup/schedule`, `backup/last-run`.
- `backup` uses `aws s3 sync` with `--exclude "*" --include "*.log.gz"`,
  so the currently-open `.log` (mutable, being written by Vector) is
  never uploaded mid-write. Only rotated files reach S3.
- **The AWS CLI runs inside a container, never on the host.** This
  mirrors `dokku-postgres`'s `s3backup` approach: the host only needs
  Docker (which Dokku already requires), and we don't ship a hidden
  apt/pip dependency. Image is `$FILELOGS_AWS_IMAGE`
  (default `amazon/aws-cli:2.17.0`, override via env). `install`
  pre-pulls it best-effort; missing image triggers a lazy pull on
  first backup. `doctor` checks both Docker presence and image
  presence whenever credentials or a backup cron exist.
- Credentials are passed to the container via `docker --env-file`,
  not argv. Secrets must never appear in `ps`, `bash history`, or
  systemd journals — the env-file is `0600` and lives only on disk.
- The log dir is bind-mounted **read-only** at `/data` inside the
  container, so a compromised AWS CLI image cannot mutate logs.
- Sync is idempotent: re-running the same `backup` call is a no-op if
  nothing changed on disk. `aws s3 sync` handles dedup via size/etag.
- Scheduling writes a plain cron file to `$FILELOGS_CRON_FILE`
  (default `/etc/cron.d/dokku-filelogs-backup`, overridable for tests).
  The file runs `dokku filelogs:backup --all` as user `dokku`.
- Per-app opt-out: `dokku filelogs:set <app> backup-exclude true`.
  `filelogs_list_backup_candidates` filters these out.
- **Backup is best-effort, not required for retention.** The GC deletes
  by retention/cap regardless of backup status. Users who need
  guaranteed archival should schedule backup more frequently than
  retention (e.g., backup daily, retention=14d).
- Tests stub `docker` on PATH (the same stub mechanism as `dokku`).
  See `test_helper.bash:assert_docker_called_with` /
  `refute_docker_called_with`. The stub captures full argv to
  `$DOCKER_CALLS_LOG` and exits 0 — sufficient because backup
  assertions only verify the invocation shape (env-file path, bind
  mount, image, `s3 sync` args). For test isolation prefer
  `docker_sync_calls` over the raw log when filtering out incidental
  `image inspect` traffic from doctor/install.

### Return-0 invariant for getter helpers

Any helper that does `cat $possibly_missing_file` MUST end with
`return 0` (or wrap the cat in `if [[ -f ]]`). If it leaks a non-zero
return, subcommands that do `x=$(helper ...)` under `set -eo pipefail`
die silently. Bats' `run` disables errexit, so unit tests on the helper
itself will *not* catch the bug — it only shows up when the helper is
called from a subcommand body. `filelogs_get_raw`, `filelogs_backup_get`,
and `filelogs_backup_cred_get` all follow this invariant. New getters
must too.

### Disk-pressure watchdog

- `gc_disk_pressure` runs **after** `gc_app` and `gc_global`, so normal
  caps get a chance first.
- Uses `filelogs_free_percent` which calls `df -P -k` portably.
- Test hook: set `FILELOGS_FAKE_FREE_PERCENT=<int>` to bypass `df` and
  force a value. `tests/gc.bats` `setup()` sets it to `100` by default
  so retention/cap-specific tests are not disturbed by the real host's
  free space (the dev box commonly runs at ~2% free).
- `oldest_file*` helpers must always `return 0`, even when no file
  matched. If they inherit `[[ -n "" ]]`'s non-zero exit, `set -eo
  pipefail` kills the whole GC run the moment the watchdog loop
  iterates once with no more trimmable files. Regression hazard —
  don't tail the function with `[[ -n "$x" ]] && echo "$x"`.

## Test conventions

- Each subcommand has a `tests/<name>.bats` file. Each trigger is covered
  in `tests/hooks.bats`. Shared helpers live in `tests/functions.bats`.
- Tests load `test_helper.bash` which provides:
  - `setup_plugin_env` — creates per-test tmp dirs, exports
    `FILELOGS_LOG_ROOT` / `FILELOGS_CONFIG_ROOT`, stubs `dokku` on PATH.
  - `source_plugin` — sources `config` then `functions`.
  - `touch_days_ago <file> <days>` — portable mtime setter.
  - `assert_dokku_called_with <substring>` / `refute_dokku_called` —
    checks the stub's call log at `$DOKKU_CALLS_LOG`.
  - `run_subcommand <name> [args]` / `run_trigger <name> [args]` —
    thin wrappers over bats' `run`.

### Known bats gotcha

`run` executes in a subshell. **Arrays do not propagate into the subshell**,
even non-exported ones. Both:
- Avoid arrays (see the `config` rule above), or
- Call the function directly in the test body, not via `run`, when you
  need to assert return status:
  ```bash
  @test "example" {
    filelogs_is_valid_key retention-days   # asserts return 0
    ! filelogs_is_valid_key bogus          # asserts return non-zero
  }
  ```

## Adding a new subcommand

1. Create `subcommands/<name>`, executable, following the existing
   subcommand scaffolding (sources config + functions, wraps logic in a
   `cmd_<name>` function, handles the `filelogs:<name>` prefix shift).
2. Add a line to the help text in `commands` and `subcommands/default`.
3. If the subcommand mutates state, add a `post-delete`-style trigger if
   cleanup is needed on app removal.
4. Add a `tests/<name>.bats`. Cover the happy path, argument validation,
   and at least one failure mode.
5. Update `SCRIPTS` in the Makefile so shellcheck lints the new file.
6. `make test` must pass.

## Adding a new config key

1. Add a default in `config` (`FILELOGS_DEFAULT_<key_upper>`).
2. Add the key to `FILELOGS_VALID_KEYS` (and, if it cannot be per-app,
   to `FILELOGS_GLOBAL_ONLY_KEYS`).
3. Extend `filelogs_validate_value` in `functions` with a case branch.
4. Extend `filelogs_get_value` with a fallback case.
5. Surface it in `subcommands/report` output.
6. Add unit tests for the new branch in `tests/set.bats` and
   `tests/functions.bats`.

## Known limitations (documented, do not try to silently fix)

- **Unbounded growth of today's open log (mitigable).** If an app
  writes faster than the day rolls over, the current-day file will
  grow until the disk fills. The watchdog cannot touch today's open
  fd directly. Mitigation available via `max-current-log-bytes`
  (per-app size cap) + `pressure-auto-downgrade=true` (global flag)
  — see the "Today's open log is never deleted" section under
  Safety above. With the flag off, the limitation stands: size the
  log volume with headroom and rely on rotated-file reclamation.

## What NOT to do

- Do not import Docker logging drivers or run a sidecar supervisord.
  The Vector integration is Dokku-supported; replacing it is out of scope.
- Do not add `--force` flags that bypass the today-file protection.
- Do not silently catch errors in GC — a broken GC that appears to
  succeed is worse than one that loudly fails the systemd unit.
- Do not add dependencies beyond `bash`, coreutils, `gzip`, `find`,
  `stat`, `du`, `systemd`. The plugin must run on a stock Dokku host.
- Do not `chown` any path outside `$FILELOGS_LOG_ROOT` /
  `$FILELOGS_CONFIG_ROOT`.
