#!/usr/bin/env bats

load test_helper

setup() {
  setup_plugin_env
  source_plugin
}

@test "human_to_bytes: plain integer" {
  run filelogs_human_to_bytes 1234
  [ "$status" -eq 0 ]
  [ "$output" = "1234" ]
}

@test "human_to_bytes: K suffix" {
  run filelogs_human_to_bytes 2K
  [ "$output" = "2048" ]
}

@test "human_to_bytes: M suffix" {
  run filelogs_human_to_bytes 3M
  [ "$output" = "3145728" ]
}

@test "human_to_bytes: G suffix" {
  run filelogs_human_to_bytes 1G
  [ "$output" = "1073741824" ]
}

@test "human_to_bytes: lowercase suffix" {
  run filelogs_human_to_bytes 2g
  [ "$output" = "2147483648" ]
}

@test "is_valid_key accepts known keys" {
  filelogs_is_valid_key retention-days
  filelogs_is_valid_key max-app-bytes
  filelogs_is_valid_key format
}

@test "is_valid_key rejects unknown" {
  ! filelogs_is_valid_key bogus
}

@test "is_global_only_key: max-total-bytes is global-only" {
  filelogs_is_global_only_key max-total-bytes
}

@test "is_global_only_key: retention-days is not global-only" {
  ! filelogs_is_global_only_key retention-days
}

@test "validate_value: valid retention-days" {
  run filelogs_validate_value retention-days 7
  [ "$status" -eq 0 ]
}

@test "validate_value: invalid retention-days" {
  run filelogs_validate_value retention-days foo
  [ "$status" -ne 0 ]
}

@test "validate_value: valid max-app-bytes" {
  run filelogs_validate_value max-app-bytes 500M
  [ "$status" -eq 0 ]
}

@test "validate_value: invalid max-app-bytes" {
  run filelogs_validate_value max-app-bytes "500XX"
  [ "$status" -ne 0 ]
}

@test "validate_value: format json ok" {
  run filelogs_validate_value format json
  [ "$status" -eq 0 ]
}

@test "validate_value: format text ok" {
  run filelogs_validate_value format text
  [ "$status" -eq 0 ]
}

@test "validate_value: format compact ok" {
  run filelogs_validate_value format compact
  [ "$status" -eq 0 ]
}

@test "validate_value: format invalid" {
  run filelogs_validate_value format xml
  [ "$status" -ne 0 ]
}

@test "validate_value: compress true/false" {
  run filelogs_validate_value compress true
  [ "$status" -eq 0 ]
  run filelogs_validate_value compress nope
  [ "$status" -ne 0 ]
}

@test "get_value: falls back to default when unset" {
  run filelogs_get_value myapp retention-days
  [ "$status" -eq 0 ]
  [ "$output" = "14" ]
}

@test "get_value: reads per-app override" {
  filelogs_set_value myapp retention-days 3
  run filelogs_get_value myapp retention-days
  [ "$output" = "3" ]
}

@test "get_value: per-app overrides global" {
  filelogs_set_value --global retention-days 30
  filelogs_set_value myapp retention-days 2
  run filelogs_get_value myapp retention-days
  [ "$output" = "2" ]
}

@test "get_value: global overrides default when per-app unset" {
  filelogs_set_value --global retention-days 30
  run filelogs_get_value myapp retention-days
  [ "$output" = "30" ]
}

@test "build_sink_dsn: default format compact, default daily rotation" {
  # Compact is the default format so log lines carry a `timestamp`
  # field out of the box. The DSN therefore includes only_fields.
  run filelogs_build_sink_dsn myapp
  [ "$status" -eq 0 ]
  [[ "$output" = "file:///?path=$FILELOGS_LOG_ROOT/myapp/%25Y-%25m-%25d.log&encoding[codec]=json&encoding[only_fields][]=timestamp&encoding[only_fields][]=message&encoding[only_fields][]=container_name" ]]
}

