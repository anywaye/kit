#!/usr/bin/env bash
#
# route_test.sh — the route proof. Synthetic argv in, ROUTE= lines out.
#
#   bash tests/route_test.sh
#
# WHAT IT PROVES. Every routing class the packet names, against tests/route.sh
# directly: docs-only, tier-only, publish-only, platform, unknown, empty, mixed
# families, and the non-PR events (push, schedule, workflow_dispatch) that must
# always take full. Pure bash, stdlib only, no venv, no network, no fixtures.
#
# WHAT IT NEVER DOES. It never invokes tests/validate.sh — the recursion this
# packet forbids (a classifier calling its own full gate from a static test).
# Case 00 greps for that and fails if it ever appears.

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

# 00. The recursion guard: the router must never launch the full gate. Comment
# lines are prose; only executable lines count.
if grep -v '^[[:space:]]*#' "$ROUTE" | grep -q "validate\.sh"; then
  printf 'FAIL: route.sh names validate.sh — the router must never launch the gate\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# 01-03. Prose/docs-only takes docs.
expect docs -- README.md CHANGELOG.md DECISIONS.md
expect docs -- LICENSE docs/guide.md templates/otel/README.md
expect docs -- REPORT-kit-04-secrets.md

# 04-05. A family prefix wins over a prose suffix: still the family.
expect tier -- templates/tier/go/tier.go templates/tier/README.md
expect tier -- templates/tier/ruby/tier.rb

# 06. Publish family.
expect publish -- templates/publish/publish.yml

# 07-09. Platform/runtime artifacts, workflows, tests take full.
expect full -- tests/validate.sh tests/route.sh
expect full -- .github/workflows/ci.yml .github/workflows/ci.reusable.yml
expect full -- templates/substrate/install.sh VERSION core/release/foo.json

# 10. Unknown paths fail closed.
expect full -- frobnicate/zz brand-new-thing

# 11. Empty/uncomputable fails closed.
expect full

# 12-14. Mixed families fail closed: no family proof covers the other.
expect full -- README.md templates/tier/go/tier.go
expect full -- README.md templates/publish/publish.yml
expect full -- templates/tier/go/tier.go templates/publish/publish.yml

# 15-17. Non-PR events always take full, even for docs-only paths.
expect full --event schedule -- README.md CHANGELOG.md
expect full --event workflow_dispatch -- README.md
expect full --event push -- README.md CHANGELOG.md

# 18. Unknown events fail closed too.
expect full --event merge_group -- README.md

printf 'route_test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
