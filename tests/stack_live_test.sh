#!/usr/bin/env bash
#
# kit's proof that the FETCHED stack actually runs, and that traces arrive in
# the store behind them and derived metrics reach the only place there is one.
#
#   bash tests/stack_live_test.sh
#
# WHY THIS EXISTS, AND WHY IT IS NOT `docker compose config`
#   `docker compose config` proves a file parses. It has been green on a stack
#   that could not start, on a collector whose exporters pointed at a port
#   nothing was listening on, and on a bind mount naming a directory four
#   containers later. kit's own history says so twice: the collector's
#   `environment:` block was missing, so every `${env:}` resolved empty and the
#   collector exited naming a memory limiter; and a store's healthcheck named a
#   directory, so the stack came up and then reported one unhealthy service for
#   two minutes.
#
#   So this brings the whole thing up, sends it a real OTLP payload, and reads
#   the data back out of Tempo over HTTP. If the fetch produced a tree that
#   cannot run, nothing here can pass.
#
# WHAT IS PROVED, IN ORDER
#   1. `bin/dev` fetches kit at a pinned ref and the STACK COMES UP HEALTHY —
#      every container, `--wait`, no sleeps.
#   2. The collector is running the fetched `otel-collector.yml`, not a copy
#      from the working tree. Asserted by diffing the container's mounted file
#      against the fetched one.
#   3. A TRACE arrives in Tempo, with the resource attributes the redaction
#      boundary is supposed to preserve.
#   4. A DERIVED METRIC reaches the collector's own stdout, under the `anywaye_`
#      namespace the spanmetrics connector mints, with the high-cardinality
#      dimensions gone. There is no metrics STORE and there has not been one
#      since it cost 130s of readiness budget per cold start; where the data
#      goes is the collector's `debug` exporter, and this reads it there.
#   5. The redaction boundary held ON THE LIVE STACK: the canary is in the
#      trace store and in neither the exported attributes nor the exported
#      metric. `canary_test.sh` proves the same property against a substituted
#      exporter; this proves it against the real fan-out, which is the only way
#      to know it is wired to what ships and not to nowhere.
#
# THE REMOTE IS LOCAL
#   A bare repository is built from this tree and fetched over `file://`, so the
#   fetch is the real one and the suite needs no network. The stack then runs
#   from the FETCHED TREE, not from the working tree — which is the property
#   under test, and the reason `$ROOT` never appears as a mount source below.
#
# EVERYTHING IS A THROWAWAY
#   Its own compose project name, its own `KIT_STACK_HOME`, and
#   `down --volumes` on the way out. No port outside 15000-15999 is touched, and
#   `KIT_STACK_NAME` is suffixed with this run's pid so two runs cannot collide.
#
# NO SLEEPS. Every wait is a poll on a health or content signal with a deadline.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-stack.XXXXXX")"
# ONE name, used for the compose project AND for the prefix on every container,
# volume and network. They were two variables once — `PROJECT` for `docker
# compose -p` and `STACK_NAME` for `KIT_STACK_NAME` — and they were not equal,
# because `STACK_NAME` was `kit-stack-$PROJECT` and the project was
# `kit-stack-$$`. Every `docker compose -p "$PROJECT"` in this file therefore
# addressed a project that did not exist, and the OTLP send reported HTTP 000
# from a container that answered 200 when asked by hand. A helper that names the
# project differently from the thing that creates it is a helper that silently
# inspects nothing.
PROJECT="kit-stack-$$"
STACK_NAME="$PROJECT"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
note() { printf 'NOTE  %s\n' "$1"; }

CANARY="CANARY-4e8b2a91-DO-NOT-SHIP"

