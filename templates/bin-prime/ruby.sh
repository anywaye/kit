#!/usr/bin/env bash

set -euo pipefail

FAST=0
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=1 ;;
    -h | --help)
      sed -n '2,20p' "$0"
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

require ruby
require bundle

step "bundle install"
bundle install

if [ "$FAST" -eq 1 ]; then
  step "skipping lint and tests (--fast)"
  exit 0
fi

if bundle exec rubocop --version >/dev/null 2>&1; then
  step "rubocop"
  _rubocop_log="$(mktemp)"
  set +e
  bundle exec rubocop --parallel 2>&1 | tee "$_rubocop_log"
  _rubocop_rc=${PIPESTATUS[0]}
  set -e
  _rubocop_inspected="$(grep -oE '[0-9]+ files? inspected' "$_rubocop_log" | grep -oE '^[0-9]+' | head -n1)"
  rm -f "$_rubocop_log"
  if [ "$_rubocop_rc" -ne 0 ]; then
    exit "$_rubocop_rc"
  fi
  if [ -z "$_rubocop_inspected" ] || [ "$_rubocop_inspected" -eq 0 ]; then
    echo "bin/prime: rubocop inspected 0 files — the lint step is vacuous (check AllCops/Exclude and the working directory)" >&2
    exit 1
  fi
else
  echo "bin/prime: rubocop is not in the bundle — skipping lint (add it to the Gemfile)" >&2
fi

step "bundle exec rake"
bundle exec rake

version="$(version_of ruby)"
step "prime ok (ruby ${version:-unknown})"
