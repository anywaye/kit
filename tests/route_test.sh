#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROUTE="$ROOT/tests/route.sh"

pass=0
fail=0

expect() {
  local want="$1"
  shift
  local got
  got="$("$ROUTE" "$@")"
  if [ "$got" = "ROUTE=$want" ]; then
    pass=$((pass + 1))
  else
    printf 'FAIL: route.sh %s -> %s (want ROUTE=%s)\n' "$*" "$got" "$want" >&2
    fail=$((fail + 1))
  fi
}

if grep -v '^[[:space:]]*#' "$ROUTE" | grep -q "validate\.sh"; then
  printf 'FAIL: route.sh names validate.sh — the router must never launch the gate\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

expect docs -- README.md CHANGELOG.md DECISIONS.md
expect docs -- LICENSE docs/guide.md templates/otel/README.md
expect docs -- REPORT-kit-04-secrets

expect tier -- templates/tier/go/tier.go templates/tier/README.md
expect tier -- templates/tier/ruby/tier.rb

expect publish -- templates/publish/publish.yml

expect full -- tests/validate.sh tests/route.sh
expect full -- ci/ci.yml ci/ci.reusable.yml
expect full -- templates/substrate/install.sh VERSION core/release/foo.json

expect full -- frobnicate/zz brand-new-thing

expect full

expect full -- README.md templates/tier/go/tier.go
expect full -- README.md templates/publish/publish.yml
expect full -- templates/tier/go/tier.go templates/publish/publish.yml

expect full --event schedule -- README.md CHANGELOG.md
expect full --event workflow_dispatch -- README.md
expect full --event push -- README.md CHANGELOG.md

expect full --event merge_group -- README.md

printf 'route_test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
