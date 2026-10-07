#!/usr/bin/env bash
#
# focused_publish.sh — the publish focused proof: family syntax + the
# chart-publish seam check + disclosure.
#
#   bash tests/focused_publish.sh
#
# WHAT IT RUNS.
#   1. templates/publish/publish.yml parses as YAML (the gate's artifact-parse
#      loop reports `yaml.safe_load_all` for it; same assertion, scoped to the
#      one file). Needs a YAML parser: the gate's venv python when present,
#      else system python3 with PyYAML, else a loud SKIP — never a silent pass.
#   2. tests/chart_publish_check.sh: the gate's EXACT chart-publish proof —
#      the same file tests/validate.sh calls — workflow_call shape, push
#      default, registry agreement with every service Application,
#      name/version not inputs, pull_request refused, plus both red controls
#      (drifted repoURL, flipped push default). Same file, same assertions,
#      same verdict; no second implementation to drift.
#
# WHAT IT NEVER DOES. It never invokes tests/validate.sh — not the full gate
# and not `--only`. tests/bootstrap.sh holds gate self-tests that invoke the
# gate; reaching them from here re-entered the gate recursively (a 624-deep
# validate.sh process tree, measured). This script stays out of that tree by
# calling the shared checker directly.
#
# WHAT IT DOES NOT RUN. Everything else in tests/validate.sh: tier,
# telemetry, observability, lint, tenancy, substrate, obs chart sources. The
# tail of this script says so by name. The full proof is
# `bash tests/validate.sh` with no flags.

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
  elif command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
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

if ! bash "$ROOT/tests/chart_publish_check.sh" \
  "$ROOT/.github/workflows/chart.reusable.yml" \
  "$ROOT/templates/substrate/manifests/applications"; then
  printf 'FOCUSED=publish  pass=%d fail=%d skip=%d + chart publish check FAILED\n' "$pass" "$fail" "$skip"
  exit 1
fi

printf 'FOCUSED=publish  pass=%d skip=%d + chart publish check passed (same file the gate calls, both red controls red)\n' "$pass" "$skip"
printf 'NOT RUN: tier, telemetry, observability, lint, tenancy, substrate, obs chart sources, and every other check — focused publish proof only, not a platform-test pass. Full proof: bash tests/validate.sh\n'
exit 0
