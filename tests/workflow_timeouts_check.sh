#!/usr/bin/env bash
#
# workflow_timeouts_check.sh — no job in kit's workflows may inherit GitHub's
# 360-minute default and burn six billed hours on a hang.
#
#   bash tests/workflow_timeouts_check.sh [workflows-dir]
#
# WHY THIS EXISTS. GitHub's default job timeout is 360 minutes. A hung job in a
# reusable workflow therefore bills for up to six hours, and the caller cannot
# fix it: a job whose body is `uses:` may carry only
# name/uses/with/secrets/needs/if/permissions, so `timeout-minutes` is not
# settable from the calling repository (measured against actionlint, which
# reports "timeout-minutes is not available" on that job). The ceiling has to
# live HERE, in the five workflow files every service calls, which is what
# makes this one packet fix the whole fleet at once.
#
# WHAT IT ASSERTS, in both directions:
#   1. Every job that runs on a runner (`runs-on:`) declares `timeout-minutes`.
#      That is the job that can hang and can be billed.
#   2. Every such bound is an integer in 1..360. GitHub caps a hosted-runner
#      job at 360; a bound above it is not a bound, and a non-integer is
#      rejected at workflow-parse time.
#   3. A `uses:` job declares NO `timeout-minutes`. GitHub refuses the whole
#      file if it does ("only following keys are allowed"), so the illegal
#      key would take the run to zero jobs and a green check — the silent
#      failure this repository keeps writing checks against. The bounded work
#      is one level down, in the callee's own runs-on jobs.
#
# WHY A BOUND IS REQUIRED BUT ITS VALUE IS NOT. The right number is a property
# of what the job does (a QEMU multi-arch build is not a `case` statement), so
# the checker demands a bound and a legal range, and the justification lives at
# the code site beside each number. Asserting one global constant here would
# make the suite the second author of every job's budget.
#
# THE THREE RED CONTROLS. Each fixture copies the REAL workflow files and
# violates exactly ONE property; the SAME checker must answer RED:
#   (a) a job's `timeout-minutes` line deleted (the regression's shape);
#   (b) `timeout-minutes` added to a `uses:` job (the illegal fix);
#   (c) a bound set to 600, above GitHub's 360 ceiling (a "bound" that is not).
# A control that stays green means the check is not measuring what it claims —
# a failure of the proof itself, reported as such rather than passed over.
#
# SINGLE SOURCE OF TRUTH. One checker program below; the real tree and all
# three controls run the SAME code against fixture directories. tests/validate.sh
# and tests/focused_publish.sh both call THIS script, so a PASS in either means
# exactly what the standalone proof means.
#
# Exit 0: the real tree passes and all three controls go red.
# Exit 1: an assertion fails, or a control stays green.
# Exit 2: usage error, or no YAML-capable python — the bound cannot be read
#         without a parser, and that is reported, never passed silently.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
workflows="${1:-$ROOT/ci}"

if [ ! -d "$workflows" ]; then
  echo "workflow timeouts: $workflows is not a directory" >&2
  exit 2
fi

# The gate's venv python when present, else a system python3 with PyYAML. No
# parser is an explicit exit 2, never a silent pass — the same resolution and
# the same discipline as chart_publish_check.sh and publish_seam_check.sh.
PY=""
if [ -x "$ROOT/.venv/bin/python" ] && "$ROOT/.venv/bin/python" -c "import yaml" 2>/dev/null; then
  PY="$ROOT/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
  PY="python3"
fi
if [ -z "$PY" ]; then
  echo "workflow timeouts: cannot measure — no YAML-capable python (gate .venv and system PyYAML both absent)" >&2
  exit 2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/kit-wf-timeouts.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

checker="$TMP/workflow-timeouts-check.py"
cat >"$checker" <<'PY'
import glob
import os
import sys

import yaml

workflows = sys.argv[1]

files = sorted(glob.glob(os.path.join(workflows, "*.yml"))) + sorted(
    glob.glob(os.path.join(workflows, "*.yaml"))
)

problems = []
runs_on_jobs = 0
uses_jobs = 0

if not files:
    sys.exit(f"workflow timeouts: no *.yml or *.yaml in {workflows}")

