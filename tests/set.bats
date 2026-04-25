#!/usr/bin/env bats

load test_helper

setup() { setup_plugin_env; }

@test "set: per-app retention-days" {
  run_subcommand set myapp retention-days 7
  [ "$status" -eq 0 ]
  [ "$(cat "$FILELOGS_CONFIG_ROOT/apps/myapp/retention-days")" = "7" ]
}

@test "set: --global max-total-bytes" {
  run_subcommand set --global max-total-bytes 20G
  [ "$status" -eq 0 ]
  [ "$(cat "$FILELOGS_CONFIG_ROOT/max-total-bytes")" = "20G" ]
}

@test "set: rejects unknown key" {
  run_subcommand set myapp bogus 1
  [ "$status" -ne 0 ]
  [[ "$output" = *"invalid key"* ]]
}

@test "set: rejects invalid value" {
  run_subcommand set myapp retention-days notanumber
  [ "$status" -ne 0 ]
}

@test "set: rejects global-only key at app scope" {
  run_subcommand set myapp max-total-bytes 5G
  [ "$status" -ne 0 ]
  [[ "$output" = *"--global"* ]]
}

@test "set: format json valid" {
  run_subcommand set myapp format json
  [ "$status" -eq 0 ]
}

@test "set: format invalid rejected" {
  run_subcommand set myapp format xml
  [ "$status" -ne 0 ]
}

@test "set: --global min-free-disk-percent valid" {
  run_subcommand set --global min-free-disk-percent 15
  [ "$status" -eq 0 ]
  [ "$(cat "$FILELOGS_CONFIG_ROOT/min-free-disk-percent")" = "15" ]
}

@test "set: min-free-disk-percent rejects out-of-range" {
  run_subcommand set --global min-free-disk-percent 200
  [ "$status" -ne 0 ]
}

@test "set: min-free-disk-percent is global-only" {
  run_subcommand set myapp min-free-disk-percent 10
  [ "$status" -ne 0 ]
  [[ "$output" = *"--global"* ]]
}

@test "set: rotation daily valid" {
  run_subcommand set myapp rotation daily
  [ "$status" -eq 0 ]
  [ "$(cat "$FILELOGS_CONFIG_ROOT/apps/myapp/rotation")" = "daily" ]
}

@test "set: rotation hourly valid" {
  run_subcommand set myapp rotation hourly
  [ "$status" -eq 0 ]
  [ "$(cat "$FILELOGS_CONFIG_ROOT/apps/myapp/rotation")" = "hourly" ]
}

@test "set: rotation invalid rejected" {
  run_subcommand set myapp rotation weekly
  [ "$status" -ne 0 ]
}

@test "set: rotation change on enabled app re-applies Vector sink" {
  mkdir -p "$FILELOGS_CONFIG_ROOT/apps/myapp"
  echo 1 > "$FILELOGS_CONFIG_ROOT/apps/myapp/enabled"

  run_subcommand set myapp rotation hourly
  [ "$status" -eq 0 ]
  # enable subcommand was invoked, which in turn called dokku logs:set.
  assert_dokku_called_with "logs:set myapp vector-sink"
  assert_dokku_called_with "%25Y-%25m-%25dT%25H.log"
}

@test "set: rotation change on disabled app does not re-apply sink" {
  run_subcommand set myapp rotation hourly
  [ "$status" -eq 0 ]
  refute_dokku_called
}

@test "set: missing args errors" {
  run_subcommand set myapp
  [ "$status" -ne 0 ]
}

@test "set: per-app max-current-log-bytes" {
  run_subcommand set myapp max-current-log-bytes 200M
  [ "$status" -eq 0 ]
  [ "$(cat "$FILELOGS_CONFIG_ROOT/apps/myapp/max-current-log-bytes")" = "200M" ]
}

@test "set: max-current-log-bytes rejects garbage" {
  run_subcommand set myapp max-current-log-bytes 500XX
  [ "$status" -ne 0 ]
}

@test "set: pressure-auto-downgrade is global-only" {
  run_subcommand set myapp pressure-auto-downgrade true
  [ "$status" -ne 0 ]
  [[ "$output" = *"--global"* ]]
}

@test "set: --global pressure-auto-downgrade true" {
  run_subcommand set --global pressure-auto-downgrade true
  [ "$status" -eq 0 ]
  [ "$(cat "$FILELOGS_CONFIG_ROOT/pressure-auto-downgrade")" = "true" ]
}
