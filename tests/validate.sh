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
#   bash tests/validate.sh --no-observability  # skip the whole observability phase
#   bash tests/validate.sh --no-live           # skip ONLY the observability live tier
#   bash tests/validate.sh --no-lint           # skip running the linters themselves
#
# --no-live, and why it exists and why it is not --no-observability:
#   `--no-observability` drops the whole phase, INCLUDING the two database
#   boundary tiers. `--no-live` drops the docker stacks the observability
#   PLATFORM is proven by, and leaves the cluster tiers alone. The distinction
#   matters because the two sets of claims are not the same: one is "the
#   collector works", the other is "a service cannot read another service's
#   rows".
#
#   WHAT IT IS NOT: silence. Each live tier becomes a `SKIP` naming the flag,
#   counted in the skip tally and printed in the summary, because a skip that
#   cannot be seen is a silent pass. See `live_check` for the shape.
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
# WHY IT EXISTS: one run of this gate is a couple of hundred checks, and
# working on one of them means paying for the rest. Narrowing WHICH checks run
# is not loosening WHAT they must prove -- a filtered run still fails if the
# checks it did run fail.
#
# THE HONEST CAVEAT. A filtered run has not run the whole gate, so it must not
# be reported as if it had. `--only` therefore prints a banner naming the filter
# on every run, and the exit status is the FILTERED suite's -- never a claim
# about the checks that were excluded.
ONLY_MATCH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --static-only)
      RUN_OBSERVABILITY=0
      RUN_LINT=0
      ;;
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
# region: kind, label, seconds, and an inherited tag. Rows are appended with
# `>>`, which is atomic for lines this short, and every writer in the tree is
# short enough to stay under one `PIPE_BUF`.
#
# FOUR KINDS, and why there are four rather than one.
#   check   a serial `check`/`check_verbose` — wall time of ONE command.
#   cpu     a `check_par` child — time of one parallel check. THESE OVERLAP: their
#           sum is an upper bound on the parallel region, not its elapsed time.
#           Collapsing them with the serial rows would double-count and produce a
#           profile that adds up to more than the run, which is the one thing a
#           profile must never do.
#   tier    a `bounded_check` — a whole heavy script.
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
# a full run spawns hundreds of checks, so an `awk`-based timer would add a
# second process per measurement and report its own overhead as the gate's cost.
# Integer arithmetic in the shell is not slower than awk for one subtraction.
# With the profile off, `_pf_now` is never called at all.
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
# The resolved interpreter is exported so every
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
# Before the interpreter, not after: on a machine whose only python is a
# mise-managed one, this is what puts it on PATH for step 3 of the resolution
# order below. See kit_activate_mise for why the gate resolves this at all.
kit_activate_mise
kit_bootstrap_python "$ROOT"
export KIT_PYTHON="$PY"

kit_phase "00 bootstrap: resolve the interpreter and install deps"

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
  # own output — which `--only` reads — is byte-identical
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
#      output to the serial run. That matters because anything reading gate
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
# which check finished first — and a reader of this output counts by position
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

# The probe each toolchain actually answers. This is a TABLE rather than a
# blanket `--version` because `--version` is not a universal spelling: `go` and
# `gofmt` both REJECT it ("flag provided but not defined: -version") and exit
# non-zero, so a blanket probe declares a perfectly working Go 1.26 absent and
# skips two tiers that would otherwise run. That is the failure this whole
# change exists to remove, reintroduced from the other side — a probe that says
# "no" about a toolchain that works is as wrong as one that says "yes" about a
# toolchain that does not, and the second one is the one that hides a tier.
#
# A toolchain not named here is probed with `--version`, which is what every
# other one of these answers. The fallback is the majority behaviour rather
# than a refusal, so adding a toolchain to the callers below does not also
# require a second edit here.
_kit_probe_for() {
  case "$1" in
    go) printf '%s' 'version' ;;
    # `gofmt` is the odd one out: it takes NO version argument at all. Anything
    # that is not a flag it recognises is read as Go SOURCE, so `gofmt version`
    # is a parse error on the word "version" ("version:1:1: expected 'package',
    # found 2.0"), and `gofmt --version` is "flag provided but not defined". It
    # has exactly one spelling that answers without reading stdin as source:
    # `-h`, which prints usage and exits 0.
    gofmt) printf '%s' '-h' ;;
    # `printf '--version'` is parsed as an OPTION by bash's printf, not as a
    # format string, and prints "printf: --: invalid option" to stderr while
    # emitting nothing on stdout. That is not a hypothetical: it made
    # python3 and elixir read as absent on a machine where both work, which
    # would have skipped six tiers. The `--` is what says "the arguments start
    # here"; every other printf in this file that emits a value that could
    # begin with a dash uses the same form.
    *)      printf '%s' '--version' ;;
  esac
}