for path in files:
    rel = os.path.basename(path)
    try:
        with open(path, encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except Exception as exc:  # noqa: BLE001 - a parse failure is the finding
        problems.append(f"{rel} does not parse: {exc}")
        continue
    if not isinstance(doc, dict):
        problems.append(f"{rel} is not a mapping")
        continue
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        problems.append(f"{rel} declares no jobs")
        continue
    for jid, job in jobs.items():
        if not isinstance(job, dict):
            problems.append(f"{rel} job {jid!r} is not a mapping")
            continue
        if "uses" in job:
            # A reusable-workflow call: `timeout-minutes` is not legal here,
            # and its bounded work is the callee's own runs-on jobs.
            uses_jobs += 1
            if "timeout-minutes" in job:
                problems.append(
                    f"{rel} job {jid!r} calls a reusable workflow and declares "
                    f"timeout-minutes — GitHub permits only name/uses/with/"
                    f"secrets/needs/if/permissions on such a job, so the file "
                    f"is refused at workflow-parse time and EVERY run of it "
                    f"starts zero jobs and reports success"
                )
            continue
        runs_on_jobs += 1
        if "timeout-minutes" not in job:
            problems.append(
                f"{rel} job {jid!r} declares no timeout-minutes — it inherits "
                f"GitHub's 360-minute default, so a hang bills up to six hours"
            )
            continue
        value = job["timeout-minutes"]
        # `bool` is an `int` in Python; `timeout-minutes: true` is not minutes.
        if isinstance(value, bool) or not isinstance(value, int):
            problems.append(
                f"{rel} job {jid!r} timeout-minutes is {value!r}, which is not "
                f"an integer number of minutes"
            )
        elif not 1 <= value <= 360:
            problems.append(
                f"{rel} job {jid!r} timeout-minutes is {value} — outside 1..360, "
                f"GitHub's accepted range for a hosted-runner job, so it is not "
                f"a bound at all"
            )

# Reading zero jobs is not the same as there being none: a renamed directory or
# an emptied file must fail loudly rather than satisfy an empty loop.
if runs_on_jobs == 0:
    problems.append(
        f"no runs-on job was inspected under {workflows} — the workflows are "
        f"missing or every job is a reusable-workflow call, so nothing was proven"
    )

if problems:
    for problem in problems:
        print(f"workflow timeouts: {problem}")
    sys.exit(1)

print(
    f"workflow timeouts: {runs_on_jobs} runs-on job(s) bounded within 1..360, "
    f"{uses_jobs} reusable-workflow call(s) correctly unbounded, across "
    f"{len(files)} workflow file(s)"
)
PY

run_checker() {
  # The `|| ec=$?` shape is load-bearing, the reason is stated in
  # chart_publish_check.sh: a bare `out="$(cmd)"` that fails takes the shell
  # down under set -e before the status is read.
  local ec=0
  CHECK_OUT=""
  CHECK_OUT="$("$PY" "$checker" "$@" 2>&1)" || ec=$?
  CHECK_EC="$ec"
}
CHECK_EC=0
CHECK_OUT=""

run_checker "$workflows"
if [ "$CHECK_EC" -ne 0 ]; then
  printf '%s\n' "$CHECK_OUT"
  exit 1
fi

# ---------------------------------------------------------------------
# THE THREE CONTROLS. Each fixture copies the REAL files and violates
# exactly ONE property; the same checker must answer RED.
# ---------------------------------------------------------------------

# A tiny text transform applied inside a copy of the real tree. It edits by
# JOB, not by value, so control (a) removes one bound rather than every bound
# that happens to share a number — a fixture that mutates two things proves
# neither. `$1` is the file, `$2` the job id, `$3` the operation.
mutate() {
  "$PY" - "$1" "$2" "$3" <<'PY'
import sys

path, job, op = sys.argv[1:4]
with open(path, encoding="utf-8") as fh:
    lines = fh.read().splitlines(keepends=True)

job_header = f"  {job}:\n"
try:
    start = lines.index(job_header)
except ValueError:
    sys.exit(f"mutate: no job {job!r} in {path}")

# The job's own body ends at the next line that starts a 2-space-indented key.
end = len(lines)
for i in range(start + 1, len(lines)):
    if lines[i].startswith("  ") and not lines[i].startswith("    "):
        end = i
        break

out = list(lines)
if op == "drop-timeout":
    for i in range(start, end):
        if out[i].lstrip().startswith("timeout-minutes:"):
            del out[i]
            break
    else:
        sys.exit(f"mutate: job {job!r} has no timeout-minutes to drop")
elif op == "set-600":
    for i in range(start, end):
        if out[i].lstrip().startswith("timeout-minutes:"):
            indent = len(out[i]) - len(out[i].lstrip())
            out[i] = " " * indent + "timeout-minutes: 600\n"
            break
    else:
        sys.exit(f"mutate: job {job!r} has no timeout-minutes to set")
elif op == "illegal-on-uses":
    # Insert the illegal key inside a `uses:` job, before its `uses:` line.
    for i in range(start, end):
        if out[i].startswith("    uses:"):
            out.insert(i, "    timeout-minutes: 30\n")
            break
    else:
        sys.exit(f"mutate: job {job!r} is not a uses job")
else:
    sys.exit(f"mutate: unknown op {op!r}")

with open(path, "w", encoding="utf-8") as fh:
    fh.writelines(out)
PY
}

copy_workflows() {
  mkdir -p "$1"
  cp "$workflows"/*.yml "$1"/
}

# (a) The regression's own shape: one job's bound deleted.
ctl_a="$TMP/ctl-a-missing"
copy_workflows "$ctl_a"
mutate "$ctl_a/ci.yml" route drop-timeout
run_checker "$ctl_a"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'workflow timeouts: control (a) a deleted bound did not go red — the missing-timeout assertion is not measuring what it claims\n'
  exit 1
fi

# (b) The illegal fix: the key on a job GitHub will not accept it on.
ctl_b="$TMP/ctl-b-uses"
copy_workflows "$ctl_b"
mutate "$ctl_b/ci.yml" full illegal-on-uses
run_checker "$ctl_b"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'workflow timeouts: control (b) a timeout on a uses job did not go red — the uses-exemption assertion is not measuring what it claims\n'
  exit 1
fi

# (c) A "bound" above GitHub's ceiling is not a bound.
ctl_c="$TMP/ctl-c-over"
copy_workflows "$ctl_c"
mutate "$ctl_c/ci.yml" route set-600
run_checker "$ctl_c"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'workflow timeouts: control (c) a bound above 360 did not go red — the range assertion is not measuring what it claims\n'
  exit 1
fi

# The proof, on the way out: the real tree's own summary line.
run_checker "$workflows"
printf '%s\n' "$CHECK_OUT"
printf 'workflow timeouts: all three red controls went red (bound deleted; key on a uses job; bound above 360)\n'
exit 0
