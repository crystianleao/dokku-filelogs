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