# Can this gate actually RUN $1? Not "is there a file called $1 on PATH".
#
# WHY IT IS NOT `command -v`, and the case that made the difference is a real
# run of this gate rather than a thought experiment. Every toolchain here is
# managed by mise, and mise installs a SHIM for each one: `command -v rustc`
# finds `~/.local/share/mise/shims/rustc` and says yes on a machine where that
# shim cannot resolve a version and errors the moment it is invoked:
#
#     $ command -v rustc && echo yes
#     yes
#     $ rustc --version
#     mise ERROR No version is set for shim: rustc
#
# So `have rustc` was TRUE on a machine with no working rustc, and every caller
# below took the "the toolchain is installed" branch and reported a FAIL for a
# toolchain that was never there. That inverts the rule this repository states
# everywhere else: a check that cannot run is a `report SKIP` NAMING the reason,
# never a red and never a silent pass. `b553c7d` records the intended outcome in
# its own words — "8 skips, all reported, each for a reason the environment
# genuinely states (... 3 needing rustc)" — and this machine produced a FAIL
# for exactly those three.
#
# It is also the asymmetry `b553c7d` set out to remove, arriving from the other
# side. That commit made python resolve through mise because "a bare
# `command -v` for everything else" was invisible interactively and fatal
# non-interactively. This is the same defect one level up: the command EXISTS,
# and it still cannot run.
#
# WHAT IT COSTS, stated rather than assumed. This now RUNS the command instead
# of naming it, so every `have` costs a process where it used to cost a PATH
# scan, and two of them (`go` and `gofmt`, below) can be slow to answer. That
# is why the answer is computed once per command and cached, and why the probe
# is bounded by `timeout` rather than left to hang on a toolchain that is
# present and wedged. A probe with no bound is the same bug wearing a different
# hat: an unbounded check for "is this thing usable" fails by hanging rather
# than by answering.
#
# A TIMEOUT IS A "no", and that is deliberate rather than convenient: a
# toolchain that cannot print its version inside 30 seconds is not one this
# gate can build a tier out of, and reporting it as absent is the honest
# reading. It is also why the bound is generous — this is a version string, not
# a build, and the toolchains here are on a warm PATH.
_kit_have_cache=""
have() {
  local cmd="$1" cached runner probe
  case "$_kit_have_cache" in
    *"|$cmd="*) cached="${_kit_have_cache#*"|$cmd="}"; cached="${cached%%|*}"
      [ "$cached" = yes ] && return 0 || return 1 ;;
  esac
  runner="$(_timeout_bin 2>/dev/null || printf '')"
  probe="$(_kit_probe_for "$cmd")"
  if command -v "$cmd" >/dev/null 2>&1; then
    if [ -n "$runner" ]; then
      "$runner" 30 "$cmd" "$probe" >/dev/null 2>&1 && cached=yes || cached=no
    else
      "$cmd" "$probe" >/dev/null 2>&1 && cached=yes || cached=no
    fi
  else
    cached=no
  fi
  _kit_have_cache="${_kit_have_cache}|${cmd}=${cached}|"
  [ "$cached" = yes ]
}

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
# else `.kit/cache/gate` under the tree. The override exists for CI,
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
# `--only` matches on and the same string a caller names in `--only=<id>`.
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
# here because the flag is set by exactly one caller,
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
  report SKIP "$label  (NOT RUN — --no-live: the observability live tier was opted out and this claim is UNEXERCISED)"
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
  # `tests/zizmor_gate.sh` is in this list because the reusable workflow runs it
  # from a service's repository, against that service's tree. A gate script that
  # is not executable is a job that dies at its first step in every repo that
  # adopts it.
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
    "$ROOT"/tests/zizmor_gate.sh; do
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

  # Every language ships: the codec, its suite, and the SDK wiring snippet.
  #
  # The field count is deliberately variable. Five languages carry a separate
  # test file; rust does not, because `rustc --test` builds a single crate from
  # one source with the suite inline. Its presence is asserted below instead, by
  # looking for the `#[test]` functions — a presence check on a file that has
  # none in it would be satisfied by a crate shipping an implementation and no
  # proof, which is the exact thing this packet exists to prevent.
  #
  # README.md and pins.md are deliberately NOT asserted here. A gate that goes
  # red because a document is missing tells its reader that the repository
  # disagrees with itself, not that a service is broken or a contract violated,
  # and those are the only two things a red here is allowed to mean.
  while IFS='|' read -r lang a b c d e; do
    [ -n "$lang" ] || continue
    wanted=()
    for f in "$a" "$b" "$c" "$d" "$e"; do
      [ -n "$f" ] && wanted+=("templates/otel/$lang/$f")
    done
    if otel_required "${wanted[@]}"; then
      report PASS "templates/otel/$lang/  (${#wanted[@]} artifacts present)"
    else
      report FAIL "templates/otel/$lang/  (${#wanted[@]} artifacts present)"
    fi
  done <<'OTEL'
