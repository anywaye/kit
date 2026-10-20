#!/usr/bin/env bash
#
# `bin/dev` refuses a stack it cannot interpolate, BEFORE it starts anything.
#
#   bash tests/failfast_test.sh
#
# WHAT IT CLAIMS, and the shape of each claim
# --------------------------------------------
#   1. A compose file that interpolates a variable with no default is REFUSED,
#      and the refusal names the variable.
#   2. It arrives in SECONDS. The budget is 10s and it is measured, not asserted
#      from the clock.
#   3. NO CONTAINER IS CREATED. Asserted against the compose project's own
#      label, not against "docker ps looks the same", because a developer's own
#      stack is running on the machine this suite shares.
#   4. It names HOW to set it — a line the developer can paste.
#   5. SET-AND-EMPTY is the same as unset, which is the state `ensure_env` puts a
#      fresh clone into. This is the case that had to be got right and the one a
#      presence check would pass.
#   6. THE CONTROL: with the variable SET, the preflight passes and the run
#      REACHES compose. Without it, claims 1-5 are satisfied by a preflight that
#      refuses unconditionally — which is not a preflight, it is a gate that
#      happens to be red.
#   7. The required set is DERIVED from the compose files, so a service's OWN
#      bare `${VAR}` is caught and one carrying a `:-` default is not.
#
# IT CAN GO RED, AND THAT WAS MEASURED
# -------------------------------------
# With the single call to `preflight_required` removed from `up()` — one line, in
# this repository's own tree, restored with `git checkout` — this suite reports
# **5 failed assertions**:
#
#   FAIL the refusal did not name KIT_POSTGRES_DATABASES
#   FAIL the refusal named the variable but not how to set it
#   FAIL 4 container(s) created for project kit-failfast-13977
#   FAIL the run reached docker compose despite the missing variable
#   FAIL with KIT_POSTGRES_DATABASES set the run still never reached compose
#
# The last one is the one worth reading twice, because it is a FALSE FAILURE and
# the suite caught its own assertion rather than the code: `compose_progress`
# anchored at `^`, docker compose indents its output, and a control run that had
# demonstrably created three containers was reported as never reaching compose.
# A teardown that named `postgres-1`, `postgres-data` and `platform` then left
# those three containers and two volumes behind on the machine. Both are fixed —
# the pattern allows leading whitespace, and cleanup sweeps by project label — and
# both are recorded because the shape recurs: an assertion that cannot see the
# evidence in front of it, and a teardown that quietly stops covering the stack.
#
# Note also which assertions stayed GREEN under that mutation, because they are
# the ones that would have been mistaken for proof: "an uninterpolatable stack is
# refused" and "refused in 3s (budget 10s)" both passed with the preflight gone.
# The stack failed, just later and for the wrong reason. A non-zero exit is not
# evidence of a refusal, which is why claims 1, 3 and 4 are asserted on the
# message and on the world rather than on the status.
#
# WHY IT NEEDS NO DOCKER AND WHY THAT IS THE POINT
#   The preflight reads two files and the environment. A suite that had to start
#   a container to observe that no container was started would be both slow and
#   unable to make the claim cheaply. Claim 3 is the one place docker is asked
#   anything at all, and it degrades to a reported SKIP rather than a pass when
#   there is no daemon — a skip nobody can see is a silent pass, and this file's
#   subject is precisely a failure nobody could see.
#
# WHY IT IS EXECUTED AND NOT PARSED
#   `grep -c 'preflight_required' templates/bin/dev.sh` would be green on a
#   function that is never called, or called after the compose call, or called
#   with an empty file list. Every assertion below reads a real subprocess's real
#   output and the real elapsed time. The claim is about what a developer
#   experiences, so it is measured the way a developer experiences it.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV="$ROOT/templates/bin/dev.sh"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}
say() { printf '   %s\n' "$1"; }

