#!/usr/bin/env bats

load test_helper

setup() { setup_plugin_env; }

@test "disable: removes enabled flag and calls dokku unset" {
  mkdir -p "$FILELOGS_CONFIG_ROOT/apps/myapp"
  echo 1 > "$FILELOGS_CONFIG_ROOT/apps/myapp/enabled"

  run_subcommand disable myapp
  [ "$status" -eq 0 ]
  [ ! -f "$FILELOGS_CONFIG_ROOT/apps/myapp/enabled" ]
  assert_dokku_called_with "logs:unset myapp vector-sink"
}

@test "disable: missing app arg exits non-zero" {
  run_subcommand disable
  [ "$status" -ne 0 ]
}

@test "disable: does not delete log files" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  echo "data" > "$FILELOGS_LOG_ROOT/myapp/2025-01-01.log"
  run_subcommand disable myapp
  [ -f "$FILELOGS_LOG_ROOT/myapp/2025-01-01.log" ]
}