@test "build_sink_dsn: explicit format json drops only_fields" {
  filelogs_set_value myapp format json
  run filelogs_build_sink_dsn myapp
  [ "$status" -eq 0 ]
  [[ "$output" != *"only_fields"* ]]
  [[ "$output" = *"encoding[codec]=json" ]]
}

@test "build_sink_dsn: honors format override" {
  filelogs_set_value myapp format text
  run filelogs_build_sink_dsn myapp
  [[ "$output" = *"encoding[codec]=text" ]]
}

@test "build_sink_dsn: hourly rotation injects %H into path" {
  filelogs_set_value myapp rotation hourly
  run filelogs_build_sink_dsn myapp
  [ "$status" -eq 0 ]
  [[ "$output" = *"%25Y-%25m-%25dT%25H.log"* ]]
}

@test "build_sink_dsn: uses ?path= query param, not URL path" {
  # Regression: putting the abs path in the URL component makes Dokku
  # emit a vector.json sink with no `path` field, and Vector enters a
  # restart loop. Path must ship as the `path` query parameter.
  run filelogs_build_sink_dsn myapp
  [ "$status" -eq 0 ]
  [[ "$output" = "file:///?path="* ]]
  [[ "$output" = *"&encoding[codec]="* ]]
}

@test "build_sink_dsn: contains no bare strftime tokens" {
  # Regression: bare %Y in DSN makes Dokku's url.Parse fail with
  # "invalid URL escape \"%Y-\"". All percent signs must ship as %25.
  run filelogs_build_sink_dsn myapp
  [ "$status" -eq 0 ]
  [[ "$output" != *"%Y"* ]]
  [[ "$output" != *"%m"* ]]
  [[ "$output" != *"%d"* ]]
  [[ "$output" = *"%25Y-%25m-%25d"* ]]
}

@test "build_sink_dsn: format compact emits only_fields" {
  filelogs_set_value myapp format compact
  run filelogs_build_sink_dsn myapp
  [ "$status" -eq 0 ]
  [[ "$output" = *"encoding[codec]=json"* ]]
  [[ "$output" = *"encoding[only_fields][]=timestamp"* ]]
  [[ "$output" = *"encoding[only_fields][]=message"* ]]
  [[ "$output" = *"encoding[only_fields][]=container_name"* ]]
}

@test "build_sink_dsn: compact uses qson array syntax not indexed map" {
  # Regression: Dokku parses the DSN via the qson library. Indexed
  # brackets like `key[0]=v` produce a map {"0":"v"} and Vector
  # rejects it ("invalid type: map, expected a sequence"). Empty
  # brackets `key[]=v` produce a proper array.
  filelogs_set_value myapp format compact
  run filelogs_build_sink_dsn myapp
  [ "$status" -eq 0 ]
  local count
  count=$(echo "$output" | grep -o 'encoding\[only_fields\]\[\]' | wc -l | tr -d ' ')
  [ "$count" = "3" ]
  [[ "$output" != *"only_fields][0]"* ]]
  [[ "$output" != *"only_fields][1]"* ]]
  [[ "$output" != *"only_fields][2]"* ]]
}

@test "build_sink_dsn: format text drops only_fields" {
  filelogs_set_value myapp format text
  run filelogs_build_sink_dsn myapp
  [ "$status" -eq 0 ]
  [[ "$output" != *"only_fields"* ]]
}

@test "build_sink_dsn: hourly form has no bare %H either" {
  filelogs_set_value myapp rotation hourly
  run filelogs_build_sink_dsn myapp
  [ "$status" -eq 0 ]
  [[ "$output" != *"%H"* ]]
  [[ "$output" = *"%25H"* ]]
}