cleanup() {
  # KIT_KEEP_WORKDIR=1 keeps the containers up too, not just the tree — a
  # failure that is "eight containers did not become healthy" cannot be read out
  # of a stopped project.
  [ "${KIT_KEEP_WORKDIR:-0}" = "1" ] ||
    (cd "$SERVICE" 2>/dev/null && bash ./bin/dev nuke >/dev/null 2>&1) || true
  # KIT_KEEP_WORKDIR=1 leaves the throwaway tree, its compose project and its
  # log behind. A docker test whose failure mode is "eight containers did not
  # become healthy" is not debuggable from its own summary, and the alternative
  # is re-deriving the setup by hand every time — which is how a test ends up
  # being "fixed" by changing the thing that was being investigated.
  if [ "${KIT_KEEP_WORKDIR:-0}" = "1" ]; then
    printf 'NOTE  keeping %s and the compose project %s\n' "$WORK" "$PROJECT" >&2
    return 0
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# wait_for <label> <deadline-seconds> <command...>
#
# A poll, not a sleep, and the label goes into the timeout message — a bare
# "timed out" on a container that exited two seconds in is the least useful
# thing this script could print.
wait_for() {
  local label="$1" deadline="$2"
  shift 2
  local start now out
  start=$(date +%s)
  while :; do
    if out="$("$@" 2>&1)"; then
      return 0
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$deadline" ]; then
      printf 'timed out after %ss waiting for: %s\n' "$deadline" "$label"
      printf '%s\n' "$out" | tail -20 | sed 's/^/        /' || true
      return 1
    fi
    sleep 1
  done
}

if ! docker info >/dev/null 2>&1; then
  echo "SKIP  stack live proof (docker daemon not reachable)"
  exit 0
fi

# ---------------------------------------------------------------------------
# The remote, and the service sandbox
# ---------------------------------------------------------------------------
REMOTE="$WORK/kit-remote.git"
SEED="$WORK/seed"
mkdir -p "$SEED"
# Built from the working tree, for the reason `fetch_test.sh` spells out: a
# remote holding the last COMMIT would make every "the fetched bytes are the
# shipped bytes" assertion compare this packet against the packet before it.
# `tar` over the tree and NOT `git ls-files`, because this has to work in a
# directory that is not a git repository — which is exactly what
# `self_test.sh`'s throwaway copies are. It was `git ls-files`, and the
# consequence was the sharpest failure mode this file could have: the self-test
# CONTROL went red, because a break of nothing at all was reported as a broken
# gate. A control that is red is not a control.
(cd "$ROOT" && tar -cf - --exclude=./.git --exclude=./.venv --exclude=./__pycache__ .) |
  (cd "$SEED" && tar -xf -)
git -C "$SEED" init -q
git -C "$SEED" add -A
git -C "$SEED" -c user.email=t@example.invalid -c user.name=kit13 commit -q -m "seed"
git clone --bare --quiet "$SEED" "$REMOTE"
rm -rf "$SEED"
PIN="$(git -C "$REMOTE" rev-parse HEAD)"

SERVICE="$WORK/service"
mkdir -p "$SERVICE/bin"
cp "$ROOT/templates/bin/dev.sh" "$SERVICE/bin/dev"
chmod +x "$SERVICE/bin/dev"

# ---------------------------------------------------------------------------
# A free slice of the port block
# ---------------------------------------------------------------------------
# The stack publishes nine fixed host ports, and kit's block is 15000-15999 —
# so two runs of this script at once, or a developer's own stack, collide. The
# house rule is "use your own compose project name", and a project name is not
# enough here: the ports are a second, independent resource and they have to be
# allocated too.
#
# Probed rather than derived from $$: a pid-derived offset collides with another
# pid's, and a collision is a confusing `port is already allocated` from a test
# that has nothing wrong with it. A bind attempt is the honest question — "is
# anything listening here" — and the answer is a boolean.
pick_port_base() {
  local base port p
  for base in $(seq 15000 10 15980); do
    local free=1
    for p in 0 500 600 700 800 900 901 902; do
      port=$((base + p))
      if ! port_is_free "$port"; then
        free=0
        break
      fi
    done
    [ "$free" -eq 1 ] && {
      printf '%s' "$base"
      return 0
    }
  done
  echo "SKIP  stack live proof (no free slice of the 15000-15999 block)" >&2
  return 1
}

# A port is free if nothing is LISTENING on it. `nc -z` is not assumed to exist
# and neither is python; bash's own /dev/tcp is the dependency-free answer, and
# it is exactly the question being asked — can something connect to it.
port_is_free() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && {
    exec 3<&- 2>/dev/null || true
    return 1
  }
  return 0
}

PORT_BASE="$(pick_port_base)" || exit 0
note "using host ports $PORT_BASE-$((PORT_BASE + 902)) (a free slice of kit's 15000-15999 block)"

# The service's own compose file: an OVERRIDE, and deliberately a small one that
# exercises the two rules most likely to be got wrong — it names no `ports:`
# (because a `ports:` entry APPENDS rather than replaces), and it does not touch
# the collector.
cat >"$SERVICE/docker-compose.yml" <<'YAML'
# The service's own compose file, after this packet. Three things it owns: its
# image, its own database name, and the fact that it exists. Everything else
# comes from the pinned kit ref.
#
# Note what is NOT here: a `ports:` entry for postgres. It is tempting, and it is
# wrong — compose APPENDS a second file's `ports:` list to the first rather than
# replacing it, so writing one publishes postgres on 15500 *and* on whatever you
# asked for. The port moves in .env, which is what the override below does.
services:
  probe:
    image: curlimages/curl:8.10.1
    entrypoint: ["sleep", "infinity"]
    networks: [platform]
    # A relative bind mount, and the third thing a service legitimately owns.
    # It resolves against the project directory — which is why `bin/dev` passes
    # `--project-directory .` explicitly: without it, compose would resolve this
    # against the FETCHED stack's directory and mount kit's repository here.
    volumes:
      - ./payload:/payload:ro
