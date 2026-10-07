#!/usr/bin/env bash
#
# focused_publish.sh — the publish focused proof: family syntax + the gate's
# exact chart-publish check + disclosure.
#
#   bash tests/focused_publish.sh
#
# WHAT IT RUNS.
#   1. templates/publish/publish.yml parses as YAML (the gate's artifact-parse
#      loop reports `yaml.safe_load_all` for it; same assertion, scoped to the
#      one file). Needs a YAML parser: the gate's venv python when present,
#      else system python3 with PyYAML, else a loud SKIP — never a silent pass.
#   2. `bash tests/validate.sh --only="chart publish"`: the gate's EXISTING
#      chart-publish proof, unmodified — workflow_call shape, push default,
#      registry agreement with every service Application, name/version not
#      inputs, pull_request refused. The --only banner inside that run names
#      the filter, so the narrowed scope is disclosed by the gate itself.
#
# WHAT IT DOES NOT RUN. Everything else in tests/validate.sh: tier, telemetry,
# observability, lint, tenancy, substrate, obs chart sources. The tail of this
# script says so by name. The full proof is `bash tests/validate.sh` with no
# flags.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/templates/publish/publish.yml"

pass=0
fail=0
skip=0

if [ -f "$F" ]; then
  PY=""
  if [ -x "$ROOT/.venv/bin/python" ] && "$ROOT/.venv/bin/python" -c "import yaml" 2>/dev/null; then
    PY="$ROOT/.venv/bin/python"
  elif python3 -c "import yaml" 2>/dev/null; then
    PY="python3"
  fi
  if [ -n "$PY" ]; then
    if "$PY" -c 'import sys, yaml; list(yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")))' "$F"; then
      printf 'PASS templates/publish/publish.yml  (yaml.safe_load_all)\n'
      pass=$((pass + 1))
    else
      printf 'FAIL templates/publish/publish.yml  (yaml.safe_load_all)\n'
      fail=$((fail + 1))
    fi
  else
    printf 'SKIP templates/publish/publish.yml  (no YAML parser: gate venv and system PyYAML both absent)\n'
    skip=$((skip + 1))
  fi
else
  printf 'FAIL templates/publish/publish.yml  (missing)\n'
  fail=$((fail + 1))
fi

if [ "$fail" -ne 0 ]; then
  printf 'FOCUSED=publish  pass=%d fail=%d skip=%d (syntax failed; chart-publish check not reached)\n' "$pass" "$fail" "$skip"
  exit 1
fi

bash "$ROOT/tests/validate.sh" --only="chart publish"
rc=$?
if [ "$rc" -ne 0 ]; then
  printf 'FOCUSED=publish  chart-publish check FAILED (exit %d)\n' "$rc"
  exit "$rc"
fi

printf 'FOCUSED=publish  pass=%d skip=%d + chart publish check passed\n' "$pass" "$skip"
printf 'NOT RUN: tier, telemetry, observability, lint, tenancy, substrate, obs chart sources, and every other check — focused publish proof only, not a platform-test pass. Full proof: bash tests/validate.sh\n'
exit 0
