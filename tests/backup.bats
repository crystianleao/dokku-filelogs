#!/usr/bin/env bats

load test_helper

setup() {
  setup_plugin_env
  source_plugin
}

# --- backup-auth -----------------------------------------------------------

@test "backup-auth: writes credentials file mode 0600" {
  run_subcommand backup-auth AKIATEST secretvalue us-east-1
  [ "$status" -eq 0 ]

  local cred="$FILELOGS_CONFIG_ROOT/backup/credentials"
  [ -f "$cred" ]
  # Mode check (portable: ls -l).
  local mode
  mode=$(stat -f %Lp "$cred" 2>/dev/null || stat -c %a "$cred")
  [ "$mode" = "600" ]

  grep -q "AWS_ACCESS_KEY_ID=AKIATEST" "$cred"
  grep -q "AWS_SECRET_ACCESS_KEY=secretvalue" "$cred"
  grep -q "AWS_DEFAULT_REGION=us-east-1" "$cred"
}

@test "backup-auth: stores endpoint for S3-compat" {
  run_subcommand backup-auth k s us-east-1 https://s3.example.com
  [ "$status" -eq 0 ]
  grep -q "FILELOGS_S3_ENDPOINT=https://s3.example.com" \
    "$FILELOGS_CONFIG_ROOT/backup/credentials"
}

@test "backup-auth: missing args errors with usage" {
  run_subcommand backup-auth
  [ "$status" -ne 0 ]
  [[ "$output" = *"usage"* ]]
}

# --- backup-deauth ---------------------------------------------------------

@test "backup-deauth: removes credentials" {
  run_subcommand backup-auth key secret
  [ -f "$FILELOGS_CONFIG_ROOT/backup/credentials" ]

  run_subcommand backup-deauth
  [ "$status" -eq 0 ]
  [ ! -f "$FILELOGS_CONFIG_ROOT/backup/credentials" ]
}

@test "backup-deauth: no-op when no credentials" {
  run_subcommand backup-deauth
  [ "$status" -eq 0 ]
}

# --- backup ----------------------------------------------------------------

@test "backup: fails without credentials" {
  run_subcommand backup myapp --bucket b
  [ "$status" -ne 0 ]
  [[ "$output" = *"no credentials"* ]]
}

@test "backup: fails without bucket" {
  run_subcommand backup-auth k s
  run_subcommand backup myapp
  [ "$status" -ne 0 ]
  [[ "$output" = *"no bucket"* ]]
}

@test "backup: single app invokes aws s3 sync inside container with correct args" {
  run_subcommand backup-auth k s us-east-1
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"

  run_subcommand backup myapp --bucket my-bucket
  [ "$status" -eq 0 ]

  # Container plumbing: ephemeral, env-file with creds, read-only bind mount, AWS CLI image.
  assert_docker_called_with "container run --rm"
  assert_docker_called_with "--env-file $FILELOGS_CONFIG_ROOT/backup/credentials"
  assert_docker_called_with "-v $FILELOGS_LOG_ROOT/myapp:/data:ro"
  assert_docker_called_with "$FILELOGS_AWS_IMAGE"

  # Sync arguments: container-internal /data path, S3 destination, log.gz filter.
  assert_docker_called_with "s3 sync /data s3://my-bucket/myapp/"
  assert_docker_called_with "--exclude * --include *.log.gz"
}

@test "backup: secrets never appear in docker argv (passed via --env-file)" {
  run_subcommand backup-auth AKIATEST topsecretvalue us-east-1
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"

  run_subcommand backup myapp --bucket b
  [ "$status" -eq 0 ]

  # The credentials must be referenced by file path only — never inlined.
  refute_docker_called_with "AKIATEST"
  refute_docker_called_with "topsecretvalue"
}

@test "backup: prefix is applied to S3 destination" {
  run_subcommand backup-auth k s
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"

  run_subcommand backup myapp --bucket b --prefix archives
  [ "$status" -eq 0 ]
  assert_docker_called_with "s3://b/archives/myapp/"
}

@test "backup: custom endpoint passed through" {
  run_subcommand backup-auth k s us-east-1 https://s3.my-host.example.com
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"

  run_subcommand backup myapp --bucket b
  [ "$status" -eq 0 ]
  assert_docker_called_with "--endpoint-url https://s3.my-host.example.com"
}

@test "backup: --all iterates every app dir" {
  run_subcommand backup-auth k s
  mkdir -p "$FILELOGS_LOG_ROOT/a" "$FILELOGS_LOG_ROOT/b"

  run_subcommand backup --all --bucket B
  [ "$status" -eq 0 ]
  assert_docker_called_with "s3://B/a/"
  assert_docker_called_with "s3://B/b/"
}

@test "backup: --all skips apps with backup-exclude=true" {
  run_subcommand backup-auth k s
  mkdir -p "$FILELOGS_LOG_ROOT/keep" "$FILELOGS_LOG_ROOT/skip"
  filelogs_set_value skip backup-exclude true

  run_subcommand backup --all --bucket B
  [ "$status" -eq 0 ]
  assert_docker_called_with "s3://B/keep/"
  refute_docker_called_with "s3://B/skip/"
}