YAML
printf '%s\n' "$PIN" >"$SERVICE/kit.ref"
# This heredoc is UNQUOTED on purpose — `$REMOTE`, `$WORK` and the port
# arithmetic have to expand. The price of that is that it is also a script: a
# backtick in anything written between `<<ENV` and the closing `ENV` is a
# command substitution and bash will run it. An earlier version of this comment
# sat INSIDE the heredoc and every backticked word in it was executed —
# `docker-compose.yml`, `bin/dev`, `isolation_test.sh`, `kit_probe` all came
# back "command not found", the test still exited 0, and the line that was
# supposed to declare the tenant never reached the `.env` at all. So prose about
# this file goes HERE, and the heredoc below stays nothing but assignments.
#
# The one line below is here because the template now REQUIRES it.
# `docker-compose.yml` passes `KIT_POSTGRES_DATABASES` through with no `:-`
# fallback at all, on purpose: a shared-infrastructure template that defaults the
# tenant list to one of its own services silently hands every adopter that
# forgets to declare itself somebody else's database (measured on identity: it
# asked for `identity`, the cluster provisioned `courier`). So the init script
# refuses an unset list by name rather than inventing one.
#
# That refusal is correct, and it caught this file. With the fallback removed,
# `bin/dev up` here exited non-zero with
#
#     10-cluster.sh: line 48: KIT_POSTGRES_DATABASES: KIT_POSTGRES_DATABASES is
#     unset. Name the services, comma-separated.
#
# and the container exited 1 — a stack that could not start, which is the right
# outcome for a consumer that declared nothing. This test WAS such a consumer,
# and the reason is worth stating plainly: this file is kit's own harness
# consuming kit's own template, so a harness that forgot to declare itself looks
# exactly like "the template broke". `isolation_test.sh` was always a correct
# consumer and already declared `ALPHA,BETA`; this one did not, and the only
# thing that found out was the test that actually brings the cluster up.
#
# A consumer declares what it wants. `kit_probe` is named for this test and
# nothing else, which also means the init script runs — so this file now proves
# one more thing than it used to: that a declared tenant is really created.
#
# AND IT DECLARES THE BACKEND, BUT NOT HERE. `KIT_DEV_PROFILES` is deliberately
# NOT read from `.env` — see the note on it in `bin/dev`: `stack_setting` cannot
# tell "unset" from "set to empty", so a `.env` saying `observability` would
# silently re-impose the four-backend tax on every command that starts a stack.
# It is read from the process environment, and the consumer therefore declares it
# on the `bin/dev up` line, where it is visible.
#
# It was declared NOWHERE until this, and the cost of that absence was a silent
# exit rather than a red. `a0415ba` flipped `KIT_DEV_PROFILES` from a default of
# `observability` to a default of nothing — correctly, because a dev loop should
# not pay for four backends nobody asked to look at — and this file went on
# reading Tempo exactly as before. `docker compose port tempo 3200` then exits
# nonzero on a stack with no Tempo in it, that nonzero status rode out of a
# command substitution, and `set -e` killed the script with no message and no
# line number. Two full gate runs produced 61 passing checks and a FAIL with no
# failing assertion in it, because the file died between two passes.
#
# There is no cheaper spelling. Tempo, Loki and Grafana all carry the SAME
# `profiles: [observability]`, so `observability` is the only value that turns
# Tempo on — `--profile tempo` enables a profile named tempo, which does not
# exist, and compose accepts it without complaint. That is worth writing down
# because the first attempt at this fix used it and got a stack with no Tempo in
# it and no error to say so. What this file reads back is Tempo's search API and
# the collector's own `debug` exporter; Grafana comes along and is not read.
cat >"$SERVICE/.env" <<ENV
KIT_STACK_URL=file://$REMOTE
KIT_STACK_HOME=$WORK/cache
KIT_STACK_NAME=$STACK_NAME
KIT_GRAFANA_PORT=$PORT_BASE
KIT_POSTGRES_PORT=$((PORT_BASE + 500))
KIT_POSTGRES_DATABASES=kit_probe
KIT_NATS_CLIENT_PORT=$((PORT_BASE + 600))
KIT_NATS_MONITOR_PORT=$((PORT_BASE + 700))
KIT_REDIS_PORT=$((PORT_BASE + 800))
KIT_TEMPO_PORT=$((PORT_BASE + 900))
KIT_LOKI_PORT=$((PORT_BASE + 901))
# 'detailed', and deliberately NOT the shipped default. The metric assertions
# below read the 'debug' exporter's own output, and at 'normal' it prints each
# metric's data point WITHOUT its attribute map — so the "the high-cardinality
# dimensions are not there" assertion would be satisfied by the exporter being
# quiet rather than by the dimensions being gone. 'detailed' prints attributes,
# which is what makes the absence mean something.
KIT_OTEL_DEBUG_VERBOSITY=detailed
ENV

