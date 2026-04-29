#!/usr/bin/env bash
# Shared test helpers. Sourced by every .bats file.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PLUGIN_ROOT

setup_plugin_env() {
  export FILELOGS_LOG_ROOT="$BATS_TEST_TMPDIR/logs"
  export FILELOGS_CONFIG_ROOT="$BATS_TEST_TMPDIR/config"
  mkdir -p "$FILELOGS_LOG_ROOT" "$FILELOGS_CONFIG_ROOT/apps"

  # Stub `dokku` on PATH — captures calls to a log file.
  export DOKKU_STUB_DIR="$BATS_TEST_TMPDIR/bin"
  export DOKKU_CALLS_LOG="$BATS_TEST_TMPDIR/dokku-calls.log"
  : > "$DOKKU_CALLS_LOG"
  mkdir -p "$DOKKU_STUB_DIR"
  cat > "$DOKKU_STUB_DIR/dokku" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOKKU_CALLS_LOG"
STUB
  chmod +x "$DOKKU_STUB_DIR/dokku"
  export PATH="$DOKKU_STUB_DIR:$PATH"

  # Stub `docker` for backup tests — echoes invocation to log.
  # filelogs:backup runs the AWS CLI inside a container, so we capture
  # the full `docker container run ... amazon/aws-cli s3 sync ...` argv.
  # Other Docker commands (image inspect, etc.) succeed silently — the
  # stub returns 0 so doctor/install hooks behave as if Docker is healthy.
  export DOCKER_CALLS_LOG="$BATS_TEST_TMPDIR/docker-calls.log"
  : > "$DOCKER_CALLS_LOG"
  cat > "$DOKKU_STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS_LOG"
# `image inspect` callers (doctor, install) check via exit status: the
# default 0 means "image present" which is convenient in tests.
exit 0
STUB
  chmod +x "$DOKKU_STUB_DIR/docker"

  # Skip Vector container side-effects in tests by default. Specific
  # tests opt back in via `unset FILELOGS_SKIP_VECTOR_RESTART` etc.
  export FILELOGS_SKIP_VECTOR_RESTART=true
  export FILELOGS_SKIP_VECTOR_VERIFY=true

  # Redirect cron file to tmp so backup-schedule tests don't touch /etc.
  export FILELOGS_CRON_FILE="$BATS_TEST_TMPDIR/cron/dokku-filelogs-backup"
  export FILELOGS_DOKKU_BIN="/usr/bin/dokku"

  # Disable tracing noise in tests.
  unset DOKKU_TRACE
}

assert_docker_called_with() {
  local needle="$1"
  if ! grep -qF -- "$needle" "$DOCKER_CALLS_LOG"; then
    echo "Expected docker call containing: $needle"
    echo "Actual calls:"
    cat "$DOCKER_CALLS_LOG"
    return 1
  fi
}

refute_docker_called_with() {
  local needle="$1"
  if grep -qF -- "$needle" "$DOCKER_CALLS_LOG"; then
    echo "Expected no docker call containing: $needle"
    echo "Actual calls:"
    cat "$DOCKER_CALLS_LOG"
    return 1
  fi
}

# Returns only the lines that look like `container run ... s3 sync ...`
# invocations — filters out incidental `image inspect` calls from doctor
# / install / backup-report so backup-specific assertions are robust.
docker_sync_calls() {
  grep -F 'container run' "$DOCKER_CALLS_LOG" | grep -F 's3 sync' || true
}

source_plugin() {
  # shellcheck source=/dev/null
  source "$PLUGIN_ROOT/config"
  # shellcheck source=/dev/null
  source "$PLUGIN_ROOT/functions"
}

# Set file mtime to N days in the past, portable (GNU + BSD).
touch_days_ago() {
  local file="$1" days="$2"
  local target_ts
  if date -d "@0" >/dev/null 2>&1; then
    # GNU date
    target_ts=$(date -d "$days days ago" +%Y%m%d%H%M.%S)
  else
    # BSD date (macOS)
    target_ts=$(date -v-"${days}"d +%Y%m%d%H%M.%S)
  fi
  touch -t "$target_ts" "$file"
}

assert_dokku_called_with() {
  local needle="$1"
  if ! grep -qF -- "$needle" "$DOKKU_CALLS_LOG"; then
    echo "Expected dokku call containing: $needle"
    echo "Actual calls:"
    cat "$DOKKU_CALLS_LOG"
    return 1
  fi
}

refute_dokku_called() {
  if [[ -s "$DOKKU_CALLS_LOG" ]]; then
    echo "Expected no dokku calls, but got:"
    cat "$DOKKU_CALLS_LOG"
    return 1
  fi
}

run_subcommand() {
  # Usage: run_subcommand <name> [args...]
  local name="$1"; shift
  run "$PLUGIN_ROOT/subcommands/$name" "$@"
}

run_trigger() {
  local name="$1"; shift
  run "$PLUGIN_ROOT/$name" "$@"
}
