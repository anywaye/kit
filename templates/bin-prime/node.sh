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

require node
require npm

step "npm ci"
npm ci

if [ "$FAST" -eq 1 ]; then
  step "skipping lint and tests (--fast)"
  exit 0
fi

if node -e 'process.exit(require("./package.json").scripts?.lint ? 0 : 1)' \
  >/dev/null 2>&1; then
  step "npm run lint"
  npm run lint
else
  echo "bin/prime: no 'lint' script in package.json — skipping lint" >&2
fi

step "npm test"
npm test

version="$(version_of node)"
step "prime ok (node ${version:-unknown})"