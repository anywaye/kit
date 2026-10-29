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
  if grep -q 'GOMODCACHE\|go mod download all' bin/prime 2>/dev/null || grep -q 'GOMODCACHE\|go mod download all' ci/ci.yml 2>/dev/null; then
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

step "go test ./..."
go test -count=1 -p 4 ./...

step "go vet ./..."
go vet ./...

version="$(version_of go)"
step "prime ok (go ${version:-unknown})"