cd "$SERVICE"

# ---------------------------------------------------------------------------
# 1. up
# ---------------------------------------------------------------------------
printf -- '-- live: the FETCHED stack comes up, and a trace reaches Tempo\n'

step_up() {
  # ALWAYS returns 0, and writes the log. `bin/dev up` is EXPECTED to exit
  # nonzero here — this sandbox has no migrations, and `bin/dev` is right to
  # refuse to pretend otherwise. Treating that exit as a stack failure is what
  # the first version did, and it reported a healthy eight-container stack as
  # "did not come up" because the thing after it had nothing to do.
  #
  # No fake `bin/migrate`. A stub in the one test whose entire claim is that
  # nothing is stubbed is self-defeating, and the real sequence is asserted from
  # the log and from `compose ps` below rather than from an exit code that
  # conflates two different claims.
  # KIT_DEV_TIMEOUT is the escape hatch `bin/dev` itself prints when its deadline
  # fires, and this test uses it for a stated reason rather than raising the
  # shipped default.
  #
# `bin/dev`'s 180s is a LAPTOP figure for a cold start on a machine doing
  # nothing else — measured here at 76s with all eight containers coming up.
  # This is a shared machine: other anywaye workers were running their own stacks
  # (a darkroom isolation postgres, an identity gate postgres, a deploy test)
  # while this ran, and a cold Grafana plus a cold Tempo under that contention
  # exceeded 180s.
  #
  # The difference matters, because there are two available responses and only
  # one of them is right. Raising the shipped default would make every developer
  # wait longer for a stack that starts in 76s on their machine; raising the
  # deadline HERE changes nothing for anyone but this test. A gate that widens a
  # shipped number to accommodate the machine it runs on has stopped measuring the
  # thing it was written to measure.
  #
  # `KIT_DEV_PROFILES=observability` is on THIS line and not in the `.env`
  # because that is the only place `bin/dev` reads it from. It is the consumer
  # declaring the backend sections 4 and 5 assert against, and the full
  # reasoning — including why there is no cheaper spelling of it — is at the
  # `.env` heredoc above.
  KIT_DEV_TIMEOUT=420 KIT_DEV_PROFILES=observability bash ./bin/dev up >"$WORK/up.log" 2>&1 || true
}

if ! wait_for "bin/dev up to finish its stack phase" 300 step_up; then
  if ! docker info >/dev/null 2>&1; then
    # The daemon died DURING the run. That is not a finding about the stack, and
    # reporting it as one is how a test teaches people to ignore it: the first
    # version of this test did exactly that, and two consecutive "the fetched
    # stack did not come up" results turned out to be OrbStack restarting. The
    # distinction is cheap — one `docker info` — and without it every environment
    # failure in this file is indistinguishable from a real defect.
    echo "SKIP  stack live proof (the docker daemon went away during the run)" >&2
    exit 0
  fi
  fail "bin/dev up did not finish its stack phase"
  tail -40 "$WORK/up.log" | sed 's/^/        /'
  exit 1
fi

# "A stack that is up" and "a stack that is migrated" are two claims, and this
# test makes the first. The second is what the fixture has no answer for, so the
# log is read to confirm the ORDER rather than the success: the stack came up
# healthy, and only then did bin/dev try to migrate and correctly refuse.
if grep -q 'no migration command found' "$WORK/up.log" &&
  grep -q 'starting the stack from kit@' "$WORK/up.log"; then
  pass "the fetched stack came up healthy, and only then did bin/dev look for migrations"
else
  if ! docker info >/dev/null 2>&1; then
    echo "SKIP  stack live proof (the docker daemon went away during the run)" >&2
    exit 0
  fi
  fail "bin/dev up did not get the stack up before it looked for a migration command"
  tail -30 "$WORK/up.log" | sed 's/^/        /'
  exit 1
fi

# Every service that DECLARES a healthcheck reports healthy, asserted from
# compose rather than from the script's own word for it.
#
# Only the services that have one. `{{.Health}}` is empty for a service with no
# healthcheck, and the first version read that as unhealthy — so a service of the
# test's own, `probe`, which deliberately has no probe of its own, was reported
# as a broken container. The claim is "everything that can report health does",
# and a service that cannot report health is not a counterexample to it.
unhealthy="$(docker compose -p "$PROJECT" ps --format '{{.Service}}|{{.Health}}' 2>/dev/null |
  awk -F'|' '$2 != "" && $2 != "healthy" {print $1" ("$2")"}' || true)"
if [ -z "$unhealthy" ]; then
  checked="$(docker compose -p "$PROJECT" ps --format '{{.Health}}' 2>/dev/null |
    grep -c 'healthy' || true)"
  pass "every service that declares a healthcheck reports healthy ($checked of them)"
