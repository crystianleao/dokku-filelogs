#!/usr/bin/env bats

load test_helper

setup() {
  setup_plugin_env
  source_plugin
  # Default to absent timer so tests don't depend on host systemd.
  export FILELOGS_FAKE_TIMER_ACTIVE=false
  # Point the helpers at a per-test vector.json.
  export FILELOGS_VECTOR_CONFIG="$BATS_TEST_TMPDIR/vector.json"
}

write_vector_json() {
  # Usage: write_vector_json <app> <path-or-empty>
  local app="$1" path="$2"
  if [[ -n "$path" ]]; then
    cat > "$FILELOGS_VECTOR_CONFIG" <<JSON
{
  "sources": {"docker-source:$app": {"type": "docker_logs"}},
  "sinks": {
    "docker-sink:$app": {
      "type": "file",
      "path": "$path",
      "encoding": {"codec": "json"},
      "inputs": ["docker-source:$app"]
    }
  }
}
JSON
  else
    cat > "$FILELOGS_VECTOR_CONFIG" <<JSON
{
  "sources": {"docker-source:$app": {"type": "docker_logs"}},
  "sinks": {
    "docker-sink:$app": {
      "type": "file",
      "encoding": {"codec": "json"},
      "inputs": ["docker-source:$app"]
    }
  }
}
JSON
  fi
}

@test "doctor: vector running + config present is OK (no app)" {
  export FILELOGS_FAKE_VECTOR_STATUS=running
  : > "$FILELOGS_VECTOR_CONFIG"
  run_subcommand doctor
  [ "$status" -eq 0 ]
  [[ "$output" = *"[OK]"*"vector container running"* ]]
  [[ "$output" = *"[OK]"*"vector config present"* ]]
  [[ "$output" = *"0 failures"* ]]
}

@test "doctor: vector restarting fails loud" {
  export FILELOGS_FAKE_VECTOR_STATUS=restarting
  : > "$FILELOGS_VECTOR_CONFIG"
  run_subcommand doctor
  [ "$status" -ne 0 ]
  [[ "$output" = *"[FAIL]"*"restarting"* ]]
}

@test "doctor: vector missing is a warning, not a failure" {
  export FILELOGS_FAKE_VECTOR_STATUS=missing
  rm -f "$FILELOGS_VECTOR_CONFIG"
  run_subcommand doctor
  [ "$status" -eq 0 ]
  [[ "$output" = *"[WARN]"*"vector container not found"* ]]
}

@test "doctor: per-app sink with path is OK" {
  export FILELOGS_FAKE_VECTOR_STATUS=running
  mkdir -p "$FILELOGS_CONFIG_ROOT/apps/myapp" "$FILELOGS_LOG_ROOT/myapp"
  echo 1 > "$FILELOGS_CONFIG_ROOT/apps/myapp/enabled"
  write_vector_json myapp "/var/log/dokku/apps/myapp/%Y-%m-%d.log"
  run_subcommand doctor myapp
  [ "$status" -eq 0 ]
  [[ "$output" = *"myapp is filelogs-enabled"* ]]
  [[ "$output" = *"sink registered in vector.json"* ]]
  [[ "$output" = *"log dir present"* ]]
}

@test "doctor: per-app sink missing path is a FAIL" {
  export FILELOGS_FAKE_VECTOR_STATUS=running
  mkdir -p "$FILELOGS_CONFIG_ROOT/apps/myapp"
  echo 1 > "$FILELOGS_CONFIG_ROOT/apps/myapp/enabled"
  write_vector_json myapp ""
  run_subcommand doctor myapp
  [ "$status" -ne 0 ]
  [[ "$output" = *"[FAIL]"*"missing 'path'"* ]]
}

@test "doctor: app not enabled is a FAIL" {
  export FILELOGS_FAKE_VECTOR_STATUS=running
  : > "$FILELOGS_VECTOR_CONFIG"
  run_subcommand doctor myapp
  [ "$status" -ne 0 ]
  [[ "$output" = *"[FAIL]"*"is not enabled"* ]]
}

@test "doctor: GC timer active OK / inactive WARN" {
  export FILELOGS_FAKE_VECTOR_STATUS=running
  : > "$FILELOGS_VECTOR_CONFIG"
  FILELOGS_FAKE_TIMER_ACTIVE=true run_subcommand doctor
  [ "$status" -eq 0 ]
  [[ "$output" = *"[OK]"*"GC timer active"* ]]
  FILELOGS_FAKE_TIMER_ACTIVE=false run_subcommand doctor
  [[ "$output" = *"[WARN]"*"GC timer not active"* ]]
}
