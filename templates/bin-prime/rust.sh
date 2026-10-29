#!/usr/bin/env bash

set -euo pipefail

FAST=0
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=1 ;;
    -h | --help)
      sed -n '2,23p' "$0"
      exit 0
      ;;
    *)
      echo "bin/prime: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "bin/prime: $1 not found on PATH — run 'mise install' in this worktree" >&2
    exit 127
  fi
}

step() {
  printf '\n== %s\n' "$1"
}

version_of() {
  "$@" --version 2>/dev/null | head -n 1 || true
}

require cargo

step "cargo fetch"
cargo fetch

if [ "$FAST" -eq 1 ]; then
  step "skipping fmt, clippy, and tests (--fast)"
  exit 0
fi

step "cargo fmt --check"
cargo fmt --check

step "cargo clippy"
cargo clippy --all-targets -- -D warnings

step "cargo test"
cargo test

version="$(version_of cargo)"
step "prime ok (cargo ${version:-unknown})"