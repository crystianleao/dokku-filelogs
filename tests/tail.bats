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

@test "tail: plain render extracts timestamp + container + message from JSON" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  local f
  f="$FILELOGS_LOG_ROOT/myapp/$(filelogs_today).log"
  cat > "$f" <<'JSON'
{"timestamp":"2026-04-25T03:08:50.770Z","message":"GET /users","container_name":"myapp.web.1"}
JSON

  run_subcommand tail myapp
  [ "$status" -eq 0 ]
  [[ "$output" = *"2026-04-25T03:08:50.770Z"* ]]
  [[ "$output" = *"[myapp.web.1]"* ]]
  [[ "$output" = *"GET /users"* ]]
  # No raw JSON braces in default output.
  [[ "$output" != *"\"timestamp\""* ]]
}

@test "tail: --raw keeps JSON intact" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  local f
  f="$FILELOGS_LOG_ROOT/myapp/$(filelogs_today).log"
  echo '{"timestamp":"2026-04-25T03:00:00Z","message":"raw","container_name":"myapp.web.1"}' > "$f"

  run_subcommand tail myapp --raw
  [ "$status" -eq 0 ]
  [[ "$output" = *"\"timestamp\""* ]]
  [[ "$output" = *"\"message\":\"raw\""* ]]
}

@test "tail: plain render passes through non-JSON lines unchanged" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  local f
  f="$FILELOGS_LOG_ROOT/myapp/$(filelogs_today).log"
  printf 'plain-line-1\nplain-line-2\n' > "$f"

  run_subcommand tail myapp
  [ "$status" -eq 0 ]
  [[ "$output" = *"plain-line-1"* ]]
  [[ "$output" = *"plain-line-2"* ]]
}

@test "tail: plain render handles JSON with missing fields" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  local f
  f="$FILELOGS_LOG_ROOT/myapp/$(filelogs_today).log"
  cat > "$f" <<'JSON'
{"message":"no-timestamp-here"}
{"timestamp":"2026-04-25T03:00:00Z","message":"no-container"}
JSON

  run_subcommand tail myapp
  [ "$status" -eq 0 ]
  [[ "$output" = *"no-timestamp-here"* ]]
  [[ "$output" = *"2026-04-25T03:00:00Z"* ]]
  [[ "$output" = *"no-container"* ]]
}

@test "tail: plain render survives mixed JSON + plain" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  local f
  f="$FILELOGS_LOG_ROOT/myapp/$(filelogs_today).log"
  cat > "$f" <<'EOF'
not-json-here
{"timestamp":"2026-04-25T03:00:00Z","message":"json-msg","container_name":"web.1"}
also-plain
EOF

  run_subcommand tail myapp
  [ "$status" -eq 0 ]
  [[ "$output" = *"not-json-here"* ]]
  [[ "$output" = *"json-msg"* ]]
  [[ "$output" = *"also-plain"* ]]
}

@test "tail: format_line_plain function passes through when stdin is empty" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  run bash -c 'source "$0/config" && source "$0/functions" && : | filelogs_format_line_plain' "$PLUGIN_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
