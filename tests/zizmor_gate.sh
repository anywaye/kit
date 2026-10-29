#!/usr/bin/env bash

set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
ZIZMOR="${2:-zizmor}"

if [ ! -d "$ROOT/ci" ]; then
  echo "zizmor_gate: $ROOT/ci does not exist — nothing to audit." >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/kit-zizmor.XXXXXX")"
trap 'rm -rf "$work"' EXIT
report="$work/findings.json"

config_args=()
if [ -f "$ROOT/.github/zizmor.yml" ]; then
  config_args=(--config "$ROOT/.github/zizmor.yml")
fi

if ! "$ZIZMOR" --no-progress --format json \
  "${config_args[@]}" \
  "$ROOT/ci" >"$report" 2>"$work/stderr"; then
  if [ ! -s "$report" ]; then
    echo "zizmor_gate: zizmor produced no report. Its output was:" >&2
    sed 's/^/  /' "$work/stderr" >&2
    exit 1
  fi
fi

"$PY" - "$report" "$ROOT" <<'PY'
import collections
import json
import sys

report, root = sys.argv[1], sys.argv[2]

try:
    findings = json.load(open(report, encoding="utf-8"))
except Exception as exc:
    sys.exit(f"zizmor_gate: could not read zizmor's report: {exc}")

RECORDED = {
    "unpinned-uses": (
        "kit and its thirteen adopters call "
        "anywaye/kit/ci/ci.reusable.yml@master by design. Pinning "
        "to a SHA is a real cost and a real benefit; both are costed in "
        "DECISIONS.md under MD10, together with the third option (pin, and let "
        "Renovate open the bump PRs). Until that is decided, this finding is "
        "counted and printed on every run, and is neither fixed nor baselined."
    ),
}

by_audit = collections.Counter(f.get("ident", "?") for f in findings)
recorded = {a: n for a, n in by_audit.items() if a in RECORDED}
fatal = {a: n for a, n in by_audit.items() if a not in RECORDED}

if recorded:
    for audit, count in sorted(recorded.items()):
        print(f"recorded: {audit}: {count} finding(s), not failing this job")
        print(f"  {RECORDED[audit]}")

if not fatal:
    if not recorded:
        print("zizmor: no findings")
    sys.exit(0)

print()
for audit, count in sorted(fatal.items()):
    print(f"FAIL zizmor: {audit}: {count} finding(s)")
for finding in findings:
    if finding.get("ident") in RECORDED:
        continue
    for loc in finding.get("locations") or []:
        concrete = (loc.get("concrete") or {}).get("location") or {}
        start = concrete.get("start_point") or {}
        print(f"  {finding.get('ident')}: {finding.get('desc')}")
        print(f"    {root}/{(loc.get('symbolic') or {}).get('key', {}).get('Local', {}).get('verbatim_path', '?')}"
              f":{start.get('row', '?')}")
        print(f"    {finding.get('url')}")

print()
print("Every audit other than unpinned-uses is fatal by design. If one of these")
print("is a false positive, record it in .github/zizmor.yml WITH A REASON — a")
print("blanket ignore is what turns a scanner into a report, and one without a")
print("reason is a deferred disclosure. See DECISIONS.md under MD10.")
sys.exit(1)
PY
