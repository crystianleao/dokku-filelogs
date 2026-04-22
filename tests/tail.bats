#!/usr/bin/env bats

load test_helper

setup() {
  setup_plugin_env
  source_plugin
}

@test "tail: reads today's log" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  local f
  f="$FILELOGS_LOG_ROOT/myapp/$(filelogs_today).log"
  printf 'line-a\nline-b\nline-c\n' > "$f"

  run_subcommand tail myapp --lines 2
  [ "$status" -eq 0 ]
  [[ "$output" = *"line-b"* ]]
  [[ "$output" = *"line-c"* ]]
}

@test "tail: reads compressed .log.gz for a given --date" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  printf 'gz-a\ngz-b\n' | gzip -c > "$FILELOGS_LOG_ROOT/myapp/2024-06-01.log.gz"

  run_subcommand tail myapp --date 2024-06-01
  [ "$status" -eq 0 ]
  [[ "$output" = *"gz-a"* ]]
  [[ "$output" = *"gz-b"* ]]
}

@test "tail: missing file errors" {
  run_subcommand tail nowhere
  [ "$status" -ne 0 ]
  [[ "$output" = *"no logs"* ]]
}

@test "tail: missing app arg errors" {
  run_subcommand tail
  [ "$status" -ne 0 ]
}

@test "tail: --lines=N form works" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  local f
  f="$FILELOGS_LOG_ROOT/myapp/$(filelogs_today).log"
  for i in 1 2 3 4 5; do echo "line$i"; done > "$f"

  run_subcommand tail myapp --lines=2
  [ "$status" -eq 0 ]
  [[ "$output" = *"line4"* ]]
  [[ "$output" = *"line5"* ]]
}

@test "tail: --date YYYY-MM-DD concatenates all hourly files of that day" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  echo "hour00" > "$FILELOGS_LOG_ROOT/myapp/2024-06-01T00.log"
  echo "hour01" > "$FILELOGS_LOG_ROOT/myapp/2024-06-01T01.log"
  printf 'hour02-a\nhour02-b\n' | gzip -c > "$FILELOGS_LOG_ROOT/myapp/2024-06-01T02.log.gz"

  run_subcommand tail myapp --date 2024-06-01 --lines 10
  [ "$status" -eq 0 ]
  [[ "$output" = *"hour00"* ]]
  [[ "$output" = *"hour01"* ]]
  [[ "$output" = *"hour02-a"* ]]
  [[ "$output" = *"hour02-b"* ]]
}

@test "tail: --at YYYY-MM-DDTHH reads just that hour" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  echo "hour05-data" > "$FILELOGS_LOG_ROOT/myapp/2024-06-01T05.log"
  echo "hour06-data" > "$FILELOGS_LOG_ROOT/myapp/2024-06-01T06.log"

  run_subcommand tail myapp --at 2024-06-01T05
  [ "$status" -eq 0 ]
  [[ "$output" = *"hour05-data"* ]]
  [[ "$output" != *"hour06-data"* ]]
}

@test "tail: invalid --date format rejected" {
  run_subcommand tail myapp --date "yesterday"
  [ "$status" -ne 0 ]
}

@test "tail: hourly rotation default reads current hour file" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  filelogs_set_value myapp rotation hourly
  local f
  f="$FILELOGS_LOG_ROOT/myapp/$(filelogs_current_hour).log"
  echo "hourly-current" > "$f"

  run_subcommand tail myapp
  [ "$status" -eq 0 ]
  [[ "$output" = *"hourly-current"* ]]
}
