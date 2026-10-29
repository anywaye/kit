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

require mix

step "mix deps.get"
mix deps.get

step "mix compile"
mix compile

if [ "$FAST" -eq 1 ]; then
  step "skipping format check and tests (--fast)"
  exit 0
fi

if [ -f .formatter.exs ]; then
  step "mix format --check-formatted"
  mix format --check-formatted
else
  echo "bin/prime: no .formatter.exs — skipping the format check" >&2
fi

step "mix test"
mix test

version="$(version_of mix)"
step "prime ok (elixir ${version:-unknown})"
