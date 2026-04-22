#!/usr/bin/env bash
# CI bootstrap: install bats + shellcheck if missing.
set -eo pipefail

if ! command -v bats >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y bats shellcheck
  elif command -v brew >/dev/null 2>&1; then
    brew install bats-core shellcheck
  else
    echo "install bats + shellcheck manually" >&2
    exit 1
  fi
fi