else
  fail "these services are not healthy: $unhealthy"
fi

# ---------------------------------------------------------------------------
# 1b. the cluster actually PROVISIONED the tenant it was told about
# ---------------------------------------------------------------------------
# This is the assertion the P0 above most needed and this file did not have.
#
# The bug being fixed was a bind mount whose source was a bare relative path, so
# it resolved against the wrong directory and `/docker-entrypoint-initdb.d` came
# up EMPTY. Docker does not complain about an empty bind source: the mount
# succeeds, `postgres` initialises from its own defaults, every container reports
# healthy, and every assertion above this line passes. The cluster was up and
# held zero of the fleet's databases. That is why "the stack came up healthy"
# was never going to catch it and why the live test was the only thing that did
# — the static gate reads YAML, and correct YAML mounted the wrong directory.
#
# So this asks the running server, not the file that was supposed to reach it.
# A tenant list that reached the init script produces a DATABASE and a ROLE that
# both carry the name, with the role as owner, and NOT a superuser — the last
# part is the assertion that a service cannot have quietly become an admin,
# which is what the per-service POSTGRES_* overrides in two repos did.
#
# It deliberately does NOT assert the cross-tenant refusal. `isolation_test.sh`
# owns that claim and owns it properly, with two tenants and a real refused
# connection; repeating it here would be a second, weaker copy of a fact that
# already has a home.
db_query() {
  docker compose -p "$PROJECT" exec -T postgres \
    psql --no-psqlrc --quiet --username "${KIT_POSTGRES_USER:-anywaye}" \
    --dbname "${KIT_POSTGRES_DB:-anywaye_platform}" --tuples-only --no-align \
    --set=ON_ERROR_STOP=1 --command="$1" 2>/dev/null | tr -d '[:space:]'
}

tenant_db="$(db_query "select count(*) from pg_database where datname = 'kit_probe'")"
tenant_owner="$(db_query "select coalesce(pg_get_userbyid(datdba), '') from pg_database where datname = 'kit_probe'")"
tenant_role="$(db_query "select count(*) from pg_roles where rolname = 'kit_probe'")"
# `rolsuper::int`, not `rolsuper`, and this is not a style choice. psql prints a
# boolean as `t`/`f`, so comparing against the word `false` fails on a role that
# is correctly NOT a superuser — the first version of this line did exactly that,
# and reported a working cluster as broken. `-1` rather than `0` is the
# no-such-role sentinel, so "the role is missing" and "the role is a superuser"
# cannot print the same answer.
tenant_super="$(db_query "select coalesce(max(rolsuper::int), -1) from pg_roles where rolname = 'kit_probe'")"

if [ "$tenant_db" = "1" ] && [ "$tenant_owner" = "kit_probe" ]; then
  pass "the initdb mount reached the running server: database kit_probe exists, owned by role kit_probe"
else
  fail "database kit_probe is missing or not owned by kit_probe (found=$tenant_db owner=${tenant_owner:-none}). \
An empty /docker-entrypoint-initdb.d produces exactly this: a healthy cluster with none of the fleet's databases."
fi

if [ "$tenant_role" = "1" ] && [ "$tenant_super" = "0" ]; then
  pass "role kit_probe exists and is not a superuser (NOSUPERUSER, so a service cannot admin the cluster)"
else
  fail "role kit_probe is missing (count=$tenant_role) or is a superuser (rolsuper=$tenant_super)"
fi

# A cluster that provisioned the tenant but left PUBLIC able to CONNECT to it has
# no isolation at all, and that is the failure mode the whole one-database-per-
# service design exists to prevent.
#
# The trap in reading `datacl`: Postgres does not print the word PUBLIC. A PUBLIC
# entry is one with an EMPTY grantee — `=c/anywaye` is "PUBLIC has CONNECT, granted
# by anywaye", while `kit_probe=CT/anywaye` is the role's own two privileges. So
# this matches on the empty-grantee shape (`=`, a privilege letter, `/`) and not
# on a substring, because a substring check for "PUBLIC" would pass on a database
# where PUBLIC holds everything.
#
# `datacl` is NULL exactly when no privilege has ever been granted or revoked,
# which is Postgres's way of saying "the defaults still stand" — and the default
# is CONNECT to PUBLIC. A NULL here is therefore a FAIL, not a skip.
tenant_acl="$(db_query "select coalesce(array_to_string(datacl, ','), '') from pg_database where datname = 'kit_probe'")"
if [ -z "$tenant_acl" ]; then
  fail "database kit_probe carries no ACL at all (datacl is null), so it still has Postgres's defaults and PUBLIC may CONNECT"
elif printf '%s' "$tenant_acl" | grep -qE '(^|,)=[A-Za-z]*/'; then
  fail "PUBLIC still holds a privilege on database kit_probe: $tenant_acl"
