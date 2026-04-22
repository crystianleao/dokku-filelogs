#!/usr/bin/env bats

load test_helper

setup() { setup_plugin_env; }

@test "report: global default output mentions log root and max-total-bytes" {
  run_subcommand report
  [ "$status" -eq 0 ]
  [[ "$output" = *"filelogs global report"* ]]
  [[ "$output" = *"$FILELOGS_LOG_ROOT"* ]]
  [[ "$output" = *"max-total-bytes"* ]]
}

@test "report: shows disk free percent and status" {
  FILELOGS_FAKE_FREE_PERCENT=90 run_subcommand report
  [ "$status" -eq 0 ]
  [[ "$output" = *"disk free:"* ]]
  [[ "$output" = *"90%"* ]]
  [[ "$output" = *"status: ok"* ]]
}

@test "report: flags LOW status when below threshold" {
  export FILELOGS_FAKE_FREE_PERCENT=3
  run_subcommand report
  [ "$status" -eq 0 ]
  [[ "$output" = *"status: LOW"* ]]
}

@test "report: per-app shows enabled state yes when flag present" {
  mkdir -p "$FILELOGS_CONFIG_ROOT/apps/myapp"
  echo 1 > "$FILELOGS_CONFIG_ROOT/apps/myapp/enabled"
  run_subcommand report myapp
  [ "$status" -eq 0 ]
  [[ "$output" = *"enabled:          yes"* ]]
}

@test "report: per-app shows enabled no when flag absent" {
  run_subcommand report myapp
  [ "$status" -eq 0 ]
  [[ "$output" = *"enabled:          no"* ]]
}

@test "report: includes disk used line" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  dd if=/dev/zero of="$FILELOGS_LOG_ROOT/myapp/data" bs=1024 count=2 >/dev/null 2>&1
  run_subcommand report myapp
  [[ "$output" = *"disk used:"* ]]
}
