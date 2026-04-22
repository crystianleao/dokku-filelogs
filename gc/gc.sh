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
  local dir="$1" today_name="$2" hour_name="$3" compress="$4"
  [[ "$compress" != "true" ]] && return 0

  find "$dir" -maxdepth 1 -type f -name "*.log" \
    ! -name "$today_name" ! -name "$hour_name" \
    -mmin +"$GRACE_MINUTES" -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        gzip -q -- "$f" || true
      done
}

gc_apply_retention() {
  local dir="$1" today_name="$2" hour_name="$3" retention="$4"

  # Older than retention: delete both .log and .log.gz, skip today.
  find "$dir" -maxdepth 1 -type f \
    \( -name "*.log" -o -name "*.log.gz" \) \
    ! -name "$today_name" ! -name "$hour_name" \
    -mtime +"$retention" -delete 2>/dev/null || true
}

# Delete oldest rotated files until $1 (dir) is <= $2 (max bytes).
# Never deletes today's open file.
gc_enforce_cap() {
  local dir="$1" max_bytes="$2" today_name="$3" hour_name="$4"
  local total

  total=$(filelogs_dir_bytes "$dir")
  while [[ -n "$total" ]] && (( total > max_bytes )); do
    local oldest
    oldest=$(filelogs_oldest_file "$dir" \
               \( -name "*.log.gz" -o -name "*.log" \) \
               ! -name "$today_name" ! -name "$hour_name")

    [[ -z "$oldest" ]] && break
    rm -f -- "$oldest"
    total=$(filelogs_dir_bytes "$dir")
  done
}

gc_app() {
  local app="$1"
  local dir="$FILELOGS_LOG_ROOT/$app"
  [[ -d "$dir" ]] || return 0

  # Protect both possible "current" names regardless of the app's
  # rotation setting. Cheaper than reading per-app config and works
  # uniformly for apps mid-rotation-switch.
  local today_name hour_name
  today_name="$(filelogs_today).log"
  hour_name="$(filelogs_current_hour).log"

  local retention compress max_bytes
  retention=$(filelogs_get_value "$app" retention-days)
  compress=$(filelogs_get_value "$app" compress)
  max_bytes=$(filelogs_human_to_bytes "$(filelogs_get_value "$app" max-app-bytes)")

  gc_compress_old_logs "$dir" "$today_name" "$hour_name" "$compress"
  gc_apply_retention "$dir" "$today_name" "$hour_name" "$retention"
  gc_enforce_cap "$dir" "$max_bytes" "$today_name" "$hour_name"
}

gc_global() {
  local max_total total
  max_total=$(filelogs_human_to_bytes "$(filelogs_get_value --global max-total-bytes)")
  total=$(filelogs_dir_bytes "$FILELOGS_LOG_ROOT")

  local today_name hour_name
  today_name="$(filelogs_today).log"
  hour_name="$(filelogs_current_hour).log"

  while [[ -n "$total" ]] && (( total > max_total )); do
    local oldest
    oldest=$(filelogs_oldest_file_recursive "$FILELOGS_LOG_ROOT" \
               \( -name "*.log.gz" -o -name "*.log" \) \
               ! -name "$today_name" ! -name "$hour_name")

    [[ -z "$oldest" ]] && break

    rm -f -- "$oldest"
    total=$(filelogs_dir_bytes "$FILELOGS_LOG_ROOT")
  done
}

# Disk-pressure watchdog. Runs last so it catches any shortfall left
# after retention + per-app + global caps. Trims oldest rotated files
# (never today's open .log) until free% >= threshold or nothing left.
gc_disk_pressure() {
  local threshold
  threshold=$(filelogs_get_value --global min-free-disk-percent)

  local free_pct
  free_pct=$(filelogs_free_percent "$FILELOGS_LOG_ROOT")

  [[ -z "$threshold" || "$threshold" -eq 0 ]] && return 0
  (( free_pct >= threshold )) && return 0

  echo "filelogs: disk pressure free=${free_pct}% threshold=${threshold}% — trimming" >&2

  local today_name hour_name
  today_name="$(filelogs_today).log"
  hour_name="$(filelogs_current_hour).log"

  while (( free_pct < threshold )); do
    local oldest
    oldest=$(filelogs_oldest_file_recursive "$FILELOGS_LOG_ROOT" \
               \( -name "*.log.gz" -o -name "*.log" \) \
               ! -name "$today_name" ! -name "$hour_name")
    [[ -z "$oldest" ]] && break
    rm -f -- "$oldest"
    free_pct=$(filelogs_free_percent "$FILELOGS_LOG_ROOT")
  done

  echo "filelogs: disk pressure post-trim free=${free_pct}%" >&2
}

main() {
  [[ -d "$FILELOGS_LOG_ROOT" ]] || exit 0

  local d
  for d in "$FILELOGS_LOG_ROOT"/*/; do
    [[ -d "$d" ]] || continue
    gc_app "$(basename "$d")"
  done

  gc_global
  gc_disk_pressure
}

main "$@"
