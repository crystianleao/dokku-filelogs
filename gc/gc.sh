#!/usr/bin/env bash
# Garbage-collect filelogs: compress, apply retention, enforce caps.
# Safe to run concurrently with Vector — never touches today's open file.

set -eo pipefail
[[ $DOKKU_TRACE ]] && set -x

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config
source "$PLUGIN_ROOT/config"
# shellcheck source=../functions
source "$PLUGIN_ROOT/functions"

# Minimum mtime age (minutes) before compressing a yesterday-or-older .log
# Ensures Vector has closed its file descriptor for that day.
GRACE_MINUTES="${FILELOGS_GC_GRACE_MINUTES:-120}"

gc_compress_old_logs() {
  local dir="$1" today_name="$2" compress="$3"
  [[ "$compress" != "true" ]] && return 0

  find "$dir" -maxdepth 1 -type f -name "*.log" \
    ! -name "$today_name" -mmin +"$GRACE_MINUTES" -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        gzip -q -- "$f" || true
      done
}

gc_apply_retention() {
  local dir="$1" today_name="$2" retention="$3"

  # Older than retention: delete both .log and .log.gz, skip today.
  find "$dir" -maxdepth 1 -type f \
    \( -name "*.log" -o -name "*.log.gz" \) \
    ! -name "$today_name" \
    -mtime +"$retention" -delete 2>/dev/null || true
}

# Delete oldest rotated files until $1 (dir) is <= $2 (max bytes).
# Never deletes today's open file.
gc_enforce_cap() {
  local dir="$1" max_bytes="$2" today_name="$3"
  local total

  total=$(filelogs_dir_bytes "$dir")
  while [[ -n "$total" ]] && (( total > max_bytes )); do
    local oldest
    oldest=$(filelogs_oldest_file "$dir" \
               \( -name "*.log.gz" -o -name "*.log" \) \
               ! -name "$today_name")

    [[ -z "$oldest" ]] && break
    rm -f -- "$oldest"
    total=$(filelogs_dir_bytes "$dir")
  done
}

gc_app() {
  local app="$1"
  local dir="$FILELOGS_LOG_ROOT/$app"
  [[ -d "$dir" ]] || return 0

  local today_name
  today_name="$(filelogs_today).log"

  local retention compress max_bytes
  retention=$(filelogs_get_value "$app" retention-days)
  compress=$(filelogs_get_value "$app" compress)
  max_bytes=$(filelogs_human_to_bytes "$(filelogs_get_value "$app" max-app-bytes)")

  gc_compress_old_logs "$dir" "$today_name" "$compress"
  gc_apply_retention "$dir" "$today_name" "$retention"
  gc_enforce_cap "$dir" "$max_bytes" "$today_name"
}

gc_global() {
  local max_total total
  max_total=$(filelogs_human_to_bytes "$(filelogs_get_value --global max-total-bytes)")
  total=$(filelogs_dir_bytes "$FILELOGS_LOG_ROOT")

  local today_name
  today_name="$(filelogs_today).log"

  while [[ -n "$total" ]] && (( total > max_total )); do
    local oldest
    oldest=$(filelogs_oldest_file_recursive "$FILELOGS_LOG_ROOT" \
               \( -name "*.log.gz" -o -name "*.log" \) \
               ! -name "$today_name")

    [[ -z "$oldest" ]] && break

    rm -f -- "$oldest"
    total=$(filelogs_dir_bytes "$FILELOGS_LOG_ROOT")
  done
}

main() {
  [[ -d "$FILELOGS_LOG_ROOT" ]] || exit 0

  local d
  for d in "$FILELOGS_LOG_ROOT"/*/; do
    [[ -d "$d" ]] || continue
    gc_app "$(basename "$d")"
  done

  gc_global
}

main "$@"