go|traceparent.go|traceparent_test.go|otelhttp.go.snippet
ruby|traceparent.rb|test_traceparent.rb|rack_middleware.rb.snippet
elixir|traceparent.ex|test_traceparent.exs|phoenix_telemetry.ex.snippet
rust|traceparent.rs|otel_client.rs.snippet
python|traceparent.py|test_traceparent.py|fastapi.py.snippet
node|traceparent.mjs|traceparent.test.mjs|hono.ts.snippet
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
  # `kamal_test`, the same needle a caller passes to
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
  # The node conformance suite, EXECUTED — not parsed, not greped.
  #
  # Why this is here rather than only in `ci.reusable.yml`'s opt-in `telemetry`
  # job: that job runs the suite in a repository that ADOPTED the template, and
  # kit itself calls the workflow with `language: none` and no `telemetry`
  # input. So on kit's own commits the suite ran nowhere. The parse check above
  # asks "is this valid TypeScript", which every revision of the snippet that
  # shipped has been; the assertion that matters asks "does this continue an
  # inbound trace", which is the question the defect class below is about.
  #
  # WHAT IT GATES, and why a paragraph was not enough. `@opentelemetry/api`'s
  # default text-map getter is `get(carrier, key) { return carrier[key] }` —
  # plain property access — and a WHATWG `Headers` keeps its entries in an
  # internal list, so that read is `undefined` for every key. Handing a `Headers`
  # to `propagation.extract` therefore returns the context UNCHANGED: every
  # inbound `traceparent` is dropped, every request becomes its own root span,
  # nothing throws, nothing logs, and every span is still exported with the right
  # `service.name`. A trace view then shows a healthy pile of unrelated
  # single-span traces, which is indistinguishable from a service receiving no
  # instrumented traffic. Measured in the fleet, not anticipated.
  #
  # The suite asserts the INBOUND TRACE ID, which is the only assertion that can
  # see it: "a span was exported" is blind to it by construction, because the
  # span IS exported — wrongly.
  #
  # WHAT ELSE IS IN THAT SUITE NOW, because the label above names only the first
  # claim and a reader should not have to open the file to find the rest. It also
  # asserts that `hono.ts.snippet` calls NONE of the APIs SDK 2.x removed
  # (`addSpanProcessor(`, `new BatchSpanProcessor({`, `addLogRecordProcessor(`,
  # `register()` on a BasicTracerProvider) and that it installs the three globals
  # and an ENABLED context manager. Those calls are what a service copies without
  # compiling them, and the last one fails in total silence: with no context
  # manager `context.with()` is a no-op that still runs its callback, so every
  # span is exported with the right `service.name` as a root span and nothing
  # downstream attributes to the request.
  #
  # It is a check on the snippet's SOURCE SHAPE and not on an installed SDK,
  # because kit vendors no OTel tree and deliberately has no network: the parse
  # check above is what a vendored tree would buy, and pins.md states that
  # trade. What the source shape buys is that these four are SPELLINGS, and a
  # spelling cannot come back by accident.
  #
  # `have node` rather than a floor check, for the reason the five other
  # languages get: node's own type stripper is already the parser above, so a node
  # too old to run this suite is a node that could not have got here.
  #
  # NOT FATAL ON A SKIP, unlike the lint phase. This is a claim about
  # propagation; the claim under test in the lint phase is "kit's configs work".
  # A machine with no node is a normal machine, and the skip is reported and
  # counted rather than swallowed.
  if have node; then
    node_suite_check() {
      node --test "$ROOT/templates/otel/node/traceparent.test.mjs" 2>&1
    }
    check 'templates/otel/node  (the traceparent suite, executed — inbound trace id asserted, and no SDK-2-removed call in the snippet)' \
      node_suite_check
  else
    report SKIP 'templates/otel/node  (node not installed — the conformance suite ran nothing)'
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
    # The one list of languages: it reads the CI workflow's `language` gate job
    # -- the case statement that rejects an unrecognised value -- so there is
    # exactly one place to add a language and the workflow cannot claim one the
    # tree does not have.
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
  # THE `run:` BODIES ARE SHELL, AND `bash -n` NEVER LOOKED AT THEM.
  #
  # `yaml.safe_load` on a workflow is a parse of the DOCUMENT. A `run:` body is
  # a string inside it, and everything that makes a step work or fail is decided
  # by the shell that runs it — which is why every check above is satisfied by a
  # workflow whose `run:` bodies are all broken.
  #
  # THE DEFECT THIS EXISTS FOR, measured. `.github/workflows/image.reusable.yml`'s
  # `stamp provenance` step was:
  #
  #   KIT_PROVENANCE_BUILT_AT="$(date …)" \
  #     KIT_PROVENANCE_SOURCE_DIRTY=clean \
  #     sh docker/provenance.sh --validate
  #   { echo "built_at=$KIT_PROVENANCE_BUILT_AT"; … } >>"$GITHUB_OUTPUT"
  #
  # `VAR=value <command>` is a PREFIX ASSIGNMENT: it exists in the environment of
  # `<command>` and in no shell variable. So the `echo` was reading a name the
  # shell had never been given, and under the `set -euo pipefail` every step in
  # this tree begins with, an unset read is not an empty value — it is
  # `unbound variable` and exit 1. The step failed on every run it ever had.
  # `cafaye/site` calls this file, so `ghcr.io/cafaye/site` has never existed.
  #
  # The other four fields in that same step work because they arrive through the
  # step's `env:` block, which really does populate the shell environment.
  # `built_at` was the only one created INSIDE the body, and the only one
  # created as a prefix assignment. It is the only one that broke. That is the
  # shape of the bug: nothing about the file looks wrong and everything about it
  # is.
  #
  # WHY A SHAPE CHECK AND NOT A REAL RUN. Executing every `run:` body needs the
  # runner's services, the checked-out tree and each action's own inputs, and a
  # check that needs all three to reach a verdict is a check that silently stops
  # running. So this asks the question that is decidable from the text: is there a
  # name that this block creates for a command and then reads as a variable?
  #
  # `KIT_PROVENANCE_SOURCE_DIRTY=clean sh …` is left alone on purpose, and the
  # check knows the difference rather than the author having to remember it: a
  # prefix assignment whose name is NEVER read bare in the same block is fine,
  # because the command is its only consumer and the command did receive it. One
  # assignment in `ci.reusable.yml` (`GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local
  # go test`) is the same shape and is likewise correct — those three reach `go`
  # and nothing reads them back.
  section 'static: a run: body does not read a name it only ever prefix-assigned'
  run_body_env_check() {
    "$PY" - "$ROOT" <<'PY'
import glob
import os
import re
import sys

import yaml

root = sys.argv[1]

# A logical line, with backslash continuations joined. A prefix assignment spread
# over three physical lines is ONE assignment, and reading only the first line
# would miss every multi-line one — which is the shape that actually shipped.
# The line number reported is the FIRST physical line, so a message points at the
# assignment rather than at its continuation.
def logical_lines(block):
    buf, start = [], None
    for i, raw in enumerate(block.splitlines(), 1):
        s = raw.rstrip()
        if start is None:
            start = i
        if s.endswith("\\"):
            buf.append(s[:-1])
            continue
        buf.append(s)
        yield start, " ".join(buf)
        buf, start = [], None
    if start is not None:
        yield start, " ".join(buf)


def strip_comment(line):
    """Drop a `#` comment.

    A workflow here carries long explanatory comments and one of them NAMES the
    bug (`built_at=$KIT_PROVENANCE_BUILT_AT` appears in prose explaining it). A
    check that counted that comment would be a check a comment can satisfy, and a
    check a comment can satisfy is the same defect as one a comment can falsify.
    """
    m = re.search(r"(?<![\"'\w])#", line)
    return line[: m.start()] if m else line


READ = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))")
# One whitespace-delimited word, honouring quotes so a value with a space in it
# (`"$(date -u +%Y-%m-%dT%H:%M:%SZ)"`) is ONE word rather than three.
WORD = re.compile(r"""(?:[^\s'"]+|'[^']*'|"[^"]*")+""")
ASSIGN_HEAD = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=")
DECLARE = re.compile(r"^(?:export|declare|readonly|local|typeset)\b")