[ -r "$DEV" ] || {
  fail "fail-fast: $DEV is not readable"
  exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-failfast.XXXXXX")"
cleanup() {
  # Everything is reached BY PROJECT LABEL, not by naming four containers.
  #
  # The first version named `postgres-1`, `postgres-data` and `platform` and left
  # the rest of the stack behind — and the run that found it had created
  # `otel-collector-1`, `nats-1` and `redis-1` and two volumes, none of which the
  # teardown reached. A teardown that names what it expects to find is a teardown
  # that silently stops cleaning up the moment the stack gains a service, and the
  # residue is on the developer's machine rather than in a CI log. The label is
  # derived from THIS RUN, so the sweep reaches only its own containers: a
  # namespace has to come from the run, or two concurrent runs share one stack.
  if [ -n "${PROJECT:-}" ]; then
    docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" 2>/dev/null |
      xargs -r docker rm -f >/dev/null 2>&1 || true
    docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" 2>/dev/null |
      xargs -r docker volume rm >/dev/null 2>&1 || true
    docker network ls -q --filter "label=com.docker.compose.project=$PROJECT" 2>/dev/null |
      xargs -r docker network rm >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

PROJECT="kit-failfast-$$"

# compose_progress <file> — did this run reach docker compose?
#
# COMPOSE INDENTS ITS OUTPUT, so the pattern allows leading whitespace. The first
# version anchored at `^` and the CONTROL failed on a run that had demonstrably
# created three containers — the assertion could not see evidence that was right
# there, which is the same class of defect AGENTS.md records for a check whose
# needle is a paraphrase rather than the thing itself. Spelled as a function so
# the three call sites cannot drift apart.
compose_progress() {
  grep -qE '^[[:space:]]*(Network|Container|Volume) .* (Creating|Created)' "$1"
}

# ---------------------------------------------------------------------------
# The fixture: a service directory holding kit's own `bin/dev` and a `kit.ref`.
# ---------------------------------------------------------------------------
# `bin/dev` is COPIED rather than symlinked or invoked in place, because the
# contract under test is the one a service gets: `templates/bin/dev.sh` copied to
# `bin/dev` at the service root, with `cd "$(dirname "$SELF")/.."` deciding where
# `.env` and `kit.ref` live. Running it from this repository's own root would put
# the fixture's `.env` beside this repository's and test a different script.
#
# The pin is a real 40-char hex sha, because `validate_ref` refuses anything else
# BEFORE the fetch and the refusal would be a green run that never reached the
# preflight. `KIT_STACK_DIR` names the tree explicitly, which is source 1 of the
# four in `resolve_stack` and the one that skips the network; the fetch machinery
# itself is `tests/fetch_test.sh`'s subject, not this file's.
SVC="$WORK/service"
mkdir -p "$SVC/bin"
cp "$DEV" "$SVC/bin/dev"
chmod +x "$SVC/bin/dev"
printf '0123456789abcdef0123456789abcdef01234567\n' >"$SVC/kit.ref"

run_dev() {
  # The clock starts before the process and stops after it, so the number
  # includes bash startup and the file copy of nothing — it is the whole time a
  # developer would wait. `env -i` is NOT used: the ambient environment is what a
  # developer actually has, and stripping it would make the measurement a claim
  # about a machine that does not exist.
  local out="$1"
  shift
  local started ended
  started=$(date +%s)
  ( cd "$SVC" && KIT_STACK_DIR="$ROOT" KIT_STACK_NAME="$PROJECT" "$@" ./bin/dev up ) \
    >"$out" 2>&1
  RUN_EXIT=$?
  ended=$(date +%s)
  RUN_ELAPSED=$((ended - started))
}

# ---------------------------------------------------------------------------
# CLAIM 1-4, 5: unset. This is the state a fresh clone is in, because
# `ensure_env` copies `.env.example`, which ships the key with nothing after it.
# ---------------------------------------------------------------------------
rm -f "$SVC/.env"
run_dev "$WORK/unset.out"

say "== an unset required variable =="
say "   exit=$RUN_EXIT  elapsed=${RUN_ELAPSED}s"
sed 's/^/   /' "$WORK/unset.out" | sed -e 's/\x1b\[[0-9;]*m//g' | tail -30

if [ "$RUN_EXIT" -eq 0 ]; then
  fail "an uninterpolatable stack exited 0"
else
  pass "an uninterpolatable stack is refused (exit $RUN_EXIT)"
fi

# Claim 2, MEASURED. 10s, and the number is printed either way so a run that
# passes at 9.8s is visible as a run that is nearly failing.
if [ "$RUN_ELAPSED" -lt 10 ]; then
  pass "refused in ${RUN_ELAPSED}s (budget 10s)"
else
  fail "refused in ${RUN_ELAPSED}s, over the 10s budget"
fi

# Claim 1 and 4: the variable is named, and the message says how to set it.
case "$RUN_ELAPSED" in : ) ;; esac
if grep -q 'KIT_POSTGRES_DATABASES' "$WORK/unset.out"; then
  pass "the refusal names KIT_POSTGRES_DATABASES"
else
  fail "the refusal did not name KIT_POSTGRES_DATABASES"
fi
if grep -q 'KIT_POSTGRES_DATABASES=<value>\|KIT_POSTGRES_DATABASES=alpha,beta' "$WORK/unset.out"; then
  pass "the refusal prints the line to set it"
else
  fail "the refusal named the variable but not how to set it"
fi

# Claim 3, and the asymmetry that matters: a refusal that merely mentions the
# variable is not a refusal. Assert on the ACTUAL run, in a directory where the
# only compose project that could be created is this run's own.
if docker info >/dev/null 2>&1; then
  made="$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
    --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$made" -eq 0 ]; then
    pass "no container was created for project $PROJECT"
  else
    fail "$made container(s) created for project $PROJECT: $(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Names}}' | tr '\n' ' ')"
  fi
else
  # Reported, counted, and not a pass. This file's subject is a failure that
  # reported itself; a check for that which SKIPS quietly is the same defect one
  # layer down.
  fail "claim 3 unexercised: no docker daemon, so 'no container was created' was NOT checked"
fi

# The output must not contain a compose progress line. `up -d --wait` prints
# `Network … Created` / `Container … Created`, and their absence is the same
# claim as the label count above from the other side: one is what the world
# looks like afterwards, the other is what this run printed while it happened.
if compose_progress "$WORK/unset.out"; then
  fail "the run reached docker compose despite the missing variable"
else
  pass "the run never reached docker compose"
fi

# ---------------------------------------------------------------------------
# CLAIM 5: set to EMPTY. Same failure, and the reason a presence check would be
# the wrong check: `.env.example` ships exactly this line.
# ---------------------------------------------------------------------------
printf 'KIT_POSTGRES_DATABASES=\n' >"$SVC/.env"
run_dev "$WORK/empty.out"
say ""
say "== the same variable, set to EMPTY (what a fresh clone gets) =="
say "   exit=$RUN_EXIT  elapsed=${RUN_ELAPSED}s"
if [ "$RUN_EXIT" -ne 0 ] && grep -q 'KIT_POSTGRES_DATABASES' "$WORK/empty.out"; then
  pass "set-and-empty is refused like unset"
else
  fail "set-and-empty was accepted (exit $RUN_EXIT): $(tail -3 "$WORK/empty.out" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# CLAIM 6, THE CONTROL. Set, non-empty: the preflight passes and the run reaches
# compose. This is what makes claims 1-5 mean something — a preflight that
# refuses unconditionally satisfies all five and is not a preflight.
#
# `bin/dev up` then runs `migrate` and `seed` after the stack, and this service
# has neither, so the run ends nonzero for a DIFFERENT and named reason. That is
# fine and is why this assertion is about REACHING compose rather than about the
# exit status: the control proves the preflight let the run past, and conflating
# that with the stack's own outcome would make this assertion depend on whether a
# four-container stack came up inside a unit test's time budget.
# ---------------------------------------------------------------------------
printf 'KIT_POSTGRES_DATABASES=alpha,beta\n' >"$SVC/.env"
if ! docker info >/dev/null 2>&1; then
  # Without a daemon there is no `up` to reach. Not a pass, not a fail: the
  # control is unexercised and that is the claim being made.
  say ""
  say "== the control: the variable SET =="
  fail "the control is unexercised: no docker daemon, so 'the preflight lets a set variable past' was NOT checked"
else
  run_dev "$WORK/set.out"
  say ""
  say "== the control: the variable SET to alpha,beta =="
  say "   exit=$RUN_EXIT  elapsed=${RUN_ELAPSED}s"
  if compose_progress "$WORK/set.out"; then
    pass "a set variable reaches docker compose — the preflight is not refusing unconditionally"
  else
    fail "with KIT_POSTGRES_DATABASES set the run still never reached compose: $(tail -5 "$WORK/set.out" | tr '\n' ' ')"
  fi
  if grep -q 'required by the compose file' "$WORK/set.out"; then
    fail "the preflight refused a stack whose variable was set"
  else
    pass "the preflight does not fire when the variable is set"
  fi
fi

# ---------------------------------------------------------------------------
# CLAIM 7: the required set is DERIVED, not restated. A service that introduces
# its own bare `${VAR}` in its own compose file gets the same fast refusal — and
# this is the assertion that says so, because a `KIT_POSTGRES_DATABASES` hardcoded
# into the script would pass claims 1-6 and fail this one.
# ---------------------------------------------------------------------------
cat >"$SVC/docker-compose.yml" <<'OVERRIDE'
---
services:
  widget:
    image: busybox:${WIDGET_IMAGE_TAG:-alpine}
    environment:
      LABEL: ${WIDGET_LABEL}
OVERRIDE
printf 'KIT_POSTGRES_DATABASES=alpha,beta\n' >"$SVC/.env"
run_dev "$WORK/own.out"
say ""
say "== a service's OWN compose file needing a variable of its own =="
if [ "$RUN_EXIT" -ne 0 ] && grep -q 'WIDGET_LABEL' "$WORK/own.out"; then
  pass "a service's own required variable is refused and named too"
else
  fail "WIDGET_LABEL was not caught (exit $RUN_EXIT): $(tail -4 "$WORK/own.out" | tr '\n' ' ')"
fi
# ...and WIDGET_IMAGE_TAG carries a shell default in the override above, so it
# must NOT be listed. A check that reported every `${VAR}` would be wrong, and
# this is the case that says so.
if grep -q 'WIDGET_IMAGE_TAG' "$WORK/own.out"; then
  fail "WIDGET_IMAGE_TAG was reported, but it carries a :- default and is not required"
else
  pass "a variable with a :- default is not reported as required"
fi
rm -f "$SVC/docker-compose.yml"

printf '\n'
if [ "$failures" -eq 0 ]; then
  printf 'fail-fast: all assertions passed\n'
  exit 0
fi
printf 'fail-fast: %s assertion(s) failed\n' "$failures"
exit 1