#!/usr/bin/env bats

load test_helper

setup() {
  setup_plugin_env
  source_plugin
}

@test "post-delete: removes app log and config dirs" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp" "$FILELOGS_CONFIG_ROOT/apps/myapp"
  echo "x" > "$FILELOGS_LOG_ROOT/myapp/data.log"
  echo 1 > "$FILELOGS_CONFIG_ROOT/apps/myapp/enabled"

  run_trigger post-delete myapp
  [ "$status" -eq 0 ]
  [ ! -d "$FILELOGS_LOG_ROOT/myapp" ]
  [ ! -d "$FILELOGS_CONFIG_ROOT/apps/myapp" ]
}

@test "post-delete: no-op on empty arg" {
  run_trigger post-delete
  [ "$status" -eq 0 ]
}

@test "post-app-create: auto-enable=true runs enable" {
  filelogs_set_value --global auto-enable true

  run_trigger post-app-create newapp
  [ "$status" -eq 0 ]
  assert_dokku_called_with "logs:set newapp vector-sink"
  [ -f "$FILELOGS_CONFIG_ROOT/apps/newapp/enabled" ]
}

@test "post-app-create: auto-enable=false does not run enable" {
  run_trigger post-app-create newapp
  [ "$status" -eq 0 ]
  refute_dokku_called
  [ ! -f "$FILELOGS_CONFIG_ROOT/apps/newapp/enabled" ]
}

@test "post-app-rename: moves log and config dirs" {
  mkdir -p "$FILELOGS_LOG_ROOT/old" "$FILELOGS_CONFIG_ROOT/apps/old"
  echo "x" > "$FILELOGS_LOG_ROOT/old/file.log"
  echo 7 > "$FILELOGS_CONFIG_ROOT/apps/old/retention-days"

  run_trigger post-app-rename old new
  [ "$status" -eq 0 ]
  [ -f "$FILELOGS_LOG_ROOT/new/file.log" ]
  [ "$(cat "$FILELOGS_CONFIG_ROOT/apps/new/retention-days")" = "7" ]
  [ ! -d "$FILELOGS_LOG_ROOT/old" ]
}

@test "post-app-rename: re-issues logs:set when new app is enabled" {
  mkdir -p "$FILELOGS_CONFIG_ROOT/apps/old"
  echo 1 > "$FILELOGS_CONFIG_ROOT/apps/old/enabled"

  run_trigger post-app-rename old new
  [ "$status" -eq 0 ]
  assert_dokku_called_with "logs:set new vector-sink"
}
