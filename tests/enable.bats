#!/usr/bin/env bats

load test_helper

setup() { setup_plugin_env; }

@test "enable: calls dokku logs:set with file sink and marks enabled" {
  run_subcommand enable myapp
  [ "$status" -eq 0 ]
  assert_dokku_called_with "logs:set myapp vector-sink file://"
  [ -f "$FILELOGS_CONFIG_ROOT/apps/myapp/enabled" ]
  [ -d "$FILELOGS_LOG_ROOT/myapp" ]
}

@test "enable: missing app arg exits non-zero" {
  run_subcommand enable
  [ "$status" -ne 0 ]
  [[ "$output" = *"usage"* ]]
}

@test "enable: respects format override" {
  source_plugin
  filelogs_set_value myapp format text
  run_subcommand enable myapp
  [ "$status" -eq 0 ]
  assert_dokku_called_with "encoding[codec]=text"
}

@test "enable: accepts command form (filelogs:enable myapp)" {
  run_subcommand enable filelogs:enable myapp
  [ "$status" -eq 0 ]
  assert_dokku_called_with "logs:set myapp vector-sink"
}

@test "enable: hourly rotation produces %H path" {
  source_plugin
  filelogs_set_value myapp rotation hourly
  run_subcommand enable myapp
  [ "$status" -eq 0 ]
  assert_dokku_called_with "%Y-%m-%dT%H.log"
}
