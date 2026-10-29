#!/usr/bin/env bash

set -euo pipefail

FAST=0
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=1 ;;
    -h | --help)
      sed -n '2,22p' "$0"
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

require bun

step "bun install --frozen-lockfile"
bun install --frozen-lockfile

if [ "$FAST" -eq 1 ]; then
  step "skipping typecheck and tests (--fast)"
  exit 0
fi

if bun -e 'process.exit(require("./package.json").scripts?.typecheck ? 0 : 1)' \
  >/dev/null 2>&1; then
  step "bun run typecheck"
  bun run typecheck
else
  echo "bin/prime: no 'typecheck' script in package.json — skipping typecheck" >&2
fi

step "bun test"
bun test

version="$(version_of bun)"
step "prime ok (bun ${version:-unknown})"