@test "build_sink_dsn: parses cleanly under Go-style URL parser" {
  # If python3 isn't available we cannot run this check; skip rather
  # than fail. urllib.parse.urlparse rejects invalid percent escapes
  # the same way Go's net/url does. Also asserts the `path` query
  # parameter decodes back to the strftime template Vector expects.
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"

  run filelogs_build_sink_dsn myapp
  [ "$status" -eq 0 ]
  local dsn="$output"

  run python3 - <<PY "$dsn"
import sys, urllib.parse
p = urllib.parse.urlparse(sys.argv[1])
qs = urllib.parse.parse_qs(p.query, strict_parsing=True)
path = qs.get('path', [''])[0]
assert path.endswith('.log'), path
assert '%Y-%m-%d' in path, path
PY
  [ "$status" -eq 0 ]
}

@test "validate_dsn: accepts a well-formed DSN" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  filelogs_validate_dsn "file:///?path=/tmp/x.log&encoding[codec]=json"
}

@test "validate_dsn: rejects bare percent escapes" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  ! filelogs_validate_dsn "file:///?path=/tmp/%Y.log&encoding[codec]=json"
}

@test "validate_dsn: accepts DSN built by build_sink_dsn" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  local dsn
  dsn=$(filelogs_build_sink_dsn myapp)
  filelogs_validate_dsn "$dsn"
}

@test "validate_dsn: accepts compact DSN built by build_sink_dsn" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  filelogs_set_value myapp format compact
  local dsn
  dsn=$(filelogs_build_sink_dsn myapp)
  filelogs_validate_dsn "$dsn"
}

@test "url_encode_pattern: leaves percent-free input untouched" {
  run filelogs_url_encode_pattern "plain-text"
  [ "$output" = "plain-text" ]
}

@test "url_encode_pattern: encodes every percent" {
  run filelogs_url_encode_pattern "%Y-%m-%dT%H"
  [ "$output" = "%25Y-%25m-%25dT%25H" ]
}

@test "rotation_pattern: daily default" {
  run filelogs_rotation_pattern myapp
  [ "$output" = "%Y-%m-%d" ]
}

@test "rotation_pattern: hourly override" {
  filelogs_set_value myapp rotation hourly
  run filelogs_rotation_pattern myapp
  [ "$output" = "%Y-%m-%dT%H" ]
}

@test "current_log_name: daily" {
  run filelogs_current_log_name myapp
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\.log$ ]]
}

@test "current_log_name: hourly" {
  filelogs_set_value myapp rotation hourly
  run filelogs_current_log_name myapp
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}\.log$ ]]
}

@test "validate_value: rotation daily|hourly" {
  run filelogs_validate_value rotation daily
  [ "$status" -eq 0 ]
  run filelogs_validate_value rotation hourly
  [ "$status" -eq 0 ]
  run filelogs_validate_value rotation nope
  [ "$status" -ne 0 ]
}

@test "list_apps lists configured app dirs" {
  mkdir -p "$FILELOGS_CONFIG_ROOT/apps/alpha" "$FILELOGS_CONFIG_ROOT/apps/beta"
  run filelogs_list_apps
  [[ "$output" = *"alpha"* ]]
  [[ "$output" = *"beta"* ]]
}

@test "dir_bytes: empty dir is 0" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  run filelogs_dir_bytes "$BATS_TEST_TMPDIR/empty"
  [ "$output" = "0" ]
}

