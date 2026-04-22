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

@test "build_sink_dsn: default format json" {
  run filelogs_build_sink_dsn myapp
  [ "$status" -eq 0 ]
  [[ "$output" = "file://$FILELOGS_LOG_ROOT/myapp/%Y-%m-%d.log?encoding[codec]=json" ]]
}

@test "build_sink_dsn: honors format override" {
  filelogs_set_value myapp format text
  run filelogs_build_sink_dsn myapp
  [[ "$output" = *"encoding[codec]=text" ]]
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

@test "oldest_file picks oldest matching" {
  mkdir -p "$BATS_TEST_TMPDIR/d"
  touch "$BATS_TEST_TMPDIR/d/new.log"
  touch "$BATS_TEST_TMPDIR/d/old.log"
  touch_days_ago "$BATS_TEST_TMPDIR/d/old.log" 3
  run filelogs_oldest_file "$BATS_TEST_TMPDIR/d" -name "*.log"
  [[ "$output" = *"old.log" ]]
}
