#!/usr/bin/env bash
#
# kit template — prime a Go worktree. Copy to bin/prime in the service repo and
# run it after `git clone`, `git worktree add`, or `git pull --rebase`.
#
#   bin/prime            # deps, build, then the full test suite
#   bin/prime --fast     # deps and build only (skips tests)
#
# WHAT IT PROMISES
#   Exit 0: the tree builds and every test passes. Anything else: nonzero, with
#   the failing step named, so a worktree that is not ready never looks ready.
#   `set -euo pipefail` is the whole mechanism — no error handling to forget.
#
# STRICTNESS NOTES
#   - No `mise install` here. The toolchain comes from mise (see mise.toml, the
#     one file that pins versions for both this script and CI). If `go` is not
#     on PATH, this script says so and exits nonzero instead of installing
#     something behind your back.
#   - `go test ./...` runs the whole suite on purpose. A worktree that primes
#     green and fails later in the afternoon is a worktree that lied to you.

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

# Never fails the prime. The toolchain checks below are the gate; a banner must
# not be able to turn a green prime red.
version_of() {
  "$@" --version 2>/dev/null | head -n 1 || true
}

require go
require git

step "go mod download"
go mod download

step "no Go generate line pins a module version"
# A Go service's `//go:generate` must not name a module version (`@v…`),
# because a gate that fetches a module on demand is a gate that cannot run
# where the module cache is cold. See ci.reusable.yml's `no generate version
# pin` step and gateway/tools.go for the pattern. The fix is to declare the
# tool as a dependency (a blank import in tools.go with `//go:build tools`)
# and run it as `go run <module>` with no `@<version>`.
if grep -rn --include='*.go' '^//go:generate.*@v' .; then
  echo "bin/prime: a //go:generate line pins a module version with @v — remove the @<version>" >&2
  echo "  so the tool resolves inside this module rather than in a throwaway one." >&2
  echo "  The version lives once, in go.mod's require (through tools.go)." >&2
  exit 1
fi

step "go build ./..."
go build ./...

if [ "$FAST" -eq 1 ]; then
  step "skipping tests (--fast)"
  exit 0
fi

# -count=1 defeats the test cache: a prime must prove the tests run now, not
# that they ran at some point today.
#
# -p 4 bounds how many package binaries run at once. It is here for the same
# reason -count=1 is, and it is fleet-wide rather than per-service: this
# template is what every new Go service copies, so a hole in it is inherited
# by everything that adopts it afterwards.
#
# The arithmetic is the cluster's, not a preference. The per-role CONNECTION
# LIMIT is a service's share of the one shared cluster (10-cluster.sh:268), and
# pgxpool's MaxConns is 8 (templates/database/go/database.go.snippet). So two
# concurrent test binaries can already breach the default cap of 10, and
# `go test ./...` runs one binary per CPU — every service that adopts this
# template with more than a couple of database-backed packages will hit it.
# Measured on identity (24 packages, limit 50, pool 8): an unbounded run failed
# with `FATAL: too many connections for role "identity"` (SQLSTATE 53300) on one
# invocation and passed on the next, with no code change in between.
#
# Raising the cap to fit a parallel run would spend a shared resource to buy
# local speed: that limit is the mechanism that stops one service's runaway
# pool from starving the other eight. Bounding the test run respects it.
# Measured on identity, all 24 packages against the real database:
#
#     -p 1 (fully serial)  114s
#     -p 4 (this)           57s
#     unbounded             46s   <- and intermittently 53300
#
# A service whose own role limit is much larger than the default may raise this;
# it is a ceiling, not a constant.
step "go test ./..."
go test -count=1 -p 4 ./...

step "go vet ./..."
go vet ./...

version="$(version_of go)"
step "prime ok (go ${version:-unknown})"