@test "dir_bytes: non-empty > 0" {
  mkdir -p "$BATS_TEST_TMPDIR/nonempty"
  dd if=/dev/zero of="$BATS_TEST_TMPDIR/nonempty/file" bs=1024 count=4 >/dev/null 2>&1
  run filelogs_dir_bytes "$BATS_TEST_TMPDIR/nonempty"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "free_percent: fake override returns that value" {
  FILELOGS_FAKE_FREE_PERCENT=7 run filelogs_free_percent "$FILELOGS_LOG_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
}

@test "free_percent: real df yields integer 0..100" {
  run filelogs_free_percent "$FILELOGS_LOG_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -ge 0 ]
  [ "$output" -le 100 ]
}

@test "validate_value: min-free-disk-percent in range" {
  run filelogs_validate_value min-free-disk-percent 10
  [ "$status" -eq 0 ]
}

@test "validate_value: min-free-disk-percent out of range" {
  run filelogs_validate_value min-free-disk-percent 150
  [ "$status" -ne 0 ]
  run filelogs_validate_value min-free-disk-percent -1
  [ "$status" -ne 0 ]
  run filelogs_validate_value min-free-disk-percent abc
  [ "$status" -ne 0 ]
}

@test "oldest_file picks oldest matching" {
  mkdir -p "$BATS_TEST_TMPDIR/d"
  touch "$BATS_TEST_TMPDIR/d/new.log"
  touch "$BATS_TEST_TMPDIR/d/old.log"
  touch_days_ago "$BATS_TEST_TMPDIR/d/old.log" 3
  run filelogs_oldest_file "$BATS_TEST_TMPDIR/d" -name "*.log"
  [[ "$output" = *"old.log" ]]
}

@test "validate_value: max-current-log-bytes accepts bytes or N[KMG]" {
  run filelogs_validate_value max-current-log-bytes 500M
  [ "$status" -eq 0 ]
  run filelogs_validate_value max-current-log-bytes 1073741824
  [ "$status" -eq 0 ]
  run filelogs_validate_value max-current-log-bytes 2g
  [ "$status" -eq 0 ]
}

@test "validate_value: max-current-log-bytes rejects garbage" {
  run filelogs_validate_value max-current-log-bytes "500XX"
  [ "$status" -ne 0 ]
}

@test "validate_value: pressure-auto-downgrade is boolean" {
  run filelogs_validate_value pressure-auto-downgrade true
  [ "$status" -eq 0 ]
  run filelogs_validate_value pressure-auto-downgrade false
  [ "$status" -eq 0 ]
  run filelogs_validate_value pressure-auto-downgrade sometimes
  [ "$status" -ne 0 ]
}

@test "is_valid_key accepts max-current-log-bytes and pressure-auto-downgrade" {
  filelogs_is_valid_key max-current-log-bytes
  filelogs_is_valid_key pressure-auto-downgrade
}

@test "is_global_only_key: pressure-auto-downgrade is global-only" {
  filelogs_is_global_only_key pressure-auto-downgrade
}

@test "is_global_only_key: max-current-log-bytes is not global-only" {
  ! filelogs_is_global_only_key max-current-log-bytes
}

@test "get_value: max-current-log-bytes default is set" {
  run filelogs_get_value myapp max-current-log-bytes
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" =~ ^[0-9]+[KkMmGg]?$ ]]
}

@test "get_value: pressure-auto-downgrade default is false" {
  run filelogs_get_value --global pressure-auto-downgrade
  [ "$output" = "false" ]
}

@test "file_size: missing file returns 0" {
  run filelogs_file_size "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "file_size: reports size for real file" {
  dd if=/dev/zero of="$BATS_TEST_TMPDIR/f" bs=1024 count=2 >/dev/null 2>&1
  run filelogs_file_size "$BATS_TEST_TMPDIR/f"
  [ "$status" -eq 0 ]
  [ "$output" = "2048" ]
}

@test "current_log_bytes: 0 when today file absent" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  run filelogs_current_log_bytes myapp
  [ "$output" = "0" ]
}

@test "current_log_bytes: reads today's size under daily rotation" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  local today
  today="$FILELOGS_LOG_ROOT/myapp/$(filelogs_today).log"
  dd if=/dev/zero of="$today" bs=1024 count=3 >/dev/null 2>&1
  run filelogs_current_log_bytes myapp
  [ "$output" = "3072" ]
}

@test "downgrade_rotation: no-op when not enabled" {
  filelogs_set_value myapp rotation daily
  ! filelogs_downgrade_rotation myapp
  refute_dokku_called
  [ "$(cat "$FILELOGS_CONFIG_ROOT/apps/myapp/rotation")" = "daily" ]
}