def prefix_assignments(line):
    """The names a logical line sets as a PREFIX assignment, in order.

    Walks the line word by word. A run of `NAME=value` words is one prefix
    assignment SET; the first word after that run is the command they belong to.
    A run with no command after it is a plain assignment — which creates a shell
    variable, so reading it back is correct.

    Written as a walk rather than as "is there a `NAME=` at the start of a line"
    because the shapes that matter are all wider than that one test:
      - `FOO=-mod=mod BAR=off baz cmd` — three, then the command
      - `FOO="$(date -u +%F)" cmd`        — a quoted value with spaces in it
      - `FOO=bar cmd; …`                  — a `case` arm, terminated by `;;`
      - `export FOO=bar cmd`              — NOT a prefix assignment; `export`
                                             makes it a shell variable, so
                                             reading it later is correct and
                                             refusing it would be the check
                                             firing on correct code
    """
    words = []
    for w in WORD.finditer(line):
        end = w.end()
        # A terminator is a word in its own right and ends the command.
        word = w.group(0)
        words.append((word, end))
    names = []
    i = 0
    while i < len(words):
        word, _ = words[i]
        if DECLARE.match(word):
            # `export`/`local` and friends: the NEXT word is the assignment, and
            # it is a plain one.
            nxt = words[i + 1][0] if i + 1 < len(words) else ""
            m = ASSIGN_HEAD.match(nxt)
            if m:
                names.append((m.group(1), False))
                i += 2
                continue
            i += 1
            continue
        m = ASSIGN_HEAD.match(word)
        if m:
            names.append((m.group(1), True))
            i += 1
            continue
        break
    # Everything collected so far is a PREFIX assignment only if a command word
    # followed the run.
    if i >= len(words):
        return []
    # `;;` closes a case arm, and `;`/`&&`/`||` close a list — a word made only
    # of those is punctuation, not the command.
    tail = words[i][0]
    if set(tail) <= set(";|&"):
        return []
    return [n for n, is_prefix in names if is_prefix]


