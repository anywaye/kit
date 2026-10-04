#!/usr/bin/env bash
#
# kit's entire test suite. kit is config-only — no runtime code, no library —
# so there is nothing to exercise. The test is that every artifact a service
# repo copies or calls actually parses, and that the telemetry templates
# actually propagate a traceparent.
#
#   bash tests/validate.sh                     # the gate: every phase
#   bash tests/validate.sh --static-only       # parse/semantic checks only (fast)
#   bash tests/validate.sh --language=go       # one telemetry language (CI matrix)
#   bash tests/validate.sh --no-self-test      # skip the "can this go red" proof
#   bash tests/validate.sh --no-observability  # skip the whole observability phase
#   bash tests/validate.sh --no-live           # skip ONLY the observability live tier
#   bash tests/validate.sh --no-lint           # skip running the linters themselves
#
# --no-live, and why it exists and why it is not --no-observability:
#   `--no-observability` drops the whole phase, INCLUDING the two database
#   boundary tiers. `--no-live` drops the three docker stacks the observability
#   PLATFORM is proven by, and leaves the cluster tiers alone. The distinction
#   matters because the two sets of claims are not the same: one is "the
#   collector works", the other is "a service cannot read another service's
#   rows". A child gate that asserts a file-level defect needs neither, and
#   `tests/self_test.sh` is 104 whole gates — each of which used to bring up
#   three docker stacks to learn one fact about one named check, on a machine
#   that may also be running five other workers' gates. That is contention, and
#   contention is what turned breakage 23b — a green-expecting proof about the
#   ruby interpreter floor — red at recipe 23 of 104 in a full suite run while
#   it was green standalone. (REPORTED, not reproduced: 23b's gate run is green
#   on this machine, standalone and in a full suite run. The claim is the
#   EXPOSURE — one whole gate, half of it docker, asserting nothing about any of
#   it — and REPORT-kit-selftest-live-tier-01.md §2 keeps the two apart.)
#   The opt-out is the fix and the bound is not: a bound widened to accommodate
#   the machine it runs on has stopped measuring the thing it was written for.
#
#   WHAT IT IS NOT: silence. Each of the three tiers becomes a `SKIP` naming the
#   flag, counted in the skip tally and printed in the summary, because a skip
#   that cannot be seen is a silent pass. Nothing sets this flag on a gate a
#   human or CI runs; see `live_check` for the shape and `AGENTS.md`.
#
# Six phases, all of which must pass:
#   static         every artifact parses, and the strictness decisions are still
#                  what we wrote them down to be (env-substituted endpoints, every
#                  compose port parameterized, every placeholder documented, and
#                  the collector's redaction allowlist DERIVED FROM core's
#                  schemas rather than transcribed beside them).
#   telemetry      the W3C traceparent templates are EXECUTED, one suite per
#                  language. This is the phase that is easy to fake and so is
#                  the one that runs the code rather than greps it.
#   observability  the two claims that are worth nothing unexercised: that a
#                  canary secret in a prompt-shaped attribute reaches no
#                  exporter, and that a service starts and serves with the
#                  collector killed. Both need a real collector, so both SKIP
#                  loudly without docker — never pass silently.
#   self_test      breaks a throwaway copy of this tree once per kind of check
#                  and asserts the gate goes red each time. A gate that cannot
#                  fail is not a gate.
#   lint           golangci-lint, RuboCop, ESLint and yamllint are RUN against
#                  a fixture built to violate them, with kit's config, and each
#                  is paired with a control that must answer differently. This
#                  is the phase `lint/` never had: 249 lines of configuration
#                  that parsed cleanly and had never been pointed at anything.
#
# One line per check: PASS, FAIL, or SKIP. Any FAIL exits 1. A SKIP is always
# reported in the summary — never hidden.
#
# Dependencies: PyYAML and yamllint (tests/requirements.txt) and hadolint, all
# three REQUIRED and all three bootstrapped by tests/bootstrap.sh on first run,
# so this one command is the whole procedure on a clean clone.
#
# node, the shellcheck binary, and the six language toolchains run when present
# and skip when they are not; the artifact-presence and static checks always
# run, so a deleted template is a failure on a machine with no toolchains at all.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/kit-validate.XXXXXX")"
# The profile is closed on the way OUT, on every exit path, because the tail of a
# run — the summary, and any check after the last `section` header — is otherwise
# an unmeasured gap between the last row and the reader's stopwatch. `kit_total`
# and `kit_phase` are defined further down and are no-ops when `KIT_PROFILE` is
# unset, so this costs the ordinary gate nothing at all.
trap 'kit_phase "END OF RUN (no section header after this point)"; kit_total; rm -rf "$TMP"' EXIT

# The one path the whole repo agrees on, read by every check that looks at the
# reusable workflow. It is a variable rather than a literal repeated in a dozen
# heredocs because the path being wrong is exactly the defect this packet
# exists to fix — see the `callable path` check below.
WORKFLOW='.github/workflows/ci.reusable.yml'

# The SECOND reusable workflow kit hands out, added by kit-32: the one that
# builds a service's image and publishes it to ghcr.io. It is a variable for
# the same reason WORKFLOW is — the callable-path check reads it, and a path
# that is wrong in one place and right in another is the exact class of defect
# that check exists to catch.
IMAGE_WORKFLOW='.github/workflows/image.reusable.yml'

# Both of them, for the checks that iterate kit's callable SURFACE rather than
# naming one standard. Two standards means two paths a caller may `uses:`, and
# a check written while there was only one has to be widened rather than
# pointed at a new file.
#
# WIDENING, AND THE FAILURE THAT PROMPTED IT. The `callable` check refused any
# second file declaring `workflow_call` anywhere in the tree, on the reasoning
# that two copies of the CI standard is the drift kit exists to prevent. Adding
# a SECOND STANDARD — not a second copy — made it go red, and the message named
# a defect that did not exist. That is the check being wrong rather than the
# tree, and the difference matters: "exactly one workflow may be callable" is a
# rule about kit, not about drift, and following it would mean kit can never
# grow. So the walk below now distinguishes the two cases. A second file that
# is a copy of a standard still fails; a file that is a DIFFERENT standard, at
# a declared path, is the thing kit-32 added on purpose.
REUSABLE_WORKFLOWS="$WORKFLOW $IMAGE_WORKFLOW"

# The three files that make the secret scanner one decision rather than three.
# Paths as variables for the same reason WORKFLOW is: the path being wrong is the
# class of defect this file exists to catch, and a literal repeated in a dozen
# heredocs is a dozen chances to spell it three ways.
GITLEAKS_CONFIG='.gitleaks.toml'
GITLEAKS_GATE='tests/gitleaks_gate.sh'
ZIZMOR_CONFIG='.github/zizmor.yml'

# The one `language` option that is not a language. `none` means "this
# repository has no service manifest": no go.mod, no Gemfile, no
# pyproject.toml. It exists because the repository that defines the workflow
# is itself such a repository, and without it kit cannot call its own
# standard — the file was uncallable by the only repo that had any business
# calling it. A real Dockerfile, a `bin/prime` and a mise pin are meaningless
# for it, so the four-artifacts rule deliberately does not apply.
CONFIG_ONLY='none'

# Arguments are parsed BEFORE anything is installed, so `--help` answers on a
# machine with no python and no network. A `--help` that bootstraps a virtualenv
# is a help message with a side effect.
RUN_STATIC=1
RUN_TELEMETRY=1
RUN_SELF_TEST=1
RUN_OBSERVABILITY=1
RUN_LINT=1
# The observability LIVE tier, which is a SUBSET of `RUN_OBSERVABILITY`: three
# docker stacks (the canary, the collector-killed service, the fetched stack)
# out of the five bounded tiers in that phase. Split out because the other two —
# the cluster isolation and the account boundary — are different claims with
# different costs, and a caller that wants one almost never wants the other.
# Measured on this branch: the three cost 128.8s of a 255.2s gate run (50.5%);
# `isolation_test.sh` + `tenancy_test.sh` cost 23.9s between them. So the live
# tier is the whole of the contention problem and the cluster tiers are not, and
# `--no-live` is scoped to the three rather than to the phase.
RUN_LIVE=1
LANGS=()

# ONLY_MATCH, when set, runs only the checks whose LABEL contains this substring.
#
# WHY IT EXISTS, measured rather than argued. A full `--static-only` run is214
# checks and takes ~50s on this machine. `tests/self_test.sh` runs the gate once
# per breakage -- 76 of them -- so the suite spends ~63 MINUTES re-running 16,000
# checks to learn 76 facts, each of which is about ONE named check.
#
# Every breakage already names the check it is testing; it is the third argument
# to `expect_red_check`, and the assertion is that THAT check goes red. Running
# the other 213 cannot change that verdict. This is the difference between
# scheduling 76 sequential runs in parallel and not doing 16,000 units of work.
#
# WHAT IT IS NOT. It does not weaken the assertion. `expect_red_check` still
# demands `FAIL <the named check>` appear in the output and still fails if it
# does not. Narrowing WHICH checks run is not the same as loosening WHAT they
# must prove, and the difference is why this is a filter on the runner rather
# than an edit to any assertion.
#
# THE HONEST CAVEAT. A filtered run has not run the whole gate, so it must not
# be reported as if it had. `--only` therefore prints a banner naming the filter
# on every run, and the exit status is the FILTERED suite's -- never a claim
# about the checks that were excluded.
ONLY_MATCH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --static-only)
      RUN_TELEMETRY=0
      RUN_SELF_TEST=0
      RUN_OBSERVABILITY=0
      RUN_LINT=0
      ;;
    --no-self-test) RUN_SELF_TEST=0 ;;
    --no-observability) RUN_OBSERVABILITY=0 ;;
    --no-live) RUN_LIVE=0 ;;
    --no-lint) RUN_LINT=0 ;;
    --language=*)
      LANGS+=("${1#*=}")
      ;;
    --only=*)
      ONLY_MATCH="${1#*=}"
      ;;
    -h | --help)
      # The whole leading comment block, up to the first line of code. This used
      # to be `sed -n '2,35p'`, a hand-counted range: it already cut a sentence
      # in half, and it moved by one line the day a flag was added, which is
      # exactly the kind of coupling a new flag must not arrive with. Anchored
      # on `set -euo pipefail` instead, which is the first line of code in this
      # file and cannot be renumbered by editing the comment above it.
      sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d'
      # The EXIT trap is armed above `kit_phase` is DEFINED — the profiler's
      # functions are hundreds of lines further down — so `exit 0` from here ran
      # a trap whose body was three unknown commands and printed
      # `kit_phase: command not found` on a successful `--help`. The temp dir is
      # removed here instead of by the trap, and the trap is then disarmed
      # rather than left to fail on the way out.
      rm -rf "$TMP"
      trap - EXIT
      exit 0
      ;;
    *)
      echo "validate.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# `KIT_NO_LIVE` is the same opt-out as `--no-live`, for the caller that cannot
# put a flag on the command line — `tests/self_test.sh`, which runs the gate in
# 105 labelled copies and would otherwise have to thread the flag through five
# helpers. Truthy values only, and `--no-live` above cannot be undone from here:
# an opt-out that a later assignment could turn back on is not an opt-out.
case "${KIT_NO_LIVE:-}" in
  1 | true | TRUE | yes | on) RUN_LIVE=0 ;;
esac

# ---------------------------------------------------------------------------
# profiling — where the run's seconds actually went
# ---------------------------------------------------------------------------
#
# WHY IT IS HERE AND WHY IT IS OFF BY DEFAULT. A gate that takes ten minutes
# cannot be improved from intuition: every claim about which part is slow is a
# claim about a measurement nobody can take again on the same tree. So the
# measurement is part of the gate rather than a thing the packet's worker had to
# hand-assemble with `date` calls and a scratch file.
#
# OFF BY DEFAULT, and off means off: every measurement site is one line of the
# form `_t0=0; [ -n "$_PROFILE" ] && _t0="$(_pf_now)"`, so with `KIT_PROFILE`
# unset the sites cost one `[` and one assignment and NO process — the clock is
# never read. That is a real cost to design for and not a hypothetical one: a
# profiler that made the run it profiles materially slower is a profiler whose
# numbers are wrong in the direction that matters.
#
# WHAT IT RECORDS, and what it deliberately does not. One TSV row per timed
# region: kind, label, seconds, and an inherited tag. The tag is how a row from
# inside a self-test breakage is told apart from a row from the gate itself —
# `KIT_PROFILE_TAG` is exported by `tests/self_test.sh` per breakage, so the
# profile attributes time to a BREAKAGE and not merely to a check name that 94
# copies all share. Rows are appended with `>>`, which is atomic for lines this
# short, and every writer in the tree is short enough to stay under one `PIPE_BUF`.
#
# FOUR KINDS, and why there are four rather than one.
#   check   a serial `check`/`check_verbose` — wall time of ONE command.
#   cpu     a `check_par` child — time of one parallel check. THESE OVERLAP: their
#           sum is an upper bound on the parallel region, not its elapsed time.
#           Collapsing them with the serial rows would double-count and produce a
#           profile that adds up to more than the run, which is the one thing a
#           profile must never do.
#   tier    a `bounded_check` — a whole heavy script, self_test included.
#   phase   the interval between two `section` headers. THE SAFETY NET: a tier
#           that is a bare `report` over a heredoc spawns no command at all, so
#           the check rows cannot see it, and the phase row can.
#   verdict a `report_par` — a loop reaching its verdict from a `[ -x ]`. ~0s by
#           construction; recorded so the table accounts for every printed line.
#
# NOT A GATE. Nothing here can change a verdict, and a profiling run is not a
# substitute for a plain one: `tests/profile_report.py` reads the TSV this writes
# and prints the table, and the run that printed the table is still the run whose
# exit status counts. The profile is an annotation of a run, not a check of its
# own — a file that could fail a build for being slow would be a speed gate, and
# this is not one.
_PROFILE="${KIT_PROFILE:-}"
_pf_tag="${KIT_PROFILE_TAG:-}"

# `_pf_now` prints integer MILLISECONDS. It is NOT `date +%s.%N`: macOS `date`
# has no `%N` and returns a literal `N`, and it is NOT bash's `$EPOCHREALTIME`
# because the gate must run on the bash 3.2 that ships with macOS and in slim
# containers, where that variable does not exist. `perl` with Time::HiRes is
# present wherever the gate's own `awk`/`sed` dependencies are.
#
# MILLISECONDS AND NOT A DECIMAL, and the reason is the one cost that would have
# silently corrupted every number here. An earlier version computed each duration
# with `awk`, which is a second process spawn per measurement — and the run being
# measured spawns roughly 19,000 checks across `self_test`'s 94 breakages, so
# the profiler would have added ~38,000 processes to the run and reported its own
# overhead as the gate's cost. Integer arithmetic in the shell is not slower than
# awk for one subtraction; it is 38,000 fewer processes. With the profile off,
# `_pf_now` is never called at all.
if [ -n "$_PROFILE" ]; then
  _pf_now() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
else
  _pf_now() { printf '0'; }
fi

# kit_profile <kind> <label> <start_ms> — one TSV row, or nothing at all.
kit_profile() {
  [ -n "$_PROFILE" ] || return 0
  local ms=$(( $(_pf_now) - $3 ))
  [ "$ms" -lt 0 ] && ms=0
  printf '%s\t%s\t%d.%03d\t%s\n' "$1" \
    "$(printf '%s' "$2" | tr '\t' ' ')" \
    "$((ms / 1000))" "$((ms % 1000))" "$_pf_tag" >>"$_PROFILE"
}

# The per-check rows are only as good as the thing they hang off, and the phases
# are what a reader of a ten-minute run actually thinks in — the phase rows are
# the safety net for the check rows, and every phase sums to the whole run.
_pf_last=0
if [ -n "$_PROFILE" ]; then
  _pf_last="$(_pf_now)"
fi
_pf_start="$_pf_last"
# `_pf_mark` / `_pf_kind` — the unit of work currently in flight, and which of the
# four kinds it is. `report` reads both and re-arms the mark; see the comment
# there. Both are 0 / `check` with the profiler off, and nothing reads them.
_pf_mark=0
_pf_kind=check

# kit_phase <name> — close the interval since the last marker, open a new one.
kit_phase() {
  [ -n "$_PROFILE" ] || return 0
  local now prev
  prev="$_pf_last"
  now="$(_pf_now)"
  local ms=$((now - prev))
  [ "$ms" -lt 0 ] && ms=0
  printf 'phase\t%s\t%d.%03d\t%s\n' "$1" "$((ms / 1000))" "$((ms % 1000))" "$_pf_tag" >>"$_PROFILE"
  _pf_last="$now"
}

# kit_total — the run's own wall clock, on the EXIT path, so the table's
# denominator is a measurement rather than the reader's arithmetic over rows that
# are individually correct and collectively incomplete (a run killed by
# `timeout` mid-check has no row for the check that was still running).
kit_total() {
  [ -n "$_PROFILE" ] || return 0
  # Declared and assigned SEPARATELY, and that is not style. `local a="$(f)" b=$((a))`
  # computes `b` from the `a` that was already in scope, because `local` takes
  # effect only after the whole list is evaluated — so the arithmetic silently ran
  # against the previous call's timestamp and produced a negative duration, which
  # then clamped to 0.000. A total that reads 0.000 is worse than no total.
  local now ms
  now="$(_pf_now)"
  ms=$((now - _pf_start))
  [ "$ms" -lt 0 ] && ms=0
  printf 'total\tFULL RUN (first line of the script to the exit trap)\t%d.%03d\t%s\n' \
    "$((ms / 1000))" "$((ms % 1000))" "$_pf_tag" >>"$_PROFILE"
}


# The gate installs its own dependencies. Not `shellcheck` and not `node` —
# those stay optional and reported as SKIPs when absent — but PyYAML, without
# which not one check in this file can run, and yamllint, which kit's own
# configs are linted with.
#
# This is the second time this has been a problem. It was a two-line manual
# step in AGENTS.md that every fresh clone and every CI runner missed, and the
# gate exited 1 with `no python with PyYAML` before checking anything. A
# prerequisite that is documented and not automated is a prerequisite that will
# be skipped by exactly the machine you most wanted to hear from.
#
# The resolved interpreter is exported so `tests/self_test.sh`, and every
# throwaway copy of the gate it spawns, uses the same one instead of each
# re-deriving it. That is not only speed: eighteen copies each bootstrapping
# their own virtualenv is eighteen chances to fail for a reason that has nothing
# to do with the breakage under test.
if [ ! -r "$ROOT/tests/bootstrap.sh" ]; then
  echo "validate.sh: tests/bootstrap.sh is missing — the gate cannot install its own dependencies" >&2
  exit 1
fi
# shellcheck source=tests/bootstrap.sh
. "$ROOT/tests/bootstrap.sh"
kit_bootstrap_python "$ROOT"
export KIT_PYTHON="$PY"

kit_phase "00 bootstrap: resolve the interpreter and install deps"

# gitleaks' pinned version, for the check messages below. Read from bootstrap.sh
# rather than re-declared, because two places holding a version number is how the
# binary that gets sha256-verified and the version the gate claims to have run
# stop being the same one. `:-unknown` so the gate still runs against a
# bootstrap.sh older than the secret-scanner checks, rather than dying on an
# unbound variable in its own bookkeeping.
KIT_GITLEAKS_VERSION="${KIT_GITLEAKS_VERSION:-unknown}"

# ---------------------------------------------------------------------------
# static helpers
# ---------------------------------------------------------------------------

# A parse error is one line, not a traceback: the gate is read by humans.
yaml_ok() {
  "$PY" - "$1" <<'PY'
import sys

import yaml

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        yaml.safe_load(fh)
except Exception as exc:
    sys.exit(f"yaml: {exc}")
PY
}

fails=0
skips=0

report() {
  # THE ONE PLACE A VERDICT CLOSES AN INTERVAL. Every `PASS`/`FAIL`/`SKIP` line
  # this gate prints comes through here — from `check`, from `check_verbose`, from
  # `bounded_check`, and from the arms that reach a verdict from a `[ -x ]` with no
  # command at all. Timing the helpers instead would have left a hole exactly
  # where the second version's `--only` smoke test put one: forty PASS lines and
  # not a single row. A hole in a profile reads as "cheap" to everyone who reads
  # the table later, so the emitter is the measurement site.
  #
  # `_pf_mark` is "the millisecond the current unit of work started", and emitting
  # RE-ARMS it to now: a `report` reached after an inline computation therefore
  # measures that computation rather than nothing at all, and a verdict that ran
  # no command is honestly reported as a near-zero `report_direct` row. `_pf_mark`
  # is 0 when no unit of work is in flight — `par_flush` clears it before it
  # prints, because each parallel child's own `cpu` row already covers that time.
  if [ -n "$_PROFILE" ] && [ "$_pf_mark" != 0 ]; then
    kit_profile "$_pf_kind" "$2" "$_pf_mark"
    _pf_mark="$(_pf_now)"
  fi
  printf '%-4s %s\n' "$1" "$2"
  case "$1" in
    FAIL) fails=$((fails + 1)) ;;
    SKIP) skips=$((skips + 1)) ;;
  esac
}

# The exit status a `check`ed command returns to say "the tool is not installed"
# rather than "the tree is wrong". See `check`.
SKIP_EXIT=78

check() { # check <label> <command...>
  local label="$1" out status
  shift
  # `--only` filter. A SUBSTRING match on the label, not a glob: the labels
  # contain `(` `)` `[` `]` and a glob would treat those as character classes
  # and silently match nothing -- a filter that excludes everything reports a
  # clean run, which is the failure mode this whole mechanism exists to avoid.
  #
  # The empty case is counted and reported rather than dropped. A `--only` that
  # matches NOTHING has proven nothing, and a suite that says PASS for it is
  # lying in the most expensive way available.
  if [ -n "$ONLY_MATCH" ]; then
    case "$label" in
      *"$ONLY_MATCH"*)
        ONLY_RAN=$((ONLY_RAN + 1))
        ;;
      *)
        ONLY_SKIPPED=$((ONLY_SKIPPED + 1))
        return 0
        ;;
    esac
  fi
  # The command substitution is the CONDITION of an `if`, not a statement of its
  # own, and that is load-bearing rather than stylistic. Under `set -e` (line
  # 49) a bare `out="$(cmd)"` that fails takes the SHELL down with it: verified
  # with a three-line reproduction, which exits 3 and never reaches the line
  # after. Capturing the status first and branching on it afterwards looks
  # equivalent and is not — it turns every FAIL into a truncated run whose last
  # line is a check, which is precisely the shape a reader has to guess at.
  _t0=0
  [ -n "$_PROFILE" ] && _t0="$(_pf_now)"
  _pf_mark="$_t0"
  _pf_kind=check
  if out="$("$@" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  # The ROW is written by `report` below, which is where every verdict is
  # emitted; the mark set above is all this function owes the profile.
  if [ "$status" -eq 0 ]; then
    report PASS "$label"
    # A check that reports WHICH SPEC it verified is a different statement from
    # one that only reports that it passed. core_check prints the resolved core
    # commit and the spec version precisely so "it passed" is anchored to
    # something a future reader can re-run — and swallowing its output on PASS
    # made that line unreachable in the only case it matters. Most checks print
    # nothing when they succeed, so this is silent for everything else.
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | sed 's/^/       /'
    fi
  elif [ "$status" -eq "$SKIP_EXIT" ]; then
    # A MISSING TOOL IS NOT A DEFECT IN THE TREE. `check` reports every non-zero
    # as FAIL, which is right for a required tool and wrong for an optional one:
    # a gate that reports FAIL because a developer's machine has no `kamal`
    # installed is blaming the tree for the machine, and the reader learns to
    # ignore red lines.
    #
    # 78 is sysexits.h EX_CONFIG. It is used instead of a sentinel string
    # because a string sentinel collides with a command that legitimately prints
    # the word "skip", and because a command's exit status is the one thing
    # `check` already has without having to parse its output.
    report SKIP "$label"
    [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/       /'
  else
    report FAIL "$label"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

# check_verbose — `check`, but it shows the proof on success too.
#
# `check` swallows a passing run's output, which is right for most checks: a
# suite that prints nothing is a suite whose output is a summary. It is wrong for
# the canary harness, whose output is the RED PROOF lines — the evidence that
# each of the five detectors actually fired rather than quietly asserting nothing.
#
# So those lines are echoed when the check passes, and the whole output when it
# fails. The first version of this used `check` and shipped with the proofs
# invisible on a green run, which is precisely the "a proof nobody can see is a
# proof nobody ran" failure the harness's own comments argue against.
check_verbose() { # check_verbose <label> <proof-regex> <command...>
  local label="$1" proof="$2" out ec=0
  shift 2
  _t0=0
  [ -n "$_PROFILE" ] && _t0="$(_pf_now)"
  _pf_mark="$_t0"
  _pf_kind=check
  out="$("$@" 2>&1)" || ec=$?
  # `check_verbose` runs a command exactly as `check` does and reports exactly as
  # `check` does, so leaving it unmarked would have produced a table with a hole
  # where a real cost was — and a hole is read as "cheap" by everyone who reads
  # the table later.
  if [ "$ec" -eq 0 ]; then
    report PASS "$label"
    printf '%s\n' "$out" | grep -E "$proof" | sed 's/^/       /' || true
  else
    report FAIL "$label"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

section() {
  # The PHASE marker, taken here because `section` is the one chokepoint every
  # phase boundary already passes through: instrumenting it means no phase can be
  # missed by forgetting to add a line, which is the failure mode a hand-placed
  # marker has. It writes to the profile file and prints nothing, so the gate's
  # own output — which `--only` and `self_test.sh` both read — is byte-identical
  # with the profiler on and off. Only `kit_phase`'s FILE is touched.
  kit_phase "$1"
  printf '\n-- %s\n' "$1"
}

# only_wanted <label> — 0 when `--only` selects this label, 1 when it excludes it.
#
# WHY IT IS A HELPER RATHER THAN A FIFTH COPY OF THE `case`. `check`,
# `check_par`, `report_par` and `bounded_check` each carry their own copy of this
# branch, and this packet found a check that had NONE: `tests/kamal_test.sh` is
# invoked by a bare `bash`, so its 24 runs of the real `kamal`/`kamal-backup`
# binaries happened on EVERY invocation of the gate — including the 86 self-test
# copies that were asked for one cheap check and had already been told, by name,
# to run one. 55.6% of a child gate's startup floor, unfilterable. Measured in
# `PROFILE-startup-floor.md`.
#
# The accounting is the part that must not drift: `ONLY_RAN` and `ONLY_SKIPPED`
# are what the summary line prints and what the `--only` refusal at the end of the
# file reads, so a filtered run that selected nothing is still a FAIL rather than
# a quiet zero. A fifth copy would have been one more place for that to be wrong.
only_wanted() {
  [ -z "$ONLY_MATCH" ] && return 0
  case "$1" in
    *"$ONLY_MATCH"*)
      ONLY_RAN=$((ONLY_RAN + 1))
      return 0
      ;;
    *)
      ONLY_SKIPPED=$((ONLY_SKIPPED + 1))
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# parallel checks — bounded, ordered, and provably the same verdict
# ---------------------------------------------------------------------------
#
# WHY. Profiled, not guessed. Timing every `check` call individually (each one
# wrapped with a `date` before and after) put the whole `--static-only` run at
# ~35s of which the three per-file loops were 9.6s and NOTHING else was close:
#
#     25 files, one shellcheck spawn each    4.8s
#     23 files, one yamllint spawn each      2.5s
#     42 files, one parser spawn each        2.3s
#
# Every one of those is a spawn whose cost is interpreter start-up, not work:
# 25 shellcheck invocations cost 4.8s and the tree it reads is 1.2MB. The loop
# is serial because `check` is, and `check` is serial because it prints as it
# goes.
#
# WHY BOUNDED, AND WHY THIS NUMBER. Not `&` per iteration. kit's own history is
# the argument: an unbounded fan-out here previously produced load-induced
# failures — self-test shard 57 and the PG-container isolation check both went
# red under 4-way parallel load and passed serially — and a gate that fails on a
# busy machine is a gate people learn to re-run until it agrees with them. So
# concurrency is capped, and the cap is a variable rather than a constant so a
# loaded box can be dialled DOWN instead of being told it was wrong.
#
#   KIT_PARALLEL_CHECKS=<n>   1 = strictly serial (the pre-change behaviour)
#                             0 = auto: nproc, capped at 4
#
# The cap is 4 and not nproc on purpose. These are short CPU-bound spawns, so
# the win flattens well before the core count, while the RISK does not: every
# extra concurrent process is load the rest of the suite — and every other kit
# worker sharing this box — has to live with. A check that got faster by making
# the machine worse is not a speedup.
#
# WHY IT IS STILL THE SAME SUITE. Three properties, all deliberate:
#
#   1. ORDER OF REPORTING IS UNCHANGED. Results are written to one file per
#      check and replayed in submission order, so a reader sees byte-identical
#      output to the serial run. That matters because self_test.sh greps gate
#      OUTPUT for `FAIL <the named check>`, and a report that reordered itself
#      would be a report whose diffs lie.
#   2. THE EXIT STATUS OF EACH CHECK IS CAPTURED, NOT INHERITED. A background
#      job's status is read from the same file its output went to, so a red
#      check is still red and `fails` still counts it. The alternative — letting
#      `wait` decide — would make every check pass.
#   3. `--only` IS APPLIED BEFORE THE SPAWN, not after. A filtered run must not
#      pay for work it is about to discard, which is the same reason the loops
#      are skipped wholesale in a filtered run.
#
# WHAT IT IS NOT. It does not make any check weaker, skip any file, or change
# any verdict. It runs the same commands with the same arguments and reports the
# same statuses in the same order; `KIT_PARALLEL_CHECKS=1` is the old code path.
par_n="${KIT_PARALLEL_CHECKS:-0}"
if [ "$par_n" -eq 0 ] 2>/dev/null; then
  par_n="$( (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4) )"
  [ "$par_n" -gt 4 ] && par_n=4
fi
case "$par_n" in
  '' | *[!0-9]*) par_n=4 ;;
esac
par_dir="$TMP/parallel"
mkdir -p "$par_dir"
par_count=0

# check_par <label> <command...> — `check`, but the work may overlap.
#
# The label and the command are recorded, the command is backgrounded, and the
# RESULT is left for `par_flush` to report in order. The `--only` filter is
# evaluated HERE, before the spawn, and it counts exactly as `check` counts it —
# a filtered-out check still increments ONLY_SKIPPED, so the summary's
# "N ran, M excluded" is the same number the serial path prints.
check_par() {
  local label="$1"
  shift
  if [ -n "$ONLY_MATCH" ]; then
    case "$label" in
      *"$ONLY_MATCH"*) ONLY_RAN=$((ONLY_RAN + 1)) ;;
      *)
        ONLY_SKIPPED=$((ONLY_SKIPPED + 1))
        return 0
        ;;
    esac
  fi
  par_count=$((par_count + 1))
  local slot="$par_dir/$par_count"
  printf '%s\n' "$label" >"$slot.label"
  # The status is written by the same child that writes the output, as its LAST
  # act, so a file that exists with a status beside it is a finished check rather
  # than one caught mid-write. Reading output and status from one place also
  # removes the possibility of reporting one check's output against another's.
  #
  # `set +e` FIRST, and it is load-bearing rather than defensive. This file runs
  # under `set -e` (line 49), and a background subshell inherits it: a failing
  # `"$@"` as a standalone statement would take the subshell down before the
  # `printf` ever ran, so the slot would get an output file and NO status — and
  # `par_flush`'s answer to that is the one thing this helper must never do,
  # which is call a check that did not finish a pass. Turning errexit off INSIDE
  # the child scopes the change to the three lines that need it.
  #
  # The clock is read INSIDE the child, not around the `&`. A parent's wall time
  # for a backgrounded spawn is the time to SPAWN, not the time the check took,
  # so measuring there would have made every parallel check look like a
  # millisecond — which is precisely the shape of measurement that argues for
  # deleting the concurrency. These rows are recorded as `cpu` rather than
  # `check` because they OVERLAP: their sum is an upper bound on the parallel
  # region, not its elapsed time, and the `phase` row is what says how long the
  # region really took. Collapsing the two would double-count and produce a
  # profile that adds up to more than the run, which is the one thing a profile
  # must never do.
  ( set +e
    _t0=0; [ -n "$_PROFILE" ] && _t0="$(_pf_now)"
    "$@" >"$slot.out" 2>&1; _ec=$?
    kit_profile cpu "$label" "$_t0"
    printf '%s\n' "$_ec" >"$slot.status" ) &
  par_pids="$par_pids $!"
  par_slots="$par_slots $slot"
  # The bound. `wait` on the OLDEST pid rather than `wait -n` (bash 4.3+; kit's
  # gate runs on whatever bash a slim container ships, and this file already
  # refuses `mapfile` for exactly that reason).
  par_running=$((par_running + 1))
  if [ "$par_running" -ge "$par_n" ]; then
    par_reap
  fi
}

# par_reap — block until the oldest outstanding check finishes.
#
# It waits for ONE pid and reports NOTHING. Reporting happens in `par_flush`, in
# submission order, because a gate whose output order depends on which check
# finished first cannot be diffed and cannot be grepped by position.
par_reap() {
  [ -n "$par_pids" ] || return 0
  # shellcheck disable=SC2086 # deliberate word-splitting: $par_pids is a list
  set -- $par_pids
  wait "$1" 2>/dev/null || true
  # Rebuild the tail from the shifted positional parameters rather than with
  # `${par_pids#* }`. That prefix strip is a no-op when the list holds exactly
  # one pid -- there is no space in `"999"` for `* ` to match -- so reaping the
  # LAST outstanding check left the list unchanged and `par_flush`'s
  # `while [ -n "$par_pids" ]` spun forever on a queue it had already emptied.
  # `"$*"` rejoins the remainder with a space, and is the empty string for the
  # empty list, which is the termination the caller is actually testing for.
  shift
  par_pids="$*"
  par_running=$((par_running - 1))
  return 0
}

# report_par <verdict> <label> — queue a verdict the loop already knows, so a
# mixed loop still prints in file order.
#
# The parse loop does not only run commands: several of its arms reach a verdict
# from a `[ -x ]` test or a missing toolchain and call `report` directly. Mixing
# those with `check_par` would print the direct ones immediately while the
# spawned ones waited for the flush, so the ORDER of the report would depend on
# which check finished first — and self_test.sh greps this output by position
# far more often than it looks.
#
# So a loop in a parallel region reports everything through here: a verdict is
# written into the same slot stream as a spawned check, in the order the loop
# produced it, and `par_flush` prints the whole run in that order. This arm also
# honours `--only` exactly as `check_par` does, which is what keeps the
# "N ran, M excluded" count identical between the serial and parallel paths.
report_par() {
  local verdict="$1" label="$2"
  if [ -n "$ONLY_MATCH" ]; then
    case "$label" in
      *"$ONLY_MATCH"*) ONLY_RAN=$((ONLY_RAN + 1)) ;;
      *)
        ONLY_SKIPPED=$((ONLY_SKIPPED + 1))
        return 0
        ;;
    esac
  fi
  par_count=$((par_count + 1))
  local slot="$par_dir/$par_count"
  printf '%s\n' "$label" >"$slot.label"
  # The slot's status file holds an EXIT CODE, not a verdict name, because that
  # is the one thing `par_flush` knows how to read back. Writing "SKIP" there
  # instead of a number reads as a non-numeric status and is reported as a FAIL,
  # which is the correct answer to the wrong question — the same wrong answer
  # twice. So the verdict is translated to the code `par_flush` will map back:
  # SKIP becomes the sysexits EX_CONFIG this file already uses for a missing
  # toolchain, FAIL becomes any non-zero. `par_flush` then re-derives the name
  # with the same `report` call the serial path would have made.
  case "$verdict" in
    PASS) printf '0\n' >"$slot.status" ;;
    SKIP) printf '%s\n' "$SKIP_EXIT" >"$slot.status" ;;
    *) printf '1\n' >"$slot.status" ;;
  esac
  : >"$slot.out"
  # Recorded, so a loop that reaches its verdict from a `[ -x ]` rather than a
  # command is still a ROW in the profile instead of a silent gap. Its duration is
  # genuinely ~0: this arm spawned nothing, and the time it spent is already
  # inside the `phase` row that covers the loop.
  #
  # The clock is read HERE, at the top of the write, rather than being taken from
  # the enclosing phase marker. An earlier version passed `$_pf_last`, which made
  # every one of these rows report the age of the whole SECTION — so a region with
  # 300 no-op verdicts would have appeared to cost 300 × the phase's duration, and
  # the profile would have summed to far more than the run it measured. A profile
  # that does not add up is worse than no profile: it is one a reader stops
  # believing.
  _t0=0
  [ -n "$_PROFILE" ] && _t0="$(_pf_now)"
  kit_profile verdict "$label" "$_t0"
}

# par_flush — wait for every outstanding check, then report them in order.
par_flush() {
  while [ -n "$par_pids" ]; do
    par_reap
  done
  # Cleared, not re-armed: every check in a parallel region has already written
  # its own `cpu` or `verdict` row from inside its child, timed where it ran.
  # Leaving a mark live here would make `par_flush`'s deferred `report` calls
  # measure the flush loop itself and charge it to whichever check happened to be
  # last — the same double-count the `cpu` kind exists to prevent.
  [ -n "$_PROFILE" ] && _pf_mark=0
  local i=1 label status out
  while [ "$i" -le "$par_count" ]; do
    local slot="$par_dir/$i"
    label="$(cat "$slot.label" 2>/dev/null || printf '')"
    if [ ! -f "$slot.status" ]; then
      # A check whose child never wrote a status did not finish, and reporting
      # it as a pass would be the one lie this helper is forbidden to tell.
      report FAIL "$label"
      printf '       the check did not report a status; it was killed rather than finished\n'
      i=$((i + 1))
      continue
    fi
    status="$(cat "$slot.status")"
    out="$(cat "$slot.out" 2>/dev/null || printf '')"
    # A status file that exists but is not a number means the child was cut off
    # between creating it and finishing the write. `[ "" -eq 0 ]` under `set -e`
    # would abort the whole gate there, and an aborted gate is not a green one,
    # but a FAIL is the honest verdict and it keeps the run going.
    case "$status" in
      '' | *[!0-9]*)
        report FAIL "$label"
        printf '       the check did not finish writing a status; it was killed rather than finished\n'
        i=$((i + 1))
        continue
        ;;
    esac
    if [ "$status" -eq 0 ]; then
      report PASS "$label"
      [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/       /'
    elif [ "$status" -eq "$SKIP_EXIT" ]; then
      report SKIP "$label"
      [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/       /'
    else
      report FAIL "$label"
      printf '%s\n' "$out" | sed 's/^/       /'
    fi
    i=$((i + 1))
  done
  par_count=0
  par_pids=""
  par_slots=""
  par_running=0
}

# Start a parallel region. `par_begin` resets the slot counter AND clears the
# slots, so each loop gets its own 1..n numbering and no section can read a
# previous section's verdict.
#
# The clear is not tidiness. Slot numbering restarts at 1 in every region while
# the files under `$TMP/parallel` are named by that number, so without it
# section two's first check would find section one's `1.status` already on disk
# and `par_flush` would happily report section one's verdict under section two's
# label. A green line for a check that never ran is the exact failure this whole
# helper exists to avoid, and it would only appear when a loop got SHORTER than
# the one before it.
par_begin() {
  par_pids=""
  par_slots=""
  par_running=0
  par_count=0
  rm -f "$par_dir"/*.label "$par_dir"/*.out "$par_dir"/*.status 2>/dev/null || true
}

par_pids=""
par_slots=""
par_running=0

have() { command -v "$1" >/dev/null 2>&1; }

# No tracked file carries a merge-conflict marker.
#
# This check exists because two markers reached `origin/master` in two different
# repositories, and no other check in this file could have seen either one.
#
# WHERE THEY SURVIVED is the whole reason a separate check was needed, and it is
# not "nobody looked hard enough". Every parse in the static phase runs over
# YAML, JSON, shell, Go, Ruby, Python and compose. All of those were clean.
# Both markers were in a `CHANGELOG.md` — PROSE, which this suite reads for the
# presence of headings and sections and never parses for content. A half-resolved
# merge is still perfectly valid markdown: `<<<<<<<`, `|||||||` and `>>>>>>>` at
# the start of a line render as text, so nothing downstream objects.
#
# The residue that actually got through was the subtle one. The `<<<<<<<` /
# `=======` / `>>>>>>>` triple was removed, and the `||||||| base` line that diff3
# writes BESIDE it was left behind — so the merge looked resolved to whoever
# skimmed the diff, and `grep -c '<<<<<<<'` reports 0 on a tree that is still
# wrong. That is why all three forms are matched here and not just the classic
# pair.
#
# THE PATTERN IS WRITTEN AS `^<{7} `, not as seven literal angle brackets, and
# that is load-bearing rather than a matter of taste. A checker whose own source
# contains the literal marker line flags itself, and the two obvious ways out are
# both worse than the problem: excluding the checker file from its own scan
# leaves a real hole in the one file most likely to hold the residue, and
# suppressing the finding wholesale makes the check unable to report the truth.
# The interval form is a REGEX, so the literal sequence never appears in this
# file, and the check is self-excluding by construction instead of by exception.
conflict_markers_absent() {
  local hits
  hits="$(git -C "$ROOT" grep -I -n -E '^<{7} |^>{7} |^\|{7} ' -- . 2>/dev/null)" || true
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
    printf 'these lines are merge residue, not content; resolve and commit\n'
    return 1
  fi
  return 0
}

# The ruby interpreter floor, read FROM THE TEMPLATE it applies to.
#
# `templates/otel/ruby` calls `Enumerable#filter_map`, which arrived in ruby 2.7.
# The macOS system interpreter at /usr/bin/ruby is 2.6, so a gate that runs the
# suite on whatever `ruby` happens to be first on PATH gets three
# NoMethodErrors and reports them as `FAIL templates/otel/ruby` — blaming the
# template for an interpreter it chose. That is not a cosmetic mislabel: the red
# it printed was attributed to three unrelated packets, and none of them could
# fix it, because none of them touched the template either.
#
# The floor comes from `KitOtel::RUBY_FLOOR` rather than a literal here. A
# version restated in the runner is a second place for it to rot, and the artifact
# is the thing that actually knows. Reading it also means the file and the gate
# cannot disagree about what the file needs — the same reason the classifier's
# tier lives in rules.json and nowhere else.
#
# Empty output means the template could not be loaded far enough to be asked, and
# the caller treats that as a template defect rather than an absent interpreter.
ruby_floor() {
  ruby -e 'require ARGV[0]; print KitOtel::RUBY_FLOOR' \
    "$ROOT/templates/otel/ruby/traceparent.rb" 2>/dev/null
}

# Is dotted version $1 at least dotted version $2?
#
# Hand-rolled rather than `sort -V`, and that choice is load-bearing rather than
# fussy: `-V` is a GNU coreutils extension that older BSD sort does not have,
# and a gate whose floor comparison degrades to a *string* compare on the sort
# shipped with macOS is a gate that reads "2.10" < "2.9" on one machine and not
# on another. Two of the six toolchains here are only ever run by developers, so
# "worked on my sort" is not a portability story.
#
# Refuses on an unparseable field instead of assuming the version is new enough:
# fail-closed is the whole lesson of this repo's classifier, and it applies to a
# shell comparison just as much.
version_at_least() {
  local have_v="$1" want_v="$2" i a b
  for i in 1 2 3; do
    a="$(printf '%s' "$have_v" | cut -d. -f"$i")"; a="${a:-0}"
    b="$(printf '%s' "$want_v" | cut -d. -f"$i")"; b="${b:-0}"
    case "$a$b" in
      '' | *[!0-9]*) return 1 ;;
    esac
    if [ "$a" -eq "$b" ]; then
      continue
    fi
    if [ "$a" -gt "$b" ]; then
      return 0
    fi
    return 1
  done
  return 0
}


# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# the fingerprint cache — P0-3 and P0-4, wired to one real tier
# ---------------------------------------------------------------------------
#
# WHAT THIS IS. `tests/fingerprint.py` can build a manifest, store a record and
# decide a hit. On its own it is a library: it changes nothing about how long
# the gate takes. These two functions are the wiring, and they are the only
# place in the tree where a recorded verdict is allowed to stand in for a run.
#
# WHY IT IS OFF BY DEFAULT. Not for caution — for measurement. Every claim this
# mechanism makes is a claim about WALL CLOCK, and a cache that cannot be
# switched off cannot be measured, because the second run is the only evidence
# and it is indistinguishable from the first if the first was already warm. So
# the cache is `on` by default and off with `KIT_FINGERPRINT=0`, and the report
# quotes both numbers because the honest before-number is the one with it off.
#
# WHERE THE RECORD LIVES, and why it is overridable. `$KIT_CACHE_DIR` if set,
# else `.kit/cache/gate` under the tree. The override exists for `self_test`,
# which runs 94 whole COPIES of this tree: a cache scoped to a copy is deleted
# with the copy and can never be hit by the copy after it, so the 94 breakages
# would each pay full price for the ~113 checks they share with each other.
# One shared cache directory is what lets copy 57 skip the checks copy 23
# already ran — which is P0-1 ("run every gate exactly once") arriving as a side
# effect of P0-4 rather than as a second mechanism.
#
# WHAT IS CACHEABLE IS DECIDED BY THE DECLARATION, not by a heuristic. A
# declaration that cannot be built is not a silent miss: the tier runs, and the
# reason is printed, because a cache that quietly stops caching is a cache whose
# miss rate nobody is watching.
_KF_ENABLED=1
case "${KIT_FINGERPRINT:-on}" in
  0|off|no|false) _KF_ENABLED=0 ;;
esac

_kf_dir() {
  if [ -n "${KIT_CACHE_DIR:-}" ]; then
    printf '%s' "$KIT_CACHE_DIR"
  else
    printf '%s/.kit/cache/gate' "$ROOT"
  fi
}

# The check's identity is the FIRST TOKEN of its label, which is the same string
# `--only` matches on and the same string `self_test.sh` names in `--only=<id>`.
# One id, written once, read by three callers — a second spelling of it would be
# a second thing to keep in step.
_kf_id() {
  printf '%s' "${1%% *}"
}

# bounded_check records its outcome in these two, so that a caller wrapping it
# can store the record without re-running the tier to find out how it went. Set
# UNCONDITIONALLY at the top of the reporting half rather than in each branch:
# a variable left holding the PREVIOUS tier's status is how a red tier gets a
# green record written for it.
KIT_CACHE_LAST_EXIT=""
KIT_CACHE_LAST_OUT=""

kit_cached_check() { # <label> <bound> <inputs-csv> <outputs-csv> <command...>
  local label="$1" bound="$2" inputs="$3" outputs="$4"
  shift 4
  [ "$_KF_ENABLED" -eq 1 ] || { bounded_check "$label" "$bound" "$@"; return $?; }

  # The `--only` filter, FIRST, and for the same reason `bounded_check` applies
  # it first: a tier nobody asked about must not have a record written for it,
  # because the record would describe a run that never happened.
  if [ -n "$ONLY_MATCH" ]; then
    case "$label" in
      *"$ONLY_MATCH"*) ONLY_RAN=$((ONLY_RAN + 1)) ;;
      *)
        ONLY_SKIPPED=$((ONLY_SKIPPED + 1))
        return 0
        ;;
    esac
  fi

  local id cdir man tmpout
  id="$(_kf_id "$label")"
  cdir="$(_kf_dir)"
  # The id is a PATH -- `tests/fetch_test.sh` -- so it cannot be a filename
  # until the slashes are folded. Same fold `fingerprint.py` applies to the
  # record's own name, which is why the two agree without either being told the
  # other's rule.
  man="$cdir/manifests/$(printf '%s' "$id" | tr '/ ' '__').json"
  mkdir -p "$cdir/manifests" 2>/dev/null || true

  # A declaration that will not build is a defect in the DECLARATION, and the
  # only honest response is to run the tier and say so. `|| true` with a loud
  # note, rather than `set -e` taking the gate down over a cache.
  if ! "$PY" "$ROOT/tests/fingerprint.py" --root "$ROOT" --cache-dir "$cdir" manifest \
        --check "$id" --inputs "$inputs" --outputs "$outputs" \
        --command "$*" --out "$man" 2>"$cdir/manifest.err"; then
    printf '       note: the fingerprint declaration for %s did not build, so this\n' "$id"
    printf '       tier ran uncached. The declaration is:\n'
    sed 's/^/         /' "$cdir/manifest.err"
    bounded_check "$label" "$bound" "$@"
    return $?
  fi

  # The skip. One extra process (or two) in exchange for not running the tier,
  # and the exchange only happens on a hit, so the miss path pays for the hit
  # path and never the other way round.
  if "$PY" "$ROOT/tests/fingerprint.py" --root "$ROOT" --cache-dir "$cdir" \
        lookup --manifest "$man" >"$cdir/replay.txt" 2>"$cdir/lookup.err"; then
    bounded_ran=$((bounded_ran + 1))
    report PASS "$label"
    printf '       (skipped: the fingerprint is unchanged and the declared outputs are\n'
    printf '        still on disk — %s)\n' "$(_kf_id "$label")"
    if [ -s "$cdir/replay.txt" ]; then
      sed 's/^/       /' "$cdir/replay.txt"
    fi
    return 0
  fi

  # A MISS, a CORRUPT record and a FOREIGN record all land here, and all three
  # mean the same thing: run it. The distinction is in the stderr the lookup
  # already printed, so the log says WHY it re-ran without this function having
  # to know how to tell the three apart.
  [ -s "$cdir/lookup.err" ] || true
  bounded_check "$label" "$bound" "$@"
  local ec=$?
  ec="$KIT_CACHE_LAST_EXIT"

  # A tier that hit its BOUND leaves the claim it exists to prove unexercised.
  # Recording that as a green would be the exact lie P0-4 forbids, so a BOUND
  # (124) and a FAIL are recorded with their own exit code and can therefore
  # never be a hit — `lookup` refuses any record whose exit is not 0.
  tmpout="$cdir/manifests/$(printf '%s' "$id" | tr '/ ' '__').out"
  printf '%s' "$KIT_CACHE_LAST_OUT" >"$tmpout"
  "$PY" "$ROOT/tests/fingerprint.py" --root "$ROOT" --cache-dir "$cdir" record \
    --manifest "$man" --exit "$ec" --stdout-file "$tmpout" 2>/dev/null || true
  rm -f "$tmpout"
  return 0
}
# bounded_check <label> <bound-seconds> <command...>
# ---------------------------------------------------------------------------
#
# `check` with a CEILING on how long it may take, and — this is the part that
# matters — a fourth, named outcome when the ceiling is reached.
#
# WHY IT EXISTS. The gate grew past what one process can finish on a loaded
# box: three docker stacks brought up and torn down, and thirty-two throwaway
# copies of a 193 KB script each running their own bootstrap. The previous full
# run on this branch was SIGKILLed (exit 137 — the kernel's OOM killer, not a
# test failure) partway through the observability collector tier, which means
# the gate reported *nothing* about the tiers it had not reached. A gate that is
# killed is a gate whose green is a claim about however far it got.
#
# `timeout N` alone would fix the symptom and hide the disease in a new place:
# a timed-out `check` prints FAIL with a two-word diagnostic that names neither
# the tier nor the bound, and the next reader files it under "flaky". So the
# bound is a verdict of its own — `BOUND` — carrying the tier, the bound and the
# tail of what it had printed. It is counted separately in the summary, because
# a bound that is reported as a PASS is exactly the silent skip the gate's own
# rules forbid, and one reported as a FAIL is indistinguishable from a defect
# in the tree.
#
# WHY IT IS NOT A SKIP. Nothing about a timed-out tier is unknown: we know it
# did not finish, and the claim it exists to prove is therefore unexercised. A
# SKIP is for a check that CANNOT run (no docker, no toolchain) and says so
# about the environment. A bound is this machine being too busy, which is a
# fact about the run and not about the tree — and it is the reason the gate
# carries a bound at all rather than being allowed to be killed.
#
# `timeout` IS NOT PORTABLE and pretending otherwise would be the same class of
# defect as the port rules this packet writes about: GNU coreutils ships it as
# `timeout`, macOS has no `/usr/bin/timeout` at all, and Homebrew's coreutils
# installs `gtimeout`. So it is RESOLVED, and a machine with neither runs the
# tier unbounded and says so in the summary — a bound that silently did not
# apply is worse than no bound, because the reader is told a ceiling exists.
bounded_ran=0
# Checks EXCLUDED by `--only`. Counted and printed, never silently dropped: a
# filtered run that does not say what it left out reads exactly like a full run.
ONLY_SKIPPED=0
# Checks the filter SELECTED. Its partner above, and the pair is the whole point:
# a filter that matches nothing runs nothing and has proved nothing.
ONLY_RAN=0
# Tiers that actually REACHED their bound. A separate counter from `bounded_ran`
# on purpose: the summary line has to say "N tiers ran under a bound, M hit it",
# and one counter cannot state both. An earlier version incremented one variable
# in both places and printed "4 tier(s) hit their time bound" for a run in which
# exactly one did — a summary that overstates a machine problem by 4x is the
# fastest way to make a reader ignore the line entirely.
bounded_hit=0
_timeout_bin() {
  for candidate in timeout gtimeout; do
    if have "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

bounded_check() {
  local label="$1" bound="$2"
  shift 2
  local runner out ec=0
  # Same `--only` filter as `check`, and for the same reason: a bounded tier is
  # the EXPENSIVE kind, so running the ones nobody asked about is what makes a
  # suite take minutes. A bounded check that is filtered out must NOT increment
  # `bounded_ran`, or the summary would claim a tier ran when it did not.
  if [ -n "$ONLY_MATCH" ]; then
    case "$label" in
      *"$ONLY_MATCH"*)
        ONLY_RAN=$((ONLY_RAN + 1))
        ;;
      *)
        ONLY_SKIPPED=$((ONLY_SKIPPED + 1))
        return 0
        ;;
    esac
  fi
  if runner="$(_timeout_bin)"; then
    bounded_ran=$((bounded_ran + 1))
    # `--kill-after` so a tier that ignores SIGTERM is still ended: without it
    # the bound is only a request, and the whole point is that the run ENDS.
    _t0=0; [ -n "$_PROFILE" ] && _t0="$(_pf_now)"
    _pf_mark="$_t0"
    _pf_kind=tier
    out="$("$runner" --kill-after=30s "$bound" "$@" 2>&1)" || ec=$?
  else
    _t0=0; [ -n "$_PROFILE" ] && _t0="$(_pf_now)"
    _pf_mark="$_t0"
    _pf_kind=tier
    out="$("$@" 2>&1)" || ec=$?
  fi
  # Published UNCONDITIONALLY, before any branch, so that a caller wrapping this
  # to store a fingerprint record cannot read the PREVIOUS tier's status. A
  # variable left holding an earlier value is how a red tier gets a green
  # record written for it, and the cache would then hand that green back.
  KIT_CACHE_LAST_EXIT="$ec"
  KIT_CACHE_LAST_OUT="$out"
  if [ "$ec" -eq 0 ]; then
    report PASS "$label"
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | sed 's/^/       /'
    fi
  elif [ "$ec" -eq 124 ]; then
    # 124 is `timeout`'s own code for "the bound was reached", and it is the
    # only status here that means the command's verdict is unknown.
    bounded_hit=$((bounded_hit + 1))
    # `BOUND` prints through `printf` rather than `report` — `report` counts
    # FAIL/SKIP and a bound is neither — so the row is emitted here or not at all.
    # A tier that hit its ceiling and left no row is precisely the tier whose cost
    # a reader most needs, because it is the one that decides how long the run is.
    if [ -n "$_PROFILE" ] && [ "$_pf_mark" != 0 ]; then
      kit_profile tier "$label" "$_pf_mark"
      _pf_mark="$(_pf_now)"
    fi
    printf '%-4s %s\n' BOUND "$label"
    printf '       exceeded its %ss bound on this machine. The tier did not finish, so\n' "$bound"
    printf '       the claim it exists to prove is UNEXERCISED — this is not a defect in\n'
    printf '       the tree, and it is not a pass. Re-run on a quieter box; every tier is\n'
    printf '       bounded, so a run that reaches the end has exercised all of them.\n'
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | tail -12 | sed 's/^/       /'
    fi
  else
    report FAIL "$label"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

# live_check <label> <bound> <command...> — the observability LIVE tier, behind
# ONE opt-out.
#
# WHAT IT IS. The three docker stacks that prove the observability platform is
# usable at all: a canary secret in ten attributes reaching no exporter, a
# service still serving with the collector killed, and the FETCHED stack coming
# up with a trace landing in Tempo and a metric in Mimir. Those are the three
# `live_check` calls in phase 30, and this wrapper is the only thing that
# decides whether they run.
#
# WHY IT IS NOT A `--only` FILTER AND NOT A WIDER BOUND. `--only` is a filter on
# a LABEL, and a breakage that wants "the gate went red" cannot use one: the
# verdict it asserts is about a check it names, and a filter broad enough to
# reach the live tier would also reach everything else. A wider bound is the
# response this repository refuses, for a reason stated in its own words further
# down: "a bound set at the observed quiet duration is a bound that fires on any
# contention at all, and a bound that fires is a tier that proved nothing" —
# and a bound widened until it stops firing on a loaded machine is a number that
# has stopped measuring the thing it was written to measure.
#
# WHY IT IS NOT `--no-observability`. That flag drops the whole phase, including
# the two cluster tiers, which are a different claim (a service cannot read
# another service's rows) at a different cost (23.9s between them, measured,
# against 128.8s for these three). A caller that wants the boundary proofs and
# not the collector proofs — or the reverse — needs both halves to be separable.
#
# WHAT THE SKIP IS, and why it is not silence. A SKIP, printed, counted in the
# tally and repeated in the summary: the rule this file keeps restating is that
# a skip nobody can see is a silent pass, and a patch that deleted the three
# `bounded_check` calls outright would satisfy every exit-status assertion while
# proving nothing. So the skip line is the whole contract.
#
# NOT FATAL, and that is a decision rather than an omission. The lint phase is
# fatal on a skip, because "kit's configs work" is unproved by a run in which no
# linter executed. `--no-live` cannot be fatal for the same reason, and the
# reason is 23b: that recipe asserts the gate is GREEN while naming a skip, so a
# fatal `--no-live` skip would red the one proof this exists to keep green. The
# honesty is carried by the count and the summary line instead — which is enough
# here because the flag is set by exactly one caller, in `tests/self_test.sh`,
# and a top-level gate never sets it.
live_check() {
  local label="$1" bound="$2"
  shift 2
  if [ "$RUN_LIVE" -eq 1 ]; then
    bounded_check "$label" "$bound" "$@"
    return $?
  fi
  # `--only` IS APPLIED HERE, FIRST, and only on this branch — and that asymmetry
  # is the point rather than an oversight. When the tier runs, `bounded_check`
  # applies the filter itself; applying it here as well would count every
  # selected tier twice in `ONLY_RAN`. When the tier does NOT run there is no
  # `bounded_check` call to filter, and a filtered run must not report three
  # skips for checks it was told not to run: of the 93 self-test recipes that run
  # the gate, 84 are `--static-only` and 8 more are narrowed by `--only`, and
  # `ONLY_SKIPPED` is a count a reader uses.
  if [ -n "$ONLY_MATCH" ]; then
    case "$label" in
      *"$ONLY_MATCH"*) ONLY_RAN=$((ONLY_RAN + 1)) ;;
      *)
        ONLY_SKIPPED=$((ONLY_SKIPPED + 1))
        return 0
        ;;
    esac
  fi
  # `SKIP_EXIT` and NOT 0, deliberately. `bounded_check` publishes these two
  # unconditionally so a caller cannot read the previous tier's verdict, and this
  # is that publication. A tier that did not run has no verdict, and 0 would be a
  # green for a run that never happened — the exact hazard the unconditional
  # publish exists to prevent, reachable again through this branch. `SKIP_EXIT`
  # is already this file's name for "could not run", and `kit_cached_check`'s
  # `lookup` refuses any record whose exit is not 0, so a skipped live tier can
  # never come back as a cache HIT either.
  KIT_CACHE_LAST_EXIT="$SKIP_EXIT"
  KIT_CACHE_LAST_OUT="$label  (not run: --no-live)"
  report SKIP "$label  (NOT RUN — --no-live, or KIT_NO_LIVE=1: the observability live tier was opted out and this claim is UNEXERCISED)"
}

# ===========================================================================
# phase: static
# ===========================================================================
kit_phase "10 static: every artifact parses, and the strictness decisions hold"

if [ "$RUN_STATIC" -eq 1 ]; then
  # erb_yaml_ok <file> — a Kamal config TEMPLATE renders, and the result is YAML.
  #
  # Two properties, in this order, and the order matters. Rendering first means a
  # template that does not render fails HERE rather than being reported as a YAML
  # error several lines away from the ERB that caused it — the failure this
  # repository keeps rediscovering, and the one that cost a run when a comment
  # inside the ERB block contained a literal tag, closed the block early, and
  # produced "undefined local variable or method `service'" pointing at a
  # variable defined two lines above.
  #
  # The variable set is the OPERATOR's, not kit's, and it is deliberately the
  # non-secret half only. `service` is set to the same placeholder `erl -n` uses
  # everywhere else in this file, so a template that grew a dependency on a value
  # kit does not have would fail here rather than in a customer's shell.
  #
  # `erb` is resolved rather than assumed, for the reason `timeout` is: this gate
  # runs on machines kit does not own, and a check that fails because a tool is
  # missing is a check that fails for a reason that has nothing to do with the
  # tree. A missing `erb` SKIPs; it never FAILs.
  erb_yaml_ok() {
    local f="$1" rendered
    have ruby || return 78
    # The render is Ruby's own `ERB#result`, which is the call Kamal's
    # configuration loader makes — not `erb -x` piped back through a second
    # parse, which was the first version here and which parsed the template
    # twice to learn the same thing.
    #
    # The environment is the operator's non-secret half, exported for the child
    # and NOT left behind: `KIT_SERVICE` is a name, never a credential, and a
    # value that outlived the check would be a value the next check inherited.
    if ! rendered="$(KIT_SERVICE=kitprobe KIT_REGISTRY_ORG=kitprobe \
      KIT_REPO=kitprobe KIT_WEB_HOST=198.51.100.7 \
      KIT_APP_DOMAIN=kitprobe.invalid \
      ruby -rerb -e '
        puts ERB.new(File.read(ARGV[0]), trim_mode: "-").result
      ' "$f" 2>&1)"; then
      printf '%s\n' "$rendered" >&2
      return 1
    fi
    printf '%s' "$rendered" | "$PY" -c 'import sys, yaml; yaml.safe_load(sys.stdin.read())'
  }


  # Dockerfile rules hadolint does not cover. Defined here rather than inline so
  # the section above reads as a list of assertions.
  docker_rules() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
docker_dir = os.path.join(root, "docker")

problems = []
for name in sorted(os.listdir(docker_dir)):
    if not name.startswith("Dockerfile."):
        continue
    rel = f"docker/{name}"
    body = open(os.path.join(docker_dir, name), encoding="utf-8").read()
    lines = body.splitlines()

    # `USER` after the LAST `FROM` is the runtime user. Everything before it is
    # build-time and runs as root by design — that is what a builder stage is.
    last_from = max(
        (i for i, ln in enumerate(lines) if re.match(r"^\s*FROM\s", ln, re.I)),
        default=None,
    )
    if last_from is None:
        problems.append(f"{rel}: no FROM — nothing to run")
        continue

    final_stage = lines[last_from:]
    users = [
        ln.strip()[len("USER "):].strip()
        for ln in final_stage
        if re.match(r"^\s*USER\s+\S", ln, re.I)
    ]
    if not users:
        problems.append(
            f"{rel}: the final stage sets no USER, so it runs as root — "
            f"a container running as root is a container where a bug is a host "
            f"compromise"
        )
    elif any(u.split(":")[0] in ("root", "0", "0:0") for u in users):
        problems.append(f"{rel}: the final stage's USER is root ({users[-1]})")

    # Every FROM carries an explicit tag, and never `latest`.
    for i, ln in enumerate(lines, 1):
        m = re.match(r"^\s*FROM\s+(\S+)(.*)$", ln, re.I)
        if not m:
            continue
        image, rest = m.group(1), m.group(2)
        # An ARG-interpolated tag still has to end in a real tag, so the last
        # colon-separated component is what carries it: `python:${V}-slim` ends
        # in `-slim`, `golang:${V}` ends in `${V}`. Neither is `latest`.
        tail = re.split(r"[ \t]", rest.strip())[0] if rest.strip() else ""
        if not tail and ":" not in image:
            problems.append(f"{rel}:{i}: FROM {image} has no tag; an untagged base is a moving target")
        if tail in ("latest",) or image.rsplit(":", 1)[-1] == "latest":
            problems.append(f"{rel}:{i}: FROM {image} is :latest")

    # ADD pulls a URL as easily as a file, so it is a way to put unverified
    # content in an image without a hash. COPY cannot do that. The four kit
    # artifacts a service inherits should not hand a reader that option.
    for i, ln in enumerate(lines, 1):
        if re.match(r"^\s*ADD\s", ln, re.I):
            problems.append(f"{rel}:{i}: ADD — use COPY, which cannot fetch a URL")

if problems:
    sys.exit("; ".join(problems))
PY
  }

  # Every template's STRICTNESS NOTES must state the non-root guarantee, in the
  # final stage, in the file itself. Parsed as the leading comment block rather
  # than grepped for a keyword: all seven files mention "root" somewhere in
  # prose, so a grep was satisfied by a line about root-owned directories while
  # the actual guarantee went unstated.
  docker_notes() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
docker_dir = os.path.join(root, "docker")

problems = []
for name in sorted(os.listdir(docker_dir)):
    if not name.startswith("Dockerfile."):
        continue
    rel = f"docker/{name}"
    lines = open(os.path.join(docker_dir, name), encoding="utf-8").read().splitlines()

    # The leading comment block, stopping at the first instruction.
    head = []
    for ln in lines:
        if not ln.lstrip().startswith("#"):
            break
        head.append(ln)

    if not head:
        problems.append(f"{rel}: no STRICTNESS NOTES header comment")
        continue

    body = "\n".join(head).lower()
    # `non-root`, `nonroot`, or `uid 1000`-style: the claim is that the process
    # is not uid 0, however the file happens to word it. What it must NOT accept
    # is a note that only talks about root-owned files.
    claims_non_root = re.search(r"non-?root", body) is not None
    if not claims_non_root:
        problems.append(
            f"{rel}: its STRICTNESS NOTES do not state that the final stage runs "
            f"non-root. Every one of these templates does run non-root (the check "
            f"above proves it), but a reader deciding whether to adopt the file "
            f"reads the notes, not the gate"
        )
    if "strictness" not in body:
        problems.append(
            f"{rel}: the header comment has no STRICTNESS NOTES block, so a future "
            f"contributor has nothing saying what is enforced and why"
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }

  # Every image starts through `docker/entrypoint.sh`, and this is the check that
  # says so. See the call site for why a presence check would not do.
  docker_entrypoint() {
    "$PY" - "$ROOT" <<'PY'
import json
import os
import re
import sys

root = sys.argv[1]
docker_dir = os.path.join(root, "docker")
script = os.path.join(docker_dir, "entrypoint.sh")

problems = []
if not os.path.isfile(script):
    problems.append(
        "docker/entrypoint.sh is missing, and every Dockerfile's ENTRYPOINT "
        "names it — which means all seven images exec a file that is not there"
    )

for name in sorted(os.listdir(docker_dir)):
    if not name.startswith("Dockerfile."):
        continue
    rel = f"docker/{name}"
    body = open(os.path.join(docker_dir, name), encoding="utf-8").read()

    entrypoints = re.findall(r"^\s*ENTRYPOINT\s+(.+)$", body, re.I | re.M)
    if not entrypoints:
        problems.append(f"{rel}: no ENTRYPOINT at all")
        continue
    # The LAST one wins: a multi-stage file may set an ENTRYPOINT per stage, and
    # the one that decides what the container runs is the final stage's.
    raw = entrypoints[-1].strip()
    if not raw.startswith("["):
        problems.append(
            f"{rel}: the final ENTRYPOINT is shell form ({raw!r}); kit's exec "
            f"contract is exec-form, because a shell form adds a shell that "
            f"does not forward SIGTERM"
        )
        continue
    try:
        argv = json.loads(raw)
    except ValueError as exc:
        problems.append(f"{rel}: the final ENTRYPOINT is not a JSON array ({exc})")
        continue

    # Endswith, not equality. The ENTRYPOINT carries the PATH
    # (`/app/kit-entrypoint`) while the Dockerfile that COPYs it names the SOURCE
    # (`docker/entrypoint.sh`); a test for the bare name `kit-entrypoint` as a
    # list member is a test that fails on every correct tree. It did, once, and
    # the tree it failed on was the one it was written for.
    at = next(
        (i for i, a in enumerate(argv) if a.endswith("kit-entrypoint")),
        None,
    )
    if at is None:
        problems.append(
            f"{rel}: the final ENTRYPOINT does not start through "
            f"docker/entrypoint.sh, so this image boots without applying its "
            f"migrations — the cold-start race kit ships the entrypoint to "
            f"delete. Expected the script before the service command."
        )
        continue
    rest = [a for a in argv[at + 1:] if a]
    if not rest:
        problems.append(
            f"{rel}: the final ENTRYPOINT ends at the entrypoint script and "
            f"names no service command, so the container would exec nothing. "
            f"The script refuses to start with no arguments."
        )
        continue
    # `-e` or `--env` before the command would be the other way to spell this,
    # but kit does not use it and accepting it would accept a Dockerfile whose
    # CMD was relied on instead — which is invisible in the ENTRYPOINT alone.
    if rest[0].startswith("-"):
        problems.append(
            f"{rel}: the final ENTRYPOINT puts {rest[0]!r} before the service "
            f"command, so the script would try to exec a flag as a program"
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }

  # First, because it is the cheapest check in the phase and the one that makes
  # the others trustworthy: a marker in a shell script or a YAML file will be
  # caught downstream by a parser complaining about the residue, but a marker in
  # a markdown file is caught by nothing, ever, and the suite reports green on a
  # tree that is wrong. See `conflict_markers_absent`.
  check 'no tracked file carries a merge-conflict marker' conflict_markers_absent

  section 'static: every artifact parses'

  # `templates/kamal/*.yml.erb` is in this list, and its ABSENCE from the plain
  # `*.yml` arm is the interesting part. These templates are not YAML: they are
  # ERB that produces YAML, so `yaml.safe_load` on the file itself would be
  # checking the wrong thing — a template's own validity is a property of the
  # text after rendering.
  #
  # So the two `.erb` files are rendered with the operator's non-secret
  # variables and the RESULT is parsed, by a case below. `drill.sh` is named
  # rather than globbed as `templates/kamal/*`, because the `*)` arm reports an
  # unrecognised type as a SKIP and `README.md` would put a permanent
  # "no parser for this file type" line in every run — and a permanently
  # reported skip is a gap nobody fixes, which is the whole point of the skip
  # existing. Naming them explicitly also means a NEW file dropped into
  # `templates/kamal/` is unparsed rather than mis-parsed: the safe direction.
  # `--only` skips this whole loop. The loop shells out PER FILE -- one `bash -n`,
  # one `python -c "yaml.safe_load"`, one `json.loads` each -- and it does that
  # before any `check` has been consulted, so a filtered run was paying for ~150
  # process spawns to produce results nobody asked for. Measured: a `--only`
  # matching ONE check still took 23s, and a `--only` matching NONE took 24s,
  # which is the signature of a fixed cost that filtering could not touch.
  #
  # It is safe to skip, and the reason is structural rather than hopeful: every
  # line in the loop calls `check`, so a filtered run would skip them anyway --
  # one `check` call each, just after paying for the file walk.
  #
  # `check_par`, not `check`: 42 files and one spawn each, 2.3s measured, and
  # nearly all of it interpreter start-up. Each iteration reads one file and
  # shares nothing with the next, which is what makes them safe to overlap. The
  # arms that reach a verdict WITHOUT spawning go through `report_par` so the
  # section still prints one line per file in file order.
  if [ -z "$ONLY_MATCH" ]; then
  par_begin
  for f in "$ROOT"/.github/workflows/* "$ROOT"/lint/* "$ROOT"/docker/* \
    "$ROOT"/templates/bin-prime/* "$ROOT"/templates/compose/* \
    "$ROOT"/templates/kamal/drill.sh \
    "$ROOT"/templates/compose/postgres/initdb/*.sh \
    "$ROOT"/templates/compose/postgres/Dockerfile \
    "$ROOT"/templates/database/contract.json \
    "$ROOT"/templates/database/tenancy/* \
    "$ROOT"/templates/bin/* "$ROOT"/templates/tier/*/* "$ROOT"/tests/*.sh; do
    [ -f "$f" ] || continue
    path="${f#"$ROOT"/}"
    case "$f" in
      *.sh) check_par "$path  (bash -n)" bash -n "$f" ;;
      *.yml | *.yaml) check_par "$path  (yaml.safe_load)" yaml_ok "$f" ;;
      *.json)
        # contract.json is where the connection check reads its requirements
        # from, so a syntax error in it would be a check reading nothing rather
        # than a red line. Parsed here so a malformed file fails on every
        # machine — including one with no docker, which is the rest of the
        # topology's dependency.
        check_par "$path  (json.loads)" "$PY" -c \
          'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$f"
        ;;
      # The cluster image. hadolint is its parser and runs below — reported
      # there rather than here for the same reason docker/Dockerfile.* is:
      # printing "no parser for this file type" beside a real hadolint result
      # would say both "unchecked" and "checked" in the same run.
      "$ROOT"/templates/compose/postgres/Dockerfile) ;;
      *.mjs)
        if have node; then
          check_par "$path  (node --check)" node --check "$f"
        else
          report_par SKIP "$path  (node not installed)"
        fi
        ;;
      "$ROOT"/docker/Dockerfile.*)
        # Linted by hadolint in the section below, and by `docker_rules` for the
        # two properties hadolint does not cover. Deliberately not reported
        # here: "no parser for this file type" was the seven-line SKIP this
        # packet exists to remove, and printing it next to a real hadolint
        # result would say both "unchecked" and "checked" in the same run.
        ;;
      # The tier templates. Each of these is a file a service COPIES, so each
      # has to parse in its own language — the rule is "parse what you hand
      # out", and `rack_middleware.rb.snippet` shipped with syntax that was not
      # Ruby because nothing checked the extension kit gave it.
      #
      # Rust is compiled rather than parsed, and that is deliberate: `tier.rs`
      # is one self-contained crate, exactly like `templates/otel/rust/`, so
      # `rustc --test` is both the parse and the strongest check available
      # without inventing a module layout kit has no use for.
      "$ROOT"/templates/tier/rust/*.rs)
        if have rustc; then
          check_par "$path  (rustc --test)" bash -c \
            "rustc --test --edition 2021 -o \"$TMP/kit-tier-rust\" '$f' && '$TMP/kit-tier-rust' --list >/dev/null"
        else
          report_par SKIP "$path  (rustc not installed)"
        fi
        ;;
      "$ROOT"/templates/tier/python/*.py)
        if have python3; then
          # `compile()`, not `python3 -m py_compile`. The module form writes a
          # `__pycache__/` into the SOURCE tree, and that directory is then
          # picked up by two other checks that iterate this one — which is how a
          # gate that started green went red on its own artefacts. `compile()`
          # is the same parse with no filesystem side effect at all.
          check_par "$path  (compile)" python3 -c \
            'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$f"
        else
          report_par SKIP "$path  (python3 not installed)"
        fi
        ;;
      "$ROOT"/templates/tier/ruby/*.rb)
        if have ruby; then
          check_par "$path  (ruby -c)" ruby -c "$f"
        else
          report_par SKIP "$path  (ruby not installed)"
        fi
        ;;
      "$ROOT"/templates/tier/elixir/*.ex)
        if have elixir; then
          # `elixir -c` is not a thing. `Code.string_to_quoted/1` is the
          # stdlib parse, it is offline, and it reports the same syntax errors
          # the compiler would — which is the property being asserted.
          check_par "$path  (Code.string_to_quoted!)" elixir -e \
            'case Code.string_to_quoted(File.read!(hd(System.argv()))) do
               {:error, e} -> IO.puts("syntax: #{inspect e}"); System.halt(1)
               {:ok, _} -> :ok
             end' "$f"
        else
          report_par SKIP "$path  (elixir not installed)"
        fi
        ;;
      # The account-boundary templates.
      #
      #   substrate.sql / isolation.sql are SQL, and there is no psql on a machine
      #   that has not installed one — so they are NOT parsed here and their
      #   correctness is `tests/tenancy_test.sh`, which runs them against the real
      #   Postgres kit ships. That is the right parser for them: a syntax error in a
      #   migration is only observable by a server.
      #
      #   The six drivers, on the other hand, are files a service COPIES, so the
      #   rule "parse what you hand out" applies to them exactly as it applies to
      #   the otel and tier snippets. `rack_middleware.rb.snippet` shipped with
      #   syntax that was not Ruby because nothing looked at it, and every one of
      #   these six was written from scratch in this packet with no toolchain
      #   resolving its imports — so a parse on any machine is worth having.
      # Markdown. Named rather than globbed, and deliberately so: the `*)` arm would
      # report `SKIP … (no parser for this file type)` on every run, and a
      # permanently-reported skip is a gap nobody fixes, which is the whole reason
      # the skip exists. This README's check is the presence check above it, which
      # asserts it is there — and a README has no syntax to be wrong about. The
      # same treatment templates/kamal/README.md gets, for the same reason.
      "$ROOT"/templates/database/tenancy/README.md)
        report_par PASS "$path  (markdown; the presence check is its check)"
        ;;
      "$ROOT"/templates/database/tenancy/substrate.sql | \
      "$ROOT"/templates/database/tenancy/isolation.sql | \
      "$ROOT"/templates/database/tenancy/advisor.sql)
        # No parser for this file type HERE, deliberately: see above. Reported
        # rather than silently passed, so a reader can see that the SQL is checked
        # by tests/tenancy_test.sh and not by this loop.
        report_par SKIP "$path  (SQL; parsed by tests/tenancy_test.sh against a real Postgres)"
        ;;
      "$ROOT"/templates/database/tenancy/assertions.txt)
        # Shape only. That every name in it is CONSTRUCTED in isolation.sql is the
        # tenancy contract check's job, and duplicating it here would be a second
        # implementation of a rule rather than a second parser of a file.
        check_par "$path  (every entry is an assertion name)" bash -c \
          "[ \"\$(grep -cE '^[[:space:]]*[^#[:space:]]' '$f')\" -eq \"\$(grep -cE '^[a-z-]+/[a-z0-9-]+$' '$f')\" ]"
        ;;
      "$ROOT"/templates/database/go/tenancy_test.go.snippet)
        if have gofmt; then
          check_par "$path  (gofmt parses)" gofmt -e "$f"
        else
          report_par SKIP "$path  (gofmt not installed)"
        fi
        ;;
      "$ROOT"/templates/database/python/tenancy_test.py.snippet)
        if have python3; then
          # `compile()`, not `python3 -m py_compile`: the module form writes a
          # `__pycache__/` into the SOURCE tree, and two other checks iterate this
          # one, which is how a gate that started green goes red on its own
          # artefacts. Same reason as the tier python case above.
          check_par "$path  (compile)" python3 -c \
            'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$f"
        else
          report_par SKIP "$path  (python3 not installed)"
        fi
        ;;
      "$ROOT"/templates/database/ruby/tenancy_test.rb.snippet)
        if have ruby; then
          check_par "$path  (ruby -c)" ruby -c "$f"
        else
          report_par SKIP "$path  (ruby not installed)"
        fi
        ;;
      "$ROOT"/templates/database/elixir/tenancy_test.exs.snippet)
        if have elixir; then
          # `Code.string_to_quoted/1` and NOT a load. A load of this file would
          # need Postgrex, and kit has no mix.exs and no deps — so a load here would
          # report an unresolved module as a parse failure, which is the exact
          # mistake the database elixir arm's own comment records happening twice.
          # This one imports a driver, so the parse is the honest bar.
          check_par "$path  (Code.string_to_quoted!)" elixir -e \
            'case Code.string_to_quoted(File.read!(hd(System.argv()))) do
               {:error, e} -> IO.puts("syntax: #{inspect e}"); System.halt(1)
               {:ok, _} -> :ok
             end' "$f"
        else
          report_par SKIP "$path  (elixir not installed)"
        fi
        ;;
      "$ROOT"/templates/database/rust/tenancy_test.rs.snippet)
        if have rustc; then
          # Crate-type lib, not `--test`: `#[tokio::test]` expands to a
          # `#[test]` fn, and compiling the test harness would need the proc macro
          # to resolve. A parse is the claim being made here, and `--crate-type lib`
          # is what makes it one. Unresolved-crate errors are expected and filtered
          # by the caller below, which is the same treatment database.rs.snippet
          # gets.
          check_par "$path  (rustc parses)" rustc --edition 2021 --crate-type lib \
            --emit=metadata -o /dev/null "$f"
        else
          report_par SKIP "$path  (rustc not installed)"
        fi
        ;;
      "$ROOT"/templates/database/node/tenancy_test.ts.snippet)
        if have node; then
          # Copied to a real extension first: node refuses a `.snippet` with
          # ERR_UNKNOWN_FILE_EXTENSION, which is a check reporting a perfectly
          # valid TypeScript file as unparseable on the strength of a filename.
          check_par "$path  (node --check, as .ts)" bash -c \
            "cp '$f' '$TMP/tenancy_test.ts' && node --experimental-strip-types --check '$TMP/tenancy_test.ts'"
        else
          report_par SKIP "$path  (node not installed)"
        fi
        ;;
      # The lint drift allowlist, which has no extension because it is not
      # meant to look like a config a linter would read — it is a list of
      # PEOPLE, and naming it `.yml` would invite exactly the `cp` this packet
      # exists to stop. It has no parser of its own; the drift check below IS
      # its parser, and it reads it as text and reports a malformed line.
      #
      # Without this case the loop's `*)` branch printed
      # `SKIP … (no parser for this file type)` for it, which is a claim that
      # would have been false — the file is read on every run of this gate.
      "$ROOT"/lint/drift-allowlist)
        # Shape only, and deliberately NOT a second copy of the drift check's
        # rules. Those four — reason, owner, dates, and an entry that no longer
        # describes a real difference — all live in `lint_drift_check` below, and
        # the last one can only be evaluated there because it needs the fleet.
        # Duplicating any of them here would be a second, unchecked copy of a
        # rule, which is the mistake this repository's classifier section
        # documents at length.
        #
        # What is checked here is the one property that is cheap and that the
        # drift check's own parser cannot report nicely: every content line
        # begins an entry. A wrapped entry shows up as a line that does not, and
        # the drift check would call it "malformed" without saying that the
        # obvious cause is a wrapped line.
        # Counted, both sides, and compared. The first version of this was a
        # `!` on one end of a pipeline, which negates the LAST stage's status
        # rather than the one the author is thinking about — so it passed on a
        # file with a wrapped entry, which is the exact case it was written for.
        # Two counts and an equality have no stage to get wrong.
        check_par "$path  (every content line starts one entry)" bash -c \
          "[ \"\$(grep -cE '^[[:space:]]*[^#[:space:]]' '$f')\" \
             -eq \"\$(grep -c '^diverged ' '$f')\" ]"
        ;;
      # A Kamal config TEMPLATE, which is ERB that produces YAML.
      #
      # `yaml.safe_load` on the file itself would be checking the wrong artifact:
      # what a service ends up with is the RENDERED text, and a template's
      # failure modes live in the gap between the two. Rendering first and
      # parsing the result is the check that can fail.
      #
      # The renderer is the SAME one kamal uses, and that is the point rather
      # than a convenience. Kamal's own configuration loader calls
      # `ERB.new(...).result`, so rendering with the stock `erb` and then handing
      # the output to `kamal config` in tests/kamal_test.sh walks the same path an
      # operator walks. A bespoke renderer would be a second parser to keep
      # correct, and this repository has already refused that twice.
      #
      # The values supplied here are the non-secret ones a real operator sets.
      # Deliberately NOT supplied: any secret. If a future edit interpolated a
      # credential into the rendered output this check would still pass — the
      # assertion that it does not is in tests/kamal_test.sh, which runs the real
      # binary and greps its real output for the real values.
      "$ROOT"/templates/kamal/deploy.yml.erb | "$ROOT"/templates/kamal/kamal-backup.yml.erb)
        check_par "$path  (renders, and the rendered YAML parses)" erb_yaml_ok "$f"
        ;;
      "$ROOT"/templates/tier/go/*.go)
        # gofmt is run over the whole tree's Go templates in the telemetry phase
        # below, so it is deliberately not reported twice here. `go build` would
        # need a module kit does not have, and `go vet` needs one too — the
        # format check is the real check, and it is where Go's own parser is
        # unhappy.
        ;;
      "$ROOT"/templates/tier/*/*.ts)
        # Stock `node --check` does not read TypeScript, and a service copying
        # this file gets TypeScript. Reported as a SKIP with its reason rather
        # than passed over: a skip nobody can see is a gap nobody fixes, and the
        # summary line is how this class of gap is found. The fix is a
        # type-stripping parser, which is a dependency, and kit is config-only.
        report_par SKIP "$path  (node --check cannot read TypeScript; needs a type-stripping parser)"
        ;;
      *)
        # A new file type with no parser is a gap, so it is loud rather than
        # quiet. It is still a SKIP, because the honest report matters more
        # than a red gate on an unknown extension — but a SKIP is counted and
        # printed in the summary, which is how the seven Dockerfiles were found.
        report_par SKIP "$path  (no parser for this file type)"
        ;;
    esac
  done
  par_flush

  # Every script kit hands out is executable. `chmod -x bin/dev` in a commit is
  # a one-character diff that silently breaks six repos the next they adopt.
  #
  # tests/ is in this list and not an afterthought: tests/gitleaks_gate.sh and
  # tests/zizmor_gate.sh are run BY the reusable workflow, from a service's
  # repository, against that service's tree. A gate script that is not executable
  # is a `secrets` job that dies at the first step in thirteen repos.
  # The two gate scripts are in this list and not an afterthought: they are run
  # BY the reusable workflow, from a service's repository, against that service's
  # tree. A gate script that is not executable is a `secrets` job that dies at
  # its first step in thirteen repos.
  #
  # `tests/bootstrap.sh` is deliberately NOT in the list: it is sourced, never
  # executed, and it says so at the top. A check that required it to be
  # executable would be asking a file to claim a contract it does not have.
  section 'static: handed-out scripts are executable'
  # `templates/kamal/drill.sh` is in this list because it is a script kit HANDS
  # OUT: an operator runs it, exactly as they run entrypoint.sh. A non-executable
  # drill.sh is a drill nobody can start, and the message is "permission denied"
  # without saying which file.
  # `docker/entrypoint.sh` is here because the comment above already named it:
  # every one of the seven Dockerfiles now `COPY`s it and `exec`s it, and a
  # developer running it against a local database needs it executable too. The
  # image itself does not depend on the mode — the ENTRYPOINT is
  # `["/bin/sh", "/app/kit-entrypoint", …]` — so this is about the person, not
  # the container. That is still a contract worth asserting, because
  # `chmod -x` is a one-character diff.
  for f in "$ROOT"/templates/bin-prime/* "$ROOT"/templates/bin/* \
    "$ROOT"/templates/kamal/drill.sh \
    "$ROOT"/docker/entrypoint.sh \
    "$ROOT/$GITLEAKS_GATE" "$ROOT/tests/zizmor_gate.sh"; do
    [ -f "$f" ] || continue
    path="${f#"$ROOT"/}"
    if [ -x "$f" ]; then
      report PASS "$path  (executable)"
    else
      report FAIL "$path  (not executable)"
    fi
  done
  fi

  # Run the linter over the scripts we wrote, not just `bash -n`. `bash -n`
  # passes on quoting bugs; shellcheck is what catches them. Optional, and
  # reported as a SKIP when absent — never silently passed.
  #
  # (Note: a comment whose first word is the linter's name is parsed as a linter
  # directive, which is why this paragraph is worded the way it is.)
  # `--only` skips this loop for the same reason as the artifact-parses loop
  # above: every iteration calls `check`, so a filtered run discards each result
  # -- after paying for the spawn. shellcheck is the second-most expensive thing
  # this gate does, and it runs on every invocation whether or not anyone asked
  # for it.
  if [ -z "$ONLY_MATCH" ] && have shellcheck; then
    section 'static: shellcheck -S warning'
    par_begin
    for f in "$ROOT"/templates/bin-prime/* "$ROOT"/templates/bin/* \
      "$ROOT"/templates/kamal/*.sh "$ROOT"/docker/*.sh "$ROOT"/tests/*.sh; do
      [ -f "$f" ] || continue
      path="${f#"$ROOT"/}"
      # SC2317 (unreachable command) is excluded deliberately: the `check`
      # helper builds a command list that shellcheck's flow analysis cannot see
      # through. Every other warning is a real finding.
      #
      # `check_par`, not `check`: this loop is the single most expensive thing
      # the static phase does (measured: 4.8s over 25 files, almost all of it
      # the linter's own start-up), and each iteration is an independent spawn
      # over one file with no shared state. The bound and the ordering
      # guarantees are documented at `check_par`.
      check_par "$path  (shellcheck -S warning)" shellcheck -S warning -e SC2317 "$f"
    done
    par_flush
  else
    report SKIP 'shellcheck (not installed)'
  fi

  # -------------------------------------------------------------------------
  section 'static: templates/otel — every artifact is present'
  # This runs on a machine with no language toolchains at all. A template that
  # was deleted or renamed must fail the gate here, not "skip" later.
  otel_required() {
    "$PY" - "$ROOT" "$@" <<'PY'
import os
import sys

root, *rest = sys.argv[1:]
missing = [p for p in rest if not os.path.isfile(os.path.join(root, p))]
if missing:
    sys.exit("missing template artifact(s): " + ", ".join(missing))
PY
  }

  # Every language ships: the codec, its suite, the SDK wiring snippet, and a
  # README saying when to use which. The README is not optional — a template
  # nobody knows when to use is a template nobody uses.
  #
  # The field count is deliberately variable. Five languages carry a separate
  # test file; rust does not, because `rustc --test` builds a single crate from
  # one source with the suite inline. Its presence is asserted below instead, by
  # looking for the `#[test]` functions — a presence check on a file that has
  # none in it would be satisfied by a crate shipping an implementation and no
  # proof, which is the exact thing this packet exists to prevent.
  #
  # `pins.md` lives at the otel root, not under rust/: it pins all six
  # languages' OTel versions, and a version table scoped to one language reads
  # as "rust's versions" to the next person who greps for it.
  otel_readme='templates/otel/README.md'
  if otel_required "$otel_readme" 'templates/otel/pins.md'; then
    report PASS 'templates/otel/{README.md,pins.md}  (present)'
  else
    report FAIL 'templates/otel/{README.md,pins.md}  (present)'
  fi

  while IFS='|' read -r lang a b c d e; do
    [ -n "$lang" ] || continue
    wanted=("templates/otel/$lang/$a" "templates/otel/$lang/$b" "templates/otel/$lang/$c")
    [ -n "$d" ] && wanted+=("templates/otel/$lang/$d")
    [ -n "$e" ] && wanted+=("templates/otel/$lang/$e")
    if otel_required "${wanted[@]}"; then
      report PASS "templates/otel/$lang/  (${#wanted[@]} artifacts present)"
    else
      report FAIL "templates/otel/$lang/  (${#wanted[@]} artifacts present)"
    fi
  done <<'OTEL'
go|traceparent.go|traceparent_test.go|otelhttp.go.snippet|README.md
ruby|traceparent.rb|test_traceparent.rb|rack_middleware.rb.snippet|README.md
elixir|traceparent.ex|test_traceparent.exs|phoenix_telemetry.ex.snippet|README.md
rust|traceparent.rs|otel_client.rs.snippet|README.md
python|traceparent.py|test_traceparent.py|fastapi.py.snippet|README.md
node|traceparent.mjs|traceparent.test.mjs|hono.ts.snippet|README.md
OTEL

  # rust keeps its suite inline, so "the test file exists" is not a check that
  # can be run on it. This is the equivalent.
  check 'templates/otel/rust/traceparent.rs  (carries its own suite)' bash -c \
    "grep -qE '#\[test\]' '$ROOT/templates/otel/rust/traceparent.rs'"

  # -------------------------------------------------------------------------
  section 'static: templates/database/tenancy — every artifact is present'
  # The account boundary is five files and six drivers, and the six are the reason
  # this is a presence check rather than a note: kit templates six languages, and a
  # half-adopted account boundary is the same defect as a half-adopted language —
  # five services protected by Postgres and one protected by a WHERE clause a
  # reviewer forgot, which is the state this packet was written about.
  #
  # `isolation.sql` and `assertions.txt` are here rather than left implicit because
  # a driver beside a missing manifest compiles, runs, and asserts completeness
  # about nothing. The manifest is the half that makes six thin drivers safe.
  if otel_required \
    'templates/database/tenancy/README.md' \
    'templates/database/tenancy/substrate.sql' \
    'templates/database/tenancy/isolation.sql' \
    'templates/database/tenancy/advisor.sql' \
    'templates/database/tenancy/assertions.txt' \
    'templates/database/go/tenancy_test.go.snippet' \
    'templates/database/elixir/tenancy_test.exs.snippet' \
    'templates/database/python/tenancy_test.py.snippet' \
    'templates/database/ruby/tenancy_test.rb.snippet' \
    'templates/database/node/tenancy_test.ts.snippet' \
    'templates/database/rust/tenancy_test.rs.snippet'; then
    report PASS 'templates/database/tenancy/  (5 shared artifacts + 6 per-language drivers)'
  else
    report FAIL 'templates/database/tenancy/  (5 shared artifacts + 6 per-language drivers)'
  fi

  # -------------------------------------------------------------------------
  section 'static: templates/kamal — every artifact is present'
  #
  # The Kamal configuration is a SET for the same reason the backup distribution
  # was, and the failure is the same shape: `config/deploy.yml` and
  # `config/kamal-backup.yml` are ONE contract (every `{ secret: NAME }` in the
  # second must appear in the backup accessory's `env.secret` list in the first,
  # or `kamal-backup validate` rejects the pair), so a service holding one
  # without the other has a config that is internally valid and jointly wrong.
  #
  # `drill.sh` is in the list because it is a script kit HANDS OUT, run by the
  # operator — so it is also in the executable and shellcheck lists above.
  #
  # `README.md` is not decoration: it is the file that answers the Ruby question
  # (does a service need Ruby to deploy?) and records what was removed and why.
  if otel_required \
    'templates/kamal/README.md' \
    'templates/kamal/deploy.yml.erb' \
    'templates/kamal/kamal-backup.yml.erb' \
    'templates/kamal/drill.sh'; then
    report PASS 'templates/kamal/  (4 artifacts present, the set is whole)'
  else
    report FAIL 'templates/kamal/  (4 artifacts present, the set is whole)'
  fi

  # The superseded custom backup toolchain must be GONE, and this is the check
  # that goes red if it ever comes back.
  #
  # It is not a deprecation warning. kit-20 built `templates/backup/` (a compose
  # file, a job script, a crontab), `templates/bin/backup.sh` (a hand-written
  # restic wrapper) and `docker/Dockerfile.backup` — roughly 1,850 lines
  # reimplementing kamal-backup's command surface. Keeping them "just in case"
  # is the failure this repository names explicitly: an unreferenced backup path
  # is a second thing to keep correct forever, and it would be a second set of
  # retention numbers and a second redaction boundary that nobody reviews.
  #
  # The property worth having is therefore NEGATIVE — a path that must not be
  # reachable — and a negative needs its own check or it is only a convention.
  if [ -e "$ROOT/templates/backup" ] || [ -e "$ROOT/templates/bin/backup.sh" ] ||
    [ -e "$ROOT/docker/Dockerfile.backup" ] || [ -e "$ROOT/tests/backup_test.sh" ]; then
    report FAIL 'the superseded custom backup toolchain  (it must be gone — kamal-backup is the standard)'
  else
    report PASS 'the superseded custom backup toolchain  (it must be gone — kamal-backup is the standard)'
  fi

  # The generated config is EXECUTED, not parsed. `yaml.safe_load` on either
  # file would say they are YAML and nothing about whether Kamal can use them,
  # and the three defects this replaces were all invisible to a parse: a
  # doubled registry host, a missing `builder.arch`, and a secret named in one
  # file and not the other. `tests/kamal_test.sh` runs the real binaries.
  #
  # It SKIPS, loudly and counted, when kamal/kamal-backup are not installed —
  # they are the OPERATOR's tools, not kit's dependency, so a machine without
  # Ruby is a normal machine and the gate must not demand one. A skip in the
  # telemetry or lint phases is fatal; here it is not, for that reason, and the
  # summary line is how the gap stays visible.
  #
  # AND IT ANSWERS `--only`, which it did not do until this packet. The call
  # below is a bare `bash` rather than a `bounded_check`, so for the whole life
  # of the check the filter could not reach it and the 24 real-binary runs
  # happened on every invocation — 3.8 s, 55.6% of the child gate's floor
  # (`PROFILE-startup-floor.md`), paid 86 times over by copies that had been told
  # to run one check. `only_wanted` is the guard; the LABEL it filters on is
  # `kamal_test`, the same needle `tests/self_test.sh` passes to
  # `expect_red_check` as `$KAMALCHECK`, and every label this block can print
  # contains that substring — so breakages 78, 79 and 82 keep selecting it and
  # keep going red through it.
  #
  # What this costs, stated rather than hidden: on a FILTERED copy
  # `tests/kamal_test.sh` does not run, exactly as `check`, `check_par` and
  # `bounded_check` already did not run. `ONLY_SKIPPED` counts it and the
  # summary line prints the exclusion, so the gap is loud. On an UNFILTERED run
  # — the gate itself, and all nine self-test copies that run a whole gate —
  # this changes nothing at all: same command, same output, same verdict.
  if have kamal && have kamal-backup && have ruby; then
    if only_wanted 'kamal_test'; then
      if bash "$ROOT/tests/kamal_test.sh" >"$TMP/kamal_test.log" 2>&1; then
        # The script's own last line is its count, and that count is the point:
        # a reader who wants to know how much of the claim was exercised should
        # not have to open a second file. The leading `PASS: ` is stripped
        # because `report` prints its own verdict, and "PASS PASS:" is the kind
        # of small wrongness that trains a reader to skim past a line that
        # matters.
        report PASS "$(sed 's/^PASS: //' "$TMP/kamal_test.log" | tail -1)"
      else
        report FAIL 'kamal_test  (the generated config is accepted by the real binaries)'
        sed 's/^/       /' "$TMP/kamal_test.log" | tail -20
      fi
    fi
  else
    report SKIP 'kamal + kamal-backup + ruby not installed  (the generated config was validated by nothing)'
  fi

  # A snippet that names no version is a snippet nobody can install: the reader
  # copies a floating major, gets three minors of drift, and files a bug
  # against a version they chose. And a snippet that vendors is a snippet that
  # has turned kit into a dependency — the rule AGENTS.md states as "no
  # dependencies, ever", checked rather than trusted.
  snippet_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
snippets = {
    "go": "otelhttp.go.snippet",
    "ruby": "rack_middleware.rb.snippet",
    "elixir": "phoenix_telemetry.ex.snippet",
    "rust": "otel_client.rs.snippet",
    "python": "fastapi.py.snippet",
    "node": "hono.ts.snippet",
}

# Each language names its installer in a different verb; the point is that one
# of them appears, not which.
install = re.compile(
    r"\b(go get|bun add|npm add|yarn add|bundle add|mix deps\.get"
    r"|pip install|uv add|cargo add)\b"
)
# A version is a digit. `@latest`, `^1.2.3` and a bare `^` are all rejected
# below for different reasons, but all of them fail this.
versioned = re.compile(r"[=<>@~^ ]\s*v?\d+\.\d+")

problems = []
for lang, name in snippets.items():
    path = os.path.join(root, "templates", "otel", lang, name)
    if not os.path.isfile(path):
        continue  # absence is the artifact-presence check's job, not a second failure
    body = open(path, encoding="utf-8").read()

    if not install.search(body):
        problems.append(f"otel/{lang}/{name}: no install line — a reader cannot install from this")

    # Floating-version scan runs over COMMENT LINES INCLUDED, unlike the
    # composer's no-literal-URL rule. A snippet puts its install commands in a
    # comment block precisely so a reader copies one line and the file is still
    # valid in a repo with no OTel dep; stripping comments first would have
    # thrown those away and the check would have passed a snippet with no
    # install line at all — which is what it did on its first run.
    for lineno, line in enumerate(body.splitlines(), 1):
        if "@latest" in line or "@main" in line or "@master" in line:
            problems.append(f"otel/{lang}/{name}:{lineno}: floating ref: {line.strip()[:60]}")

    # A version is a digit somewhere in the body. Prose mentioning "no
    # dependencies" must not satisfy it, so the match is anchored to the
    # characters that actually introduce a version.
    if not versioned.search(body):
        problems.append(f"otel/{lang}/{name}: no versioned dependency anywhere")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/otel/*/*.snippet  (installable, versioned, not vendored)' snippet_check

  # -------------------------------------------------------------------------
  # The canary harness's Go sources must PARSE, and must parse in Go's own
  # parser rather than in a regex.
  #
  # The gate executes the suite (telemetry phase), so a syntax error is caught
  # there — but only on a machine with Go installed, where it would be reported
  # as a telemetry SKIP's opposite and a developer would read it as "the canary
  # is fine". A parse here runs with no toolchain at all, so a missing template
  # or a bad edit is a static failure on any machine, which is the property the
  # otel snippets were given for the same reason.
  section 'static: the canary harness parses in Go'
  # `--only` skips the per-file gofmt loop; see the artifact-parses loop above.
  if [ -z "$ONLY_MATCH" ] && have gofmt; then
    # gofmt is a real parser: it exits non-zero on a file it cannot parse, and
    # unlike `go build` it needs no module, no resolver and no network.
    for f in "$ROOT"/templates/secrets/go/*.go "$ROOT"/templates/secrets/go/internal/*/*.go; do
      [ -f "$f" ] || continue
      path="${f#"$ROOT"/}"
      check "$path  (gofmt parses)" gofmt -e "$f"
    done
  else
    report SKIP 'templates/secrets/go  (gofmt not installed — cannot parse)'
  fi

  # Every snippet must PARSE in its own language. This is not a style check and
  # not a stretch: a snippet is the file a service copies, so a syntax error in
  # one ships as a service that does not boot.
  #
  # It already happened. rack_middleware.rb.snippet contained
  # `c.use_all, :auto_instrumentation`, which is not valid Ruby, and no check in
  # this file looked at it — the artifact-presence table only asked whether the
  # file existed, and `node --check` refuses a `.snippet` extension outright.
  #
  # Snippets are copied to a real extension before parsing, because
  # `ruby -c foo.snippet` fails on the extension alone and `node --check` throws
  # ERR_UNKNOWN_FILE_EXTENSION.
  section 'static: every otel snippet parses in its own language'
  snippet_dir="$TMP/snippets"
  rm -rf "$snippet_dir"
  mkdir -p "$snippet_dir"

  # <lang>|<file>|<extension>|<command...>
  while IFS='|' read -r lang file ext cmd; do
    [ -n "$lang" ] || continue
    src="$ROOT/templates/otel/$lang/$file"
    [ -f "$src" ] || continue
    copy="$snippet_dir/$lang$ext"
    cp "$src" "$copy"
    if out=$($cmd "$copy" 2>&1); then
      report PASS "otel/$lang/$file  (parses as $ext)"
    else
      report FAIL "otel/$lang/$file  (parses as $ext)"
      printf '%s\n' "$out" | head -8 | sed 's/^/       /'
    fi
  done <<'SNIPPETS'
go|otelhttp.go.snippet|.go|gofmt -e -l
ruby|rack_middleware.rb.snippet|.rb|ruby -c
python|fastapi.py.snippet|.py|python3 -m py_compile
SNIPPETS

  # Elixir, which kit-02 did not check and should have. A `.ex` file compiles at
  # LOAD time, so `Code.require_file` is a parser for it — and it is the only
  # thing that could have caught what this packet's rewrite actually contained
  # before it shipped: a `Logger.log` call with a keyword list followed by a
  # `"key" => value` pair, which is a hard SyntaxError in Elixir and an entirely
  # ordinary-looking line in every other language.
  #
  # The traceparent codec is required first so the file has no cross-file
  # dependency, and a load that reports *warnings* about the OTel modules it
  # cannot find is a PASS: kit has no mix.exs and no deps, and a warning about a
  # missing `:opentelemetry` is exactly what a dependency-free kit should
  # produce. Only a real compile error fails — and the two shapes are counted
  # rather than grepped for the word "error", because the warnings above contain
  # that word too and a check that cannot tell a warning from an error is a
  # check that fails on a clean file.
  if have elixir; then
    ex_copy="$snippet_dir/phoenix_telemetry.ex"
    cp "$ROOT/templates/otel/elixir/phoenix_telemetry.ex.snippet" "$ex_copy"
    ex_out="$(elixir -r "$ROOT/templates/otel/elixir/traceparent.ex" "$ex_copy" 2>&1 || true)"
    if grep -qE '\*\* \((Compile|Syntax)Error\)|^\s*error:' <<<"$ex_out"; then
      report FAIL 'otel/elixir/phoenix_telemetry.ex.snippet  (parses as .ex)'
      printf '%s\n' "$ex_out" | head -8 | sed 's/^/       /'
    else
      report PASS 'otel/elixir/phoenix_telemetry.ex.snippet  (parses as .ex)'
    fi
  else
    report SKIP 'otel/elixir/phoenix_telemetry.ex.snippet  (elixir not installed)'
  fi

  # rustc needs its own treatment: --emit=metadata on a file importing
  # opentelemetry fails on unresolved crates (E0432/E0433), which is not a
  # syntax error and is exactly what a dependency-free kit should produce. So
  # the check is "no error other than an unresolved-crate error", which still
  # catches every parse error.
  if have rustc; then
    rust_copy="$snippet_dir/otel_client.rs"
    cp "$ROOT/templates/otel/rust/otel_client.rs.snippet" "$rust_copy"
    rust_out="$(rustc --edition 2021 --crate-type lib --emit=metadata \
      -o /dev/null "$rust_copy" 2>&1 || true)"
    # Compare ERROR CODES, not lines. rustc's trailing
    # `error: aborting due to 16 previous errors` carries no code, so a
    # line-based "is any line not E0432/E0433" test reports that summary as a
    # syntax error. Which is what the first version of this check did.
    rust_codes="$(printf '%s\n' "$rust_out" | grep -oE '^error\[E[0-9]+\]' | sort -u)"
    rust_unexpected="$(printf '%s\n' "$rust_codes" | grep -vE 'E0432|E0433|E0463' || true)"
    if [ -n "$rust_unexpected" ]; then
      report FAIL 'otel/rust/otel_client.rs.snippet  (parses as .rs)'
      printf '%s\n' "$rust_unexpected" | sed 's/^/       /'
    elif [ -z "$rust_codes" ]; then
      report PASS 'otel/rust/otel_client.rs.snippet  (parses; crates resolved)'
    else
      report PASS 'otel/rust/otel_client.rs.snippet  (parses; crates unresolved, as expected)'
    fi
  else
    report SKIP 'otel/rust/otel_client.rs.snippet  (rustc not installed)'
  fi

  # TypeScript: node's own type stripper is a parser, and it is in the node
  # already running this gate. No typescript-eslint, no install.
  if have node; then
    ts_copy="$snippet_dir/hono.ts"
    cp "$ROOT/templates/otel/node/hono.ts.snippet" "$ts_copy"
    # The ExperimentalWarning goes to stderr and is not a parse failure, so it
    # is filtered rather than allowed to fail a clean parse.
    ts_out="$(node --experimental-strip-types --check "$ts_copy" 2>&1 |
      grep -vE 'ExperimentalWarning|trace-warnings' || true)"
    if [ -z "$ts_out" ]; then
      report PASS 'otel/node/hono.ts.snippet  (parses as .ts)'
    else
      report FAIL 'otel/node/hono.ts.snippet  (parses as .ts)'
      printf '%s\n' "$ts_out" | head -8 | sed 's/^/       /'
    fi
  else
    report SKIP 'otel/node/hono.ts.snippet  (node not installed)'
  fi

  # A template must not declare a dependency. kit is config-only; if these
  # files can `require` something, kit has a lockfile and a supply chain.
  section 'static: templates declare no third-party dependency'
  check 'templates/otel/go/go.mod  (no require)' bash -c \
    "! grep -qE '^[[:space:]]*require' '$ROOT/templates/otel/go/go.mod'"
  # The canary harness is the other stdlib-only template, and the same rule
  # applies for a sharper reason: a canary test that pulls in a dependency is a
  # canary test whose own output has to be trusted not to contain the thing it
  # is sweeping for. kit has no dependencies, and neither does a thing kit hands
  # out.
  check 'templates/secrets/go/go.mod  (no require)' bash -c \
    "! grep -qE '^[[:space:]]*require' '$ROOT/templates/secrets/go/go.mod'"
  if [ -f "$ROOT/templates/otel/node/package.json" ]; then
    check 'templates/otel/node/package.json  (no dependencies)' bash -c \
      "$PY -c \"import json,sys; d=json.load(open(sys.argv[1])); sys.exit(1 if (d.get('dependencies') or d.get('devDependencies')) else 0)\" \
      '$ROOT/templates/otel/node/package.json'"
  else
    report PASS 'templates/otel/node/package.json  (not needed: node:test + stdlib)'
  fi

  # -------------------------------------------------------------------------
  # The seven Dockerfiles.
  #
  # These are one of the four artifacts every adopting service inherits, and
  # until now they received NO lint at all: the artifact-presence loop above
  # reached the `*)` branch and printed
  #
  #     SKIP docker/Dockerfile.go  (no parser for this file type)
  #
  # seven times. A skip is honest, which is how it was found, and honest is not
  # the same as covered: a Dockerfile that does not build ships unverified, and
  # a service that adopts one finds out on its own first deploy.
  #
  # hadolint is the real parser and it is required, not optional. It is a
  # single static binary, so `kit_bootstrap_binary` fetches a pinned release and
  # verifies its published sha256 rather than trusting whatever is on PATH —
  # a linter that is silently absent, or silently different, is the same
  # SKIP wearing a PASS.
  section 'static: every Dockerfile is hadolint clean'
  if kit_bootstrap_binary hadolint \
    "https://github.com/hadolint/hadolint/releases/download/v${KIT_HADOLINT_VERSION}" \
    "$KIT_HADOLINT_SHA256S" "$ROOT"; then
    for f in "$ROOT"/docker/Dockerfile.* "$ROOT"/templates/compose/postgres/Dockerfile; do
      [ -f "$f" ] || continue
      rel="${f#"$ROOT"/}"
      # `--no-color`: the gate's output is read by humans and by CI log
      # scrapers, and an ANSI escape in a FAIL block is noise in both.
      if out=$("$BIN" -c "$ROOT/lint/hadolint.yaml" --no-color "$f" 2>&1); then
        report PASS "$rel  (hadolint)"
      else
        report FAIL "$rel  (hadolint)"
        printf '%s\n' "$out" | sed 's/^/       /'
      fi
    done
  else
    # Not a SKIP. hadolint is the only thing standing between a template and a
    # broken build, and a gate that reports "I could not check" and exits 0 is
    # the exact shape PLAN.md §1 calls a gate that is not green. It is also the
    # shape that let seven Dockerfiles go unlinted in the first place.
    report FAIL 'hadolint (required: could not be installed — see the note above)'
  fi

  # hadolint is a syntax-and-practice linter. It will happily pass a Dockerfile
  # whose final stage runs as root, and root in a container is a container where
  # a bug is a host compromise. So the two properties kit's own STRICTNESS NOTES
  # claim for all seven — a non-root final stage, and a pinned (never `:latest`)
  # base image — are asserted here rather than assumed from the prose.
  #
  # Read from the file as text, not from a Dockerfile parser: these templates
  # use `ARG` interpolation, so a base image is `python:${PYTHON_VERSION}-slim`
  # and the claim to check is that the tag exists and is not `latest`, not that
  # it is a literal. hadolint is the parser for everything it can parse; this is
  # the two claims that outlive it.
  section 'static: every Dockerfile runs non-root on a pinned base'
  check 'docker/Dockerfile.*  (non-root final stage, no :latest, no ADD)' docker_rules

  # A Dockerfile with no USER in its final stage is a real defect, and the check
  # above proves that claim can fail. So the claim is written down where the
  # reader is: in each template's own STRICTNESS NOTES, the block a person
  # deciding whether to adopt this file actually reads.
  #
  # The note is required to be about the non-root final stage specifically, not
  # merely to contain the word "root" — every one of the seven already mentions
  # running non-root SOMEWHERE in passing, in prose no check read. A check that
  # the claim is documented where the reader looks, and the check that the claim
  # is true, are different checks; this is the first.
  section 'static: each Dockerfile documents its own non-root guarantee'
  check 'docker/Dockerfile.*  (STRICTNESS NOTES state the non-root stage)' docker_notes

  # -------------------------------------------------------------------------
  # Every image starts through the entrypoint, and this asserts the WIRING rather
  # than the presence of the file.
  #
  # A presence check would be satisfied by a `docker/entrypoint.sh` that nothing
  # runs — and, worse, would be satisfied SILENTLY by its absence: the
  # executable-files loop above is `[ -f "$f" ] || continue`, so deleting the
  # script removes a line from the output and nothing else. The file existing and
  # the contract holding are different claims, and only the second one is worth
  # anything here.
  #
  # What it checks per Dockerfile, because each of the three is a way this has
  # silently stopped being true:
  #
  #   1. the final `ENTRYPOINT` names the entrypoint script. A template edited
  #      back to a bare `ENTRYPOINT ["/app/service"]` is exactly the regression
  #      this packet exists to reverse, and it is a one-line diff that looks like
  #      tidying.
  #   2. the final `ENTRYPOINT` still carries the SERVICE command after the
  #      script. An `ENTRYPOINT` that ends at the script execs nothing; the
  #      script refuses to start with no arguments, so the container crash-loops
  #      on a perfectly good image.
  #   3. the script itself is present, so (1) cannot be satisfied by a name.
  #
  # Read as text with a regex, not with a Dockerfile parser, for the reason
  # `docker_rules` gives two paragraphs earlier: these templates use ARG
  # interpolation, so the claim is about the shape of the last ENTRYPOINT, not
  # about a resolved image reference.
  section 'static: every image starts through the migration entrypoint'
  check 'docker/Dockerfile.*  (ENTRYPOINT migrates, then execs the service)' docker_entrypoint

  # -------------------------------------------------------------------------
  # AGENTS.md: "Half a language is worse than none." The whole point of kit is
  # that six repos get the same thing, so a language that has a CI job but no
  # primer is worse than a language kit does not claim to support: the first is
  # a service that adopts kit and finds a step missing, silently.
  #
  # One list, checked four ways, so adding a language is one edit that fails
  # until the other three artifacts exist.
  section 'static: every language ships all four artifacts'
  kit_languages() {
    # Kept in step with ci_check's `languages` list below. Both read the CI
    # workflow's `language` gate job -- the case statement that rejects an
    # unrecognised value -- so there is exactly one place to add a language and
    # the workflow cannot claim one the tree does not have.
    #
    # It USED to read the `options:` list under the input. That key is not
    # legal under `workflow_call`; GitHub rejected the whole file, and every
    # check that read it was reading a key the file was not allowed to carry.
    # The gate job's case statement is where the enumeration actually lives now,
    # so it is what everything reads.
    #
    # `$2` is the option that means "no language" and so ships no artifacts.
    # It is skipped here rather than being special-cased out of the workflow,
    # because a hardcoded name in two places is exactly how the two drift.
    #
    # The path arrives as argv[3] rather than being written out again here: a
    # second copy of this string is a second thing to forget to move.
    "$PY" - "$ROOT" "$CONFIG_ONLY" "$WORKFLOW" <<'PY'
import re
import sys

import yaml

skip = sys.argv[2]
with open(sys.argv[3], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
jobs = doc.get("jobs") or {}
script = "\n".join(
    str(s.get("run") or "") for s in ((jobs.get("language") or {}).get("steps") or [])
    if isinstance(s, dict)
)
# One case arm per language: `go|ruby|...)` on its own line. Reading the
# enumeration from the thing that enforces it is the point -- a list that lives
# only in a check is a list nothing enforces.
#
# An EMPTY enumeration is an error here, not an empty result. Every caller of
# this function loops over what it prints, so a gate job that was renamed or
# deleted would turn four checks into four silent passes -- the exact way this
# file used to lose a signal. A check that could not ask its question says so.
found = [
    name
    for arm in re.findall(r"^\s*([a-z|]+)\)\s*$", script, re.M)
    for name in arm.split("|")
    if name and name != skip
]
if not found:
    sys.exit(
        "the reusable workflow has no `language` gate job naming any language, "
        "so no language artefact can be checked. Reading zero languages is not "
        "the same as there being none"
    )
for name in found:
    print(name)
PY
  }

  # The consumers below loop over this function's output, so an empty output is
  # an empty loop and an empty loop is a silent pass. `kit_languages` exits
  # non-zero in that case, and that is reported rather than swallowed.
  _kit_langs="$(kit_languages)" ||
    report FAIL "every language  (the language list could not be read at all)"
  if [ -n "$_kit_langs" ]; then
    while IFS= read -r lang; do
      [ -n "$lang" ] || continue
      if otel_required "docker/Dockerfile.$lang" "templates/bin-prime/$lang.sh"; then
        report PASS "$lang  (Dockerfile + bin/prime present)"
      else
        report FAIL "$lang  (Dockerfile + bin/prime present)"
      fi
    done <<<"$_kit_langs"
  fi

  # mise.toml pins every language too. Checked by parsing the TOML rather than
  # grepping, so a key that appears in a comment does not count as a pin — a
  # check that can be satisfied by a comment is not a check.
  mise_check() {
    "$PY" - "$ROOT" "$CONFIG_ONLY" "$WORKFLOW" <<'PY'
import re
import sys

root = sys.argv[1]
config_only = sys.argv[2]
with open(sys.argv[3], encoding="utf-8") as fh:
    import yaml

    doc = yaml.safe_load(fh)
# The language gate job's case statement is where the enumeration lives. It
# used to be an `options:` list under the `workflow_call` input, which is not a
# legal key there -- GitHub refused the entire file, and these checks were
# reading a key the file was not allowed to carry.
jobs = doc.get("jobs") or {}
gate = "\n".join(
    str(s.get("run") or "")
    for s in ((jobs.get("language") or {}).get("steps") or [])
    if isinstance(s, dict)
)
langs = [
    name
    for arm in re.findall(r"^\s*([a-z|]+)\)\s*$", gate, re.M)
    for name in arm.split("|")
    if name and name != config_only
]
if not langs:
    problems.append(
        "the reusable workflow's `language` gate job names no language, so this "
        "check could not ask its question. Reading zero languages is not the "
        "same as there being none"
    )

source = open(f"{root}/templates/mise.toml", encoding="utf-8").read()
# Only the [tools] table, and only its own lines: a version mentioned in a
# comment above the table is documentation, not a pin.
table = re.split(r"^\[", source, flags=re.M)
tools = ""
for chunk in table:
    if chunk.startswith("tools]"):
        tools = chunk
        break

problems = []
if not tools:
    problems.append("templates/mise.toml has no [tools] table")
else:
    for lang in langs:
        if not re.search(rf'^\s*"?{re.escape(lang)}"?\s*=\s*\S', tools, flags=re.M):
            problems.append(f"templates/mise.toml pins no version for {lang}")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/mise.toml  (a [tools] pin per language)' mise_check

  # -------------------------------------------------------------------------
  section 'static: compose — the observability chokepoint'
  # Privacy boundary, enforced. REWRITTEN in kit-03, and the change is recorded
  # here rather than smuggled. The boundary used to be "the only exporter is
  # `debug`, which cannot leave the machine". Observability being ON BY DEFAULT
  # (PLAN.md §7b) means the shipped collector now fans out to Tempo, Loki and
  # Mimir, so "ships nothing" is no longer the claim this file can make.
  #
  # The claim that CAN be made, and is asserted on the parsed document:
  #
  #   1. every exporter endpoint is a ${env:...} substitution, never a literal.
  #      A literal endpoint is an endpoint some laptop will use by default, and
  #      it is the one shape that turns a privacy boundary into an incident.
  #   2. every pipeline runs a redaction processor, BEFORE batch and therefore
  #      before every exporter. Filter before export, never after: a redaction
  #      step that runs after an exporter has already handed the data off is a
  #      comment, and the comment is what a future reader trusts.
  #   3. the exporter set is exactly the three backends plus the local `debug`.
  #
  # (1) is kit-02's rule and is unchanged. (2) and (3) are new, and (3) is why
  # a self-hoster's bring-your-own backend is a variable they set rather than an
  # exporter a reviewer has to read: <SERVICE>_OTEL_ENDPOINT points their service
  # somewhere else entirely and this stack goes quiet.
  collector_check() {
    "$PY" - "$ROOT" <<'PY'
import re
import sys

import yaml

root = sys.argv[1]
path = f"{root}/templates/compose/otel-collector.yml"
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)

problems = []

pipelines = (doc.get("service") or {}).get("pipelines") or {}
if not pipelines:
    problems.append("no service.pipelines in the collector config")

exporters = doc.get("exporters") or {}
for name, cfg in exporters.items():
    if not isinstance(cfg, dict):
        continue
    for key in ("endpoint", "traces_endpoint", "metrics_endpoint", "logs_endpoint"):
        value = cfg.get(key)
        if isinstance(value, str) and "${env:" not in value:
            problems.append(f"exporter {name}.{key} is a literal endpoint, not an ${{env:}} substitution")

# The shipped stack is EXACTLY the two backends plus the local `debug`. Anything
# else is an exporter a reviewer did not read, and `otlp` with a *defaulted*
# endpoint is the exact shape of that mistake.
#
# The backend set and the component type are asserted SEPARATELY, and the second
# one was wrong as first written. This check originally pinned the literal set
# {"otlp/tempo", "otlp/loki", "otlp/mimir", "debug"} — all three gRPC — and went
# red against a correct config, because the three backends do NOT agree on wire
# protocol: Tempo accepts OTLP over gRPC on :4317, while Loki's and Mimir's native
# OTLP receivers are HTTP-only, mounted at `/otlp` on :3100 and :8080. A gRPC
# exporter pointed at either of them fails to connect, which is a broken stack
# that still satisfies "the only exporter is debug".
#
# So the claim under test is "these backends and nothing else", and the
# transport is a property of the backend rather than part of the name. Asserting
# `(otlp|otlphttp)/<one of the two>` keeps that claim exactly as tight while
# letting each backend be spoken to in the dialect it speaks.
#
# THE THIRD NAME LEFT WITH THE THIRD STORE. There was a metrics backend here,
# and it cost 130s of readiness budget per cold start (retries 12 x interval 10s)
# against a 180s deadline for the whole stack, so it was removed rather than left
# half-removed. Dropping its name from this tuple is the check following the tree
# out; the tuple is a CLOSED set either way, so an exporter for a store that does
# not exist is still `unexpected exporter(s)` and one added to the tree has to be
# added here too, in the same commit, or this goes red.
BACKENDS = {"tempo", "loki"}
unknown = []
for name in exporters:
    if name == "debug":
        continue
    kind, sep, backend = name.partition("/")
    if not sep or kind not in ("otlp", "otlphttp") or backend not in BACKENDS:
        unknown.append(name)
if unknown:
    problems.append(
        "unexpected exporter(s): "
        + ", ".join(unknown)
        + " — the shipped stack is tempo, loki and the local debug. A "
        "bring-your-own backend is an ${env:} endpoint, never a new exporter."
    )

# ...and the converse, which the literal set above never checked. A config whose
# exporters are only `debug` satisfies "nothing unexpected" while shipping no
# observability at all, so a check written as a set difference alone passes on a
# stack that collects everything and prints it. Asserted per signal below that
# every pipeline has exporters, but that is a different claim: a pipeline can
# point at `debug` alone and still be a pipeline. This is the one that says the
# backends are actually wired.
for backend in sorted(BACKENDS):
    if not any(n.partition("/")[2] == backend for n in exporters):
        problems.append(
            f"no exporter for {backend}: the shipped stack is two backends, and a "
            "config with only `debug` is a stack that collects everything and "
            "prints it rather than storing it"
        )

# The ordering, per pipeline. "The config has a redaction processor somewhere"
# is exactly the check that passes while the metrics pipeline ships unredacted,
# so the assertion is per pipeline and positional.
for signal, pipe in pipelines.items():
    if not isinstance(pipe, dict):
        continue
    if not pipe.get("receivers"):
        problems.append(f"{signal} pipeline has no receivers")
    raw = pipe.get("processors") or []
    if "memory_limiter" not in raw:
        problems.append(f"{signal} pipeline has no memory_limiter")
    elif raw[0] != "memory_limiter":
        problems.append(
            f"{signal} pipeline starts with {raw[0]!r}, not memory_limiter"
        )
    if "batch" not in raw:
        problems.append(f"{signal} pipeline has no batch processor")
    redactions = [i for i, p in enumerate(raw) if p.startswith("redaction/")]
    if not redactions:
        problems.append(
            f"{signal} pipeline has no redaction processor: a signal with no "
            f"boundary reads as a signal that has one"
        )
    if redactions and "batch" in raw and min(redactions) > raw.index("batch"):
        problems.append(
            f"{signal} pipeline redacts after batching, which is after the data "
            f"has already left the process"
        )
    # 3. SPAN EVENTS ARE OUT OF REACH. The redaction processor is specified over
    #    span/log/datapoint ATTRIBUTES; a span event carries its own attribute map
    #    at a different depth which it does not visit. So a service still writing
    #    the DEPRECATED `exception` span event ships `exception.message` and
    #    `exception.stacktrace` straight through a boundary with neither on its
    #    allowlist. Found by the canary test failing, not by reading the docs.
    if signal == "traces" and not any("span_event" in p for p in raw):
        problems.append(
            "the traces pipeline has no span-event transform, so exception.message "
            "and exception.stacktrace on a span EVENT bypass the redaction "
            "processor entirely — it does not visit event attributes"
        )
    if not pipe.get("exporters"):
        problems.append(f"{signal} pipeline has no exporters: it collects and drops")

# All three signals. Traces and metrics without logs means no crash layer, and
# logs without metrics means a log store nobody has a dashboard for.
for signal in ("traces", "metrics", "logs"):
    if signal not in pipelines:
        problems.append(f"no {signal} pipeline: the stack is a partial observability story")

# PER-SIGNAL WIRING, which is a different claim from the backend tuple above.
# The tuple answers "no exporter for a store the tree ships"; this answers "and
# the signal that store answers is the one actually pointed at it". Without it a
# config can hold `otlp/tempo` somewhere on the traces pipeline, leave `debug`
# alone on the pipeline that matters, and be green on both counts above.
#
# The METRICS half is the new one and it is the negative, which is the point.
# There is no metrics store, so the metrics pipeline exports to `debug` and to
# NOTHING ELSE — and this assertion is what makes the removal of that store
# load-bearing rather than aspirational. The failure it names is the one that
# actually happens: somebody re-adds the endpoint variable to .env.example to
# "put metrics back" and leaves the exporter too, and the stack then flushes to
# a host with nothing on it once every 15s for the life of the process, in a log
# nobody reads, while `up --wait` reports the stack healthy. Putting a store back
# is four edits and they belong together — see `otel-collector.yml`.
WIRING = {"traces": "tempo", "logs": "loki"}
for signal, backend in sorted(WIRING.items()):
    pipe = pipelines.get(signal)
    if not isinstance(pipe, dict):
        continue
    names = [str(e) for e in (pipe.get("exporters") or [])]
    if not any(n.partition("/")[2] == backend for n in names):
        problems.append(
            f"the {signal} pipeline exports to {names} and not to the {backend} "
            f"store: an exporter nobody reads is the same as no exporter, and a "
            f"panel over {backend} that renders empty teaches a reader that empty "
            f"means no traffic"
        )

metrics_pipe = pipelines.get("metrics")
if isinstance(metrics_pipe, dict):
    stored = [
        str(e) for e in (metrics_pipe.get("exporters") or []) if str(e) != "debug"
    ]
    if stored:
        problems.append(
            "the metrics pipeline exports to "
            + ", ".join(stored)
            + ": there is no metrics store in this stack. Span metrics are "
            "derived and redacted and go to `debug` (this process's own stdout). "
            "An exporter pointed at a host with nothing behind it is a connection "
            "refused per flush, forever, in a log nobody reads — the half-removed "
            "backend this file will not ship. Restoring a store is four edits and "
            "they belong together: the endpoint variable in .env.example, the "
            "exporter block in otel-collector.yml, the `exporters:` line on this "
            "pipeline, the compose service, and the datasource"
        )

# No literal URL anywhere outside a comment: an endpoint that is not an
# ${env:...} substitution is an endpoint somebody's laptop will use by default.
source = open(path, encoding="utf-8").read()
stripped = "\n".join(line.split("#", 1)[0] for line in source.splitlines())
for url in re.findall(r"https?://[^\s\"']+", stripped):
    problems.append(f"literal URL in collector config: {url}")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/compose/otel-collector.yml  (redaction first, env endpoints, no URL)' collector_check

  # -------------------------------------------------------------------------
  # THE REDACTION BOUNDARY, DERIVED FROM core's SCHEMAS.
  #
  # This is the check that makes "kit's collector is the enforcement point" a
  # fact rather than an intention. core owns the allowlist
  # (schemas/telemetry/traces.schema.json, metrics.schema.json, logs.schema.json
  # and redaction.schema.json); this repo's collector config is supposed to be a
  # projection of it. A projection that disagrees is not a style difference: it
  # is either an attribute core says may not be recorded, shipping anyway, or an
  # attribute a service is allowed to record being dropped on the floor.
  #
  # The comparison is BIDIRECTIONAL on purpose, and that is the part worth
  # defending:
  #
  #   core -> kit   every attribute name core allows on a signal appears in that
  #                 signal's `redaction/*` allowed_keys. A missing one is a
  #                 silently-attribute-less span, which is the failure nobody
  #                 notices because the span still arrives.
  #   kit -> core   every name in allowed_keys is either on core's list for that
  #                 signal or on core's fleet-wide redaction allowlist, and
  #                 carries no word core's schema forbids. An extra one is a
  #                 leak with a check attached to it.
  #
  # One direction would be a check that passes on an empty allowlist. Both
  # directions together is a check that fails on a wrong one.
  #
  # A DERIVED rather than a hand-maintained claim: the comparison is computed
  # from core's files on disk at gate time, so the day core changes an allowlist
  # the gate goes red here and names the name. The resolved core commit is
  # printed, because "it passed" against a spec from six weeks ago is not the
  # same statement as "it passed".
  #
  # core is a sibling checkout, not a vendored copy (AGENTS.md: `../core` is a
  # read-only reference; kit does not depend on it). When it is absent this
  # check SKIPs loudly and the summary says so — a security check that is
  # silently absent is worse than one that is loudly absent, and hiding the skip
  # is what makes it silently absent.
  core_repo() {
    local cand
    if [ -n "${KIT_CORE:-}" ]; then
      printf '%s' "$KIT_CORE"
      return 0
    fi
    for cand in "$ROOT/../core" "$ROOT/../../core" "$ROOT/../cafaye/core"; do
      if [ -f "$cand/schemas/telemetry/traces.schema.json" ]; then
        (cd "$cand" && pwd)
        return 0
      fi
    done
    return 1
  }

  core_check() {
    local core
    core="$(core_repo)" || {
      echo "core not found: set KIT_CORE=<path to a core checkout>"
      return 1
    }
    "$PY" - "$ROOT" "$core" <<'PY'
import json
import os
import re
import subprocess
import sys

root, core = sys.argv[1], sys.argv[2]

def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def core_commit(path):
    try:
        return subprocess.run(
            ["git", "-C", path, "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except Exception:
        return "unknown"


sch = f"{core}/schemas/telemetry"
traces = load(f"{sch}/traces.schema.json")
metrics = load(f"{sch}/metrics.schema.json")
logs = load(f"{sch}/logs.schema.json")
redaction = load(f"{core}/examples/valid/telemetry/redaction.json")

# core's per-signal attribute sets, read out of the schemas rather than
# transcribed here. A transcription is a second copy of a contract, and the
# whole point of this check is that there is only one.
core_traces = set(traces["$defs"]["tracesAttributes"]["properties"])
core_metrics = set(metrics["$defs"]["measurementAttributes"]["properties"])
core_logs = set(logs["$defs"]["logsAttributes"]["properties"])
core_resource = set(traces["$defs"]["resource"]["properties"])
core_fleet = set(redaction["allowed"])
core_prohibited = set(redaction.get("prohibited", []))
# The content-word vocabulary is a `not.pattern` list inside
# redaction.schema.json, not prose. Read it out of the schema itself so the
# vocabulary this check enforces is core's and cannot drift from it.
rs = load(f"{sch}/redaction.schema.json")
# core writes each pattern as `(?i)word`. Concatenated as-is they would be
# `(?i)a|(?i)b`, and Python rejects a global flag anywhere but position 0 — so
# the flag is stripped and applied once, which is also what it means.
core_content_words = [
    re.sub(r"^\(\?i\)", "", p["pattern"])
    for p in rs["properties"]["allowed"]["items"]["not"]["anyOf"]
    if "pattern" in p
]
content_re = re.compile("|".join(f"(?:{w})" for w in core_content_words), re.I)

import yaml

with open(f"{root}/templates/compose/otel-collector.yml", encoding="utf-8") as fh:
    col = yaml.safe_load(fh)

problems = []
# The per-signal allowlists, and the pipelines that carry each signal.
allowed = {
    name.rsplit("/", 1)[-1].replace("cafaye_", ""): set(cfg.get("allowed_keys") or [])
    for name, cfg in (col.get("processors") or {}).items()
    if name.startswith("redaction/")
}
expected = {"traces": core_traces, "metrics": core_metrics, "logs": core_logs}
for signal, core_set in expected.items():
    got = allowed.get(signal)
    if got is None:
        problems.append(f"no redaction/cafaye_{signal} processor: signal is not allowlisted")
        continue
    missing = sorted(core_set - got)
    if missing:
        problems.append(
            f"redaction/cafaye_{signal} drops attributes core allows on {signal}: "
            + ", ".join(missing)
        )
    extra = sorted(got - core_set)
    if extra:
        # An extra name is only legitimate if core's fleet-wide redaction
        # allowlist carries it — that is the `llm.*` half, which core's
        # redaction schema allows and whose absence from the per-signal schema
        # is core's own gap (raised in kit's report as a DECISION NEEDED).
        unbacked = [n for n in extra if n not in core_fleet]
        if unbacked:
            problems.append(
                f"redaction/cafaye_{signal} allows attributes core does not: "
                + ", ".join(unbacked)
            )
    for name in sorted(got):
        if content_re.search(name):
            problems.append(
                f"redaction/cafaye_{signal} allows {name!r}, whose name contains a "
                f"word core's redaction schema forbids on an allowed name"
            )
    for name in sorted(got & core_prohibited):
        problems.append(
            f"redaction/cafaye_{signal} allows {name!r}, which core's redaction "
            f"schema names as prohibited"
        )

# The three signals must all be present. Two of three is a partial boundary and
# a partial boundary reads as a whole one.
if sorted(allowed) != ["logs", "metrics", "traces"]:
    problems.append(f"redaction processors are {sorted(allowed)}; a signal with no boundary reads as one with")

# `allow_all_keys: true` disables the allowlist entirely while still looking
# configured. It is the single most dangerous line in the file and it is worth
# its own check rather than a footnote.
for name, cfg in (col.get("processors") or {}).items():
    if name.startswith("redaction/") and cfg.get("allow_all_keys") is not False:
        problems.append(
            f"{name}: allow_all_keys must be explicitly false — true disables the "
            f"allowlist while still looking configured"
        )

# A resource attribute is NOT a span attribute. core's whole cardinality
# argument is that identity lives on the resource and is exempt from the 2000
# cap; a resource name smuggled into allowed_keys is identity moved back onto
# the measurement. core asserts the two lists are disjoint, and so does this.
resource_leaks = sorted((allowed.get("metrics") or set()) & core_resource)
if resource_leaks:
    problems.append(
        "redaction/cafaye_metrics allows resource attributes as measurement "
        "attributes: " + ", ".join(resource_leaks)
    )

# THE RESOURCE EXEMPTION, and this check is the reason the config carries a
# stash/restore pair at all.
#
# The redaction processor's `allowed_keys` and `ignored_keys` are BOTH flat
# lists, and they are applied to resource attributes and measurement attributes
# by the same rule - so `ignored_keys: [tenant_id]` exempts the resource AND
# every data point, and the data point is exactly what core's metrics schema
# prohibits. Verified against the pinned image rather than assumed, because this
# is the one place an assumption is completely invisible: the pipeline runs, the
# dashboard renders, and the breakdown quietly undercounts.
#
# WHICH resource attributes can safely go in `ignored_keys` is DERIVED from
# core, not declared here. A name is safe exactly when core does not also list it
# on a signal's allowlist. `service.name` qualifies: it is never a measurement
# attribute, so exempting it cannot weaken the metrics boundary. `tenant_id` and
# `account_id` are the names core puts in BOTH places, and they are the ones
# that have to go through the stash.
#
# Four things are asserted, and (2) and (3) are the ones that stop the exemption
# being the bug:
#   1. every resource attribute core defines is either safely ignorable or
#      stashed - otherwise it is stripped and the per-tenant totals are lost;
#   2. no name core lists on BOTH a resource and a signal allowlist appears in
#      ignored_keys - that single entry is what exempts a data point too;
#   3. an ignored name core does not define anywhere is reported, because an
#      exemption nobody reasoned about is how a prohibited identifier gets back
#      onto a measurement in six months;
#   4. the stash/restore bracket the redaction processor, positionally.
pipelines = (col.get("service") or {}).get("pipelines") or {}

# The names that are BOTH a resource attribute and PROHIBITED on a measurement,
# read out of the `not` clause core already wrote for exactly this purpose.
#
# The first version derived this as "appears in the resource schema AND in any
# signal's allowlist", and that put `service.name` in the set — because core's
# log schema permits `service.name` as an ATTRIBUTE (a log store fanning several
# services into one stream needs it as a label). Which is not the hazard at all.
# The hazard is a name core REFUSES on a measurement, and core refuses those by
# name in a `not` clause: tenant_id, user_id, account_id, request_id, trace_id,
# span_id, session_id, message_id, notification_id, email, error.message,
# error.stacktrace, url.full, url.path. Read from there, so the answer is core's
# list rather than an inference from file layout.
prohibited_on_measurement = set()
for clause in metrics["$defs"]["measurementAttributes"]["not"]["anyOf"]:
    for key in clause.get("required", []):
        prohibited_on_measurement.add(key)
both_places = core_resource & prohibited_on_measurement

# The stash is read out of the config's OWN transform statements rather than
# assumed to cover a fixed list, so a stash that stops handling `account_id`
# fails here instead of quietly stripping it.
stash_src = ""
for cfg in (col.get("processors") or {}).values():
    if not isinstance(cfg, dict):
        continue
    for key in ("trace_statements", "log_statements", "metric_statements"):
        for group in cfg.get(key) or []:
            stash_src += " ".join(str(s) for s in (group or {}).get("statements") or [])
stashed = {name for name in both_places if f'attributes["{name}"]' in stash_src}
# `cafaye.stashed.<name>` is a PRIVATE name this config invents, and it is the
# one entry in ignored_keys that core has never heard of. It is allowed, and
# only because the stash/restore pair is asserted to bracket the redaction
# processor below and the restore deletes it — a private name that outlived the
# restore would be an attribute in every export, and the unknown-ignored-keys
# check below would otherwise (correctly) report it.
private_stash = {f"cafaye.stashed.{n}" for n in both_places}

for signal in ("traces", "metrics", "logs"):
    proc = f"redaction/cafaye_{signal}"
    cfg = (col.get("processors") or {}).get(proc) or {}
    ignored = set(cfg.get("ignored_keys") or [])

    missing = sorted(core_resource - ignored - stashed)
    if missing:
        problems.append(
            f"{proc}: resource attributes core defines are neither ignored nor "
            f"stashed, so they are stripped: {', '.join(missing)}. Strip "
            f"service.name and the fleet dashboard has nothing to partition by; "
            f"strip tenant_id and the per-tenant totals core requires are lost, "
            f"silently."
        )
    if not stashed:
        problems.append(
            f"{proc}: no resource attribute core PROHIBITS on a measurement is "
            f"stashed, so tenant_id/account_id are either stripped from every "
            f"resource or exempted on every data point. core's metrics schema "
            f"requires the first to happen not to and the second not to happen "
            f"at all."
        )
    both_in_ignored = sorted(ignored & both_places)
    if both_in_ignored:
        problems.append(
            f"{proc}: ignored_keys contains {', '.join(both_in_ignored)}, which "
            f"core lists as a resource attribute AND as a prohibited measurement "
            f"attribute. ignored_keys is one flat list applied to both, so this "
            f"exempts the data point too - the cardinality bomb core's metrics "
            f"schema exists to prevent. Use the stash/restore pair instead."
        )
    unknown = sorted(ignored - core_resource - private_stash)
    if unknown:
        problems.append(
            f"{proc}: ignored_keys names {', '.join(unknown)}, which core's "
            f"resource schema does not define. An exemption nobody reasoned "
            f"about is how a prohibited identifier gets back onto a measurement."
        )

    # THE CARRIER HAS TO SURVIVE THE PROCESSOR THAT READS IT, and this is the
    # check that says so. Being *stashed* is not the same as being *exempted*:
    # the stash writes `cafaye.stashed.tenant_id`, the redaction processor
    # deletes every attribute it does not exempt, and the restore then reads a
    # name that no longer exists. The pipeline runs, the trace arrives, the
    # dashboard renders — and every trace is missing the tenant_id on its
    # resource, which is per-tenant totals core's metrics schema exists to
    # produce.
    #
    # The three processors are one idea written out three times, and they had
    # drifted: metrics carried the private names and traces and logs did not.
    # The consequence was that the metric view had per-tenant totals and the
    # trace and log views silently did not. Found by running the stack and
    # reading a span back out of Tempo — every other check passed, because from
    # the config alone `tenant_id` genuinely is stashed.
    unexempted = sorted(private_stash - ignored)
    if unexempted:
        problems.append(
            f"{proc}: ignored_keys is missing {', '.join(unexempted)}, which is "
            f"the carrier the stash writes and the restore reads. The redaction "
            f"processor DELETES every attribute it does not exempt, so the stash "
            f"is undone before the restore can act on it: tenant_id and "
            f"account_id arrive on no resource at all, silently, while the "
            f"pipeline reports success."
        )

# ...and the three lists must agree, because three hand-copied lists are three
# places for one of them to drift. Equality across all three, reported against
# the union so the message names what is missing and what is extra without
# having to first work out which of the three is the odd one out — and without
# that subtlety, since picking a reference list to compare against is exactly
# how a check like this comes to ignore the very case it was added for.
_ignored_by_signal = {
    signal: set(
        ((col.get("processors") or {}).get(f"redaction/cafaye_{signal}") or {}).get(
            "ignored_keys"
        )
        or []
    )
    for signal in ("traces", "metrics", "logs")
}
_union = set().union(*_ignored_by_signal.values())
_intersection = set.intersection(*_ignored_by_signal.values())
if _union != _intersection:
    detail = "; ".join(
        f"{signal} {'lacks' + repr(sorted(_union - keys)) if _union - keys else 'extras' + repr(sorted(keys - _union))}"
        for signal, keys in sorted(_ignored_by_signal.items())
        if keys != _union
    )
    problems.append(
        f"the three redaction processors disagree on ignored_keys: {detail}. All "
        "three signals get the same resource exemption; one of them drifting is "
        "how a signal ends up quietly partitioned differently from the other two, "
        "which is the bug this assertion was added for."
    )

# The stash and the restore must bracket the redaction processor in EVERY
# pipeline, in that order. Checked positionally, because a pipeline that
# restores first is a pipeline that exports the private name.
for signal, pipe in pipelines.items():
    procs = pipe.get("processors") or []
    try:
        stash = procs.index("transform/cafaye_resource_stash")
        restore = procs.index("transform/cafaye_resource_restore")
        # Named `boundary_at`, not `redaction`: `redaction` is the loaded
        # core policy document, and shadowing it with an integer means the
        # summary line at the end of this script dies with a TypeError on
        # `redaction['version']` — after every check has already reported. A
        # check whose failure mode is a traceback is a check that reports the
        # wrong thing at the worst possible moment.
        boundary_at = next(i for i, p in enumerate(procs) if p.startswith("redaction/"))
    except (ValueError, StopIteration):
        problems.append(
            f"{signal} pipeline: the resource stash/restore pair is missing or "
            f"incomplete — without it, tenant_id is stripped from the resource"
        )
        continue
    if not (stash < boundary_at < restore):
        problems.append(
            f"{signal} pipeline: order is {procs}. It must be stash < redaction < "
            f"restore; the other way round exports the private stash name instead "
            f"of tenant_id."
        )

# Every spanmetrics dimension is a trace attribute the allowlist keeps. A
# dimension the redaction processor has already stripped produces a metric with
# an always-empty label: a dashboard column that is permanently blank, which
# looks like "no traffic" and is really "your filter ran first".
conn = (col.get("connectors") or {}).get("spanmetrics") or {}
for dim in conn.get("dimensions") or []:
    name = dim.get("name") if isinstance(dim, dict) else dim
    if name not in (allowed.get("traces") or set()):
        problems.append(
            f"spanmetrics dimension {name!r} is not in redaction/cafaye_traces' "
            f"allowed_keys, so the metric's label will always be empty"
        )

commit = core_commit(core)
if problems:
    sys.exit("; ".join(problems))
print(f"derived from core@{commit} (spec {redaction['version']})")
PY
  }
  if core_repo >/dev/null 2>&1; then
    check 'otel-collector allowlist  (derived from core schemas/telemetry)' core_check
  else
    report SKIP 'otel-collector allowlist vs core (core checkout not found — set KIT_CORE)'
  fi

  # exceptions-as-logs. PLAN.md §7b and the semconv: the `exception` span-event
  # convention is Deprecated, the replacement is an exception LOG RECORD, and
  # the switch is OTEL_SEMCONV_EXCEPTION_SIGNAL_OPT_IN=logs. The collector half
  # of that is: the spanmetrics connector must not mint the deprecated
  # exceptions counter, and there must be a logs pipeline for the record to
  # arrive on. Checked, because "we migrated" is a claim and a connector that
  # still counts span events is a migration that did not happen.
  exception_signal_check() {
    "$PY" - "$ROOT" <<'PY'
import sys

import yaml

root = sys.argv[1]
with open(f"{root}/templates/compose/otel-collector.yml", encoding="utf-8") as fh:
    col = yaml.safe_load(fh)

problems = []
conn = (col.get("connectors") or {}).get("spanmetrics") or {}
events = conn.get("events")
if not isinstance(events, dict) or events.get("enabled") is not False:
    problems.append(
        "spanmetrics events.enabled must be explicitly false: the `exceptions` "
        "counter it mints is the DEPRECATED exception span-event convention, and "
        "the replacement is an exception log record on the logs pipeline"
    )

pipelines = ((col.get("service") or {}).get("pipelines") or {})
logs = pipelines.get("logs") or {}
if not logs.get("receivers"):
    problems.append(
        "no logs pipeline, so there is nowhere for an exception log record to "
        "arrive — migrating from span events to logs means having the logs half"
    )
if not logs.get("exporters"):
    problems.append("no logs exporter: the crash layer would be collected and dropped")

# The signal that receives exceptions has to receive them from somewhere other
# than a span. `otlp` is how an SDK sends a log record; `syslog`/`filelog` is
# how a container's stderr becomes one with no per-language SDK (PLAN.md §7b
# layer 2). Neither alone is the whole contract.
if "otlp" not in (logs.get("receivers") or []):
    problems.append("the logs pipeline does not receive otlp, so an SDK cannot send an exception log record")
if not any(r.startswith(("syslog", "filelog")) for r in (logs.get("receivers") or [])):
    problems.append(
        "the logs pipeline tails no container stdout/stderr, so PLAN.md §7b's "
        "zero-SDK crash layer is not implemented"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'otel-collector signals  (exceptions as logs, not span events)' exception_signal_check

  # No buffering, no retry, no warning storm. Same three properties core's
  # otel-endpoint.schema.json pins to `none` for a service's own SDK, asserted
  # here for the collector that every service exports into. A queue with
  # retry_on_failure is a background thread waking on a timer for the life of
  # the process while Tempo is down, and it is invisible in every dashboard
  # because nothing is being recorded.
  degrade_honestly_check() {
    "$PY" - "$ROOT" <<'PY'
import sys

import yaml

root = sys.argv[1]
with open(f"{root}/templates/compose/otel-collector.yml", encoding="utf-8") as fh:
    col = yaml.safe_load(fh)

problems = []
for name, cfg in (col.get("exporters") or {}).items():
    cfg = cfg or {}
    queue = cfg.get("sending_queue")
    if isinstance(queue, dict) and queue.get("enabled") is not False:
        problems.append(
            f"exporter {name}: sending_queue must be explicitly disabled — a queue "
            f"that accepts spans while Tempo is down is a memory leak with a "
            f"telemetry-shaped trigger"
        )
    retry = cfg.get("retry_on_failure")
    if isinstance(retry, dict) and retry.get("enabled") is not False:
        problems.append(
            f"exporter {name}: retry_on_failure must be explicitly disabled — a "
            f"retry loop against a dead endpoint is a thread waking on a timer "
            f"for the life of the process"
        )

pipelines = ((col.get("service") or {}).get("pipelines") or {})
for signal, pipe in pipelines.items():
    procs = pipe.get("processors") or []
    if procs and procs[0] != "memory_limiter":
        problems.append(
            f"{signal} pipeline starts with {procs[0]!r}, not memory_limiter: "
            f"without a limiter a runaway service takes the collector down and "
            f"every other service loses its telemetry at the same moment"
        )

if not ((col.get("extensions") or {}).get("health_check")):
    problems.append(
        "no health_check extension, so the compose healthcheck has nothing real "
        "to probe and `up --wait` cannot mean anything"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'otel-collector degradation  (no queue, no retry, limiter first, health_check)' degrade_honestly_check

  compose_check() {
    "$PY" - "$ROOT" <<'PY'
import re
import sys

import yaml

root = sys.argv[1]
path = f"{root}/templates/compose/docker-compose.yml"
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)

problems = []
services = doc.get("services") or {}
if not services:
    problems.append("no services")

# The shared infra every cafaye service joins. Half a platform is worse than
# none: a service that adopts the stack needs all of these or none of them.
# The three backing services are in the required set because the observability
# PROFILE exists so a constrained machine can opt out, and the profile is the
# explicit spelling rather than the default: `bin/dev up` alone brings up
# postgres, nats, redis and the collector, and `KIT_DEV_PROFILES=observability
# bin/dev up` brings up the stores too. The check that the profile and the
# default AGREE is `dev_escape_hatch_check`, which executes bin/dev with the
# variable empty; the one that the backends are inside the profile at all is
# `backing_check` below. They are required HERE so that deleting a store cannot
# be half-done: a service that adopts the stack and loses one of them finds out.
#
# It was four. There was a metrics backend here, and it cost 130s of readiness
# budget per cold start against a 180s deadline for the whole stack, so it went
# with its volume, its port and its collector exporter rather than being left
# half-wired. A name added to this tuple without a service behind it is a red
# gate, which is the point.
for required in ("postgres", "nats", "redis", "otel-collector", "tempo", "loki", "grafana"):
    if required not in services:
        problems.append(f"missing service: {required}")

for name, svc in services.items():
    image = svc.get("image")
    if not image:
        problems.append(f"{name}: no image")
        continue
    tag = image.rsplit(":", 1)[-1] if ":" in image.rsplit("/", 1)[-1] else ""
    if tag in ("", "latest"):
        problems.append(f"{name}: image is unpinned ({image})")
    # Health, or `docker compose up --wait` cannot mean anything.
    if "healthcheck" not in svc:
        problems.append(f"{name}: no healthcheck, so `up --wait` cannot gate on it")

# Every published port is a ${KIT_*} substitution. A literal host port in this
# file is a port collision waiting for the second service a developer runs.
#
# Read from the PARSED document's `ports:` lists rather than by grepping lines.
# A line-based scan flags anything shaped like `host:container`, which includes
# the collector's bind addresses (`0.0.0.0:4317` under `environment:`) — those
# are endpoints inside the network, not published ports, and a check that cannot
# tell the two apart is a check everyone learns to ignore.
published = []
for name, svc in services.items():
    for entry in (svc or {}).get("ports") or []:
        if isinstance(entry, dict):
            # long form: {target: 5432, published: "5432"}
            host = str(entry.get("published", ""))
            target = str(entry.get("target", ""))
        else:
            host, _, target = str(entry).partition(":")
        if not host or not target:
            continue
        if "${" not in host:
            published.append(f"{name}: published host port {host} is not a ${{KIT_*}} substitution")

if published:
    problems.extend(published)

# Nothing in the stack may name a cafaye SERVICE: hostnames are the service's
# own to choose, and a template that picks them for you is a template six repos
# disagree with. Infrastructure is fine — that is what this file is — and the
# observability backends are infrastructure, which is why they are named
# explicitly rather than allowed through by the exclusion below.
INFRASTRUCTURE = (
    "postgres",
    "nats",
    "redis",
    "otel-collector",
    "tempo",
    "loki",
    "grafana",
)
for name in services:
    if name not in INFRASTRUCTURE:
        problems.append(f"unexpected service: {name}")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/compose/docker-compose.yml  (pinned, healthy, parameterized)' compose_check

  # The backing services. Grafana, Loki and Tempo are AGPL-3.0 and are shipped
  # UNMODIFIED, which is the condition the licence cares about and the one this
  # check can actually hold: no `build:` (a build is a fork), no image from a
  # cafaye-owned registry, no volume overlaying anything into the vendor's own
  # tree. Configuration is fine and is what the flags are; a modified binary is
  # not, and `build:` is the only way that gets here.
  #
  # It was four, and the fourth went because it cost 130s of readiness budget per
  # cold start against a 180s deadline for the whole stack. A licence check that
  # names a backend the tree does not ship is a check reporting on a container
  # nobody can pull, so the name went with it rather than being left to fail.
  #
  # They are also bounded, because a dev machine running six services plus three
  # more needs bounded memory or the whole thing gets killed and blamed on
  # something else.
  backing_check() {
    "$PY" - "$ROOT" <<'PY'
import sys

import yaml

root = sys.argv[1]
with open(f"{root}/templates/compose/docker-compose.yml", encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
services = doc.get("services") or {}

BACKING = {
    "grafana": "grafana/grafana",
    "loki": "grafana/loki",
    "tempo": "grafana/tempo",
}
problems = []

for name, upstream in BACKING.items():
    svc = services.get(name)
    if not isinstance(svc, dict):
        problems.append(f"missing service: {name}")
        continue
    if "build" in svc:
        problems.append(
            f"{name}: has a build: stanza, which is a fork. AGPL-3.0 covers the "
            f"Grafana SERVER; shipping it unmodified is the condition, and "
            f"rebuilding the image is how that condition gets broken quietly."
        )
    image = svc.get("image") or ""
    if not image.startswith(upstream + ":"):
        problems.append(
            f"{name}: image {image!r} is not an unmodified upstream {upstream} image"
        )
    if not svc.get("healthcheck"):
        problems.append(f"{name}: no healthcheck, so `up --wait` cannot gate on it")
    if not svc.get("mem_limit"):
        problems.append(
            f"{name}: no mem_limit. Six services plus three more on one laptop "
            f"needs a bound, or the stack is killed and the cause is attributed "
            f"to whatever was running when the machine ran out of memory."
        )
    profiles = svc.get("profiles") or []
    if "observability" not in profiles:
        problems.append(
            f"{name}: not in the `observability` profile. The three backends are "
            f"the expensive half of the stack, and an escape hatch that does not "
            f"exist is not an escape hatch — but they must still be what the "
            f"DEFAULT bin/dev path brings up, which is a property of bin/dev, "
            f"not of the profile."
        )

# The collector is NOT in that profile, deliberately: it is the default value
# of <SERVICE>_OTEL_ENDPOINT, so a service with nothing switched on has
# somewhere to send. Without the collector running, a service's exporter has a
# dead endpoint, and the collector is what makes that dead endpoint cheap.
if "observability" in ((services.get("otel-collector") or {}).get("profiles") or []):
    problems.append(
        "otel-collector is in the `observability` profile, so a developer who "
        "turns the backends off also loses the endpoint every service points at "
        "by default"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'docker-compose.yml  (three AGPL backends, unmodified, pinned, bounded)' backing_check

  # The port range. kit-02 was moving the stack onto a high range so two
  # checkouts — or a developer's own postgres — do not collide; this check is
  # what makes that a rule rather than an intention.
  #
  # Asserted as a RANGE and as UNIQUENESS, not as a list of approved ports: a
  # list would have to be edited every time a service is added, and a check
  # that must be edited is a check that gets skipped. Every published host port
  # must sit in the documented block, must be a ${KIT_*:default} (the existing
  # check covers that) and must not be used twice.
  port_range_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import sys

import yaml

root = sys.argv[1]
# The block kit claims for the whole stack, one hundred per service. Declared
# here and in .env.example; the check reads the declared block so widening it is
# a deliberate edit in two visible places.
LOW, HIGH = 15000, 15999
BLOCK = f"{LOW}-{HIGH}"

with open(f"{root}/templates/compose/docker-compose.yml", encoding="utf-8") as fh:
    services = (yaml.safe_load(fh).get("services") or {})

problems = []
seen = {}
for name, svc in services.items():
    for entry in (svc or {}).get("ports") or []:
        if isinstance(entry, dict):
            host = str(entry.get("published", ""))
        else:
            host = str(entry).partition(":")[0]
        if "${" in host:
            # Read the DEFAULT, which is what a fresh clone binds.
            host = host.split(":-", 1)[1].rstrip("}") if ":-" in host else host
        if not host.isdigit():
            continue
        port = int(host)
        if not (LOW <= port <= HIGH):
            problems.append(
                f"{name}: published host port {port} is outside the {BLOCK} block "
                f"kit claims. 5432 and 6379 are the two most likely things on a "
                f"developer machine already, and a dev stack that loses to them "
                f"is a dev stack nobody runs."
            )
        if port in seen:
            problems.append(f"{name}: host port {port} is already published by {seen[port]}")
        seen[port] = name

# The block has to be written down, or "claim" means nothing to the next person.
example = open(f"{root}/templates/compose/.env.example", encoding="utf-8").read()
if BLOCK not in example:
    problems.append(
        f"templates/compose/.env.example does not state the {BLOCK} block this "
        f"check enforces: a port range nobody can read is a range nobody respects"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check "docker-compose.yml  (host ports all in the 15000-15999 block, no reuse)" port_range_check

  # TELEMETRY IS NEVER IN THE READINESS PATH.
  #
  # A service that hangs on startup because the collector is down is worse than
  # no telemetry at all, and the way it happens is always the same shape: one
  # `depends_on: [otel-collector]` added for convenience, then a readiness probe
  # that transitively waits on it, then a deploy that will not roll out because
  # a dev-local collector is not running in the cluster.
  #
  # This is the static half of the proof; tests/no_telemetry_in_readiness.sh is
  # the live half. Neither alone is enough: the static check cannot see a probe
  # that checks a collector over the network, and the live check only sees the
  # one topology it builds.
  readiness_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

import yaml

root = sys.argv[1]
with open(f"{root}/templates/compose/docker-compose.yml", encoding="utf-8") as fh:
    services = (yaml.safe_load(fh).get("services") or {})

problems = []
for name, svc in services.items():
    if name == "otel-collector":
        continue
    depends = svc.get("depends_on") or []
    if isinstance(depends, dict):
        depends = list(depends)
    for dep in depends:
        if "otel" in str(dep):
            problems.append(
                f"{name}: depends_on {dep!r}. Telemetry must never be in anyone's "
                f"readiness path: a service that waits for the collector serves "
                f"no traffic while the collector is down, which is strictly worse "
                f"than serving traffic with no traces."
            )
    probe = svc.get("healthcheck") or {}
    test = " ".join(str(probe.get("test", [])))
    for target in ("otel-collector", "4317", "4318", "13133"):
        if target in test:
            problems.append(
                f"{name}: its healthcheck probes {target}. core's probes schema "
                f"wants /healthz to consult NOTHING and /readyz to check real "
                f"dependencies — the collector is not one."
            )

# bin/dev is the other half: if it waits on the collector before migrating, then
# a dead collector is a dead dev machine even though nothing depends on it.
dev = open(f"{root}/templates/bin/dev.sh", encoding="utf-8").read()
up_body = dev.split("\nup() {", 1)[-1].split("\n}\n", 1)[0]
for needle, why in (
    ("healthz", "bin/dev must not probe a telemetry endpoint"),
    ("4317", "bin/dev must not wait on an OTLP port"),
    ("4318", "bin/dev must not wait on an OTLP port"),
):
    if needle in up_body:
        problems.append(f"{why} (found {needle!r} in bin/dev's up path)")

# And the rule has to reach the service repos, not just this file: a service
# adopting kit is where a probe would actually be written.
agents = open(f"{root}/templates/AGENTS.md", encoding="utf-8").read()
if "OTEL" not in agents and "telemetry" not in agents:
    problems.append(
        "templates/AGENTS.md says nothing about telemetry and readiness, so the "
        "rule never reaches the service repo where a probe would be written"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'compose + bin/dev  (telemetry is never in a readiness path)' readiness_check

  # The escape hatch is first-class, so it is checked like one. `<SERVICE>_
  # OTEL_ENDPOINT` is the ONLY contract (core D16) and the shipped collector is
  # its default value — not a requirement. The second half is the property that
  # is easy to lose: a "disabled" path that still dials out is worse than no
  # telemetry support at all.
  escape_hatch_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
snippets = {
    "go": "otelhttp.go.snippet",
    "ruby": "rack_middleware.rb.snippet",
    "elixir": "phoenix_telemetry.ex.snippet",
    "rust": "otel_client.rs.snippet",
    "python": "fastapi.py.snippet",
    "node": "hono.ts.snippet",
}

# Comments are removed before anything is asserted, and the marker is
# PER LANGUAGE. The first version of this check stripped on `#` only, which
# does nothing to a Go, Rust or TypeScript comment — and every one of those
# snippets explains *why* `error.message` is prohibited in a comment, so the
# check reported all six languages for mentioning the very attribute it exists
# to keep out. A check whose fix is to delete the explanation is a check that
# trains people to delete explanations.
LINE_COMMENT = {"go": "//", "rust": "//", "node": "//", "ruby": "#", "elixir": "#", "python": "#"}

# Docstring syntaxes, per language. A docstring is prose wearing code's
# punctuation, and a check that reads one as code reports a file for explaining
# itself.
DOCSTRINGS = {
    "python": (('"""', '"""'), ("'''", "'''")),
    "elixir": (('"""', '"""'),),
    "ruby": (),
    "go": (),
    "rust": (),
    "node": (("`", "`"),),
}


def strip_comments(body, marker):
    out, in_block = [], False
    for line in body.splitlines():
        cleaned, i = [], 0
        while i < len(line):
            if in_block:
                end = line.find("*/", i)
                if end == -1:
                    i = len(line)
                else:
                    in_block, i = False, end + 2
                continue
            if line.startswith("/*", i):
                in_block, i = True, i + 2
                continue
            if line.startswith(marker, i):
                break
            cleaned.append(line[i])
            i += 1
        out.append("".join(cleaned))
    return "\n".join(out)


def strip_prose(code, lang):
    """Remove docstrings, so a check cannot fail on a file's own explanation."""
    pairs = DOCSTRINGS.get(lang, ())
    if not pairs:
        return code
    out = code
    for open_q, close_q in pairs:
        out = re.sub(
            rf"{re.escape(open_q)}.*?{re.escape(close_q)}", "", out, flags=re.S
        )
    return out


problems = []
for lang, name in snippets.items():
    path = os.path.join(root, "templates", "otel", lang, name)
    if not os.path.isfile(path):
        continue  # artifact presence is another check's job
    body = open(path, encoding="utf-8").read()
    stripped = strip_comments(body, LINE_COMMENT[lang])
    where = f"otel/{lang}/{name}"

    # 1. It must read the cafaye variable, not only the OTel standard one.
    #    core D16: `<SERVICE>_OTEL_ENDPOINT`, derived from the service name so
    #    it is knowable without reading any code.
    if not re.search(r'"?[A-Z][A-Z0-9]*_OTEL_ENDPOINT"?', stripped):
        problems.append(
            f"{where}: reads no *_OTEL_ENDPOINT variable. That variable is the "
            f"only contract (core D16) and the shipped collector is just its "
            f"default value."
        )

    # 2. On by default. The default endpoint is the collector that ships with
    #    the stack, NOT "no exporter". A snippet that returns a no-op provider
    #    when the variable is absent has made telemetry opt-in, which is the
    #    exact thing the user directive reversed.
    if not re.search(r"OTEL_EXPORTER_OTLP_ENDPOINT|otel-collector:431", stripped):
        problems.append(
            f"{where}: does not name the shipped collector as the default value "
            f"of the endpoint variable, so telemetry is opt-in rather than on by "
            f"default (PLAN.md §7b)"
        )

    # 3. The free no-op is pinned to the OpenTelemetry spec's own switch, not to
    #    a cafaye reimplementation. Six reimplementations of "disabled" is how
    #    six services acquire six definitions of it, and the difference between
    #    them is somebody's production incident.
    if "OTEL_SDK_DISABLED" not in stripped:
        problems.append(
            f"{where}: does not honour OTEL_SDK_DISABLED. core pins the no-op to "
            f"the OTel spec's own switch; a cafaye-specific one is the thing D16 "
            f"was decided against."
        )

    # 4. The four negatives from otel-endpoint.schema.json, asserted on the
    #    CODE and not on the prose.
    #
    #    This took a second pass to get right, and the first version is worth
    #    recording because it is the same mistake the artifact-presence check
    #    made: it looked for the WORD `retry`, and every one of these snippets
    #    has to EXPLAIN why there is no retry — so all six were reported for
    #    containing the sentence "a retry loop against a dead endpoint is a
    #    background thread". A check whose fix is to delete the explanation is a
    #    check that trains people to delete explanations.
    #
    #    So it matches retry and queue CONFIGURATION — an identifier a runtime
    #    reads — and nothing else. `max_queue_size` is a number in a struct
    #    literal; the sentence about a memory leak is not.
    #
    #    Docstrings are stripped too, for the same reason comments are: Python's
    #    `"""…"""` and Elixir's `@moduledoc` are prose, and treating a docstring
    #    as code is how a snippet ends up with a check that fails on its own
    #    documentation.
    code = strip_prose(stripped, lang)
    for pat, why in (
        (r"retry_on_failure|RetryConfig|retry_after|retry_delay|max_retries|retries\s*[:=]\s*\d|retry\s*:", "no retry loop against a dead endpoint"),
        (r"sending_queue|max_queue_size|queue_size|enqueue|Enqueue|batch_size\s*[:=]", "no buffering"),
    ):
        hit = re.search(pat, code)
        if hit:
            problems.append(
                f"{where}: {why} on the disabled path (matched {hit.group(0)!r})"
            )
    for pat in (r"console\.warn\b", r"log\.warning\b", r"Logger\.warn\b", r"logger\.warn\b", r"Rails\.logger\.warn\b", r"log\.Warn\b"):
        hit = re.search(pat, code)
        if hit:
            problems.append(
                f"{where}: no warning spam on the disabled path (matched {hit.group(0)!r})"
            )

    # 5. `error.message` is prohibited by name. An SDK adds it by default, so a
    #    snippet that does not say so ships a leak by default rather than by
    #    decision — and core's metrics schema refuses the OTel spelling as well
    #    as the dotted one for exactly that reason.
    if re.search(r"error[._]message", stripped):
        problems.append(
            f"{where}: records error.message. core prohibits it BY NAME: a "
            f"provider's content-policy rejection quotes the offending content "
            f"back at you, so the message is a prompt by another route."
        )
    if "error.type" not in stripped and "error_type" not in stripped:
        problems.append(
            f"{where}: never records error.type, which is the bounded class that "
            f"answers 'one place to see all errors' (PLAN.md §7b, core D14)"
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/otel/*/*.snippet  (cafaye endpoint, on by default, free no-op)' escape_hatch_check

  # -------------------------------------------------------------------------
  # Grafana provisioning. "A dashboard a self-hoster has to rebuild is not a
  # dashboard we shipped" (PLAN.md §7b), so everything is a file and the files
  # are parsed here rather than clicked together by hand.
  #
  # The second check is the research constraint, and it is the one that matters:
  # the predicate for "this is an error" is span STATUS, not error.type. The
  # semconv expects high cardinality in error.type when no filter is applied, so
  # a fleet-wide breakdown grouped by error.type is wrong however good it looks.
  grafana_provisioning_check() {
    "$PY" - "$ROOT" <<'PY'
import json
import os
import sys

import yaml

root = sys.argv[1]
base = f"{root}/templates/compose/grafana"
problems = []

if not os.path.isdir(base):
    sys.exit("templates/compose/grafana/ is missing: a dashboard a self-hoster has to rebuild is not a dashboard we shipped")

ds_path = f"{base}/provisioning/datasources/datasources.yml"
if not os.path.isfile(ds_path):
    sys.exit(f"missing {ds_path}")
with open(ds_path, encoding="utf-8") as fh:
    datasources = (yaml.safe_load(fh).get("datasources") or [])

uids = {}
for ds in datasources:
    uid = ds.get("uid")
    if not uid:
        problems.append(f"datasource {ds.get('name')!r} has no uid; a dashboard that points at a datasource by uid cannot survive a rename")
        continue
    uids[uid] = ds.get("type")
# TWO LAYERS OF §7b HAVE A STORE, and this asserts both halves of that: the two
# are provisioned, and the third is NOT. The positive half is what it always
# was. The negative half is the one worth having, because a metrics datasource
# left behind by a store that left is the worst of both — Grafana resolves it,
# every panel over it renders, and the number is simply absent, with nothing in
# the UI saying why. A reader who meets a permanently-empty panel learns that
# empty means nothing, and then misses the one time it did.
for need, kind in (("tempo", "tempo"), ("loki", "loki")):
    if need not in uids:
        problems.append(f"no {kind} datasource with uid {need!r}: traces and logs are the two layers of §7b that have a store")
    elif uids[need] != kind:
        problems.append(f"datasource uid {need!r} is type {uids[need]!r}, expected {kind!r}")

for uid, kind in sorted(uids.items()):
    if kind in ("prometheus", "grafana-mimir-datasource"):
        problems.append(
            f"datasource uid {uid!r} is type {kind!r}, but there is no metrics "
            f"store in this stack: the backend cost 130s of readiness budget per "
            f"cold start and went with its service, its volume and its collector "
            f"exporter. A datasource nothing fills renders panels that are "
            f"permanently empty and teach a reader that empty means nothing. "
            f"Putting a store back means this entry, an exporter in "
            f"`otel-collector.yml`, an endpoint variable in `.env.example` and "
            f"the compose service — all four, together"
        )

dash_dir = f"{base}/provisioning/dashboards"
provider = f"{dash_dir}/dashboards.yml"
if not os.path.isfile(provider):
    problems.append(f"missing {provider}: without a provider stanza Grafana loads no dashboard at all")
else:
    with open(provider, encoding="utf-8") as fh:
        opts = ((yaml.safe_load(fh).get("providers") or [{}])[0]).get("options") or {}
    path = opts.get("path")
    if not path:
        problems.append(f"{provider} names no path, so the provider watches nothing")
    elif not os.path.isabs(path):
        # Grafana resolves a relative path against its own working directory,
        # which in the image is /var/lib/grafana and nowhere a reader expects.
        problems.append(f"{provider} path {path!r} is relative; Grafana resolves it against its own cwd and finds nothing")

dashboards = sorted(
    f for f in os.listdir(dash_dir) if f.endswith(".json") if os.path.isdir(dash_dir)
) if os.path.isdir(dash_dir) else []
if not dashboards:
    problems.append("no dashboard JSON under provisioning/dashboards: the fleet error view is the centrepiece of §7b and it is a file")

seen_uids = set()
for name in dashboards:
    with open(f"{dash_dir}/{name}", encoding="utf-8") as fh:
        try:
            dash = json.load(fh)
        except Exception as exc:
            problems.append(f"{name}: not valid JSON ({exc})")
            continue
    uid = dash.get("uid")
    if not uid:
        problems.append(f"{name}: no uid, so it is unaddressable and unlinkable")
    elif uid in seen_uids:
        problems.append(f"{name}: duplicate dashboard uid {uid!r}")
    seen_uids.add(uid)
    blob = json.dumps(dash)
    for target in uids:
        if f'"datasource": {{"type": "prometheus", "uid": "{target}"}}' in blob or f'"{target}"' in blob:
            break
    else:
        problems.append(f"{name}: references none of the provisioned datasource uids {sorted(uids)}")

# At least one alert rule, as a file.
alerting = f"{base}/provisioning/alerting"
if not os.path.isdir(alerting) or not [f for f in os.listdir(alerting) if f.endswith(".yml")]:
    problems.append("no alert rule file: a stack that can render a dashboard but cannot page is half a stack")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'grafana provisioning  (2 datasources, and no third, dashboards, alerting — all files)' grafana_provisioning_check

  # The error predicate. PLAN.md §7b and the semconv, verbatim:
  #
  #   The predicate for "this is an error" is span status Error, not error.type.
  #   error.type is a classification BENEATH the predicate, never the predicate.
  #   Consumers are explicitly expected to see high cardinality in error.type
  #   when no filter is applied, so a fleet-wide breakdown grouped by error.type
  #   is valid only under a service.name filter.
  #
  # That is a sentence a dashboard author reads once and forgets, so it is
  # asserted on the dashboard JSON: every panel that groups by an error class
  # must be scoped to a service, and at least one panel must filter on status.
  # A "fix" that makes this go red is a dashboard that looks better and answers
  # the wrong question.
  error_predicate_check() {
    "$PY" - "$ROOT" <<'PY'
import json
import os
import re
import sys

root = sys.argv[1]
dash_dir = f"{root}/templates/compose/grafana/provisioning/dashboards"
if not os.path.isdir(dash_dir):
    sys.exit("no dashboard directory")

problems = []
grouped_by_class_globally = 0
status_filtered = 0
service_partitioned = 0

def walk_targets(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key in ("expr", "query", "rawSql", "definition", "jsonData"):
                yield value
            yield from walk_targets(value)
    elif isinstance(node, list):
        for item in node:
            yield from walk_targets(item)

for name in sorted(f for f in os.listdir(dash_dir) if f.endswith(".json")):
    with open(f"{dash_dir}/{name}", encoding="utf-8") as fh:
        dash = json.load(fh)
    targets = [t for t in walk_targets(dash) if isinstance(t, str)]
    blob = "\n".join(targets)

    # `by (error_type)` / `group by ... error.type` with no service filter is
    # the exact failure the research named. Note the `service_name` allowance
    # below: the rule is "error.type is a drill-down INSIDE a service", and a
    # template variable that selects the service is that drill-down.
    for match in re.finditer(r"by\s*\(([^)]*)\)", blob):
        clause = match.group(1)
        if "error_type" in clause or "error\\.type" in clause:
            window = blob[max(0, match.start() - 400) : match.end() + 200]
            if not re.search(r"service_name\s*[=!~]+", window):
                grouped_by_class_globally += 1
                problems.append(
                    f"{name}: groups by an error class with no service filter. The "
                    f"predicate for 'this is an error' is span STATUS; error.type is "
                    f"a drill-down inside a service, and the semconv expects high "
                    f"cardinality there when no filter is applied."
                )

    if re.search(r"status(_\.?code)?\s*[=!]+\s*\"?STATUS_CODE_ERROR", blob) or \
       re.search(r'status\s*=\s*error', blob) or re.search(r"\{\s*status\s*=", blob):
        status_filtered += 1
    if re.search(r"by\s*\(\s*service_name\s*\)", blob) or "service_name" in blob:
        service_partitioned += 1

if not status_filtered:
    problems.append(
        "no panel filters on span status error. Grouping by error.type without "
        "the status predicate answers 'which classes exist' rather than 'what "
        "failed' — a request that failed without an error.type is invisible to it."
    )
if not service_partitioned:
    problems.append(
        "no panel partitions by service.name. §7b's answer is 'partition by "
        "resource.service.name, filter on status = error'; a single undifferentiated "
        "total is the wall of ungrouped text the user asked whether cafaye could avoid."
    )
if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'grafana dashboards  (status is the predicate, error.type is a drill-down)' error_predicate_check

  # -------------------------------------------------------------------------
  # EVERY PANEL NAMES THE BACKEND IT QUERIES, and the name is the one it means.
  #
  # Both dashboards shipped with `"datasource": null` on all 15 query targets.
  # A null datasource in Grafana means "use the DEFAULT datasource", and the
  # default was the metrics store — so every LogQL panel and the TraceQL panel
  # were being sent to a Prometheus API:
  #
  #     Mimir, given {service_name=~"$service"} |= `log.severity` |~ "..."
  #       parse error: unexpected character: '|'
  #
  # The store has since gone and `isDefault` moved to Tempo, so the uid a null
  # panel reaches is different. The bug is identical and the rule did not
  # change with the default, which is why the rule is what this check asserts
  # and not the uid it happened to be.
  #
  # The panels provision, the dashboards render, the datasource health checks
  # are green, and the crash layer — the panel the user explicitly asked for —
  # is structurally incapable of drawing anything. Found by sending each panel's
  # query to the backend it was actually bound to and reading the replies; 12 of
  # 15 were rejected. No static check in this file could have seen it, because
  # the JSON is perfectly valid and every datasource really was reachable.
  #
  # The language is classified from the query's own grammar, not the panel's
  # title: PromQL never opens an expression with a bare `{`, and Grafana's own
  # `queryType` hint says `range` for a log query and `nativeSearch` for a trace
  # search.
  datasource_binding_check() {
    "$PY" - "$ROOT" <<'PY'
import json
import os
import re
import sys

import yaml

root = sys.argv[1]
base = f"{root}/templates/compose/grafana/provisioning"

# Read the uids and types from the PROVISIONING FILE rather than repeating them,
# so renaming a uid in one file does not leave this check asserting against a
# name nothing uses.
with open(f"{base}/datasources/datasources.yml", encoding="utf-8") as fh:
    provisioned = {
        d["uid"]: d["type"]
        for d in (yaml.safe_load(fh).get("datasources") or [])
        if isinstance(d, dict) and d.get("uid")
    }

# Which query language each backend can serve, and which of those Grafana type
# strings mean what. Kept as a table so an unlisted backend is a FAILURE rather
# than a panel nobody has an opinion about.
LANGUAGES = {
    "prometheus": {"lang": "promql", "grafana_type": "prometheus"},
    "loki": {"lang": "logql", "grafana_type": "loki"},
    "tempo": {"lang": "traceql", "grafana_type": "tempo"},
}

problems = []
dash_dir = f"{base}/dashboards"


def classify(target):
    """The query language a target's text is, by its own grammar."""
    kind = str(target.get("queryType") or "").lower()
    if kind in ("range", "instant"):
        return "logql"
    if kind == "nativesearch":
        return "traceql"
    text = target.get("expr") or target.get("query") or ""
    if isinstance(text, str) and text.strip().startswith("{"):
        return "logql"
    return "promql"


def walk(node):
    """Yield (panel_title, target) for every panel, at any nesting depth."""
    if isinstance(node, dict):
        for panel in node.get("panels") or []:
            for target in panel.get("targets") or []:
                yield panel.get("title", "(row)"), target
            yield from walk(panel)
    elif isinstance(node, list):
        for item in node:
            yield from walk(item)


for entry in sorted(os.listdir(dash_dir)):
    if not entry.endswith(".json"):
        continue
    with open(f"{dash_dir}/{entry}", encoding="utf-8") as fh:
        doc = json.load(fh)
    for title, target in walk(doc):
        text = target.get("expr") or target.get("query") or ""
        if not isinstance(text, str) or not text.strip():
            continue
        ds = target.get("datasource")
        want = classify(target)

        if not ds or not isinstance(ds, dict) or not ds.get("uid"):
            problems.append(
                f"{entry} / {title}: the query has no datasource, so Grafana sends "
                f"it to the DEFAULT one — traces, not logs. This is a {want} query; "
                f"bound to a Prometheus API it returns a parse error, which is a "
                f"red panel rather than an empty one. Name the uid explicitly."
            )
            continue

        uid = ds["uid"]
        if uid not in provisioned:
            problems.append(
                f"{entry} / {title}: datasource uid {uid!r} is not in "
                f"datasources.yml ({', '.join(sorted(provisioned)) or 'none'}), so "
                f"the panel renders with no data and no error"
            )
            continue
        if ds.get("type") != provisioned[uid]:
            problems.append(
                f"{entry} / {title}: says type={ds.get('type')!r} for uid {uid!r}, "
                f"but datasources.yml provisions it as {provisioned[uid]!r}"
            )
        if provisioned[uid] not in LANGUAGES:
            problems.append(
                f"{entry} / {title}: datasource type {provisioned[uid]!r} is not a "
                f"backend this check knows how to route "
                f"({', '.join(sorted(LANGUAGES))})"
            )
            continue
        if LANGUAGES[provisioned[uid]]["lang"] != want:
            problems.append(
                f"{entry} / {title}: a {want} query bound to {uid!r}, which "
                f"serves {LANGUAGES[provisioned[uid]]['lang']}. Bound to the wrong "
                f"backend this is a parse error, not an empty result."
            )

# The alert rules are dashboards with a different trigger, and they carried the
# same class of mistake: the status predicate grouped on `otel.status_code`,
# which is a PARSE ERROR in PromQL because OTLP ingestion mangles the dot to an
# underscore. A rule that cannot be parsed never fires and never reports that it
# cannot be parsed.
#
# Scoped to the `expr` strings, not the whole file. The rules DOCUMENT these
# names in their descriptions — "`error.type` is a bounded class" is correct
# English about the OTLP attribute and must not be rewritten — and a scan over
# the serialised document cannot tell a sentence from a query. It can also only
# see what it was given, which is why the earlier version of this regex was
# matching the word "error" out of a description and reporting that a label
# called `error` should be `error`.
with open(f"{base}/alerting/rules.yml", encoding="utf-8") as fh:
    rules = yaml.safe_load(fh) or {}
exprs = []
for holder in [rules, *(rules.get("groups") or [])]:
    if not isinstance(holder, dict):
        continue
    for rule in holder.get("rules") or []:
        for source in [rule, *(rule.get("data") or [])]:
            if not isinstance(source, dict):
                continue
            model = source.get("model")
            expr = model.get("expr") if isinstance(model, dict) else source.get("expr")
            if isinstance(expr, str):
                exprs.append((rule.get("title", "(rule)"), expr))
for title, expr in exprs:
    for dotted in set(re.findall(r"\b(?:otel|error|http|service|span|messaging|db)\.[a-z_]+", expr)):
        problems.append(
            f"alerting/rules.yml rule {title!r} uses {dotted!r} in a PromQL expr. "
            f"OTLP ingestion mangles a dot in a label name to an underscore, so "
            f"what the backend holds is '{dotted.replace('.', '_')}'. A matcher on "
            f"the dotted spelling is a parse error, and an alert that cannot be "
            f"parsed never fires and never says so."
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'grafana panels  (every query names the backend that can answer it)' \
    datasource_binding_check

  # The wiring check that YAML parsing cannot do, and the one that caught a real
  # bug. otel-collector.yml interpolates ${env:NAME}, which the collector
  # resolves from ITS OWN process environment. Docker Compose reads .env to
  # expand ${KIT_*:default} in the compose file, and does NOT inject those into
  # containers. So a collector config full of ${env:...} against a compose file
  # with no `environment:` block parses perfectly, passes every check above, and
  # then the collector exits at startup with an error naming a memory limiter
  # rather than the missing environment.
  #
  # It did. That stack had never run. Asserting the wiring is cheaper than
  # running docker in the gate, and it fails with a message that names the cause.
  collector_wiring_check() {
    "$PY" - "$ROOT" <<'PY'
import re
import sys

import yaml

root = sys.argv[1]
with open(f"{root}/templates/compose/otel-collector.yml", encoding="utf-8") as fh:
    yaml.safe_load(fh)
with open(f"{root}/templates/compose/docker-compose.yml", encoding="utf-8") as fh:
    compose = yaml.safe_load(fh)

problems = []

# Every env-substituted name the collector reads, over the whole document
# rather than a fixed path: the value can sit at any depth (a processor arg, an
# exporter's verbosity, an extension endpoint), and a check that only knew the
# three it was written against would miss the fourth.
#
# Comment lines are excluded. A prose example of the syntax — which this file
# needs, because the whole point of the rule is to state it — otherwise
# registers as a variable the collector needs, and a check that fails on its own
# documentation is a check people delete.
raw = "\n".join(
    line
    for line in open(
        f"{root}/templates/compose/otel-collector.yml", encoding="utf-8"
    ).read().splitlines()
    if not line.lstrip().startswith("#")
)
needed = set(re.findall(r"\$\{env:([A-Z0-9_]+)\}", raw))

svc = (compose.get("services") or {}).get("otel-collector")
if not isinstance(svc, dict):
    problems.append("no otel-collector service to carry the environment")
else:
    provided = set(svc.get("environment") or {})
    for name in sorted(needed - provided):
        # Assembled rather than an f-string: `${env:NAME}` is not a valid Python
        # f-string expression, and a check whose failure message raises is a
        # check that reports the wrong thing at the exact moment it matters.
        placeholder = "$" + "{env:" + name + "}"
        problems.append(
            f"otel-collector.yml reads {placeholder} but docker-compose.yml does "
            f"not pass {name} into the container; it resolves empty and the "
            f"collector refuses to start"
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'otel-collector env  (every ${env:} reaches the container)' collector_wiring_check

  # Every ${VAR} the stack interpolates must be documented in .env.example,
  # with a default, so a fresh clone runs without a hand-written .env.
  env_example_check() {
    "$PY" - "$ROOT" <<'PY'
import re
import sys

root = sys.argv[1]
example = open(f"{root}/templates/compose/.env.example", encoding="utf-8").read()
documented = dict(
    (m.group(1), m.group(2))
    for m in re.finditer(r"^(KIT_[A-Z0-9_]+)=(.*)$", example, re.M)
)

# The `:-default` each variable falls back to in the stack itself. This is what
# decides whether an EMPTY line in .env.example breaks a fresh clone, so it has
# to be read rather than assumed - see the rule below.
#
# COMMENTS ARE STRIPPED FIRST, and that is not tidiness: this file documents the
# old broken value in prose, so a scanner that reads the raw text finds
# `${KIT_POSTGRES_DATABASES:-courier}` in a COMMENT and reports the defect it is
# describing. A check that cannot tell a sentence about a value from the value
# is not a check, and the first version of this rule failed on its own
# explanation - caught by running it, not by reading it.
compose_default = {}
compose_src = open(f"{root}/templates/compose/docker-compose.yml", encoding="utf-8").read()
compose_live = "\n".join(
    ln for ln in compose_src.splitlines() if not ln.strip().startswith("#")
)
for m in re.finditer(r"\$\{(KIT_[A-Z0-9_]+):-([^}]*)\}", compose_live):
    compose_default.setdefault(m.group(1), m.group(2))

problems = []
for name in ("docker-compose.yml", "otel-collector.yml"):
    source = open(f"{root}/templates/compose/{name}", encoding="utf-8").read()
    for var in sorted(set(re.findall(r"\$\{(KIT_[A-Z0-9_]+)[^}]*\}", source))):
        if var not in documented:
            problems.append(f"{name} uses ${{{var}}} which .env.example does not set")

# A documented placeholder with no default AND no fallback in the compose file
# breaks a fresh clone; `foo=` with an empty default is the same failure in YAML
# form. But an empty line whose variable the compose file already defaults is
# not a broken clone - it is the compose file's own default applying, which is
# exactly what the line is FOR. The two are not the same defect and collapsing
# them is what forced a real value into a file that must not carry one.
#
# AND A THIRD CASE, which is the one that matters most and the one this rule was
# rewritten for after it caught the author: an empty value for a variable the
# INIT SCRIPT REFUSES is not a silent breakage at all. It is the script stopping
# the container and naming the fix.
#
# `KIT_POSTGRES_DATABASES` is exactly that, and the sequence is worth recording
# because the first attempt at this fix got it backwards. The obvious repair for
# "the default names a tenant" is an empty default; that was tried, and bringing
# the template up with it produced, from `10-cluster.sh:48`:
#   KIT_POSTGRES_DATABASES: KIT_POSTGRES_DATABASES is unset. Name the services,
#   comma-separated.
# and a container that exits 1. The empty default is therefore NOT a supported
# state - but the FAILURE is the correct one, and it is strictly better than the
# default it replaced, which provisioned a real service's database for whoever
# adopted the template. So the rule is not "empty is allowed" and not "empty is
# forbidden": it is that emptiness must be CAUGHT, and this checks that it is,
# by looking for the guard rather than trusting a comment that says it exists.
init_script = ""
try:
    init_script = open(
        f"{root}/templates/compose/postgres/initdb/10-cluster.sh", encoding="utf-8"
    ).read()
except OSError:
    pass

for var, default in sorted(documented.items()):
    if default != "":
        continue
    if var in compose_default and compose_default[var] != "":
        continue  # the compose file supplies it; nothing is empty in practice
    if var in init_script and re.search(rf"{var}\s+is unset", init_script):
        continue  # refused loudly, by name, with the fix in the message
    problems.append(
        f".env.example sets {var}= with no default, and nothing supplies one: "
        f"docker-compose.yml has no :-fallback for it and initdb/10-cluster.sh "
        f"does not refuse it either. So a fresh clone with no .env gets an empty "
        f"value and NOTHING COMPLAINS - the value is consumed rather than "
        f"rejected, which is the silent half of a broken default. Give it a "
        f"fallback, or refuse it in the init script with a message naming the fix."
    )

# NO TENANT NAME AS A SHARED DEFAULT.
#
# This is the rule that would have caught the defect this file used to carry, and
# it is here because the old rule could not: `KIT_POSTGRES_DATABASES=courier`
# has a perfectly good non-empty default, so "every placeholder documented with
# a default" was satisfied by exactly the wrong value. A default that names one
# service in a template that NINE services fetch is a hardcoded tenant - every
# adopter that does not override it provisions that service's database, and
# `bin/dev` copies the value into each of their `.env` files, where it outranks
# the adopting service's own committed declaration.
#
# Measured, twice, on identity: its compose file said `:-identity`, the copied
# `.env` said `courier`, and the cluster provisioned `courier`. Then, with that
# corrected, its committed `KIT_POSTGRES_ROLE_CONNECTIONS: 50` was defeated the
# same way by this file's `10`, and 175 tests failed with `too many connections
# for role "identity"`.
#
# So both variables a service legitimately declares FOR ITSELF are required to be
# empty here, and empty is a supported state rather than a gap.
SERVICE_OWNED = ("KIT_POSTGRES_DATABASES", "KIT_POSTGRES_ROLE_CONNECTIONS")
for var in SERVICE_OWNED:
    if documented.get(var, "") != "":
        problems.append(
            f".env.example sets {var}={documented[var]!r}. This is a value the "
            f"service declares for ITSELF, in its own committed compose file, and "
            f"`.env` outranks that file - `bin/dev` copies this one verbatim and "
            f"Compose prefers it over the `:-default`. So this line does not "
            f"provide a fallback, it CANCELS the service's declaration, on every "
            f"machine where `bin/dev` has run, with nothing in any diff. Leave it "
            f"empty: docker-compose.yml's own default then applies, and a service "
            f"that needs a different one says so where it is reviewable."
        )

# And the same rule against the compose file's own default, but ONLY for the
# variable whose value is a LIST OF TENANTS. `KIT_POSTGRES_DATABASES` holds
# service names, so any non-empty fallback in a template nine services fetch is
# a hardcoded tenant: every adopter that does not override it provisions that
# service's database.
#
# `KIT_POSTGRES_ROLE_CONNECTIONS` is deliberately NOT in this half. `10` is a
# blast-radius default, not a tenant - it is a number Postgres understands and
# no service is named by it - so the compose default stays and only the
# `.env.example` line above is emptied. Conflating "empty in .env.example" with
# "empty as a fallback" is what would have had this check demanding that the
# cluster stop having a connection limit at all.
if compose_default.get("KIT_POSTGRES_DATABASES", "") != "":
    problems.append(
        f"docker-compose.yml defaults KIT_POSTGRES_DATABASES to "
        f"{compose_default['KIT_POSTGRES_DATABASES']!r}. That variable holds "
        f"SERVICE NAMES, and a template fetched by nine services must not name one "
        f"of them as a default: every adopter that does not override it inherits "
        f"that service's database. Measured on identity - it declared "
        f"`KIT_POSTGRES_DATABASES: ${{KIT_POSTGRES_DATABASES:-identity}}` and the "
        f"cluster still provisioned courier's database. An empty default is the "
        f"honest one: a cluster nobody has declared a tenant on is a real, "
        f"visible state, and a service says which database is its own in its own "
        f"compose file, where it is in the diff."
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/compose/.env.example  (every placeholder documented, no tenant named)' env_example_check

  # -------------------------------------------------------------------------
  # THE CONNECTION CONTRACT, ASSERTED AGAINST GENERATED OUTPUT, PER LANGUAGE.
  #
  #   A comment saying "remember to set prepare: :unnamed" is not a contract.
  #   A comment saying "do NOT set it, and here is why" PLUS a check that fails
  #   the build when it appears is one.
  #
  # Two directions, both load-bearing, both read from
  # templates/database/contract.json so the requirements live in one file rather
  # than being restated per language:
  #
  #   REQUIRED — every generated config carries application_name,
  #   statement_timeout, idle_in_transaction_session_timeout, and a bounded
  #   pool. A service missing one is unbounded on a shared cluster.
  #
  #   FORBIDDEN — no generated config carries a pooler workaround. This is the
  #   half that catches the real failure: a service carrying `prepare:
  #   :unnamed` or `default_query_exec_mode=simple_protocol` LOOKS correct, is
  #   wrong (kit runs no pooler), and is measurably slower, and the only way to
  #   notice is to look for the flag. See templates/database/README.md.
  #
  # The requirements are matched as TOKENS over the file's text rather than
  # executed, and that is the honest bar: five of the six settings are
  # connection-string or builder arguments whose effect is Postgres's, not the
  # driver's, and asserting them by running them would mean standing up a
  # cluster per language. What IS executed is the claim that would be cheap to
  # fake — that each snippet parses in its own language — which is the same split
  # `snippet_check` and the otel parse loop already make.
  database_contract_check() {
    "$PY" - "$ROOT" <<'PY'
import json
import os
import re
import sys

root = sys.argv[1]
contract_path = os.path.join(root, "templates/database/contract.json")
if not os.path.isfile(contract_path):
    sys.exit(
        "templates/database/contract.json does not exist. The connection "
        "requirements then have no single source, and the next language restates "
        "them in its own snippet and disagrees with the other five."
    )
contract = json.load(open(contract_path, encoding="utf-8"))


def strip_comments(src, lang):
    """`src` with its COMMENTS removed, per language.

    Exists because a required setting can be named in prose and not set in code,
    and a substring test cannot tell the two apart. Measured: the go snippet's
    header comment reads "1. application_name — THE ONE THAT IS NOT OPTIONAL",
    so deleting the one line that sets it left the contract satisfied and
    self-test breakage 72 green.

    The rules, and the reasoning behind each:

      * go / elixir / node / rust  — `//` to end of line. Elixir is the awkward
        one: a `#` starts a comment there too, and `#{}` is interpolation, so a
        `#` is only a comment when it is NOT inside `{}`.
      * python                     — `#` to end of line.
      * ruby (a `.yml`)            — `#` to end of line. The ruby snippet is
        DATA, so this strips YAML comments; it is not ERB, because the file holds
        `<%= ENV.fetch(…) %>` as a plain scalar.
      * sql                        — `--` to end of line. Added for the tenancy
        substrate, whose comments quote nearly every required string while
        explaining why it exists; a check that read that file as text would report
        the whole contract satisfied on a substrate with none of it.

    String literals are NOT tracked, and that is the conservative choice in the
    right direction: a comment marker inside a string is left in place, so the
    code that follows it is still scanned and a real setting is still found. The
    failure this could cause is a false NEGATIVE — a setting missed because a
    `#` in a string opened a comment that ran to end of line — and every one of
    the six snippets' settings is on its own line above such a marker, so it
    survives. The opposite error, eating code that carries a setting, would make
    this check red on a correct tree.
    """
    out = []
    for line in src.splitlines():
        marker = None
        if lang in ("go", "node", "rust"):
            marker = "//"
        elif lang == "sql":
            marker = "--"
        elif lang in ("python", "ruby"):
            marker = "#"
        elif lang == "elixir":
            # `#` but not `#{…}`: interpolation is code and can hold a setting.
            i = line.find("#")
            if i != -1 and not (i + 1 < len(line) and line[i + 1] == "{"):
                marker = "#"
        if marker is None:
            out.append(line)
            continue
        i = line.find(marker)
        if i == -1:
            out.append(line)
        else:
            # Keep the indentation so a reader of the finding can see where the
            # line was; only the comment text goes.
            out.append(line[:i].rstrip())
    return "\n".join(out)


required = contract.get("requiredSettings") or []
pool = contract.get("boundedPool") or {}
pool_tokens = pool.get("tokens") or []
forbidden = (contract.get("pooler") or {}).get("forbidden") or []
languages = contract.get("languages") or []

problems = []
if not required:
    problems.append("contract.json declares no requiredSettings")
if not pool_tokens:
    problems.append("contract.json declares no boundedPool.tokens")
if not forbidden:
    problems.append(
        "contract.json declares no forbidden pooler settings. An empty forbidden "
        "list would make the half of this check that matters a no-op."
    )
if not languages:
    problems.append("contract.json declares no languages")
if problems:
    sys.exit("; ".join(problems))

for entry in languages:
    lang = entry.get("lang", "?")
    rel = entry.get("snippet", "")
    path = os.path.join(root, rel)
    if not rel or not os.path.isfile(path):
        problems.append(f"{lang}: {rel} does not exist")
        continue
    body = open(path, encoding="utf-8").read()
    # THE CODE, NOT THE PROSE. Measured, and it is the rule AGENTS.md states
    # about `-count=1`: a check that a comment can satisfy is not a check.
    #
    # `application_name` appears in the go snippet's header comment — "1.
    # application_name — THE ONE THAT IS NOT OPTIONAL" — so deleting the only
    # line that ACTUALLY SETS it left the substring in the file and this check
    # reported the contract satisfied. Self-test breakage 72 exists to catch
    # precisely that, and it was green: the mutation it performs is the one this
    # check could not see.
    #
    # So the required-setting test reads code with the comments removed. It is a
    # per-language stripper rather than one regex because a line comment is `//`
    # in four of the six languages, `#` in two, and a YAML or a doc comment is not
    # a line comment at all — a stripper that got this wrong would either eat real
    # code (a `#` inside a string) or leave the comment in.
    #
    # The stripper is deliberately CONSERVATIVE: it removes a comment it can
    # recognise and leaves anything ambiguous alone, because a false NEGATIVE
    # here (comment retained, check still satisfied) is the bug being fixed,
    # while a false positive (code removed, a real setting reported absent) would
    # be a red on a correct tree — and both directions are proven below.
    code = strip_comments(body, entry.get("lang", ""))

    for setting in required:
        key = setting.get("key", "?")
        if key not in code:
            problems.append(
                f"database/{lang}: does not set {key}. {setting.get('why', '')} "
                f"The contract is templates/database/contract.json and this file "
                f"is the generated output; a setting that is required there and "
                f"absent here is the service running unbounded on a shared "
                f"cluster."
            )

    if not any(t in code for t in pool_tokens):
        problems.append(
            f"database/{lang}: no bounded pool setting. Expected one of "
            f"{pool_tokens}. {pool.get('why', '')}"
        )

    # The forbidden half, and it is checked per language rather than once over
    # the directory: a single check over the directory would be satisfied by four
    # clean files beside one that carries the flag.
    for bad in forbidden:
        if bad in code:
            problems.append(
                f"database/{lang}: contains {bad!r}, which is a pooler "
                f"workaround. kit runs NO pooler — see "
                f"templates/database/README.md for the argument, and "
                f"DECISIONS.md for the measurements. Each of these trades real "
                f"performance for compatibility with a component that is not in "
                f"the path, and a service carrying one looks correct and is "
                f"slower, so this is the only way it gets noticed."
            )

    # The service name, because `application_name` is only useful if it is the
    # service's own name. Asserted as "the file names a service at all" rather
    # than as a particular one, because kit's rule is that pins are placeholders
    # and a service raises them in its own repository.
    #
    # Unquoted as well as quoted: the ruby snippet is YAML, where
    # `application_name: courier` is the natural spelling, and a check that
    # demanded quotes would fail the one language whose config is data.
    if not any(re.search(rf"""["']?\b{n}\b["']?""", body)
               for n in ("courier", "billing", "identity", "darkroom")):
        problems.append(
            f"database/{lang}: names no service, so application_name has nothing "
            f"to attribute a query to. Every snippet ships a placeholder service "
            f"name and the service changes it; none of them may ship without one."
        )

if problems:
    sys.exit("\n       ".join([""] + problems))
print(f"       contract: {len(languages)} language(s) x ({len(required)} required "
      f"+ {len(pool_tokens)} pool tokens + {len(forbidden)} forbidden) — all satisfied")
PY
  }
  check 'templates/database/*  (the contract, in the generated output, per language)' \
    database_contract_check

  # -------------------------------------------------------------------------
  # THE ACCOUNT BOUNDARY, ASSERTED AGAINST THE TEMPLATES THAT ENFORCE IT.
  #
  #   The isolation templates are a contract in the same sense the connection
  #   contract is, and they are checked in the same place, for the same reason: a
  #   comment saying "remember FORCE ROW LEVEL SECURITY" is not a contract, and a
  #   comment saying "do NOT set prepare: :unnamed, and here is why" plus a check
  #   that fails the build when it appears IS one.
  #
  # FOUR DIRECTIONS, and the last two are the ones that make the first two mean
  # something:
  #
  #   REQUIRED in substrate.sql, over CODE. Measured rather than argued: the
  #   substrate's own comments quote nearly every required string while explaining
  #   why it exists, so a check that read the file as text would report the whole
  #   contract satisfied on a substrate containing none of it. This is the
  #   `-count=1` rule — "a check that a comment can satisfy is not a check" —
  #   and self-test breakage 72 is the recipe that proved it has to be done.
  #
  #   FORBIDDEN in substrate.sql, for the four shapes that make a policy
  #   decorative. Also over code, for the same reason.
  #
  #   THE SPINE IS CONSTRUCTED. Every name in `tenancy.isolation.spine` has to
  #   appear in isolation.sql AND in assertions.txt. A manifest naming an
  #   assertion the script never makes is a manifest reporting completeness for a
  #   proof that does not contain it, and that is the failure a list-of-names was
  #   introduced to prevent.
  #
  #   THE TWO FILES AGREE. Read assertions.txt and isolation.sql and fail on a
  #   difference in EITHER direction. This is `assert the AGREEMENT, not the
  #   presence of a file`: both existing is not the claim, both existing and
  #   naming the same twenty-four assertions is.
  #
  #   EVERY DRIVER OPENS BOTH FILES AT RUNTIME, and the check looks for the READ
  #   rather than the mention. A driver that names `assertions.txt` in a comment
  #   and never opens it asserts completeness about nothing — which is the failure
  #   ESLint's `reportUnusedDisableDirectives` exists for, in a language where the
  #   directive is prose.
  tenancy_contract_check() {
    "$PY" - "$ROOT" <<'PY'
import json
import os
import re
import sys

root = sys.argv[1]
contract_path = os.path.join(root, "templates", "database", "contract.json")
if not os.path.isfile(contract_path):
    sys.exit("templates/database/contract.json is missing, so the account boundary has "
             "no requirements and the next edit states them in a README")
contract = json.load(open(contract_path, encoding="utf-8"))
tenancy = contract.get("tenancy") or {}
if not tenancy:
    sys.exit(
        "templates/database/contract.json declares no `tenancy` block. The account "
        "boundary then has no machine-readable requirements, and the check that used "
        "to assert them has nothing to read — which is how a check ends up green "
        "having checked nothing."
    )


def strip_sql_comments(src):
    """`src` with its `--` comments removed, per LINE.

    Deliberately conservative in the same direction the connection check's
    stripper is: a marker it cannot recognise is left alone, so a false NEGATIVE
    (a required string left in a comment, check satisfied anyway) is the known
    failure mode rather than a false POSITIVE that would take a correct tree red.

    String literals are not tracked, and that is safe here for a measured reason
    rather than a hopeful one: every required token in the substrate lives on its
    own line, and the substrate's only `--` inside a string is the `'cafaye:tier=db
    ...'`-shaped hint text, which no required token overlaps.
    """
    out = []
    for line in src.splitlines():
        i = line.find("--")
        if i == -1:
            out.append(line)
        else:
            out.append(line[:i].rstrip())
    return "\n".join(out)


def read(rel):
    path = os.path.join(root, rel)
    if not rel or not os.path.isfile(path):
        return None, f"{rel} does not exist"
    return open(path, encoding="utf-8").read(), ""


problems = []

# ---------------------------------------------------------------- the substrate
sub = tenancy.get("substrate") or {}
sub_rel = sub.get("file", "")
sub_raw, err = read(sub_rel)
if err:
    problems.append(f"tenancy/substrate: {err}")
else:
    sub_code = strip_sql_comments(sub_raw)
    for entry in sub.get("required") or []:
        token = entry.get("token", "?")
        if token not in sub_code:
            problems.append(
                f"tenancy/substrate: does not contain {token!r}. {entry.get('why', '')} "
                f"The requirements are templates/database/contract.json and this file is "
                f"the thing they are about; a requirement absent here is an account "
                f"boundary that does not exist."
            )
    if not sub.get("required"):
        problems.append(
            "contract.json's tenancy.substrate declares no `required`. An empty list "
            "would make the half of this check that matters a no-op that passes."
        )
    for bad in sub.get("forbidden") or []:
        if bad.lower() in sub_code.lower():
            problems.append(
                f"tenancy/substrate: contains {bad!r}, which makes a policy decorative. "
                f"{'; '.join(sub.get('forbiddenWhy') or []) or 'See substrate.sql.'}"
            )
    if not sub.get("forbidden"):
        problems.append(
            "contract.json's tenancy.substrate declares no `forbidden` list. The four "
            "shapes that make an RLS policy read correctly and enforce nothing are the "
            "ones nobody notices."
        )

# ---------------------------------------------------------------- the proof
iso = tenancy.get("isolation") or {}
iso_rel = iso.get("file", "")
iso_raw, err = read(iso_rel)
if err:
    problems.append(f"tenancy/isolation: {err}")
else:
    for token in iso.get("required") or []:
        if token not in iso_raw:
            why = iso.get("requiredWhy") or []
            problems.append(
                f"tenancy/isolation: does not contain {token!r}. "
                f"{why[iso.get('required').index(token)] if token in (iso.get('required') or []) else ''}"
            )
    if not iso.get("required"):
        problems.append("contract.json's tenancy.isolation declares no `required` list")

# --------------------------------------------------- the manifest, both ways
man = tenancy.get("assertions") or {}
man_rel = man.get("file", "")
man_raw, err = read(man_rel)
listed = []
if err:
    problems.append(f"tenancy/assertions: {err}")
else:
    listed = [l.strip() for l in man_raw.splitlines()]
    listed = [l for l in listed if l and not l.startswith("#")]
    if not listed:
        problems.append(
            f"{man_rel} lists no assertions. Every one of the six drivers compares the "
            f"proof's results against this file, so an empty one makes them all "
            f"satisfied by a proof that returned nothing."
        )
    if len(listed) != len(set(listed)):
        dupes = sorted({n for n in listed if listed.count(n) > 1})
        problems.append(f"{man_rel} lists {len(duped)} name(s) twice: {', '.join(dupes)}")

if iso_raw and listed:
    # Every name the manifest lists must be CONSTRUCTED in the script. The script
    # builds the two per-role halves by concatenation (`r || '/no-identity…'`), so
    # the check looks for the suffix as well as the whole name — and a missing one
    # is reported against the manifest, because that is the file a reader trusts to
    # be complete.
    for name in listed:
        suffix = name.split("/", 1)[1] if "/" in name else name
        if ("'" + name + "'") not in iso_raw and ("'/" + suffix + "'") not in iso_raw:
            problems.append(
                f"tenancy/assertions: lists {name!r}, which isolation.sql never "
                f"constructs. Every one of the six drivers compares the proof's "
                f"results against this list, so a name here that the proof does not "
                f"make is a driver asserting completeness about an assertion that "
                f"does not exist — and the driver will be red for it, which is the "
                f"right answer to the wrong question."
            )
    # ...and every assertion the script constructs must be listed. The reverse
    # direction: an assertion nobody claims is an assertion no service is told to
    # expect, so a driver that compares the sets does not fail on it and the proof
    # has silently grown.
    spine = iso.get("spine") or []
    if not spine:
        problems.append(
            "contract.json's tenancy.isolation declares no `spine`. The spine is the "
            "shape the packet names — three denials and an allowance — and a check "
            "that cannot say which assertions are the shape cannot say the shape is "
            "still there."
        )
    for name in spine:
        if name not in listed:
            problems.append(
                f"tenancy/isolation: the spine requires {name!r}, which "
                f"{man_rel} does not list. The spine is asserted in the contract and "
                f"carried by the manifest, and the two must agree or one of them is "
                f"decorative."
            )
    for name in ("owner/no-identity-reads-no-rows",
                 "owner/another-tenants-rows-read-as-none",
                 "owner/own-rows-are-visible",
                 "owner/own-identity-reads-only-its-own-rows"):
        if name not in listed:
            problems.append(
                f"tenancy/assertions: the OWNER half is missing {name!r}. The login "
                f"half passes on a substrate with no FORCE ROW LEVEL SECURITY at all, "
                f"so an assertion set without the owner half cannot detect the one "
                f"defect this whole directory exists for."
            )

# ------------------------------------------- the advisor and the proof of it
#
# WHY THIS HALF EXISTS, and it is the same reason breakage 92 exists one section
# up. `advisor.sql` is the only thing in the account boundary that grades the
# LIVE DATABASE, and its rules are graded by fixtures in a script that
# `--static-only` never runs. So a rule can be added, renamed or deleted, the
# fixture that trips it can be renamed with it, and every static check stays
# green -- because nothing here was comparing the two lists.
#
# The comparison is both ways and it is over RULE NAMES, not over counts. A count
# would be satisfied by nine rules and nine fixtures that do not correspond,
# which is precisely the state this check exists to make impossible.
adv_raw, err = read("templates/database/tenancy/advisor.sql")
adv_rules = set()
if err:
    problems.append(f"tenancy/advisor: {err}")
else:
    adv_code = strip_sql_comments(adv_raw)
    # `select '<name>'::text as name` — the shape every arm uses, so it is read
    # from the arms and not from the prose. A comment listing the rules is
    # documentation; this is the union that produces them.
    adv_rules = set(re.findall(r"select\s+'([a-z0-9_]+)'::text\s+as\s+name", adv_code))
    if not adv_rules:
        problems.append(
            "tenancy/advisor: no rule names found in advisor.sql. The pattern reads "
            "`select '<name>'::text as name`, which is the shape every union arm uses. "
            "If the arms were rewritten this check would find nothing and pass — which "
            "is the state it is meant to make impossible, so it says so rather than "
            "reporting a clean file."
        )

ten_raw, err = read("tests/tenancy_test.sh")
if err:
    problems.append(f"tenancy/tenancy_test.sh: {err}")
else:
    # The trip list, read as the `rule:fixture` PAIRS the assertion-7 loop
    # iterates, so what is compared against the advisor is what is actually
    # asserted rather than every mention of a rule name in the file (which
    # includes the comments that explain them).
    trip_pairs = re.findall(
        r"^ *'([a-z0-9_]+):([a-z0-9_]+)'", ten_raw, re.M
    )
    tripped = {r for r, _ in trip_pairs}
    if not tripped:
        problems.append(
            "tests/tenancy_test.sh: no `<rule>:<fixture>` trip pairs found. The pattern "
            "reads the quoted pairs the assertion-7 loop iterates. Without them this "
            "half of the check has nothing to compare and reports agreement between "
            "two empty sets."
        )
    for rule in sorted(adv_rules - tripped):
        problems.append(
            f"tenancy/advisor: rule {rule!r} has NO fixture that trips it in "
            f"tests/tenancy_test.sh. A detective that has never fired is a detective "
            f"nobody can trust, and one that cannot fire is indistinguishable from a "
            f"detective that does not work."
        )
    for rule in sorted(tripped - adv_rules):
        problems.append(
            f"tests/tenancy_test.sh: asserts a rule {rule!r} that advisor.sql does not "
            f"define. Either the rule was renamed or removed and the fixture was not, "
            f"and the suite would then be proving a rule that no longer exists."
        )

# ---------------------------------------------------------------- the drivers
drivers = tenancy.get("drivers") or {}
DRIVER_FILES = {
    "go": "templates/database/go/tenancy_test.go.snippet",
    "elixir": "templates/database/elixir/tenancy_test.exs.snippet",
    "python": "templates/database/python/tenancy_test.py.snippet",
    "ruby": "templates/database/ruby/tenancy_test.rb.snippet",
    "node": "templates/database/node/tenancy_test.ts.snippet",
    "rust": "templates/database/rust/tenancy_test.rs.snippet",
}
# The READ, in each language's own spelling. A mention is not a read, so these are
# all `read the file` forms and none of them is a bare string: that is the whole
# point of looking for these rather than for the file name.
READ_FORMS = {
    "go": [r"os\.ReadFile\("],
    "elixir": [r"File\.read!\("],
    "python": [r"\.read_text\(", r"open\("],
    "ruby": [r"File\.readlines\(", r"File\.read\("],
    "node": [r"readFile\("],
    "rust": [r"read_to_string\("],
}
for lang, rel in DRIVER_FILES.items():
    body, err = read(rel)
    if err:
        problems.append(f"tenancy/driver {lang}: {err}")
        continue
    # CODE, not prose, and that is the whole difficulty rather than the first half
    # of it. Every one of the six drivers names both files in its own header
    # comment — the header is WHY the driver is thin — so a check that counted
    # mentions was satisfied by deleting the read. This is the `-count=1` rule: a
    # check a comment can satisfy is not a check.
    #
    # WHOLE-LINE comments only, which is the narrower version on purpose. The other
    # check in this file strips trailing comments too, and reusing that would mean
    # either a fifth program in tests/ — which the carve-out refuses — or merging
    # two checks that are separately filterable. So this does the half that matters
    # and says so: the problem is a header block, not a trailing aside.
    code = [l for l in body.splitlines() if not l.lstrip().startswith(("//", "#", "--"))]

    # mustCarry: present in code at all. The result table is what a driver queries
    # after running the proof, so its absence means the driver is not running this
    # proof whatever else it does.
    if not drivers.get("mustCarry"):
        problems.append(
            "contract.json's tenancy.drivers declares no `mustCarry`. Every list this "
            "check iterates needs an empty-list guard, because an empty list makes the "
            "loop over it a no-op that PASSES — which is how a check ends up green "
            "having read nothing at all."
        )
    for token in drivers.get("mustCarry") or []:
        if token not in "\n".join(code):
            problems.append(
                f"tenancy/driver {lang}: {token!r} is not in the code. Every driver runs "
                f"isolation.sql and reads the result table it creates; a driver that "
                f"never asks for it is not running this proof."
            )

    # mustRead: on the SAME LINE as one of the language's own read forms.
    #
    # A file-wide "does it contain a read anywhere" is satisfied by every driver,
    # because all six read isolation.sql — so a driver that had stopped reading
    # assertions.txt was reported clean by that too. Two checks, two versions, the
    # same failure: each was satisfied by the exact edit it was written to catch.
    if not drivers.get("mustRead"):
        problems.append(
            "contract.json's tenancy.drivers declares no `mustRead`. Without it the "
            "half of this check that distinguishes a driver which READS the assertion "
            "set from one which merely names it in a comment does not exist."
        )
    for token in drivers.get("mustRead") or []:
        forms = READ_FORMS[lang]
        hit = [l.strip() for l in code
               if token in l and any(re.search(f, l) for f in forms)]
        if not hit:
            problems.append(
                f"tenancy/driver {lang}: does not READ {token!r} — no mention of it on a "
                f"line that also opens a file ({', '.join(forms)}). A driver that names "
                f"the assertion set without reading it asserts completeness about "
                f"nothing, and the failure is silent: the driver still runs and still "
                f"passes."
            )
if problems:
    sys.exit("\n       ".join([""] + problems))
print(
    f"       tenancy: substrate {len(sub.get('required') or [])} required + "
    f"{len(sub.get('forbidden') or [])} forbidden, isolation {len(iso.get('required') or [])} "
    f"required, spine {len(iso.get('spine') or [])}, manifest {len(listed)} assertions, "
    f"{len(DRIVER_FILES)} driver(s) all reading both files"
)
PY
  }
  check 'templates/database/tenancy/*  (the account boundary, in the templates that enforce it)' \
    tenancy_contract_check

  # -------------------------------------------------------------------------
  # DECISIONS.md EXISTS, AND EVERY REFERENCE TO IT RESOLVES.

  # -------------------------------------------------------------------------
  # DECISIONS.md EXISTS, AND EVERY REFERENCE TO IT RESOLVES.
  #
  # This file was referenced by AGENTS.md (twice), README.md (twice, one of them
  # a MARKDOWN LINK), .github/zizmor.yml, the reusable workflow (three times) and
  # three of the gate's own scripts — and did not exist. That is the worst shape
  # a documentation reference can have: every reader is told the trade is written
  # down, and the person who goes to read it finds nothing, and the natural
  # conclusion is that the trade was never actually made.
  #
  # So this asserts both halves. The file exists and is a real file rather than an
  # empty placeholder; and every `DECISIONS.md` reference in the tree names a
  # file that exists, so a future rename is a FAIL rather than a dangling link.
  decisions_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
rel = "DECISIONS.md"
path = os.path.join(root, rel)
problems = []

if not os.path.isfile(path):
    problems.append(
        f"{rel} does not exist, and it is referenced from AGENTS.md, README.md, "
        f".github/zizmor.yml, .github/workflows/ci.reusable.yml and three of the "
        f"gate's own scripts. A reference to a decision document that is not "
        f"there tells the reader the trade was made and then leaves them with "
        f"nothing to read — which is worse than not claiming it, because the "
        f"absence looks like they have not looked hard enough."
    )
else:
    text = open(path, encoding="utf-8").read()
    if len(text.strip()) < 400:
        problems.append(
            f"{rel} exists but is {len(text.strip())} characters. An empty or "
            f"one-line DECISIONS.md satisfies every reference to it and records "
            f"no trade, which is the failure this check exists to catch."
        )
    # A document of trades that records none is the same failure wearing a file.
    headings = re.findall(r"^## ", text, re.M)
    if len(headings) < 3:
        problems.append(
            f"{rel} has {len(headings)} top-level sections; a decisions "
            f"document with fewer than three entries is a placeholder"
        )

# Every reference, wherever it is, must resolve. Only files, not REPORT-*.md:
# the reports are historical records and are allowed to describe a state that
# has since changed.
skip_dirs = {".git", "REPORT", "CHANGELOG"}
counted = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in skip_dirs and d != ".venv"]
    for name in filenames:
        if not name.endswith((".md", ".sh", ".yml", ".yaml", ".toml", ".json")):
            continue
        full = os.path.join(dirpath, name)
        if os.path.abspath(full) == os.path.abspath(path):
            continue
        try:
            body = open(full, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if "DECISIONS.md" not in body:
            continue
        counted += 1
        relname = os.path.relpath(full, root)
        # A reference that names a DIFFERENT file (`../DECISIONS.md` in a fleet
        # repository) is about that repository's document and is not this
        # check's business. A bare `DECISIONS.md` is about this one.
        for match in re.findall(r"`?(\.{0,2}/?DECISIONS\.md)`?", body):
            if match.startswith(".."):
                continue
            if not os.path.isfile(os.path.join(root, "DECISIONS.md")):
                problems.append(f"{relname} references {match}, which does not exist")
                break

if problems:
    sys.exit("; ".join(problems))
print(f"       {rel} exists and {counted} referring file(s) resolve against it")
PY
  }
  check 'DECISIONS.md  (exists, records trades, and every reference resolves)' decisions_check

  # -------------------------------------------------------------------------
  # EVERY `bin/dev <command>` THE DOCUMENTATION PROMISES IS ONE THE SCRIPT HAS.
  #
  # `DECISIONS.md` was created to stop this repository promising a document that
  # does not exist, and four files in kit-21 then promised a COMMAND that did not:
  # `bin/dev db grant <name>` is named in templates/database/README.md, in
  # DECISIONS.md, in the init script and in the compose file, and `bin/dev` had no
  # `db` command at all. Every one of those four is a reader who is told the way
  # out of "my service's database was never created" exists, runs it, and gets
  # `unknown command` — after `bin/dev up` has already told them the stack is fine.
  #
  # It is the same defect one layer down, and it is worth a check rather than a
  # fix because the class is not the command: it is a document naming an interface
  # and the interface disagreeing. So this reads the subcommands the script's own
  # `case` dispatches, and fails on any documented one that is not there.
  #
  # Only COMMANDS are read, and only from prose that is telling a service author
  # what to run. A prose mention of a flag, a URL, or a subcommand belonging to
  # some other tool is not a promise about `bin/dev`, and a check that flagged
  # those would be a check that fires on correct work.
  bin_dev_command_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
dev = os.path.join(root, "templates/bin/dev.sh")
if not os.path.isfile(dev):
    sys.exit("templates/bin/dev.sh does not exist")

source = open(dev, encoding="utf-8").read()

# THE INTERFACE, TAKEN FROM THE SCRIPT — and read from the `case` in `main` by
# BRACE MATCHING rather than by pattern-matching a line shape, because three
# successive pattern attempts each reported a different wrong answer:
#
#   * requiring the line to END at `)` found four of the ten arms, and reported
#     the real `bin/dev down` and `bin/dev nuke` as promised-but-missing;
#   * requiring a bare `word)` on its own line, to spot a nested `case`, also
#     matched a COMMENT, so `bin/dev pin v0` and `bin/dev logs tempo` were read as
#     two-level promises — `v0` is a version;
#   * and keying "does this arm take a subcommand" on the presence of that nested
#     `case` meant that DELETING the nested `case` made the check go GREEN on
#     `bin/dev db grant` — the exact defect it exists to catch.
#
# The last one is the reason the arms are read from `main` itself rather than
# from the file. The lesson is not "write a better regex"; it is that a predicate
# which infers an interface from a FORMATTING convention reports the interface
# correctly only while the formatting holds, and this check got that wrong three
# times in a row.
_main = re.search(r"^main\(\)\s*\{(.*?^\})", source, re.M | re.S)
if not _main:
    sys.exit("templates/bin/dev.sh has no main() to read the command interface from")
_main_body = _main.group(1)

# Depth 1: `main`'s own arms, and depth 2: the arms of a `case` nested in one of
# them, together with the arm they belong to. `help` and the two flag spellings
# are dispatched by the same arm as each other and are not separate commands.
dispatch = set()
subcommands_of = {}
for _m in re.finditer(r"^\s{4}([a-z][a-z0-9-]*|-h\s*\|\s*--help\s*\|\s*help)\)(.*?)(?=^\s{4}[a-z-]|\Z)",
                      _main_body, re.M | re.S):
    _arm, _body = _m.group(1), _m.group(2)
    if "|" in _arm:
        # One arm dispatching several spellings of the same thing.
        for _alt in re.split(r"\|", _arm):
            dispatch.add(_alt.strip())
        continue
    dispatch.add(_arm)
    if re.search(r"^\s+case\s", _body, re.M):
        # The `*)` catch-all is NOT a subcommand — it is the ABSENCE of one. So
        # it is discarded, and an arm left with nothing is recorded as taking no
        # subcommand at all. That distinction is load-bearing: with it, deleting
        # `grant)` and leaving only `*) die …` empties the set, and the check
        # reports the documented `bin/dev db grant` as a promise with nothing
        # behind it — rather than deciding the arm has no subcommands and
        # staying quiet about a promise four files make.
        subs = {a for a in re.findall(r"^\s{8}([a-z][a-z0-9-]*)\)", _body, re.M)}
        subs.discard("esac")
        subs.discard("*")
        subcommands_of[_arm] = subs
dispatch -= {"esac", "in"}

problems = []
# A promise has to LOOK like a promise: inside backticks, or at the start of a
# line in a usage block. The first version of this check matched the bare text
# `bin/dev` followed by any lowercase word and reported thirty findings, every one
# of them English — and it matched its OWN explanation, which is the shape
# AGENTS.md records about `gate_declaration_check`: a check that fires on correct
# work teaches the reader to ignore it.
documented = {}
skip_dirs = {".git", ".venv", "REPORT", "CHANGELOG", "copies"}
# A backticked `bin/dev …` invocation. Two things about the shape, both measured:
#
#   * the space before the first argument is required, because
#     `` `bin/dev` is the callable path `` is a SENTENCE about the script and
#     appears in nine files; without it the closing backtick is skipped and the
#     next English word reads as a command;
#   * an ARGUMENT PLACEHOLDER has to be tolerated, because the four files naming
#     `bin/dev db grant` all name it as `` `bin/dev db grant <name>` ``;
#   * a word belongs to the invocation only when what FOLLOWS it is another word,
#     a placeholder, or the CLOSING BACKTICK. A span that runs to the next
#     backtick swallows the sentence after the command, which is how an earlier
#     version reported `fetches`, `refuses` and `was` as promised subcommands —
#     twenty-one findings, every one English;
#   * and a command word is one the SCRIPT KNOWS, never a word that merely
#     follows it. `` `bin/dev` fetches the stack `` is a sentence, and no amount
#     of pattern work on the span distinguishes it from `` `bin/dev db grant` ``
#     — the difference is that `db` is dispatched and `fetches` is not. So the
#     candidates are intersected with the interface BEFORE anything is reported:
#     an unknown first word is only a finding if it is not a plausible English
#     continuation, and English is excluded by requiring the word to be followed
#     by another word or the closing backtick AND by appearing in a span that
#     opens with `bin/dev ` rather than `bin/dev` `.
WORD = r"(?:[a-z][a-z0-9-]*|<[^>]*>)"
# The opening is `bin/dev` followed by a SPACE and then a word — `bin/dev db
# grant`. `` `bin/dev` `` with the backtick closing immediately is the script
# being REFERRED TO, never being invoked, and every English finding in three
# versions of this check came from reading past that backtick.
CALL = re.compile(r"`bin/dev\s(" + WORD + r"(?:\s+" + WORD + r")*)\s?`")
# A usage-block line: `bin/dev <word>` at the start, after any prompt strip.
USAGE = re.compile(r"^\s*(?:\$|#)?\s*bin/dev((?:\s+" + WORD + r")*)", re.M)
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in skip_dirs]
    for name in filenames:
        if not name.endswith((".md", ".sh", ".yml", ".yaml", ".toml", ".json")):
            continue
        full = os.path.join(dirpath, name)
        # This check's own source, and `bin/dev` itself. The first version of
        # this check reported `bin/dev is` — a phrase in its OWN explanation,
        # quoted back at it by its own pattern. A check that reads its own
        # comments is a check whose findings are about the check.
        #
        # `__file__` is NOT usable for that: this Python arrives on stdin, so it
        # is `<stdin>` and the comparison never matches. Named literally instead.
        if os.path.realpath(full) in (os.path.realpath(dev),
                                      os.path.join(os.path.realpath(root), "tests/validate.sh")):
            continue
        try:
            body = open(full, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        rel = os.path.relpath(full, root)
        for pattern in (CALL, USAGE):
            for m in pattern.finditer(body):
                words = [w for w in m.group(1).split()
                         if not w.startswith("-") and not w.startswith("<")]
                if not words:
                    continue
                first = words[0]
                if first not in dispatch:
                    documented.setdefault(f"{first} (command)", []).append(
                        f"{rel} (as `bin/dev {first}`)"
                    )
                    continue
                # The SECOND word is a subcommand only when the first word is an
                # arm that dispatches any. `bin/dev pin v0.1.2` is a command and
                # a version; `bin/dev db grant courier` is two levels of promise.
                # And when the arm dispatches subcommands, the second word has to
                # be one of THEM — which is what makes deleting the nested `case`
                # a FAIL rather than a silence.
                if len(words) > 1 and first in subcommands_of:
                    second = words[1]
                    if second not in subcommands_of[first]:
                        documented.setdefault(f"{first} {second} (subcommand)", []).append(
                            f"{rel} (as `bin/dev {first} {second}`)"
                        )

if documented:
    listed = ", ".join(
        f"`bin/dev {cmd}` cited in {len(where)} file(s)"
        for cmd, where in sorted(documented.items())
    )
    sys.exit(
        f"the documentation promises a command the script does not dispatch: {listed}. "
        f"bin/dev dispatches: {', '.join(sorted(dispatch))}"
        + (
            f"; and under {', '.join(sorted(subcommands_of))}: "
            + ", ".join(f"{a}->{sorted(s)}" for a, s in sorted(subcommands_of.items()))
            if subcommands_of
            else ""
        )
        + ". A reader told to run a command that does not exist is worse than one "
        "told nothing — the promise is the whole message."
    )

print(f"       every documented bin/dev subcommand is dispatched ({len(dispatch)}: "
      f"{', '.join(sorted(dispatch))})")
PY
  }
  check 'bin/dev  (every command the documentation promises is one the script dispatches)' \
    bin_dev_command_check

  # -------------------------------------------------------------------------
  # THE POSTGRES TAG, IN BOTH DIRECTIONS.
  #
  # This is a defect that shipped. `templates/compose/.env.example` said
  # `KIT_POSTGRES_TAG=16.6-alpine` while docker-compose.yml defaulted to
  # `17-alpine`, and .env.example WINS — `bin/dev` copies it to `.env` on first
  # run. So every developer's stack ran 16.6 while the compose file, the README
  # and the CHANGELOG all said 17. Commit 48689e6 fixed the compose default and
  # left this line alone, which is the more dangerous half of that fix: it made
  # the repository agree with itself and the developer's machine disagree with
  # both.
  #
  # So this asserts the AGREEMENT, in both directions, over the parsed values
  # rather than by grepping lines:
  #
  #   .env.example's tag == docker-compose.yml's `${KIT_POSTGRES_TAG:-…}` default
  #
  # Either one being changed alone is a FAIL. A check that only asked "is
  # KIT_POSTGRES_TAG in .env.example" would be satisfied by the broken state,
  # because the broken state has it.
  postgres_tag_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
compose_path = os.path.join(root, "templates/compose/docker-compose.yml")
example_path = os.path.join(root, "templates/compose/.env.example")

problems = []
compose = open(compose_path, encoding="utf-8").read()
example = open(example_path, encoding="utf-8").read()

# The image line, and the substitution's DEFAULT rather than the variable name.
m = re.search(r"^\s*POSTGRES_TAG:\s*\$\{KIT_POSTGRES_TAG:-([^}]+)\}\s*$",
              compose, re.M)
if not m:
    problems.append(
        "docker-compose.yml does not pass POSTGRES_TAG as "
        "${KIT_POSTGRES_TAG:-<default>}; without a default the stack cannot "
        "start on a clone with no .env, and this check cannot compare anything"
    )
    compose_default = None
else:
    compose_default = m.group(1)

m2 = re.search(r"^KIT_POSTGRES_TAG=(.*)$", example, re.M)
if not m2:
    problems.append(
        ".env.example does not set KIT_POSTGRES_TAG. That is the state this check "
        "exists for: an unset variable means the compose default silently wins, "
        "which is the half of the disagreement nobody can see."
    )
    example_value = None
else:
    example_value = m2.group(1).strip()
    if not example_value:
        problems.append(
            "KIT_POSTGRES_TAG= with no value. bin/dev copies .env.example to .env, "
            "so an empty value here OVERRIDES the compose default with nothing — "
            "and `postgres:` is an image reference with no tag."
        )

if compose_default and example_value and compose_default != example_value:
    problems.append(
        f"the Postgres tag disagrees. docker-compose.yml defaults to "
        f"{compose_default!r} and templates/compose/.env.example sets "
        f"{example_value!r}. .env.example WINS, because bin/dev copies it to .env "
        f"on first run — so the stack a developer actually gets is "
        f"{example_value!r} while every document in this repository says "
        f"{compose_default!r}. Change both, or neither."
    )

# The variant is not decoration: pgvector arrives as a glibc-linked pglayers
# layer and does not load on alpine's musl. A tag that is silently switched back
# to `-alpine` produces an image that builds cleanly and cannot create an
# extension, which is the failure mode templates/compose/postgres/Dockerfile
# documents at length.
for value, where in ((example_value, ".env.example"),
                     (compose_default, "docker-compose.yml")):
    if value and "alpine" in value:
        problems.append(
            f"{where} pins the Postgres tag as {value!r} (an alpine variant). "
            "pgvector comes from pglayers as a glibc-linked layer and does not "
            "load on musl — measured, in templates/compose/postgres/Dockerfile: "
            "`Error loading shared library ld-linux-*.so` and `CREATE EXTENSION "
            "vector` reporting the extension is not available. Use the Debian "
            "variant."
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'postgres tag  (.env.example and compose agree, and it is not alpine)' postgres_tag_check

  # -------------------------------------------------------------------------
  # THE CLUSTER'S TOPOLOGY, AND EVERY ${env:} IT DEPENDS ON HAS TO REACH THE
  # CONTAINER.
  #
  # `collector_wiring_check` below holds that rule for the collector, and this is
  # the same rule for postgres — with a sharper edge, because postgres's inputs
  # are not endpoint URLs that fail loudly. `KIT_POSTGRES_DATABASES` unset does
  # not stop the container: the official entrypoint creates its default database
  # and reports ready, and the healthcheck passes. What is missing is the four
  # service databases, discovered later as four services whose migrations run
  # against a database that was never created.
  #
  # So this asserts the three agreements the topology rests on:
  #
  #   1. every KIT_POSTGRES_* the init script reads is passed by compose;
  #   2. the init script is MOUNTED where the image will run it;
  #   3. the image is BUILT from a Dockerfile that pins both tags, because a
  #      compose `build:` with no Dockerfile, or one naming a floating tag, is a
  #      cluster that either cannot start or silently changes major version.
  cluster_topology_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
compose_path = os.path.join(root, "templates/compose/docker-compose.yml")
init_path = os.path.join(root, "templates/compose/postgres/initdb/10-cluster.sh")
dockerfile_path = os.path.join(root, "templates/compose/postgres/Dockerfile")

problems = []
compose = open(compose_path, encoding="utf-8").read()

# (1) What the init script reads. `:-` defaults count as reads, because a
# default is kit deciding a value on the operator's behalf.
if not os.path.isfile(init_path):
    sys.exit(
        "templates/compose/postgres/initdb/10-cluster.sh does not exist, so the "
        "cluster provisions exactly one database — POSTGRES_DB, the admin one — "
        "and every service's migrations run against a database that was never "
        "created."
    )
init = open(init_path, encoding="utf-8").read()
read_vars = set(re.findall(r"\$\{(KIT_POSTGRES_[A-Z0-9_]+)[:\-]", init))

svc = re.search(r"^  postgres:\n(.*?)(?=^  [a-z]|\Z)", compose, re.M | re.S)
if not svc:
    sys.exit("docker-compose.yml has no postgres service")
block = svc.group(1)

# COMMENTS ARE STRIPPED BEFORE ANY ASSERTION ABOUT CONTENT, and this is the
# third time that has turned out to be load-bearing rather than tidiness — see
# `.env.example`'s tenant rule, which failed on the sentence documenting the
# value it was checking for. The mechanism is always the same: `in` over raw
# YAML cannot tell a sentence about a string from the string, so a check
# asserted against `block` is a check that a well-commented file satisfies by
# being well-commented.
#
# MEASURED, on the fix that added `${KIT_COMPOSE_DIR:-.}` to the initdb mount,
# which is to say on this packet's own change: the postgres block held the
# literal `/docker-entrypoint-initdb.d` TWICE — once as the mount, and once
# inside the comment explaining why the mount must be there. So when the real
# mount was deleted, breakage 70's mutation went green: the comment was still
# asserting the mount existed. A guard against the cluster provisioning nothing
# was reading a comment about that guard.
#
# The lesson generalises past this line, and that is why the stripping is here
# rather than inside the one assertion that happened to break: any check that
# reads compose TEXT to decide whether a thing is WIRED can be satisfied by a
# comment saying it is wired. The structured fix is to parse the YAML; until
# that happens, a comment is not a wire.
block_live = "\n".join(
    ln for ln in block.splitlines() if not ln.strip().startswith("#")
)
provided = set(re.findall(r"KIT_POSTGRES_[A-Z0-9_]+", block_live))
for name in sorted(read_vars - provided):
    problems.append(
        f"the init script reads ${{{name}}} but docker-compose.yml does not pass "
        f"{name} into the container, so it resolves empty and the cluster "
        f"provisions whatever the script's default is rather than what the "
        f"operator configured. This is the collector_wiring_check rule applied "
        f"where the failure is SILENT: postgres still starts, and the missing "
        f"thing is the databases."
    )

# (2) The mount. Without it the script never runs, and the symptom is again a
# healthy cluster holding one database. `block_live`, per the note above.
if "/docker-entrypoint-initdb.d" not in block_live:
    problems.append(
        "the postgres service does not mount anything at "
        "/docker-entrypoint-initdb.d, so initdb/10-cluster.sh never runs. The "
        "cluster comes up healthy with a single database and no per-service "
        "roles, and nothing reports it."
    )

# (3) The build. `image:` alone would be a pull of something kit does not
# control, and `build:` with no `dockerfile:` is a convention rather than a
# statement.
if "build:" not in block:
    problems.append(
        "the postgres service has no build: stanza. The image is the official "
        "postgres image plus the pglayers layer, which has to be composed — a "
        "pull would be either a third-party postgres replacement or a cluster "
        "with no pgvector."
    )
else:
    if "dockerfile:" not in block:
        problems.append(
            "the postgres build: stanza names no dockerfile:, so which file is "
            "built is a convention rather than a statement"
        )
    if not os.path.isfile(dockerfile_path):
        problems.append("templates/compose/postgres/Dockerfile does not exist")
    else:
        df = open(dockerfile_path, encoding="utf-8").read()
        for arg in ("POSTGRES_TAG", "PGVECTOR_TAG"):
            if not re.search(rf"^ARG {arg}=", df, re.M):
                problems.append(
                    f"the cluster Dockerfile declares no ARG {arg}, so the tag "
                    f"compose passes as a build arg is ignored and the image "
                    f"silently uses whatever the ARG default is"
                )
        for tag in re.findall(r"^\s*FROM\s+(\S+)", df, re.M):
            if tag.endswith(":latest") or ":" not in tag.rsplit("/", 1)[-1]:
                problems.append(f"the cluster Dockerfile has an unpinned FROM: {tag}")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'the cluster  (one database + role per service, wired end to end)' cluster_topology_check

  # -------------------------------------------------------------------------
  # KIT'S OWN HARNESSES DECLARE A TENANT, without needing a docker daemon.
  #
  # This check exists because of a regression that 214 static checks and 86
  # self-test proofs all passed straight through. Removing the `:-` fallback from
  # `KIT_POSTGRES_DATABASES` was correct — a template that defaults the tenant
  # list to one of its own services hands every adopter that forgets to declare
  # itself somebody else's database, and identity asked for `identity` and got
  # `courier`. But `tests/stack_live_test.sh` is a CONSUMER of that template, and
  # it had never declared one. Nothing static looked: every other check in this
  # file reads the template or a service's committed files, and kit's own test
  # harnesses are none of those.
  #
  # The live test caught it, in 10 minutes, with a docker daemon and eight
  # containers. This catches the same mistake in about a second with neither.
  #
  # WHAT IT DOES NOT DO, because the version that did this was wrong twice. It
  # does not grep for the string `KIT_POSTGRES_DATABASES` — `templates/compose/
  # .env.example` mentions that name in prose, and `tests/stack_live_test.sh`
  # mentions it in a comment, so a substring search is satisfied by text
  # describing the variable rather than by an assignment of it. It finds the
  # ASSIGNMENT, at the start of a line, with a value, and it reads the heredoc
  # body rather than the whole file, because a real assignment outside the
  # heredoc would not reach the `.env` either.
  #
  # The rule it enforces: any file under tests/ that writes a `.env` carrying a
  # `KIT_` variable must declare a tenant in the same heredoc. That is derived
  # from the files rather than listed, so a new harness is covered the day it is
  # written instead of the day someone remembers to add it.
  harness_tenant_check() {
    python3 - <<'PY'
import pathlib, re, sys

problems = []
checked = 0

# A heredoc that writes a .env. The delimiter is captured so the BODY can be
# read: an assignment outside the body is not in the file that gets written.
heredoc = re.compile(r"cat\s*>\s*\"?\$?\{?SERVICE\}?/\.env\"?\s*<<-?\s*'?([A-Za-z_][A-Za-z0-9_]*)'?")

for path in sorted(pathlib.Path("tests").glob("*.sh")):
    text = path.read_text()
    for match in heredoc.finditer(text):
        delim = match.group(1)
        rest = text[match.end():]
        end = re.search(rf"^\s*{delim}\s*$", rest, re.M)
        if not end:
            continue
        body = rest[:end.start()]
        # Only harnesses that actually drive the compose template count. One
        # that writes an .env with no KIT_ variable at all is not a stack
        # consumer and is not this check's business.
        if not re.search(r"^KIT_[A-Z0-9_]+=", body, re.M):
            continue
        checked += 1
        if not re.search(r"^KIT_POSTGRES_DATABASES=\S", body, re.M):
            problems.append(
                f"{path} writes an .env with KIT_ variables but declares no "
                f"KIT_POSTGRES_DATABASES; the cluster init script refuses an unset "
                f"tenant list by name and the stack will not come up"
            )

if checked == 0:
    sys.exit("no .env-writing harness found — the rule below is proving nothing")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'kit harnesses  (every .env-writing harness declares its own tenant)' harness_tenant_check

  # -------------------------------------------------------------------------
  # THE CONNECTION BUDGET, AS AN ARITHMETIC IDENTITY rather than a comment.
  #
  # The pooler decision is "no pooler, and a stated budget instead" — and a
  # stated budget that can be set below what the stack needs is a comment. This
  # is the arithmetic that makes it a check:
  #
  #     max_connections  >=  (databases declared x per-role limit)  +  reserved
  #
  # Read out of the three files that hold the three numbers, so the check fails
  # when any one of them moves without the others. Postgres reserves
  # `superuser_reserved_connections` (3 by default) plus its own autovacuum and
  # background workers, which is the `reserved` term.
  connection_budget_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
example = open(
    os.path.join(root, "templates/compose/.env.example"), encoding="utf-8"
).read()
compose = open(
    os.path.join(root, "templates/compose/docker-compose.yml"), encoding="utf-8"
).read()
init = open(
    os.path.join(root, "templates/compose/postgres/initdb/10-cluster.sh"),
    encoding="utf-8",
).read()

problems = []

# COMMENTS ARE STRIPPED before the fallback scan, for the same reason the
# .env.example check strips them: this file quotes the old broken defaults in
# prose, and a scanner that cannot tell a sentence about a value from the value
# reports the defect it is documenting.
compose_live = "\n".join(
    ln for ln in compose.splitlines() if not ln.strip().startswith("#")
)

def env_value(name):
    m = re.search(rf"^{name}=(.*)$", example, re.M)
    return int(m.group(1)) if m and m.group(1).strip().isdigit() else None

def compose_fallback(name):
    m = re.search(rf"\$\{{{name}:-(\d+)\}}", compose_live)
    return int(m.group(1)) if m else None

def script_default(name):
    m = re.search(rf'^\s*{name}="\$\{{{name}:-(\d+)\}}"', init, re.M)
    return int(m.group(1)) if m else None

# THE VALUE THAT ACTUALLY TAKES EFFECT, resolved through the whole chain rather
# than read out of one file.
#
# This check used to read `.env.example` and nothing else, and that was correct
# while `.env.example` carried a value for everything. It no longer does, on
# purpose: a value in `.env.example` is COPIED into each service's `.env` by
# `bin/dev` and outranks the service's own committed compose file, so those two
# lines are now deliberately empty for anything a service declares for itself.
# Reading only that file made this check stop describing the system - it began
# reporting a cluster that cannot happen, over a default that was the defect.
#
# So: `.env.example` if it sets one, else the compose file's `:-` fallback, else
# the init script's own fallback. That is the order the container sees, and
# agreeing with it is the whole point of a budget check.
def effective_int(name):
    for source in (env_value(name), compose_fallback(name), script_default(name)):
        if source is not None:
            return source
    return None

max_conn = effective_int("KIT_POSTGRES_MAX_CONNECTIONS")
role_limit = effective_int("KIT_POSTGRES_ROLE_CONNECTIONS")

for name, value in (
    ("KIT_POSTGRES_MAX_CONNECTIONS", max_conn),
    ("KIT_POSTGRES_ROLE_CONNECTIONS", role_limit),
):
    if value is None:
        problems.append(
            f"nothing sets {name} to an integer - not .env.example, not "
            f"docker-compose.yml's :-fallback, not initdb/10-cluster.sh's - so the "
            f"connection budget cannot be checked and a service that raises one of "
            f"them has no idea whether the cluster can absorb it"
        )
if problems:
    sys.exit("; ".join(problems))

# THE TENANT COUNT, and this is where an empty default stops being a gap.
#
# `KIT_POSTGRES_DATABASES` now defaults to empty on purpose - kit no longer names
# one of its own services as the fleet's default tenant - so the example stack
# provisions zero service databases and the arithmetic below would be
# `0 x role_limit + 8`, which is true of every number ever written and so proves
# nothing. A check that cannot fail is a check that has stopped working, which
# is the failure this repository exists to refuse, so the count does not come
# from the default: it comes from the size of the fleet the template claims to
# serve.
#
# That claim is stated in this repository's own prose - "the nine services share
# all three", "nine services at the per-role limit above exceed it" - so the
# budget is asserted against nine tenants whether or not a given developer has
# adopted nine of them. Lower `KIT_POSTGRES_MAX_CONNECTIONS` and this goes red
# on the template alone, which is the point: the budget has to be right for the
# fleet the template is FOR, not only for whoever happened to run it.
FLEET_SERVICES = 9

declared = None
for source in (example, compose_live):
    m = re.search(r"^KIT_POSTGRES_DATABASES=(.*)$", source, re.M) or re.search(
        r"KIT_POSTGRES_DATABASES:\s*\$\{KIT_POSTGRES_DATABASES:-([^}]*)\}", source
    )
    if m and m.group(1).strip():
        declared = m.group(1)
        break

if declared is None:
    tenants = FLEET_SERVICES
    basis = f"no tenant is declared by default, so the fleet this template is for ({tenants} services) is used"
else:
    dbs = [d.strip() for d in declared.split(",") if d.strip()]
    service_dbs = [d for d in dbs if not d.startswith("KIT_")]
    tenants = len(service_dbs)
    basis = f"{tenants} database(s) declared"

# The script's own default must not disagree with the effective one, for the same
# reason the tag check exists: two files, one fact, and the one that is silently
# overridden is the one nobody sees.
for name, effective, from_script in (
    ("KIT_POSTGRES_ROLE_CONNECTIONS", role_limit, script_default("KIT_POSTGRES_ROLE_CONNECTIONS")),
):
    if from_script is not None and from_script != effective:
        problems.append(
            f"{name}: the effective default is {effective} and initdb/10-cluster.sh's "
            f"fallback says {from_script}. The script only reaches its fallback "
            f"when compose does not pass the variable, so the two disagreeing is "
            f"a shape that works on a developer's machine and not in CI."
        )

# Postgres's own reserves: superuser_reserved_connections (3) plus autovacuum
# and background workers, which are not client connections but do occupy
# superuser-reserved slots during a heavy autovacuum. 8 is the measured-safe
# margin and is asserted rather than assumed.
RESERVED = 8
needed = tenants * role_limit + RESERVED
if max_conn < needed:
    problems.append(
        f"KIT_POSTGRES_MAX_CONNECTIONS is {max_conn} but the topology needs "
        f"{tenants} databases x {role_limit} connections "
        f"(KIT_POSTGRES_ROLE_CONNECTIONS) + {RESERVED} for Postgres's own "
        f"reserves = {needed} ({basis}). With no pooler in the path, the "
        f"connection budget IS the isolation story's other half: a service that "
        f"cannot get a connection cannot reach another service's data, so an "
        f"undersized budget shows up as a total outage rather than as a refused "
        f"query."
    )

if problems:
    sys.exit("; ".join(problems))
print(
    f"       budget: {max_conn} >= {tenants} db x {role_limit} + "
    f"{RESERVED} reserved = {needed}  ({basis})"
)
PY
  }
  # `max_connections`, which is the variable this check actually reads
  # (`KIT_POSTGRES_MAX_CONNECTIONS`) and the GUC it compares. The label said
  # `max_connions` — a different spelling of a thing that does not exist, in the
  # one line a reader greps for when they want to know what this check measures.
  # Self-test breakage 71 asserts the label as its needle, so the label is a
  # contract: renaming it silently un-proofs the breakage, which is the same
  # coupling as the `callable path` check and worth the same discipline.
  check 'the connection budget  (max_connections covers the declared topology)' connection_budget_check

  # Every database snippet must PARSE in its own language, and the parse has to
  # be the LANGUAGE's own — a regex is not a parser.
  #
  # The otel snippets above exist because `rack_middleware.rb.snippet` shipped
  # with `c.use_all, :auto_instrumentation`, which is not valid Ruby, and nothing
  # in this file looked at it. A connection snippet has a higher cost for the
  # same failure: a service that boots and then cannot reach its database fails
  # in a way that looks like a cluster problem.
  #
  # Ruby and Node are the interesting cases and both are skipped loudly when the
  # toolchain is absent rather than passed over, because this snippet is a file a
  # service copies verbatim.
  section 'static: every database snippet parses in its own language'
  db_snippet_dir="$TMP/db-snippets"
  rm -rf "$db_snippet_dir"
  mkdir -p "$db_snippet_dir"

  # <file>|<extension>|<command...>
  #
  # Only the languages a single command can honestly parse are here. Elixir and
  # Rust are NOT, and each has a block below: `.exs` is EVALUATED rather than
  # compiled, and `rustc` distinguishes an unresolved crate from a syntax error
  # only by its error CODES. Both first shipped in this generic loop and both
  # were wrong there — the generic form reported a missing `psycopg_pool` as a
  # syntax error in python, and reported an unresolved `tokio_postgres` as one in
  # rust, which is precisely the defect this repository's rules call out.
  #
  # node and TypeScript are decided on EXIT STATUS rather than on filtered
  # output: `node --check` writes its warnings to stderr and exits 0, so
  # grepping for a clean result reports a successful parse as a failure whenever
  # node happens to print a hint line. The status is the verdict.
  while IFS='|' read -r file ext cmd; do
    [ -n "$file" ] || continue
    src="$ROOT/templates/database/${file}"
    [ -f "$src" ] || continue
    # Named <lang><ext>, NOT <basename><ext>. The basename is
    # `database.ts.snippet`, so the copy would be `database.ts.snippet.ts` — and
    # node's type stripper refuses that:
    #
    #   TypeError [ERR_UNKNOWN_FILE_EXTENSION]: Unknown file extension ".ts"
    #
    # which is a check reporting a perfectly valid TypeScript file as unparseable
    # on the strength of a filename this loop invented. The extension therefore
    # comes from the TABLE rather than from the filename, because the filename's
    # last dot-segment is `snippet`.
    lang="${file%%/*}"
    copy="$db_snippet_dir/$lang.$ext"
    cp "$src" "$copy"
    tool="${cmd%% *}"
    if command -v "$tool" >/dev/null 2>&1; then
      if out=$($cmd "$copy" 2>&1); then
        report PASS "database/${file}  (parses as $ext)"
      else
        report FAIL "database/${file}  (parses as $ext)"
        printf '%s\n' "$out" | head -8 | sed 's/^/       /'
      fi
    else
      report SKIP "database/${file}  (parses as $ext — $tool not installed)"
    fi
  done <<'DBSNIPPETS'
go/database.go.snippet|.go|gofmt -e -l
python/database.py.snippet|.py|python3 -m py_compile
ruby/database.yml.snippet|.yml|yaml_ok
DBSNIPPETS

  # Three of those need their own treatment, because the generic command cannot
  # express them. All three copy their own file first — the generic loop's table
  # deliberately does not list them, so there is one place per language that
  # decides how it is parsed and no second spelling to keep in step.
  #
  # Elixir: a `.exs` file is EVALUATED, not merely compiled, so this is a real
  # load. The snippet is written to be loadable with the standard library alone
  # — it defines the settings module and deliberately does NOT define the
  # `Courier.Repo` module, because `use Ecto.Repo` needs a dependency kit must
  # not have and a module that cannot compile is a module the gate cannot check.
  # The bar is therefore "loads with no CompileError and no SyntaxError", and
  # the error COUNT rather than a grep for the word "error", because warnings
  # about unresolved modules contain that word too.
  #
  # This shipped wrong twice. It first ran through the generic loop, which
  # reported the snippet's own `use Ecto.Repo` as a syntax error; and it then
  # reported a CompileError that was in fact an unresolved module. Both were the
  # same mistake — treating a missing DEPENDENCY as a parse failure.
  if have elixir; then
    cp "$ROOT/templates/database/elixir/repo.exs.snippet" "$db_snippet_dir/elixir.exs"
    out="$(elixir "$db_snippet_dir/elixir.exs" 2>&1 || true)"
    if printf '%s\n' "$out" | grep -qE '\*\* \((Compile|Syntax)Error\)|^\s*error:'; then
      report FAIL 'database/elixir/repo.exs.snippet  (loads as .exs)'
      printf '%s\n' "$out" | head -8 | sed 's/^/       /'
    else
      report PASS 'database/elixir/repo.exs.snippet  (loads; stdlib only, as intended)'
    fi
  else
    report SKIP 'database/elixir/repo.exs.snippet  (elixir not installed)'
  fi

  # Rust: `rustc --emit=metadata` fails with E0432/E0433 on an unresolved crate,
  # which is NOT a syntax error and is exactly what a dependency-free kit should
  # produce. So the check is "no error other than an unresolved-crate one", and it
  # compares error CODES rather than lines — rustc's trailing "aborting due to N
  # previous errors" carries no code, and a line-based test reports that summary
  # as a syntax error. Which is what the otel loop's comment says about its own
  # first version of this check, and about running `rustfmt` here: rustfmt wants
  # an edition, says so on stderr, and a check that reads output rather than a
  # status calls that a broken parse.
  if have rustc; then
    cp "$ROOT/templates/database/rust/database.rs.snippet" "$db_snippet_dir/rust.rs"
    out="$(rustc --edition 2021 --crate-type lib --emit=metadata \
      -o /dev/null "$db_snippet_dir/rust.rs" 2>&1 || true)"
    codes="$(printf '%s\n' "$out" | grep -oE '^error\[E[0-9]+\]' | sort -u)"
    unexpected="$(printf '%s\n' "$codes" | grep -vE 'E0432|E0433|E0463' || true)"
    if [ -n "$unexpected" ]; then
      report FAIL 'database/rust/database.rs.snippet  (parses as .rs)'
      printf '%s\n' "$unexpected" | sed 's/^/       /'
    elif [ -z "$codes" ]; then
      report PASS 'database/rust/database.rs.snippet  (parses; crates resolved)'
    else
      report PASS 'database/rust/database.rs.snippet  (parses; crates unresolved, as expected)'
    fi
  else
    report SKIP 'database/rust/database.rs.snippet  (rustc not installed)'
  fi

  # TypeScript: node's own type stripper is a parser, and it is in the node
  # already running this gate. No typescript-eslint, no install.
  if have node; then
    # On EXIT STATUS, deliberately. `node --check` prints its warnings to stderr
    # and exits 0, so a check that filters the output and looks for emptiness
    # reports a clean parse as a failure whenever node adds a hint line — which
    # it did here ("(Use `node --trace-warnings ...`)") and which the otel loop's
    # version of this check hits the same way.
    cp "$ROOT/templates/database/node/database.ts.snippet" "$db_snippet_dir/node.ts"
    out="$(node --experimental-strip-types --check "$db_snippet_dir/node.ts" 2>&1)" \
      && node_status=0 || node_status=$?
    if [ "$node_status" -eq 0 ]; then
      report PASS 'database/node/database.ts.snippet  (parses as .ts)'
    else
      report FAIL 'database/node/database.ts.snippet  (parses as .ts)'
      printf '%s\n' "$out" | head -8 | sed 's/^/       /'
    fi
  else
    report SKIP 'database/node/database.ts.snippet  (node not installed)'
  fi

  # -------------------------------------------------------------------------
  # bin/dev's escape hatch must actually WORK, and "must work" is a claim only
  # running it settles.
  #
  # `set -u` plus an empty array is a portable-shell trap: macOS ships bash 3.2,
  # where `"${a[@]}"` on an empty array is an "unbound variable" ERROR rather
  # than nothing. kit-03 shipped `local profile_args=()` and expanded it
  # unconditionally, so `KIT_DEV_PROFILES= bin/dev up` — the DOCUMENTED way to
  # run the stack without the observability backends — died on line one with
  #
  #   bin/dev: line 120: profile_args[@]: unbound variable
  #
  # The failure is spectacular precisely because the default path works, so
  # nothing else in the suite noticed. Here the script is actually executed with
  # the variable empty and is only required to get past argument parsing, which
  # is where the trap bites; a stub `docker` on PATH keeps the test hermetic and
  # fast, because what is under test is the shell, not compose.
  dev_escape_hatch_check() {
    local stub sandbox out ec=0 kitcheck
    stub="$TMP/dev-hatch-stub"
    sandbox="$TMP/dev-hatch"
    # The stub KIT TREE, as a separate directory. The sandbox below is a service
    # repository, and after this packet a service repository holds NONE of the
    # stack: no docker-compose.yml of kit's, no otel-collector.yml, no vendor
    # config directories. Everything `bin/dev` mounts comes from the tree it
    # fetches, so the fixture has to have one — pointed at with `KIT_STACK_DIR`,
    # which is a checkout a person named rather than one that was fetched.
    # The stub kit tree, with exactly the directories a cheap-default run needs:
    # the two config directories that are FETCHED, and NO metrics-store
    # directory. That absence is the point of the fixture now. `stack_is_usable`
    # used to require the metrics store's directory, and a fixture that carried
    # it proved nothing about whether the check and the default agree — it
    # passed for the same reason the old default passed. A fetched tree with only
    # tempo/ and loki/ in it is what a cheap `bin/dev up` actually resolves, and
    # this check requires the script to accept it.
    kitcheck="$TMP/dev-hatch-kit"
    rm -rf "$stub" "$sandbox" "$kitcheck"
    mkdir -p "$stub" "$sandbox/bin"
    mkdir -p "$kitcheck/templates/compose" "$kitcheck/templates/compose/tempo" \
      "$kitcheck/templates/compose/loki" \
      "$kitcheck/templates/compose/grafana/provisioning"
    : >"$kitcheck/templates/compose/docker-compose.yml"
    : >"$kitcheck/templates/compose/otel-collector.yml"
    : >"$kitcheck/templates/compose/.env.example"
    printf '%s\n' "0000000000000000000000000000000000000000" >"$sandbox/kit.ref"
    cat >"$stub/docker" <<'STUB'
#!/usr/bin/env bash
# Reports readiness so `bin/dev up` believes the stack came up, and does
# nothing else. What is under test is the SHELL, not compose.
case "$*" in
  *" version"*) echo "Docker Compose version v2.0.0"; exit 0 ;;
esac
case "$1" in
  --profile) shift 2 ;;
esac
exit 0
STUB
    chmod +x "$stub/docker"
    # The sandbox is a service repository and NOTHING ELSE: no compose file of
    # kit's, no collector config, no `.env`. That is the shape this packet leaves
    # behind, and the fixture has to be the shape or the check proves a world
    # that no longer exists — the first version of this sandbox carried five
    # empty files that `require_files` demanded, and the moment `require_files`
    # went away the fixture stopped reaching `up` at all.
    #
    # `KIT_STACK_DIR` is how the escape hatch is exercised without a network: it
    # is a checkout a person named on this run, which is source 1 of the four in
    # `resolve_stack` and the only one that skips git entirely.
    cp "$ROOT/templates/bin/dev.sh" "$sandbox/bin/dev"

    # `KIT_DEV_PROFILES=''` and not `KIT_DEV_PROFILES=`: shellcheck reads the
    # latter as a typo, and it is right to.
    out="$(cd "$sandbox" && KIT_DEV_PROFILES='' KIT_STACK_DIR="$kitcheck" \
      PATH="$stub:$PATH" bash ./bin/dev up 2>&1)" || ec=$?
    case "$out" in
      *"unbound variable"*)
        echo "the documented escape hatch KIT_DEV_PROFILES= is broken:"
        printf '%s\n' "$out" | head -3
        return 1
        ;;
      # Both halves are asserted, and the second is not decoration. Reaching the
      # migration step proves the profile expansion survived; that the run got
      # all the way there on a sandbox with NO `.env` and no stack of its own
      # proves the fetch path does not require either. A fixture that wrote a
      # `.env` would pass the first and silently not be testing the second.
      *"no migration command found"*) return 0 ;;
      *)
        echo "bin/dev with KIT_DEV_PROFILES= exited $ec without reaching the"
        echo "migration step; expected the clean 'no migration command' exit."
        printf '%s\n' "$out" | head -6
        return 1
        ;;
    esac
  }
  check 'templates/bin/dev.sh  (KIT_DEV_PROFILES= escape hatch actually runs)' dev_escape_hatch_check

  # -------------------------------------------------------------------------
  # THE FLEET GATE, and it is RED on master. That is the point, and the shape is
  # the same as D4: three repositories that do not spell the same gate the same
  # way is invisible to any check that reads only one of them, so kit's gate
  # reads the OTHER repositories rather than trusting that they adopted it.
  #
  # Four failure modes, one check each, in tests/fleet_check.py:
  #   - a service carrying a copy of the shared infrastructure
  #   - a service that weakened the redaction boundary
  #   - an otel-collector.yml that exists but that nothing ever starts
  #   - a pin that is unpinned, or points at a branch
  #
  # IT SKIPS LOUDLY WHEN THERE IS NO FLEET, and that is not a detail. A clone of
  # kit on CI has no siblings, and "no fleet was found" is not "the fleet is
  # clean" — the same `unknown` vs `current` confusion tests/staleness.py exists
  # to avoid. A gate that reports the second when it means the first is a gate
  # that gets muted, and this one is going to be red a lot on purpose.
  #
  # `KIT_FLEET` is the seam, and it exists so self_test.sh can point the check at
  # a FIXTURE fleet. Without it every breakage below would depend on the real
  # fleet being present and dirty, which is a proof that passes when the fleet is
  # absent — the exact shape this repository keeps warning about.
  #
  # The SKIP decision is `fleet_check.py`'s, not this file's, and the reason is a
  # disagreement that was real. The first version guarded the call with its own
  # "are there any sibling entries?" test — `ls -A ..` minus kit's own worktrees.
  # A self-test's throwaway directory HAS sibling entries (one per breakage) and
  # none of them is a repository, so the guard said "there is a fleet", ran the
  # check, and the check exited 2 with "no cafaye repositories". The self-test's
  # CONTROL would have gone red, which D13 treats as blocking the packet, for a
  # reason that has nothing to do with the packet.
  #
  # So there is exactly one predicate for "is there a fleet", it lives beside the
  # code that knows what a repository is, and it answers with a machine-readable
  # marker. `check` cannot express three outcomes, which is why this is written
  # out rather than delegated: a SKIP is not a PASS that happened quietly.
  #
  # THE ADOPTION CEILING, and it is the fourth outcome this block has to express.
  # `fleet_check.py` answers three questions and this file must not collapse
  # them: is there a fleet (SKIP), is any ADOPTING repository defective (FAIL),
  # and is any UNADOPTED repository carrying debt (PASS, with the debt printed).
  # The three outcomes are read off the exit code plus the `CEILING fleet:` line
  # the check always prints, rather than from a fourth flag, because a fourth
  # flag is a fourth thing to keep in step with the check that emits it.
  #
  # WHY A PASS CAN CARRY FINDINGS, and why this is not the softening the packet
  # refuses. The strictness has not moved anywhere weaker; it has moved to WHERE
  # ADOPTION EXISTS. The same four predicates, the same messages, the same
  # severity — and the moment a repository commits `git -C ../kit rev-parse HEAD
  # > kit.ref`, every finding inside it becomes a FAIL with no discretion and no
  # re-review. A gate that stays red for thirteen findings no repository has
  # agreed to fix is a gate whose red stops being read, and a gate nobody reads
  # catches nothing. This is core-16's shape for a missing OpenAPI document, and
  # it is a WAVE, not a discount: each repository's adoption converts its own
  # named debt into a failure.
  #
  # The count is printed because a ceiling with no number on it cannot be
  # argued about: "PASS" and "PASS with 13 named warnings across 6 repositories"
  # are different statements, and only the second is true.
  section 'static: the fleet adopts the stack rather than copying it'
  fleet_out='' fleet_ec=0
  fleet_out="$("$PY" "$ROOT/tests/fleet_check.py" --kit "$ROOT" \
    --repos-dir "${KIT_FLEET:-$ROOT/..}" --no-fleet 2>&1)" || fleet_ec=$?
  case "$fleet_out" in
    *FLEET-ABSENT:*)
      report SKIP 'fleet adoption (no cafaye repository on this machine — set KIT_FLEET=<dir>)'
      ;;
    *)
      if [ "$fleet_ec" -eq 0 ]; then
        if printf '%s\n' "$fleet_out" | grep -q '^WARN fleet: '; then
          fleet_debt=$(printf '%s\n' "$fleet_out" | sed -n 's/^WARN fleet: //p')
          report PASS "fleet  (adopting repositories clean; $fleet_debt — adoption debt, non-fatal until each repository writes kit.ref)"
        else
          report PASS 'fleet  (no stale copy, no weakened boundary, no dead config, every ref pinned)'
        fi
        printf '%s\n' "$fleet_out" | sed 's/^/       /'
      else
        report FAIL 'fleet  (no stale copy, no weakened boundary, no dead config, every ref pinned)'
        printf '%s\n' "$fleet_out" | sed 's/^/       /'
      fi
      ;;
  esac

  # -------------------------------------------------------------------------
  # THE GENERATED LOCAL STACK IS NOT A SOURCE FILE, and this is the check that
  # stops it being committed as one. It is deliberately NOT part of the fleet
  # gate above, and the two reasons are both load-bearing.
  #
  # SCOPE. That gate checks repositories that DECLARE LOCAL INFRASTRUCTURE — a
  # root compose file or a root collector config. This one checks every
  # repository that HAS A `cafaye.yml`, which is a different set: `core`, `docs`,
  # `muse`, `gateway` and `cafaye-ts` have manifests and no stack, and `core` is
  # the repository that had this file COMMITTED. Folding it in would have scoped
  # the check that matters most to the predicate that excludes it.
  #
  # SEVERITY. Every finding above is routed through the ADOPTION CEILING: a
  # warning in a repository that has not adopted `kit.ref`, a failure in one
  # that has. That ceiling is right there and wrong here, because it is about
  # WHO OWNS A DEBT, and this defect has no adopter. A repository that has never
  # heard of kit's stack still must not commit its generated one; there is no
  # wave that makes that acceptable.
  #
  # It reads its population off the FILESYSTEM — a `cafaye.yml` at the root is
  # what `caf dev` itself uses to decide a directory is a project at all — so a
  # repository that grows a manifest is in scope the day it does, with nothing
  # here edited. That is the whole argument for a guard at all: the list that
  # prompted this work named five repositories and was correct only because
  # somebody had run `caf dev` on that laptop and left a file behind. Five
  # further repositories had manifests and no ignore entry and were invisible to
  # it, and a list cannot tell you about a repository nobody has visited.
  #
  # SKIPS LOUDLY WHEN THERE IS NO FLEET, on the same `FLEET-ABSENT:` marker the
  # gate above prints, so a clone of kit on CI reports that it looked at nothing
  # rather than that the fleet is clean.
  #
  # AND IT RESPECTS THE SCOPE DECISION IN ITS EXIT STATUS, which is the whole
  # difference between a gate that can go green on this machine and one that
  # cannot. `MVP-SCOPE.md` — one directory above the fleet, in no repository —
  # holds `billing`, `darkroom` and `muse` out of the MVP until it is launched
  # and selling, and two of them carry this exact defect TODAY. The first
  # version of this section failed on both, so merging it would have made kit's
  # gate permanently red on a tree nobody is permitted to fix — and the
  # predictable response to a gate that cannot go green is a human turning it
  # off, which would have stopped the check running in the nine repositories that
  # CAN be fixed today. A gate that cannot go green teaches the fleet to ignore
  # gates, which is worse than not shipping the check.
  #
  # So the FINDINGS stay exactly as they were and only the exit status is
  # routed: a finding in an in-scope repository fails, a finding in a frozen one
  # is printed and does not, and the row below says which of the two happened.
  # The frozen set is READ from that file through `--scope`, never written down
  # here or in the checker, so the day the scope lifts the exemptions lift with
  # it rather than outliving the decision that granted them. `KIT_SCOPE_FILE`
  # overrides the location for a machine whose fleet is not beside its
  # directive, and the check's own default is the directory above the fleet, so
  # it also works when it is run on its own.
  section 'static: the generated local stack is not committed'
  gen_out='' gen_ec=0
  gen_out="$("$PY" "$ROOT/tests/generated_stack_check.py" --repos-dir "${KIT_FLEET:-$ROOT/..}" --scope "${KIT_SCOPE_FILE:-$ROOT/../../MVP-SCOPE.md}" --no-fleet 2>&1)" || gen_ec=$?
  # THE ROW NAMES WHICH VERDICT THIS IS, because a green that came from frozen
  # repositories and a green that came from a clean fleet are different facts
  # and the summary line is where a reader looks first. Read out of the output
  # rather than restated here, because a second copy of the count is a second
  # copy to be wrong.
  gen_label='generated stack  (no repository commits the file caf dev generates)'
  case "$gen_out" in
    *SCOPE-ABSENT:*)
      gen_label="$gen_label; no scope decision read, so nothing is exempt"
      ;;
  esac
  # `sed -n` reads all of its input, so this cannot SIGPIPE the writer — the
  # broken-pipe shape `expect_red_check` documents, and the reason those
  # assertions match a captured variable instead.
  gen_frozen=$(printf '%s\n' "$gen_out" | sed -n 's/^FROZEN-FINDINGS: \([0-9][0-9]*\) .*/\1/p')
  case "$gen_frozen" in
    ''|0) ;;
    *) gen_label="$gen_label; $gen_frozen in frozen repositories, reported not counted" ;;
  esac
  case "$gen_out" in
    *FLEET-ABSENT:*)
      report SKIP 'generated stack  (no cafaye repository on this machine - set KIT_FLEET=<dir>)'
      ;;
    *)
      if [ "$gen_ec" -eq 0 ]; then
        report PASS "$gen_label"
        printf '%s\n' "$gen_out" | sed 's/^/       /'
      else
        report FAIL "$gen_label"
        printf '%s\n' "$gen_out" | sed 's/^/       /'
      fi
      ;;
  esac

  # -------------------------------------------------------------------------
  # THE COLLECTOR CONFIG IS MOUNTED FROM THE TREE `bin/dev` FETCHED, and this is
  # the check for a defect that ONLY RUNNING THE STACK could find.
  #
  # `templates/compose/otel-collector.yml` carries the redaction allowlist. Once
  # the file is no longer copied into the service, the compose file must mount it
  # from `${KIT_COMPOSE_DIR:-.}`, and `bin/dev` must set that variable to the
  # FETCHED tree. Get either half wrong and nothing above notices: the compose
  # file parses, `docker compose config` renders the same project either way, and
  # every static check in this file stays green — because the value of the
  # variable is not a property of the YAML.
  #
  # What it actually does when it is wrong: the mount resolves to a path that does
  # not exist, and Docker's answer to a missing bind source is to CREATE A
  # DIRECTORY. The collector then exits naming a file type:
  #
  #   failed to read configFile /etc/tempo/tempo.yaml: is a directory
  #
  # which says nothing about the thing that is wrong, and arrives four containers
  # after a stack that was supposed to come up. `tests/stack_live_test.sh` is what
  # found it, by bringing the fetched stack up and reading the collector's own
  # mount back with `docker inspect`. This check is the static half of the same
  # property, so the defect cannot be re-introduced between one live run and the
  # next.
  #
  # It asserts BOTH halves. Checking the compose file alone would pass on a
  # `bin/dev` that stopped exporting `KIT_COMPOSE_DIR`; checking `bin/dev` alone
  # would pass on a compose file that stopped using the variable. The defect is
  # in their AGREEMENT, so the check is over their agreement.
  stack_mount_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
compose = open(f"{root}/templates/compose/docker-compose.yml", encoding="utf-8").read()
dev = open(f"{root}/templates/bin/dev.sh", encoding="utf-8").read()

problems = []

# 1. Every vendor config kit hands out is mounted through the variable, and none
#    of them through a bare `./`. A bare `./` was correct when the file sat in the
#    service and is wrong now that it does not, and nothing else in the tree would
#    notice the difference.
#
#    It was five. The metrics store's config went with the store, and this list is
#    the one place in the gate where a config that nobody mounts is invisible:
#    nothing renders a compose file, nothing resolves a bind source, and an
#    unreferenced `mimir.yaml` in the tree would have gone on being fetched by
#    every service that adopts kit for ever.
VENDOR_MOUNTS = {
    "otel-collector.yml": "/etc/otel/otel-collector.yml",
    "tempo/tempo.yaml": "/etc/tempo/tempo.yaml",
    "loki/loki-config.yaml": "/etc/loki/loki-config.yaml",
    "grafana/provisioning": "/etc/grafana/provisioning",
}
for source, destination in VENDOR_MOUNTS.items():
    mounted = [ln for ln in compose.splitlines()
               if source in ln and destination in ln]
    if not mounted:
        problems.append(
            f"docker-compose.yml does not mount {source} into {destination} at all"
        )
        continue
    if not any("${KIT_COMPOSE_DIR:-.}" in ln for ln in mounted):
        problems.append(
            f"docker-compose.yml mounts {source} without ${KIT_COMPOSE_DIR:-.}. "
            f"That path is relative to wherever compose runs, and `bin/dev` runs it "
            f"from the service root - where this file no longer is. Docker creates a "
            f"DIRECTORY at a missing bind source and the collector exits naming a "
            f"file type instead of the mount that is wrong."
        )

# 1a. ...AND NOTHING IN THE COMPOSE DIRECTORY IS UNREFERENCED, which is the other
#      half of "nothing names a container that does not exist" and the half a
#      hand-written list above can never hold by itself.
#
#      The list is a list, so a config file added under `templates/compose/` and
#      not added here is mounted by nothing, fetched by every adopting service,
#      and reported as `current` by the staleness reporter forever. That is the
#      silent half-removal this packet exists to close, and it is measurable:
#      every file under the compose directory is either in VENDOR_MOUNTS, or is
#      the compose file itself, or is the postgres build context (a `build:`, not
#      a mount — see below).
#
#      `.env.example` is excluded too, and for a different reason: it is
#      documentation the stack reads for defaults, not a file a container mounts,
#      and its own coverage is asserted by the `.env.example` check above.
compose_dir = os.path.join(root, "templates/compose")
skip_unreferenced = {"docker-compose.yml", ".env.example"}
unreferenced = []
for dirpath, _dirnames, filenames in os.walk(compose_dir):
    for fname in filenames:
        full = os.path.join(dirpath, fname)
        rel = os.path.relpath(full, compose_dir)
        top = rel.split(os.sep)[0]
        if fname in skip_unreferenced or top in ("postgres",):
            continue
        if not any(src == rel or src.split("/")[0] == top for src in VENDOR_MOUNTS):
            unreferenced.append(rel)
if unreferenced:
    problems.append(
        "nothing mounts: "
        + ", ".join(sorted(unreferenced))
        + ". Every file under templates/compose/ is fetched by every adopting "
        "service and must be mounted by something; a file nothing mounts is a "
        "config nobody can read, and a store that 'is configured' on disk"
    )

# 1b. AND NO HOST PATH IN THIS FILE IS BARE-RELATIVE, WHICHEVER SERVICE IT
#     BELONGS TO.
#
#     The loop above is a HAND-WRITTEN LIST, and that is the whole reason the
#     defect below survived it: the postgres service's two paths were never
#     vendor configs, so they were never in the list, and a check over a list
#     only ever says something about the list. Measured, on this tree, before
#     the fix: `docker-compose.yml:173` (`build.context: ./postgres`) and
#     `:249` (`- ./postgres/initdb:/docker-entrypoint-initdb.d:ro`) were the
#     only two bare paths in the file, and the only two that were wrong.
#
#     What they cost, measured on identity rather than reasoned about: `bin/dev`
#     runs compose with `--project-directory .`, the SERVICE root, and Docker
#     Compose resolves a relative bind source and build context against the
#     PROJECT DIRECTORY, not against the directory holding the compose file. So
#     both resolved to `<service>/postgres/...`, which does not exist, and
#     Docker's answer to a missing bind source is to CREATE IT AS A DIRECTORY.
#     `/docker-entrypoint-initdb.d` was then empty inside a HEALTHY container:
#     `10-cluster.sh` never ran, no service got a role, no service got a
#     database, no `REVOKE CONNECT` was ever applied - and `docker compose up
#     --wait` exited 0 and reported the cluster healthy. A green stack proving
#     nothing is the exact failure this repository is built to refuse, so the
#     rule below is derived from the FILE rather than from a list of what
#     somebody remembered to list: adding an eighth service cannot escape it.
for n, ln in enumerate(compose.splitlines(), 1):
    stripped = ln.strip()
    if stripped.startswith("#"):
        continue
    # short-syntax volume:  - <source>:<destination>[:ro]
    host = None
    if stripped.startswith("- "):
        parts = stripped[2:].split(":")
        # A windows-style drive letter or a bare name is not a relative path.
        if len(parts) >= 2 and parts[0] not in ("", "/"):
            host = parts[0]
    elif stripped.startswith("context:"):
        host = stripped.split(":", 1)[1].strip()
    elif stripped.startswith("source:"):
        host = stripped.split(":", 1)[1].strip()
    if host and (host.startswith("./") or host.startswith("../")):
        problems.append(
            f"docker-compose.yml:{n} uses the bare relative path {host!r}. That is "
            f"resolved against the compose PROJECT directory, which `bin/dev` sets to "
            f"the service root - where this file's siblings do not live. Use "
            f"${{KIT_COMPOSE_DIR:-.}}/{host.lstrip('./')}. If this is the build "
            f"context or the initdb mount, getting it wrong is not a visible error: "
            f"Docker creates the missing directory, `/docker-entrypoint-initdb.d` "
            f"comes up EMPTY, no role or database is provisioned, no REVOKE is "
            f"applied, and the cluster still reports healthy."
        )

# 2. `bin/dev` sets it, to the FETCHED compose directory and not the kit root.
#    The kit root resolves every mount to `<kit>/grafana/provisioning`, which does
#    not exist - the same failure, one directory up.
if "KIT_COMPOSE_DIR=" not in dev:
    problems.append(
        "bin/dev never sets KIT_COMPOSE_DIR, so every vendor config mount falls "
        "back to `.` and resolves against the service root"
    )
else:
    exports = re.findall(
        r"(?:export\s+)?KIT_COMPOSE_DIR=(?:\"([^\"]*)\"|'([^']*)'|([^\s#]*))", dev
    )
    values = [next(g for g in m if g) for m in exports if any(m)]
    if not values:
        problems.append("bin/dev mentions KIT_COMPOSE_DIR but never assigns it")
    else:
        bad = [v for v in values if "templates/compose" not in v]
        if bad:
            problems.append(
                f"bin/dev assigns KIT_COMPOSE_DIR={bad[0]!r}, which is not the "
                f"tree's templates/compose directory. Naming it after the thing it "
                f"points at rather than after the repository it came from is what "
                f"keeps the hand-copied case and the fetched case the same path with "
                f"a different prefix, rather than two different shapes."
            )

# 3. The two files must agree on the DEFAULT too. `.` in the compose file means
#    "the directory holding this file", which is right for a hand-copied stack and
#    is the value `bin/dev` overrides. If the default were ever changed to the kit
#    root, the hand-copied case would silently break instead of the fetched one.
if "${KIT_COMPOSE_DIR:-.}" not in compose:
    problems.append(
        "docker-compose.yml no longer documents the `.` default for "
        "KIT_COMPOSE_DIR, so the hand-copied stack has no path left to fall back to"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/compose/ + bin/dev  (every vendor config mounts from the fetched tree)' \
    stack_mount_check

  # -------------------------------------------------------------------------
  # THE PIN IS `kit.ref`, AND THREE FILES AGREE ON THAT SPELLING.
  #
  # `bin/dev` reads the pin, `tests/fleet_check.py` audits it, and
  # `templates/compose/.env.example` documents where it is NOT. Three files, one
  # fact, and the failure mode if they disagree is invisible: the fleet gate
  # reports "kit.ref: ABSENT" on a repository whose `bin/dev` reads `.env`, and
  # reads it as a broken repository rather than as two kit files that stopped
  # agreeing — which is what it is, and which only kit can fix.
  #
  # This is the same SHAPE as the `callable path` check further down, and it is
  # here for the same reason: a documented string that stops being true while
  # every behavioural check stays green. `tests/fetch_test.sh` proves `bin/dev`
  # honours the pin; this proves `bin/dev` and the gate are talking about the same
  # one, which no execution of either can show.
  pin_contract_check() {
    "$PY" - "$ROOT" <<'PY'
import re
import sys

root = sys.argv[1]
dev = open(f"{root}/templates/bin/dev.sh", encoding="utf-8").read()
fleet = open(f"{root}/tests/fleet_check.py", encoding="utf-8").read()
example = open(f"{root}/templates/compose/.env.example", encoding="utf-8").read()

problems = []

# 1. `bin/dev` must actually read a file for the pin, and it must be named the
#    same way `fleet_check.py` names it.
assigned = re.search(r'^REF_FILE="([^"]+)"', dev, re.M)
if not assigned:
    problems.append(
        "bin/dev has no REF_FILE assignment, so there is no committed pin file and "
        "the gate's 'kit.ref: ABSENT' finding would be about a file bin/dev never "
        "reads"
    )
else:
    ref_file = assigned.group(1)
    if "kit.ref" not in fleet:
        problems.append(
            f"bin/dev reads the pin from {ref_file!r} and fleet_check.py does not "
            f"mention it, so the fleet gate audits a file nothing reads"
        )
    if ref_file not in dev:
        problems.append(f"REF_FILE is {ref_file!r} but bin/dev never opens it")

# 2. `.env.example` must NOT carry the pin. This is the assertion with teeth: the
#    file becomes `.env`, `.env` is git-ignored, and a pin there exists on one
#    machine and on no CI runner. Shipping a `KIT_STACK_REF=` line in the template
#    is how that state gets reintroduced - and it would look like the pin is
#    configured, which is worse than its absence.
for line in example.splitlines():
    m = re.match(r"^([A-Z_][A-Z0-9_]*)=", line)
    if m and m.group(1) == "KIT_STACK_REF":
        problems.append(
            ".env.example sets KIT_STACK_REF. `.env` is git-ignored, so a pin there "
            "exists on one machine and on no CI runner; the pin is `kit.ref`, "
            "committed. Remove the line."
        )
        break

# 3. `.env.example` must still TELL a developer where the pin lives. Removing the
#    line without documenting the alternative leaves the ref undiscoverable, and
#    the first `bin/dev` on a fresh clone fails with a message about a file
#    nothing mentions.
if "kit.ref" not in example:
    problems.append(
        ".env.example never mentions kit.ref, so a developer whose `.env` has no "
        "pin is never told which committed file is supposed to hold one"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/bin/dev.sh + .env.example  (the pin is kit.ref, and the gate reads the same file)' \
    pin_contract_check
  # ------------------------------------------------------------------ core
  # The fan-out standard: vendir templates, the shared Renovate policy, and the
  # two runnable pieces (the change classifier and the staleness reporter).
  #
  # `core_fanout_check` is a real parser over four file types and its failure
  # modes are specific enough to be worth reading in one place, so it lives in
  # tests/core_fanout_check.py rather than inlined here.
  section 'static: the core fan-out standard'
  core_fanout_check() {
    "$PY" "$ROOT/tests/core_fanout_check.py" "$ROOT"
  }
  check 'core/vendir/ + core/renovate/  (structurally what Renovate and vendir need)' \
    core_fanout_check

  # ------------------------------------------------------------------ fleet
  # NO ADOPTER CARRIES A WORKAROUND FOR A FIXED CORE DEFECT.
  #
  # `core` shipped two checker defects that forced repositories which adopted
  # `gate.yml` into local workarounds: D12 (`RUN_KEY` could not see a one-line
  # `run:`, fixed in 63fd319) and D13 (proofs matched against bytes carrying
  # ANSI colour, fixed in c63af27). Both are fixed. A workaround for a fixed
  # defect is not neutral — it is a second, local, unpolicied copy of a
  # decision that now lives in core, and it is the kind that rots. So a rule
  # about it belongs here, in the thing that distributes the gate format, rather
  # than in a report nobody re-reads.
  #
  # THE FLEET ROOT IS FOUND, NOT ASSUMED, and its absence is a reported SKIP
  # rather than a pass — the same treatment the core-allowlist check above gets,
  # for the same reason. A sweep that could not read a single declaration has
  # not found the fleet.
  #
  # `$ROOT/..` is checked FIRST and it is where this repository's worktrees live
  # during a packet, which is the whole point: the check has to see the state
  # the fleet is in today, not the state on a CI runner that has no siblings.
  # A CI runner legitimately reaches the SKIP, and the summary says so.
  fleet_root() {
    local cand
    # `..` and `../cafaye`, and NOT `../..`. This was `../..` in the first
    # version and it found a fleet: a leftover copy of a cafaye repository in a
    # shared temp directory two levels up, whose branch still carried the D12
    # workaround this check had just retired. The gate went red on a tree with
    # nothing wrong with it, naming a file nobody had touched in weeks.
    #
    # A sweep that reaches further than it owns is worse than no sweep, so the
    # search is exactly the two layouts this repository is actually cloned into:
    # beside its siblings, or inside a directory of them.
    for cand in "$ROOT/.." "$ROOT/../cafaye"; do
      # At least one `gate.yml` under it, or it is not a fleet and pointing at
      # it would report "no adopting repository found" — technically true and
      # completely useless, which is why this tests for the file rather than the
      # directory.
      if [ -n "$(find "$cand" -maxdepth 2 -name gate.yml -not -path '*/.venv/*' 2>/dev/null | head -1)" ]; then
        (cd "$cand" && pwd)
        return 0
      fi
    done
    return 1
  }

  gate_workaround_check() {
    local root
    root="$(fleet_root)" || {
      echo "no fleet root: no directory beside this one holds a gate.yml."
      echo "set KIT_FLEET=<path> to point at one."
      return 1
    }
    KIT_FLEET="$root" "$PY" "$ROOT/tests/gate_declaration_check.py" "$root"
  }
  section 'static: no adopting repository carries a D12/D13 workaround'
  if [ -n "${KIT_FLEET:-}" ]; then
    check 'adopting repositories  (no workaround for a fixed core defect)' \
      "$PY" "$ROOT/tests/gate_declaration_check.py" "$KIT_FLEET"
  elif fleet_root >/dev/null 2>&1; then
    check 'adopting repositories  (no workaround for a fixed core defect)' \
      gate_workaround_check
  else
    report SKIP 'adopting repositories  (no fleet beside this one — set KIT_FLEET)'
  fi

  # ------------------------------------------------- the account-scope contract
  # SIX SERVICES DECLARE THEIR ACCOUNT-SCOPED SURFACE AND NOT ONE OF THEM RUNS
  # THE CHECKER IN ITS OWN GATE. Measured, and the measurement is the whole
  # reason this section exists:
  #
  #   cd /Users/kaka/Code/any/moon/cafaye && grep -rln "account_scope_check" \
  #       --include="*.sh" --include="*.yml" --include="Makefile" --include="*.exs" . \
  #     | grep -v "^./core/harness" | grep -v wt-m39
  #     -> pantry/account_scope.yml
  #        courier/account_scope.yml
  #        gateway/account_scope.yml
  #        core/.github/workflows/ci.yml
  #        core/harness/tests/account_scope_self_test.sh
  #
  # Every hit is either a declaration MENTIONING the tool or `core` running its
  # own self-test over its own fixtures. So the contract is continuous in nobody's
  # build: a service can add a route, widen a declaration, or delete
  # `account_scope.yml` entirely and its own gate stays green. That is D18's
  # shape one level up from where D18 has been looking.
  #
  # `tests/account_scope_fleet_check.py` runs core's checker over every repository
  # `MVP-SCOPE.md` puts in the MVP and compares the answer with what
  # `tests/account_scope_fleet_ratchet.yml` records — in BOTH directions, so a
  # repository that got better and whose row nobody retired is as red as one that
  # got worse.
  #
  # WHY IT REPLACES THE FIVE-FUNCTION ADAPTER CONTRACT rather than extending it:
  # `cross_tenant_harness.sh`'s `adapter_install_probe` / `adapter_language_tool`
  # / `adapter_migrate` / `adapter_prepare` / `adapter_run` are five questions
  # about RUNNING A SERVICE, four of them about a live Postgres. There is no
  # service to run here and nothing to bring up or tear down, so the harness's
  # `up`/`run`/`down` has no meaning over a declaration checker. The discipline
  # that contract carries — a run that could not happen exits non-zero and never
  # reports a pass — is kept, and it is the discipline this section is really
  # about.
  #
  # THE FLEET ROOT IS FOUND, NOT ASSUMED, and its absence is a reported SKIP
  # rather than a pass, for the same reason as the check above and with the same
  # two candidate layouts. A CI runner legitimately reaches the SKIP, which is
  # why the account-scope contract has its OWN job in `.github/workflows/ci.yml`
  # that assembles a fleet and runs this runner for real: wiring a check only
  # into a path that skips on every machine that runs it is the defect this
  # packet is about, done one level down.
  account_scope_fleet_root() {
    local cand
    for cand in "$ROOT/.." "$ROOT/../cafaye"; do
      # A directory holding `core/harness/account_scope_check.py` and one of
      # the in-scope services is a fleet this runner can measure. Testing for
      # the INSTRUMENT rather than for the directory is the same instinct as
      # the `gate.yml` probe above: pointing at something that is not a fleet
      # reports "no repository checked" — technically true and useless.
      if [ -f "$cand/core/harness/account_scope_check.py" ] \
         && [ -n "$(find "$cand" -maxdepth 2 -name account_scope.yml -not -path '*/.venv/*' \
                    2>/dev/null | head -1)" ]; then
        (cd "$cand" && pwd)
        return 0
      fi
    done
    return 1
  }

  account_scope_contract_check() {
    local root
    root="$(account_scope_fleet_root)" || {
      echo "no fleet root: no directory beside this one holds core's account-scope checker"
      echo "and a service's account_scope.yml. set KIT_FLEET=<path> to point at one."
      return "$SKIP_EXIT"
    }
    "$PY" "$ROOT/tests/account_scope_fleet_check.py" --repos-dir "$root"
  }
  section 'static: the account-scope contract, across every in-scope repository'
  if [ -n "${KIT_FLEET:-}" ]; then
    check 'in-scope repositories  (every one declares its account-scoped surface)' \
      "$PY" "$ROOT/tests/account_scope_fleet_check.py" --repos-dir "$KIT_FLEET"
  elif account_scope_fleet_root >/dev/null 2>&1; then
    check 'in-scope repositories  (every one declares its account-scoped surface)' \
      account_scope_contract_check
  else
    report SKIP 'in-scope repositories  (no fleet beside this one — set KIT_FLEET)'
  fi

  # THE GATE-DID-NOT-RUN-THE-PROOF GUARD, and it is a separate check on purpose.
  #
  # The check above SKIPs on every machine that has no fleet beside it, which on
  # this repository's own CI is all of them — and a check whose only proof is a
  # SKIP is the failure `DEBT.md` records by name. So the wiring is asserted
  # separately, and it runs everywhere including CI: deleting the `check` above,
  # renaming the program, or deleting either half of the RECORD turns this red
  # rather than leaving the gate quieter.
  #
  # The assertion is on the INVOCATION, not on the file existing, for the reason
  # AGENTS.md states about `lint-args`: a comment that names a check, or a file
  # that is present and never run, both read exactly like a check that is run.
  # `strip_shell_comments` is not applied here on purpose — the needle is a
  # command line, and a comment quoting the whole command would satisfy a check
  # that a deletion had just emptied. So the needle is the ARGUMENT that makes
  # it a run rather than a mention: `--repos-dir`.
  account_scope_wiring_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import sys

root = sys.argv[1]
problems = []

gate = os.path.join(root, "tests", "validate.sh")
with open(gate, encoding="utf-8") as handle:
    body = handle.read()

# The invocation, and the argument that makes it an invocation. A `grep` for the
# program's name alone is satisfied by the comments around it, which is the trap
# this whole check exists in.
if "tests/account_scope_fleet_check.py" not in body:
    problems.append(
        "tests/validate.sh never names tests/account_scope_fleet_check.py, so nothing "
        "in this repository's own gate runs the account-scope contract"
    )
if "--repos-dir" not in body:
    problems.append(
        "tests/validate.sh does not pass --repos-dir to the account-scope runner, so the "
        "mention above it may be a comment rather than a run"
    )

# And the record, which is what makes a red comparable to yesterday's red. A
# runner with no record tolerates nothing, which is a defensible state for its
# first commit and a broken gate for every one after it.
for relative, why in (
    ("tests/account_scope_fleet_ratchet.yml",
     "the recorded state of the fleet's account-scope contract"),
    ("tests/account_scope_fleet_scope.yml",
     "the vendored in-scope table a machine with no scope decision beside it runs on"),
):
    path = os.path.join(root, relative)
    if not os.path.isfile(path):
        problems.append(f"{relative} is missing: it is {why}")

if problems:
    sys.exit("; ".join(problems))
print("the account-scope runner is invoked by this gate with --repos-dir, and both "
      "halves of its record are on disk")
PY
  }
  check 'account-scope wiring  (the gate runs the runner, and the runner has a record)' \
    account_scope_wiring_check

  # Dogfood lint/yamllint.yml on every YAML in the tree, not just the two
  # compose templates. kit ships the config and a repo that copies it lints its
  # own CI against it on day one, so a YAML that breaks the config is a YAML
  # that greets the first adopting repo with a failure nobody authored.
  #
  # This also subsumes kit-03's own walk of `templates/compose`, which existed
  # because the provisioning tree is three directories deep and a glob of
  # `templates/compose/*` reaches none of it. `yamls_of_the_tree` below finds
  # those files for the same reason and covers the rest of the repo too, so the
  # narrower walk is gone rather than kept alongside: two loops over the same
  # files report every problem twice and disagree about which is authoritative.
  #
  # Required, not optional: it is in tests/requirements.txt and the bootstrap
  # above has already installed it, so a machine that reaches this line has
  # yamllint. A SKIP here would hide a broken config behind a missing tool on
  # exactly the machine that has not run the gate before.
  #
  # The check that used to skip when it was absent is now a FAIL, and says so —
  # the absence is a defect in the environment, not a neutral fact, and it is
  # the difference between "this YAML is bad" and "I did not look".
  section 'static: every YAML in the tree is yamllint clean'
  if [ -z "${KIT_YAMLLINT:-}" ]; then
    if ! kit_bootstrap_console_script yamllint yamllint "$ROOT"; then
      exit 1
    fi
    YAMLLINT="$CONSOLE"
  else
    YAMLLINT="$KIT_YAMLLINT"
  fi
  if [ ! -x "$YAMLLINT" ]; then
    report FAIL "yamllint (KIT_YAMLLINT=$YAMLLINT is not executable)"
  else
    # Lint the tree, not a hand-kept list. `git ls-files` rather than `find` so
    # the gate lints exactly what a caller clones, and so a .venv full of
    # somebody else's YAML never enters the report. Falls back to `find` in a
    # throwaway copy from self_test, which is not a git repository.
    #
    # `while read` rather than `mapfile` into an array: mapfile is a bash 4
    # builtin and kit's gate is also run by whatever `bash` a slim container
    # ships. A loop over a pipeline needs no array, and no `set -u`-safe empty
    # expansion.
    yamls_of_the_tree() {
      if [ -d "$ROOT/.git" ] || [ -f "$ROOT/.git" ]; then
        git -C "$ROOT" ls-files '*.yml' '*.yaml' 2>/dev/null
      else
        (cd "$ROOT" && find . -name .venv -prune -o -type f \( -name '*.yml' -o -name '*.yaml' \) -print |
          sed 's|^\./||' | sort)
      fi
    }
    par_begin
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      [ -f "$ROOT/$rel" ] || continue
      # `check_par`: 23 independent single-file spawns, 2.5s measured, and the
      # same bounded-and-ordered guarantee as the shellcheck loop above.
      check_par "$rel  (yamllint -c lint/yamllint.yml)" \
        "$YAMLLINT" -c "$ROOT/lint/yamllint.yml" "$ROOT/$rel"
    done < <(yamls_of_the_tree)
    par_flush

    # The glob above only reaches `*.yml` and `*.yaml`, and kit now ships YAML
    # under other names: the vendir templates are `vendir.yml.<service>` so that
    # a repository that copies one to `vendir.yml` gets a file Renovate's
    # `managerFilePatterns` can find, while kit's own tree is never itself a
    # vendir target.
    #
    # A file a service copies that breaks kit's own lint config greets its first
    # CI run with a failure nobody authored, which is the `rack_middleware.rb.snippet`
    # defect in AGENTS.md arriving in a different costume. So they are linted
    # here by name, and the name list is explicit: a glob over
    # `core/vendir/vendir.yml.*` would also catch a backup file.
    for rel in core/vendir/vendir.yml.template core/vendir/vendir.yml.muse \
               core/vendir/vendir.yml.pantry core/vendir/vendir.yml.caf; do
      [ -f "$ROOT/$rel" ] || continue
      check "$rel  (yamllint -c lint/yamllint.yml, under a non-.yml name)" \
        "$YAMLLINT" -c "$ROOT/lint/yamllint.yml" "$ROOT/$rel"
    done
  fi

  # The CI workflow gains a job; assert the job exists, is opt-in, and that the
  # default call still runs exactly the six original jobs. A kit change that
  # breaks every consumer's CI is a kit change that does not ship.
  #
  # The secrets and zizmor jobs are asserted separately, below, because they are
  # the two jobs whose absence is silent in a way `option has no job` does not
  # make silent: a repo without a secrets job has no secret scanning, and every
  # other check in this file is still green.
  ci_check() {
    "$PY" - "$ROOT" "$CONFIG_ONLY" "$WORKFLOW" <<'PY'
import re
import sys

import yaml

config_only = sys.argv[2]
with open(sys.argv[3], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)

problems = []

# `on:` is read by PyYAML 1.1 as the boolean True.
triggers = doc.get("on") or doc.get(True) or {}
call = (triggers.get("workflow_call") or {}).get("inputs") or {}

telemetry = call.get("telemetry")
if not isinstance(telemetry, dict):
    problems.append("no `telemetry` workflow_call input")
else:
    default = str(telemetry.get("default", ""))
    if default not in ("false", "False"):
        problems.append(f"telemetry input defaults to {default!r}; it must default to 'false'")
    if str(telemetry.get("type")) != "string":
        problems.append("telemetry input must be type: string (booleans coerce badly)")

jobs = doc.get("jobs") or {}

# One entry per language kit ships a Dockerfile, a bin/prime and a mise pin for.
# The list lives here and nowhere else, so "add a language" is one line that
# fails immediately until the other three artifacts exist — rather than a
# language with a CI job and no primer.
languages = ["go", "ruby", "elixir", "python", "node", "bun", "rust"]

for lang in languages:
    job = jobs.get(lang)
    if not isinstance(job, dict):
        problems.append(f"job {lang} disappeared")
        continue
    cond = job.get("if")
    if cond is None or f"inputs.language == '{lang}'" not in cond:
        problems.append(f"job {lang} is no longer gated on its language input")

# A caller can pass anything, so the job that REJECTS an unknown value is what
# makes "an option with no job" impossible. `workflow_call` has no `options:`
# key -- that is a `workflow_dispatch` feature, and GitHub refuses the whole
# file if you write it here -- so the enumeration kit used to declare and then
# enforce has to be enforced by a job that runs instead.
#
# So the `language` job is the list now, and this is the check that it still
# names every language the file has a job for. A language added to `languages`
# above without a case arm there is a language a caller can ask for that runs
# nothing.
gate = jobs.get("language")
if not isinstance(gate, dict):
    problems.append(
        "no `language` job: without it an unrecognised value skips every "
        "language job's `if:` and leaves a green run that tested nothing"
    )
else:
    script = "\n".join(
        str(s.get("run") or "") for s in (gate.get("steps") or []) if isinstance(s, dict)
    )
    # Every language, plus `none`, must appear in the gate's case statement.
    for name in languages + [config_only]:
        if not re.search(rf"(^|[\s|(]){re.escape(name)}(\)|[\s|])", script, re.M):
            problems.append(
                f"the `language` job does not accept `{name}`: it is not one of "
                f"the values its case statement handles"
            )

# `none` is what lets a repository with no service manifest adopt this
# workflow at all, and kit is such a repository. It gets the same treatment as
# every other option: a job, and a guard on the input. An option whose job has
# no `if` would run in all thirteen consumer repos on day one.
cjob = jobs.get(config_only)
if not isinstance(cjob, dict):
    problems.append(
        f"job {config_only} disappeared: without it a repository with no service "
        f"manifest cannot call this workflow, which is why kit never called its own"
    )
else:
    cond = cjob.get("if")
    if cond is None or f"inputs.language == '{config_only}'" not in cond:
        problems.append(f"job {config_only} is not gated on its language input")

tjob = jobs.get("telemetry")
if not isinstance(tjob, dict):
    problems.append("no `telemetry` job")
else:
    cond = tjob.get("if") or ""
    if "inputs.telemetry" not in cond:
        problems.append("telemetry job is not gated on the telemetry input: it would run by default")
    matrix = ((tjob.get("strategy") or {}).get("matrix") or {}).get("language")
    if not matrix:
        problems.append("telemetry job has no language matrix: it must execute every language")
    elif sorted(matrix) != sorted(["go", "ruby", "elixir", "python", "node", "rust"]):
        problems.append(f"telemetry matrix does not cover the six languages: {matrix}")

# A workflow that parses is not a workflow that runs. `if:` conditions and
# `${{ }}` are opaque to yaml.safe_load, so the two ways this file has actually
# broken in review — an expression that never resolves, and a `${{` that opens a
# block it never closes — are caught by reading the source as text. A file
# needing this check is a file that needed it.
source = open(sys.argv[3], encoding="utf-8").read()
for match in re.finditer(r"\$\{\{", source):
    lineno = source[: match.start()].count("\n") + 1
    tail = source[match.start() :]
    line_end = tail.find("\n")
    line = tail if line_end == -1 else tail[:line_end]
    if "}}" not in line:
        problems.append(f"line {lineno}: unclosed ${{{{ in an expression")
        break

# Every `uses:` is owner/repo[/path]@ref. A step with no ref resolves to
# whatever that action's default branch says today, which is not a pin.
for lineno, line in enumerate(source.splitlines(), 1):
    stripped = line.strip()
    if not stripped.startswith("uses:"):
        continue
    ref = stripped.split("uses:", 1)[1].strip().strip("'\"")
    if ref.startswith("./") or ref.startswith("docker://"):
        continue
    if "@" not in ref:
        problems.append(f"line {lineno}: `uses: {ref}` has no ref")
    elif ref.endswith(("@master", "@main")):
        problems.append(f"line {lineno}: `uses: {ref}` points at a branch, not a release")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check "$WORKFLOW  (opt-in telemetry job, defaults intact)" ci_check

  # -------------------------------------------------------------------------
  # The tier convention. Three claims, three checks, split because they decay
  # separately: the templates drift, the wiring drifts, the allowlist rots. One
  # check covering all three would keep passing while two of them rotted.
  # -------------------------------------------------------------------------
  section 'static: every language declares a tier, and says how it is collected'

  # (1) The declaration, per language, in the templates.
  #
  # Read out of the workflow's `language` options, so there is still exactly one
  # place to add a language — the same rule as the four-artifacts check above.
  # For each: a `templates/tier/<lang>/` directory, the declared form inside it,
  # and a row in the tier README naming the collector that reads it.
  #
  # The README row is required rather than nice-to-have, because a tier nobody
  # can collect is a comment — and a comment is what this whole packet exists to
  # stop being. A language with a declaration and no named collector is a
  # language whose tier can never be required of anything.
  tier_declaration_check() {
    "$PY" - "$ROOT" "$CONFIG_ONLY" "$WORKFLOW" <<'PY'
import os
import re
import sys

import yaml

root, config_only, workflow = sys.argv[1], sys.argv[2], sys.argv[3]
with open(workflow, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
# Read the language gate job's case statement, not an `options:` list: `options`
# is a `workflow_dispatch` key, GitHub rejects the whole workflow file if it
# appears under `workflow_call`, and the enumeration it used to hold now lives
# in the job that rejects an unrecognised value.
jobs = doc.get("jobs") or {}
gate = "\n".join(
    str(st.get("run") or "")
    for st in ((jobs.get("language") or {}).get("steps") or [])
    if isinstance(st, dict)
)
langs = [
    name
    for arm in re.findall(r"^\s*([a-z|]+)\)\s*$", gate, re.M)
    for name in arm.split("|")
    if name and name != config_only
]
if not langs:
    problems.append(
        "the reusable workflow's `language` gate job names no language, so this "
        "check could not ask its question. Reading zero languages is not the "
        "same as there being none"
    )

tier_readme = os.path.join(root, "templates", "tier", "README.md")
if not os.path.isfile(tier_readme):
    sys.exit("templates/tier/README.md is missing: a convention with no document is a rumour")
readme = open(tier_readme, encoding="utf-8").read()

# The first column of every markdown table row in that file, backticks stripped.
# Restored to a set and compared by membership, so a row is found wherever it
# sits in the document rather than at a guessed line.
declared_rows = {
    cell.strip().strip("`")
    for line in readme.splitlines()
    if line.strip().startswith("|")
    for cell in [line.strip().strip("|").split("|")[0]]
}

# The declaration itself, per language: the token a service author actually
# writes, and in every case a no-op at runtime — a build tag, an attribute
# libtest already prints, a marker, a const, a macro. Asserting the token is
# PRESENT in the shipped template is what stops a declaration being described in
# a README and absent from the file a service copies. Prose is not a
# declaration; only the template is.
DECLARED = {
    "go": r"^//go:build tier_db$",
    "rust": r'#\[ignore = "cafaye:tier=',
    "python": r"^@pytest\.mark\.tier_db$",
    "bun": r'^export const TIER = "db" as const;$',
    "node": r'^export const TIER = "db" as const;$',
    "ruby": r"^\s*tier :db$",
    "elixir": r"^  @tier :db$",
}

problems = []
for lang in langs:
    d = os.path.join(root, "templates", "tier", lang)
    if not os.path.isdir(d):
        problems.append(
            f"{lang}: no templates/tier/{lang}/ — a language with a CI job and no tier "
            f"declaration is a language whose tier can never be required"
        )
        continue

    files = [
        f
        for f in sorted(os.listdir(d))
        # isfile, because a directory in a template tree is a problem to
        # REPORT, not a crash. Reading it raised IsADirectoryError and took two
        # checks down with a traceback, which is the least useful way a gate
        # can fail. `__pycache__` got in here for real.
        if not f.startswith(".") and os.path.isfile(os.path.join(d, f))
    ]
    if not files:
        problems.append(f"templates/tier/{lang}/ holds no files")
        continue
    strays = [
        f
        for f in sorted(os.listdir(d))
        if not f.startswith(".") and not os.path.isfile(os.path.join(d, f))
    ]
    if strays:
        problems.append(
            f"templates/tier/{lang}/ holds {strays}, which is not a file a service "
            f"can copy. kit hands out files; a build artefact in this tree is "
            f"something a previous run left behind"
        )

    bodies = [open(os.path.join(d, f), encoding="utf-8").read() for f in files]
    token = DECLARED.get(lang)
    if token is None:
        problems.append(
            f"{lang}: this check knows no declared form for it. Add one — a language "
            f"whose declaration nothing can assert is a check that cannot fail"
        )
    elif not any(re.search(token, b, re.M) for b in bodies):
        problems.append(
            f"templates/tier/{lang}/: none of {files} carries the declared form. The "
            f"README describes a declaration the template does not have"
        )

    # The collector, named in the README's per-language table.
    #
    # The table is PARSED rather than substring-searched, because the rows are
    # written as `| `go` |` — the option value in backticks, since it is the
    # literal a caller types into `language:`. A `f"| {lang} |" in readme` test
    # does not match a backticked cell, and the first version of this check
    # failed on a table that was correct in every way a reader could check. A
    # check that is right about the rule and wrong about the syntax is still
    # wrong, and the fix belongs in the check.
    if lang not in declared_rows:
        problems.append(
            f"templates/tier/README.md has no table row for {lang}: a service author "
            f"cannot learn how their language's tier is collected"
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/tier/<lang>/  (a declared tier, and a README row naming the collector)' \
    tier_declaration_check

  # (2) The demand, wired. `REQUIRED_<TIER>=1` must be exported by every language
  #     job and checked by every language job, or naming a variable in a caller
  #     is a promise no job keeps.
  #
  #     The demand steps are byte-identical on purpose — GitHub reusable
  #     workflows cannot share a step — so this asserts they STAY identical. Six
  #     hand-maintained copies of a policy block is the drift kit exists to
  #     prevent, and the only defence against hand-maintained copies is a check
  #     that reads them.
  #
  #     `-count=1` is asserted on the Go job alone: no other language kit ships
  #     has a test cache keyed on the environment, and mandating a flag that does
  #     not exist is a check nobody could satisfy honestly.
  tier_demand_check() {
    "$PY" - "$ROOT" "$CONFIG_ONLY" "$WORKFLOW" <<'PY'
import re
import sys

import yaml

root, config_only, workflow = sys.argv[1], sys.argv[2], sys.argv[3]
with open(workflow, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
triggers = doc.get("on") or doc.get(True) or {}
call = (triggers.get("workflow_call") or {}).get("inputs") or {}
jobs = doc.get("jobs") or {}
gate = "\n".join(
    str(st.get("run") or "")
    for st in ((jobs.get("language") or {}).get("steps") or [])
    if isinstance(st, dict)
)
langs = [
    name
    for arm in re.findall(r"^\s*([a-z|]+)\)\s*$", gate, re.M)
    for name in arm.split("|")
    if name and name != config_only
]

if not langs:
    sys.exit(
        "the reusable workflow's `language` gate job names no language, so this "
        "check could not ask its question. Reading zero languages is not the "
        "same as there being none"
    )


def strip_shell_comments(src):
    """Remove shell comments from a `run:` body, keeping quoted `#` intact.

    AGENTS.md: "a check that can be satisfied by a comment is not a check."
    That is not a hypothetical here — this function exists because the
    `-count=1` assertion was written as a substring test, the go step's own
    comment block explains WHY the flag is mandated and names the flag twice,
    and deleting the flag from the command left the check green. It was
    satisfied by the sentence explaining that removing it would be a mistake.

    Only a `#` at the start of a word begins a comment, and a `#` inside
    single or double quotes is content. So `grep -qE '^ran[[:space:]]'` and
    `echo "::error::#1"` both survive intact, and `# -count=1 is mandated`
    does not.
    """
    out = []
    for line in src.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        # Walk the line tracking quote state, and cut at the first `#` that
        # follows a space outside quotes — the shell's own rule, near enough.
        quote = None
        cut = None
        for i, ch in enumerate(line):
            if quote:
                if ch == quote:
                    quote = None
                continue
            if ch in ("'", '"'):
                quote = ch
            elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
                cut = i
                break
        out.append(line if cut is None else line[:cut])
    return "\n".join(out)


problems = []

# Opt-in by an EMPTY default, not by "0". "0" would be a tier named 0 demanded
# at a value that is neither true nor false, and every caller would have to know
# that. Same reasoning as the `telemetry` input, and the same string type.
demand = call.get("required-tier")
if not isinstance(demand, dict):
    problems.append("no `required-tier` workflow_call input")
elif str(demand.get("default", "x")) != "":
    problems.append(
        f"`required-tier` defaults to {demand.get('default')!r}; it must default to the "
        f"empty string, or adopting kit turns a green repo red on day one"
    )
elif str(demand.get("type")) != "string":
    problems.append("`required-tier` must be type: string, for the reason telemetry is")

bodies = {}
for lang in langs:
    steps = (jobs.get(lang) or {}).get("steps") or []
    if "tier demand" not in [s.get("name") for s in steps]:
        problems.append(
            f"job {lang} has no `tier demand` step: naming a required-tier in a caller "
            f"would be a promise no step keeps, and a gate variable that is set while "
            f"a tier runs zero tests is a green build that verified nothing"
        )
    for s in steps:
        if s.get("name") == "tier demand":
            # The identity comparison below is on the RAW body: it is the
            # duplication that is being compared, comments included, because two
            # copies of a policy block that differ only in their commentary are
            # two copies a reader has to diff by hand.
            bodies[lang] = s.get("run") or ""
            # The `^ran` assertion is on the body with comments stripped. The
            # step's own comment block says "a `ran` line is the evidence that
            # something executed", so an unstripped substring test is satisfied
            # by the sentence describing the check rather than by the check.
            if "^ran" not in strip_shell_comments(bodies[lang]):
                problems.append(
                    f"job {lang}: its `tier demand` step does not look for a 'ran' "
                    f"line, so it cannot tell a tier that ran from one that did not"
                )

    # Both halves of the test step, because either alone is a dead gate:
    # exporting without capturing cannot be checked, and capturing without
    # exporting checks a variable nothing set.
    test = next((s for s in steps if s.get("name") == "test"), None)
    if not isinstance(test, dict):
        problems.append(f"job {lang} has no `test` step to demand a tier from")
        continue
    body = strip_shell_comments(test.get("run") or "")
    if 'export "$REQUIRED_TIER=1"' not in body:
        problems.append(
            f"job {lang}: its test step does not export the demanded gate variable. "
            f"gateway's GATEWAY_REDIS_REQUIRED fails at tier-INVOCATION time, before a "
            f"report exists; a variable applied after the run cannot do that"
        )
    if "kit-tier.log" not in body:
        problems.append(
            f"job {lang}: its test step does not tee to kit-tier.log, so `tier demand` "
            f"has nothing to read and exits green on an empty log"
        )

if len(set(bodies.values())) > 1:
    problems.append(
        "the `tier demand` steps are not identical across language jobs. They are "
        "duplicated because GitHub reusable workflows cannot share a step, and the "
        "duplication is only safe while a check reads them: change all of them or none"
    )

# `-count=1` on the gated tier, for the one language with an env-keyed cache.
go_body = ""
for s in ((jobs.get("go") or {}).get("steps") or []):
    if s.get("name") == "test":
        go_body = strip_shell_comments(s.get("run") or "")
if go_body and "-count=1" not in go_body:
    problems.append(
        "the go test step does not pass -count=1. Go keys its test cache on the "
        "environment a test reads, so a gated and an ungated run already differ — but "
        "mandating the flag removes the question instead of reasoning about it"
    )

if problems:
    sys.exit("; ".join(problems))
print(
    f"required-tier is opt-in (default ''), exported by all {len(langs)} language jobs, "
    f"and checked by {len(bodies)} identical demand steps"
)
PY
  }
  check "$WORKFLOW  (required-tier is declared, demanded by every language job, and identical)" \
    tier_demand_check

  # -------------------------------------------------------------------------
  # LINT RUNS FROM KIT, NOT FROM A COPY. Three claims, and they decay separately.
  # -------------------------------------------------------------------------
  #
  # `lint/` shipped 249 lines of golangci/rubocop/eslint/yamllint/hadolint
  # configuration and NOT ONE service in the fleet had ever copied it. Adoption
  # correlated inversely with how much a file did: the small self-contained
  # artifacts are universal, the large behavioural ones are at zero.
  #
  # The reason is structural, and it is worth stating because it is what this
  # check defends. `uses: cafaye/kit/...@master` is LIVE — change kit and every
  # service gets it with no action. A copied config has NO propagation at all:
  # it rots silently, and the file nobody chose still runs while the file nobody
  # copies just decays. The measured numbers are in README.md; the mechanism
  # that ends the rot is putting the config where the step already is.
  #
  # This check reads the reusable workflow and asserts the three things that
  # make the lint step a GATE rather than a report. Each has a self_test
  # breakage, because a check with no counterexample is a claim in a comment.
  lint_wiring_check() {
    "$PY" - "$ROOT" "$WORKFLOW" <<'PY'
import os
import re
import sys

import yaml

root, workflow_path = sys.argv[1], sys.argv[2]
with open(workflow_path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
jobs = doc.get("jobs") or {}
source = open(workflow_path, encoding="utf-8").read()

problems = []


def strip_shell_comments(src):
    """`run:` bodies, with shell comments removed. See the identical helper in
    the tier_demand check, and the reason it exists there: a check satisfied by
    the sentence explaining a flag is not a check.

    YAML comments are a second, separate problem here, and they are removed
    FIRST: this file's own prose names every one of these flags while explaining
    why each is load-bearing, so a naive substring test over the raw source is
    satisfied by the documentation of the very step it is meant to police.
    """
    without_yaml = "\n".join(
        ln for ln in src.splitlines() if not ln.lstrip().startswith("#")
    )
    out = []
    for line in without_yaml.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        quote, cut = None, None
        for i, ch in enumerate(line):
            if quote:
                if ch == quote:
                    quote = None
                continue
            if ch in ("'", '"'):
                quote = ch
            elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
                cut = i
                break
        out.append(line if cut is None else line[:cut])
    return "\n".join(out)


def steps_of(lang):
    return (jobs.get(lang) or {}).get("steps") or []


def lint_step(lang):
    """The step that runs the language's linter, or None.

    Matched by NAME, not by scanning the job for a linter-shaped command: the
    name is what a reviewer renames, and a check keyed on the thing being
    checked cannot notice when the thing it names is gone.
    """
    for step in steps_of(lang):
        if step.get("name") == "lint":
            return step
    return None


# ---------------------------------------------------------------------------
# 1. EVERY LANGUAGE JOB THAT LINTS, LINTS WITH KIT'S CONFIG.
# ---------------------------------------------------------------------------
#
# The three languages, and the flag each one needs, are all different. That is
# not a preference — each was measured on a fixture containing a violation only
# that linter would catch, and the results are in tests/lint_test.sh. The
# invariant is the SHAPE, and the shape is the thing that decays:
#
#     golangci-lint  `--config=<path>`   GOLANGCI_LINT_CONFIG is NOT read by
#                                        v2 (measured: silently ignored, the
#                                        run proceeds on the 5-linter default
#                                        set, exit 0 on a file kit rejects).
#     rubocop        `--config=<path>`   measured: a 13-line method is green
#                                        under kit (Max 15) and red on RuboCop's
#                                        default (Max 10).
#     eslint         `--config=<path>`   and the path must be INSIDE the repo,
#                                        because node resolves the config's own
#                                        imports upward from the config file.
#
# `--config` is the only spelling all three accept, so it is what is asserted.
# A per-language exception would be a second thing to keep in step, and the
# measurement says there is nothing to gain by it.
NEEDS_KIT_CONFIG = {
    "go": ("golangci", "golangci-lint"),
    "ruby": ("rubocop",),
    "node": ("eslint",),
}

for lang, linters in NEEDS_KIT_CONFIG.items():
    step = lint_step(lang)
    if step is None:
        problems.append(
            f"job {lang} has no step named `lint`, so nothing checks that it "
            f"still lints with kit's config. A renamed step is a lint step that "
            f"stopped being policed, and this check is the only thing that would "
            f"notice"
        )
        continue

    # The run body, for `run:` steps, and the `with:` block, for action steps.
    # Both are read, because the two mechanisms are different: the go job uses
    # the golangci-lint ACTION (so the flag lives in `with:`) while ruby and
    # node use `run:`. A check that only read `run:` would pass on a go job
    # whose action had lost its args, and that job is the one whose default set
    # is a plausible-looking five linters.
    haystack = strip_shell_comments(step.get("run") or "")
    with_block = step.get("with") or {}
    haystack += "\n" + "\n".join(
        f"{k}: {v}" for k, v in (with_block.items() if isinstance(with_block, dict) else [])
    )

    if not any(tool in haystack for tool in linters):
        problems.append(
            f"job {lang}: its `lint` step names none of {linters}, so it is not "
            f"the linter kit configures. Every check in this file can be green "
            f"while the step that was supposed to run the linter runs something "
            f"else"
        )
        continue

    if "--config" not in haystack:
        problems.append(
            f"job {lang}: its `lint` step does not pass `--config`. Measured: "
            f"with no config in the repository, each of these linters falls back "
            f"to its own DEFAULT policy rather than failing — golangci-lint to "
            f"five linters, rubocop to MethodLength 10, eslint to no rules — so "
            f"the step still runs, still passes, and is now on a policy nobody "
            f"chose. This is the exact failure the check exists to end"
        )

    # The config has to be KIT's, and the only way to say that without a second
    # copy of the path to rot is to require the path to go through the
    # environment variable that names the checked-out kit. A path into the
    # service's own tree is a copy, and a copy is the mechanism this packet
    # replaces: it has no propagation, so it rots in silence.
    #
    # The variable is the seam, not a convenience: the three jobs spell the
    # path differently (one interpolates `${{ github.workspace }}` and the env
    # var, two use a shell `$VAR`), and requiring the variable rather than a
    # literal is what lets them differ without the check having to know how.
    if "KIT_LINT_DIR" not in haystack or "/lint/" not in haystack:
        problems.append(
            f"job {lang}: its `lint` step does not read the config out of the "
            f"checked-out kit (`$KIT_LINT_DIR/lint/…`). A path inside the "
            f"service's own tree is a copy, and a copy is the mechanism this "
            f"packet replaces: it has no propagation, so it rots silently"
        )

# ---------------------------------------------------------------------------
# 1b. THE KIT CHECKOUT THAT MAKES `$KIT_LINT_DIR` NAME SOMETHING.
# ---------------------------------------------------------------------------
#
# The claim above is that each lint step reads its config out of a checked-out
# kit. A step that references the variable perfectly well still reads nothing if
# the checkout that fills it was deleted — and that is a one-line deletion in a
# job with eight steps, it leaves the YAML valid, and every other check in this
# file stays green. The lint step would then be a bare `eslint` with no config,
# which is precisely the default-policy failure the check above is about.
#
# Asserted on the PARSED step rather than by grepping, so a `uses:` inside a
# comment (this file has several, explaining exactly this mechanism) cannot
# satisfy it. And `ref` is required to be the INPUT rather than a literal: a
# checkout pinned to `master` in three places is three places to update, and a
# ref that is not the input is a ref that disagrees with the caller's own pin
# without anyone noticing.
for lang in sorted(NEEDS_KIT_CONFIG):
    steps = steps_of(lang)
    kit_steps = [
        s
        for s in steps
        if isinstance(s, dict)
        and str(s.get("uses", "")).startswith("actions/checkout")
        and (s.get("with") or {}).get("repository") == "cafaye/kit"
    ]
    if not kit_steps:
        problems.append(
            f"job {lang}: no step checks out cafaye/kit, so the path its `lint` "
            f"step reads its config from does not exist. The lint step still runs, "
            f"still passes, and is now on the linter's defaults — the exact "
            f"failure this check exists to catch, reached by deleting one step"
        )
        continue
    for step in kit_steps:
        with_block = step.get("with") or {}
        ref = str(with_block.get("ref", ""))
        if "inputs.kit-lint-ref" not in ref:
            problems.append(
                f"job {lang}: its kit checkout pins `ref: {ref or '(none)'}`, not "
                f"`inputs.kit-lint-ref`. A ref hardcoded here is a fourth place a "
                f"pin lives, and it is the one place the caller cannot see"
            )
        # `persist-credentials: false` — the checkout leaves kit's token in a git
        # config inside the tree the service's own later steps run in. Cheap to
        # require and the cost of forgetting it is a credential outliving the
        # step that fetched it.
        if with_block.get("persist-credentials") is not False:
            problems.append(
                f"job {lang}: its kit checkout does not set `persist-credentials: "
                f"false`, so kit's token is left in a git config inside the tree "
                f"the service's later steps run in"
            )

# ---------------------------------------------------------------------------
# 2. THE LINT STEPS ARE GATES, NOT REPORTS.
# ---------------------------------------------------------------------------
#
# `continue-on-error: true` on a lint step is the single most likely way for
# this whole packet to become decoration, and it is invisible: the step runs,
# prints its findings, and the job is green. A linter that only warns is a
# report. So the assertion is on the PARSED step, and it is a separate claim
# from the one above — a step can pass kit's config perfectly and still be
# advisory.
#
# `|| true` and `| head` in a run body are the same defect wearing shell
# clothes, and both are caught by looking at the command rather than the
# setting, because `set -euo pipefail` is already in force and a pipeline's
# status is what decides.
for lang in sorted(NEEDS_KIT_CONFIG):
    step = lint_step(lang)
    if not isinstance(step, dict):
        continue
    if step.get("continue-on-error") is True:
        problems.append(
            f"job {lang}: its `lint` step is `continue-on-error: true`. The step "
            f"still runs and still prints its findings, and the job is green — a "
            f"linter that only warns is a report. This is the breakage that "
            f"matters most, which is why it is asserted on the parsed step rather "
            f"than left to a reviewer"
        )
    body = strip_shell_comments(step.get("run") or "")
    if re.search(r"\|\|\s*true\b", body):
        problems.append(
            f"job {lang}: its `lint` run body swallows the linter's exit status "
            f"with `|| true`, which is continue-on-error in shell and reads as a "
            f"deliberate choice to nobody"
        )

# ---------------------------------------------------------------------------
# 3. KIT'S CONFIGS ARE STILL WHAT THEY WERE.
# ---------------------------------------------------------------------------
#
# The workflow can point `--config` at `.kit/lint/golangci.yml` on every run and
# the file can still have been emptied of every linter it enabled. Nothing
# above notices: the step runs, the config parses, and the job is green on a
# policy that is now five defaults. So the strictness decisions are asserted
# ON THE FILES, by value.
#
# Read as YAML rather than grepped, so a linter name in a comment cannot satisfy
# the check — the same rule AGENTS.md states for every other check here.
REQUIRED_LINTERS = {
    "golangci.yml": [
        "bodyclose", "copyloopvar", "errorlint", "exhaustive",
        "misspell", "noctx", "revive", "unconvert", "wastedassign",
    ],
}
for filename, wanted in REQUIRED_LINTERS.items():
    path = f"{root}/lint/{filename}"
    if not os.path.isfile(path):
        problems.append(f"lint/{filename} is missing")
        continue
    with open(path, encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh) or {}
    enabled = ((cfg.get("linters") or {}).get("enable")) or []
    missing = [name for name in wanted if name not in enabled]
    if missing:
        problems.append(
            f"lint/{filename} no longer enables {missing}. The workflow points "
            f"`--config` at this file on every run, so an emptied config is not a "
            f"failed check — it is a green build on a policy nobody chose. The "
            f"list is asserted BY VALUE because this is the file whose weakening "
            f"is invisible from every other angle"
        )

# `formatters` is a separate key from `linters` in golangci-lint v2, and a
# config that kept its linters and lost its formatters still parses. gofmt and
# goimports are the formatting half of the Go strictness story and they live
# there.
with open(f"{root}/lint/golangci.yml", encoding="utf-8") as fh:
    gcl = yaml.safe_load(fh) or {}
formatters = ((gcl.get("formatters") or {}).get("enable")) or []
for name in ("gofmt", "goimports"):
    if name not in formatters:
        problems.append(
            f"lint/golangci.yml no longer enables the `{name}` formatter. "
            f"`formatters` is a different key from `linters` in golangci-lint v2, "
            f"so this one is lost without touching the linter list at all"
        )

if problems:
    sys.exit("; ".join(problems))
print(
    "3 lint jobs pass --config at a checked-out kit; none is advisory; "
    "the linter list is intact"
)
PY
  }
  section 'static: lint runs from kit, not from a copy'
  check 'lint/ + the workflow  (every lint step is a gate on kit config)' \
    lint_wiring_check

  # -------------------------------------------------------------------------
  # THE SEAM IS NARROW, AND "NARROW" IS A LIST SOMEONE CAN SHORTEN.
  # -------------------------------------------------------------------------
  #
  # `lint-args` is the deviation seam, and the workflow says in three places
  # what it may not be used for. A promise in a comment is not a control, and the
  # first version of this file PROMISED a control that did not exist: the
  # input's own comment said `lint_wiring_check` "fails on exactly that string",
  # and `lint_wiring_check` had no such assertion anywhere in it.
  #
  # The reason is structural and it is worth stating, because it decides where
  # the control lives: **`lint-args` is the CALLER's value.** kit's gate can see
  # that the input exists, that it is a string, and that it defaults to empty. It
  # cannot see what a service put in it, because kit has never got it. So the
  # rule that makes the seam narrow has to run in the service — the
  # `lint-args guard` step, which every lint job has.
  #
  # Which leaves exactly the failure this check exists for: three hand-maintained
  # copies of a policy block, in a repository whose own rule is that duplicated
  # policy blocks are only safe while something reads them. This asserts all
  # three: that the guard is in each lint job, that the three bodies are
  # byte-identical, that the guard runs BEFORE the linter (a guard after it is
  # decoration — the lint has already had its chance), that the linter actually
  # receives the variable (a guard over a value nothing passes on is a guard over
  # nothing), and that the forbidden token list is the one written here.
  #
  # The last of those is the one that matters most. Without it, deleting
  # `--no-config` from the guard's `case` list is a one-token edit that widens
  # the seam for every service in the fleet and leaves the workflow looking
  # exactly as it did before.
  lint_args_seam_check() {
    "$PY" - "$ROOT" "$WORKFLOW" <<'PY2'
import re
import sys

import yaml

root, workflow_path = sys.argv[1], sys.argv[2]
with open(workflow_path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
source = open(workflow_path, encoding="utf-8").read()
triggers = doc.get("on") or doc.get(True) or {}
call = (triggers.get("workflow_call") or {}).get("inputs") or {}
jobs = doc.get("jobs") or {}

LINT_JOBS = ("go", "ruby", "node")

# The forbidden tokens, held HERE as well as in the workflow. Every one was read
# out of the linter's own `--help` on the version kit pins, not remembered:
#
#   which config is read   golangci-lint `--no-config`; eslint
#                         `--no-config-lookup`; rubocop `--force-default-config`;
#                         all three spell "use this config" differently
#   what is linted         golangci-lint `--new*` — a diff, not the tree
#   whether it fails       golangci-lint `--issues-exit-code` (`=0` cannot fail);
#                         rubocop `--fail-level`; eslint `--quiet` (errors only,
#                         which is looser, not stricter) and
#                         `--no-error-on-unmatched-pattern`
#   and two that WRITE A FILE, which is this packet's own reason to refuse them:
#                         rubocop `--auto-gen-config`, `--regenerate-todo`
FORBIDDEN = (
    "--config",
    "-c",
    "--no-config",
    "--no-config-lookup",
    "--force-default-config",
    "--issues-exit-code",
    "--fail-level",
    "--quiet",
    "--no-error-on-unmatched-pattern",
    "--auto-gen-config",
    "--regenerate-todo",
    "--new",
    "--new-from-rev",
    "--new-from-patch",
    "--new-from-merge-base",
)

problems = []

# ---------------------------------------------------------------- the input
seam = call.get("lint-args")
if not isinstance(seam, dict):
    problems.append(
        "no `lint-args` workflow_call input, so a service that needs a stricter "
        "linter has no seam and will fork the workflow instead. Callers override, "
        "they never fork"
    )
else:
    if str(seam.get("type")) != "string":
        problems.append(
            "`lint-args` must be type: string — a list would be split by the "
            "guard's own word-splitting rules and could smuggle a token past it"
        )
    if str(seam.get("default", "x")) != "":
        problems.append(
            f"`lint-args` defaults to {seam.get('default')!r}; it must default to "
            f"the empty string, or every service adopts one team's deviation"
        )
    if "guard" not in (seam.get("description") or ""):
        problems.append(
            "the `lint-args` description does not point at the `lint-args guard` "
            "step. The first version of this description promised an enforcement "
            "in tests/validate.sh that did not exist, and a reader who believed it "
            "would not go looking for the real one"
        )

# ------------------------------------------------------- the guard, per job
bodies = {}
for lang in LINT_JOBS:
    steps = (jobs.get(lang) or {}).get("steps") or []
    names = [s.get("name") for s in steps if isinstance(s, dict)]
    if "lint-args guard" not in names:
        problems.append(
            f"job {lang} has no `lint-args guard` step. The seam's limits are then "
            f"enforced nowhere: kit's gate cannot see the value (it is the "
            f"caller's), so a `--no-config` in a caller would restore the "
            f"linter's defaults and turn kit's policy into five of them"
        )
        continue
    gi = names.index("lint-args guard")
    li = names.index("lint") if "lint" in names else None
    if li is not None and gi > li:
        problems.append(
            f"job {lang}: the `lint-args guard` runs AFTER the `lint` step, so the "
            f"linter has already had its argument list and the guard is decoration"
        )
    body = next(s for s in steps if s.get("name") == "lint-args guard").get("run") or ""
    bodies[lang] = body

    # The tokens, read out of the GUARD'S OWN `case` list rather than the whole
    # body: the guard's comment block names every forbidden flag while explaining
    # why each is refused, so counting tokens in the body would be satisfied by
    # the documentation of the very list it is meant to police.
    m = re.search(r'case\s+"\$name"\s+in(.*?)\besac\b', body, re.S)
    if not m:
        problems.append(
            f"job {lang}: its `lint-args guard` has no `case \"$name\" in ... esac` "
            f"list, so it refuses nothing"
        )
    else:
        listed = set(re.findall(r"--?[A-Za-z][A-Za-z0-9-]*", m.group(1)))
        missing = [t for t in FORBIDDEN if t not in listed]
        if missing:
            problems.append(
                f"job {lang}: the `lint-args guard` no longer refuses {missing}. The "
                f"seam is documented as narrow and this is the list that makes it so; "
                f"dropping a token widens the input for every service in the fleet and "
                f"leaves the workflow looking exactly as it did before"
            )

    # And the guard has to be reading the variable the linter is given.
    if "KIT_LINT_ARGS" not in body:
        problems.append(
            f"job {lang}: its `lint-args guard` does not read KIT_LINT_ARGS, so it "
            f"guards a variable it was not given"
        )
    lint = next((s for s in steps if s.get("name") == "lint"), None)
    if isinstance(lint, dict):
        hay = (lint.get("run") or "") + "\n" + "\n".join(
            f"{k}: {v}" for k, v in (lint.get("with") or {}).items()
        )
        if "KIT_LINT_ARGS" not in hay:
            problems.append(
                f"job {lang}: its `lint` step does not receive KIT_LINT_ARGS, so the "
                f"seam is guarded and then discarded — a repo may set a stricter "
                f"flag, be told it is not allowed to set it, and still get no effect"
            )

if len(set(bodies.values())) > 1 and len(bodies) == len(LINT_JOBS):
    problems.append(
        "the `lint-args guard` steps are not identical across the lint jobs. They "
        "are duplicated because GitHub reusable workflows cannot share a step, and "
        "three copies of a policy block that disagree is the drift this repository "
        "exists to prevent"
    )

if problems:
    sys.exit("; ".join(problems))
print(
    f"the seam is a string input defaulting to empty, guarded by an identical "
    f"pre-lint step in all {len(LINT_JOBS)} lint jobs, refusing {len(FORBIDDEN)} "
    f"flags; and the linter receives it"
)
PY2
  }
  check 'the seam  (narrow, guarded before the linter, and wired to it)' \
    lint_args_seam_check

  # -------------------------------------------------------------------------
  # THE DRIFT CHECK. A service that carries a lint config INCONSISTENT with
  # kit's is the failure this packet exists to end, and it is invisible from
  # both sides: kit cannot see the service's tree, and the service's CI goes
  # green the whole time.
  #
  # WHY IT IS NOT "THE FILE MUST NOT EXIST". That version is easier to write and
  # it is wrong in a way that costs more than the drift it prevents. A service
  # whose `.golangci.yml` is byte-identical to kit's has not drifted; it has
  # arrived at the same policy by another route, and failing it teaches the
  # lesson that kit's config is a thing you get shouted at for having. The
  # check a moment later asserts exactly this, as breakage 27b's GREEN control.
  #
  # So this READS BOTH FILES and reports THE DIFFERENCE, linter by linter. A
  # reader of the failure message learns which linters the service turned off
  # and which it added, which is the only information anyone can act on. A check
  # that only said "unexpected file" would send someone to `diff` by hand.
  #
  # SCOPE, and it is a real limitation rather than a convenient one: this reads
  # the kit working tree plus whatever service checkouts are present beside it
  # (`../<repo>`), which is how every other fleet-shaped check in this file
  # works — `core_repo()` above is the same shape. With no sibling checkout the
  # check SKIPS loudly and says which environment variable points at one. It is
  # never silently green, because a drift check that could not have run and
  # reported nothing is the same class of defect as a lint step that cannot fail.
  # The fleet directories, one per line, that CALL the reusable workflow. A
  # service repo is one that calls it: a repository that does not is not
  # governed by kit's policy, and reporting drift in it would be noise that
  # trains people to ignore this check.
  #
  # Resolved in the same way as `core_repo()` above, and for the same reason: a
  # sibling checkout, or a loud skip. Never a silent pass.
  fleet_repos() {
    local base cand
    for base in "$ROOT/.." "$ROOT/../.." "$ROOT/../../cafaye"; do
      [ -d "$base" ] || continue
      for cand in "$base"/*; do
        [ -d "$cand/.github/workflows" ] || continue
        if grep -ql 'uses: cafaye/kit/.github/workflows/ci.reusable.yml' \
          "$cand"/.github/workflows/*.yml 2>/dev/null; then
          printf '%s\n' "$cand"
        fi
      done
      return 0
    done
    return 1
  }

  # The comparison itself, in Python, because comparing two YAML documents is
  # not a thing shell does, and approximating it with grep is how a check ends
  # up comparing the wrong lines.
  lint_drift_check() {
    local fleet
    fleet="$(fleet_repos)"
    if [ -z "$fleet" ]; then
      # A SKIP and not a failure, and not a pass. The same call `core_check`
      # above makes when core is absent, and for the same reason: a
      # throwaway copy of kit — which is what `self_test.sh` runs the gate
      # against, twenty-odd times — has no fleet beside it, and a check that
      # cannot have run and reported nothing must not be indistinguishable from
      # a check that passed.
      return 2
    fi
    "$PY" - "$ROOT" $fleet "$ROOT/lint/drift-allowlist" <<'PY'
import datetime
import os
import re
import sys

import yaml

kit_root = sys.argv[1]
allowlist_path = sys.argv[-1]
fleet_roots = sorted({os.path.realpath(p) for p in sys.argv[2:-1]})


def is_worktree(path):
    """True when `path` is a git WORKTREE rather than its own repository.

    Same rule and the same reasoning as `tests/staleness.py`: a worktree's
    `.git` is a file, it shares the parent repository's history, and counting it
    separately reports one repository's config twice. Here the cost is a
    duplicated allowlist entry and a finding that looks like two, which is
    exactly the sort of thing a reader learns to discount.
    """
    marker = os.path.join(path, ".git")
    if not os.path.isfile(marker):
        return False
    try:
        with open(marker, encoding="utf-8") as fh:
            return fh.read(6).strip() == "gitdir"
    except OSError:
        return False


# The service-side filenames this check READS. Two facts measured on
# golangci-lint v2.6.2, and the first one corrected a claim this file made
# before it was run:
#
#   1. DISCOVERY IS THE FALLBACK, NOT THE OVERRIDE. `golangci-lint run -v`
#      prints `[config_reader] Used config file <path>`, and it is decisive: with
#      `--config=<kit>` it names kit's file and nothing else, and without the
#      flag it names the repo-root one. A repo-root `.golangci.yml` that
#      disables `misspell` is INERT under `--config` — the misspelling is still
#      reported. This file previously claimed the opposite, that discovery
#      "beats every flag", and that claim was the whole justification for
#      reporting drift. It was wrong.
#   2. So a stale copy does NOT hijack kit's CI. What it does is split the
#      policy: every OTHER golangci-lint invocation in that repository — a
#      developer's `golangci-lint run`, an editor integration, a `make lint`, a
#      pre-commit hook — reads the local file, while kit's CI reads kit's. Two
#      policies in one repository, one of them enforced nowhere it is written
#      down. And the copy becomes live again the moment the `--config` flag goes
#      missing, which is breakage 29, and silently, because a copy is always
#      weaker than the thing it was copied from.
#
# The check is therefore not "the file hijacks the build". It is "the file and
# kit disagree, and only one of the two is what CI runs" — which is a real
# finding, and an honest one.
#
# `eslint.config.mjs` is deliberately NOT here, and now for a measured reason
# rather than a rhetorical one: ESLint's `--config` also wins outright, and a
# service's own `eslint.config.mjs` is only read by something that points at it.
# The two linters behave the same way, so the difference between listing it and
# not listing it is intent, not mechanics: a repo's own ESLint config is a
# legitimate thing to own, and this check is about copies of KIT's policy.
SERVICE_CONFIGS = (".golangci.yml", ".golangci.yaml")


def policy_of(doc):
    """The comparable part of a golangci config: what it turns on and off.

    Three keys, and the omissions are as deliberate as the inclusions.
    Settings, exclusions and paths are NOT compared: a service excluding one
    generated file is a narrow, legitimate, reviewable decision, and comparing
    it would make this check fire on the one deviation the seam explicitly
    permits. What is compared is the linter SET, because turning a linter off
    wholesale is the drift, and it is the drift nobody can see from either side.
    """
    linters = (doc or {}).get("linters") or {}
    return {
        "enable": frozenset(linters.get("enable") or []),
        "disable": frozenset(linters.get("disable") or []),
        "formatters": frozenset(((doc or {}).get("formatters") or {}).get("enable") or []),
    }


def load(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


kit_policy_path = f"{kit_root}/lint/golangci.yml"
if not os.path.isfile(kit_policy_path):
    sys.exit("lint/golangci.yml is missing, so there is no policy to compare against")
kit_policy = policy_of(load(kit_policy_path))

# --------------------------------------------------------------------------
# the allowlist
# --------------------------------------------------------------------------
#
# Two services in the fleet carry a `.golangci.yml` today, and this packet
# cannot fix them — kit does not touch other repositories, and the fix for
# each is a decision its own team makes. So the drift is REAL and RECORDED, with
# an owner and an expiry, rather than being reported as a green pass or as a
# permanently red gate.
#
# This is the same shape as `templates/tier/skip-allowlist` and for the same
# reason. An allowlist nobody can expire is a comment; an allowlist that is only
# ever added to is a ratchet pointing the wrong way. So:
#
#   1. every entry needs a reason, an owner, and both dates;
#   2. an EXPIRED entry is a FAILURE on the day it expires;
#   3. a duplicate (repo, path, key) is a FAILURE — one of the two is dead;
#   4. AN ENTRY THAT NO LONGER DESCRIBES A REAL DIFFERENCE IS A FAILURE.
#
# Rule 4 is the one that earns the other three. Modelled on ESLint's
# `reportUnusedDisableDirectives`, which reports a disable comment that no
# longer suppresses anything: without it, a fixed repository stays listed, the
# listing stops being read, and within two quarters the file contains every
# repository in the fleet. The entry is how you find out first.
LINE = re.compile(
    r"^diverged\s+(?P<repo>\S+)\s+(?P<path>\S+)\s+(?P<key>\S+)"
    r"(?P<fields>(?:\s+[a-z]+=(?:\"[^\"]*\"|\S+))*)\s*$"
)
FIELD = re.compile(r'([a-z]+)=("[^"]*"|\S+)')
WHY = {
    "reason": 'without one, "we will get to it" is the reason for everything',
    "owner": "drift nobody owns is drift nobody will ever fix",
    "since": "the ratchet needs the date the decision was taken",
    "until": "an entry that cannot expire has stopped being a decision",
}
KEYS = ("enable", "disable", "formatters")

allowed = {}
today = datetime.date.today()
if not os.path.isfile(allowlist_path):
    sys.exit(
        f"{allowlist_path} is missing. A drift check with nowhere to record a "
        f"known divergence is a check that either reports the fleet as broken or "
        f"has been taught to report nothing"
    )

for lineno, raw in enumerate(open(allowlist_path, encoding="utf-8").read().splitlines(), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    m = LINE.match(line)
    if not m:
        sys.exit(
            f"lint/drift-allowlist:{lineno}: malformed entry. Expected "
            f"'diverged <repo> <path> <enable|disable|formatters> "
            f"reason=\"...\" owner=... since=YYYY-MM-DD until=YYYY-MM-DD' on ONE line"
        )
    fields = {k: v.strip('"') for k, v in FIELD.findall(m.group("fields"))}
    for field in ("reason", "owner", "since", "until"):
        if not fields.get(field):
            sys.exit(f"lint/drift-allowlist:{lineno}: entry names no {field} — {WHY[field]}")
    if m.group("key") not in KEYS:
        sys.exit(
            f"lint/drift-allowlist:{lineno}: key {m.group('key')!r} is not one of "
            f"{list(KEYS)}. A key the comparison does not read is an entry that "
            f"silently matches nothing"
        )
    for field in ("since", "until"):
        try:
            datetime.date.fromisoformat(fields[field])
        except ValueError:
            sys.exit(f"lint/drift-allowlist:{lineno}: {field}={fields[field]!r} is not an ISO date")
    if datetime.date.fromisoformat(fields["until"]) < today:
        sys.exit(
            f"lint/drift-allowlist:{lineno}: EXPIRED on {fields['until']} (today is "
            f"{today.isoformat()}). Delete the entry, or move the date and write a new "
            f"reason — a date that rolls forward by itself is not a ratchet"
        )
    key = (m.group("repo"), m.group("path"), m.group("key"))
    if key in allowed:
        sys.exit(
            f"lint/drift-allowlist:{lineno}: {key} is already listed on line "
            f"{allowed[key]}. Two lines for one divergence means one of them is no "
            f"longer being read"
        )
    allowed[key] = lineno

# --------------------------------------------------------------------------
# the comparison
# --------------------------------------------------------------------------
problems = []
seen_repos = set()
found = set()
compared = 0

for root in fleet_roots:
    if is_worktree(root):
        continue  # one repository, one entry — see the docstring
    name = os.path.basename(root)
    seen_repos.add(name)
    for service_name in SERVICE_CONFIGS:
        path = os.path.join(root, service_name)
        if not os.path.isfile(path):
            continue
        compared += 1
        try:
            got = policy_of(load(path))
        except Exception as exc:
            problems.append(
                f"{name}/{service_name} does not parse as YAML ({exc}), so nobody can "
                f"say what policy it applies. An unreadable copy is the worst case of "
                f"the thing this check is for: a service linted by a config nobody "
                f"can read, in a build that stays green"
            )
            continue
        for key in KEYS:
            if kit_policy[key] == got[key]:
                continue
            found.add((name, service_name, key))
            if (name, service_name, key) in allowed:
                continue
            missing = sorted(kit_policy[key] - got[key])
            extra = sorted(got_policy for got_policy in (got[key] - kit_policy[key]))
            what = []
            if missing:
                what.append(f"no longer enables {missing}")
            if extra:
                what.append(f"enables {extra}, which kit does not")
            problems.append(
                f"{name}/{service_name}: {key} INCONSISTENT with lint/golangci.yml — "
                f"{'; '.join(what)}. Measured on golangci-lint v2.6.2: `--config` "
                f"WINS, so this file is inert for kit's CI, and that is the reason "
                f"this is a finding rather than a non-event. Two policies now govern "
                f"one repository — kit's, which CI runs, and this one, which every "
                f"other invocation reads (a developer's `golangci-lint run`, an "
                f"editor, a `make lint`). And the split is silent in the direction "
                f"that matters: the moment the workflow's `--config` is dropped, "
                f"this weaker file governs the build and nothing says so. Either "
                f"delete it and let kit's policy be the only one, or make the "
                f"deviation deliberate and visible in the workflow's `lint-args` "
                f"seam. To record a difference you cannot delete yet, add an entry "
                f"to lint/drift-allowlist with a reason, an owner and an expiry"
            )

# "The fleet is not here" is checked BEFORE the unused-entry rule, and the order
# is load-bearing. Both rules read the same missing information: with no sibling
# checkouts there is no comparison, so every entry trivially describes no
# difference. Reporting all of them as unused in that case is a false alarm that
# says "delete these" about debt nobody has discharged, and it fires in exactly
# the place it is most damaging — `tests/self_test.sh` runs the gate against a
# throwaway copy of kit, which has no fleet beside it, so the control would be
# red on a correct tree.
#
# The rule can only be evaluated when there was a fleet to evaluate it against.
if not seen_repos:
    sys.exit(
        "no cafaye service checkout was found beside this one, so the drift check "
        "had nothing to compare. A drift check that could not have run and reported "
        "nothing is a check that will not be missed when it matters"
    )

# Rule 4. An entry that no longer describes a real difference is dead weight,
# and dead weight in an allowlist is how an allowlist becomes a list of
# everything.
#
# RULE 4 IS SCOPED TO THE REPOSITORIES THIS RUN ACTUALLY LOOKED AT, and that
# scoping is the whole correctness of the rule rather than a softening of it.
# "This entry no longer describes a difference" is a claim about a file, and the
# only way to make it is to have read that file. A repository that is not in the
# fleet beside this checkout has NOT been read, so nothing is known about it, and
# reporting its entry as unused is a check inventing a finding out of its own
# ignorance.
#
# It is not a theoretical concern. It fired the moment this file was finished:
# `tests/self_test.sh` runs this gate against a throwaway COPY of kit, and a
# copy's fleet is itself rather than the cafaye directory, so every entry in the
# allowlist named a repository that was not present — and the gate went red on a
# perfectly correct tree, telling the reader to delete debt that had not been
# discharged. A rule that cries wolf in its own test suite is a rule people
# learn to bypass with `--no-`, which is the failure this packet exists to end.
#
# The consequence is stated rather than hidden: a repository DELETED from the
# fleet leaves an entry nothing can flag. That is a real limit and it is paid
# for deliberately, because the alternative is a gate that is red whenever kit is
# checked out on its own — which is every fresh clone and every CI runner. What
# covers the deleted case is `tests/staleness.py`, which reports a repository
# that calls kit and is not resolvable; this file covers the case where the
# repository is HERE and no longer differs, and the two are not the same
# question.
# Whether this run can speak about a repository it did not see, and the answer
# is not the same in the two situations kit runs in.
#
#   - A REAL checkout: the scan found the fleet, so a repository in the
#     allowlist that the scan did NOT find is a repository that has been deleted,
#     renamed, or renamed away. That is a finding, and it is the case rule 4
#     exists for: the entry is dead weight and nobody will notice without it.
#   - A COPY of kit, which is what `tests/self_test.sh` runs the gate against
#     twenty-odd times: the only "fleet" beside it is itself, because a copy has
#     no cafaye directory next to it. Nothing can be said about `identity` there,
#     and reporting its entry as dead would be the check inventing a finding out
#     of its own ignorance — red on a perfectly correct tree, telling the reader
#     to delete debt that has not been discharged. It fired the moment this file
#     was finished, on the gate's own test suite.
#
# So the two are told apart by asking whether the scan found anything other than
# this checkout, which is a fact about the run rather than a flag someone can set
# to make the check quiet.
only_me = seen_repos <= {os.path.basename(os.path.realpath(kit_root))}
unverified = 0
for repo, path_name, key in sorted(set(allowed) - found):
    if repo not in seen_repos and only_me:
        # Counted and printed, never failed on. Silence would be the other
        # mistake: a reader cannot tell "checked and clean" from "never looked".
        unverified += 1
        continue
    if repo not in seen_repos:
        problems.append(
            f"lint/drift-allowlist:{allowed[(repo, path_name, key)]}: the entry "
            f"names {repo}/{path_name} ({key}), and this run found no such "
            f"repository in the fleet beside this checkout. Either that repository "
            f"has been deleted or renamed — in which case the entry is dead weight "
            f"and the file is one step from being a list of every repository the "
            f"fleet has ever had — or the entry is a typo. Neither is a state you "
            f"can leave it in"
        )
        continue
    problems.append(
        f"lint/drift-allowlist:{allowed[(repo, path_name, key)]}: the entry for "
        f"{repo}/{path_name} ({key}) no longer describes a difference — the "
        f"repository is here and no longer diverges, so either it adopted kit's "
        f"policy or the file is wrong. Delete the entry, or this file becomes a "
        f"list of every repository the fleet has ever had"
    )

if problems:
    sys.exit("; ".join(problems))

print(
    f"{len(seen_repos)} service repo(s) compared against kit's golangci policy; "
    f"{compared} carried their own config; {len(allowed)} divergence(s) recorded in "
    f"lint/drift-allowlist, none expired, none unused"
    + (
        f"; {unverified} entr(y/ies) named a repository that is not in this "
        f"checkout's fleet, so this run could not look and did NOT count them as "
        f"clean (this is a copy of kit with no fleet beside it, not the fleet)"
        if unverified
        else ""
    )
)
PY
  }
  # `check` cannot express "skip", so the exits are handled here: 2 is this
  # check's own "there was nothing to compare" and reports a SKIP, which the
  # summary counts. Anything else is a real finding.
  #
  # The output is printed on the passing path rather than swallowed, for the same
  # reason `core_check`'s is: the count of repositories compared is what makes
  # "it passed" mean something, and a green line that could equally have come
  # from a check that examined nothing is the failure this whole file is about.
  if _drift_out="$(lint_drift_check 2>&1)"; then
    report PASS 'lint drift  (a service config is compared to kit, not merely forbidden)'
    [ -n "$_drift_out" ] && printf '%s\n' "$_drift_out" | sed 's/^/       /'
  else
    case "$?" in
      2) report SKIP 'lint drift  (no cafaye service checkout found beside this one)' ;;
      *)
        report FAIL 'lint drift  (a service config is compared to kit, not merely forbidden)'
        printf '%s\n' "$_drift_out" | sed 's/^/       /'
        ;;
    esac
  fi

  # (3) The skip allowlist and its four hygiene rules. This is the load-bearing
  #     check of the packet, and rule 4 is the sharpest property in the repo:
  #     AN ENTRY THAT MATCHES NOTHING IS A FAILURE.
  #
  #     The inventory is derived from `templates/tier/` — the declarations kit
  #     ships — because that is the only inventory kit can see. Applying the same
  #     rule over a service's real run is `caf gate`'s job, and that boundary is
  #     written down in templates/tier/README.md rather than blurred here.
  #
  #     Note what this inventory is NOT. It is not a grep for a sentinel that
  #     guesses whether a test "looks like" a database test, which is what fails
  #     open. It reads ids the author DECLARED. That difference is the whole
  #     distance between a derivation that misses new tests and one that cannot.
  skip_allowlist_check() {
    "$PY" - "$ROOT" <<'PY'
import datetime
import os
import re
import sys

root = sys.argv[1]
path = os.path.join(root, "templates", "tier", "skip-allowlist")
if not os.path.isfile(path):
    sys.exit("templates/tier/skip-allowlist is missing: a skipped test needs a recorded reason")

# ---------------------------------------------------------------- the inventory
#
# One regex per language, reading the id the author declared. Deliberately
# simple, and deliberately the only place kit looks at a language at all. A
# language with no pattern here simply cannot have an allowlist entry, which is
# the safe direction: an unresolvable entry is a failure, never a silent pass.
ID_PATTERNS = {
    "go": r"^func (Test\w+)\(",
    "rust": r"^\s*fn (\w+)\(",
    "python": r"^def (test_\w+)\(",
    "ruby": r"^\s*def (test_\w+)\b",
    "elixir": r'^\s*test "([\w.]+)"',
    "bun": r'^test\("([\w]+)"',
    "node": r'^test\("([\w]+)"',
}

inventory = set()
tier_root = os.path.join(root, "templates", "tier")
for lang, pattern in ID_PATTERNS.items():
    d = os.path.join(tier_root, lang)
    if not os.path.isdir(d):
        continue
    for name in sorted(os.listdir(d)):
        # isfile, and a non-file is the declaration check's problem to report
        # rather than this one's to crash on. See the note there.
        if name.startswith(".") or name == "README.md":
            continue
        if not os.path.isfile(os.path.join(d, name)):
            continue
        body = open(os.path.join(d, name), encoding="utf-8").read()
        for tid in re.findall(pattern, body, re.M):
            inventory.add(f"{lang}/{name} {tid}")

# A check that proved nothing because it looked at nothing is a check that ran
# nothing. An empty inventory would make rule 4 either reject every entry or —
# far worse — invite someone to relax it into a no-op that always passes.
if not inventory:
    sys.exit(
        "no test ids were derived from templates/tier/, so the unused-entry rule "
        "would be checking nothing: every ID_PATTERNS entry has stopped matching "
        "its own template"
    )

# ---------------------------------------------------------------- the entries
#
#   skipped <tier> <suite-id> <test-id> reason="…" owner=… since=… until=…
#
# The first four fields are the normalised result line verbatim, so a result and
# its exemption share one shape and a reader only has to learn one format.
LINE = re.compile(
    r'^skipped\s+(?P<tier>\S+)\s+(?P<suite>\S+)\s+(?P<test>\S+)'
    r'(?P<fields>(?:\s+[a-z]+=(?:"[^"]*"|\S+))*)\s*$'
)
FIELD = re.compile(r'([a-z]+)=("[^"]*"|\S+)')
WHY = {
    "reason": 'without one, "flaky" becomes the reason for everything',
    "owner": "a skip nobody owns is a skip nobody will ever remove",
    "since": "the ratchet needs the date the decision was taken",
    "until": "an entry that cannot expire has stopped being a decision",
}

today = datetime.date.today()
problems = []
seen = {}
entries = 0

for lineno, raw in enumerate(open(path, encoding="utf-8").read().splitlines(), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    entries += 1

    m = LINE.match(line)
    if not m:
        problems.append(
            f"line {lineno}: malformed entry. Expected 'skipped <tier> <suite-id> "
            f"<test-id> reason=\"...\" owner=... since=YYYY-MM-DD until=YYYY-MM-DD' on "
            f"ONE line — a wrapped reason is two entries, one of which is a parse error"
        )
        continue

    fields = {k: v.strip('"') for k, v in FIELD.findall(m.group("fields"))}
    key = (m.group("tier"), m.group("suite"), m.group("test"))

    # Rules 1, 2 and 3: a reason, an owner, and both dates. Each message says
    # why the rule exists, because a bare "missing field" reads like a nit.
    for name in ("reason", "owner", "since", "until"):
        if not fields.get(name):
            problems.append(f"line {lineno}: entry names no {name} — {WHY[name]}")

    if key in seen:
        problems.append(
            f"line {lineno}: duplicate entry, already listed on line {seen[key]}. Two "
            f"lines for one test means one of them is no longer being read"
        )
    seen[key] = lineno

    for name in ("since", "until"):
        value = fields.get(name)
        if not value:
            continue
        try:
            parsed = datetime.date.fromisoformat(value)
        except ValueError:
            problems.append(f"line {lineno}: {name}={value!r} is not an ISO date (YYYY-MM-DD)")
            continue
        # The gate reads the clock. An expired entry is a FAILURE on the day it
        # expires, and the file's own header says so, so nobody is surprised by
        # a red build in January: that is the ratchet working.
        if name == "until" and parsed < today:
            problems.append(
                f"line {lineno}: EXPIRED on {value} (today is {today.isoformat()}). "
                f"Delete the entry, or move the date and write a new reason — a date "
                f"that rolls forward by itself is not a ratchet"
            )

    # Rule 4. Modelled on ESLint's `reportUnusedDisableDirectives`, which reports
    # a disable comment that no longer suppresses anything. Without this rule an
    # allowlist is a ratchet that only turns one way: fixed tests stay listed,
    # listed tests stop being checked, and within two quarters the file contains
    # every test in the repository. The unused entry is how you find out first.
    lookup = f"{m.group('suite')} {m.group('test')}"
    if lookup not in inventory:
        problems.append(
            f"line {lineno}: entry matches NOTHING — no test id {m.group('test')!r} in "
            f"{m.group('suite')}. The test was renamed, or the skip was fixed and the "
            f"entry left behind. Either way it is dead weight, and dead entries are "
            f"how an allowlist becomes a list of every test in the repository"
        )

if problems:
    for p in problems:
        print("  -", p)
    sys.exit(1)

# THE TOTAL, PRINTED ON PASS. The `check` helper prints a passing check's stdout
# indented under its label, so this shows up in a GREEN run — the only place a
# growing list is least likely to be noticed. Individual entries look justified;
# the aggregate is the problem, and an aggregate nobody is shown is an aggregate
# nobody watches. Conftest reports exceptions as a separate tally for this reason.
print(
    f"skip allowlist: {entries} entr{'y' if entries == 1 else 'ies'}, all matched "
    f"against {len(inventory)} declared test ids — none unused, none expired. "
    f"The total is the number to watch."
)
PY
  }
  check 'templates/tier/skip-allowlist  (reason, owner, since, until; unused entries fail)' \
    skip_allowlist_check

  # (3b) The PARITY allowlist, and the artefact table it is checked against.
  #
  #     Same four hygiene rules as the tier skip allowlist above, in the same
  #     words, because kit does not have two dialects of "record why". What is
  #     NEW here is the other direction, and it is the one that matters most:
  #
  #     AN UNPINNED DIVERGENCE OR ABSENCE IS A FAILURE.
  #
  #     The tier allowlist does not need that rule because its entries name
  #     tests that are either present or absent for reasons the file's own
  #     comments explain. This one names copies in repositories kit cannot see
  #     at gate time, so the file is a RECORD OF THE FLEET, and a record that
  #     silently omits a cell is worse than no record: it reads as "handled".
  #
  #     Which is why the count is printed on PASS, in the sentence a green run
  #     shows, and why the header says the number is a measurement and not a
  #     ledger to shrink. Deleting an entry to make the count go down is a
  #     failure of its own, and the reporter catches it against the fleet.
  #
  #     The two checks the gate can run WITHOUT the fleet are the ones it runs:
  #     an entry that names an `artefact-id` kit does not ship, and an entry
  #     whose verb is not a verb the reporter can report. The rest — an unpinned
  #     cell, a dead entry, a verb that disagrees with the measurement — needs
  #     the fleet, and is proven by `tests/staleness_test.sh` against a fixture
  #     fleet rather than asserted here. Saying so is the point: a check that
  #     claims to have compared 80 entries against nine repositories it has
  #     never read is the kind of claim this repository exists to distrust.
  parity_allowlist_check() {
    "$PY" - "$ROOT" <<'PY'
import datetime
import json
import os
import re
import sys

root = sys.argv[1]
ledger = os.path.join(root, "templates", "parity-allowlist")
table_path = os.path.join(root, "tests", "artifacts.json")

if not os.path.isfile(ledger):
    sys.exit(
        "templates/parity-allowlist is missing: kit ships twelve artefacts that "
        "services copy, and a divergence with no recorded reason is unproven "
        "rather than fine"
    )
if not os.path.isfile(table_path):
    sys.exit("tests/artifacts.json is missing: there is no declaration of what kit ships")

# The inventory is the artefact table — the SAME file the reporter reads, which
# is the point of having one. An inventory derived independently here would be a
# second, unchecked copy of the truth, which is the defect AGENTS.md's
# header/recipe check exists to prevent and which kit has already had once.
try:
    with open(table_path, encoding="utf-8") as fh:
        table = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    sys.exit(f"tests/artifacts.json is unreadable: {exc}. A table this gate cannot "
             f"read is a table it would approve anything against")

ids = {a.get("id") for a in table.get("artefacts", []) if a.get("id")}
if not ids:
    sys.exit(
        "tests/artifacts.json declares no artefact ids, so the unused-entry rule "
        "would check nothing: an allowlist validated against an empty inventory "
        "is an allowlist that accepts everything"
    )

#   diverged  present at the declared path, not byte-identical
#   absent    not present where kit ships one
#   unknown   the comparison could not be made (no declared language)
#
# Three verbs, and the third is why this is not a two-verb format: an
# unmeasurable cell is a finding, and a two-verb ledger would have to state
# something false about it to record something true.
LINE = re.compile(
    r'^(?P<verb>diverged|absent|unknown)\s+(?P<repo>\S+)\s+(?P<artefact>\S+)'
    r'(?P<fields>(?:\s+[a-z]+=(?:"[^"]*"|\S+))*)\s*$'
)
FIELD = re.compile(r'([a-z]+)=("[^"]*"|\S+)')
WHY = {
    "reason": 'without one, "it is fine" becomes the reason for everything',
    "owner": "a divergence nobody owns is a divergence nobody will bring back into line",
    "since": "the ratchet needs the date the decision was taken",
    "until": "an entry that cannot expire has stopped being a decision",
}

today = datetime.date.today()
problems = []
seen = {}
entries = 0

for lineno, raw in enumerate(open(ledger, encoding="utf-8").read().splitlines(), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    entries += 1

    m = LINE.match(line)
    if not m:
        problems.append(
            f"line {lineno}: malformed entry. Expected 'diverged|absent|unknown <repo> "
            f"<artefact-id> reason=\"...\" owner=… since=YYYY-MM-DD "
            f"until=YYYY-MM-DD' on ONE line — a wrapped reason is two entries, one "
            f"of which is a parse error"
        )
        continue

    fields = {k: v.strip('"') for k, v in FIELD.findall(m.group("fields"))}
    key = (m.group("repo"), m.group("artefact"))

    for name in ("reason", "owner", "since", "until"):
        if not fields.get(name):
            problems.append(f"line {lineno}: entry names no {name} — {WHY[name]}")

    # The unused-entry rule, against the artefact table. This is ESLint's
    # `reportUnusedDisableDirectives` shape: an entry for something that no
    # longer exists excuses nothing, and the entry is how you find out first.
    # Resolved against the TABLE and not against a directory listing, so a
    # renamed artefact fails loudly instead of quietly matching whatever now
    # sits at that path.
    if m.group("artefact") not in ids:
        problems.append(
            f"line {lineno}: entry matches NOTHING — tests/artifacts.json declares "
            f"no artefact {m.group('artefact')!r}. The artefact was renamed or "
            f"removed, or the entry was written for a typo. Either way it is dead "
            f"weight, and a ledger that cannot notice its own dead entries is a "
            f"ledger that eventually contains the whole fleet"
        )

    if key in seen:
        problems.append(
            f"line {lineno}: duplicate entry for {key[0]}/{key[1]}, already listed "
            f"on line {seen[key]}. Two records for one cell means one of them is "
            f"not being read"
        )
    seen[key] = lineno

    for name in ("since", "until"):
        value = fields.get(name)
        if not value:
            continue
        try:
            parsed = datetime.date.fromisoformat(value)
        except ValueError:
            problems.append(f"line {lineno}: {name}={value!r} is not an ISO date (YYYY-MM-DD)")
            continue
        if name == "until" and parsed < today:
            problems.append(
                f"line {lineno}: EXPIRED on {value} (today is {today.isoformat()}). "
                f"Re-copy the artefact and delete the entry, or move the date and "
                f"write a NEW reason — a date that rolls forward by itself is not "
                f"a ratchet"
            )

if problems:
    for p in problems:
        print("  -", p)
    sys.exit(1)

# THE TOTAL, PRINTED ON PASS. `check` indents a passing check's stdout under its
# label, so this is visible in a GREEN run — the only place a growing list is
# least likely to be noticed, and the whole reason the tier allowlist prints its
# count too. 80 entries is a bad number, and it is printed so that everybody
# can see it is a bad number.
print(
    f"parity allowlist: {entries} entr{'y' if entries == 1 else 'ies'} across "
    f"{len({k[0] for k in seen})} repositor{'y' if len({k[0] for k in seen}) == 1 else 'ies'}, "
    f"every artefact id in artifacts.json, none expired, none dead. THE TOTAL IS "
    f"THE MEASUREMENT: 80 entries is 80 copies of kit's templates that the fleet "
    f"has not adopted or has changed, and the way to shrink it is to re-copy, not "
    f"to delete an entry. Compare against `tests/staleness.py --scope templates "
    f"--repos-dir …` for the per-cell state."
)
PY
  }
  check 'templates/parity-allowlist  (reason, owner, since, until; dead entries fail)' \
    parity_allowlist_check

  # (3c) The artefact table must describe files that EXIST.
  #
  #     A table naming a file kit does not ship makes the reporter call every
  #     service `absent` for it, forever. That output is indistinguishable from
  #     a migration backlog, which is the dangerous direction: it would put a
  #     permanent, unactionable finding in front of a reader and be believed.
  #     So the table is checked against the tree, and the reporter refuses to
  #     run at all on a table that fails — proved by staleness_test.sh case 28.
  #
  #     This is the same check the reporter makes, called directly rather than
  #     reimplemented, because two implementations of "is this a real path" is
  #     one implementation too many.
  artifact_table_check() {
    "$PY" - "$ROOT" <<'PY'
import importlib.util
import os
import sys

root = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "staleness", os.path.join(root, "tests", "staleness.py")
)
if spec is None or spec.loader is None:
    sys.exit("tests/staleness.py could not be loaded, so the artefact table cannot "
             "be checked against the tree it describes")
staleness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staleness)

table = staleness.load_table(os.path.join(root, "tests", "artifacts.json"))
problems = staleness.validate_table_against_kit(table, root)

# A `{lang}` source must resolve for EVERY language the workflow offers. The
# glob above proves the shape exists, which catches a rename; this catches a
# template that exists for five of the seven languages, which is a half-adopted
# language and the exact defect kit's own "half a language is worse than none"
# rule is about.
# The languages, read the way the rest of this file reads them: as YAML, from
# the workflow's own `language` gate job. `validate.sh` already requires PyYAML
# and already loads this workflow several times, so parsing it here is not a new
# dependency — it is the difference between asking the question and grepping
# for it.
#
# It used to read an `options:` list under the input. That key is not legal
# under `workflow_call` — GitHub rejects the whole file — so this check was
# reading a key the workflow was not allowed to carry, and would have reported
# "could not check" the moment the file was made legal. The enumeration now
# lives in the case statement of the job that rejects an unrecognised value,
# which is the only place it is actually enforced.
#
# `none` is excluded: it is not a language, it is the value for a repository
# with no service manifest, and `templates/bin-prime/none.sh` does not exist and
# should not.
import re

import yaml

workflow = os.path.join(root, ".github", "workflows", "ci.reusable.yml")
languages = set()
try:
    with open(workflow, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}
    gate = "\n".join(
        str(st.get("run") or "")
        for st in (((doc.get("jobs") or {}).get("language") or {}).get("steps") or [])
        if isinstance(st, dict)
    )
    languages = {
        name
        for arm in re.findall(r"^\s*([a-z|]+)\)\s*$", gate, re.M)
        for name in arm.split("|")
        if name and name != "none"
    }
except (OSError, yaml.YAMLError) as exc:
    problems.append(f"the reusable workflow could not be parsed: {exc}")
if not languages:
    problems.append(
        "the reusable workflow's `language` job names no languages, so the "
        "{lang}-interpolated artefacts cannot be checked for every language. A "
        "check that could not ask its question must not report a pass"
    )

for artefact in table["artefacts"]:
    if not artefact.get("needsLanguage"):
        continue
    for lang in sorted(languages):
        source = os.path.join(root, artefact["source"].replace("{lang}", lang))
        if not os.path.isfile(source):
            problems.append(
                f"{artefact['id']}: kit offers `language: {lang}` but ships no "
                f"{artefact['source'].replace('{lang}', lang)}. Half a language is "
                f"worse than none: a service that adopts it gets a broken primer"
            )

if problems:
    for p in problems:
        print("  -", p)
    sys.exit(1)
print(
    f"artefact table: {len(table['artefacts'])} artefact(s), every source present "
    f"in this tree, and every {{lang}} source resolving for all "
    f"{len(languages)} languages the workflow offers"
)
PY
  }
  check 'tests/artifacts.json  (every declared source exists, for every language)' \
    artifact_table_check

  # (3d) The carve-out boundary: the two programs import NOTHING from outside the
  #      standard library, and only from the seven modules AGENTS.md names.
  #
  #      AGENTS.md's rules section says "standard library only, no import outside
  #      json/os/re/sys/argparse/subprocess" and calls that a carve-out rather
  #      than a precedent. Until now nothing checked it, which made the sentence
  #      a promise — and a promise nobody can break is decoration. This parses
  #      every `import` in both programs rather than grepping, so a
  #      `from x import y`, a function-local import and a module named inside a
  #      docstring's example are all read the same way.
  #
  #      `difflib` is on the list because the templates half of the staleness
  #      reporter counts the lines two copies differ by, and a list that grows
  #      by a later commit is not a control — so growing it is a red gate, and
  #      the only way past is to change this file and this check in the same
  #      commit.
  carveout_boundary_check() {
    "$PY" - "$ROOT" <<'PY'
import ast
import os
import sys

root = sys.argv[1]

# The list is written HERE and in AGENTS.md, and the two are compared against
# each other by the check below — so the sentence in AGENTS.md cannot quietly
# stop matching the rule the gate enforces, which is the property that made
# kit-05's fail-closed headline worth restating.
# `yaml` is PyYAML, which `tests/requirements.txt` already carries and the gate
# already bootstraps — so naming it is the existing carve-out rather than a
# widened one. AGENTS.md names it in the same paragraph that names the program
# that needs it, and the check below asserts the two agree.
STANDARD_LIBRARY = {
    "__future__", "argparse", "difflib", "glob", "hashlib", "json", "os", "re",
    "subprocess", "sys", "urllib",
}
ALLOWED = STANDARD_LIBRARY | {"yaml"}

# generated_stack_check.py joined this list in fleet-generated-compose-01 and is
# the first program here that answers git rather than parsing a file. It is
# stdlib for the same reason the others are — the carve-out is what keeps kit
# a repository with no dependencies — and naming it here is the only way it
# stays inside the boundary rather than merely claiming to.
# account_scope_fleet_check.py is the fourth: it exists because a CI runner has no
# fleet beside the repository, so the contract has to be run by a program the
# workflow can invoke directly rather than by this gate. AGENTS.md argues it in
# the Rules section, and the assertion at the bottom of this block is what stops
# that argument and this list from being different claims.
programs = ["tests/classify.py", "tests/staleness.py",
            "tests/generated_stack_check.py",
            "tests/account_scope_fleet_check.py"]
problems = []
seen_modules = set()

for rel in programs:
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        problems.append(
            f"{rel} is missing: the carve-out is a boundary around its named programs")
        continue
    with open(path, encoding="utf-8") as fh:
        try:
            tree = ast.parse(fh.read(), filename=rel)
        except SyntaxError as exc:
            problems.append(f"{rel} does not parse: {exc}")
            continue
    # ast.walk, not the module body: a function-local import is still an
    # import, and the whole value of this check is that there is nowhere to put
    # one that it cannot see.
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names = [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom):
            # `level > 0` is a relative import, which cannot happen in a program
            # nothing imports — and is checked rather than assumed.
            if node.level:
                problems.append(
                    f"{rel}:{node.lineno} is a RELATIVE import. Nothing here is a "
                    f"package, and a relative import is the first sign of one"
                )
                continue
            names = [node.module or ""]
        else:
            continue
        for name in names:
            top = name.split(".")[0]
            seen_modules.add(top)
            if top not in ALLOWED:
                problems.append(
                    f"{rel}:{getattr(node, 'lineno', '?')} imports {top!r}, which is "
                    f"not standard library or not on AGENTS.md's list. These "
                    f"programs are the ONE carve-out from 'config only', and the "
                    f"carve-out is what keeps kit a repository with no "
                    f"dependencies — so a new import is a decision about this "
                    f"repo's identity, not a convenience"
                )

# A check that proved nothing because it parsed nothing is a check that ran
# nothing. Every program must be present AND the walk must have seen something.
if not seen_modules:
    problems.append(
        "no imports were found in any of the programs, so the carve-out check "
        "would approve anything: they have changed shape and the check has not"
    )

# AGENTS.md and this list must agree. The list is the enforcement; the sentence
# in AGENTS.md is what a reader believes, and a reader who believes something
# else from the one that is enforced is worse off than either. That is also why
# `account_scope_fleet_check.py` had to be named there on the day it landed: the
# fourth program is a decision, and a decision nobody can find is not made.
#
# `urllib` and its submodules are the reason this half exists as a separate
# assertion: the reporter imports `urllib.request` and `urllib.error` for the
# GitHub-org discovery route, and AGENTS.md's original list did not name them —
# so the sentence was already out of date before this check, and the only way
# anyone would ever have found out is if they went looking.
agents = open(os.path.join(root, "AGENTS.md"), encoding="utf-8").read()
missing = sorted(m for m in seen_modules if f"`{m}`" not in agents)
if missing:
    problems.append(
        f"AGENTS.md's carve-out sentence does not name {', '.join(missing)}, which "
        f"the programs import. The sentence a reader trusts and the list the gate "
        f"enforces are not allowed to be different lists"
    )

if problems:
    for p in problems:
        print("  -", p)
    sys.exit(1)
# The sentence says WHICH modules are not standard library rather than asserting
# every one of them is: `yaml` is PyYAML, which is the point, and a summary that
# claimed "all standard library" over a list containing PyYAML would be a false
# claim printed on every green run.
third_party = sorted(m for m in seen_modules if m not in STANDARD_LIBRARY)
print(
    f"carve-out boundary: {len(programs)} programs, {len(seen_modules)} distinct "
    f"imports ({', '.join(sorted(seen_modules))}); standard library except "
    f"{', '.join(third_party) or '(none)'}"
    + (", which is PyYAML — already in tests/requirements.txt and already "
       "bootstrapped by this gate" if third_party else "")
    + ". All named in AGENTS.md. kit has no dependency and cannot grow one without "
      "this gate going red."
)
PY
  }
  check 'the carve-out programs  (stdlib plus PyYAML; enforced, and AGENTS.md agrees)' \
    carveout_boundary_check

  # (4) Never cache a test report.
  #
  #     `actions/cache` `restore-keys` restores STALE caches by PREFIX MATCH, and
  #     GitHub documents that the default branch's cache is available to other
  #     branches. So a key built from `hashFiles('**/lockfile')` — which does not
  #     contain the gate variable — restores a test report written by a run that
  #     HAD the database into a run that does not. A witness restored from a
  #     different run is not a witness.
  #
  #     Build products (target/, $GOCACHE, node_modules, vendor/bundle) are
  #     cacheable and deliberately not caught here. Test reports are.
  #
  #     The cross-trust-boundary half — fork PRs get read-only cache access, so
  #     any workflow using actions/cache can restore a trusted run's report — is
  #     stated in README.md rather than checked here, because it is a property of
  #     GitHub's cache and not of this repository.
  no_cached_report_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]

# A path that is a test RESULT, not a build product. The alternation is
# anchored on a path segment or the string start, so `reports/coverage.xml` is
# caught and `internal/report.go` is not.
REPORT = re.compile(
    r"(?:^|/)(?:junit|test-?results?|coverage|coverage\.\w+|report\.xml"
    r"|pytest\.xml|nextest\.xml|gotestsum\.xml|karma[\w-]*\.xml)(?:$|[/\s'\"])"
)

problems = []
checked = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in (".git", ".venv", "node_modules")]
    for name in sorted(filenames):
        if not name.endswith((".yml", ".yaml")):
            continue
        full = os.path.join(dirpath, name)
        rel = os.path.relpath(full, root)
        try:
            src = open(full, encoding="utf-8").read()
        except OSError:
            continue
        if "actions/cache" not in src:
            continue
        checked += 1
        # Read as text rather than through yaml: `path:` is a scalar in every
        # shape a cache step takes, and the case that matters most is a
        # multi-line list, which safe_load would flatten into something no error
        # message could quote back at a reader.
        for m in re.finditer(r"^\s*(?:-\s*)?path:\s*(.+)$", src, re.M):
            value = m.group(1).strip().strip("'\"")
            if REPORT.search(value):
                lineno = src[: m.start()].count("\n") + 1
                problems.append(
                    f"{rel}:{lineno}: actions/cache path {value!r} is a test report. "
                    f"restore-keys matches by PREFIX, so a report written by a run "
                    f"that HAD the dependency is restored into a run that did not. "
                    f"Cache build products (target/, GOCACHE, node_modules, "
                    f"vendor/bundle); never a witness"
                )

if problems:
    sys.exit("; ".join(problems))
# The PASS line is written carefully, because the obvious phrasing of it is
# wrong in a way that would mislead the next reader. kit's workflows DO cache —
# `actions/setup-go`, `ruby/setup-ruby` with `bundler-cache`, `setup-node` with
# `cache: npm` and `setup-uv` with `enable-cache` all keep dependency caches —
# and every one of those is a build product. Saying "kit caches nothing" would
# be false; saying what is actually true is the whole point of this check.
print(
    f"{checked} workflow file(s) use actions/cache; none caches a test report. "
    f"Dependency caches (GOCACHE, vendor/bundle, ~/.npm, the uv cache) are build "
    f"products and are not in scope"
    if checked
    else "no actions/cache step in this repo; the rule is for the adopters, and the "
    f"dependency caches kit's own workflows do use (GOCACHE, vendor/bundle, ~/.npm) "
    f"are build products"
)
PY
  }
  check '.github/workflows/*  (no test report is ever cached)' no_cached_report_check

  # -------------------------------------------------------------------------
  # The `secrets` job, asserted as a job rather than as a config file.
  #
  # Three things, and each is a distinct way this job could stop being a gate
  # while every other check in the file stayed green:
  #
  #   1. it could stop existing — a repo with no secret scanning is a repo that
  #      has never been scanned, and nothing else here notices
  #   2. it could become advisory — `continue-on-error` at the job or step level
  #      is the single most common way a security job is neutralised, and it is
  #      invisible in a green build. A secret scanner that only warns is a report
  #   3. it could lose its full history — `fetch-depth` reverting to the
  #      default shallow clone is a one-line diff that turns a history scan into
  #      a HEAD scan, and a HEAD scan cannot see a deleted secret
  secrets_job_check() {
    "$PY" - "$ROOT" "$WORKFLOW" "$GITLEAKS_GATE" <<'PY'
import sys

import yaml

workflow, gate = sys.argv[2], sys.argv[3]
with open(workflow, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
jobs = doc.get("jobs") or {}
problems = []

job = jobs.get("secrets")
if not isinstance(job, dict):
    problems.append(
        "no `secrets` job. Every other job in this file is a test the repo asked "
        "for; this one is the one a repo must not have to ask for, and a "
        "repository with no secret scanning has never been scanned while every "
        "other check here is green"
    )
else:
    # Advisory is the failure mode, so it is checked at both levels. A job-level
    # `continue-on-error: true` makes the whole job non-blocking; a step-level one
    # makes the scan non-blocking and leaves the job green.
    if job.get("continue-on-error") is True:
        problems.append(
            "the `secrets` job sets continue-on-error: true. That is what makes a "
            "secret scanner a report: the build goes green having found nothing, "
            "and a green badge is a claim"
        )

    steps = job.get("steps") or []
    # Full history. `fetch-depth: 0` on the checkout, not merely its absence —
    # an explicit 0 and an absent key look identical to a grep.
    checkout_depths = []
    for step in steps:
        if not isinstance(step, dict):
            continue
        if str(step.get("uses", "")).startswith("actions/checkout@"):
            checkout_depths.append((step.get("with") or {}).get("fetch-depth"))
    if not checkout_depths:
        problems.append("the `secrets` job has no actions/checkout step")
    elif not any(str(d) == "0" for d in checkout_depths):
        problems.append(
            f"the `secrets` job checks out with fetch-depth {checkout_depths}. The "
            f"runner default is a SHALLOW clone — one commit. A shallow scan is a "
            f"diff scan with extra steps, and a diff scan cannot see a secret that "
            f"was committed and deleted, which is the finding that matters most: it "
            f"is on every fork and in the packfile of anyone who cloned. fetch-depth "
            f"must be 0"
        )

    # The scan must be the shared script, so CI and `bash tests/validate.sh` are
    # the same scan. A workflow that inlines its own gitleaks command line is two
    # scanners, and the one that goes red is whichever nobody runs.
    runs = "\n".join(
        str(s.get("run", "")) for s in steps if isinstance(s, dict)
    )
    if gate not in runs:
        problems.append(
            f"the `secrets` job does not run {gate}. kit's gate runs that script and "
            f"this job inlines its own command line instead, which means the scan a "
            f"developer runs and the scan CI runs have already drifted, and the one "
            f"that goes red is whichever nobody runs"
        )

    # Every step must be blocking.
    for i, step in enumerate(steps, 1):
        if isinstance(step, dict) and step.get("continue-on-error") is True:
            problems.append(
                f"the `secrets` job step {i} ({step.get('name', step.get('uses', '?'))}) "
                f"sets continue-on-error: true, which makes the scan advisory"
            )

    # No `if: always()` or `if: failure()` on the scan step: a scan that only
    # runs when something else already failed is a report about the failure.
    for step in steps:
        if not isinstance(step, dict):
            continue
        cond = str(step.get("if", ""))
        if "always()" in cond or "failure()" in cond or "success()" in cond:
            problems.append(
                f"a `secrets` step is conditional on {cond!r}. A secret scan that runs "
                f"only under some conditions is a report about those conditions"
            )

    # And the job must not be opt-in, which is the opposite of every other job
    # in this file and the one deliberate exception.
    cond = str(job.get("if", ""))
    if "inputs." in cond:
        problems.append(
            f"the `secrets` job is gated on {cond!r}. It is the one job in this file "
            f"with no opt-in, deliberately: an opt-in security control is not a "
            f"control, and a secret scanner that only warns is a report"
        )

# The zizmor job is opt-in and must say so with a STRING comparison, for the
# reason every other opt-in input in this file does: GitHub coerces a bare
# `false` to a boolean in some positions, and `if: inputs.zizmor` is a trap.
zjob = jobs.get("zizmor")
if not isinstance(zjob, dict):
    problems.append(
        "no `zizmor` job. The audit reads the adopting repo's OWN workflows, which "
        "kit did not write, so it is opt-in — but a job that has quietly stopped "
        "existing and an input that is quietly never passed are the same silence"
    )
else:
    cond = str(zjob.get("if", ""))
    if "inputs.zizmor" not in cond:
        problems.append(
            f"the `zizmor` job is not gated on its input ({cond!r}), so it would run "
            f"in every adopting repo on day one and turn them red for findings in "
            f"workflows kit did not write"
        )
    elif "'true'" not in cond:
        problems.append(
            f"the `zizmor` job's condition is {cond!r}; it must compare to the STRING "
            f"'true'. A bare boolean coerces unpredictably in some positions, which is "
            f"the exact trap the `telemetry` input exists to avoid"
        )

# Both new inputs must exist and default to 'false', for the same reason
# `telemetry` does — a kit change that breaks every consumer's CI does not ship.
triggers = doc.get("on") or doc.get(True) or {}
call = (triggers.get("workflow_call") or {}).get("inputs") or {}
for name in ("zizmor",):
    declared = call.get(name)
    if not isinstance(declared, dict):
        problems.append(f"no `{name}` workflow_call input")
    else:
        if str(declared.get("default", "")) not in ("false", "False"):
            problems.append(
                f"the `{name}` input defaults to {declared.get('default')!r}; it must "
                f"default to 'false'"
            )
        if str(declared.get("type")) != "string":
            problems.append(f"the `{name}` input must be type: string (booleans coerce badly)")

# `secrets` must NOT be an input at all: it takes no opt-in, and an input named
# `secrets` with a default of false would be a way to turn the secret scanner off
# without anyone noticing the flag.
if "secrets" in call:
    problems.append(
        "the workflow declares a `secrets` input. The secret scanner is the one job "
        "with no opt-in, and an input is an off switch — a `secrets: false` in a "
        "caller would be a way to disable secret scanning that looks like "
        "configuration"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check "$WORKFLOW  (secrets job: not advisory, full history, not opt-in)" \
    secrets_job_check

  # Every README section a reader is told to copy must exist. A doc that points
  # at a path that was renamed is worse than no doc.
  readme_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
readme = open(f"{root}/README.md", encoding="utf-8").read()
problems = []
for path in (
    "templates/compose/docker-compose.yml",
    "templates/compose/otel-collector.yml",
    "templates/compose/.env.example",
    "templates/bin/dev.sh",
    "templates/otel/README.md",
    # Directory paths, and checked with exists() rather than isfile() — these are
    # trees, and asking isfile() about a directory reports a missing doc for a
    # directory that is right there.
    #
    # The grafana tree is one entry, not three. Three entries with a file inside
    # each would make the README carry three near-identical table rows so that a
    # check could be satisfied by pasting the paths in, and the thing a reader
    # needs is the tree, not its leaves.
    "templates/compose/grafana/provisioning",
    "templates/compose/loki",
    "templates/compose/tempo",
    # NOT `templates/compose/mimir`, and that omission is the check. This list
    # is what keeps a directory that is gone from being documented as present;
    # adding the path back to satisfy a stale README is the one edit that would
    # make this whole list worthless.
    "tests/canary_test.sh",
    # The harness's own sharding. The README describes `KIT_SELF_TEST_SHARD=i/n`
    # as a way to split the suite, and the way that description was WRONG is the
    # reason this path is listed rather than left implicit: shard n/n verified
    # nothing and reported green.
    "tests/shard_test.sh",
    "tests/no_telemetry_in_readiness.sh",
    # The two files the staleness templates half is made of. Both are the kind
    # of thing a reader would never know to look for: the reporter is
    # self-explanatory, and the ledger is a list. A reader who does not know
    # they exist concludes the reporter invents its own inventory, which it
    # does not — and that a divergence with no recorded reason is fine, which
    # it is not.
    "tests/artifacts.json",
    "templates/parity-allowlist",
    # The three the fetched-stack packet added. A README that documents the stack
    # without documenting how it is OBTAINED describes a copy, and this packet's
    # whole claim is that the copy is gone.
    "tests/fetch_test.sh",
    "tests/stack_live_test.sh",
    "tests/fleet_check.py",
    # The cluster, its proof, and the connection contract. A README that
    # documents a shared cluster without documenting that the DATABASE is the
    # isolation boundary describes nine databases and says nothing about whether
    # one service can read another's rows — which is the only question that
    # matters about a shared cluster.
    "tests/isolation_test.sh",
    "templates/compose/postgres/Dockerfile",
    "templates/compose/postgres/initdb/10-cluster.sh",
    "templates/database/README.md",
    "templates/database/contract.json",
    # The account-scope contract, which is a check that spans repositories rather
    # than a template a service copies. The four are named together because they
    # are one thing: a README that documents the declaration format without
    # documenting WHO RUNS THE CHECKER describes a convention, and a convention
    # nothing enforces is the finding `DEBT.md` D18 keeps recording one level up
    # from where it has been looking.
    "tests/account_scope_fleet_check.py",
    "tests/account_scope_fleet_ratchet.yml",
    "tests/account_scope_fleet_scope.yml",
    "reports/account-scope-contract-01/snapshot.sh",
):
    if path not in readme:
        problems.append(f"README.md never mentions {path}")
    if not os.path.exists(os.path.join(root, path)):
        problems.append(f"README.md documents {path}, which does not exist")

# The licence condition is the kind of sentence that gets edited away by a
# copy-paste, and it is the one sentence in this file that is a legal statement
# rather than a technical one. Asserted, because "ship them unmodified" only
# helps anybody if the README says it.
for phrase, why in (
    ("AGPL", "the licence of the four backing services must be named"),
    ("unmodified", "the unmodified condition is the whole point of the licence note"),
    ("bring your own", "bring-your-own is a supported deployment, not a degraded mode"),
    ("not a degraded mode", "the phrase itself is the claim being made"),
):
    if phrase.lower() not in readme.lower():
        problems.append(f"README.md does not state {why} (looked for {phrase!r})")

# `kit.ref` IS NAME-ONLY, deliberately, and it is the one entry in the list above
# that cannot also be an existence check. kit is the repository being pinned, so
# it has no `kit.ref` of its own — requiring one would make this repository fail a
# check about the repositories that consume it, which is the confusion the whole
# split between "kit's own artifacts" and "the fleet" exists to prevent.
#
# It is read by two programs — `bin/dev` at run time and `tests/fleet_check.py`
# at gate time — so a README that lists it in a table of files without saying what
# it is has documented a file, not a contract.
if not re.search(r"`?kit\.ref`?", readme):
    problems.append(
        "README.md never names kit.ref, so a reader cannot find where the pin "
        "lives — and the pin is the one thing in this packet that decides which "
        "bytes of kit a developer's machine runs."
    )
if not re.search(r"(?i)pin", readme):
    problems.append(
        "README.md never uses the word `pin`, so kit.ref reads as a filename "
        "rather than as the thing it is. A reader who does not know it is a pin "
        "will edit it to `master`."
    )

# The escape hatch, and the ports. A self-hoster reads the README and not the
# code, so the variable name has to be in the README and so does the block.
#
# The pattern requires a real service-shaped prefix before `_OTEL_ENDPOINT`.
# `_OTEL_ENDPOINT` on its own is the shape of a variable that has not been
# derived from anything, and the whole point of core's D16 is that the name
# comes from the service name so it is knowable without reading code.
if not re.search(r"`?[A-Z][A-Z0-9]*_OTEL_ENDPOINT`?", readme):
    problems.append(
        "README.md never names the <SERVICE>_OTEL_ENDPOINT contract. A reader who "
        "has to grep the source to learn the variable name is a reader who never "
        "sets it, and a self-hoster who never sets it runs with the shipped stack "
        "by accident."
    )
if "15000" not in readme or "15999" not in readme:
    problems.append("README.md does not state the host port range the stack claims")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'README.md  (documents every new template)' readme_check

  # THE CLOSURE HALF, and the direction the list above cannot see.
  #
  # WHAT `readme_check` GUARDS, restated because it is a one-sided list and the
  # half it does not guard is the half a packet moves in. It walks a
  # hand-maintained tuple and asserts, per entry, that the README names it AND
  # that it exists. So a documented path that was then deleted is a finding. A
  # path that was ADDED and never documented is not — `templates/deploy/` shipped
  # a 1,067-line distribution for a packet and appears nowhere in the README,
  # and `.github/workflows/image.reusable.yml` is kit's second reusable standard
  # and appears nowhere either. The list's own comment is honest about this ("that
  # omission is the check"), and honest about only that half.
  #
  # WHY IT IS A COMPANION AND NOT AN EXTENSION OF THE TUPLE. The tuple's failure
  # mode is that it is hand-maintained, so "add one entry per new file" is the
  # same ratchet the skip allowlist has, in the opposite direction: it only ever
  # grows, and it grows by one line per artefact a fleet of nine services reads
  # once. This check instead READS its coverage out of the README and asks
  # whether the tree is closed under it, which means a packet that adds
  # `templates/payments/gateway.yml` is caught on the day it does, with no edit
  # to `validate.sh` at all.
  #
  # THE BOUND, and it is the whole argument. Requiring a row per shipped file is
  # the failure this check exists to avoid: measured on this tree, 145 of the 175
  # tracked files under `reports/`, `tests/` and `templates/` are not on the
  # tuple, and a README listing 157 paths is a README nobody reads. So coverage
  # is per TREE, not per file, and the trees are chosen by what the README is for:
  #
  #   IN:  .github/ core/ docker/ lint/ templates/ — the adoption trees. A file
  #        here is something a service copies or a caller reaches by `uses:`, and
  #        a reader who has never heard of it cannot adopt it.
  #   OUT: tests/ — kit's own gate implementation. The README names every proof
  #        a reader is expected to RUN (isolation, tenancy, canary, kamal, fetch,
  #        live stack) and `tests/validate.sh` itself; `fingerprint.py` and
  #        `bootstrap.sh` are how the gate runs, not what kit ships. Naming them
  #        would add 17 rows and teach the reader nothing.
  #   OUT: reports/ — packet evidence. `AGENTS.md` forbids committing a REPORTED
  #        measurement; what is committed here is a packet's own mutation record,
  #        which is addressed to whoever reads that packet's report, not to a
  #        reader deciding whether to adopt kit. 32 files, zero rows.
  #
  # THE CHEAP TRUE CASE IS GREEN AND THAT IS THE POINT. The file this check was
  # written against — a new file inside `templates/compose/grafana/provisioning/`,
  # a directory the README already names — is COVERED, because the README's row
  # for that tree describes its contents in prose ("Datasources, the dashboard
  # provider, the fleet error dashboard and the alert rules"). A check that went
  # red on it would be demanding a row for a fifth datasource, which is the
  # 157-paths failure wearing a smaller hat. So the direction that goes red is
  # the one a packet actually produces: a whole new tree nobody named.
  #
  # WEAKNESS, STATED BECAUSE IT IS THE SAME ONE `readme_check` HAS. Coverage is a
  # substring over README prose, so a path named only in a passing sentence or a
  # code fence satisfies it. Tightening that means requiring a table row, which
  # is a different check with a different failure mode; the honest description is
  # that this asserts the tree is CLOSED, not that the prose is good.
  readme_closure_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
readme = open(f"{root}/README.md", encoding="utf-8").read()

# Every path-shaped run of text in the README, anywhere — not only the
# backticked ones, because three of the paths the existing tuple requires
# (`tests/account_scope_fleet_check.py`, `reports/.../snapshot.sh`) are written
# in prose and a backtick-only reader would call all three undocumented and be
# wrong three times.
TOKEN = re.compile(r"[A-Za-z0-9._<>-]+(?:/[A-Za-z0-9._<>{},*-]+)+")


def expand(token):
    """`{tempo,loki}/` names two paths. JSON-Schema-style set notation is the
    only expansion the README uses, and it is expanded rather than treated as a
    literal because `templates/compose/{tempo,loki}/` is a row about two
    directories and reading it as one directory named `{tempo,loki}` would
    report both of them undocumented."""
    m = re.search(r"\{([^{}]*,[^{}]*)\}", token)
    if not m:
        return [token]
    out = []
    for part in m.group(1).split(","):
        out.extend(expand(token[: m.start()] + part + token[m.end() :]))
    return out


def as_pattern(token):
    """A segment carrying `<…>` or `*` is a wildcard, because
    `docker/Dockerfile.<lang>` and `templates/database/<lang>/` are how the
    README names all seven Dockerfiles and all six connection configs. Treating
    the angle brackets as literal characters measured as 13 false findings on an
    unbroken tree, which is the fail-loud direction being pointed the wrong way."""
    return re.compile(
        "^"
        + "/".join(
            "[^/]+" if ("<" in seg or "*" in seg) else re.escape(seg)
            for seg in token.split("/")
        )
        + "$"
    )


patterns = []
for m in TOKEN.finditer(readme):
    for token in expand(m.group(0).rstrip("/.,;:")):
        token = token.strip().rstrip("/.,;:")
        # A path inside another repository, or an absolute one, says nothing
        # about what THIS tree ships, and `<kit>/docker/Dockerfile.go` is a path
        # in kit as seen from a service — which does cover the real file, so the
        # leading `<kit>/` is dropped rather than the token discarded.
        if ".." in token or token.startswith(("http", "$", "/")):
            continue
        if token.startswith("<kit>/"):
            token = token[len("<kit>/") :]
        # ONE SEGMENT IS NOT A TREE, and admitting one is the fail-open direction
        # this check exists to close. `## The templates half — templates/` is how
        # the README introduces the section, so a one-segment token `templates`
        # prefix-matches `templates/deploy/README.md` and the entire adoption
        # tree is reported documented by a heading. Measured: with one-segment
        # tokens admitted, the walk found ONE undocumented path where there are
        # SEVEN — a green that hid six real gaps, and it hid them for the same
        # reason a check whose pattern stopped matching does. Coverage is asserted
        # per tree, and a tree is named by its path from the root.
        if len(token.split("/")) < 2:
            continue
        patterns.append((token, as_pattern(token)))


def documented(rel):
    segs = rel.split("/")
    # Longest prefix first: `templates/compose/grafana/provisioning` must be
    # tried before `templates/compose`, and a file is covered by a token that
    # names it OR any ancestor directory of it.
    for n in range(len(segs), 0, -1):
        head = "/".join(segs[:n])
        for token, pattern in patterns:
            if pattern.match(head):
                return token
    return None


# The adoption trees, and why tests/ and reports/ are not among them. See the
# comment above the function; this is the same list in a form the walk can read.
ADOPTION_TREES = (".github", "core", "docker", "lint", "templates")

# A walk, not `git ls-files`, and the reason is the harness rather than taste:
# `tests/self_test.sh` makes a throwaway copy with no `.git` beside it, so a
# check that shelled out to git would find zero files in every copy and pass
# while proving nothing — the same false green `fresh_copy`'s comment describes.
# Scratch that is not shipped is skipped by name instead.
SKIP_DIRS = {"__pycache__", "node_modules"}

undocumented = []
walked = 0
for tree in ADOPTION_TREES:
    top = os.path.join(root, tree)
    for dirpath, dirnames, filenames in os.walk(top):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
        for name in filenames:
            if name.startswith(".") and name not in (".env.example",):
                continue
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            walked += 1
            if documented(rel) is None:
                undocumented.append(rel)

if undocumented:
    sys.exit(
        f"{len(undocumented)} shipped path(s) in an adoption tree are named "
        f"nowhere in README.md: " + ", ".join(sorted(undocumented)) + ". Add the "
        "TREE to the README's file table — the tree, not its leaves: this check "
        "is closed under a documented directory, so listing the directory once "
        "covers everything inside it, and listing every file would be the "
        "157-paths README this check exists to prevent."
    )

# The count is printed on PASS, and it is a measurement rather than a constant:
# a check that asserts "everything is covered" and reports nothing on success is
# indistinguishable from a check whose pattern stopped matching, which is worse
# than no check at all.
print(f"{walked} path(s) walked across {len(ADOPTION_TREES)} adoption trees; every one is documented")
PY
  }
  check 'README.md  (every shipped path in an adoption tree is documented)' \
    readme_closure_check

  # kit's own licence, and the one property about it that can rot.
  #
  # WHY THIS EXISTS. kit carried no `LICENSE` at all while the rest of the fleet
  # was being given one, and the state that produces is not "unlicensed" — it is
  # "all rights reserved", because that is the default copyright position when a
  # public repository grants nothing. cafaye's decision is MIT everywhere, and a
  # decision that is written down on a website and absent from the repository is
  # a decision a buyer's own legal review cannot see.
  #
  # The interesting half is not the file. It is that a licence is only
  # unambiguous when there is exactly ONE place in a repository that can declare
  # one, and that place is easy to lose: a `package.json` appears, it carries
  # `"license": "AGPL-3.0-only"` copied out of a service, and now the repository
  # says MIT in one file and AGPL in another. Both are true statements about
  # different fields, and the reader has no way to tell which one a licence
  # compliance tool reads.
  #
  # So this asserts the AGREEMENT, not the presence of a file:
  #
  #   1. `LICENSE` exists and grants MIT, recognised by the grant's own words
  #      rather than by the string "MIT" — a file saying "MIT" and granting
  #      something else passes every check that looks for the word, and this is
  #      the check that looks for the words.
  #   2. it names a copyright holder, because MIT's attribution obligation is
  #      that notice travelling with the software, and a grant with no holder is
  #      a grant nobody can attribute.
  #   3. README says MIT and links the file. A grant nobody reads is not
  #      published, and the two licence questions in kit's README are separate
  #      on purpose (MIT for kit, AGPL-3.0 for the four backends it ships
  #      unmodified) — so the check asserts against kit's OWN paragraph and
  #      leaves the AGPL one alone, since conflating the two is the mistake the
  #      README's structure exists to prevent.
  #   4. every root manifest that CAN carry a licence field declares MIT.
  #
  # Point 4 is deliberately a check for AGREEMENT and not a ban on the file. The
  # same reasoning as breakage 31b: a check satisfied by "kit has no
  # package.json" would train the next contributor to delete a manifest rather
  # than to fix its licence field, and would be a FAIL the day kit legitimately
  # grew one. Today it finds zero manifests and prints that count, because "0
  # manifests, none of which can disagree" is a measurement and silence is not.
  license_check() {
    "$PY" - "$ROOT" <<'PY'
import glob
import os
import re
import sys

root = sys.argv[1]
problems = []

# (1) and (2): the grant itself.
path = os.path.join(root, "LICENSE")
if not os.path.isfile(path):
    problems.append(
        "LICENSE does not exist. cafaye's decision is MIT across the fleet, and a "
        "repository with no grant is not permissive — it is all rights reserved, "
        "which is the default copyright position when nothing is granted. The "
        "grant is one file and it is the whole grant"
    )
else:
    text = open(path, encoding="utf-8").read()
    # The grant's own sentences, not the identifier. `MIT` as a bare string is
    # also how a summary, a badge line, or a note about some OTHER repository's
    # licence is spelled, and matching it would pass on all three.
    for phrase, why in (
        (
            "Permission is hereby granted, free of charge",
            "the permission grant is MIT's first sentence and the thing being granted",
        ),
        (
            'THE SOFTWARE IS PROVIDED "AS IS"',
            "MIT's warranty disclaimer. Its ABSENCE is how you tell a copied "
            "identifier from a real grant, and a grant without it is a different "
            "licence",
        ),
    ):
        if phrase not in text:
            problems.append(
                f"LICENSE does not contain {phrase!r} — {why}. If kit is not MIT, "
                f"say so in README.md instead of leaving the two files to disagree"
            )
    if not re.search(r"^Copyright \(c\) \d{4} \S.*$", text, re.M):
        problems.append(
            "LICENSE names no copyright holder. MIT's attribution obligation is "
            "that notice travelling with the software, and a grant with no holder "
            "is a grant nobody can attribute"
        )

# (3): the README, against kit's OWN paragraph.
readme = open(os.path.join(root, "README.md"), encoding="utf-8").read()
# The `## License` section, not the whole file: the AGPL paragraph above names a
# licence that is NOT kit's, and a substring search over the document is
# satisfied by that one — which is the exact conflation the section split exists
# to prevent.
section = re.split(r"^## ", readme, flags=re.M)
own = next((s for s in section if s.startswith("License")), "")
if not own:
    problems.append(
        "README.md has no `## License` section. A grant nobody reads is not "
        "published, and this is the section a reader is looking for"
    )
else:
    if not re.search(r"\bMIT\b", own):
        problems.append("README.md's License section does not state MIT")
    if not re.search(r"\]\(LICENSE\)", own):
        problems.append(
            "README.md's License section does not link to the LICENSE file, so a "
            "reader has to go looking for it"
        )
# The separation itself, which is a claim rather than a file.
if not re.search(r"AGPL", own):
    problems.append(
        "README.md's License section does not name AGPL anywhere. kit shipping "
        "AGPL-3.0 backends unmodified and kit itself being MIT are two different "
        "questions, and the section that answers the second has to say why the "
        "first does not change the answer"
    )

# (4): anything in the tree root that can carry a licence field.
# Deliberately ROOT-ONLY and deliberately not a ban. `templates/` holds
# manifests for other people — `go.mod` files, a service's package.json — and a
# licence declared in a template is that template's business. What cannot be
# allowed is a licence declared about KIT, and only the root can be about kit.
FIELDS = {
    "package.json": r'"license"\s*:\s*"([^"]*)"',
    "Cargo.toml": r'^\s*license\s*=\s*"([^"]*)"',
    "pyproject.toml": r'^\s*license\s*=\s*(?:\{[^}]*text\s*=\s*)?"([^"]*)"',
    "composer.json": r'"license"\s*:\s*"([^"]*)"',
    "setup.cfg": r"^license\s*=\s*(\S+)",
    "bower.json": r'"license"\s*:\s*"([^"]*)"',
}
found = 0
for name, pattern in FIELDS.items():
    for full in sorted(glob.glob(os.path.join(root, name))):
        found += 1
        body = open(full, encoding="utf-8").read()
        m = re.search(pattern, body, re.M)
        if not m:
            # No field is not a disagreement: the LICENSE file still governs, and
            # the check above already asserted it says MIT.
            continue
        declared = m.group(1)
        if "MIT" not in declared:
            problems.append(
                f"{name} declares license {declared!r} while LICENSE grants MIT. A "
                f"licence compliance tool reads the manifest, a reader reads the "
                f"file, and the repository now says two different things about the "
                f"same grant"
            )
for full in sorted(glob.glob(os.path.join(root, "*.gemspec"))):
    found += 1
    m = re.search(r"\.license\s*=\s*[\"']([^\"']+)[\"']", open(full, encoding="utf-8").read())
    if m and "MIT" not in m.group(1):
        problems.append(
            f"{os.path.basename(full)} declares license {m.group(1)!r} while LICENSE "
            f"grants MIT — same disagreement, same reason"
        )

if problems:
    sys.exit("; ".join(problems))

# Printed on PASS, because "no manifest could disagree" and "nobody looked" are
# the same output otherwise.
print(
    "LICENSE grants MIT and names cafaye; README states it and links the file; "
    f"{found} root manifest(s) inspected, none declaring a licence other than MIT "
    f"(kit has {'none' if found == 0 else str(found)}, so the file is the only "
    "place a grant can be declared)"
)
PY
  }
  check 'LICENSE  (MIT, and nothing in the tree can disagree with it)' license_check

  # ---------------------------------------------------------------------------
  # THE VERSION STRING IS THE PROMISE, AND IT IS DERIVED
  # ---------------------------------------------------------------------------
  #
  # kit is adopted by COPY and by `uses:` at a ref, so "is 2.4.0 safe to take?"
  # is the only question a consumer has, and until this check it was answered by
  # a person reading a diff. kit also had no version at all: the changelog said
  # so in its own first paragraph ("kit has no releases yet and no semver
  # contract"), which is an honest sentence and an unusable one — the tier was
  # documentation, so nothing could fail when the documentation was wrong.
  #
  # `VERSION` is one line and it is the ONLY place the version is written. Three
  # tiers, derived from the two versions and never asserted anywhere:
  #
  #   breaking   MAJOR moved. A consumer must read what changed, and must be
  #              given a MIGRATION, because "read the diff" is the thing this
  #              whole mechanism exists to stop asking of people.
  #   additive   MINOR moved. Something was added; nothing a consumer holds was
  #              taken away.
  #   invisible  PATCH moved. A consumer may take it without reading anything,
  #              which is what "invisible" has to mean for it to be worth
  #              deriving.
  #
  # WHY THESE THREE, AND NOT FOUR, AND NOT A BOOLEAN
  #
  # The rule of thumb is that the number you do NOT have to read is the size of
  # the promise, so the tiers have to be the three sizes of change there are.
  # A fourth tier would be a claim about something this repository cannot
  # observe — the difference between "invisible" and "safe" is a difference
  # about the CONSUMER's code, which kit does not have. And a boolean
  # (`breaking: true|false`) is what cafaye has today and it is what the
  # research calls the weakest form of this: it answers "did anything break?"
  # with one bit, so it cannot say WHICH surface broke, so a consumer reading it
  # still has to open the diff. The tier is derived from the number the consumer
  # already has, which is the property that makes it checkable at all.
  #
  # WHY A VERSION STRING THIS CHECK REFUSES
  #
  # `2.4.0-rc1` and `v2.4.0` are BOTH refused rather than guessed at, and both
  # refusals are deliberate:
  #   * a prerelease suffix is exactly where "what tier is this" stops having an
  #     answer — semver puts `2.4.0-rc1` BELOW `2.4.0`, which means the derived
  #     tier would change meaning when the suffix is dropped, so the string stops
  #     being the source of truth for its own promise. kit has no prerelease
  #     story and a refused version string is the honest answer to "which tier is
  #     rc1 in", where guessing is the expensive one.
  #   * `v` is the TAG spelling, not the version spelling. `kit.ref` accepts
  #     `v<semver>` because that is a git tag, and this file is not a git tag.
  #     A `v` here means somebody pasted the tag where the version goes, which
  #     is precisely the hand-written-number drift this replaces.
  #
  # Both surface as `unknown`, and `unknown` is a FAILURE. A string the
  # function cannot place must not be given a tier, because a tier that is a
  # guess is the fail-open direction and this repository's rule is to fail
  # closed.
  #
  # WHY THE DERIVATION IS A FUNCTION AND NOT PROSE
  #
  # A table in this comment is a table somebody can read and nobody has to
  # agree with. `stability_tier` is asserted against a published table by the
  # check below it, so a change to the rule that is not a change to the table is
  # a red gate — and that is the whole difference between a standard and a
  # convention.
  stability_tier() {
    stability_parse "$1" || { printf 'unknown\n'; return 0; }
    local _fm=$STAB_MAJOR _fm2=$STAB_MINOR _fp=$STAB_PATCH
    stability_parse "$2" || { printf 'unknown\n'; return 0; }
    if [ "$STAB_MAJOR" -lt "$_fm" ] ||
      { [ "$STAB_MAJOR" -eq "$_fm" ] && [ "$STAB_MINOR" -lt "$_fm2" ]; } ||
      {
        [ "$STAB_MAJOR" -eq "$_fm" ] && [ "$STAB_MINOR" -eq "$_fm2" ] &&
          [ "$STAB_PATCH" -lt "$_fp" ]
      }; then
      # A version that went backwards. Not a fourth tier: nothing about a
      # consumer's risk changes, which is precisely why it is named separately
      # and refused rather than folded into one of the three.
      printf 'retracted\n'
    elif [ "$STAB_MAJOR" -gt "$_fm" ]; then
      printf 'breaking\n'
    elif [ "$STAB_MINOR" -gt "$_fm2" ]; then
      printf 'additive\n'
    elif [ "$STAB_PATCH" -gt "$_fp" ]; then
      printf 'invisible\n'
    else
      printf 'none\n'
    fi
  }

  # stability_parse <string> — three whole-number components, and nothing else.
  # Sets STAB_MAJOR/MINOR/PATCH on success. `10#` because `08` is a syntax error
  # in arithmetic and a version is not a place where a leading zero is worth an
  # octal surprise.
  stability_parse() {
    local s="${1:-}" a b c
    unset STAB_MAJOR STAB_MINOR STAB_PATCH
    case "$s" in
      *[!0-9.]* | '') return 1 ;;
    esac
    IFS=. read -r a b c <<<"$s"
    case "$a$b$c" in
      '' | *[!0-9]*) return 1 ;;
    esac
    [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] || return 1
    # A leading zero is refused rather than read as a number. `01.4.0` and
    # `1.4.0` are the same version to a comparator and two different strings to
    # a consumer, so a string that means two things is not a source of truth.
    # Per COMPONENT, not on the concatenation: `1.0.0` joined reads `1000` and a
    # pattern over that matches a version that has no leading zero at all.
    local comp
    for comp in "$a" "$b" "$c"; do
      if [ "${#comp}" -gt 1 ]; then
        case "$comp" in
          0[0-9]*) return 1 ;;
        esac
      fi
    done
    STAB_MAJOR=$((10#$a))
    STAB_MINOR=$((10#$b))
    STAB_PATCH=$((10#$c))
    return 0
  }

  # The published table. A row is (from, to, expected, why the row is here).
  # Every row is a case the function gets WRONG for a different reason if the
  # derivation is loosened, which is what makes it a table rather than three
  # examples.
  stability_tier_table_check() {
    local problems=0 rows
    rows='1.0.0 2.0.0 breaking  a MAJOR moved: read this one
1.0.0 1.4.0 additive  something arrived, nothing a consumer holds left
1.0.0 1.0.1 invisible  take it without reading anything
1.0.0 1.0.0 none      no bump at all: nothing is promised because nothing moved
2.0.0 1.9.0 retracted a version went backwards, which is refused rather than tiered
1.0.0 2.0.0-rc1 unknown a prerelease suffix changes the meaning of the number
1.0.0 v1.4.0 unknown a tag is not a version string
1.0.0 1.4 unknown two components is not a version
1.0.0 "" unknown no version is not a tier
1.0.0 01.4.0 unknown a leading zero is arithmetic here and prose there'
    local row from to want why got
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      # shellcheck disable=SC2086 # four fields, read into four names
      set -- $row
      from="$1"
      to="$2"
      want="$3"
      why="$4"
      got="$(stability_tier "$from" "$to")"
      if [ "$got" != "$want" ]; then
        printf '  %s -> %s derived %s, the published table says %s. %s\n' \
          "$from" "$to" "$got" "$want" "$why" >&2
        problems=$((problems + 1))
      fi
    done <<<"$rows"
    if [ "$problems" -ne 0 ]; then
      return 1
    fi
    printf '10 version pairs derive the tier they are published with; VERSION parses as %s\n' \
      "$(head -1 "$ROOT/VERSION" 2>/dev/null || printf 'ABSENT')"
  }
  check 'stability tiers  (derived from two version strings, never asserted)' stability_tier_table_check

  # The GATE. What the tier requires is not a paragraph, it is a set of files
  # this check reads, so a tier crossing without its discharge is a red build.
  stability_gate_check() {
    local version from tier problems=0
    if [ ! -f "$ROOT/VERSION" ]; then
      printf 'VERSION does not exist. kit is adopted by copy, so the version string is the only thing a consumer has to go on, and a repository without one answers nothing.\n' >&2
      return 1
    fi
    # One line, one version. A file with a trailing comment or a second version
    # is two sources of truth, which is the failure this file exists to remove.
    # Counted as non-blank LINES rather than bytes, because a file with no
    # trailing newline is still one line and that is a text-file convention
    # rather than a second version.
    if [ "$(grep -c '[^[:space:]]' "$ROOT/VERSION")" != "1" ]; then
      printf 'VERSION is not exactly one line. One line, one number: a second version or a comment in this file is a second place the promise can be written.\n' >&2
      problems=$((problems + 1))
    fi
    if ! version="$(head -1 "$ROOT/VERSION")"; then
      version=''
    fi
    if ! stability_parse "$version"; then
      printf 'VERSION reads %s, which is not MAJOR.MINOR.PATCH. kit has no prerelease spelling and no leading-v spelling; a version this check cannot place cannot carry a promise it could not derive.\n' "${version:-<empty>}" >&2
      return 1
    fi

    # WHERE THE PREVIOUS VERSION COMES FROM, AND WHY IT IS NOT GIT
    #
    # The first version of this read the predecessor out of git — `git show
    # HEAD:VERSION`, the version consumers have versus the working tree's. It is
    # the intuitive answer and it is the wrong one, measured rather than
    # argued: it resolves to NOTHING in a throwaway copy with no repository, so
    # every version bump in a release rehearsal or an unpacked tarball derived
    # `initial`, and both MAJOR and MINOR breakages stayed GREEN. A gate whose
    # verdict depends on having a `.git` beside it is a gate that verifies
    # nothing on the machines that consume kit the same way services do.
    #
    # So the predecessor is read from the TREE: the highest version section in
    # CHANGELOG.md below the one naming VERSION. That is better than a fallback
    # rather than only more robust — it is the version a consumer can actually
    # see, which is the same fact the promise is about, so the two cannot
    # disagree without the check (2) below going red.
    from="${KIT_STABILITY_FROM:-}"
    if [ -z "$from" ]; then
      local seen_current=0
      while IFS= read -r v; do
        if [ "$v" = "$version" ]; then
          seen_current=1
          continue
        fi
        if [ "$seen_current" -eq 1 ] && [ -z "$from" ]; then
          from="$v"
        fi
      done < <(grep '^## ' "$ROOT/CHANGELOG.md" | sed 's/^## //' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true)
    fi
    if [ -z "$from" ]; then
      # The first version under the contract. Nothing is compatible with
      # nothing, so there is no tier to derive — and the checks below are the
      # whole requirement, which is why they do not depend on this branch.
      tier=initial
    else
      tier="$(stability_tier "$from" "$version")"
    fi
    case "$tier" in
      breaking | additive | invisible | none | initial) ;;
      *)
        printf 'the bump from %s to %s derives the tier %s, which is not a promise a consumer can be given. A version this check cannot tier is a red build, not a guess.\n' \
          "${from:-<none>}" "$version" "$tier" >&2
        return 1
        ;;
    esac

    # (1) The version has to be RECORDED, at every tier including invisible.
    #     "Invisible" is a promise about the consumer's time, and it is kept by
    #     the entry existing; a patch bump nobody wrote down is a patch bump
    #     nobody can have checked.
    if ! grep -qxF "## $version" "$ROOT/CHANGELOG.md"; then
      printf 'CHANGELOG.md has no "## %s" section. A version bump has to say what it did, and this is the record a consumer reads instead of a diff.\n' "$version" >&2
      problems=$((problems + 1))
    fi

    # (2) The version sections must be in descending order and the top one must
    #     BE the version. Without this the file is a list in whatever order the
    #     history produced, and "which version am I reading" is a question with
    #     no answer. Read with a process substitution rather than a pipe because
    #     a pipe would run this in a subshell and throw away every finding — and
    #     `mapfile` is not in the bash 3.2 this repository is read with.
    local prev='' v first='' bad_order=0
    while IFS= read -r v; do
      if [ -z "$first" ]; then
        first="$v"
      elif [ "$v" = "$version" ]; then
        printf 'CHANGELOG.md lists %s below %s. The sections are read newest-first, and a version that is not on top is a version nobody reads first.\n' "$v" "$prev" >&2
        bad_order=1
      fi
      if [ -n "$prev" ]; then
        if stability_parse "$prev" && stability_parse "$v"; then
          if [ "$(stability_tier "$v" "$prev")" = none ] ||
            [ "$(stability_tier "$v" "$prev")" = retracted ]; then
            printf 'CHANGELOG.md lists %s above %s, so the sections are not in descending order.\n' "$prev" "$v" >&2
            bad_order=1
          fi
        fi
      fi
      prev="$v"
    done < <(grep '^## ' "$ROOT/CHANGELOG.md" | sed 's/^## //' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true)
    if [ "$bad_order" -ne 0 ]; then
      problems=$((problems + 1))
    fi
    if [ "$first" != "$version" ]; then
      printf 'the newest version section in CHANGELOG.md is %s and VERSION is %s. Those are the same fact written twice, and they disagree.\n' "${first:-<none>}" "$version" >&2
      problems=$((problems + 1))
    fi

    # (3) THE TIER'S OWN REQUIREMENT.
    #
    #     breaking needs a MIGRATION, not a changelog line. A consumer who
    #     adopted kit by copy cannot apply a sentence; the migration is the only
    #     artefact that can tell them what to change, so it is the thing the
    #     tier owes them and the thing that is checked for.
    if [ "$tier" = breaking ]; then
      if ! awk -v want="$version" '
        $0 == "## " want { inside = 1; next }
        /^## / { inside = 0 }
        inside && /^### Breaking/ { found = 1 }
        END { exit(found ? 0 : 1) }' "$ROOT/CHANGELOG.md"; then
        printf 'the bump to %s is a MAJOR, which derives the tier `breaking`, and its section names nothing that breaks. A breaking release whose breaking part is unwritten is a release whose promise is unchecked.\n' "$version" >&2
        problems=$((problems + 1))
      fi
      if [ ! -f "$ROOT/MIGRATIONS.md" ] ||
        ! grep -qxF "## $version" "$ROOT/MIGRATIONS.md" 2>/dev/null; then
        printf 'the bump to %s is a MAJOR, so it owes a consumer a MIGRATION, and MIGRATIONS.md has no "## %s" section. Read the diff is what this version number is supposed to replace.\n' "$version" "$version" >&2
        problems=$((problems + 1))
      fi
    fi
    # additive owes the consumer its promise too: a MINOR says nothing was taken
    # away, and that is a claim about the section as much as about the tree.
    if [ "$tier" = additive ]; then
      if awk -v want="$version" '
        $0 == "## " want { inside = 1; next }
        /^## / { inside = 0 }
        inside && /^### Breaking/ { found = 1 }
        END { exit(found ? 0 : 1) }' "$ROOT/CHANGELOG.md"; then
        printf 'the bump to %s is a MINOR, which derives the tier `additive`, and its section declares a breaking change. A breaking change is a MAJOR bump; if it is really additive, the heading is a lie.\n' "$version" >&2
        problems=$((problems + 1))
      fi
    fi

    # (4) THE RULE THAT NEEDS NO PREDECESSOR, and it is the load-bearing one.
    #
    #     Every `### Breaking` heading in the file must sit under a version
    #     whose MAJOR is greater than the MAJOR of the section above it, and
    #     never under `## Unreleased`. So the promise holds for the WHOLE
    #     history, not only for the bump being released now: a breaking entry
    #     filed under a MINOR — or parked in Unreleased where it is covered by
    #     no version at all — is a red build even when the current VERSION is
    #     untouched. This is the rule that makes the promise checkable rather
    #     than documented, and it is why the check does not only ask about the
    #     version in VERSION.
    local cur='' below='' bad=0
    while IFS= read -r line; do
      case "$line" in
        '## '*) cur="${line#\#\# }" ;;
        '### Breaking'*)
          if [ "$cur" = Unreleased ]; then
            printf 'CHANGELOG.md declares a breaking change under `## Unreleased`, which is covered by no version at all. Until the release that carries it is a MAJOR, it is a breaking change with no version attached to it.\n' >&2
            bad=1
          elif ! stability_parse "$cur"; then
            printf 'CHANGELOG.md declares a breaking change under the heading "## %s", which is not a version, so no bump can be checked against it.\n' "$cur" >&2
            bad=1
          else
            # THE PREDECESSOR IS THE SECTION BELOW, and this line used to read
            # ABOVE. Measured, both halves, because the fix is the opposite
            # direction and a wrong neighbour is a check that reports the wrong
            # thing confidently.
            #
            # "A breaking change moves MAJOR" is a claim about the bump that
            # PRODUCED the version, so the version it has to be compared with is
            # the one it was released against — and the changelog is
            # newest-first, so that is the section BELOW. The section above a
            # version is whatever was released AFTER it, which says nothing at
            # all about whether the version was allowed to break anything.
            #
            # Two measured consequences of reading the wrong neighbour, both on
            # this repository and neither hypothetical:
            #
            #   (a) IT WAS DEAD. The only `### Breaking` on this tree is under
            #       `## 2.0.0`, and the section above that is `## Unreleased` —
            #       which `stability_parse` refuses, so the comparison never ran
            #       and the clause this file calls "the load-bearing one" never
            #       executed even once.
            #
            #   (b) IT FIRED FALSELY ON A CORRECT TREE. Rename `## Unreleased`
            #       to `## 2.1.0` and set VERSION to 2.1.0 — an ordinary
            #       additive release that breaks nothing — and the gate went
            #       red: "CHANGELOG.md declares a breaking change under 2.0.0,
            #       and the section above it is 2.1.0". 2.0.0's `### Breaking`
            #       is legal, because 2.0.0 was released against 1.0.0 and its
            #       MAJOR moved. The check was punishing a section for a release
            #       written after it.
            #
            # And `-B1` on the FIRST entry of a list returns that entry itself,
            # so the newest section was compared against its own MAJOR and the
            # test `MAJOR <= MAJOR` was true by construction. It fired on
            # breakage 96's own mutation, reporting 4.0.0 against 4.0.0.
            #
            # So: `sed -n 2p` over `grep -A1`, which is the section below, and
            # EMPTY when the section is the oldest — nothing is compatible with
            # nothing, so there is no bump to check and no clause to run. The
            # list is filtered to version sections first, so a heading that is
            # not a version can never become a predecessor.
            below="$(grep '^## ' "$ROOT/CHANGELOG.md" | sed 's/^## //' |
              grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' |
              grep -A1 -xF "$cur" | sed -n '2p' || true)"
            # `STAB_MAJOR` IS CAPTURED BEFORE `stability_parse "$below"`, and that
            # ordering is the whole of the second defect here. `stability_parse`
            # does not return a value — it leaves the numbers in globals and
            # UNSETS them first — so parsing the predecessor OVERWRITES
            # STAB_MAJOR with the PREDECESSOR's MAJOR. The comparison then reads
            # `[ predecessor_major -le predecessor_major ]`, which is true by
            # construction, so the clause reported a violation every time it
            # executed and could never report anything else.
            #
            # It never executed on this tree, which is the only reason a vacuous
            # clause survived: the neighbour it compared against was
            # `## Unreleased`, and `stability_parse` refuses that, so the `&&`
            # short-circuited before the test. The clause was DEAD and VACUOUS at
            # the same time, and each defect hid the other. Fixing only the
            # neighbour would have turned a dead clause into a permanently-firing
            # one, which is the more dangerous of the two and is exactly what my
            # first attempt at this fix did: with `below` resolved correctly, this
            # repository's own LEGAL `### Breaking` under `## 2.0.0` went red.
            local cur_major=$STAB_MAJOR
            if [ -n "$below" ] && stability_parse "$below"; then
              local pm=$((10#${below%%.*}))
              if [ "$cur_major" -le "$pm" ]; then
                printf 'CHANGELOG.md declares a breaking change under %s, which was released against %s. A breaking change that does not move MAJOR is not a versioned promise; that is the entire rule this file enforces.\n' "$cur" "$below" >&2
                bad=1
              fi
            fi
          fi
          ;;
      esac
    done <"$ROOT/CHANGELOG.md"
    if [ "$bad" -ne 0 ]; then
      problems=$((problems + 1))
    fi

    if [ "$problems" -ne 0 ]; then
      return 1
    fi
    # The summary names what the derived tier OWED and that it is there, so the
    # PASS row is a measurement rather than the word "fine". A plain case into a
    # variable rather than a `$( )` wrapping a multi-line case: the command
    # substitution does not survive the newlines, and it printed a shell syntax
    # error into a PASS row on the first run of it.
    local owed='nothing — this is the first version under the contract'
    case "$tier" in
      breaking) owed='a MAJOR owes a MIGRATION, and one is there' ;;
      additive) owed='a MINOR declares nothing broken' ;;
      invisible) owed='a PATCH is invisible by the definition of the tier' ;;
      none) owed='no bump since the last commit, so nothing is promised' ;;
    esac
    printf 'VERSION %s, tier `%s` from %s; changelog sections descend and the top one is the version; %s\n' \
      "$version" "$tier" "${from:-nothing, so this is the first version under the contract}" "$owed"
  }
  check 'stability gate  (a version bump pays for the tier it derives)' stability_gate_check

  # RESERVED. One check, one direction: a retired name must still be gone. The
  # rule it enforces and why the fourth hygiene rule is INVERTED here rather
  # than copied is in the file's own header.
  reserved_check() {
    local problems=0 count=0 line kind name retired
    if [ ! -f "$ROOT/RESERVED" ]; then
      printf 'RESERVED does not exist. Retiring a template path without leaving a tombstone is how the same path comes back meaning something else, and nothing else in this tree would notice.\n' >&2
      return 1
    fi
    while IFS= read -r line; do
      case "$line" in
        '' | \#*) continue ;;
      esac
      count=$((count + 1))
      # The leading word is the ledger's own `reserved` marker, so the KIND is
      # the second field. Reading $1 as the kind made every entry declare kind
      # "reserved", which is a ledger that checks one thing and reports another.
      case "$line" in
        reserved\ *)
          ;;
        *)
          printf 'a RESERVED entry does not begin with `reserved`: %s\n' "$line" >&2
          problems=$((problems + 1))
          continue
          ;;
      esac
      # shellcheck disable=SC2086 # two leading fields, then key="value" pairs
      set -- $line
      shift
      kind="${1:-}"
      name="${2:-}"
      retired=''
      shift 2 2>/dev/null || true
      for kv in "$@"; do
        case "$kv" in
          retired_in=*) retired="${kv#retired_in=}" ;;
        esac
      done
      case "$line" in
        *reason=*owner=*since=*)
          ;;
        *)
          printf 'a RESERVED entry does not carry reason, owner and since: %s\n' "$line" >&2
          problems=$((problems + 1))
          ;;
      esac
      if [ "$kind" != path ]; then
        printf 'RESERVED entry %s declares kind %s, and no check implements that kind. A kind nobody checks is an entry that reads as protection and provides none.\n' "${name:-<no name>}" "${kind:-<none>}" >&2
        problems=$((problems + 1))
        continue
      fi
      if [ -z "$name" ] || [ -z "$retired" ]; then
        printf 'a RESERVED entry is missing its name or its retired_in: %s\n' "$line" >&2
        problems=$((problems + 1))
        continue
      fi
      if ! stability_parse "$retired"; then
        printf 'RESERVED entry %s retires in %s, which is not a version, so nothing can be checked against it.\n' "$name" "$retired" >&2
        problems=$((problems + 1))
        continue
      fi
      if [ -e "$ROOT/$name" ]; then
        printf 'RESERVED says %s was retired in %s, and it is in the tree. This is the check the file exists for: a tombstone nothing enforces is a note.\n' "$name" "$retired" >&2
        problems=$((problems + 1))
      fi
    done <"$ROOT/RESERVED"
    if [ "$problems" -ne 0 ]; then
      return 1
    fi
    printf '%s reserved name(s), every one of them absent from the tree\n' "$count"
  }
  check 'reserved tombstones  (a retired name stays dead)' reserved_check

  # The README's own examples must call the workflow the README says it does.
  #
  # Every yaml block in the README that contains `uses: cafaye/kit/` is a
  # caller. A caller passing an input the workflow does not declare fails at
  # run time on the adopting repo's first push — thirteen repos, one stale
  # sentence in this file. So the examples are parsed and checked against the
  # workflow's real inputs, and a doc that lies fails the gate.
  caller_check() {
    "$PY" - "$ROOT" "$REUSABLE_WORKFLOWS" <<'PY2'
import os
import re
import sys

import yaml

root = sys.argv[1]
readme = open(f"{root}/README.md", encoding="utf-8").read()

# Fenced yaml blocks only, and only the ones that are actually calling kit.
blocks = re.findall(r"```yaml\n(.*?)```", readme, re.S)
callers = [b for b in blocks if "uses: cafaye/kit/" in b]
if not callers:
    sys.exit("no documented caller of the reusable workflow found in README.md")

# ONE MAP OF PATH -> DECLARED INPUTS, not one workflow's inputs.
#
# Before kit-32 this read a single file and compared every documented `with:`
# against it, which was correct while kit handed out one standard and became a
# false positive the moment it handed out two: README's documented publish
# caller names `push`, the CI workflow does not declare `push`, and the check
# reported a documentation defect against a document that was right.
#
# So the inputs are resolved PER `uses:` PATH. A block that names a declared
# standard is checked against that standard; a bare `with:` fragment with no
# `uses:` line is checked against the CI standard, which is what every such
# fragment in the README is about. Which is the rule, stated once: a documented
# caller is checked against the workflow it actually calls.
def _inputs_of(path):
    full = os.path.join(root, path)
    if not os.path.isfile(full):
        return None
    with open(full, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    triggers = (doc or {}).get("on") or (doc or {}).get(True) or {}
    return (((triggers.get("workflow_call") or {}).get("inputs")) or {})

reusables = sys.argv[2].split()
by_path = {p: _inputs_of(p) for p in reusables}
default_path = reusables[0]
declared = by_path[default_path]
required = {k for k, v in declared.items() if (v or {}).get("required")}

# `cafaye/kit/.github/workflows/x.yml@master` -> `.github/workflows/x.yml`
def _path_of(uses):
    return uses.partition("@")[0].replace("cafaye/kit/", "", 1)


def uses_values(node):
    """Every value assigned to a `uses:` key, at any depth.

    Restated here rather than imported: this check is its own script with its
    own heredoc, and the `callable` check below has its own copy for the same
    reason. A shared module would be a file the walk in that check would have to
    exempt, which is a small price for not having the two readers of `uses:`
    disagree.
    """
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "uses" and isinstance(value, str):
                found.append(value)
            else:
                found.extend(uses_values(value))
    elif isinstance(node, list):
        for item in node:
            found.extend(uses_values(item))
    return found

def _find_with_keys(node):
    """Every key set under a `with:` mapping, at any depth."""
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "with" and isinstance(value, dict):
                found.append(value.keys())
            else:
                found.extend(_find_with_keys(value))
    elif isinstance(node, list):
        for item in node:
            found.extend(_find_with_keys(item))
    return found


def _find_telemetry(node):
    """Every value assigned to a `telemetry` key, at any depth.

    The examples are fragments, so the key can sit under `with:`, under a `job`,
    or under nothing at all. A depth-limited walk would miss the case that
    matters.
    """
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "telemetry":
                found.append(value)
            else:
                found.extend(_find_telemetry(value))
    elif isinstance(node, list):
        for item in node:
            found.extend(_find_telemetry(item))
    return found


problems = []
for n, block in enumerate(callers, 1):
    try:
        doc_n = yaml.safe_load(block)
    except Exception as exc:
        problems.append(f"documented caller #{n} is not valid YAML: {exc}")
        continue
    for job_name, job in (doc_n.get("jobs") or {}).items():
        if not isinstance(job, dict) or "cafaye/kit/" not in str(job.get("uses", "")):
            continue
        # Resolved per job, not per file: one README block may show a service
        # calling both standards, and each job's `with:` is checked against the
        # workflow THAT job calls.
        called = _path_of(str(job.get("uses", "")))
        inputs = by_path.get(called)
        if inputs is None:
            problems.append(
                f"documented caller #{n} job {job_name} calls {called}, which is "
                f"not one of kit's declared standards ({', '.join(reusables)})"
            )
            continue
        req = {k for k, v in inputs.items() if (v or {}).get("required")}
        passed = set(job.get("with") or {})
        unknown = sorted(passed - set(inputs))
        missing = sorted(req - passed)
        if unknown:
            problems.append(
                f"documented caller #{n} job {job_name} (calling {called}): "
                f"passes {unknown}, which the workflow does not declare"
            )
        if missing:
            problems.append(
                f"documented caller #{n} job {job_name} (calling {called}): "
                f"omits required {missing}"
            )

# Any documented `with:` block names workflow inputs, whether or not the block
# also carries a `uses:` line. The adoption steps and the telemetry opt-in are
# both bare `with:` fragments under prose, and they are the two a reader copies
# line by line — so restricting the input check to complete caller blocks checks
# the example nobody copies and skips the ones everybody does.
for n, block in enumerate(blocks, 1):
    if "with:" not in block:
        continue
    try:
        parsed = yaml.safe_load(block)
    except Exception:
        continue
    # Resolved FROM THE BLOCK, per block. A block carrying a `uses:` line is
    # checked against the workflow it names, so the README's documented publish
    # caller is not reported as passing an input the CI standard does not
    # declare. A block with no `uses:` line is a bare fragment, and every such
    # fragment in this README documents the CI standard — which is stated in the
    # failure message, because "which workflow did you mean" is not a question a
    # reader can answer from the message alone.
    named = [v for v in uses_values(parsed) if "cafaye/kit/" in v]
    block_path = _path_of(named[0]) if named else default_path
    block_inputs = by_path.get(block_path)
    if block_inputs is None:
        # The per-caller loop above already reports an unknown standard, with
        # the job name. Skipping here keeps one defect to one message.
        continue
    for keys in _find_with_keys(parsed):
        unknown = sorted(set(keys) - set(block_inputs))
        if unknown:
            problems.append(
                f"yaml block #{n}: a `with:` names {unknown}, which {block_path} "
                f"does not declare as an input"
            )

# `telemetry` must be shown as a STRING everywhere it appears, not only in a
# full caller block. The input exists precisely because GitHub coerces the bare
# word `false` to a boolean in some positions, so a README example that writes
# `telemetry: true` teaches the one spelling that does not work — and a reader
# who copies it gets an opt-in job running that they did not intend to switch
# on, in a repo that was green a moment earlier.
#
# Checked on every yaml block, including the `with:` fragments that have no
# `uses:` line to key off. The first version of this check only looked at
# callers and therefore missed exactly the fragment most likely to be copied.
for n, block in enumerate(blocks, 1):
    if "telemetry" not in block:
        continue
    try:
        parsed = yaml.safe_load(block)
    except Exception:
        continue  # reported by the caller loop if it is a caller at all
    found = _find_telemetry(parsed)
    for value in found:
        if not isinstance(value, str):
            problems.append(
                f"yaml block #{n}: telemetry must be the string 'true' or "
                f"'false', not {value!r} — a bare boolean is the trap this input "
                f"type exists to avoid"
            )

if problems:
    sys.exit("; ".join(problems))
PY2
  }
  check 'README.md  (its documented callers match the workflow inputs)' caller_check

  # -------------------------------------------------------------------------
  # The check this packet exists for.
  #
  # kit-02 shipped a reusable workflow at `workflows/ci.reusable.yml`, a README
  # telling every reader to write
  #
  #     uses: cafaye/kit/workflows/ci.reusable.yml@master
  #
  # and GitHub, which does not support subdirectories of the workflows
  # directory, resolving that to nothing. Every check in this file was green
  # for the whole of that time. A layout bug and a documentation bug that agree
  # with each other are invisible to any check that reads only one of them, and
  # the file they disagreed about is the one thirteen repos were told to depend
  # on.
  #
  # So this asserts the agreement directly, in the places it can drift:
  #
  #   1. the file is at the path callers are told to use
  #   2. it declares `on: workflow_call` (parseable, and actually callable)
  #   3. every real `uses:` that names kit — in the docs' fenced yaml blocks and
  #      in this repo's own workflow files — is exactly that path, cross-repo
  #      with a ref, or local with `./` for kit calling itself
  #   4. kit's own CI calls it with the LOCAL form, so the self-proof is a
  #      self-proof and not a network fetch of some other ref
  #   5. there is exactly one copy of it in the tree
  #
  # Point 5 is not paranoia. A mirror — canonical file here, callable copy
  # there — is one of the two layouts the packet offered, and it is only
  # acceptable with a check that fails when the copies differ. kit chose the
  # move, so this walks the tree and refuses to find a second one. Same
  # reasoning as the outbox/`registries` duplication this repo already refuses.
  #
  # Only *executable* call sites are read: the `uses:` keys of parsed yaml.
  # Prose that quotes a wrong path to explain why it is wrong — which README
  # and AGENTS.md both now do — is not a call site, and a check that flags its
  # own explanation is a check people delete.
  callable_check() {
    "$PY" - "$ROOT" "$WORKFLOW" "$REUSABLE_WORKFLOWS" <<'PY3'
import os
import re
import sys

import yaml

root = sys.argv[1]
workflow = sys.argv[2]
# Every path kit declares callable, so step 5 can tell a second COPY of a
# standard from a second STANDARD.
reusables = sys.argv[3].split()
remote = "cafaye/kit/" + workflow
local = "./" + workflow

problems = []

# --- 1 and 2: the file is where callers are told it is, and it is callable ----
path = os.path.join(root, workflow)
if not os.path.isfile(path):
    problems.append(
        f"callers are documented to write `uses: cafaye/kit/{workflow}@<ref>`, and "
        f"{workflow} does not exist — GitHub resolves a reusable workflow only "
        f"from .github/workflows/, so nothing can call kit"
    )
else:
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    # `on:` is read by PyYAML 1.1 as the boolean True.
    triggers = doc.get("on") or doc.get(True) or {}
    if not isinstance(triggers, dict) or "workflow_call" not in triggers:
        problems.append(
            f"{workflow} does not declare `on: workflow_call`; GitHub rejects the "
            f"call before it reads a single input, so a caller gets a red build "
            f"with no explanation"
        )

# --- 2b: every OTHER declared standard is at its declared path and callable ---
#
# The same two claims about each remaining entry in REUSABLE_WORKFLOWS, because
# a variable listing a path is not evidence the file is there. Declaring
# `image.reusable.yml` in order to widen step 5 would otherwise have the effect
# of exempting a path from the copy walk that does not exist — the drift check
# silently weakened to accommodate the file it was written to police.
for other in reusables:
    if other == workflow:
        continue
    other_path = os.path.join(root, other)
    if not os.path.isfile(other_path):
        problems.append(
            f"{other} is declared callable in REUSABLE_WORKFLOWS but does not "
            f"exist. Either ship the file or drop it from the list: an entry "
            f"naming a path with no file behind it makes step 5 exempt a path "
            f"nothing can call"
        )
        continue
    with open(other_path, encoding="utf-8") as fh:
        other_doc = yaml.safe_load(fh)
    other_triggers = (other_doc or {}).get("on") or (other_doc or {}).get(True) or {}
    if not isinstance(other_triggers, dict) or "workflow_call" not in other_triggers:
        problems.append(
            f"{other} does not declare `on: workflow_call`, so it is not callable "
            f"at all. It is in REUSABLE_WORKFLOWS because it is a standard kit "
            f"hands out, and a standard nobody can call is a comment"
        )


def uses_values(node):
    """Every value assigned to a `uses:` key, at any depth."""
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "uses" and isinstance(value, str):
                found.append(value)
            else:
                found.extend(uses_values(value))
    elif isinstance(node, list):
        for item in node:
            found.extend(uses_values(item))
    return found


# --- 3: every real call site resolves to the one path ------------------------
call_sites = []  # (where, value)

# 3a. the fenced yaml blocks in the two documents a reader copies from.
#
# EACH DECLARED STANDARD NEEDS AN EXAMPLE IN EACH DOCUMENT, not one example of
# one of them. That is the widened form: kit-32 added a second callable
# workflow, and a README that documents calling the CI standard while shipping
# an image workflow nobody is told how to call has reproduced exactly the defect
# this check exists for — a standard with no call to copy.
documented_paths = set()
for doc_name in ("README.md", "AGENTS.md"):
    body = open(os.path.join(root, doc_name), encoding="utf-8").read()
    for n, block in enumerate(re.findall(r"```yaml\n(.*?)```", body, re.S), 1):
        try:
            parsed = yaml.safe_load(block)
        except Exception:
            continue  # not a workflow fragment; another check reports real yaml
        for value in uses_values(parsed):
            if "cafaye/kit" not in value and not value.startswith("./"):
                continue
            call_sites.append((f"{doc_name} yaml block #{n}", value))
            if value.startswith("cafaye/kit"):
                documented_paths.add(value.partition("@")[0].replace("cafaye/kit/", "", 1))
    # Both documents must show the calls. AGENTS.md is not decoration: it is the
    # file a contributor reads before touching the workflow, and it was the one
    # telling people to edit `workflows/ci.reusable.yml` for six months.
    for rel in reusables:
        if rel not in documented_paths:
            problems.append(
                f"{doc_name} shows no `uses: cafaye/kit/{rel}@<ref>` example, so "
                f"a reader of that file has no call to copy for that standard"
            )

# 3b. this repo's own workflow files. Comments are not yaml and are skipped by
#     parsing, so the header of the reusable workflow — which shows the same
#     call as an example — is documentation, not a call site, and is not
#     double-counted here.
live_dir = os.path.join(root, ".github", "workflows")
for name in sorted(os.listdir(live_dir)) if os.path.isdir(live_dir) else []:
    if not name.endswith((".yml", ".yaml")):
        continue
    with open(os.path.join(live_dir, name), encoding="utf-8") as fh:
        try:
            parsed = yaml.safe_load(fh)
        except Exception as exc:
            problems.append(f".github/workflows/{name} is not valid YAML: {exc}")
            continue
    for value in uses_values(parsed):
        if "cafaye/kit" in value or value.startswith("./"):
            call_sites.append((f".github/workflows/{name}", value))

if not call_sites:
    problems.append(
        "no `uses:` anywhere calls kit, so nothing in this repository exercises "
        "the callable path"
    )

for where, value in call_sites:
    if value.startswith("./"):
        if value != local:
            problems.append(
                f"{where}: `uses: {value}` does not resolve; kit's own copy is at "
                f"`{local}`"
            )
        continue
    if not value.startswith("cafaye/kit/"):
        problems.append(f"{where}: `uses: {value}` is not a reference to kit")
        continue
    # Split the ref off before comparing. Comparing the whole string to the
    # path made every correct `...@master` look wrong, which is the check
    # failing on the very line it exists to bless.
    ref_path, _, ref = value.partition("@")
    # NOT `!= remote`. Before kit-32 that compared against the one CI path, so a
    # correct `uses: cafaye/kit/.github/workflows/image.reusable.yml@master` in
    # README was reported as "a path GitHub cannot resolve" — the check telling
    # a reader their documented call is wrong about the thing the check was
    # added to protect. With two standards, ANY of them resolves; what must not
    # resolve is a path kit does not declare.
    declared_rel = ref_path.replace("cafaye/kit/", "", 1)
    if declared_rel not in reusables:
        problems.append(
            f"{where}: `uses: {value}` names {declared_rel}, which is not one of "
            f"kit's declared standards ({', '.join(reusables)}). Callers must write "
            f"`uses: cafaye/kit/<declared-path>@<ref>`"
        )
    elif not ref:
        problems.append(
            f"{where}: `uses: {value}` has an empty @ref, which resolves to nothing"
        )

# --- 4: kit's own CI calls it locally ---------------------------------------
self_call = os.path.join(root, ".github", "workflows", "ci.yml")
if not os.path.isfile(self_call):
    problems.append(
        "no .github/workflows/ci.yml, so the repository defining the standard is "
        "not held to it and the callable path is never exercised in CI"
    )
else:
    with open(self_call, encoding="utf-8") as fh:
        parsed = yaml.safe_load(fh)
    jobs = (parsed or {}).get("jobs") or {}
    # Both spellings count: the cross-repo one, and the local `./` form kit is
    # the only repository that can legitimately write. Filtering on
    # `cafaye/kit` alone read kit's own self-call as "no reusable workflow at
    # all", which is the same class of false negative this check exists to
    # remove.
    kit_jobs = {
        name: job
        for name, job in jobs.items()
        if isinstance(job, dict)
        and ("cafaye/kit" in str(job.get("uses", "")) or str(job.get("uses", "")).startswith("./"))
    }
    if not kit_jobs:
        problems.append(
            ".github/workflows/ci.yml calls no reusable workflow: kit does not run "
            "its own gate in CI"
        )
    for name, job in kit_jobs.items():
        if job.get("uses") != local:
            problems.append(
                f".github/workflows/ci.yml job {name}: `uses: {job.get('uses')}` — "
                f"kit must call its own workflow with `{local}`, so the job proves "
                f"the local path resolves instead of fetching some other ref from "
                f"the network"
            )

# --- 5: one copy per standard, at the reachable path ------------------------
# Walked rather than globbed, because the whole failure mode is a file parked
# somewhere the documented path does not point. `.git` and the gate's own
# gitignored `.venv` are the only trees skipped; everything else is fair game.
#
# THE EXEMPTION IS THE SET, NOT THE ONE FILE. Before kit-32 this skipped a
# single path and refused every other `workflow_call` file in the tree, which
# works until kit owns a second standard — and then the check reports a defect
# that does not exist, on a file added deliberately. A rule that makes kit
# unable to grow is not a drift check; it is a freeze.
#
# So a file is exempt when its path is one kit DECLARES callable, and every
# other file is compared on content. Two cases, deliberately reported
# differently, because they are different mistakes:
#
#   - same `name:` as a declared standard  -> a COPY, parked where no caller
#     can reach it. This is the original defect and it is still the failure
#     this step exists for.
#   - a different `name:`                 -> an UNDECLARED standard. Not drift;
#     a callable workflow kit ships without listing it, which is the same
#     documentation/agreement bug the whole packet is about, one file over.
#
# A file that neither declares nor matches is skipped, which is where the
# walker's own self_test.sh and the workflow headers live.
declared_names = {}
for rel in reusables:
    full = os.path.join(root, rel)
    try:
        with open(full, encoding="utf-8") as fh:
            declared_names[yaml.safe_load(fh).get("name")] = rel
    except Exception:
        continue

copies = []
undeclared = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [
        # tests/.bin is the gate's own fetched scanners (hadolint, gitleaks).
        # It is gitignored and a throwaway copy carries it, and a 15MB binary is
        # not a file to read the first 64KB of looking for a YAML key.
        d for d in dirnames if d not in (".git", ".venv", ".bin", "__pycache__")
    ]
    for filename in filenames:
        full = os.path.join(dirpath, filename)
        rel = os.path.relpath(full, root)
        if rel in reusables:
            continue
        # shell scripts are excluded for the same reason, and because the
        # walker's own self_test.sh names `workflow_call` in a comment explaining
        # breakage 8 — which this check reported as a second copy of the CI
        # standard. A check that fires on the file proving it wrong is a check
        # that gets deleted.
        if filename.endswith((".sh", ".toml", ".md", ".pyc")):
            continue
        try:
            with open(full, encoding="utf-8") as fh:
                head = fh.read(65536)
        except (OSError, UnicodeDecodeError):
            continue
        if "workflow_call" not in head:
            continue
        # A third-party reference in a comment is not a copy.
        if not re.search(r"^\s*workflow_call\s*:", head, re.M):
            continue
        # Which mistake is this? Read the parsed `name:` rather than guessing
        # from the path, because the two failures need two different fixes: a
        # copy gets deleted, an undeclared standard gets added to
        # REUSABLE_WORKFLOWS.
        try:
            with open(full, encoding="utf-8") as fh:
                parsed = yaml.safe_load(fh)
            found_name = (parsed or {}).get("name")
        except Exception:
            found_name = None
        if found_name in declared_names:
            copies.append(f"{rel} (a copy of {declared_names[found_name]})")
        else:
            undeclared.append(f"{rel} (name: {found_name!r})")

if copies:
    problems.append(
        f"a copy of a declared standard exists at {copies}. Two copies of one "
        f"standard is the drift kit exists to prevent, and only the paths in "
        f"REUSABLE_WORKFLOWS are reachable by a caller"
    )
if undeclared:
    problems.append(
        f"a callable workflow exists at {undeclared} and is not in "
        f"REUSABLE_WORKFLOWS. A standard kit hands out has to be listed there: "
        f"the list is what makes it exempt from the copy check above, so an "
        f"unlisted one is invisible to the drift check rather than exempt from "
        f"it. Either add the path or delete the file"
    )

if problems:
    sys.exit("; ".join(problems))
PY3
  }
  # The label says "reusable workflows" rather than naming one file, because kit
  # has declared TWO standards and this check governs both. A label reading
  # `ci.reusable.yml` on a failure that is actually inside `image.reusable.yml`
  # sends the next reader to the wrong file — which is the same defect the check
  # exists to catch, one level up: a name that has stopped matching what it is
  # about.
  check "reusable workflows  (callable: exists, on: workflow_call, docs agree)" callable_check

  # -------------------------------------------------------------------------
  # A workflow file GitHub REJECTS is invisible here by default, and it is the
  # most expensive kind of invisible this gate has.
  #
  # WHAT HAPPENED. From 2026-09-30 until kit-33, `ci.reusable.yml` declared an
  # `options:` list under its `workflow_call` `language` input. `options` is a
  # `workflow_dispatch` feature; `workflow_call` inputs accept only
  # `description`, `required`, `type` and `default`. GitHub rejects the ENTIRE
  # FILE at parse time for an unknown key — not the one input, the file — so
  # every job in it failed to start, for every caller, in every repository.
  #
  # WHY NOTHING CAUGHT IT FOR TWO DAYS. Every check in this gate read the
  # workflow as TEXT and every one of them was satisfied: the file existed, it
  # declared `workflow_call`, the documented call matched, the inputs matched.
  # What none of them asked was whether the file is a workflow GitHub can run.
  # Meanwhile the run summary said only "This run likely failed because of a
  # workflow file issue" and the check suite reported zero check runs, so the
  # badge was red in a way that looked like infrastructure rather than like a
  # defect in the tree. Every static check was green throughout.
  #
  # WHAT THIS CHECK IS, PRECISELY, because a check that claims more than it does
  # is the defect it exists to catch. It is NOT a GitHub Actions schema
  # validator and it will not catch every way a workflow can be invalid — it
  # cannot know about expression contexts, runner labels, or a `uses:` that
  # resolves to nothing. It asserts ONE property, and the one it asserts is the
  # one that was actually violated: every key directly under a `workflow_call`
  # input is one GitHub documents for that event.
  #
  # `options` is named in the message because it is the key that was written, it
  # is the one every author reaches for, and a message naming the key is a
  # message the next author can act on.
  workflow_inputs_check() {
    "$PY" - "$ROOT" $REUSABLE_WORKFLOWS <<'PY1'
import sys, yaml

root, reusables = sys.argv[1], sys.argv[2].split()

# Documented for `workflow_call`. `options` and the dropdown UI belong to
# `workflow_dispatch`; they are not a smaller version of the same thing, they
# are a different event's schema, and GitHub's parser knows the difference and
# refuses the file.
ALLOWED = {"description", "required", "type", "default"}

problems = []
for rel in reusables:
    path = f"{root}/{rel}"
    try:
        doc = yaml.safe_load(open(path))
    except Exception as exc:
        problems.append(f"{rel}: does not parse as YAML ({exc})")
        continue
    if not isinstance(doc, dict):
        problems.append(f"{rel}: is not a mapping at the top level")
        continue
    # `on:` parses as the boolean True under YAML 1.1, and PyYAML follows
    # YAML 1.1. Both spellings are accepted so this check does not depend on
    # which one the file happened to use.
    on = doc.get("on", doc.get(True))
    if not isinstance(on, dict):
        problems.append(f"{rel}: has no `on:` block")
        continue
    call = on.get("workflow_call")
    if call is None:
        problems.append(f"{rel}: declares no `workflow_call`")
        continue
    inputs = call.get("inputs") or {}
    for name, spec in inputs.items():
        if not isinstance(spec, dict):
            problems.append(f"{rel}: input `{name}` is not a mapping")
            continue
        for key in spec:
            if key not in ALLOWED:
                hint = ""
                if key == "options":
                    hint = (
                        "  `options` is a `workflow_dispatch` feature."
                        " `workflow_call` has no dropdown,\n  and the legal"
                        " values belong in the `description:` -- enforce them"
                        " with a job,\n  because an unrecognised value skips"
                        " every `if: inputs.x == ...` gate and\n  leaves a green"
                        " run that tested nothing."
                    )
                problems.append(
                    f"{rel}: input `{name}` declares `{key}`, which is not one"
                    f" of GitHub's `workflow_call` input keys{hint}"
                )
if problems:
    sys.exit("; ".join(problems))
PY1
  }
  check "reusable workflows  (workflow_call inputs use only documented keys)" workflow_inputs_check

  # -------------------------------------------------------------------------
  # The concurrency group a reusable workflow asks for must not be one its
  # CALLER can also ask for.
  #
  # MEASURED, and the measurement is four days long. Every caller in the fleet
  # declared
  #
  #     concurrency:
  #       group: ${{ github.workflow }}-${{ github.ref }}
  #       cancel-in-progress: true
  #
  # and `.github/workflows/ci.reusable.yml` declared the identical block from the
  # commit that first published it (8ebf4db, 2026-09-30). Inside a reusable
  # workflow `github.workflow` is the CALLER's workflow name and `github.ref` is
  # the caller's ref, so both sides computed the same string and asked for the
  # same lock. The caller holds it. The `uses:` job produced no job, no
  # check-run and no log line:
  #
  #   $ gh api repos/cafaye/parlor/actions/runs/37230458669/jobs \
  #       --jq '.jobs[] | "\(.name) | \(.status)/\(.conclusion)"'
  #   typecheck + build | completed/success
  #   bin/prime         | completed/success
  #   $ gh api repos/cafaye/parlor/actions/runs/37230458669 --jq '.conclusion'
  #   failure
  #
  # BOTH jobs green, the run red, `--log-failed` empty. The `language` gate job is
  # UNCONDITIONAL, so its absence is the unambiguous signal, and no caller in the
  # fleet has ever produced a job ending `/ language` — which is where lint, the
  # frozen install and the coverage step live.
  #
  # WHY A CHECK IN THIS FILE AND NOT A RUNNER. `callable_check` above already
  # asserts the path resolves, that `workflow_call` is declared, and that the
  # inputs match; the file was green for the whole of the time this was broken,
  # because every one of those claims was TRUE. This defect is not about the
  # workflow being valid. It is about two valid workflows asking for one lock, and
  # the only place both sides are visible at once is here.
  #
  # WHAT IT ASSERTS, and it is deliberately narrow — a check that claims more
  # than it does is the defect it exists to catch, so it does not attempt to
  # evaluate a concurrency expression. It compares the SHAPES:
  #
  #   1. every standard kit hands out namespaces its group with `kit-`, so a
  #      caller's group and kit's cannot be the same string;
  #   2. a caller that calls a kit standard and declares `concurrency` must not
  #      produce a group that normalises to the same expression as one of kit's.
  #
  # (2) is read from THIS repository's own `.github/workflows/ci.yml`, because
  # kit is a caller of itself and had the defect in both files at once. It is not
  # a fleet sweep: `fleet_check.py` reads the repositories beside this one and
  # reports a loud SKIP when there are none, and a second reader of the same
  # fleet would be a second answer to a question kit already asks. What kit OWNS
  # is its own spelling, and a caller is one `kit-` prefix away from the fix.
  #
  # THE NORMALISATION IS THE PART THAT MATTERS, and it exists because `core`
  # writes `${{ github.workflow }}-${{ ref }}` — not `github.ref`. Those are the
  # same value to GitHub and different bytes to a `==`, so a byte comparison
  # would have called the one repository that got it differently CLEAN.
  reusable_concurrency_check() {
    "$PY" - "$ROOT" "$REUSABLE_WORKFLOWS" <<'PY4'
import os
import re
import sys

import yaml

root, reusables = sys.argv[1], sys.argv[2].split()

PREFIX = "kit-"


def group_of(doc):
    """A workflow's concurrency group, or None.

    Read as a document rather than grepped: `concurrency` may be a bare string
    (`concurrency: my-group`) or a mapping, and only the mapping form carries the
    `group` key. A check that read one spelling would pass on a tree using the
    other.
    """
    conc = (doc or {}).get("concurrency")
    if isinstance(conc, str):
        return conc
    if isinstance(conc, dict):
        got = conc.get("group")
        return got if isinstance(got, str) else None
    return None


def normalise(expr):
    """Reduce a group expression to the thing two files can collide ON.

    `github.ref` and the bare `ref` are the same value to GitHub, and the fleet
    uses both spellings, so they are the same token here. `github.workflow` is
    left as its own token rather than substituted: kit's group prefixes it with
    `kit-`, and a caller's does not, which is exactly the difference being
    measured. Whitespace and quoting are stripped so a reformat is not a fix.
    """
    out = re.sub(r"github\.ref\b", "ref", expr)
    out = out.replace("${{", "").replace("}}", "")
    out = out.replace("github.", "")
    return re.sub(r"\s+", "", out.strip().strip("'\""))


problems = []
kit_groups = {}

for rel in reusables:
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        continue
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    group = group_of(doc)
    if group is None:
        # Declaring no `concurrency` cannot collide with anything. That is the
        # state `image.reusable.yml` is in, and it is why its two callers
        # produce `image / build` on every run while `ci.reusable.yml`'s eleven
        # produce nothing.
        continue
    kit_groups[rel] = group
    if not group.startswith(PREFIX):
        problems.append(
            f"{rel}: concurrency group `{group}` does not begin with `{PREFIX}`. "
            f"A reusable workflow and its caller both evaluate `github.workflow` "
            f"and `github.ref` to the CALLER's values, so an unprefixed group is "
            f"the group the caller is already holding: the `uses:` job is then "
            f"never created, with no job, no check-run and no log to show for it. "
            f"Prefix it with `{PREFIX}`."
        )

# kit's own caller. Same file, same group, both sides — which is why this defect
# was invisible: kit held the standard AND was a caller of it.
self_path = os.path.join(root, ".github", "workflows", "ci.yml")
if os.path.isfile(self_path):
    with open(self_path, encoding="utf-8") as fh:
        self_doc = yaml.safe_load(fh)
    mine = group_of(self_doc)
    for rel, theirs in kit_groups.items():
        if mine is not None and normalise(mine) == normalise(theirs):
            problems.append(
                f".github/workflows/ci.yml declares concurrency group `{mine}` and "
                f"{rel} declares `{theirs}`. These are the same lock: the caller "
                f"holds it and the callee is refused, so the `uses:` job below "
                f"never runs. One of the two has to differ."
            )

if problems:
    sys.exit("; ".join(problems))

print(
    f"{len(kit_groups)} reusable workflow(s) declare a `kit-` namespaced "
    f"concurrency group, and kit's own caller does not collide with "
    f"{'any of them' if kit_groups else 'them'}"
)
PY4
  }
  check "reusable workflows  (no caller and callee share a concurrency group)" \
    reusable_concurrency_check

  # -------------------------------------------------------------------------
  # Secrets. Two scanners and two different questions, and this section is the
  # part of the gate that proves both of them can fail.
  #
  # gitleaks answers "was a secret committed"; the canary harness answers "does
  # one leave the process while the tests run". Neither is a substitute for the
  # other, and the second has no off-the-shelf implementation at all — see
  # templates/secrets/README.md for the measurement behind that.
  #
  # The scanner runs in `secrets` / `zizmor`-style jobs in the reusable workflow,
  # and ALSO here, because a check that only runs in a CI runner is a check whose
  # first execution is on a stranger's commit. `bash tests/validate.sh` is the
  # whole procedure on a clean clone, and this is part of it.
  # The gitleaks config check needs tomllib (python 3.11+). Resolved ONCE, here,
  # so that a machine without it gets one honest FAIL that names the cause rather
  # than five separate "could not parse" failures that read as five defects.
  HAVE_TOMLLIB=1
  if ! "$PY" -c 'import tomllib' >/dev/null 2>&1; then
    HAVE_TOMLLIB=0
  fi

  section 'static: secrets — the scanner is present, configured, and can fail'

  # The scanner is RESOLVED FIRST, before any check that executes it.
  #
  # Ordering, and it is not cosmetic: the behavioural check below runs the scan
  # against a throwaway repository, so it needs a binary. Resolving afterwards
  # meant the check read an unset variable and reported "unbound variable" —
  # which is a FAIL for the wrong reason, and a FAIL nobody can act on.
  #
  # A FAIL and not a SKIP when gitleaks cannot be installed, for the reason the
  # hadolint check gives: a gate that reports "I could not check" and exits 0 is
  # the exact shape PLAN.md §1 calls a gate that is not green. It is also the
  # shape that let seven Dockerfiles go unlinted.
  GITLEAKS_BIN=''
  if [ -n "${KIT_GITLEAKS:-}" ]; then
    GITLEAKS_BIN="$KIT_GITLEAKS"
  elif kit_bootstrap_binary gitleaks \
    "https://github.com/gitleaks/gitleaks/releases/download/v${KIT_GITLEAKS_VERSION}" \
    "$KIT_GITLEAKS_SHA256S" "$ROOT" \
    "gitleaks_${KIT_GITLEAKS_VERSION}_@ros@_@arch@.tar.gz" gitleaks; then
    GITLEAKS_BIN="$BIN"
    # Exported so the twenty-odd throwaway copies self_test makes share this
    # binary instead of each downloading its own 15MB archive. Same reasoning as
    # KIT_PYTHON, one level down: twenty downloads is twenty chances to fail for
    # a reason that has nothing to do with the breakage under test.
    export KIT_GITLEAKS="$BIN"
  else
    report FAIL 'gitleaks (required: could not be installed — see the note above)'
  fi

  gitleaks_config() {
    "$PY" - "$ROOT" "$GITLEAKS_CONFIG" "$HAVE_TOMLLIB" <<'PY'
import os
import sys

root, rel, have_tomllib = sys.argv[1], sys.argv[2], sys.argv[3]
path = os.path.join(root, rel)
problems = []

if not os.path.isfile(path):
    sys.exit(
        f"{rel} does not exist. gitleaks then runs on its DEFAULT rules with no "
        f"cafaye allowlist, which is a scan that looks configured and is not — "
        f"and the allowlist is the only part of it anyone wrote"
    )

# Parsed as TOML, not grepped. Resolved by the caller so a machine without
# tomllib gets one honest message instead of several that read as several
# defects — and a config nobody parsed is a config nobody is reading.
if have_tomllib != "1":
    sys.exit(
        f"{rel} could not be parsed: this python has no tomllib (3.11+). The file "
        f"exists and gitleaks will read it, but nothing in this gate has, and a "
        f"secret-scanner allowlist that no tool ever parses is not an allowlist"
    )
import tomllib

with open(path, "rb") as fh:
    try:
        doc = tomllib.load(fh)
    except Exception as exc:
        sys.exit(f"{rel} is not valid TOML: {exc}")

# The rules must be gitleaks' own. A repo that redefines a rule has taken
# responsibility for the regex, and the reason kit can be thirty lines instead of
# six thousand is that it does not.
if "rules" in doc:
    problems.append(
        f"{rel} defines its own [[rules]]. kit extends gitleaks' defaults "
        f"(extend.useDefault) so a new provider detection reaches thirteen repos "
        f"the day gitleaks ships it. A vendored rule set is a rule set that stops "
        f"receiving providers, which is a secret scanner that has stopped working"
    )

extend = doc.get("extend") or {}
if extend.get("useDefault") is not True:
    problems.append(
        f"{rel} does not set extend.useDefault = true, so the rules it runs are "
        f"whatever this file happens to declare — which is none of them"
    )

# R3: every allowlist entry carries a reason, and an entry with no reason is a
# failure. This is the ESLint reportUnusedDisableDirectives property and it is
# the load-bearing one: an allowlist that grows monotonically and is never pruned
# is not an allowlist, it is a deferred disclosure.
#
# A VAGUE reason fails too, and the minimum length is the whole mechanism. The
# failure mode this rule exists to prevent is not "someone forgot" — it is
# "someone typed `false positive` and moved on", and a presence check accepts
# that without noticing. 40 characters is short enough that every honest reason
# clears it and long enough that every non-reason does not.
MIN_REASON = 40
allowlists = doc.get("allowlists") or []
if not isinstance(allowlists, list):
    problems.append(f"{rel}: `allowlists` is not a list of tables")
    allowlists = []

for i, entry in enumerate(allowlists, 1):
    desc = (entry or {}).get("description") or ""
    if not desc.strip():
        problems.append(
            f"{rel}: allowlist entry #{i} has no description. Every entry is a "
            f"decision to accept that a scanner will keep reporting something, and "
            f"the decision needs a name on it — otherwise the next reader cannot "
            f"tell an accepted false positive from an accepted secret"
        )
    elif len(desc.strip()) < MIN_REASON:
        problems.append(
            f"{rel}: allowlist entry #{i} has a description of {len(desc.strip())} "
            f"characters, which is not a reason. State what is allowed AND why, in "
            f"at least {MIN_REASON} characters. `false positive` is not a reason: "
            f"it is the absence of one, and a presence check accepts it silently"
        )
    # An entry with nothing to allowlist is a no-op that reads like a decision.
    has_scope = any(
        entry.get(k) for k in ("paths", "pathsRegex", "regexes", "commits", "stopwords", "targetRules")
    )
    if not has_scope:
        problems.append(
            f"{rel}: allowlist entry #{i} has a description but no paths, "
            f"regexes, commits or stopwords — it allows nothing and says why, "
            f"which is the shape of a comment that will be mistaken for a rule"
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check "$GITLEAKS_CONFIG  (allowlist only, every entry reasoned)" gitleaks_config

  # R3's other half: an allowlist that also exists inline is an allowlist
  # nobody reviews. gitleaks takes `-i <file>`, and .gitleaksignore is the file
  # it reads. Neither may exist in the tree, because a scanner finding in a
  # throwaway copy would be silenced by a file the reviewer never saw.
  gitleaks_ignore_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import sys

root = sys.argv[1]
found = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in (".git", ".venv", "__pycache__")]
    for name in filenames:
        if name == ".gitleaksignore":
            found.append(os.path.relpath(os.path.join(dirpath, name), root))
if found:
    sys.exit(
        f"a .gitleaksignore exists at {found}. That is the inline allowlist: it "
        f"lives beside the scanner rather than in {os.path.basename(sys.argv[0])}'s "
        f"committed config, so it is invisible in review, unversioned, and gone the "
        f"next time someone runs the scanner by hand. Entries go in the committed "
        f"config, one per finding, each with a reason"
    )
PY
  }
  check 'no .gitleaksignore  (the allowlist is the committed config)' gitleaks_ignore_check

  # R1: --redact is load-bearing, and so is the scan's coverage.
  #
  # Asserted on the SOURCE of the scan script rather than on the workflow,
  # because the workflow does not contain the gitleaks command line — it calls
  # tests/gitleaks_gate.sh, which is the same script this gate runs. Asserting
  # on the workflow would be asserting that a comment mentions a flag.
  #
  # The check is that the flag is UNCONDITIONAL. A `--redact` that appears
  # inside an `if`, or behind a variable that a caller can set, is not
  # redaction; it is a default.
  # R1: --redact is load-bearing, and so is the scan's coverage.
  #
  # Asserted by EXECUTING the scan, not by reading it.
  #
  # The first version of this check grepped the script for `--redact`, and the
  # first version of that grep was defeated by a comment: `#   - --redact, always`
  # satisfies `grep -- --redact`, and the comment is a sentence explaining that
  # the flag is mandatory. A check that a comment satisfies is a check that
  # reports the comment. Self_test breakage 43 proved it — the flag removed, the
  # check still green — which is the only reason this is a behavioural assertion.
  #
  # So: run the scan against a tree that contains a detectable credential, and
  # read the OUTPUT. `--redact` is proven by the output not containing the secret
  # even though the scan found it.
  #
  # This is the reason the probe below is assembled from parts rather than
  # written out. The scan runs over the whole tree, and a probe committed as a
  # literal would make tests/validate.sh itself a gitleaks finding — so the real
  # tree's own scan goes red for a reason that has nothing to do with the tree.
  # That is not hypothetical: it is what happened the first time, and the gate
  # reported four leaks in the file that was planting them.
  probe_secret() {
    # GitLab's published PAT format sample — gitleaks' `gitlab-pat` rule, and a
    # documented example value rather than a live credential. Assembled from two
    # halves, neither of which is a credential on its own.
    printf 'glpat-%s' 'ABC123def456GHI789jkl012'
  }

  scan_behaviour_check() {
    "$PY" - "$ROOT" "$GITLEAKS_GATE" "${GITLEAKS_BIN:-}" <<'PY'
import os
import subprocess
import sys
import tempfile

root, gate, gitleaks = sys.argv[1], sys.argv[2], sys.argv[3]
problems = []

if not gitleaks or not os.access(gitleaks, os.X_OK):
    # Resolved above; reported there as its own FAIL. Nothing to add here, and
    # saying so is better than a second message about the same missing file.
    sys.exit(0)

work = tempfile.mkdtemp(prefix="kit-redact-")
try:
    # A throwaway git repository, because the history requirement needs one and a
    # directory scan would not exercise the same code path.
    def run(*cmd, **kw):
        return subprocess.run(cmd, capture_output=True, text=True, **kw)

    run("git", "init", "-q", work)
    run("git", "-C", work, "config", "user.email", "t@example.invalid")
    run("git", "-C", work, "config", "user.name", "t")

    secret = "glpat-" + "ABC123def456GHI789jkl012"
    with open(os.path.join(work, "config.toml"), "w", encoding="utf-8") as fh:
        fh.write('private_token = "%s"\n' % secret)
    run("git", "-C", work, "add", "-A")
    run("git", "-C", work, "commit", "-qm", "add")

    # The scan, exactly as the gate runs it, plus --verbose.
    #
    # --verbose is here for one reason: gitleaks names the rule that fired only
    # in verbose output, and a check that cannot say WHICH rule fired cannot
    # distinguish "the scanner works" from "the scanner failed for a reason
    # nobody has diagnosed yet". It is also the more dangerous output — verbose
    # prints the finding, the fingerprint and the entropy — so it is the right
    # place to prove that --redact holds when there is the most to redact.
    def scan():
        return run(
            "bash", os.path.join(root, gate), work, gitleaks, "--verbose"
        )

    res = scan()
    combined = res.stdout + res.stderr

    # 1. It must FIND the secret. Without this, everything below is vacuous: a
    #    scanner that finds nothing would pass a redaction assertion.
    if res.returncode == 0:
        problems.append(
            "the scan over a tree containing a GitLab-PAT-shaped string exited 0, "
            "so it did not detect it. The redaction assertions below would then be "
            "satisfied by a scanner that scans nothing"
        )
    if "gitlab-pat" not in combined:
        problems.append(
            "the scan exited non-zero but did not name the gitlab-pat rule. A scan "
            "that fails for an unstated reason is a scan whose next failure will be "
            "a mystery"
        )

    # 2. It must NOT PRINT it. This is the property. The exit code says the
    #    secret was found; the absence of the secret from the output says the
    #    report is safe to paste into an issue.
    if secret in combined:
        problems.append(
            "THE SCAN PRINTED THE SECRET IT FOUND. --redact is not being applied: "
            "a CI log is a place secrets go to be read, and the scanner finding a "
            "credential must never be the reason the credential is printed. The "
            "value is a format sample, not a live credential, so this run proves "
            "the mechanism and not a disclosure"
        )
    # And the verbose output specifically, which is where gitleaks prints the
    # finding and the fingerprint and would print the value if redaction were off.
    if "Secret:" in combined and "REDACTED" not in combined:
        problems.append(
            "the verbose scan printed a `Secret:` line with no REDACTED marker on "
            "it. --redact is meant to replace the value, not merely suppress the "
            "summary line"
        )

    # 3. It must read the FULL HISTORY. A secret that was committed and then
    #    deleted is the case that matters, and it is invisible to a HEAD-only or
    #    shallow scan.
    os.remove(os.path.join(work, "config.toml"))
    run("git", "-C", work, "add", "-A")
    run("git", "-C", work, "commit", "-qm", "remove")
    res = scan()
    combined = res.stdout + res.stderr
    if res.returncode == 0:
        problems.append(
            "after the credential was committed and then DELETED, the scan exited "
            "0. It is not reading history, or is reading only the last commit. A "
            "secret that was added and removed in one PR is still in the history "
            "and still on every fork — that is the finding that matters most"
        )
    if secret in combined:
        problems.append("the history scan printed the secret it found; --redact is not applied")
finally:
    subprocess.run(["rm", "-rf", work], capture_output=True)

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check "$GITLEAKS_GATE  (finds a real secret, never prints it, reads history)" \
    scan_behaviour_check

  # R2: `pull_request`, never `pull_request_target`.
  #
  # The trigger, not the prose. This reads the PARSED trigger keys of every
  # workflow in the tree, so the explanation in the header comment — which has
  # to exist, and which names the string — is not a violation. A grep would fail
  # on the file that documents why the thing is forbidden, which is how a check
  # gets deleted.
  #
  # The whole tree is read, not just the reusable workflow: kit's own ci.yml
  # chooses its triggers, and a service adopting kit writes its own caller. A
  # job is one click from being a credential-theft primitive, and the trigger is
  # the only thing that makes it one.
  trigger_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import sys

import yaml

root = sys.argv[1]
# `pull_request_target` runs in the context of the BASE repository, with that
# repository's secrets and a writable token, executing code proposed by a FORK.
# `workflow_run` and `issue_comment` have the same property for the same reason.
FORBIDDEN = {
    "pull_request_target": (
        "runs with the base repository's secrets and a writable token in the "
        "context of a FORK's code. Any job under it is a credential-theft "
        "primitive waiting for a reason, and the secret scanner is the job that "
        "most invites 'let me just pull the base branch in so the scan sees the "
        "real history'"
    ),
    "workflow_run": (
        "runs with the base repository's secrets, triggered by a run a FORK can "
        "cause. Same property as pull_request_target"
    ),
    "issue_comment": (
        "runs with repository secrets on an attacker-controlled payload — a "
        "comment body is not code, but it is input, and issue_comment handlers "
        "read it"
    ),
}

problems = []
workflows = os.path.join(root, ".github", "workflows")
if not os.path.isdir(workflows):
    problems.append("no .github/workflows directory, so no trigger was checked")

for name in sorted(os.listdir(workflows)) if os.path.isdir(workflows) else []:
    if not name.endswith((".yml", ".yaml")):
        continue
    rel = f".github/workflows/{name}"
    with open(os.path.join(workflows, name), encoding="utf-8") as fh:
        try:
            doc = yaml.safe_load(fh)
        except Exception as exc:
            problems.append(f"{rel} is not valid YAML: {exc}")
            continue
    if not isinstance(doc, dict):
        continue
    # `on:` is read by PyYAML 1.1 as the boolean True.
    triggers = doc.get("on") or doc.get(True) or {}
    if isinstance(triggers, str):
        found = {triggers}
    elif isinstance(triggers, list):
        found = set(triggers)
    elif isinstance(triggers, dict):
        found = set(triggers)
    else:
        found = set()
    for trigger in sorted(found & FORBIDDEN.keys()):
        problems.append(f"{rel} declares `on: {trigger}`. {FORBIDDEN[trigger]}")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check '.github/workflows/*  (no dangerous trigger, on parsed keys)' trigger_check

  # R4: unpinned-uses is recorded, never baselined.
  #
  # The finding is real, the trade is real, and the costed options are in
  # DECISIONS.md under MD10. What must NOT happen is the trade being made
  # invisibly, in a file that looks like routine configuration — which is what
  # adding it to zizmor's ignore list would be.
  #
  # So: zizmor's config must not ignore or disable it, and must not disable
  # audits wholesale. `tests/zizmor_gate.sh` counts it instead, and prints the
  # count on every run.
  unpinned_check() {
    "$PY" - "$ROOT" "$ZIZMOR_CONFIG" <<'PY'
import os
import sys

import yaml

root, rel = sys.argv[1], sys.argv[2]
path = os.path.join(root, rel)
problems = []

if not os.path.isfile(path):
    # Absent is the preferred state, and is asserted as one below.
    print(f"note: no {rel}; nothing is baselined, which is the correct state")
    sys.exit(0)

with open(path, encoding="utf-8") as fh:
    try:
        doc = yaml.safe_load(fh)
    except Exception as exc:
        sys.exit(f"{rel} is not valid YAML: {exc}")

rules = (doc or {}).get("rules") or {}
rule = rules.get("unpinned-uses") or {}
if rule.get("disable") is True:
    problems.append(
        f"{rel} DISABLES unpinned-uses. The trade it would be suppressing is real "
        f"and is costed in DECISIONS.md under MD10 — pinning thirteen repositories "
        f"to SHAs and owning the bump is not free, and not pinning means a change "
        f"to kit's workflow lands in six services' CI without review. Suppressing "
        f"it HERE makes that trade invisibly, in a file whose only other purpose "
        f"is a different trade. Record it instead: tests/zizmor_gate.sh counts "
        f"and prints every unpinned-uses finding on every run"
    )
if rule.get("ignore"):
    problems.append(
        f"{rel} IGNORES specific unpinned-uses findings ({rule['ignore']}). Same "
        f"reason as above: a per-line allowlist for this audit is a baseline with "
        f"a diff, and a diff is easier to extend than a decision is to revisit"
    )

# A blanket baseline is the thing that turns a scanner into a report. Three of
# them, because a blanket can be spelled three ways.
for audit, conf in (rules or {}).items():
    if not isinstance(conf, dict):
        continue
    if conf.get("ignore") == "*" or conf.get("ignore") == ["*"]:
        problems.append(
            f"{rel}: rule {audit} ignores `*`. A blanket baseline means the audit "
            f"can never report anything again, which is not a stricter check — it "
            f"is the absence of one"
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check "$ZIZMOR_CONFIG  (unpinned-uses recorded, never baselined)" unpinned_check

  # Every zizmor ignore entry carries a reason.
  #
  # zizmor's own ignore syntax is `file.yml[:line[:column]]` with no place for a
  # reason, so the reason lives in an adjacent comment and this check is what
  # makes that a rule rather than a convention. A baseline with no reason is how a
  # scanner becomes a report one commit at a time.
  zizmor_reason_check() {
    "$PY" - "$ROOT" "$ZIZMOR_CONFIG" <<'PY'
import os
import re
import sys

root, rel = sys.argv[1], sys.argv[2]
path = os.path.join(root, rel)
if not os.path.isfile(path):
    sys.exit(0)

lines = open(path, encoding="utf-8").read().splitlines()
problems = []

# A list item under a `rules.<id>.ignore:` block.
in_ignore = False
item_indent = None
for i, line in enumerate(lines, 1):
    stripped = line.strip()
    if re.match(r"^ignore:\s*$", stripped):
        in_ignore = True
        continue
    if in_ignore:
        if not stripped or stripped.startswith("#"):
            # A comment is the reason, or part of it. Looked at below, not here.
            continue
        if stripped.startswith("- "):
            indent = len(line) - len(line.lstrip())
            if item_indent is None:
                item_indent = indent
            if indent != item_indent:
                # Dedented out of the list.
                in_ignore = False
                continue
            # Does this entry have a reason? Any of: a comment on the same line,
            # or one or more comment lines directly above with nothing between.
            above = []
            j = i - 2
            while j >= 0:
                prev = lines[j].strip()
                if not prev:
                    break
                if not prev.startswith("#"):
                    break
                above.append(prev)
                j -= 1
            if "#" in line.split("- ", 1)[1]:
                continue  # trailing comment
            if not above:
                problems.append(
                    f"{rel}:{i}: ignore entry {stripped!r} has no reason. A "
                    f"baseline with no stated reason is how a scanner becomes a "
                    f"report one commit at a time: the next reader cannot tell an "
                    f"accepted false positive from a deferred one"
                )
        else:
            in_ignore = False

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check "$ZIZMOR_CONFIG  (every ignore entry carries a reason)" zizmor_reason_check

  # The scanner itself, executed over kit's own tree and full history. The
  # behaviour is asserted by the check above; this is the real scan of the real
  # repository, which is the only one that can report a secret that is actually
  # in this repository's history.
  if [ -n "$GITLEAKS_BIN" ]; then
    if out=$(bash "$ROOT/$GITLEAKS_GATE" "$ROOT" "$GITLEAKS_BIN" 2>&1); then
      report PASS "gitleaks  ($KIT_GITLEAKS_VERSION, full history, --redact)"
    else
      report FAIL "gitleaks  ($KIT_GITLEAKS_VERSION, full history, --redact)"
      printf '%s\n' "$out" | sed 's/^/       /'
    fi
  fi

  # -------------------------------------------------------------------------
  # The canary harness: the artifacts, and the contract they implement.
  section 'static: the canary harness — contract, adapter, and every artifact'
  secrets_readme_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
problems = []

# The contract. Language-neutral and in the tree, because a canary test that
# only exists for Go protects one of six services — so the thing every adapter
# must implement is kit's to own, and it is a document rather than an
# implementation.
contract = os.path.join(root, "templates", "secrets", "README.md")
if not os.path.isfile(contract):
    problems.append(
        "templates/secrets/README.md does not exist. The contract is language-"
        "neutral on purpose: without it there is nothing for a second adapter to "
        "implement, and six adapters invent six different checks"
    )
else:
    body = open(contract, encoding="utf-8").read()
    # All five vectors, named. Not "at least five" — the names are the contract,
    # and a rename that left one behind would otherwise be invisible.
    for vector in (
        "canary",
        "unknown-field",
        "stringified-error",
        "absent-field",
        "type coverage",
    ):
        if vector not in body:
            problems.append(f"templates/secrets/README.md does not name the {vector!r} vector")

    # The safety property. A canary that is not safe to commit is worse than no
    # canary, so the contract has to say how this one is safe — and the reason is
    # not "it is obviously fake", it is that the value is BUILT.
    if "cafaye_canary_" not in body:
        problems.append(
            "templates/secrets/README.md never states the canary prefix, so a "
            "reader cannot tell a planted canary from a real credential in a log"
        )
    if "assembled" not in body and "built at run time" not in body:
        problems.append(
            "templates/secrets/README.md does not say the canary is assembled at "
            "run time. That is the property that makes it safe to commit, and it "
            "is the reason .gitleaks.toml needs no entry for it"
        )

    # The honesty requirement. A harness whose limits are undocumented is a
    # harness whose limits are discovered in production.
    for phrase, why in (
        ("not covered", "a harness that does not say what it cannot see"),
        ("type check, not a call-graph check", "vector 5's real limitation"),
    ):
        if phrase not in body.lower():
            problems.append(
                f"templates/secrets/README.md does not say {why!r} "
                f"(looked for {phrase!r})"
            )

# The Go adapter's artifacts. Presence only — the suite is EXECUTED in the
# telemetry phase below, which is the check that can catch a broken one.
go_dir = os.path.join(root, "templates", "secrets", "go")
for rel in (
    "canary.go",
    "sweep.go",
    "typecover.go",
    "canary_test.go",
    "typecover_test.go",
    "print_shape_test.go",
    "go.mod",
    "README.md",
    os.path.join("internal", "safe", "creds.go"),
    os.path.join("internal", "leaky", "creds.go"),
):
    if not os.path.isfile(os.path.join(go_dir, rel)):
        problems.append(f"templates/secrets/go/{rel} is missing")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/secrets  (contract names all five vectors, states its limits)' \
    secrets_readme_check

  # The canary itself, asserted from OUTSIDE the Go suite as well as inside it.
  #
  # Two checks of one property is not redundancy here: the Go suite proves the
  # value is not committed as a literal *in the template*, and this proves it is
  # not committed as a literal *anywhere in the tree*, which is the property the
  # scanner depends on. A future file outside the template is exactly where it
  # would appear.
  canary_literal_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import sys

root = sys.argv[1]

# The same assembly the Go adapter performs, reproduced here rather than
# imported. If the two ever disagree, one of them is wrong and the gate says so
# instead of a canary being half-planted in CI and half in the gate.
prefix = "cafaye_canary_"
body = "notarealsecret"
canary = prefix + (body * 3)[:32]

hits = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in (".git", ".venv", "__pycache__")]
    for name in filenames:
        full = os.path.join(dirpath, name)
        rel = os.path.relpath(full, root)
        try:
            with open(full, encoding="utf-8") as fh:
                body_text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
        if canary in body_text:
            hits.append(rel)

if hits:
    sys.exit(
        f"the assembled canary appears as a literal in {hits}. Build it, do not "
        f"write it: a committed credential-shaped string is a finding every "
        f"scanner in the world will make, and allowlisting it teaches the next "
        f"reader that allowlisting a credential is normal. The Go suite asserts "
        f"the same property for templates/secrets/go; this catches it anywhere "
        f"else in the tree"
    )
PY
  }
  check 'the canary  (never committed as a literal, anywhere)' canary_literal_check

  # The canary is safe to commit, which means it must never be a plausible real
  # credential. The prefix is the first half of that; this is the second, and it
  # is checked against the scanner itself rather than against a regex: if
  # gitleaks does not flag it, it is not a plausible real credential as far as
  # anything in this repository is concerned.
  canary_safety_check() {
    "$PY" - "$ROOT" "$KIT_GITLEAKS_VERSION" <<'PY'
import sys

version = sys.argv[1]
prefix = "cafaye_canary_"
canary = prefix + ("notarealsecret" * 3)[:32]

# Structural properties, asserted here because they are properties of the VALUE
# rather than of any Go code, and the gate should not have to run Go to know
# whether the thing it is sweeping for is safe to commit.
if not canary.startswith(prefix):
    sys.exit("the canary does not carry its prefix")
if len(canary) != len(prefix) + 32:
    sys.exit(f"the canary is {len(canary)} bytes; the contract says prefix + 32")
if "notarealsecret" not in canary:
    sys.exit(
        "the canary has no human-readable 'this is fake' component. A value that "
        "merely LOOKS random is one a reader mistakes for a real credential"
    )

# The shape a real credential does not have, and the one thing that would make
# this dangerous: high entropy. A real 32-byte token is indistinguishable from
# random; this is 32 bytes of one repeated word, which no real token ever is and
# which no entropy-based detector will ever score.
# The property that makes it safe to commit: the body is ONE REPEATED WORD.
#
# Not "low entropy" — an entropy THRESHOLD is the wrong instrument, and the
# first version of this check used one (8 distinct bytes) and failed on its own
# canary, which has 9. A threshold is also a number somebody will tune upwards
# the first time it is inconvenient, and a fake credential tuned to pass an
# entropy filter is not a fake credential.
#
# The property is structural and there is nothing to tune: the body must BE the
# repeated word, so no detector that scores entropy can score it as random, and
# so it is obvious to a human reading a CI log at 3am.
body_expected = ("notarealsecret" * 3)[:32]
if canary[len(prefix):] != body_expected:
    sys.exit(
        "the canary body is not the repeated word the contract specifies, so it "
        "is no longer unmistakably fake. A high-entropy canary is "
        "indistinguishable from a real credential to any detector that scores "
        "entropy, which is most of them"
    )
print(f"gitleaks {version}: the canary is prefixed, low-entropy, and self-describing")
PY
  }
  check 'the canary  (unmistakably fake: prefixed, low-entropy, self-describing)' \
    canary_safety_check

  # The gate's own output, swept for the canary.
  #
  # Not paranoia: it happened. `TestTheReferenceTypeLeaksUnderBadVerbs` logs an
  # example of what a leaking format verb produces, and the example contained the
  # canary — on every green run, in the line that exists to document a leak. It
  # is the fake canary, so nothing was disclosed, and that is exactly why it
  # needs a check: the day this harness is pointed at a real credential, the same
  # habit is a disclosure, and a habit is what survives a refactor.
  #
  # The check runs the canary suite, captures EVERYTHING it writes — stdout and
  # stderr, pass and fail — and asserts the value is in none of it. It is a
  # separate check from the suite's own rather than a line inside it because the
  # suite cannot observe its own output: `go test` buffers it.
  canary_output_check() {
    local out ec=0
    if ! have go; then
      echo "go is not installed, so there is no output to sweep" >&2
      return 1
    fi
    out="$(cd "$ROOT/templates/secrets/go" &&
      GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local go test -v -count=1 ./... 2>&1)" || ec=$?

    local needle
    needle="$("$PY" -c '
prefix = "cafaye_canary_"
print(prefix + ("notarealsecret" * 3)[:32])
')"
    if [ -n "$needle" ] && printf '%s\n' "$out" | grep -qF -- "$needle"; then
      echo "the canary suite printed the value it planted. The harness must never print the" >&2
      echo "thing it is sweeping for: a report of a leak that carries the leak is a leak." >&2
      echo "The offending lines, with the value redacted:" >&2
      printf '%s\n' "$out" | grep -F -- "$needle" |
        sed "s|$needle|cafaye_canary_REDACTED|g" | sed 's/^/  /' >&2
      return 1
    fi

    # The suite's own status, restated. Running it twice is cheap (stdlib, no
    # network) and the alternative is a check that passes because the suite
    # crashed before producing output — which is a check that cannot fail.
    if [ "$ec" -ne 0 ]; then
      printf '%s\n' "$out" | tail -20 | sed 's/^/       /' >&2
      return 1
    fi
    return 0
  }
  check 'the canary suite  (never prints the value it planted)' canary_output_check
fi

# ===========================================================================
# phase: telemetry — execute the traceparent templates
# ===========================================================================

kit_phase "20 telemetry: the six traceparent suites, executed"
if [ "$RUN_TELEMETRY" -eq 1 ]; then
  # Formatting is part of the template: a service that copies a template
  # formatted differently from its neighbours is a template that reads as ours.
  #
  # BOTH Go template trees, not just otel's. The tier tree was added without
  # this, and `gofmt -d` on it wanted a `#` on every ALL-CAPS doc heading — Go
  # 1.19 reformatted doc comments, and a heading without the marker is one
  # gofmt rewrites. It was found by running gofmt over the new files by hand,
  # which is the part that was actually wrong: a new template tree that no
  # existing check reads is a tree that can be malformed in silence, and the
  # house rule is that a new file type gets its parser in the same commit.
  if have gofmt; then
    for tree in otel tier; do
      if [ -z "$(gofmt -l "$ROOT"/templates/"$tree"/go/*.go 2>&1)" ]; then
        report PASS "templates/$tree/go/*.go  (gofmt clean)"
      else
        report FAIL "templates/$tree/go/*.go  (gofmt clean)"
        gofmt -l "$ROOT"/templates/"$tree"/go/*.go | sed 's/^/       /'
      fi
    done
  else
    report SKIP 'gofmt (not installed)'
  fi

  section 'telemetry: W3C traceparent propagation, executed'

  # -------------------------------------------------------------------------
  # The toolchain floor, checked BEFORE any suite runs.
  #
  # Written because of what this phase did on a machine with a system Ruby
  # 2.6.10 on PATH: the suite ran, three tests raised `NoMethodError: undefined
  # method 'filter_map'`, and the summary said
  #
  #     FAIL templates/otel/ruby  (ruby test suite)
  #
  # which is a false accusation. Nothing is wrong with the template. The
  # interpreter on PATH was older than the one construct the template uses, and
  # `Array#filter_map` is a RUNTIME call, so the failure arrives as a stack
  # trace from inside a helper rather than as a refusal to run. Every other
  # language here fails loudly on its own — go's go.mod plus GOTOOLCHAIN=local,
  # rustc's --edition, python's `from __future__ import annotations` — so this
  # was the only one that could report a wrong answer instead of no answer.
  #
  # The floor is a FEATURE PROBE, not a version number, and that is the whole
  # design. A literal like `2.7` in this file is a claim about the template
  # that nothing checks: raise the template's floor and the claim rots; the
  # probe is derived from the same call the suite makes, so the two cannot
  # disagree. It is a probe rather than a version comparison because the
  # interesting question is not "how old is this ruby" but "can it run the code
  # we ship" — which is answerable exactly, and which a version string can only
  # approximate.
  #
  # FAIL, not SKIP. A too-old interpreter is not an absent one: the suite is
  # installed, the code is here, and the check is genuinely unrun. Reporting
  # SKIP would make the gate green having verified nothing about ruby — the
  # "a gate that skips is not green" rule, and the direction this repo's own
  # fail-closed discipline points. An ABSENT toolchain is still a SKIP: that is
  # an environment without the language, not a broken one.
  toolchain_floor_ruby() {
    ruby -e 'exit(Array.method_defined?(:filter_map) ? 0 : 1)' 2>/dev/null
  }

  # Each language is one command. Everything is stdlib-only and offline: no
  # `go mod download`, no bundle install, no npm ci, no cargo fetch. If these
  # ever need the network the template has grown a dependency and kit has
  # stopped being config-only.
  run_go() {
    (
      cd "$ROOT/templates/otel/go"
      GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local go test ./...
    )
  }
  run_ruby() {
    ruby "$ROOT/templates/otel/ruby/test_traceparent.rb"
  }

  run_elixir() {
    # -r the module first: mix is not involved, so ExUnit.start() lives in the
    # test file and there is no mix.exs to grow.
    elixir -r "$ROOT/templates/otel/elixir/traceparent.ex" \
      "$ROOT/templates/otel/elixir/test_traceparent.exs"
  }
  run_python() {
    python3 "$ROOT/templates/otel/python/test_traceparent.py"
  }
  run_node() {
    node --test "$ROOT/templates/otel/node/traceparent.test.mjs"
  }
  run_rust() {
    rustc --test --edition 2021 -o "$TMP/kit-otel-rust" \
      "$ROOT/templates/otel/rust/traceparent.rs"
    "$TMP/kit-otel-rust"
  }

  # `set -u` treats an empty array expansion as an error, and no --language
  # argument is the normal case (run everything). Declare it non-empty-safe.
  wanted() {
    [ "${#LANGS[@]}" -eq 0 ] && return 0
    for want in "${LANGS[@]}"; do
      [ "$want" = "$1" ] && return 0
    done
    return 1
  }

  for lang in go ruby elixir python node rust; do
    wanted "$lang" || continue
    case "$lang" in
      go) tool=go ;;
      ruby) tool=ruby ;;
      elixir) tool=elixir ;;
      python) tool=python3 ;;
      node) tool=node ;;
      rust) tool=rustc ;;
    esac
    if ! have "$tool"; then
      report SKIP "templates/otel/$lang  ($tool not installed)"
      continue
    fi
    # ruby only, because ruby is the only one of the six that can fail
    # *silently*: the other five refuse on their own — an old go, an old node
    # or an old rustc fails at build time with a message naming its own
    # requirement — whereas ruby 2.6 loads this template happily and then dies
    # on the first method call, which reads as a behavioural failure. A floor
    # check for a toolchain that already refuses would be a second place to be
    # wrong.
    if [ "$lang" = ruby ]; then
      ruby_seen="$(ruby -e 'print RUBY_VERSION' 2>/dev/null || true)"
      ruby_need="$(ruby_floor || true)"
      if [ -z "$ruby_need" ]; then
        # The template could not be loaded far enough to be asked. That is a
        # defect in the artifact, not an absent interpreter, so it is a FAIL.
        report FAIL "templates/otel/$lang  ($tool test suite)"
        printf '%s\n' \
          "       Could not read KitOtel::RUBY_FLOOR from" \
          "       templates/otel/ruby/traceparent.rb, so the interpreter floor" \
          "       is unknown and the suite cannot be run knowingly. This is a" \
          "       template defect: the constant is how the gate asks the" \
          "       template what interpreter it needs."
        continue
      fi
      if ! version_at_least "$ruby_seen" "$ruby_need"; then
        # A SKIP, not a FAIL, and the distinction is the whole point of this
        # check. The template is correct; the interpreter is too old to run it.
        # Reporting that as a FAIL would keep three landed-or-landing packets
        # blocked by a red that names a file none of them touched. Reporting it
        # as a PASS would be worse — it would claim the suite passed having
        # never run a single test. So: a loud, counted SKIP that names both
        # versions and the one command that fixes it, which is exactly the
        # treatment every other absent toolchain in this file already gets.
        report SKIP "templates/otel/$lang  (ruby $ruby_seen is below the template's $ruby_need floor)"
        printf '%s\n' \
          "       templates/otel/ruby declares KitOtel::RUBY_FLOOR = $ruby_need and the" \
          "       ruby first on PATH is $ruby_seen, so the suite did NOT run. On a" \
          "       conforming interpreter it is green; this is a toolchain fact wearing" \
          "       a template's clothes, not a finding about trace propagation." \
          "       Fix: put a pinned ruby first on PATH — mise exec -- bash tests/validate.sh," \
          "       or any PATH whose ruby is >= $ruby_need. kit's own pin is templates/mise.toml (3.4)."
        continue
      fi
    fi
    check "templates/otel/$lang  ($tool test suite)" "run_$lang"
  done

  # -------------------------------------------------------------------------
  # The canary harness, EXECUTED.
  #
  # Same reasoning as the traceparent suites above, and it is the reason this is
  # in the telemetry phase rather than only in the static one: a canary harness
  # that is only grepped is a harness that has never run a detector.
  #
  # `-v` is not decoration. Every vector prints a RED PROOF line, and a proof
  # nobody can see is a proof nobody ran — the same argument the self_test phase
  # makes, applied to the harness instead of to the gate.
  section 'telemetry: runtime credential-leak canary, executed'

  run_canary() {
    (
      cd "$ROOT/templates/secrets/go"
      GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local go test -v -count=1 ./...
    )
  }
  if have gofmt; then
    if [ -z "$(gofmt -l "$ROOT"/templates/secrets/go/*.go "$ROOT"/templates/secrets/go/internal/*/*.go 2>&1)" ]; then
      report PASS 'templates/secrets/go/*.go  (gofmt clean)'
    else
      report FAIL 'templates/secrets/go/*.go  (gofmt clean)'
      gofmt -l "$ROOT"/templates/secrets/go/*.go "$ROOT"/templates/secrets/go/internal/*/*.go | sed 's/^/       /'
    fi
  else
    report SKIP 'gofmt (not installed)'
  fi

  if have go; then
    # `check_verbose`, not `check`: the five RED PROOF lines are the evidence
    # that each detector fired. On a green run they are the ONLY output, and a
    # gate that proves the gate can fail while hiding the proofs is making the
    # argument in one file and breaking it in the next.
    check_verbose 'templates/secrets/go  (five vectors, each with a red proof)' \
      'RED PROOF|known and accepted' run_canary
  else
    report SKIP 'templates/secrets/go  (go not installed)'
  fi
fi

# ===========================================================================
# phase: observability — the two proofs that need a real collector
# ===========================================================================

kit_phase "30 observability: the claims worth nothing unexercised"
if [ "$RUN_OBSERVABILITY" -eq 1 ]; then
  section 'observability: the redaction boundary, against a real collector'

  # Not skippable by preference. A dev machine with no docker gets a reported
  # SKIP, because the alternative — running the suite and reporting PASS while
  # the security claim went unexercised — is the shape of a proof nobody ran.
  #
  # BOUNDED, each tier with its own. Three docker stacks, eight containers apiece,
  # brought up and torn down in sequence, on a machine that may also be running
  # five other workers' gates. This is the tier the previous full run was
  # SIGKILLed inside, and a kill costs the reader every tier after it — so each
  # of these three carries a bound generous enough for a loaded box and a verdict
  # of its own if it is reached.
  #
  # The numbers are ~3x the quiet-machine durations recorded in REPORT-kit-13.md
  # §7, not a guess: a bound set at the observed quiet duration is a bound that
  # fires on any contention at all, and a bound that fires is a tier that proved
  # nothing. That sentence is also why the fix for contention here was NOT to
  # widen these three: a number widened until it stops firing on a loaded box is
  # a number that has stopped measuring the thing it was written to measure.
  #
  # THE THREE BELOW GO THROUGH `live_check`, and the two cluster tiers after them
  # do not. Measured on this branch (KIT_PROFILE, `--language=ruby
  # --no-self-test`, an otherwise green run): canary 19.1s +
  # no_telemetry_in_readiness 63.6s + stack_live 46.1s = 128.8s of a 255.2s run,
  # against isolation_test 13.5s + tenancy_test 10.4s = 23.9s. So the live tier
  # is 50.5% of that gate run and the cluster tiers are 9.4% of it, which is
  # what makes `--no-live` a subset rather than `--no-observability` a synonym.
  if ! have docker; then
    report SKIP 'observability proofs (docker not installed)'
  elif ! docker info >/dev/null 2>&1; then
    report SKIP 'observability proofs (docker daemon not reachable)'
  else
    live_check 'tests/canary_test.sh  (a canary secret reaches no exporter)' \
      900 bash "$ROOT/tests/canary_test.sh"
    live_check 'tests/no_telemetry_in_readiness.sh  (collector killed, service still serves)' \
      900 bash "$ROOT/tests/no_telemetry_in_readiness.sh"
    # THE STACK, RUN. Every claim in this file about the observability platform
    # being usable is a claim about YAML until this one runs: that the FETCHED
    # stack comes up healthy, that a trace arrives in Tempo, that a metric
    # arrives in Mimir, and that a canary planted in ten attributes reaches
    # neither. `docker compose config` proved a stack that could not start, twice,
    # in this repository's own history — once because the collector's environment
    # block was missing and once because Mimir's healthcheck named a directory.
    live_check 'tests/stack_live_test.sh  (the fetched stack runs; a trace and a metric land)' \
      900 bash "$ROOT/tests/stack_live_test.sh"

    # THE CLUSTER, RUN, AND THE ANSWER IN THE OUTPUT.
    #
    # Every other claim about database-per-service is a claim about a file until
    # this one runs. `docker compose config` is green on a stack whose
    # `REVOKE ALL ON DATABASE ... FROM PUBLIC` is a comment, whose init script
    # provisions two of nine databases, or whose service roles are superusers —
    # and the symptom of all three is a cross-service query that works in
    # development and is a report in production.
    #
    # It is in THIS phase rather than a new one because it is the same kind of
    # claim: a security property that is worth nothing unexercised. And it prints
    # the refused query and the server's answer rather than a summary line,
    # because the evidence is the point — see `bounded_check`'s siblings above
    # for why a proof nobody can see is a proof nobody ran.
    #
    # 1800s, not 900s: this suite builds the cluster image (a pull from ghcr.io
    # on a cold cache), brings the stack up, and then brings a SECOND cluster up
    # for the negative control. Three container lifecycles and two initdb runs.
    bounded_check 'tests/isolation_test.sh  (service A cannot reach service B'"'"'s database)' \
      1800 bash "$ROOT/tests/isolation_test.sh"
    # THE ACCOUNT BOUNDARY, RUN, WITH ITS CONTROL AND ITS MEASUREMENT.
    #
    # In THIS phase rather than a new one because it is the same class of claim: a
    # security property that is worth nothing unexercised. And it carries the one
    # control the whole directory exists for — the same proof with
    # `FORCE ROW LEVEL SECURITY` removed, which must go red on the OWNER half while
    # the LOGIN half stays green. A proof without that control would pass on a
    # substrate with no FORCE at all, which is the exact defect the packet named.
    #
    # 1800s for the same reason as its sibling above: it builds the cluster image,
    # brings the stack up, applies the substrate, and runs the proof three times
    # (once clean, once with the control mutation, once measuring the init plan).
    bounded_check 'tests/tenancy_test.sh  (no identity, another tenant and its own tenant — as the login role AND as the owner; and the same proof with FORCE removed goes red)' \
      1800 bash "$ROOT/tests/tenancy_test.sh"
  fi
fi
# ===========================================================================
# phase: classifier + staleness — the two runnable pieces, executed
#
# Separate from `static` and run unconditionally, because both are the property
# rather than the shape: classify_test asserts that the classifier FAILS on an
# unrecognised change, and staleness_test asserts that the reporter tells
# `current` from `unknown` from `undeclared`. A check that only parses those two
# files would pass on a classifier that waves every change through.
#
# Both scripts build their own fixtures in a temp directory, so neither depends
# on a repository being checked out or on the network.

  # NOTE: deliberately not guarded by RUN_STATIC. kit-05's own comment
  # called these "the property rather than the shape", but the block shipped
  # wrapped in `if [ "$RUN_STATIC" -eq 1 ]`, which would let a static-analysis
  # skip silently drop the fail-closed proof. A gate that skips is not green.
kit_phase "40 classifier + staleness + fetch + tenancy, executed"
check 'tests/classify_test.sh  (19 cases, incl. the fail-closed property)' \
  bash "$ROOT/tests/classify_test.sh"

# THE HARNESS'S OWN SHARDING, and it is here rather than in a comment because the
# property is about the arithmetic in tests/self_test.sh and nothing else in the
# gate can see it. `self_test` runs its recipes in shards when asked to, and it
# shipped computing a 0-based residue against a 1-based shard index -- so shard
# n/n matched nothing, ran nothing, and reported PASS. Four shards as a merge gate
# covered three quarters of the suite and said all four were green.
#
# `tests/shard_test.sh` evaluates the real `_shard_claims` out of self_test.sh
# rather than restating it, so this cannot pass while the function it proves has
# drifted; a second copy of the modulo would be a second thing to be wrong.
#
# Bounded, like the other executed proofs, because it forks once per shard index
# and the largest safe n (62) is 62 of them. Measured ~23s.
check 'tests/fingerprint_test.sh  (the skip is proven able to be WRONG: outputs deleted, one byte changed, a corrupt record, a foreign version)' \
  bash "$ROOT/tests/fingerprint_test.sh"

bounded_check 'tests/shard_test.sh  (the n shards partition the suite, shard n/n included)' \
  300 bash "$ROOT/tests/shard_test.sh"

# The fetch is a claim about a REAL SUBPROCESS talking to a REAL REMOTE, and it is
# the only proof that `bin/dev` can obtain the stack it runs at all. A check that
# parsed bin/dev would pass on a script that fetches nothing, which is why this is
# executed and why its remote is a local bare repository rather than github.com: a
# gate that goes red when the network is down is a gate people learn to re-run
# with --no-observability, and then it is not a gate.
#
# Deliberately OUTSIDE the `RUN_STATIC` guard, for the reason the classifier and
# the staleness reporter are: these are the PROPERTY rather than the shape, and a
# gate that skips is not green.
section 'provenance: the stamp a pulled image carries, and what it refuses to carry'
# P3-18's redaction half, and the reader half of P3-19.
#
# `tests/provenance_test.sh` is EXECUTED rather than grepped, for the same reason
# `tests/multi_tenant_split_test.sh` is: the claim under test is that a shape is
# REFUSED, and only running the stamper can show that. Eleven leak shapes — an
# email, two local paths, an internal hostname, a URL, a relative path, a
# credential, a branch where a commit is claimed, a short sha, uppercase hex, a
# dirty FILE LIST — are each asserted to be refused BY NAME, against a control
# that is green, so a stamper that refused everything would not pass.
#
# It also carries the consumer side, because that is where a stamp stops being
# decorative: a real image is built from the real `docker/Dockerfile.go`, the
# label and the file are compared, and `--verify` is required to exit non-zero on
# a wrong commit and on an unstamped image — as two DIFFERENT codes, because a
# check that returns one code for both cannot tell a consumer which happened.
#
# Outside the `RUN_STATIC` guard: a security claim that a static-analysis skip
# drops is a security claim nobody ran.
check 'tests/provenance_test.sh  (11 leak shapes refused; both sinks agree; --verify refuses a foreign or ill-shaped stamp; 4/5/6 stay distinct)' \
  bash "$ROOT/tests/provenance_test.sh"

section 'fetch: the pinned kit ref resolves, and a moving one is refused'
kit_cached_check 'tests/fetch_test.sh  (a pin fetches, a branch is refused, offline is real)' \
  120 \
  'tests/fetch_test.sh,templates/bin/dev.sh,VERSION' \
  '' \
  bash "$ROOT/tests/fetch_test.sh"

section 'tenancy: how one shared cluster is split into per-service databases'
# ONE CLUSTER, A DATABASE AND A ROLE PER SERVICE is the topology this fleet is
# built around, and until now every check of it exercised exactly ONE service.
# That is not a small gap: it is the difference between proving the promise once
# and proving it for the second name in the list, and the second name is where
# this file's sibling checks had nothing to say.
#
# It is not a static shape check either. It runs the shipped
# `templates/compose/postgres/initdb/10-cluster.sh` with `psql` stubbed, so the
# real parse runs and the real refusals fire, without a container or a volume —
# seconds where the live measurement took a full `bin/dev up`.
#
# Deliberately OUTSIDE the `RUN_STATIC` guard: this is a property of the script,
# not a grep over it, and a gate that skips is not green.
check 'tests/multi_tenant_split_test.sh  (a second tenant is split, not fused; identifiers hold in every locale)' \
  bash "$ROOT/tests/multi_tenant_split_test.sh"

section 'staleness: the fleet reporter tells the states apart'
# The case count is READ OUT OF THE RUN rather than counted in the source, and
# that is not pedantry. Counting `printf 'PASS …'` sites in the file gives 27
# while the suite runs 26, because case 9b has two mutually exclusive branches
# (a worktree that could be created, and the direct `is_worktree()` assertion
# for when it could not). A number derived from the source and a number the
# reader sees in the output then disagree on a green run, which is exactly how a
# count stops meaning anything — the same reason `self_test`'s count is counted
# from recipes and the header/recipe check exists at all.
#
# So the script runs, its own summary line is read, and the label carries what
# the run said. If the two ever drift, this block fails rather than printing a
# number nobody checked.
_stale_out=""
_stale_ec=0
_stale_skip=""
# `--only` skips this tier, and it is the single most expensive thing in the
# gate: 9s of an 18s filtered run, measured. It is written as a bare
# `$(bash ...)` rather than through `check`, because its label has to carry the
# case count it READ OUT of the run -- which is the right call for honesty and
# the wrong call for filterability, because a block that never calls `check` is a
# block `--only` cannot see.
#
# So the filter is applied here explicitly rather than being left to discover
# itself. The gate's whole argument is that a check which cannot be selected is a
# check nobody can skip, and 9 seconds per invocation times ~76 invocations is
# the difference between a suite that finishes and one that does not.
if [ -n "$ONLY_MATCH" ]; then
  _stale_label="tests/staleness_test.sh  (the templates half tells current / diverged / absent apart)"
  case "$_stale_label" in
    *"$ONLY_MATCH"*) ;;
    *)
      ONLY_SKIPPED=$((ONLY_SKIPPED + 1))
      _stale_out=""
      _stale_ec=0
      _stale_skip=1
      ;;
  esac
fi
if [ -z "$_stale_skip" ]; then
_stale_out=$(bash "$ROOT/tests/staleness_test.sh" 2>&1) || _stale_ec=$?
fi
_stale_cases=$(printf '%s\n' "$_stale_out" | sed -nE 's/^PASS: staleness_test — ([0-9]+) case.*/\1/p')
if [ -n "$_stale_skip" ]; then
  # Filtered out, deliberately. Reported as SKIP and never as PASS: this tier
  # ran zero cases, and a reader who sees it green would be reading a claim about
  # a suite that did not execute.
  report SKIP "tests/staleness_test.sh  (excluded by --only)"
elif [ "$_stale_ec" -ne 0 ] || [ -z "$_stale_cases" ]; then
  report FAIL "tests/staleness_test.sh  (the templates half could not report its own case count)"
  printf '%s\n' "$_stale_out" | sed 's/^/       /'
elif [ "$_stale_cases" -lt 20 ]; then
  # A floor, and it exists because this suite's job is to be able to fail: a
  # run that quietly stopped proving the absent case would still exit 0. The
  # number is not the claim — the self-test breakages are — but a suite that
  # lost half its cases is a suite nobody is running any more.
  report FAIL "tests/staleness_test.sh  ($_stale_cases cases; the templates half is no longer covered)"
  printf '%s\n' "$_stale_out" | sed 's/^/       /'
else
  report PASS "tests/staleness_test.sh  ($_stale_cases cases, incl. the red proof and the absent case)"
  printf '%s\n' "$_stale_out" | sed 's/^/       /'
fi

# ===========================================================================
# phase: docker_tier_project_name — one shared namespace per RUN
# ===========================================================================
#
# ITS OWN TOP-LEVEL PHASE, and the placement is the point rather than tidiness.
# It was written first as a check inside the self_test phase, next to
# `self_test_live_tier` and `self_test_no_version_literal` — and therefore inside
# `if [ "$RUN_SELF_TEST" -eq 1 ]`, which `--static-only` sets to 0. So the guard
# did not run in the static phase at all: `bash tests/validate.sh --static-only`
# was green on a tree with a hardcoded project name in it, and 84 of the 93
# recipes in the self-test invoke the gate exactly that way.
#
# This is the failure the self_test phase already records one section above, in
# a comment about `RUN_STATIC`: a property that lives inside a phase's own guard
# is a property that does not hold when the phase is skipped. It is the same shape
# as the one `--no-live` was introduced for, one layer up, and it was found by
# RUNNING the gate and looking for the check in the output rather than by reading
# where the check had been put.
#
# It is a text scan over files in this directory, so it belongs with the static
# checks and nowhere else.

  # A DOCKER TIER MAY NOT HARDCODE A NAME IN A SHARED NAMESPACE.
  #
  # WHY THIS IS A CHECK AND NOT A CONVENTION. A compose project name is the
  # namespace for a stack's containers, networks and volumes; a fixed one means
  # two concurrent runs of kit's own tests are not two stacks but one stack with
  # two owners. `tests/isolation_test.sh` and `tests/tenancy_test.sh` each wrote
  # `kit-isolation` / `kit-tenancy` at two sites apiece and it survived review
  # because nothing about either file looks wrong. Observed on this box rather
  # than argued (reports/compose-collision/): the second run could not bring up a
  # cluster at all, and the first died part way through its assertions with psql's
  # exit code and NO FAIL LINE OF ITS OWN, because the other run's teardown took
  # the project volume out from under it. Through this file's FAIL summary that
  # reads as a database-boundary violation — which is the one claim those two
  # tiers exist to make trustworthy. A copy-paste reintroduces it in one line, and
  # the failure it causes is a red that blames the wrong subsystem, so it is
  # worth a gate rather than a review habit.
  #
  # FOUR NAMESPACES, not one. The packet names only the project name, and fixing
  # only that would have left the same defect wearing three other hats, so each
  # is checked for the same reason and none is checked because it was named:
  #
  #   project    `docker compose -p X` / `--project-name X` — containers,
  #              networks, volumes.
  #   container  `docker run --name X` — `docker rm -f X` takes a bare name and
  #              will delete a container belonging to a different run.
  #   volume     `docker volume rm X` — same, and a leaked volume makes the NEXT
  #              run reuse an already-provisioned cluster, which then fails on an
  #              assertion about state a previous run created.
  #   host port  `KIT_POSTGRES_PORT=N` — worse than the rest, because it collides
  #              with the DEVELOPER'S OWN running stack, not merely with another
  #              test run. Measured while fixing this: deriving the project name
  #              alone left two concurrent runs red on `port is already
  #              allocated`, so the collision had been relocated rather than
  #              fixed.
  #
  # DERIVED, NOT LISTED, twice over — which is the whole design and the reason a
  # sixth tier is covered on the day it lands. (1) The set of docker tiers is
  # every script under tests/ that brings a container up, not an enumeration that
  # can name a script that was renamed. (2) Within a tier, the set of names it
  # OWNS is read out of the assignments that exist, and each is checked against
  # its use sites — so a tier that derives its project but writes its control
  # container literally is caught by the same rule that caught the project.
  # This is the same move as `self_test_live_tier` reading the live set out of
  # `live_check` calls and `self_test_no_version_literal` reading its file set
  # out of the recipes, and for the same reason: a list written down separately
  # is a list that goes stale.
  #
  # EMPTINESS IS A FINDING, as `self_test_no_version_literal` does it. A guard
  # that covers nothing must say so rather than report nothing — a check that
  # silently passes because its pattern stopped matching is worse than no check,
  # because it is a green that costs a reader their trust in the red ones. Four
  # separate emptiness findings, because the four can each fail alone: no tiers
  # found, no names derived, no use sites examined, or a tier that brings a stack
  # up without naming a project at all (compose would then derive one from the
  # working directory, which is its own kind of collision).
  docker_tier_project_name() {
    "$PY" - "$ROOT/tests" <<'PY'
import os
import re
import sys

tests_dir = sys.argv[1]
# `validate.sh` is excluded, and not by an accident of naming: it is this check's
# own source, and this check's rule text contains `docker compose … up` written
# out in prose. Without the exclusion the guard reads its own documentation as a
# tier that brings a stack up without naming a project, and fails itself. A guard
# that trips over the sentence explaining the guard is worse than useless — it
# teaches the reader that the message is noise.
# RECURSIVE, and the recursion is the point. This used to be `os.listdir(tests_dir)`,
# which reads the top level only — so a docker tier placed in a subdirectory was
# not merely unchecked, it was INVISIBLE: it was in neither `tiers` nor
# `uncovered`, so the gate printed a count of tiers that did not include it and
# said nothing about it at all.
# `tests/tenant_isolation/cross_tenant_harness.sh` is that file: it brings a
# container up, derives its container name and its host port from the session,
# and would have carried on doing so with no rule pointed at any of it. The
# finding this whole rule exists for is the same shape one level up — a check
# whose scope is narrower than a reader believes costs its trust in the findings
# it does report.
#
# The paths are RELATIVE to tests/, so the messages name a path a reader can open
# rather than one relative to whatever directory the python happened to run in.
_ti_root = os.path.abspath(tests_dir)
scripts = sorted(
    os.path.relpath(os.path.join(d, f), _ti_root)
    for d, _subdirs, files in os.walk(_ti_root)
    for f in files
    if f.endswith(".sh") and not f.startswith("_") and f != "validate.sh"
)

# (1) THE DOCKER TIERS, derived: a script that brings a container up. A SEARCH
# rather than an anchored match, for the same reason DOCKER_USE is one — the
# bring-up sites are `if ! docker compose … up`, and anchoring at the start of
# the line misses them.
BRING_UP = re.compile(r"\bdocker\s+(?:compose\b.*\bup\b|run\b)")

# …OR BRINGS ONE UP THROUGH A LOCAL WRAPPER, and that second arm is not an
# optimisation. The first version of this rule was BRING_UP alone and it was
# green on a tree carrying the exact defect the check exists to catch:
#
#     tests/canary_test.sh:82  compose() { docker compose -p "$PROJECT" -f "$WORK/compose.yml" "$@"; }
#     tests/canary_test.sh:419 if compose up -d --wait --wait-timeout 120 sender …; then
#
# No single LOGICAL LINE contains both halves. `docker compose` is in the
# wrapper's body; `up` arrives at the call site through `"$@"`. So the file was
# dropped from `tiers` before any of the four rules ran, and nothing in the
# output said so — not even the emptiness finding, which counts tiers and so
# cannot see a tier that was never counted. Measured with the mutation asserted
# BY TEXT: `PROJECT="kit-canary-$$"` → `PROJECT="kit-canary"`, guard exit 0,
# zero findings. reports/wrapper-tier-scope/mutations.sh is the recipe; it
# extracts this guard's own source out of validate.sh on every run, so it cannot
# outlive it.
#
# THE DEFINITION, not the call sites, and that is not a matter of taste. A
# call-site pattern has to know every spelling a pass-through can take
# (`compose up`, `"$COMPOSE" up`, `dc -f x up`, a wrapper three files away), and
# the sixth such idiom in a tree it has never seen is another blind spot. The
# DEFINITION has exactly one shape — a function whose body invokes
# `docker compose` — and it is on the same line as the `docker compose` it is
# hiding. `stack_live_test.sh` is covered by the same arm for the same reason:
# its `tempo_port() { docker compose -p "$PROJECT" port tempo 3200 …; }` is a
# wrapper too.
#
# `[^{}]*` rather than `.*` so the body cannot run past this function's closing
# brace and borrow the next one's `docker`. A wrapper pattern that swallows the
# rest of the file is a pattern that matches more than it means to, and the tier
# it invents is then a tier the four rules will report emptiness findings about.
WRAPPER = re.compile(
    r"^\s*(?:function\s+)?[A-Za-z_][A-Za-z0-9_]*\s*\(\s*\)\s*\{[^{}]*\bdocker\s+compose\b"
)

# A line whose first non-blank character is `#` is a comment. Everything read
# here is CODE: these files explain the rule at length, and a check that fires on
# a comment explaining why a literal is wrong is a check that fires on its own
# documentation — the mistake `self_test_live_tier` records about itself.
def code_lines(path):
    with open(path, encoding="utf-8") as fh:
        raw = fh.read().splitlines()
    return [
        (n, ln)
        for n, ln in enumerate(raw, 1)
        if ln.strip() and not ln.lstrip().startswith("#")
    ]


# A line that INVOKES a docker command, anywhere in it.
#
# Deliberately a SEARCH and not a statement starter. The first version of this
# rule matched `^[ \t]*docker`, and that is wrong in the most expensive way
# available here: the bring-up sites are `if ! docker compose … up`, so the
# anchor never matched them and the guard was blind to precisely the line this
# packet exists to protect. It passed on a tree with `--project-name
# kit-isolation` hardcoded at the bring-up site, and the mutation suite is what
# said so rather than the reading of the code.
#
# The price of searching instead of anchoring is that prose can match, which is
# why COMMENTS ARE STRIPPED FIRST — the comments in these files quote this rule's
# own examples, and a check that fires on the sentence explaining the rule is a
# check that fires on its own documentation.
DOCKER_USE = re.compile(r"\bdocker\s+(?:compose|run|rm|volume|network)\b")

# WHERE A NAMESPACE CAN BE PASSED, which is wider than DOCKER_USE by exactly the
# subcommands the newer rules read. It is used for ONE question only - "is this
# variable handed to docker anywhere in this file" - and NOT for `examined`, which
# stays on DOCKER_USE so the emptiness finding below keeps counting exactly what it
# counted before.
#
# That asymmetry is measured rather than tidiness. With DOCKER_USE as the
# declaration rule's predicate, `GOOD_IMAGE="kit-provenance-test-$$:good"` was not
# fed to docker by the check's own reckoning, because `docker build` is not one of
# DOCKER_USE's five subcommands - so removing the `$$` from it produced no finding,
# and the mutation case written to catch exactly that reported NOT BITTEN. Widening
# `examined` at the same time would have made the emptiness finding harder to fire,
# which is the wrong direction to reach in.
NAMES_IN_DOCKER = re.compile(
    r"\bdocker\s+(?:compose|run|rm|volume|network|build|image|rmi|create|tag)\b"
)

# WHAT A SCRIPT *TOUCHES*, which is a WIDER question than what it brings up, and
# it has to be wider or the emptiness finding below is dead code — a rule whose
# predicate is the tier predicate cannot fire, and a rule that cannot fire is the
# defect this whole packet chain exists to kill wearing a new hat.
#
# The five subcommands DOCKER_USE leaves out are `build`, `image`, `rmi`, `create`
# and `tag`, and every one of them takes a name in a namespace that is shared by
# every concurrent run on the machine. They are here because `tests/
# provenance_test.sh` builds `-t kit-provenance-test:good` and tears it down with
# `docker rmi -f`, and before this rule nothing named that file at all.
#
# `cp` is in the list for the same reason and is the one that costs nothing: it
# names nothing, but a script that reads out of a container is a script whose
# result depends on which run created it.
TOUCHES_DOCKER = re.compile(
    r"\bdocker\s+(?:compose|run|rm|volume|network|build|image|rmi|create|tag|cp)\b"
)

# `docker build -t NAME` / `--tag NAME` names an IMAGE, which is a fifth shared
# namespace and not a sixth spelling of the first four: `docker rmi -f NAME` takes
# a bare name, will delete an image another run is still building against, and
# leaves that run's next assertion failing on a missing image rather than on
# anything it did.
#
# SCOPED TO `docker build` ON PURPOSE. `-t` is also `--tty` to `docker run` and
# `docker exec`, where the value is `true`/`false` and there is no image at all —
# `tests/tenancy_test.sh:211` carries `psql -A -t -F'@'` on a line that also runs
# `docker exec`. A flag taken across every docker subcommand would read that as a
# literal image name, and a check that fires on correct code teaches a reader to
# ignore it.
IMAGE_TAG = re.compile(r"\bdocker\s+build\b[^\n]*?(?:\s-t\s+|\s--tag[=\s]+)(\S+)")

# A COMMAND INSIDE A STRING IS NOT A COMMAND, and this rule is the only one here
# whose pattern can match a whole one.
#
# `tests/deploy_test.sh:456` is `note "  docker build -t cafaye-kit16/courier:35c6a27
# /path/to/courier"` — an example printed to a reader who has no image to hand. It
# is not a comment, so `code_lines` keeps it, and IMAGE_TAG matched the whole
# command inside the string and reported a hardcoded image tag that does not exist
# anywhere. A check that fires on correct code teaches a reader to ignore it, which
# is this repository's own recorded rule about `Naming/PredicateName` and about
# keyword scans over comments, and it is the mistake `self_test_live_tier`
# documents making and then backing out of.
#
# SCOPED TO THIS RULE RATHER THAN APPLIED TO EVERY LOGICAL LINE, and the reason is
# a measurement rather than a preference: DOCKER_USE is a SEARCH whose result feeds
# the `examined` emptiness finding, so destringing the lines it reads would change
# how many use sites a tier appears to have, and that count is itself a check.
# `docker` ITSELF has to lie outside the quoted run — not the command's arguments.
# Blanking the quoted runs first, which was the first attempt, breaks the two lines
# that matter most: `docker build --tag "$IMAGE_BAD"` becomes `docker build --tag
#    ` and the pattern captures the NEXT flag as the image name (`-f`), and a
# `\` continuation swallowed whole reports `-t` with the value `\` on its back. Both
# are findings with a name in them, so both read as real defects and neither is.
# The mask below answers the question the comment actually asks, and the captured
# value is then taken from the UNTOUCHED body, where it is still `"$IMAGE_BAD"`.
QUOTED = re.compile(r'"(?:\\.|[^"\\])*"|\'[^\']*\'')

def outside_quotes(body):
    """One character per character of `body`: '0' inside a quoted run, '1' outside."""
    mask = ["1"] * len(body)
    for m in QUOTED.finditer(body):
        for i in range(m.start(), m.end()):
            mask[i] = "0"
    return "".join(mask)


def command_positions(pattern, body):
    """Every match of `pattern` in `body` whose first character is not inside a
    quoted run. Yielded as the match objects so the caller still reads the value
    out of the original body."""
    mask = outside_quotes(body)
    return [m for m in pattern.finditer(body) if mask[m.start()] == "1"]

# (1c) A SCRIPT THAT NAMES A SHARED NAMESPACE IS A TIER EVEN IF IT STARTS
# NOTHING.
#
# `tests/provenance_test.sh` builds `-t kit-provenance-test:good`, reads labels
# back out of it, and tears it down with `docker rmi -f kit-provenance-test:good
# kit-provenance-test:plain`. It never runs a container, so neither of the two
# arms above sees it — and it is exactly the defect this check exists to catch, in
# a namespace (the local image store) that `docker rmi -f` reaches by bare name
# and that no `-p` has any say over. Two concurrent runs build over each other and
# one run's teardown removes the image the other is still asserting against.
#
# This arm is why the tier set is a TIER SET and not a bring-up list. It also keeps
# the emptiness finding below non-vacuous: `TAKES_A_SHARED_NAME` is a subset of
# `TOUCHES_DOCKER`, so a script that runs docker without naming anything — `docker
# ps`, `docker info` — is still outside the tier set and still has to be named by
# the finding rather than silently dropped.
TAKES_A_SHARED_NAME = re.compile(
    r"\bdocker\s+(?:compose|run|volume|network|build|image|rmi|tag)\b[^\n]*?"
    r"(?:\s(?:" + r"--project-name|--name|-p|-t|--tag|-v)[=\s])"
)

# The namespace-taking flags. `-p` and `--project-name` name a project, `--name`
# names a container. `-v` is NOT here and the distinction is load-bearing: `docker
# run -v host:container` publishes a PORT (a namespace) while `-v name:/path` is a
# bind mount whose source is a path on this machine. Both spell `-v`, and
# separating them by shape is cheaper than being wrong about one of them.
NAMESPACE_FLAGS = r"(?:--project-name|--name|-p)"

# Continuations are joined before scanning, so a flag on one line and its value on
# the next are read together — `--name \` + newline + `  foo` is one command.
def logical_lines(pairs):
    out, cur = [], None
    for n, ln in pairs:
        if cur is None:
            cur = (n, [ln])
        else:
            cur[1].append(ln)
        if cur is not None and not ln.rstrip().endswith("\\"):
            out.append(cur)
            cur = None
    if cur is not None:
        out.append(cur)
    return [(n, " ".join(b)) for n, b in out]


# The assignment forms a derived name takes. `PROJECT="kit-x-$$"` and
# `PROJECT=kit-x-$$` are the same declaration; `readonly PROJECT=...` is a third
# and is included because a name that cannot be reassigned is a name a later
# literal cannot quietly disagree with.
ASSIGN = re.compile(
    r"^\s*(?:readonly\s+|export\s+|local\s+)*"
    r"(?P<var>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
    r'"?(?P<rhs>[^"\s][^"]*)"?\s*$'
)

# IS THIS WORD DERIVED PER RUN? The test is that it contains shell expansion of
# ANY kind — `$PROJECT`, `${PROJECT}`, or an inline `$$`.
#
# `$$` counts, and an earlier version of this rule required the word to be
# nothing BUT a variable reference. That was wrong in a way worth recording: it
# fired on `tests/deploy_test.sh`'s `docker volume rm "kit16-not-ours-v-$$"`,
# which is a decoy volume that IS unique to the run, because it inlines the pid
# rather than naming a variable holding it. A check that fires on correct code
# teaches a reader to ignore it, which is this repository's own recorded rule
# about `Naming/PredicateName` and about keyword scans over comments — and it is
# the mistake `self_test_live_tier` documents making and then backing out of.
#
# INLINING IS ACCEPTED DELIBERATELY, and the boundary is worth being exact about,
# because "bind the name once" is the rule the fix was written to and this is the
# place that could have quietly relaxed it. What actually breaks is two sites
# DISAGREEING: one deriving `kit-isolation-$$` and one spelling `kit-isolation`
# literal, so the tier queries a namespace it did not create. Two sites that both
# inline the same `$$` agree, and two stacks do not collide. Spelling a name twice
# is untidy; spelling two DIFFERENT names is the defect, and only the second is
# this check's business.
def is_derived(word):
    return "$" in word


problems = []
tiers = []
# Scripts that invoke docker and were not counted as a tier. Collected rather
# than decided inline, because the finding that names them is about the tier SET
# and is raised below the loop with the whole set in hand.
uncovered = []

for name in scripts:
    path = os.path.join(tests_dir, name)
    try:
        pairs = code_lines(path)
    except OSError:
        continue
    # Over LOGICAL LINES, not over single lines, and that detail is the whole
    # reason this rule works at all. `if ! docker compose --project-name … \` on
    # one line and `up -d --wait postgres` on the next is ONE command; a
    # per-line test asks each half a question neither can answer, finds no bring-up
    # anywhere, and quietly drops the tier out of scope. tenancy_test.sh was
    # excluded that way while a literal sat in it, and the mutation suite is what
    # said so.
    logical = logical_lines(pairs)
    if not any(
        BRING_UP.search(b) or WRAPPER.search(b) or command_positions(TAKES_A_SHARED_NAME, b)
        for _, b in logical
    ):
        if any(TOUCHES_DOCKER.search(b) for _, b in logical):
            uncovered.append(name)
        continue
    tiers.append(name)

    # (2) THE NAMES THIS TIER OWNS, derived from its own assignments. Restricted
    # to names that LOOK like namespaces — they carry a `kit-` prefix, or a name
    # ending in -control — so the rule does not trip over `failures=0` and the
    # other ordinary counters these files are full of.
    #
    # AND ONLY THE ONES DOCKER ACTUALLY READS, which is a narrowing this packet
    # forced rather than chose. Widening the tier set to wrapper tiers put
    # `tests/stack_live_test.sh` in scope for the first time, and it immediately
    # reported `KIT_POSTGRES_DATABASES="kit_probe"` as a literal namespace — a
    # database name created INSIDE the stack this same file brings up under
    # `PROJECT="kit-stack-$$"`. Two runs cannot collide on it, because the
    # databases live in the container and the container is already per-run: the
    # finding's own sentence, "every run of this tier shares it", is false there.
    # A check whose message is false is worse than one that is absent, so the rule
    # now asks the question the message asserts — does this variable reach a docker
    # invocation in this file — and derives that from the file rather than from a
    # list. `PROJECT` and every other real namespace is read by a `docker compose
    # -p "$PROJECT"` line, so the load-bearing case is untouched; the measurement
    # that says so is reports/wrapper-tier-scope/mutations.sh, whose six cases all
    # still bite.
    fed_to_docker = set()
    for n, body in logical:
        if not NAMES_IN_DOCKER.search(body):
            continue
        for var in re.findall(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)", body):
            fed_to_docker.add(var)
    owned = {}
    for n, ln in pairs:
        m = ASSIGN.match(ln)
        if not m:
            continue
        var, rhs = m.group("var"), m.group("rhs")
        if re.fullmatch(r"[0-9]+", rhs):
            continue
        if not (re.match(r"\s*[\"']?kit[-_]", rhs) or re.search(r"-control", rhs)):
            continue
        if var not in fed_to_docker:
            continue
        owned[var] = (n, rhs)
        # A literal in the ASSIGNMENT is the same defect as a literal at the use
        # site, and it is the harder one to see: `"$CONTROL_C"` looks derived at
        # every use, so a rule that reads use sites alone passes on a tier whose
        # control container is `kit-isolation-control` for every run on the
        # machine. The mutation suite called this one NOT BITTEN. So the
        # declaration is checked as well as the call.
        #
        # `WORK="${TMPDIR:-/tmp}/kit-isolation.$$"` is fine and is the shape most
        # of these take: it carries `$$`, so it is derived. A name with neither
        # `$` nor `$$` in it is the same literal wearing a variable's clothes.
        # THE ADVICE HAS TO SURVIVE BEING READ ON THE VARIABLE IT NAMES. The
        # suggestion used to be `{var}="$PROJECT-…"`, and on the three wrapper
        # tiers added by this packet that renders as `PROJECT="$PROJECT-…"` for the
        # file whose variable is *named* `PROJECT` — an instruction to assign a
        # variable from itself, on the very line a reader is trying to fix. It was
        # unreachable while only the five original tiers were in scope and none of
        # them names its project variable `PROJECT`, so widening the tier set is
        # what made it visible. A finding whose remedy is wrong is half a finding.
        advice = (
            f"{var}=\"$RUN-…\""
            if var == "PROJECT"
            else f"{var}=\"$PROJECT-…\""
        )
        if not is_derived(rhs):
            problems.append(
                f"{name}:{n}: `{var}=\"{rhs}\"` assigns a namespace LITERALLY, so every "
                f"run of this tier shares it — two concurrent runs are one stack with two "
                f"owners. Put the run's own name in it (`{advice}`), which is "
                f"what the use sites below already read."
            )

    # The rule itself, over USE SITES rather than over declarations. A tier is
    # allowed to derive its names anywhere it likes; what it may not do is hand
    # `docker` a literal in a shared namespace.
    examined = 0
    for n, body in logical:
        if not DOCKER_USE.search(body):
            continue
        examined += 1
        for m in re.finditer(r"(?:^|\s)(" + NAMESPACE_FLAGS + r")\s+(\S+)", body):
            flag, word = m.group(1), m.group(2).strip("\"'")
            if is_derived(word):
                continue
            problems.append(
                f"{name}:{n}: `docker … {flag} {word}` names a project or container "
                f"LITERALLY. Every run of this tier then shares one namespace, so two "
                f"concurrent runs are one stack with two owners — and one run's teardown "
                f"lands mid-assertion in the other, which reads as a failure of the thing "
                f"this tier proves. Derive it from the run's own name; this file already "
                f"derives {', '.join(sorted(owned)) or 'nothing yet'}."
            )

    # `docker volume rm X` takes a bare name and does not care which project made
    # it, so a literal there is a teardown reaching outside its own namespace.
    for n, body in logical:
        m = re.search(r"\bdocker\s+volume\s+rm\s+(\S+)", body)
        if not m:
            continue
        word = m.group(1).strip("\"'")
        if is_derived(word) or word.startswith("--"):
            continue
        problems.append(
            f"{name}:{n}: `docker volume rm {word}` removes a volume this run may not own. "
            "Derive it, or delete the line if nothing in the tier creates that volume."
        )

    # THE HOST PORT, in the shape a compose tier actually moves it: the `.env`
    # override. Checked on the code that writes it, not on the `.env.example` it
    # overrides, and only when the value is a bare literal — a tier that writes
    # `KIT_POSTGRES_PORT=$PGPORT` has derived it.
    for n, body in logical:
        m = re.search(r"KIT_POSTGRES_PORT=\"?\$?\{?([A-Za-z0-9_$-]+)\"?", body)
        if not m:
            continue
        if not re.fullmatch(r"[0-9]+", m.group(1)):
            continue
        problems.append(
            f"{name}:{n}: `KIT_POSTGRES_PORT={m.group(1)}` is a FIXED HOST PORT, and a "
            "fixed host port is worse than a fixed project name — it collides with the "
            "developer's own running stack, not merely with another test run. Measured "
            "while fixing this: deriving the project name alone still left two concurrent "
            "runs red on `port is already allocated`. Derive a free port the way "
            "tests/stack_live_test.sh does."
        )

    # A tier that brings a stack up must NAME its project. Compose otherwise
    # derives one from the working directory, which two runs in one checkout also
    # share.
    brings_up = any(
        re.search(r"docker\s+compose\b.*\bup\b", body) for _, body in logical
    )
    if brings_up:
        names_a_project = any(
            re.search(r"docker\s+compose\b.*" + NAMESPACE_FLAGS, body)
            for _, body in logical
        )
        if not names_a_project:
            problems.append(
                f"{name}: brings a stack up with `docker compose … up` and never names a "
                "project. Compose derives one from the working directory, so two runs in one "
                "checkout share it."
            )
    if examined == 0:
        problems.append(
            f"{name}: was counted as a docker tier because it brings a container up, but no "
            "docker invocation could be read as a logical line. The pattern that finds the "
            "names has stopped matching this file, so the rule is passing by not looking."
        )

# The IMAGE TAG, in the shape `docker build` actually takes it. A separate
    # rule from the use-site scan above because `-t` means --tty to every other
    # docker subcommand, and a flag that is only a namespace in one of them has to
    # be matched only there.
    for n, body in logical:
        for m in command_positions(IMAGE_TAG, body):
            word = m.group(1).strip("\"'")
            if is_derived(word):
                continue
            problems.append(
                f"{name}:{n}: `docker build -t {word}` names an IMAGE LITERALLY. An image "
                "tag is a shared namespace in the same sense a project name is, and "
                "`docker rmi -f` takes a bare one: two concurrent runs then build over "
                "each other and one run's teardown removes the image the other is still "
                "asserting against. Derive it from the run's own name."
            )

# (3) EMPTINESS IS A FINDING, five ways, each of which can fail alone.
if not tiers:
    problems.append(
        "no docker tier found under tests/ — this check is asserting over nothing. Either the "
        "tiers moved or the pattern has stopped matching them; both mean the rule is no longer "
        "covering what it was written for."
    )
else:
    derived = sum(
        1
        for name in tiers
        for n, ln in code_lines(os.path.join(tests_dir, name))
        if ASSIGN.match(ln)
        and (
            re.match(r"\s*[\"']?kit[-_]", ASSIGN.match(ln).group("rhs"))
            or re.search(r"-control", ASSIGN.match(ln).group("rhs"))
        )
    )
    if derived == 0:
        problems.append(
            f"{len(tiers)} docker tier(s) found and none derives a namespaced name, so this "
            "check cannot tell a derived name from a literal. It is passing because it is not "
            "looking."
        )

# …AND THE FIFTH IS THE TIER SET ITSELF, which is the one that could not have been
# written before the mutation suite existed.
#
# The four above are all "a tier was found and nothing could be read inside it". This
# one is "a script uses docker and NO rule here was ever pointed at it" — and it is
# the one that was load-bearing while being absent, because a file dropped from
# `tiers` is invisible to a rule that counts tiers. Three such files sat under
# tests/ carrying the exact defect this check exists to catch and the output said
# `5 docker tier(s), 0 hardcoded … name` in the same breath.
#
# SCOPE IS DERIVED, not listed, and from a predicate WIDER than the tier set on
# purpose. Deriving it from `tiers` would be a tautology that can never fire; the
# predicate here is "invokes a docker subcommand", which is a different question
# from "brings a container up" and is true of `provenance_test.sh`. That file is
# named by this finding and is not a tier, and the reason it is not is that it
# builds an image rather than starting a container — which is exactly the shape a
# rule scoped to `… up` cannot see.
for name in uncovered:
    problems.append(
        f"{name}: invokes docker but was not counted as a docker tier, so none of the rules "
        "above were pointed at it — this is a gap, not a pass. It brings no stack up in a form "
        "this check recognises, so either it names a shared namespace somewhere else (an image "
        "tag, a container name, a `docker volume rm`) and that name is unchecked, or it does "
        "not and the gap is worth knowing about anyway: a check that covers less than a reader "
        "believes is worse than no check, because it costs its trust in the findings it does "
        "report."
    )

if problems:
    for p in problems:
        print("  -", p)
    sys.exit(1)
print(
    f"{len(tiers)} docker tier(s), 0 hardcoded container/volume/project/image name and 0 "
    f"fixed host port; {len(uncovered)} script(s) under tests/ invoke docker without being a "
    f"tier, so a stack brought up through a wrapper is a tier too — covered on the day it "
    f"lands, not the day this file is edited"
)
PY
  }
  check 'tests/  (no docker tier hardcodes a project, container, volume, image or host port name; every shared namespace is derived from the run)' \
    docker_tier_project_name


# ===========================================================================
# phase: lint — run the configs, do not parse them
# ===========================================================================
#
# Deliberately NOT inside the `RUN_STATIC` guard, and that placement is the
# point rather than an oversight. `lint/` spent its whole life behind a parse
# check: `yaml.safe_load` on golangci.yml, `node --check` on eslint.config.mjs,
# and both green on a file that no linter had ever been pointed at. Not one
# service in the fleet had copied any of them.
#
# A phase that only parses cannot tell a config that works from a config that is
# valid YAML, and the difference between those two is the difference between a
# gate and a decoration. So this EXECUTES each linter against a fixture built to
# contain a violation, and asserts the linter rejects it — and, for every one,
# runs a control with the config REMOVED and asserts the control's answer
# differs. A linter that rejects the fixture for a reason other than kit's
# config cannot pass, which is what stops a broken fixture from proving a
# working config.
#
# It also gates on its own toolchains, unlike every other phase: a skip here
# means the claim "kit's lint configs work" went untested, and a claim nobody
# ran is a rumour. See the script's own footer.
kit_phase "50 lint: the four linters, run against fixtures that must fail them"
section 'lint: kit configs, executed against fixtures that must fail them'
if [ "$RUN_LINT" -eq 0 ]; then
  report SKIP 'lint_test.sh  (--no-lint)'
else
  check 'tests/lint_test.sh  (every linter runs, and its control disagrees)' \
    bash "$ROOT/tests/lint_test.sh"
fi

# ===========================================================================
# phase: self_test — prove the gate can go red
# ===========================================================================

kit_phase "60 self_test: n whole gates, one per breakage"
if [ "$RUN_SELF_TEST" -eq 1 ]; then
  section 'self_test: this gate is able to fail'
  # The numbers in this label are COUNTED from self_test.sh's recipes rather than
  # written down. Every breakage calls exactly one of the four red-expecting
  # helpers, so counting those calls is the breakage count by construction — and
  # a hardcoded number is exactly the kind of thing that goes stale quietly when
  # the next packet adds a check. The wording follows from the counts so the two
  # cannot disagree.
  # Three counts, because the helpers no longer agree on what they expect.
  # `expect_skip_check` (breakage 23b) asserts the gate stays GREEN while naming
  # a SKIP, and `expect_green_check` (breakage 59) asserts it stays green while
  # naming a FINDING — kit-13's adoption ceiling, the other side of the same
  # claim. Conflating either with the red-expecting helpers would either claim
  # sixty-seven reds when there are sixty-five, or drop a green-expecting proof
  # from the label entirely, and a proof the summary does not count is a proof
  # nobody runs.
  #
  # The `green_check`/`skip_check` arms on the first pattern and their absence
  # on the second are the load-bearing asymmetry: `breakages` is every recipe,
  # `reds` is only the ones that must fail. Both read the same file, so neither
  # can go stale, and both are anchored on the BREAKAGE LABEL so a helper
  # *definition* can never be counted as a call.
  _st_breakages=$(grep -cE '^ *expect_(red(_check|_lang|_script)?|green_check|skip_check) +.breakage +[0-9]+[a-z]*:' "$ROOT/tests/self_test.sh" || true)
  _st_reds=$(grep -cE '^ *expect_red(_check|_lang|_script)? +.breakage +[0-9]+[a-z]*:' "$ROOT/tests/self_test.sh" || true)

  # The header is a promise about what the file proves, and a promise nobody
  # reads is decoration. Compare the breakage numbers the header NAMES against
  # the numbers the recipes CARRY, so the two cannot drift:
  #
  #   - a recipe with no header entry is a breakage the file proves but does not
  #     claim, which is how a proof quietly stops being one;
  #   - a header entry with no recipe is worse — a claim the file does not
  #     deliver, and the summary line above would be counting the recipes while
  #     the documentation advertises something else.
  #
  # `2b` is parsed as a letter-suffixed continuation of 2 and is expected to
  # appear on both sides, so it is compared literally rather than dropped.
  #
  # EVERYTHING IS A STRING. The first version of this check expanded `7-10` with
  # `range(int(lo), int(hi) + 1)`, so those entries entered the set as `int` while
  # the single entries arrived from the regex as `str`. `named - carried` then
  # reported 7, 8, 9, 10 and every two-digit breakage as both documented-without-
  # a-recipe AND proven-without-being-documented — which is the check reporting a
  # disagreement that did not exist, on a tree that was correct. Normalising to
  # `str` at every point of entry is the whole fix, and the reason it is worth
  # stating: a set difference over two representations of the same number is
  # never empty, so the failure mode is a permanently red check, not a missed one.
  #
  # ---------------------------------------------------------------------------
  # AND THE SECOND PROPERTY ABOUT THE SAME FILE: no recipe needs the live tier,
  # and every child gate opts out of it through ONE wrapper. Both are derived
  # here rather than asserted in `self_test.sh`'s header, because the header is
  # exactly the kind of claim this repository stops believing: a comment saying
  # "the child gates do not run docker" is a comment, and the thing that failed
  # was a docker tier that ran anyway for twenty-odd whole gates.
  #
  # THREE THINGS ARE CHECKED, and each answers a way this can rot:
  #
  #   1. `bash tests/validate.sh` appears EXACTLY ONCE in `self_test.sh`, in a
  #      non-comment line. Five helpers spawn child gates; a sixth added without
  #      the opt-out is a whole gate that quietly brings up three docker stacks
  #      again, and the suite gets slower and flakier with nothing to read.
  #   2. That one line sets `KIT_NO_LIVE=1` and lives inside `kit_child_gate`, so
  #      the single place is also the place that knows what the opt-out is.
  #   3. ZERO recipe invocations mention a live tier. The live set is READ from
  #      this file's own `live_check` calls rather than written out here, so a
  #      fourth live tier is covered by the same check on the day it lands, and
  #      the list can never name a script that has been renamed.
  #
  # (3) is the count this packet asked for, as a check rather than as a claim:
  # today it is 0, and it is 0 because every recipe asserts a verdict about ONE
  # named check — a collector config, a workflow, a linter, a reporter — and the
  # observability live tier is not one of them. It is 0 for a second reason the
  # count cannot see. Counted on this tree: of the 107 recipe invocations, 93 run
  # the gate at all (6 `expect_red_lang` and 8 `_script` invocations never do),
  # **84 of the 93 pass `--static-only`**, and the other 9 are all narrowed to
  # the single check they assert by `expect_red_check`'s `--only` — except 23b,
  # whose helper cannot be filtered because the string it must find is a SKIP's
  # verdict text rather than a check's label. So the opt-out changes the output
  # of exactly ONE recipe in the suite.
  self_test_live_tier() {
    "$PY" - "$ROOT/tests/validate.sh" "$ROOT/tests/self_test.sh" <<'PY'
import re
import sys

gate, suite = sys.argv[1], sys.argv[2]
src = open(gate, encoding="utf-8").read()
self_src = open(suite, encoding="utf-8").read()

# (3) The live set, DERIVED. `live_check '<label>' … bash "$ROOT/tests/<script>"`
# is the only shape a live tier has, because `live_check` is the only wrapper
# that honours RUN_LIVE — and requiring the `live_check` spelling is the point:
# a new tier added straight to `bounded_check` would be invisible here, so the
# rule is that anything behind the opt-out is spelled `live_check`.
live = re.findall(r"^[ \t]*live_check[^\n]*\n[ \t]*\d+ bash \"\$ROOT/tests/([^\"]+)\"", src, re.M)
if not live:
    print("  - no `live_check` invocation found: the observability live tier is not")
    print("    behind --no-live any more, so `KIT_NO_LIVE=1` would opt out of nothing")
    print("    and the opt-out in tests/self_test.sh would be a decoration.")
    sys.exit(1)

lines = self_src.splitlines()
# A line whose first non-blank character is `#` is a comment. Everything this
# check reads is CODE, and the file is full of prose that legitimately names
# `canary_test.sh` — including the wrapper's own comment, which explains why the
# count is zero.
code = [(n, ln) for n, ln in enumerate(lines, 1) if ln.strip() and not ln.lstrip().startswith("#")]

problems = []

# (1) One spawn, and it is the gate rather than a path to it. The pattern is
# deliberately loose about the path -- `bash "$dir/tests/validate.sh"` is the same
# spawn as `bash tests/validate.sh` and opts out of nothing -- and deliberately
# excludes `bash -n`, which this file already uses to syntax-check a script and
# which runs no gate.
spawns = [
    (n, ln)
    for n, ln in code
    if re.search(r"\bbash\b(?! +-n\b)[^|;&\n]*tests/validate\.sh", ln)
]
if len(spawns) != 1:
    where = ", ".join("line %d" % n for n, _ in spawns) or "nowhere"
    problems.append(
        f"a `bash … tests/validate.sh` spawn appears {len(spawns)} time(s) outside "
        f"comments in tests/self_test.sh ({where}); expected exactly 1. Every child gate "
        "must go through kit_child_gate, or it does not get KIT_NO_LIVE=1."
    )

# (2) The one spawn opts out, and it lives in a wrapper that exists.
#
# CONTAINMENT IS DELIBERATELY NOT ASSERTED, and the reason is a mutation that
# made this check red on correct work while it was being written. Locating the
# spawn "inside `kit_child_gate`" needs either brace counting or "the nearest
# function definition above it", and both are wrong the moment a definition is
# written inside another definition's body — which bash accepts, which no linter
# here flags, and which a reader can do by accident. The span version reported
# the nested function as the enclosing one and blamed a function that spawns
# nothing; a check that fires on a correct edit teaches the reader to ignore it,
# which is this repository's own rule about `Naming/PredicateName` and about
# keyword scans over comments. So the property here is the one that matters —
# one spawn, and it carries the opt-out — plus the fact that the wrapper is
# still there to carry the reasoning.
if len(spawns) == 1:
    n, ln = spawns[0]
    if "KIT_NO_LIVE=1" not in ln:
        problems.append(
            f"line {n} spawns the gate without KIT_NO_LIVE=1, so that child gate runs "
            "the observability live tier — three docker stacks — for a recipe that "
            "asserts one named check."
        )
    if not any(re.match(r"^kit_child_gate\(\)\s*\{\s*$", ln) for ln in lines):
        problems.append(
            "tests/self_test.sh defines no `kit_child_gate()`. One spawn of the gate is "
            "not enough on its own: the wrapper is the single place that says what the "
            "opt-out is and why, and a bare spawn in five helpers is a promise repeated "
            "five times with nothing to check it."
        )

# (3) No recipe names a live tier. Statements are joined on a trailing `\` because
# every recipe in this file is written across two or three lines. `cur` holds the
# line NUMBER and the lines, in that order, because the failure message has to be
# able to point at the recipe rather than at "somewhere in the file".
stmts, cur = [], None
for n, ln in code:
    if cur is None:
        # Anchored on the NAME and required NOT to be a definition. `expect_red()
        # {` matches a name-only pattern exactly as well as a call does — which
        # is the mistake this repository has already made once, in both the
        # `_st_breakages` count and the header/recipe agreement check, and which
        # printed 28 over 23 recipes on a run that was fine. The `()` is what
        # tells the two apart.
        if re.match(
            r"^[ \t]*expect_(?:red(?:_check|_lang|_script)?|green_check|skip_check|green)\b",
            ln,
        ) and not re.match(r"^[ \t]*expect_[A-Za-z0-9_]*\(\)\s*\{", ln):
            cur = (n, [ln])
    else:
        cur[1].append(ln)
    if cur is not None and not ln.rstrip().endswith("\\"):
        stmts.append(cur)
        cur = None
if cur is not None:
    stmts.append(cur)

offenders = []
for start, body_lines in stmts:
    body = " ".join(body_lines)
    for script in live:
        if script in body:
            offenders.append(f"line {start} names `{script}`")
if offenders:
    problems.append(
        f"{len(offenders)} recipe invocation(s) name a live tier out of "
        f"{', '.join(live)}: " + "; ".join(offenders) + ". A recipe that asserts a "
        "live docker tier can only be evaluated on a quiet machine, which is the "
        "condition that made breakage 23b red at position 23 of 104 and green "
        "standalone. Prove that tier from the top-level gate instead."
    )

if problems:
    for p in problems:
        print("  -", p)
    sys.exit(1)
print(
    f"0 of {len(stmts)} recipe invocations name a live tier; "
    f"{len(spawns)} child-gate spawn, opted out of all {len(live)}"
)
PY
  }
  check 'tests/self_test.sh  (0 of the recipes name a live tier; every child gate opts out through one wrapper)' \
    self_test_live_tier
  self_test_claims() {
    "$PY" - "$ROOT/tests/self_test.sh" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()

# Sort by (number, suffix) so 2b lands next to 2 rather than at the end. The
# labels are strings so that `2` and `2b` can be told apart at all.
def breakage_sort(label):
    m = re.fullmatch(r"(\d+)([a-z]?)", label)
    return (int(m.group(1)), m.group(2)) if m else (0, label)


# The header block, up to the first `set -euo`.
header = src.split("set -euo pipefail", 1)[0]

# Breakage numbers as WRITTEN, all as `str`. A header line like `7-10.` is one
# entry naming a range; it is expanded, not counted, so `7-10` in the header is
# matched by breakages 7, 8, 9 and 10 in the recipes.
named = set()
for lo, hi in re.findall(r"^#\s+(\d+)-(\d+)\.", header, re.M):
    named.update(str(n) for n in range(int(lo), int(hi) + 1))
# Individually named entries, optionally letter-suffixed (`2b.`).
named.update(re.findall(r"^#\s+(\d+[a-z]?)\.", header, re.M))

# Breakage numbers as LABELLED, from the recipe invocations.
carried = set(
    re.findall(
        # Either quoting style. Breakage 5's label has always been double-quoted
        # and breakage 4's single; matching one of them would have reported a
        # disagreement that does not exist, and the fix belongs in the pattern
        # rather than in rewriting a working recipe to suit a new check.
        # All FIVE helpers, or the check reports a header/recipe disagreement
        # that does not exist: breakages 21 and 22 are `expect_red_script`, and
        # a pattern missing `_script` calls them undocumented. Same omission as
        # the `_st_breakages` count above — one bug, two symptoms, because the
        # helper list was written down twice.
        r"""^[ \t]*expect_(?:red(?:_check|_lang|_script)?|green_check|skip_check) ['"]breakage\s+(\d+[a-z]?):""",
        src,
        re.M,
    )
)

problems = []
for missing in sorted(named - carried, key=breakage_sort):
    problems.append(f"header documents breakage {missing} but no recipe carries it")
for orphan in sorted(carried - named, key=breakage_sort):
    problems.append(f"recipe proves breakage {orphan} but the header does not document it")

# A throwaway-copy DIRECTORY variable that is REASSIGNED stops being a path.
# This is here because it already happened, and it happened silently: the
# renumber that gave breakages 41-51 descriptive directory names gave breakage
# 50's directory the name `canary_literal`, which was already the name of the
# canary VALUE assembled six lines below it. The reassignment meant `edit` was
# handed `cafaye_canary_.../templates/secrets/go/canary.go`, the recipe died with
# a FileNotFoundError, and breakage 50 never ran — taking 51 with it, because
# the script stops at the first crash. Two proofs dead, and the only symptom was
# a traceback in a phase whose output nobody reads on a green run.
#
# Nothing about READING the file shows this. Both lines look correct in isolation,
# and `bash -n` is happy, and the header/recipe agreement above is perfect while
# both of them are wrong. So it is asserted here, where a check already parses
# this file.
_lines = src.splitlines()
_fresh = re.compile(r'^(\w+)="\$\(fresh_copy\b')
_assign = re.compile(r'^(\w+)=')
_dirvars = {}
for _n, _line in enumerate(_lines, 1):
    _m = _fresh.match(_line)
    if _m and _m.group(1) not in _dirvars:
        _dirvars[_m.group(1)] = _n
for _n, _line in enumerate(_lines, 1):
    _m = _assign.match(_line)
    if not _m or _m.group(1) not in _dirvars or _fresh.match(_line):
        continue
    problems.append(
        f"line {_n}: `{_m.group(1)}` holds a throwaway copy (assigned at line "
        f"{_dirvars[_m.group(1)]}) and is reassigned here, so that recipe edits a path that no longer exists"
    )

# `sys.exit` rather than `return`: this is a top-level script, not a function
# body, and the other checks in this file use the same shape. A `return` here is
# a SyntaxError at import time — which is exactly how this check first failed.
if problems:
    for p in problems:
        print("  -", p)
    sys.exit(1)
PY
  }
  check 'tests/self_test.sh  (every documented breakage has a recipe, and vice versa)' \
    self_test_claims

  # NO RECIPE MAY ANCHOR ON A BARE VERSION LITERAL.
  #
  # WHY THIS IS A CHECK AND NOT A CONVENTION. `edit` already refuses an anchor it
  # cannot find, loudly, naming the file — so nothing here is about being louder.
  # It is about making the class impossible rather than about detecting one
  # instance, and the difference is the whole argument:
  #
  #   Four recipes anchored their mutations on the literal `1.0.0`. The next
  #   release moved VERSION to 2.0.0 and all four reported
  #   `the recipe no longer applies to its copy`, which reads as a harness
  #   complaint rather than as "the only proof that a MAJOR bump owes a migration
  #   has stopped running". Four proofs of kit's own release discipline died on a
  #   commit whose message named three OTHER breakages and none of these four.
  #
  # A refusal cannot catch that, because at the moment `edit` refuses, the recipe
  # is already dead and the damage is done. This check runs on the SOURCE, so the
  # sixth recipe to be written the same way is a red gate at authoring time rather
  # than a dead proof at release time.
  #
  # WHY NOT THE OTHER SHAPE. The alternative in the packet — a guard at suite
  # start that resolves each anchor against a copy and names the drift — is the
  # same information one step later, and it costs a full set of copies to say what
  # a text scan says for free. Worse, it cannot say WHICH recipe or WHY at the
  # moment somebody is writing one. Decided and recorded in DECISIONS.md (MD31).
  #
  # DERIVED, NOT ASSERTED. The set of interesting files is read out of the
  # recipes themselves — every path `edit` is handed that resolves to `VERSION` or
  # `CHANGELOG.md` — so adding a version recipe brings itself under the rule
  # without this file being edited. That is the same move as `self_test_live_tier`
  # deriving the live tier from `live_check` invocations, and for the same reason:
  # a list of what is forbidden, written down separately, is a list that goes
  # stale, and a rule that only covers the recipes its author remembered is a rule
  # with a hole shaped like the next packet.
  self_test_no_version_literal() {
    "$PY" - "$ROOT/tests/self_test.sh" "$ROOT/VERSION" <<'PY'
import os
import re
import sys

suite = open(sys.argv[1], encoding="utf-8").read()
live_version = open(sys.argv[2], encoding="utf-8").read().strip()

lines = suite.splitlines()
# Comments are excluded because this file is mostly prose about versions, and a
# check that fires on a comment explaining WHY a literal is wrong is a check that
# fires on its own documentation.
code = [(n, ln) for n, ln in enumerate(lines, 1) if ln.strip() and not ln.lstrip().startswith("#")]

# Join a trailing `\`, because every recipe here is written across two or three
# lines and a per-line scan would see half a string literal and match nothing.
stmts, cur = [], None
for n, ln in code:
    if cur is None:
        if re.match(r"^[ \t]*edit\s", ln):
            cur = (n, [ln])
    else:
        cur[1].append(ln)
    if cur is not None and not ln.rstrip().endswith("\\"):
        stmts.append(cur)
        cur = None

# MAJOR.MINOR.PATCH, as three components and nothing else. `1.0.0-rc1` and
# `v1.4.0` are deliberately NOT matched by the bare form: they cannot appear in
# VERSION, so a recipe that writes one is asserting a string the tree forbids.
# The gate's own `stability_parse` refuses both for the same reason.
VERSION_LITERAL = re.compile(r"(?<![\w.$/-])(\d+\.\d+\.\d+)(?![\w.-])")

# The files whose contents a release moves. `VERSION` is the version;
# `CHANGELOG.md` carries the version headings and the `## Unreleased` section.
INTERESTING = ("VERSION", "CHANGELOG.md")

problems = []
# Which recipes the rule is about, derived rather than written down: a recipe
# that mentions one of these paths. Used only for the summary count, so the
# number printed is a measurement of the file rather than a claim about it.
guarded = set()
for start, body_lines in stmts:
    body = " ".join(body_lines)
    # The path is the first quoted or bare word after `edit`.
    m = re.search(r"edit\s+(\"[^\"]*\"|'[^']*'|\S+)", body)
    if not m:
        continue
    path = m.group(1).strip("\"'")
    if not path.endswith(INTERESTING):
        continue
    guarded.add(start)
    # Every remaining argument, so the rule covers the REPLACEMENT as well as the
    # anchor. A recipe that anchored on a variable and wrote a literal
    # destination has the same fuse: the literal stops existing the moment the
    # tree moves past it.
    #
    # DEDUPED, because the commonest form names the same version twice — once as
    # the anchor and once as the destination — and two identical findings read as
    # two problems where there is one. One recipe, one finding per version.
    for lit in sorted(set(VERSION_LITERAL.findall(body))):
        problems.append(
            f"line {start}: the recipe editing `{os.path.basename(path)}` names the version "
            f"literal `{lit}` ({'the tree is at ' + live_version if lit == live_version else 'a version this tree has never been at'}). "
            "Derive it from the copy instead: `copy_version \"$baseNN\"` for the version it "
            "carries and `bump <v> <major|minor>` for the destination. A literal here is a "
            "time bomb whose fuse is one release, and the release that lights it takes this "
            "recipe's proof with it while reporting a harness complaint rather than a lost proof."
        )

if not guarded:
    problems.append(
        "no recipe edits VERSION or CHANGELOG.md any more, so this check is asserting over "
        "nothing. Either the version recipes were removed or this pattern has stopped "
        "matching their calls; both mean the rule is no longer covering what it was written for."
    )

if problems:
    for p in problems:
        print("  -", p)
    sys.exit(1)
print(
    f"{len(stmts)} mutation(s) in {len(guarded)} recipe(s) touching "
    f"{', '.join(INTERESTING)}; 0 anchors a bare version literal, so the next bump is not an event"
)
PY
  }
  check 'tests/self_test.sh  (no recipe anchors on a bare version literal; every version a recipe writes is derived from its copy)' \
    self_test_no_version_literal

  # The label carries both numbers and, deliberately, does not sum them into
  # "N breakages, N reds" the way it did while every recipe was red-expecting.
  # Sixty-seven breakages of which sixty-five must go red and two must stay green
  # — 23b naming a SKIP, 59 naming a FINDING — is a *stronger* suite than
  # sixty-seven that must all go red, and a label that flattened the two would hide
  # the only facts that distinguish them. The NUMBERS in this label are counted from
  # the recipes; the numbers in these comments are written down, which is why they
  # are the ones that go stale.
  #
  # BOUNDED, and this is the phase that most needs it. Every recipe builds a
  # fresh throwaway copy of the tree and runs the whole static gate inside it, so
  # the self-test is _n_ gates in sequence: 77 on this branch, and the number
  # grows with every check this repository adds. On a quiet box it is the
  # longest phase in the run by a wide margin, and it is the one that grows
  # silently — nothing in it announces that the gate just got slower.
  #
  # The count in the LABEL above is computed from the recipes, so the number in
  # this comment is the one place it can go stale, and it did: it read 67 for
  # three packets. Corrected here rather than left, because a comment claiming a
  # count is a claim, and this repository's rule about `DECISIONS.md` — that a
  # reference to something that does not exist is worse than no reference — is the
  # same rule one layer down.
  #
  # AND A BOUND IS NOT A RESULT ABOUT THE BREAKAGES IT DID NOT REACH. Measured on
  # kit-22: this tier BOUNDed at breakage 56 of 77, so 21 recipes never ran, and
  # the run still exited 0. That is the correct behaviour — a bound is neither a
  # pass nor a skip, and it is reported — but it means a green gate is not
  # evidence about the unreached recipes. Running them by hand is how kit-22 found
  # breakage 72 green on a check that could not see its own defect. See
  # AGENTS.md, "a BOUND self_test is a gate to run by hand".
  #
  # 5400s is measured, not chosen. The uninterrupted run recorded in
  # REPORT-kit-13.md §5.2 took ~44 minutes end to end, of which the self-test
  # phase was the majority; 5400 leaves room for a box three times busier than
  # this one without being a number so large it never binds. A bound that never
  # binds is the correct answer here — the point is that the run REACHES THE END
  # and says so, not that it fails sooner. A tier that hits its bound is reported
  # as a BOUND, which is neither a pass nor a skip, so a bound cannot buy a green
  # this tree did not earn.
  bounded_check "tests/self_test.sh  ($_st_breakages breakages: $_st_reds red, $((_st_breakages - _st_reds)) green-expecting — the ceiling has both sides proved)" \
    5400 bash "$ROOT/tests/self_test.sh"
fi

# ---------------------------------------------------------------------------

kit_phase "70 summary"
printf '\n'
# FOUR COUNTS, and the reason there are four is the reason this summary exists
# at all. `PASS` and `FAIL` are verdicts about the tree. `SKIP` is a verdict
# about the ENVIRONMENT: the check could not run here. `BOUND` is a verdict
# about the RUN: the check started, this machine was too busy to finish it, and
# the claim it exists to prove is therefore unexercised.
#
# Collapsing BOUND into FAIL would report a loaded box as a defect in the tree,
# and collapsing it into PASS would be a lie with a green word on it. Either way
# the reader loses the one thing they need: which failures to go and fix, and
# which to go and re-run. The count is printed whenever it is non-zero, exactly
# like the skip count, so a run that hit a bound cannot end quietly.
# A `--only` FILTER THAT MATCHED NOTHING IS A FAILURE, and this is the single
# most important line in this file.
#
# Measured, not argued: `--only=ZZZ_NO_SUCH_CHECK_XYZ` exits 0 and prints
# "PASS: every check passed." It matches no check, runs no check, proves
# nothing, and reports success. That is precisely the vacuous pass this
# repository exists to prevent -- the same shape as a census walk that sees no
# routes, or a tally that under-counts passes inside failing binaries.
#
# It is WORSE than an unrelated typo, because the whole point of `--only` is
# speed, and the speediest possible invocation is the one that checks nothing.
# A caller optimising a CI loop would find it, take the win, and lose the gate.
if [ -n "$ONLY_MATCH" ] && [ "$ONLY_RAN" -eq 0 ]; then
  echo "FAIL: --only='$ONLY_MATCH' selected NO check out of the suite."
  echo "       A filter that matches nothing runs nothing and proves nothing;"
  echo "       agreeing with a filter that matches nothing is not a passing gate."
  echo "       $ONLY_SKIPPED check(s) were excluded. The filter is a typo, or the"
  echo "       check it names does not exist -- and both are worth failing on."
  exit 1
fi
if [ -n "$ONLY_MATCH" ]; then
  echo "note: FILTERED run -- $ONLY_RAN check(s) ran, $ONLY_SKIPPED excluded by --only='$ONLY_MATCH'."
  echo "       This is NOT a claim about the $ONLY_SKIPPED excluded check(s). Run without --only for that."
fi
# `--no-live` GETS ITS OWN SUMMARY LINE, on both exit paths, and this is the
# second half of the honesty argument `live_check` starts. The three SKIP rows
# above are the first half; without a line here, a reader who reads only the
# summary sees `PASS: every check passed.` and `note: 9 check(s) skipped` with
# nothing telling them WHICH nine, which is the same shape as a check that
# quietly stopped running. So the opt-out is named at the point where a verdict
# is announced, in the past tense and with the consequence in it: those three
# claims were not exercised by this run, whoever asked for the skip.
if [ "$RUN_LIVE" -eq 0 ]; then
  echo "note: --no-live: the observability live tier (canary, collector-killed, fetched stack)"
  echo "       did NOT run. Three claims are UNEXERCISED by this run and no gate that a"
  echo "       human or CI runs sets this flag; it exists for the throwaway gates in"
  echo "       tests/self_test.sh, none of which asserts anything about those three."
fi
if [ "$fails" -ne 0 ]; then
  echo "FAIL: $fails check(s) failed."
  [ "$skips" -eq 0 ] || echo "note: $skips check(s) skipped (reported above)."
  [ "$bounded_hit" -eq 0 ] || echo "note: $bounded_hit tier(s) hit their time bound — the proof was unexercised, not passed (reported above)."
  exit 1
fi
echo "PASS: every check passed."
[ "$skips" -eq 0 ] || echo "note: $skips check(s) skipped — reported above, never hidden."
[ "$bounded_hit" -eq 0 ] || echo "note: $bounded_hit tier(s) hit their time bound — reported above, never hidden."
# And the bound itself, on the runs where it did NOT bind, because a ceiling the
# reader has never been told about is a ceiling they cannot rely on. Only
# printed when a bound was actually applied, so a machine with no `timeout` at
# all is not told about bounds it never had.
if [ "$bounded_ran" -gt 0 ]; then
  echo "note: $bounded_ran tier(s) ran under a time bound; none was reached."
fi
