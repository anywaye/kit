#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
workflows="${1:-$ROOT/ci}"

if [ ! -d "$workflows" ]; then
  echo "workflow timeouts: $workflows is not a directory" >&2
  exit 2
fi

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

ctl_a="$TMP/ctl-a-missing"
copy_workflows "$ctl_a"
mutate "$ctl_a/ci.yml" route drop-timeout
run_checker "$ctl_a"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'workflow timeouts: control (a) a deleted bound did not go red — the missing-timeout assertion is not measuring what it claims\n'
  exit 1
fi

ctl_b="$TMP/ctl-b-uses"
copy_workflows "$ctl_b"
mutate "$ctl_b/ci.yml" full illegal-on-uses
run_checker "$ctl_b"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'workflow timeouts: control (b) a timeout on a uses job did not go red — the uses-exemption assertion is not measuring what it claims\n'
  exit 1
fi

ctl_c="$TMP/ctl-c-over"
copy_workflows "$ctl_c"
mutate "$ctl_c/ci.yml" route set-600
run_checker "$ctl_c"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'workflow timeouts: control (c) a bound above 360 did not go red — the range assertion is not measuring what it claims\n'
  exit 1
fi

run_checker "$workflows"
printf '%s\n' "$CHECK_OUT"
printf 'workflow timeouts: all three red controls went red (bound deleted; key on a uses job; bound above 360)\n'
exit 0