@test "backup: success writes last-attempt + last-success, no last-error" {
  run_subcommand backup-auth k s
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"

  run_subcommand backup myapp --bucket b
  [ "$status" -eq 0 ]

  local dir="$FILELOGS_CONFIG_ROOT/backup"
  [ -f "$dir/last-attempt" ]
  [ -f "$dir/last-success" ]
  [ ! -f "$dir/last-error" ]
  grep -qE "^[0-9]+$" "$dir/last-attempt"
  grep -qE "^[0-9]+$" "$dir/last-success"
}

@test "backup: failure writes last-attempt + last-error, no last-success" {
  run_subcommand backup-auth k s
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"

  # Force the docker stub to fail so sync_app returns non-zero.
  cat > "$DOKKU_STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS_LOG"
case "$1 $2" in
  "container run") exit 7 ;;
  *)               exit 0 ;;
esac
STUB
  chmod +x "$DOKKU_STUB_DIR/docker"

  run_subcommand backup myapp --bucket b
  [ "$status" -ne 0 ]

  local dir="$FILELOGS_CONFIG_ROOT/backup"
  [ -f "$dir/last-attempt" ]
  [ ! -f "$dir/last-success" ]
  [ -f "$dir/last-error" ]
  grep -q "1/1 apps failed" "$dir/last-error"
}

@test "backup: success after a prior error clears last-error" {
  run_subcommand backup-auth k s
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"

  local dir="$FILELOGS_CONFIG_ROOT/backup"
  echo "stale error" > "$dir/last-error"

  run_subcommand backup myapp --bucket b
  [ "$status" -eq 0 ]
  [ ! -f "$dir/last-error" ]
}

# --- backup-schedule -------------------------------------------------------

@test "backup-schedule: writes cron file with the command line" {
  run_subcommand backup-auth k s
  run_subcommand backup-schedule "0 3 * * *" --bucket my-logs --prefix hist
  [ "$status" -eq 0 ]

  [ -f "$FILELOGS_CRON_FILE" ]
  grep -q "0 3 \* \* \*" "$FILELOGS_CRON_FILE"
  grep -q "filelogs:backup --bucket my-logs --prefix hist --all" "$FILELOGS_CRON_FILE"
}

@test "backup-schedule: requires auth" {
  run_subcommand backup-schedule "0 3 * * *" --bucket b
  [ "$status" -ne 0 ]
}

@test "backup-schedule: invalid cron rejected" {
  run_subcommand backup-auth k s
  run_subcommand backup-schedule "not a cron" --bucket b
  [ "$status" -ne 0 ]
  [[ "$output" = *"invalid cron"* ]]
}

@test "backup-schedule: persists bucket and schedule for report" {
  run_subcommand backup-auth k s
  run_subcommand backup-schedule "*/15 * * * *" --bucket archive
  [ "$status" -eq 0 ]
  [ "$(cat "$FILELOGS_CONFIG_ROOT/backup/bucket")" = "archive" ]
  [ "$(cat "$FILELOGS_CONFIG_ROOT/backup/schedule")" = "*/15 * * * *" ]
}

# --- backup-unschedule -----------------------------------------------------

@test "backup-unschedule: removes cron file" {
  run_subcommand backup-auth k s
  run_subcommand backup-schedule "0 3 * * *" --bucket b
  [ -f "$FILELOGS_CRON_FILE" ]

  run_subcommand backup-unschedule
  [ "$status" -eq 0 ]
  [ ! -f "$FILELOGS_CRON_FILE" ]
}

# --- backup-report ---------------------------------------------------------

@test "backup-report: shows 'no' when uninitialized" {
  run_subcommand backup-report
  [ "$status" -eq 0 ]
  [[ "$output" = *"credentials:      no"* ]]
  [[ "$output" = *"bucket:           <unset>"* ]]
}

@test "backup-report: shows details after auth + schedule" {
  run_subcommand backup-auth k s eu-west-1 https://ep.example.com
  run_subcommand backup-schedule "0 3 * * *" --bucket my-logs --prefix arc

  run_subcommand backup-report
  [ "$status" -eq 0 ]
  [[ "$output" = *"credentials:      yes"* ]]
  [[ "$output" = *"region:           eu-west-1"* ]]
  [[ "$output" = *"endpoint:         https://ep.example.com"* ]]
  [[ "$output" = *"bucket:           my-logs"* ]]
  [[ "$output" = *"prefix:           arc"* ]]
  [[ "$output" = *"schedule (cron):  0 3 * * *"* ]]
}

@test "backup-report: reflects no cron file after unschedule" {
  run_subcommand backup-auth k s
  run_subcommand backup-schedule "0 3 * * *" --bucket b
  run_subcommand backup-unschedule

  run_subcommand backup-report
  [[ "$output" = *"(absent)"* ]]
}

# --- set: backup-exclude ---------------------------------------------------

@test "set: backup-exclude true valid" {
  run_subcommand set myapp backup-exclude true
  [ "$status" -eq 0 ]
}

@test "set: backup-exclude invalid rejected" {
  run_subcommand set myapp backup-exclude maybe
  [ "$status" -ne 0 ]
}