else
  pass "PUBLIC holds no privilege on database kit_probe (datacl=$tenant_acl)"
fi

# ---------------------------------------------------------------------------
# 2. the collector is running the FETCHED config
# ---------------------------------------------------------------------------
# The whole claim of the packet in one assertion. If the collector were reading
# a `otel-collector.yml` from the service's own directory, everything else below
# would still pass and the redaction boundary would be whatever that file said.
FETCHED="$WORK/cache/$PIN"
if [ -f "$FETCHED/.kit-stack-ref" ] && [ "$(head -1 "$FETCHED/.kit-stack-ref")" = "$PIN" ]; then
  pass "the running stack came from the fetched tree at the pinned ref ($PIN)"
else
  fail "the stack did not come from the pinned fetch"
fi

# ASK DOCKER where the collector's config comes from, rather than asking the
# collector or asking the host.
#
#   docker inspect .Mounts is the daemon's own record of the bind it set up, and
#   it is the only one of the three answers that cannot be a self-report. The
#   host file is what we THINK we mounted; the container is distroless and has no
#   shell to ask. The first version did try `exec ... cat` first, and on a
#   distroless image the exec fails — so its output was an error string that
#   compared unequal to the config and reported the boundary was not the fetched
#   one. The error string was the evidence.
MOUNT_SRC="$(docker inspect --format   '{{range .Mounts}}{{if eq .Destination "/etc/otel/otel-collector.yml"}}{{.Source}}{{end}}{{end}}' \
  "$PROJECT-otel-collector-1" 2>/dev/null || true)"
if [ -z "$MOUNT_SRC" ]; then
  fail "the collector container has no bind mount at /etc/otel/otel-collector.yml.
   Without it the collector is running a default config, and a default config is
   not the redaction allowlist."
elif diff -q "$MOUNT_SRC" "$FETCHED/templates/compose/otel-collector.yml" >/dev/null 2>&1; then
  pass "the collector's config is the FETCHED otel-collector.yml, byte for byte (per docker inspect)"
else
  fail "the collector is running $MOUNT_SRC, which is NOT the fetched config at $FETCHED"
fi

# And the fetched tree itself really is the pinned ref, by the marker the fetch
# writes rather than by this script's memory of what it asked for.
if [ "$(head -1 "$FETCHED/.kit-stack-ref" 2>/dev/null)" = "$PIN" ]; then
  pass "the tree the collector is reading declares the pinned ref ($PIN)"
else
  fail "the fetched tree records a different ref than the one pinned"
fi

# ---------------------------------------------------------------------------
# 3. send a trace and a metric
# ---------------------------------------------------------------------------
# Hand-built OTLP/JSON, for the reason `canary_test.sh` gives: when this fails,
# the first question is "what exactly did you send", and an answer that needs
# re-deriving it is not an answer.
cat >"$WORK/traces.json" <<JSON
{
  "resourceSpans": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name", "value": { "stringValue": "kitstackprobe" } },
          { "key": "service.namespace", "value": { "stringValue": "anywaye" } },
          { "key": "tenant_id", "value": { "stringValue": "tnt_kit13live" } }
        ]
      },
      "scopeSpans": [
        {
          "scope": { "name": "kit-stack-live" },
          "spans": [
            {
              "traceId": "9c1f2b7a4d3e5f60718293a4b5c6d7e8",
              "spanId": "1a2b3c4d5e6f7081",
              "name": "kit.probe",
              "kind": 2,
              "startTimeUnixNano": "$(($(date +%s) * 1000000000 - 50000000))",
              "endTimeUnixNano": "$(($(date +%s) * 1000000000))",
              "status": { "code": 2, "message": "provider auth rejected" },
              "attributes": [
                { "key": "http.route", "value": { "stringValue": "/v1/probe" } },
                { "key": "error.type", "value": { "stringValue": "provider_auth" } },
                { "key": "otel.status_code", "value": { "stringValue": "ERROR" } },
                { "key": "llm.model", "value": { "stringValue": "gpt-4o-mini" } },
                { "key": "llm.prompt", "value": { "stringValue": "a prompt containing $CANARY" } },
                { "key": "error.message", "value": { "stringValue": "rejected: $CANARY" } }
              ]
            }
          ]
        }
      ]
    }
  ]
}
JSON

