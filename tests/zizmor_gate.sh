#!/usr/bin/env bash
#
# kit's GitHub Actions security audit, split the way MD10 ruled it.
#
#   bash tests/zizmor_gate.sh [ROOT] [ZIZMOR]
#
# ONE definition, two callers: the `zizmor` job in .github/workflows/
# ci.reusable.yml, and this repository's own gate. A policy that is expressed
# twice is expressed once in CI and once in someone's head.
#
# WHAT THIS SCRIPT DOES THAT A PLAIN `zizmor` DOES NOT
#
#   `unpinned-uses` findings are RECORDED, and nothing else is.
#
#   The fleet calls `anywaye/kit/ci/ci.reusable.yml@master`, so
#   every `uses:` in every adopting repo is a branch ref and zizmor reports
#   thirty-odd of them. Two things can be done with that, and only one of them
#   is honest:
#
#     - fix it: pin thirteen repositories to SHAs, and own the bump. The fleet
#       calls a moving ref on purpose, and the reasons are costed in DECISIONS.md.
#     - baseline it: add `unpinned-uses` to zizmor.yml's ignore list, at which
#       point zizmor stops reporting it and the trade has been made invisibly,
#       in a file whose only other purpose is a different trade.
#
#   So this script does neither. It runs the audit, counts `unpinned-uses`
#   separately, prints the count with a pointer to the decision, and fails on
#   every OTHER finding. `unpinned-uses` is therefore not fixed and not baselined
#   away: it is still measured, still printed on every run, and still the reason
#   the decision exists.
#
#   Everything else zizmor finds is a real finding and fails the build, whether
#   it is fixed in the workflow or accepted in .github/zizmor.yml with a reason.
#   That is the property that stops a blanket baseline: you cannot add a blanket,
#   because a blanket for `unpinned-uses` has nowhere to hide in — this script
#   counts it either way — and a blanket for everything else stops the job
#   finding anything at all.
#
# OFFLINE
#   zizmor's audits read workflow files. The one that does not is
#   `impostor-commit`, which queries the remote; the invocations here do not ask
#   for it. Nothing in this script reaches github.com.

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

# The config is passed with --config rather than left to discovery. Discovery
# walks up from the input to the repository root and would happily find a
# different file on a developer's machine than the one this commit contains;
# zizmor's own docs make the global form take precedence for exactly this
# reason. kit's config is at .github/zizmor.yml, and it is the one that runs.
config_args=()
if [ -f "$ROOT/.github/zizmor.yml" ]; then
  config_args=(--config "$ROOT/.github/zizmor.yml")
fi

# --format json because the split is the whole point and the human-facing
# renderer cannot be told to bucket by audit id. zizmor's exit status is not
# consulted: a non-zero exit means "there are findings", and which findings is
# the question this script exists to answer.
if ! "$ZIZMOR" --no-progress --format json \
  "${config_args[@]}" \
  "$ROOT/ci" >"$report" 2>"$work/stderr"; then
  # Not an error: findings present is a normal outcome, and the report is about
  # to be read. A zizmor that could not run at all prints nothing parseable, so
  # that is the case worth failing on here.
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

# The one audit this job records instead of failing on. Spelled as a constant
# with the reason attached, because the list of audits a job is allowed to
# merely observe is a security decision and belongs where a reader finds it.
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
