#!/usr/bin/env bats

load test_helper

setup() {
  setup_plugin_env
  # Speed up compression grace in tests.
  export FILELOGS_GC_GRACE_MINUTES=0
  # Disable disk-pressure watchdog by default so real-host free% doesn't
  # interfere with retention/cap-specific tests. Pressure tests opt in
  # by re-setting FILELOGS_FAKE_FREE_PERCENT inside the test body.
  export FILELOGS_FAKE_FREE_PERCENT=100
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

@test "gc: disk pressure trims rotated files when free% below threshold" {
  filelogs_set_value --global min-free-disk-percent 50
  filelogs_set_value --global retention-days 3650
  filelogs_set_value --global max-total-bytes 100G
  filelogs_set_value --global max-app-bytes 100G

  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  for i in 1 2 3; do
    local f="$FILELOGS_LOG_ROOT/myapp/2024-01-0$i.log.gz"
    echo "data" > "$f"
    touch_days_ago "$f" "$((10 - i))"
  done

  # Stub df-backed helper: pretend disk is full.
  export FILELOGS_FAKE_FREE_PERCENT=0

  run "$PLUGIN_ROOT/gc/gc.sh"
  [ "$status" -eq 0 ]

  # All rotated files should be gone (loop drains until nothing left).
  local remaining
  remaining=$(find "$FILELOGS_LOG_ROOT/myapp" -type f | wc -l | tr -d ' ')
  [ "$remaining" = "0" ]

  # Stderr should announce pressure.
  [[ "$output" = *"disk pressure"* ]]
}

@test "gc: disk pressure spares today's open log" {
  filelogs_set_value --global min-free-disk-percent 50

  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  local today
  today="$FILELOGS_LOG_ROOT/myapp/$(filelogs_today).log"
  echo "current" > "$today"

  export FILELOGS_FAKE_FREE_PERCENT=0

  run "$PLUGIN_ROOT/gc/gc.sh"
  [ "$status" -eq 0 ]
  [ -f "$today" ]
}

@test "gc: disk pressure no-op when threshold met" {
  filelogs_set_value --global min-free-disk-percent 5

  mkdir -p "$FILELOGS_LOG_ROOT/myapp"
  local old="$FILELOGS_LOG_ROOT/myapp/2024-01-01.log.gz"
  echo "keep" > "$old"
  touch_days_ago "$old" 2
  filelogs_set_value --global retention-days 3650

  export FILELOGS_FAKE_FREE_PERCENT=90

  run "$PLUGIN_ROOT/gc/gc.sh"
  [ "$status" -eq 0 ]
  [ -f "$old" ]
  [[ "$output" != *"disk pressure"* ]]
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

@test "gc: size-trigger warns when current log exceeds cap" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp" "$FILELOGS_CONFIG_ROOT/apps/myapp"
  filelogs_set_value myapp max-current-log-bytes 1K
  filelogs_set_value myapp retention-days 3650

  local today
  today="$FILELOGS_LOG_ROOT/myapp/$(filelogs_today).log"
  dd if=/dev/zero of="$today" bs=1024 count=4 >/dev/null 2>&1

  run "$PLUGIN_ROOT/gc/gc.sh"
  [ "$status" -eq 0 ]
  [[ "$output" = *"exceeds cap"* ]]
  [ -f "$today" ]
}

@test "gc: size-trigger does not downgrade without flag" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp" "$FILELOGS_CONFIG_ROOT/apps/myapp"
  echo 1 > "$FILELOGS_CONFIG_ROOT/apps/myapp/enabled"
  filelogs_set_value myapp rotation daily
  filelogs_set_value myapp max-current-log-bytes 1K
  filelogs_set_value myapp retention-days 3650

  local today
  today="$FILELOGS_LOG_ROOT/myapp/$(filelogs_today).log"
  dd if=/dev/zero of="$today" bs=1024 count=4 >/dev/null 2>&1

  run "$PLUGIN_ROOT/gc/gc.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$FILELOGS_CONFIG_ROOT/apps/myapp/rotation")" = "daily" ]
}

@test "gc: size-trigger downgrades daily->hourly when flag enabled" {
  mkdir -p "$FILELOGS_LOG_ROOT/myapp" "$FILELOGS_CONFIG_ROOT/apps/myapp"
  echo 1 > "$FILELOGS_CONFIG_ROOT/apps/myapp/enabled"
  filelogs_set_value --global pressure-auto-downgrade true
  filelogs_set_value myapp rotation daily
  filelogs_set_value myapp max-current-log-bytes 1K
  filelogs_set_value myapp retention-days 3650

  local today
  today="$FILELOGS_LOG_ROOT/myapp/$(filelogs_today).log"
  dd if=/dev/zero of="$today" bs=1024 count=4 >/dev/null 2>&1

  run "$PLUGIN_ROOT/gc/gc.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$FILELOGS_CONFIG_ROOT/apps/myapp/rotation")" = "hourly" ]
  assert_dokku_called_with "logs:set myapp vector-sink"
}

@test "gc: watchdog downgrades daily apps when pressure persists and flag set" {
  filelogs_set_value --global min-free-disk-percent 50
  filelogs_set_value --global max-total-bytes 100G
  filelogs_set_value --global max-app-bytes 100G
  filelogs_set_value --global retention-days 3650
  filelogs_set_value --global pressure-auto-downgrade true

  mkdir -p "$FILELOGS_LOG_ROOT/myapp" "$FILELOGS_CONFIG_ROOT/apps/myapp"
  echo 1 > "$FILELOGS_CONFIG_ROOT/apps/myapp/enabled"
  filelogs_set_value myapp rotation daily
  # Big enough to not re-trigger size-trigger (cap is the 500M default).
  filelogs_set_value myapp max-current-log-bytes 10G

  # Today's open file is tiny — force pressure purely via fake free%.
  local today
  today="$FILELOGS_LOG_ROOT/myapp/$(filelogs_today).log"
  echo "x" > "$today"

  export FILELOGS_FAKE_FREE_PERCENT=0

  run "$PLUGIN_ROOT/gc/gc.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$FILELOGS_CONFIG_ROOT/apps/myapp/rotation")" = "hourly" ]
  [[ "$output" = *"pressure persists"* ]]
}

@test "gc: watchdog does not downgrade without pressure-auto-downgrade flag" {
  filelogs_set_value --global min-free-disk-percent 50
  filelogs_set_value --global max-total-bytes 100G
  filelogs_set_value --global max-app-bytes 100G
  filelogs_set_value --global retention-days 3650

  mkdir -p "$FILELOGS_LOG_ROOT/myapp" "$FILELOGS_CONFIG_ROOT/apps/myapp"
  echo 1 > "$FILELOGS_CONFIG_ROOT/apps/myapp/enabled"
  filelogs_set_value myapp rotation daily
  filelogs_set_value myapp max-current-log-bytes 10G

  local today
  today="$FILELOGS_LOG_ROOT/myapp/$(filelogs_today).log"
  echo "x" > "$today"

  export FILELOGS_FAKE_FREE_PERCENT=0

  run "$PLUGIN_ROOT/gc/gc.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$FILELOGS_CONFIG_ROOT/apps/myapp/rotation")" = "daily" ]
  [[ "$output" != *"pressure persists"* ]]
}
