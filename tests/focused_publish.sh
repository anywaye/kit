#!/usr/bin/env bash

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
  "$ROOT/ci/chart.reusable.yml" \
  "$ROOT/templates/substrate/manifests/applications"; then
  printf 'FOCUSED=publish  pass=%d fail=%d skip=%d + chart publish check FAILED\n' "$pass" "$fail" "$skip"
  exit 1
fi

if ! bash "$ROOT/tests/publish_seam_check.sh" \
  "$ROOT/ci" \
  "$ROOT/templates/substrate/manifests/applications" \
  "$ROOT/.." \
  "$ROOT/templates/publish/publish.yml"; then
  printf 'FOCUSED=publish  pass=%d fail=%d skip=%d + publish seam check FAILED\n' "$pass" "$fail" "$skip"
  exit 1
fi

if ! bash "$ROOT/tests/workflow_timeouts_check.sh" "$ROOT/ci"; then
  printf 'FOCUSED=publish  pass=%d fail=%d skip=%d + workflow timeouts check FAILED\n' "$pass" "$fail" "$skip"
  exit 1
fi

if ! bash "$ROOT/tests/publish_toolchain_check.sh" "$ROOT/ci"; then
  printf 'FOCUSED=publish  pass=%d fail=%d skip=%d + publish toolchain check FAILED\n' "$pass" "$fail" "$skip"
  exit 1
fi

printf 'FOCUSED=publish  pass=%d skip=%d + chart publish, publish seam, workflow timeouts and publish toolchain checks passed (same files the gate calls, all red controls red)\n' "$pass" "$skip"
printf 'NOT RUN: tier, telemetry, observability, lint, tenancy, substrate, obs chart sources, and every other check — focused publish proof only, not a platform-test pass. Full proof: bash tests/validate.sh\n'
exit 0