cat >"$WORK/metrics.json" <<JSON
{
  "resourceMetrics": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name", "value": { "stringValue": "kitstackprobe" } },
          { "key": "service.namespace", "value": { "stringValue": "anywaye" } }
        ]
      },
      "scopeMetrics": [
        {
          "scope": { "name": "kit-stack-live" },
          "metrics": [
            {
              "name": "kit.probe.calls",
              "unit": "1",
              "description": "a direct metric, so the OTLP metrics path is proven as well as the connector's",
              "counter": {
                "aggregationTemporality": 2,
                "dataPoints": [
                  {
                    "timeUnixNano": "$(($(date +%s) * 1000000000))",
                    "asInt": "3",
                    "attributes": [
                      { "key": "http.route", "value": { "stringValue": "/v1/probe" } }
                    ]
                  }
                ]
              }
            }
          ]
        }
      ]
    }
  ]
}
JSON

send() {
  local signal="$1"
  docker compose -p "$PROJECT" exec -T probe curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "http://otel-collector:4318/v1/$signal" \
    -H 'Content-Type: application/json' \
    --data-binary "@/payload/$signal.json" 2>/dev/null || echo 000
}
# The payload is written into the directory the service's override MOUNTS, and
# then read out of the container by that mount. Not `docker cp`: a payload
# assembled on the host and injected by a second mechanism is a payload nobody
# can say for certain is the one the test meant, and the mount is itself part of
# what is being tested.
mkdir -p "$SERVICE/payload"
cp "$WORK/traces.json" "$WORK/metrics.json" "$SERVICE/payload/"

for signal in traces metrics; do
  code="$(send "$signal")"
  case "$code" in
    200) pass "OTLP/$signal accepted by the running collector" ;;
    *) fail "OTLP/$signal rejected with HTTP $code" ;;
  esac
done

# ---------------------------------------------------------------------------
# 4. the trace is in TEMPO
# ---------------------------------------------------------------------------
# Tempo's search API, over its published port. `docker compose port` rather than
# a hardcoded one: the point of kit's 15000 block is that the port is not a
# number anybody should have to remember, and a test that hardcodes it would be
# asserting the default is still the default rather than asserting the data
# arrived.
tempo_port() { docker compose -p "$PROJECT" port tempo 3200 2>/dev/null | sed 's/.*://'; }

# Asked for, and checked, rather than assumed. This is the second half of the
# `KIT_DEV_PROFILES` note above: a stack with no Tempo in it answers this
# question with an empty string and a nonzero exit, and under `set -e` that
# nonzero exit propagates out of the command substitution and ends the script
# between two PASSes. A test that dies where it meant to assert is worse than
# one that goes red, because the log looks like a pass that ran out of checks.
# So an unanswerable question is an answer, and this one is the wrong one.
if ! TP="$(tempo_port)" || [ -z "$TP" ]; then
  fail "tempo is not running, so nothing in section 4 can be read off it"
  note "is KIT_DEV_PROFILES=tempo set in this file's .env above?"
  docker compose -p "$PROJECT" ps --services 2>/dev/null | sed 's/^/        running: /' || true
  exit 1
fi
note "tempo on $TP (read from compose, not assumed)"

# The canary is in the payload and must not be in the store. Asserted as an
# ABSENCE against a search for the trace's own identity, so a store that simply
# had nothing in it cannot pass it — the search below first proves the trace is
# there, and only then does the canary's absence mean anything.
if wait_for "the trace reaches Tempo" 60 sh -c \
  "curl -sf 'http://localhost:$TP/api/search?tags=service.name%3Dkitstackprobe' | grep -q kit.probe"; then
  pass "the trace is in Tempo, found by service.name"
else
  fail "the trace never reached Tempo within 60s"
  curl -s "http://localhost:$TP/api/search?tags=service.name%3Dkitstackprobe" 2>&1 |
    head -5 | sed 's/^/        /' || true
fi

# The allowed data survived, on the real store. A redaction boundary that
# deletes everything passes "no canary" and is useless.
if wait_for "Tempo serves the trace by id" 40 sh -c \
  "curl -sf 'http://localhost:$TP/api/traces/9c1f2b7a4d3e5f60718293a4b5c6d7e8' | grep -q provider_auth"; then
  pass "Tempo returns the trace, and error.type survived the boundary"
else
  fail "Tempo did not return the trace, or error.type was stripped"
fi

# The canary, on the real backend rather than a substituted exporter. This is the
# half `canary_test.sh` cannot make: it proves the fan-out reaches a store that is
# really there, rather than a file exporter standing in for it.
if curl -sf "http://localhost:$TP/api/traces/9c1f2b7a4d3e5f60718293a4b5c6d7e8" 2>/dev/null |
  grep -q "$CANARY"; then
  fail "the canary reached TEMPO — the redaction boundary does not hold on the live stack"
else
  pass "the canary reached no exporter on the live stack (Tempo checked by trace id)"
fi

