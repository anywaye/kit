#!/usr/bin/env bash

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

compose_progress() {
  grep -qE '^[[:space:]]*(Network|Container|Volume) .* (Creating|Created)' "$1"
}

SVC="$WORK/service"
mkdir -p "$SVC/bin"
cp "$DEV" "$SVC/bin/dev"
chmod +x "$SVC/bin/dev"
printf '0123456789abcdef0123456789abcdef01234567\n' >"$SVC/kit.ref"

run_dev() {
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

if [ "$RUN_ELAPSED" -lt 10 ]; then
  pass "refused in ${RUN_ELAPSED}s (budget 10s)"
else
  fail "refused in ${RUN_ELAPSED}s, over the 10s budget"
fi

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

if docker info >/dev/null 2>&1; then
  made="$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
    --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$made" -eq 0 ]; then
    pass "no container was created for project $PROJECT"
  else
    fail "$made container(s) created for project $PROJECT: $(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Names}}' | tr '\n' ' ')"
  fi
else
  fail "claim 3 unexercised: no docker daemon, so 'no container was created' was NOT checked"
fi

if compose_progress "$WORK/unset.out"; then
  fail "the run reached docker compose despite the missing variable"
else
  pass "the run never reached docker compose"
fi

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

printf 'KIT_POSTGRES_DATABASES=alpha,beta\n' >"$SVC/.env"
if ! docker info >/dev/null 2>&1; then
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