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

@test "set: missing args errors" {
  run_subcommand set myapp
  [ "$status" -ne 0 ]
}
