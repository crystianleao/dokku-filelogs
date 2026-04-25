#!/usr/bin/env bats

load test_helper

setup() { setup_plugin_env; }

@test "enable: calls dokku logs:set with file sink and marks enabled" {
  run_subcommand enable myapp
  [ "$status" -eq 0 ]
  assert_dokku_called_with "logs:set myapp vector-sink file:///?path="
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
  assert_dokku_called_with "%25Y-%25m-%25dT%25H.log"
}

@test "enable: DSN passed to dokku contains no bare strftime tokens" {
  # Regression: Dokku url.Parse rejects "%Y-" as invalid percent escape.
  run_subcommand enable myapp
  [ "$status" -eq 0 ]
  ! grep -E '%[YmdH][^0-9a-fA-F]' "$DOKKU_CALLS_LOG"
  grep -F '%25Y-%25m-%25d.log' "$DOKKU_CALLS_LOG"
}

@test "enable: restarts vector container after logs:set" {
  unset FILELOGS_SKIP_VECTOR_RESTART
  run_subcommand enable myapp
  [ "$status" -eq 0 ]
  assert_dokku_called_with "logs:vector-stop"
  assert_dokku_called_with "logs:vector-start"
}

@test "enable: warns when sink is absent from vector.json" {
  unset FILELOGS_SKIP_VECTOR_VERIFY
  export FILELOGS_VECTOR_CONFIG="$BATS_TEST_TMPDIR/vector.json"
  echo '{"sinks":{}}' > "$FILELOGS_VECTOR_CONFIG"
  run_subcommand enable myapp
  [ "$status" -eq 0 ]
  [[ "$output" = *"WARN"* ]]
  [[ "$output" = *"vector.json"* ]]
}

@test "enable: confirms sink registration when path present" {
  unset FILELOGS_SKIP_VECTOR_VERIFY
  export FILELOGS_VECTOR_CONFIG="$BATS_TEST_TMPDIR/vector.json"
  cat > "$FILELOGS_VECTOR_CONFIG" <<'J'
{"sinks":{"docker-sink:myapp":{"type":"file","path":"/var/log/dokku/apps/myapp/%Y-%m-%d.log"}}}
J
  run_subcommand enable myapp
  [ "$status" -eq 0 ]
  [[ "$output" = *"sink registered in vector.json"* ]]
  [[ "$output" != *"WARN"* ]]
}
