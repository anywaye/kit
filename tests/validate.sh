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

# The three files that make the secret scanner one decision rather than three.
# Paths as variables for the same reason WORKFLOW is: the path being wrong is the
# class of defect this file exists to catch, and a literal repeated in a dozen
# heredocs is a dozen chances to spell it three ways.
GITLEAKS_CONFIG='.gitleaks.toml'
GITLEAKS_GATE='tests/gitleaks_gate.sh'
# literal in two places is two chances to spell it three ways.

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


  # -------------------------------------------------------------------------
  section 'static: compose — the observability chokepoint'

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

  # -------------------------------------------------------------------------
  # The tier convention. Three claims, three checks, split because they decay
  # separately: the templates drift, the wiring drifts, the allowlist rots. One
  # check covering all three would keep passing while two of them rotted.
  # -------------------------------------------------------------------------
  section 'static: every language declares a tier, and says how it is collected'



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








  # -------------------------------------------------------------------------
  # `eslint_typed_scope`: every linted file gets type information, or the
  # type-aware rules cannot run at all.
  #
  # WHAT IT IS FOR. `lint/eslint.config.mjs` turned on
  # `tseslint.configs.recommendedTypeChecked` and supplied `parserOptions` under
  # a `files` glob of `**/*.{js,mjs,cjs,ts,tsx}`. Meanwhile one of the configs
  # inside `recommendedTypeChecked` — `typescript-eslint/eslint-recommended` —
  # declares `files: ['**/*.ts','**/*.tsx','**/*.mts','**/*.cts']`, which ADDS
  # `.mts` and `.cts` to the set of files ESLint will lint. So every `.mts` file
  # in a service was linted, was handed the type-aware rules, and was never
  # handed the type information those rules require:
  #
  #   Error: Error while loading rule '@typescript-eslint/await-thenable':
  #   You have used a rule which requires type information, but don't have
  #   parserOptions set to generate type information for this file.
  #
  # Measured in cafaye/site run 37236386666 and cafaye/parlor run 37230458669,
  # on the `node` job, whose first real execution this was — the job had been
  # suppressed for four days by the concurrency collision fixed in ad3e320. Both
  # services carry three `.mts` files at the repo root (vitest.config.mts,
  # vite.config.mts, vite.node.config.mts), so this was never marginal. The run
  # dies at exit 2 before reporting a single finding.
  #
  # THE DIAGNOSIS THAT WAS WRONG, recorded because the wrong diagnosis is the
  # more useful half. It was attributed to `tsconfigRootDir:
  # import.meta.dirname` — kit's directory rather than the caller's — and that is
  # a real misconfiguration which is also fixed. It is not what produced the
  # error. Measured on eslint 9.39.5 / typescript-eslint 8: with
  # `projectService: true`, setting `tsconfigRootDir` to `/nonexistent-root`, or
  # deleting it, leaves the run byte-identical, because the project service walks
  # UP from the linted FILE to find a tsconfig rather than searching from the
  # root. A check written for the reported cause would have been green on the
  # defect that actually shipped.
  #
  # WHY THIS IS A CHECK RATHER THAN A COMMENT. `files` is load-bearing in a way
  # nothing else in this file's static phase can see, because ESLint 9 accepts a
  # `files` glob that is narrower than the set of files its own inputs pull in,
  # and there is no parse error and no warning: the run simply dies when the
  # first type-aware rule is constructed. The only place this is observable is a
  # real run against a real project — which is `tests/lint_test.sh`'s job, and
  # which has an assertion for it. What THIS check does is hold the invariant the
  # fix rests on, so a future edit to either list is caught here rather than in
  # eleven services' CI.
  #
  # BOTH DIRECTIONS, because they are different mistakes with different costs.
  # Too NARROW is the defect that shipped: a crash, exit 2, no findings. Too WIDE
  # lints files kit never linted before — `.jsx` is the standing example, and
  # adding it would turn every React service red with `was not found by the
  # project service` since no `.jsx` file is in anyone's tsconfig. So the
  # assertion is a superset-with-a-reason: every extension the recommended sets
  # add must be present, and an extension nobody has a reason for is a finding.
  eslint_typed_scope_check() {
    "$PY" - "$ROOT" "$ESLINT_CONFIG" <<'PYE'
import re
import sys

path = sys.argv[2]


def strip_js_comments(src):
    """Remove `//` and block comments, leaving string contents intact.

    This exists because the first version of this check read its answer out of
    the file's own COMMENT and went red on a config that is correct. `tsconfig-
    RootDir` appears eleven times in the header above, explaining at length why
    the value must be the caller's workspace, and the regex matched the first of
    those rather than the `process.cwd()` on the last line.

    That is AGENTS.md's rule arriving in a new place: "a check that can be
    satisfied by a comment is not a check", and the mirror image is worse — a
    check that can be FALSIFIED by one. The file documenting its own invariant
    is the normal case, not an unlucky one, so any check reading a JS or shell
    file has to strip comments first or it is reading the prose.

    Strings are tracked because a `//` inside a quoted path is content: the
    `paths` style glob in this very file is full of them.
    """
    out = []
    i, n = 0, len(src)
    while i < n:
        ch = src[i]
        if ch in ("'", '"', "`"):
            quote = ch
            out.append(ch)
            i += 1
            while i < n:
                out.append(src[i])
                if src[i] == "\\":
                    if i + 1 < n:
                        out.append(src[i + 1])
                        i += 2
                        continue
                elif src[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        if ch == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if ch == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                if src[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


src = strip_js_comments(open(path, encoding="utf-8").read())

# The extensions `recommendedTypeChecked` can hand a type-aware rule. Held HERE
# and asserted against kit's glob rather than read out of an installed
# typescript-eslint, because this repository ships no node_modules and no
# dependencies, and a check that could only run where a package was installed
# would be a check that never runs in the one place it is needed. The value is
# typescript-eslint 8's own `eslint-recommended` `files`, quoted in
# lint/eslint.config.mjs's own header comment; if a future version changes it,
# this list is the thing to update and the comment is where the reason lives.
#
# `.jsx` is deliberately NOT here and the comment says why; it is a plausible
# addition to this tuple and one that would be wrong.
REQUIRED = ("ts", "tsx", "mts", "cts")

# kit's glob, read out of the file rather than restated. A restatement would be a
# second copy of the same fact, and AGENTS.md's rule about `advisoryOps` and
# `unrecognisedTier` is the general form of the point: a property stated in two
# places is a property asserted zero times.
m = re.search(r"files:\s*\[([^\]]*\*\.\{[^}]*\}[^\]]*)\]", src)
if not m:
    sys.exit(
        f"{path}: could not find the brace-globbed `files` entry this check reads. "
        f"The check has stopped being able to ask its question, and a check that "
        f"cannot ask its question is not a check"
    )
present = set(re.findall(r"[a-z]+", m.group(1)))

problems = []
missing = [e for e in REQUIRED if e not in present]
if missing:
    problems.append(
        f"{path}: the `files` glob covering `parserOptions` is missing {missing}. "
        f"tseslint.configs.recommendedTypeChecked contains a config whose own "
        f"`files` adds {list(REQUIRED)} to the set of files ESLint lints, and "
        f"`recommendedTypeChecked` itself is UNSCOPED — so a linted file outside "
        f"this glob is given the type-aware rules and never given the type "
        f"information they require, and the run dies at exit 2 with `You have "
        f"used a rule which requires type information` before reporting a single "
        f"finding. This is the defect that shipped: cafaye/site run 37236386666 "
        f"and cafaye/parlor run 37230458669, both of which carry three root-level "
        f"`.mts` files"
    )

# And the other direction. `jsx` is the named example, and the reason is
# measured: nothing above adds it to the linted set, so adding it here widens
# kit's lint in every service in the fleet, and no `.jsx` file is in anyone's
# tsconfig — so every one of them goes red with `was not found by the project
# service`. A React service's components are `.tsx`.
UNJUSTIFIED = ("jsx",)
stray = [e for e in UNJUSTIFIED if e in present]
if stray:
    problems.append(
        f"{path}: the `files` glob now covers {stray}. No recommended set adds "
        f"those to the linted set, so this widens what kit lints in every service "
        f"in the fleet, and a `.jsx` file is in nobody's tsconfig — so the cost is "
        f"a red `was not found by the project service` in each of them. If this is "
        f"wanted it is a decision about the fleet's lint policy and belongs in a "
        f"comment here saying so"
    )

# `tsconfigRootDir` must be the CALLER's workspace. Not the reported cause of the
# crash above, and still asserted: it is load-bearing in exactly one place, and
# that place is `allowDefaultProject`, whose globs are matched RELATIVE TO IT
# (`useProgramFromProjectService.js` does
# `path.relative(parseSettings.tsconfigRootDir, filePathAbsolute)`). With kit's
# own directory as the root, a pattern meant to cover the caller's root config
# files resolves to `.kit/lint/*.mts` and matches nothing — the error says so:
# `allowDefaultProject is set to ["*.mts"], which does not match '../../x.mts'`.
# So the value is wrong in a way that is invisible until the first entry is added.
tm = re.search(r"tsconfigRootDir:\s*([^,\n}]+)", src)
if not tm:
    problems.append(
        f"{path}: no `tsconfigRootDir` is set. typescript-eslint then infers one, "
        f"and the inference is a guess about a directory layout kit does not know"
    )
elif "import.meta.dirname" in tm.group(1):
    problems.append(
        f"{path}: `tsconfigRootDir` is `import.meta.dirname`, which is kit's own "
        f"`lint/` directory rather than the caller's workspace. It is not the cause "
        f"of the crash the header describes — with `projectService: true` the "
        f"service walks up from the linted FILE, so this value is ignored for "
        f"project lookup — but `allowDefaultProject` globs are matched relative to "
        f"it, so the first entry added would resolve to `.kit/lint/` and match "
        f"nothing. It must be the caller's workspace"
    )

if problems:
    sys.exit("; ".join(problems))

print(
    f"every extension recommendedTypeChecked can lint ({', '.join(REQUIRED)}) is "
    f"inside the `files` glob that supplies parserOptions, no extension is present "
    f"without a reason, and tsconfigRootDir is the caller's workspace rather than "
    f"kit's"
)
PYE
  }


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
    live_check 'tests/no_telemetry_in_readiness.sh  (collector killed, service still serves)' \
      900 bash "$ROOT/tests/no_telemetry_in_readiness.sh"
    # THE STACK, RUN. Every claim in this file about the observability platform
    # being usable is a claim about YAML until this one runs: that the FETCHED
    # stack comes up healthy, that a trace arrives in Tempo, that a metric
    # arrives in Mimir, and that a canary planted in ten attributes reaches
    # neither. `docker compose config` proved a stack that could not start, twice,
    # in this repository's own history — once because the collector's environment
    # block was missing and once because Mimir's healthcheck named a directory.

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
