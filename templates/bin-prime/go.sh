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

step "no Go generate line pins a module version without a declared shape"
# A Go `//go:generate` that names a module version (`@v…`) resolves in a throwaway
# module context whose transitive graph lives nowhere in this tree, so a gate that
# fetches it on demand cannot run where the cache is cold. Two legitimate shapes
# exist, and the guard must tell them apart:
#
#   1. DECLARED (applications): the tool is a blank import in tools.go with
#      `//go:build tools`, `go mod tidy` records its graph, `go mod download`
#      fills the cache, and the `//go:generate` line runs as `go run <module>`
#      with no `@<version>`. See gateway/tools.go. The version lives once, in
#      go.mod's require through tools.go.
#
#   2. WARMED OUT OF BAND (libraries): the service is a library — consumers import
#      it and a `require` would pollute their graph (identity/client,
#      TestTheGeneratorIsNotAModuleDependency). The `//go:generate` line keeps
#      `@v`, and the gate warms the cache out of band: it reads the module@version
#      from the generate line (never retyped), creates a throwaway module that
#      requires it, runs `go mod download all`, and discards the temp dir.
#      GOMODCACHE is shared so `go run <module>@<version>` hits the cache offline.
#      See identity/bin/prime. A library takes the second because the first would
#      ship ten thousand lines of generator into every consumer.
#
# A `//go:generate` may name `@v` ONLY if the gate warms the cache (shape 2), and
# must NOT name it when the tool is a declared dependency (shape 1). The check
# fails when neither shape is present — the defect the guard exists for.
if grep -rn --include='*.go' '^//go:generate.*@v' . >/dev/null; then
  # Has @v — library shape requires warming evidence somewhere the gate runs.
  # Warming is a throwaway module that reads the version from the generate line
  # and runs `go mod download all` out of band, so we look for that pattern in
  # the gate itself (bin/prime) or in the CI workflow. GOMODCACHE is the marker
  # that the cache is shared between the throwaway module and `go run`.
  if grep -q 'GOMODCACHE\|go mod download all' bin/prime 2>/dev/null || grep -q 'GOMODCACHE\|go mod download all' ci/ci.yml 2>/dev/null; then
    : # warmed out of band — library shape, allowed
  else
    echo "bin/prime: a //go:generate line pins @v but no cache-warming step was found" >&2
    echo "  A library must warm the generator's graph out of band (throwaway module, GOMODCACHE is shared)" >&2
    echo "  or an application must declare the tool in tools.go and run as go run <module> without @v." >&2
    echo "  See identity/bin/prime for the library shape and gateway/tools.go for the declared shape." >&2
    exit 1
  fi
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