@test "downgrade_rotation: no-op when already hourly" {
  mkdir -p "$FILELOGS_CONFIG_ROOT/apps/myapp"
  echo 1 > "$FILELOGS_CONFIG_ROOT/apps/myapp/enabled"
  filelogs_set_value myapp rotation hourly
  ! filelogs_downgrade_rotation myapp
  refute_dokku_called
}

@test "vector_status: honors FILELOGS_FAKE_VECTOR_STATUS" {
  FILELOGS_FAKE_VECTOR_STATUS=running run filelogs_vector_status
  [ "$output" = "running" ]
  FILELOGS_FAKE_VECTOR_STATUS=restarting run filelogs_vector_status
  [ "$output" = "restarting" ]
}

@test "vector_config_path: defaults under /var/lib/dokku, override via env" {
  unset FILELOGS_VECTOR_CONFIG
  run filelogs_vector_config_path
  [[ "$output" = *"/var/lib/dokku/data/logs/vector.json" ]]
  FILELOGS_VECTOR_CONFIG=/tmp/foo.json run filelogs_vector_config_path
  [ "$output" = "/tmp/foo.json" ]
}

@test "vector_has_sink_for_app: true when path present" {
  cat > "$BATS_TEST_TMPDIR/v.json" <<'J'
{"sources":{},"sinks":{"docker-sink:myapp":{"type":"file","path":"/x.log","encoding":{"codec":"json"}}}}
J
  FILELOGS_VECTOR_CONFIG="$BATS_TEST_TMPDIR/v.json" filelogs_vector_has_sink_for_app myapp
}

@test "vector_has_sink_for_app: false when path absent" {
  cat > "$BATS_TEST_TMPDIR/v.json" <<'J'
{"sources":{},"sinks":{"docker-sink:myapp":{"type":"file","encoding":{"codec":"json"}}}}
J
  ! FILELOGS_VECTOR_CONFIG="$BATS_TEST_TMPDIR/v.json" filelogs_vector_has_sink_for_app myapp
}

@test "vector_has_sink_for_app: false when sink absent" {
  cat > "$BATS_TEST_TMPDIR/v.json" <<'J'
{"sources":{},"sinks":{}}
J
  ! FILELOGS_VECTOR_CONFIG="$BATS_TEST_TMPDIR/v.json" filelogs_vector_has_sink_for_app myapp
}

@test "vector_sink_path_for_app: emits configured path" {
  cat > "$BATS_TEST_TMPDIR/v.json" <<'J'
{"sources":{},"sinks":{"docker-sink:myapp":{"type":"file","path":"/var/log/x.log"}}}
J
  FILELOGS_VECTOR_CONFIG="$BATS_TEST_TMPDIR/v.json" run filelogs_vector_sink_path_for_app myapp
  [ "$output" = "/var/log/x.log" ]
}

@test "vector_restart: skipped when FILELOGS_SKIP_VECTOR_RESTART=true" {
  FILELOGS_SKIP_VECTOR_RESTART=true filelogs_vector_restart
  refute_dokku_called
}

@test "vector_restart: calls vector-stop then vector-start" {
  unset FILELOGS_SKIP_VECTOR_RESTART
  filelogs_vector_restart
  assert_dokku_called_with "logs:vector-stop"
  assert_dokku_called_with "logs:vector-start"
}

@test "downgrade_rotation: switches daily->hourly and re-emits DSN" {
  mkdir -p "$FILELOGS_CONFIG_ROOT/apps/myapp"
  echo 1 > "$FILELOGS_CONFIG_ROOT/apps/myapp/enabled"
  filelogs_set_value myapp rotation daily
  filelogs_downgrade_rotation myapp
  [ "$(cat "$FILELOGS_CONFIG_ROOT/apps/myapp/rotation")" = "hourly" ]
  assert_dokku_called_with "logs:set myapp vector-sink"
  assert_dokku_called_with "%25Y-%25m-%25dT%25H.log"
}
