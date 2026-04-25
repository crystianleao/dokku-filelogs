#!/usr/bin/env bats

load test_helper

setup() { setup_plugin_env; }

@test "commands help: single summary line, no subcommand list" {
  run "$PLUGIN_ROOT/commands" help
  [ "$status" -eq 0 ]
  [[ "$output" = *"persist Dokku app logs"* ]]
  # Must not leak the full subcommand list at top-level dokku help.
  [[ "$output" != *":enable <app>"* ]]
  [[ "$output" != *":backup-auth"* ]]
  [[ "$output" != *":tail"* ]]
  # Single non-empty line.
  local lines
  lines=$(printf '%s\n' "$output" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
  [ "$lines" = "1" ]
}

@test "commands filelogs:help: full subcommand list" {
  run "$PLUGIN_ROOT/commands" filelogs:help
  [ "$status" -eq 0 ]
  [[ "$output" = *"filelogs:enable"* ]]
  [[ "$output" = *"filelogs:disable"* ]]
  [[ "$output" = *"filelogs:set"* ]]
  [[ "$output" = *"filelogs:report"* ]]
  [[ "$output" = *"filelogs:gc"* ]]
  [[ "$output" = *"filelogs:tail"* ]]
  [[ "$output" = *"filelogs:backup"* ]]
  [[ "$output" = *"filelogs:backup-auth"* ]]
  [[ "$output" = *"filelogs:backup-deauth"* ]]
  [[ "$output" = *"filelogs:backup-schedule"* ]]
  [[ "$output" = *"filelogs:backup-unschedule"* ]]
  [[ "$output" = *"filelogs:backup-report"* ]]
}

@test "commands filelogs:help: lists all current config keys" {
  run "$PLUGIN_ROOT/commands" filelogs:help
  [ "$status" -eq 0 ]
  [[ "$output" = *"max-current-log-bytes"* ]]
  [[ "$output" = *"pressure-auto-downgrade"* ]]
  [[ "$output" = *"min-free-disk-percent"* ]]
  [[ "$output" = *"rotation"* ]]
  [[ "$output" = *"backup-exclude"* ]]
}

@test "commands unknown verb: exits with DOKKU_NOT_IMPLEMENTED_EXIT" {
  export DOKKU_NOT_IMPLEMENTED_EXIT=10
  run "$PLUGIN_ROOT/commands" totally-unknown
  [ "$status" -eq 10 ]
}

@test "subcommands/default still shows full subcommand block" {
  run "$PLUGIN_ROOT/subcommands/default"
  [ "$status" -eq 0 ]
  [[ "$output" = *"filelogs:enable"* ]]
  [[ "$output" = *"filelogs:backup-auth"* ]]
  [[ "$output" = *"max-current-log-bytes"* ]]
}