# ---------------------------------------------------------------------------
# 5. the DERIVED METRIC REACHES THE COLLECTOR'S OWN STDOUT
# ---------------------------------------------------------------------------
# WHERE THIS LOOKED BEFORE, AND WHY IT CANNOT LOOK THERE ANY MORE. This section
# used to query a metrics store over its published PromQL port for two things:
# the metric the probe sent directly, and the one the `spanmetrics` connector
# minted from the trace. That store cost 130s of readiness budget per cold start
# (retries 12 x interval 10s) against a 180s deadline for the whole stack, and
# was removed rather than left half-wired — no service, no volume, no port, no
# exporter dialling a host with nothing on it.
#
# So the assertions move to the collector's `debug` exporter, which is where the
# metrics pipeline goes now, and which is a BETTER place to read them from: the
# store answered a question about what survived to disk, and the exporter
# answers the question the change is actually about, which is whether the
# derived series still pass the ingest deny set on the way OUT. Nothing in this
# tree stores metrics, so the collector's stdout is the last place a dropped
# dimension can still be observed — and it is observable, because the export
# prints the attribute map (see `KIT_OTEL_DEBUG_VERBOSITY=detailed` in the .env
# this test writes above).
#
# `collector_logs` reads the container rather than a file, because a file
# exporter standing in for the fan-out is exactly what `canary_test.sh` already
# substitutes and what this test exists not to do.
#
# And it is a FUNCTION, which is a trap the first version of this assertion fell
# into. `wait_for` takes a COMMAND and runs it through `sh -c`, and `sh -c` is a
# new shell: it does not inherit this file's functions. The probe therefore ran
# `collector_logs`, got `sh: collector_logs: command not found`, and exited
# nonzero on the FIRST attempt and on all ninety after it — so the assertion
# reported that the spanmetrics connector had minted nothing while the very log
# lines it printed on failure showed `Name: anywaye.calls_total` sitting right
# there. A probe that cannot run and a system that is broken look identical from
# the outside, which is why this is a function AND why the command form is
# spelled out where `sh` can see it.
collector_logs() { docker compose -p "$PROJECT" logs --no-color otel-collector 2>/dev/null; }

# The connector. `duration` is the shape `spanmetrics` mints for an
# `http.server.request.duration`-style span, and the namespace prefix is the
# `KIT_OTEL_METRIC_NAMESPACE` the collector was configured with — so finding it
# is a proof that the CONFIG reached the container and that the connector is
# wired, not only that the collector is printing something.
#
# Spelled as a command `sh` can execute, not as a call to the function above.
if wait_for "the spanmetrics connector mints a metric" 90 sh -c \
  "docker compose -p '$PROJECT' logs --no-color otel-collector 2>/dev/null | grep -qE 'anywaye[_.]duration'"; then
  pass "the spanmetrics connector exported anywaye_duration — the fleet dashboard's source"
else
  fail "the spanmetrics connector minted nothing: the error view would be empty"
  collector_logs | grep -iE 'anywaye[_.]' | head -5 | sed 's/^/        /' || true
fi

# THE INGEST DENY SET, on the real pipeline. This is the assertion the removal
# made necessary: the metrics pipeline still runs — derived, redacted, exported
# — and its whole purpose now is to be observable, so the deny set has to be
# observable too. `tenant_id` on a data point is the one that must never appear;
# the transform's own comment records why a resource exemption cannot cover it.
if collector_logs | grep -qE 'tenant_id|account_id|request_id'; then
  fail "a high-cardinality dimension reached an exporter as a metric label — the ingest deny set did not run"
  collector_logs | grep -nE 'tenant_id|account_id|request_id' | head -5 | sed 's/^/        /' || true
else
  pass "no high-cardinality dimension appears on an exported metric label"
fi

# The redaction boundary on the metric side. A metric carrying the canary would
# be the worst leak of all, because a metric is queryable by anyone with read
# access rather than visible only to someone reading a trace.
if collector_logs | grep -q "$CANARY"; then
  fail "the canary reached the collector's exporter"
else
  pass "the canary reached no exporter on the live stack (exported attributes checked)"
fi

# ---------------------------------------------------------------------------
# 6. the stack the service FILE made, merged
# ---------------------------------------------------------------------------
# The final assertion, and the one the packet is really about: the service's
# three-line override and the fetched 400-line stack merge into ONE coherent
# project, with kit's seven services intact and the service's own network joined
# to the same one the collector is on. If the override had shadowed the network,
# `probe` would not have been able to reach `otel-collector` by name — and every
# assertion above would already have failed, which is why this is the last line
# rather than the first.
if docker compose -p "$PROJECT" ps --services 2>/dev/null | grep -qx probe; then
  pass "the service's own service joined the fetched stack rather than replacing it"
else
  fail "the service's own service is not in the running project"
fi

printf '\n'
if [ "$failures" -ne 0 ]; then
  echo "FAIL: stack live — $failures assertion(s) failed. Logs in $WORK/up.log"
  exit 1
fi
echo "PASS: stack live — the fetched stack ran, and a trace reached Tempo and a derived metric reached the collector's exporter."