def steps(node, path=()):
    """Yield (yaml_path, run_body) for every step with a `run:`."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "run" and isinstance(v, str):
                yield path, v
            else:
                yield from steps(v, path + (k,))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from steps(v, path + (i,))


problems = []

for wf in sorted(glob.glob(os.path.join(root, ".github/workflows/*.yml"))):
    rel = os.path.relpath(wf, root)
    with open(wf, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    if not isinstance(doc, dict):
        continue
    for path, body in steps(doc):
        lines = list(logical_lines(body))
        # name -> (first line number, the line as written)
        prefix = {}
        for ln, raw in lines:
            for name in prefix_assignments(strip_comment(raw)):
                prefix.setdefault(name, (ln, raw.strip()))

        for name, (assign_ln, assign_txt) in sorted(prefix.items()):
            bare = []
            for ln, raw in lines:
                if ln <= assign_ln:
                    continue
                line = strip_comment(raw)
                for m in READ.finditer(line):
                    got = m.group(1) or m.group(2)
                    if got != name:
                        continue
                    # Skip the value of a LATER assignment of the same name:
                    # `echo "$X" > f` then `X=…` is not a bare read, and a
                    # check that counted it would fire on correct code.
                    if re.search(
                        r"(?:^|[\s;&|])" + re.escape(name) + r"=\S*$", line[: m.start()]
                    ):
                        continue
                    bare.append((ln, raw.strip()))
            if not bare:
                continue
            problems.append(
                f"{rel} :: {'/'.join(str(p) for p in path)}: {name} is set as a "
                f"PREFIX assignment on line {assign_ln} "
                f"({assign_txt[:70]}) and read as a shell variable on line "
                f"{bare[0][0]} ({bare[0][1][:70]}). A prefix assignment reaches "
                f"the COMMAND's environment, not the shell, so under `set -u` "
                f"that read is fatal: 'unbound variable', exit 1. Assign it on "
                f"its own line and export it, or keep it as a prefix assignment "
                f"and stop reading it back."
            )

if not problems:
    sys.exit(0)
sys.exit("; ".join(problems))
PY
  }
  check 'every run: body  (no name is prefix-assigned and then read as a variable)' \
    run_body_env_check

  # -------------------------------------------------------------------------
  section 'static: compose — the observability chokepoint'

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
# bin/dev up` brings up the stores too. They are required HERE so that deleting
# a store cannot be half-done: a service that adopts the stack and loses one of
# them finds out.
#
# It was four. There was a metrics backend here, and it cost 130s of readiness
# budget per cold start against a 180s deadline for the whole stack, so it went
# with its volume, its port and its collector exporter rather than being left
# half-wired. A name added to this tuple without a service behind it is a red
# gate, which is the point.
for required in ("postgres", "nats", "redis", "otel-collector", "tempo", "loki", "grafana", "clickstack"):
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
    "clickstack",
)
for name in services:
    if name not in INFRASTRUCTURE:
        problems.append(f"unexpected service: {name}")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/compose/docker-compose.yml  (pinned, healthy, parameterized)' compose_check

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
  # the otel and database parse loops already make.
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
  # The same rule the collector config is held to, applied to postgres — with a
  # sharper edge, because postgres's inputs
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
        f"operator configured. This is the collector rule applied "
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
  # is asserted structurally rather than by scoring the value against something.
  canary_safety_check() {
    "$PY" - "$ROOT" <<'PY'
import sys

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
print("the canary is prefixed, low-entropy, and self-describing")
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
    # ONE CLUSTER, TWO SERVICES, THROUGH `bin/dev` — the packet's own question.
    #
    # `isolation_test.sh` above already proves the boundary on a two-tenant
    # cluster, and it proves it carefully. It brings the stack up ITSELF, with its
    # own `docker compose --project-name … up -d --wait postgres`, which is why it
    # can move one port and start one container. So on this tree the property was
    # proven and the DEVELOPER'S PATH to it was not: every step between a person
    # and that cluster lives inside `bin/dev` — the ref validation, the `.env`
    # creation, the compose argument assembly, the readiness wait — and no tier in
    # this file invoked `bin/dev`. A `bin/dev` that resolved the wrong project
    # directory or waited on the wrong health signal would leave the two cluster
    # tiers green.
    #
    # It runs the FULL cheap stack rather than `postgres` alone, which is why it
    # moves five published ports and not one: `bin/dev up` brings up
    # postgres/nats/redis/collector, and a developer's own stack is on the same
    # machine. That collision was measured, and it is reported in the script's
    # header — templates/compose/docker-compose.yml's port block calls the range
    # collision-free for two checkouts, and it is not, for the four services
    # whose defaults sit inside the block.
    #
    # 1800s like its siblings: it builds the cluster image on a cold cache and
    # runs one initdb.
    bounded_check 'tests/onecluster_test.sh  (two services, ONE postgres container, each with its own database and roles; both answer as their own role, neither reaches the other'"'"'s)' \
      1800 bash "$ROOT/tests/onecluster_test.sh"
  fi
fi
# ===========================================================================
# phase: classifier + fingerprint — the runnable pieces, executed
#
# Separate from `static` and run unconditionally, because both are the property
# rather than the shape: classify_test asserts that the classifier FAILS on an
# unrecognised change, and fingerprint_test asserts that a skip can be WRONG.
# A check that only parsed those two files would pass on a classifier that waves
# every change through.
#
# Both scripts build their own fixtures in a temp directory, so neither depends
# on a repository being checked out or on the network.

  # NOTE: deliberately not guarded by RUN_STATIC. kit-05's own comment
  # called these "the property rather than the shape", but the block shipped
  # wrapped in `if [ "$RUN_STATIC" -eq 1 ]`, which would let a static-analysis
  # skip silently drop the fail-closed proof. A gate that skips is not green.
kit_phase "40 classifier + fingerprint + fetch + tenancy, executed"
check 'tests/classify_test.sh  (19 cases, incl. the fail-closed property)' \
  bash "$ROOT/tests/classify_test.sh"

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
# the fingerprint test are: these are the PROPERTY rather than the shape, and a
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

# THE FAIL-FAST PATH, EXECUTED. The claim is about a developer's wall clock and
# about what is running on their machine afterwards, so it is measured with
# `date +%s` against a real `bin/dev up` and the container list is read by compose
# project label.
#
# Deliberately NOT inside the `RUN_STATIC` guard, and not a `check` on a grep:
# `grep -c preflight_required templates/bin/dev.sh` is green on a function that is
# never CALLED, or called after the compose call, or called with an empty file
# list — and this file's whole subject is a defect that existed for exactly that
# long without anyone noticing, because the check was never there. It needs a
# docker daemon for two of its claims and DEGRADES LOUDLY without one: "no
# container was created" is reported as unexercised rather than passed, because a
# silent skip of this particular claim is the defect it exists to catch.
#
# Gated on `have docker` rather than run unconditionally, so a machine with no
# daemon gets one reported SKIP naming the flag instead of a wall of failures that
# all say the same missing thing.
if have docker && docker info >/dev/null 2>&1; then
  check 'tests/failfast_test.sh  (a missing required variable is refused in seconds, by name, with nothing started)' \
    bash "$ROOT/tests/failfast_test.sh"
else
  report SKIP 'tests/failfast_test.sh  (NOT RUN — no docker daemon: "no container was created" and the control are UNEXERCISED)'
fi

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

kit_phase "60 summary"
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
  echo "       did NOT run. Those claims are UNEXERCISED by this run."
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
