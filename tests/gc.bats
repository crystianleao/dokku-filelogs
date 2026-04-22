#!/usr/bin/env bats

load test_helper

setup() {
  setup_plugin_env
  # Speed up compression grace in tests.
  export FILELOGS_GC_GRACE_MINUTES=0
  source_plugin
}

today_log() { echo "$FILELOGS_LOG_ROOT/$1/$(filelogs_today).log"; }

@test "gc: compresses yesterday's .log" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  local old="$FILELOGS_LOG_ROOT/myapp/2024-01-01.log"
  echo "old data" > "$old"
  touch_days_ago "$old" 2

  run "$PLUGIN_ROOT/gc/gc.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$old" ]
  [ -f "$old.gz" ]
}

@test "gc: does not touch today's open log" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  local today
  today=$(today_log myapp)
  echo "current" > "$today"

  run "$PLUGIN_ROOT/gc/gc.sh"
  [ "$status" -eq 0 ]
  [ -f "$today" ]
  [ ! -f "$today.gz" ]
}

@test "gc: retention deletes files older than retention-days" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  filelogs_set_value myapp retention-days 3

  local ancient="$FILELOGS_LOG_ROOT/myapp/2020-01-01.log.gz"
  echo "x" > "$ancient"
  touch_days_ago "$ancient" 10

  run "$PLUGIN_ROOT/gc/gc.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$ancient" ]
}

@test "gc: enforces per-app max-app-bytes by deleting oldest first" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  filelogs_set_value myapp max-app-bytes 10K
  filelogs_set_value myapp retention-days 3650   # avoid retention killing them

  # Create 3 x 8K files; total 24K > 10K cap.
  for i in 1 2 3; do
    local f="$FILELOGS_LOG_ROOT/myapp/2024-01-0$i.log.gz"
    dd if=/dev/zero of="$f" bs=1024 count=8 >/dev/null 2>&1
    touch_days_ago "$f" "$((10 - i))"
  done

  run "$PLUGIN_ROOT/gc/gc.sh"
  [ "$status" -eq 0 ]

  # Oldest (01) should be gone; some newer remain.
  [ ! -f "$FILELOGS_LOG_ROOT/myapp/2024-01-01.log.gz" ]
  local remaining
  remaining=$(find "$FILELOGS_LOG_ROOT/myapp" -type f | wc -l)
  [ "$remaining" -lt 3 ]
}

@test "gc: enforces global max-total-bytes" {
  filelogs_set_value --global max-total-bytes 10K
  filelogs_set_value --global retention-days 3650

  for app in a b; do
    mkdir -p "$FILELOGS_LOG_ROOT/$app"
    local f="$FILELOGS_LOG_ROOT/$app/2024-01-01.log.gz"
    dd if=/dev/zero of="$f" bs=1024 count=8 >/dev/null 2>&1
    touch_days_ago "$f" 5
  done

  run "$PLUGIN_ROOT/gc/gc.sh"
  [ "$status" -eq 0 ]

  # Total should drop under cap; at least one of the two was deleted.
  local total
  total=$(filelogs_dir_bytes "$FILELOGS_LOG_ROOT")
  [ "$total" -le 10240 ]
}

@test "gc: empty log root exits cleanly" {
  run "$PLUGIN_ROOT/gc/gc.sh"
  [ "$status" -eq 0 ]
}

@test "gc: compress=false keeps .log uncompressed" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  filelogs_set_value myapp compress false

  local old="$FILELOGS_LOG_ROOT/myapp/2024-01-01.log"
  echo "x" > "$old"
  touch_days_ago "$old" 2

  run "$PLUGIN_ROOT/gc/gc.sh"
  [ "$status" -eq 0 ]
  [ -f "$old" ]
  [ ! -f "$old.gz" ]
}
