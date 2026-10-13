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
#      name/version not inputs, pull_request refused, plus its red controls
#      (repoURL at the registry root, repoURL path disagreeing with `chart:`,
#      drifted registry prefix, flipped push default). Same file, same assertions,
#      same verdict; no second implementation to drift.
#   3. tests/publish_seam_check.sh: the gate's EXACT publish-path proof —
#      the same file tests/validate.sh calls — the local reusable-workflow
#      references root-relative and resolving, caller/callee inputs agreeing
#      in both directions, the image tag derived from Chart.yaml's
#      appVersion, sha-<40> kept, and every sibling chart beside
#      $ROOT/.. asserted against its Application (or named absent).
#   4. tests/workflow_timeouts_check.sh: the billing guard — every `runs-on`
#      job in .github/workflows/*.yml declares `timeout-minutes` in 1..360,
#      and no `uses:` job carries the key GitHub refuses. Its three red
#      controls (a deleted bound; the key on a uses job; a bound above 360)
#      must go red under the same checker the real tree passes.
#   5. tests/publish_toolchain_check.sh: the two publish steps that had never
#      once succeeded — the helm pin's verification (`helm version --client`,
#      a flag Helm 4 removed) and the provenance stamper (read from the
#      caller's checkout though it lives in kit). Its five red controls
#      (`--client`; a comparison that cannot fail; the caller-relative path; a
#      `master` ref; the missing-file guard removed) must go red under the
#      same checker the real tree passes.
#
# WHAT IT NEVER DOES. It never invokes tests/validate.sh — not the full gate
# and not `--only`. The re-entrancy this packet removes lived INSIDE the
# gate itself (`have()` ↔ `_timeout_bin()` mutual recursion: one forked
# gate child per `$( )` level, a 624-deep validate.sh tree from one focused
# run — not the bootstrap help texts, whose validate.sh matches are inert
# heredocs). This script stays out of that tree by calling the shared
# checker directly.
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

if ! bash "$ROOT/tests/publish_seam_check.sh" \
  "$ROOT/.github/workflows" \
  "$ROOT/templates/substrate/manifests/applications" \
  "$ROOT/.." \
  "$ROOT/templates/publish/publish.yml"; then
  printf 'FOCUSED=publish  pass=%d fail=%d skip=%d + publish seam check FAILED\n' "$pass" "$fail" "$skip"
  exit 1
fi

# 4. The billing guard: every job that can hang carries a bound, and no
# `uses:` job carries the key GitHub rejects. This file is the narrow gate for
# the workflow-timeouts packet, so its own proof (green here, three red
# controls inside) runs beside the publish seams it lives with.
if ! bash "$ROOT/tests/workflow_timeouts_check.sh" "$ROOT/.github/workflows"; then
  printf 'FOCUSED=publish  pass=%d fail=%d skip=%d + workflow timeouts check FAILED\n' "$pass" "$fail" "$skip"
  exit 1
fi

# 5. The toolchain seams: no helm flag the pinned v4 lacks, a helm pin that is
# verified against one value, and the provenance stamper fetched from kit's own
# commit — the two steps that failed the first time the publish path ran.
if ! bash "$ROOT/tests/publish_toolchain_check.sh" "$ROOT/.github/workflows"; then
  printf 'FOCUSED=publish  pass=%d fail=%d skip=%d + publish toolchain check FAILED\n' "$pass" "$fail" "$skip"
  exit 1
fi

printf 'FOCUSED=publish  pass=%d skip=%d + chart publish, publish seam, workflow timeouts and publish toolchain checks passed (same files the gate calls, all red controls red)\n' "$pass" "$skip"
printf 'NOT RUN: tier, telemetry, observability, lint, tenancy, substrate, obs chart sources, and every other check — focused publish proof only, not a platform-test pass. Full proof: bash tests/validate.sh\n'
exit 0
