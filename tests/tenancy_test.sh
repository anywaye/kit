#!/usr/bin/env bash
#
# THE PROOF that kit's account-isolation templates isolate a tenant.
#
#   bash tests/tenancy_test.sh
#
# WHAT THIS IS, AND WHY IT IS A SEPARATE SCRIPT.
#
#   kit's other suites parse configuration. This one brings up a real Postgres
#   from the stack kit ships, applies `templates/database/tenancy/substrate.sql`,
#   runs `templates/database/tenancy/isolation.sql`, and reports every assertion —
#   printing the ones that failed, with the reason each one exists.
#
#   It exists because "a service that reads another tenant's rows is a bug in
#   review" is a claim about a RUNNING system. AGENTS.md's rule is that a config
#   written from documentation rather than from the pinned image is a config that
#   breaks on the first `bin/dev up`; this is the answer to that for the account
#   boundary, which cannot be checked any other way.
#
# NINE THINGS, and the last five are what make the first one mean something:
#
#   1. every assertion in isolation.sql passes.        (the property)
#   2. the CONTROL: with `FORCE ROW LEVEL SECURITY` removed, the OWNER half of the
#      spine goes red and the LOGIN half stays green.   (the property is
#      load-bearing, and it is load-bearing FOR THE OWNER specifically — which is
#      the half a policy's mere presence cannot satisfy)
#   3. the init plan, MEASURED: a wrapped policy calls the identity function once
#      per statement and a bare one calls it once per candidate row. (a comment
#      saying so is not a measurement)
#   4. the assertion set is EXACTLY the one assertions.txt names, both ways.
#      (the proof has not quietly shrunk)
#   5. an ADOPTER'S FIXTURE SCHEMA, planted before the proof runs, is out of the
#      sweep's scope and the proof is still green.  (0b: the sweep does not
#      assume it owns the database)
#   6. an unprotected account-scoped table in a schema the substrate DOES own
#      turns the proof red.                            (5: and scoping the sweep
#      did not turn it into a green constant)
#   7. THE DATABASE'S OWN ADVISOR, `templates/database/tenancy/advisor.sql`, run
#      against this cluster, reports ZERO ERROR and zero WARN on the two tables
#      the substrate wrote.                            (the one question the five
#      above cannot ask: a policy that PERMITS everything satisfies every denial,
#      because a denial cannot tell permitted-by-predicate from
#      permitted-by-accident)
#   8. every rule in that advisor FIRES on a fixture built to trip it, naming
#      itself and the object it fired on, AND stays silent on four views built to
#      prove it is selective.                (a detective that has never fired is
#      a detective you cannot trust; one that fires on everything is a detective
#      nobody reads)
#   9. THE AUDIT ANSWERS EVERY ROLE THE SAME. `cafaye.credential_tables()` is
#      read as the owner, as the cluster's admin role and as the non-owner LOGIN
#      role; the three answers must be identical AND non-empty.  (8: an audit
#      whose answer depends on the reader's `search_path` reports "no credential
#      path in this database" to the one role whose `"$user"` schema is `cafaye`,
#      which is the most expensive reading in the file to believe)
#
#   Assertion 2 is the expensive and the important one. It is the control this
#   repository's rules insist on: a control that never runs differently proves
#   nothing. Without it, a proof that asserted "the owner reads no rows" would
#   also pass on a template with no FORCE at all — which is precisely the trap
#   this file exists for, because FORCE is absent from Supabase's guide and no
#   lint in this fleet checks for it.
#
#   Assertions 0b and 5 are one measurement in two directions, and neither means
#   anything alone. `identity` adopted this substrate and its whole-suite run then
#   failed kit's account-isolation control: its test helper builds a private
#   fixture schema per test by cloning tables with `LIKE ... INCLUDING ALL`, which
#   does not copy row-level security, so every fixture carries an `account_id`
#   column and no policies -- and a sweep that scanned the whole database named
#   all of them, with the count moving per run (5, then 21) as neighbours went in
#   and out of flight. 0b plants that shape and requires it to be ignored. 5
#   requires an unprotected table in the substrate's OWN schema to still be
#   named. Narrow the scope to `pg_temp` alone and 0b passes forever while 5 goes
#   red, because every real table in every adopter is then outside it: which is
#   the only reason 5 exists rather than 0b by itself.
#
# SKIPS LOUDLY, NEVER SILENTLY. No docker, no image, no network to GHCR: this is a
# SKIP that names what it needed, and `validate.sh` counts it. A skip is honest; a
# skip reported as a pass is the thing this repository forbids.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Two services. `alpha` and `beta` rather than real names, because the point is
# that the harness does not know or care what the services are called.
ALPHA=alpha
BETA=beta

SUBSTRATE="$ROOT/templates/database/tenancy/substrate.sql"
ISOLATION="$ROOT/templates/database/tenancy/isolation.sql"
MANIFEST="$ROOT/templates/database/tenancy/assertions.txt"
ADVISOR="$ROOT/templates/database/tenancy/advisor.sql"

# ONE NAME FOR THE WHOLE RUN. This was `kit-tenancy`, written out at both
# compose sites, and a compose project name namespaces that stack's containers,
# networks and volumes — so two concurrent runs were one stack with two owners.
# Observed rather than argued, and the tenancy shape is the worst of the two:
# the second run cannot bring up a cluster ("removal of container … is already in
# progress"), and the FIRST run — already mid-assertion — then dies part way
# through assertion 5 with psql's exit code and no FAIL line of its own, because
# the other run's teardown took the project volume out from under it. Through
# validate.sh's FAIL summary that reads as a database-boundary violation, which
# is precisely the claim this tier exists to make trustworthy.
#
# `$$` is the convention the four other docker tiers already use, and it is unique
# among live processes on one machine — which is the scope that has to hold, since
# CI gives every job its own daemon. DECISIONS.md records why not `mktemp`.
PROJECT="kit-tenancy-$$"

# THE HOST PORT is a fixed name of the same class in a different hat, and it is
# WORSE than the project name, because it collides with the developer's own running
# stack rather than only with another test run. `KIT_POSTGRES_PORT=15531` was
# hardcoded; deriving only the project name would still leave two concurrent runs
# of this tier fighting over one port, and the second red on `port is already
# allocated` — the collision not fixed, merely relocated to the next namespace.
#
# This suite never reaches postgres from the host: every query goes through
# `docker exec`. The port is published only because the shipped compose file
# publishes it, and moving it is enough to keep two runs apart.
#
# The probe is the dependency-free one stack_live_test.sh uses (`/dev/tcp`, not
# `nc` or python), for the reason it gives: nothing in a tier may assume a tool is
# installed. The SEARCH is below `fail`'s definition — see the comment there.

WORK="${TMPDIR:-/tmp}/kit-tenancy.$$"
IMAGE_TAG="17"
# The pgvector layer pin, matching templates/compose/postgres/Dockerfile. It is
# repeated here rather than read out of that file for the reason
# tests/isolation_test.sh gives: parsing ARGs out of a BuildKit Dockerfile in bash
# would be a second place for the pin to drift.
PGVECTOR_TAG="17-0.8.6"

say() { printf '%s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  # `docker compose down -v`, not `docker rm -f` plus a guessed volume name, for
  # the reason tests/isolation_test.sh records: `docker-entrypoint-initdb.d` runs
  # ONLY on a fresh volume, so a leaked volume makes the next run reuse an
  # already-provisioned cluster and the suite fails on an assertion about state the
  # previous run created — which reads exactly like a broken boundary.
  #
  # `docker rm -f kit-tenancy-control` and `docker volume rm
  # kit-tenancy-control-vol` were REMOVED rather than derived, which is a claim
  # worth making loudly because it is the opposite of what this file did. Nothing
  # here ever creates either object: every control in this suite is a SQL mutation
  # against THIS cluster, not a second container. So those two lines were reaching
  # outside their own namespace to delete objects belonging to a different tier —
  # `docker rm` takes a bare name and does not care who made it. Deleting a name
  # this run never created is a teardown that removes something it does not own.
  if [ -f "$WORK/compose/docker-compose.yml" ]; then
    docker compose --project-name "$PROJECT" -f "$WORK/compose/docker-compose.yml" \
      down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# THE HOST PORT, searched here rather than at the top of the file because it calls
# `fail`, and shellcheck (correctly) reports a function used before it is defined.
# Being the first thing to fail means a machine with no free port says so by name
# instead of exiting 127 on a missing function.
PGPORT_BASE=$(( 15500 + ($$ % 400) ))
PGPORT=""
_p=0
while [ "$_p" -lt 400 ]; do
  _cand=$(( PGPORT_BASE + _p ))
  if ! (exec 3<>"/dev/tcp/127.0.0.1/$_cand") 2>/dev/null; then
    PGPORT="$_cand"
    break
  fi
  _p=$(( _p + 1 ))
done
[ -n "$PGPORT" ] || fail "no free host port in this run's 400-port slice; the tier cannot start without colliding with something"

for f in "$SUBSTRATE" "$ISOLATION" "$MANIFEST" "$ADVISOR"; do
  [ -r "$f" ] || fail "$(basename "$f") is not readable, so there is nothing to prove"
done

# ---------------------------------------------------------------------------
# Environment. Everything missing is named, because "SKIP (docker)" tells a
# reader nothing about which of three things was absent.
if ! command -v docker >/dev/null 2>&1; then
  say "SKIP tests/tenancy_test.sh: docker is not installed, so the account boundary is unexercised."
  exit 3
fi
if ! docker info >/dev/null 2>&1; then
  say "SKIP tests/tenancy_test.sh: the docker daemon is not reachable, so the account boundary is unexercised."
  exit 3
fi

mkdir -p "$WORK"

# Derived from `$PROJECT`, which is the whole point. Spelled out, it addressed
# ONE cluster shared by every run of this suite, so every `psql_in` and
# `run_script` below could be answered by whichever run won the race — a proof
# that asserts against a cluster it did not start.
C="$PROJECT-postgres-1"

psql_in() { # psql_in <role> <db> <sql>
  docker exec -e PGPASSWORD=cafaye "$C" psql -U "$1" -d "$2" -tAX -c "$3"
}

# psql as the OWNER with the whole script, because the assertions need the simple
# query protocol (a script is a batch) and need the transaction the script opens
# for itself.
run_script() { # run_script <db> <sql-file>
  docker exec -e PGPASSWORD=cafaye "$C" psql -U "$ALPHA" -d "$1" -A -t -F'@' \
    -v ON_ERROR_STOP=1 -f "$2" 2>&1
}

# The wait is for the EVIDENCE the init script produces, not for the server to
# answer. During `docker-entrypoint-initdb.d` the image runs a TEMPORARY server
# that `pg_isready` returns 0 against, so polling either that or a healthcheck
# returns while the cluster is still half-provisioned.
wait_for_provisioning() { # wait_for_provisioning <container> <role> <db>
  local container="$1" role="$2" db="$3" out
  for _ in $(seq 1 90); do
    out="$(docker exec -e PGPASSWORD=cafaye "$container" \
      psql -U "$role" -d cafaye_platform -tAX -c \
      "SELECT count(*) FROM pg_database WHERE datname = '$db'" 2>/dev/null || true)"
    if [ "$out" = "1" ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# The WHOLE of templates/compose, not just the postgres directory, so the thing
# under test is the STACK kit ships: the init script's bind mount, the `build:`
# args and the environment block are all in that one file.
cp -R "$ROOT/templates/compose" "$WORK/compose"
docker cp "$SUBSTRATE" "$C:/tmp/substrate.sql" >/dev/null 2>&1 || true

if ! docker build \
  --build-arg "POSTGRES_TAG=$IMAGE_TAG" \
  --build-arg "PGVECTOR_TAG=$PGVECTOR_TAG" \
  -f "$WORK/compose/postgres/Dockerfile" \
  -t "kit-tenancy-postgres:$IMAGE_TAG" \
  "$WORK/compose/postgres" >"$WORK/build.log" 2>&1; then
  say "SKIP tests/tenancy_test.sh: could not build the cluster image from templates/compose/postgres/Dockerfile."
  say "       (needs network access to ghcr.io for the pglayers layer). Last lines:"
  tail -5 "$WORK/build.log" | sed 's/^/       /'
  exit 3
fi

cp "$ROOT/templates/compose/.env.example" "$WORK/compose/.env"
{
  echo "KIT_POSTGRES_PORT=$PGPORT"
  echo "KIT_POSTGRES_DATABASES=$ALPHA,$BETA"
} >>"$WORK/compose/.env"

if ! docker compose --project-name "$PROJECT" -f "$WORK/compose/docker-compose.yml" \
  up -d --wait postgres >"$WORK/up.log" 2>&1; then
  say "FAIL: the shared cluster did not come up. Last lines:"
  tail -20 "$WORK/up.log" | sed 's/^/       /'
  fail "cluster bring-up"
fi

if ! wait_for_provisioning "$C" cafaye "$BETA"; then
  say "FAIL: the cluster came up but initdb/10-cluster.sh never created a database named $BETA."
  docker logs "$C" 2>&1 | tail -25 | sed 's/^/       /'
  fail "init script did not complete"
fi

say ""
say "== the cluster, provisioned by templates/compose/postgres/initdb/10-cluster.sh =="
docker logs "$C" 2>&1 | grep -E '\[cluster\]' | sed 's/^/   /' \
  || say "   (no [cluster] lines — the init script did not run on this volume)"

# ---------------------------------------------------------------------------
# ASSERTION 0 — the topology. Before asking whether isolation works, ask whether
# the cluster is the shape the contract claims: one database, and TWO roles, of
# which the login role owns nothing.
#
# Without this, every assertion below passes on a cluster with no `_app` role at
# all, because isolation.sql's preflight would be the only thing that noticed and
# a proof that stops at its own preflight is a proof that stopped.
say ""
say "== assertion 0: the topology the templates require is present"
for svc in "$ALPHA" "$BETA"; do
  got="$(psql_in cafaye cafaye_platform \
    "SELECT count(*) FROM pg_database WHERE datname = '$svc'")"
  [ "$got" = "1" ] || fail "expected a database named $svc; found $got"
  got="$(psql_in cafaye cafaye_platform \
    "SELECT count(*) FROM pg_roles WHERE rolname = '${svc}_app' AND rolcanlogin AND NOT rolsuper")"
  [ "$got" = "1" ] || fail "expected one non-superuser LOGIN role named ${svc}_app; found $got"
  # The membership, in the one direction that is allowed. The reverse is what
  # would undo the design, so it is asserted absent here as well as present:
  # a claim that a direction is allowed is worthless without the claim that the
  # other one is not.
  got="$(psql_in cafaye cafaye_platform \
    "SELECT count(*) FROM pg_auth_members m
       JOIN pg_roles member ON member.oid = m.member
       JOIN pg_roles granted ON granted.oid = m.roleid
      WHERE member.rolname = '$svc' AND granted.rolname = '${svc}_app'")"
  [ "$got" = "1" ] || fail "$svc cannot impersonate ${svc}_app, so nothing can prove the boundary from outside it"
  got="$(psql_in cafaye cafaye_platform \
    "SELECT count(*) FROM pg_auth_members m
       JOIN pg_roles member ON member.oid = m.member
       JOIN pg_roles granted ON granted.oid = m.roleid
      WHERE member.rolname = '${svc}_app' AND granted.rolname = '$svc'")"
  [ "$got" = "0" ] || fail "${svc}_app is a member of $svc, so the login role holds every privilege the owner has. That is the whole design undone by one GRANT."
done
say "   topology: 2 databases, 2 owner roles, 2 non-owner LOGIN roles, membership in one direction only"

# ---------------------------------------------------------------------------
# THE SUBSTRATE, applied. This is the file a service applies once, and it is
# applied here by the owner role — the same role a service's migrations run as,
# which is the only role the design is interesting for.
say ""
say "== applying templates/database/tenancy/substrate.sql, as the OWNER role"
docker cp "$SUBSTRATE" "$C:/tmp/substrate.sql" >/dev/null
if ! docker exec -e PGPASSWORD=cafaye "$C" psql -U "$ALPHA" -d "$ALPHA" \
  -v ON_ERROR_STOP=1 -q -f /tmp/substrate.sql >"$WORK/substrate.log" 2>&1; then
  say "FAIL: the substrate did not install. Last lines:"
  tail -20 "$WORK/substrate.log" | sed 's/^/       /'
  fail "substrate install"
fi
docker cp "$ISOLATION" "$C:/tmp/isolation.sql" >/dev/null
say "   installed: schema cafaye, current_account_id/0, begin_account/1, protect_table/2, unprotected_tables/0"

# ---------------------------------------------------------------------------
# ASSERTION 0b — AN ADOPTER'S FIXTURE SCHEMA, PLANTED BEFORE THE PROOF RUNS.
#
# This is identity's shape, reproduced rather than described. Its test helper
# builds a private fixture schema per test by cloning tables with
# `LIKE ... INCLUDING ALL`, and `LIKE` does not copy row-level security: an
# `account_id` column with no policies. A sweep that scans the whole database
# names every one of those, so `identity`'s whole-suite run failed kit's
# account-isolation control on a database whose five real tables were all
# protected -- and the count moved per run with how many neighbours were
# mid-flight.
#
# It is planted HERE, before assertion 1 runs, and permanently rather than in a
# transaction the proof rolls back, because the defect is precisely that the
# sweep sees a schema it did not create and does not roll back.
#
# The clone is a real `LIKE ... INCLUDING ALL` rather than a hand-written
# `create table`, because a hand-written table is not the thing that went wrong:
# the shape that matters is a fixture built by a helper the substrate never saw,
# and a fixture authored here would be a different shape wearing the same name.
say ""
say "== assertion 0b: an adopter's fixture schema is present, and out of the sweep's scope"
psql_in "$ALPHA" "$ALPHA" "
  set client_min_messages = warning;
  drop schema if exists kit_neighbour_fixture cascade;
  create schema kit_neighbour_fixture;
  create table kit_neighbour_fixture.account_users (
    id bigint generated always as identity primary key,
    account_id uuid not null,
    email text not null
  );
  create table kit_neighbour_fixture.api_keys (
    id bigint generated always as identity primary key,
    account_id uuid not null
  );
" >/dev/null

# ...and it really is unprotected, so a green proof below cannot be a sweep that
# found nothing to ignore. Both halves are read from the catalog rather than
# assumed: an `account_id` column, and neither `relrowsecurity` nor a policy.
got="$(psql_in "$ALPHA" "$ALPHA" "
  SELECT count(*) FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'account_id' AND NOT a.attisdropped
   WHERE n.nspname = 'kit_neighbour_fixture'
     AND c.relkind = 'r'
     AND NOT c.relrowsecurity
     AND NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid)")"
[ "$got" = "2" ] || fail "the fixture schema holds $got unprotected account-scoped table(s), not 2, so assertion 0b is not testing what it claims"

# The sweep must not name either of them. Read the function's own answer rather
# than inferring it from the proof's verdicts, so a failure here says "the sweep
# reached into a foreign schema" instead of "some assertion went red".
leaked="$(psql_in "$ALPHA" "$ALPHA" \
  "SELECT count(*) FROM cafaye.unprotected_tables() WHERE table_schema = 'kit_neighbour_fixture'")"
[ "$leaked" = "0" ] || fail "the sweep named $leaked table(s) in an adopter's fixture schema. It is scoped to the schemas the substrate was applied in, and kit_neighbour_fixture is not one of them."
say "   2 unprotected account-scoped tables in kit_neighbour_fixture, and the sweep names neither."
say "   identity's whole-suite failure was exactly this, with the count moving per run."

# ---------------------------------------------------------------------------
# ASSERTION 1 — every assertion in the set passes.
say ""
say "== assertion 1: every assertion in templates/database/tenancy/isolation.sql passes"
out="$(run_script "$ALPHA" /tmp/isolation.sql)"

# The result rows are `assertion@expected@actual@verdict@why`, and `why` is prose
# that may itself contain `@` in a future edit, so only the first three fields are
# split and the rest is taken as the remainder. A field-splitting shape chosen
# against the CURRENT prose rather than the intended one is how a check starts
# reporting empty results on a correct tree.
failures="$(printf '%s\n' "$out" | grep '@fail@' || true)"
total="$(printf '%s\n' "$out" | grep -cE '@(pass|fail)@' || true)"
[ "$total" -gt 0 ] || {
  say "FAIL: the proof returned no assertions at all."
  printf '%s\n' "$out" | tail -20 | sed 's/^/       /'
  fail "isolation.sql produced no rows"
}

if [ -n "$failures" ]; then
  say "FAIL: $failures assertion(s) failed, of $total:"
  printf '%s\n' "$failures" | while IFS= read -r line; do
    name="${line%%@*}"
    rest="${line#*@}"
    expected="${rest%%@*}"
    actual_and_verdict="${rest#*@}"
    actual="${actual_and_verdict%%@*}"
    verdict="${actual_and_verdict#*@}"
    printf '  %s\n     expected %s / actual %s (%s)\n' "$name" "$expected" "$actual" "$verdict"
  done
  fail "the account boundary is not in place"
fi
say "   $total assertions, all pass"

# ---------------------------------------------------------------------------
# ASSERTION 4 — the assertion set is EXACTLY the one assertions.txt names, both
# ways. Run before the controls so a shrunken proof is caught before it is used to
# prove anything else.
say ""
say "== assertion 4: the proof returns EXACTLY the assertions assertions.txt names"
want="$(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" | sort)"
got_names="$(printf '%s\n' "$out" | grep -E '@(pass|fail)@' | awk -F@ '{print $1}' | sort)"
if [ "$want" != "$got_names" ]; then
  say "FAIL: the proof and assertions.txt disagree."
  say "  only in assertions.txt (isolation.sql stopped asserting it):"
  comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got_names") | sed 's/^/       /'
  say "  only in the proof (not listed, so no service asserts it):"
  comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$got_names") | sed 's/^/       /'
  fail "the assertion set has drifted"
fi
say "   $(printf '%s\n' "$want" | grep -c .) assertions, named identically in both files"

# ---------------------------------------------------------------------------
# ASSERTION 2 — THE CONTROL. The same proof, with `FORCE ROW LEVEL SECURITY`
# removed from the substrate, must go red — and must go red on the OWNER half
# ONLY.
#
# This is the measurement the packet exists for. Measured here, on this tree:
#
#   with FORCE      owner reads 1 row (its own), login reads 1 row
#   without FORCE   owner reads 3 rows (every tenant's), login reads 1 row
#
# The login half staying green is the point rather than an inconvenience: it is
# what makes it obvious that an isolation suite written only against the
# application role passes on a template with no FORCE at all.
say ""
say "== assertion 2: the CONTROL — same proof, FORCE ROW LEVEL SECURITY removed"
mkdir -p "$WORK/noforce"
# The EXECUTABLE line, and only the executable line. A case-insensitive grep for the
# words removes the substrate's own explanation of why FORCE is there as well, and a
# control whose mutation also deletes the reasoning is a control whose recipe has to
# be re-read every time somebody edits a comment — which is the "a breakage recipe
# asserts its own premise before it mutates" rule, applied to a control rather than
# to a self-test.
grep -v "execute format('alter table %s force row level security'" \
  "$SUBSTRATE" >"$WORK/noforce/substrate.sql"
if grep -q "execute format('alter table %s force row level security'" "$WORK/noforce/substrate.sql"; then
  fail "the control's mutation did not remove the FORCE statement, so the control would prove nothing"
fi
# ...and that it was SURGICAL: the substrate's own explanation of why FORCE is
# required is still there. A mutation that removed the reasoning along with the
# statement would leave a control nobody can read six months from now, and the
# test for that is that the paragraph survives.
grep -q "FORCE ROW LEVEL SECURITY is still required" "$WORK/noforce/substrate.sql" \
  || fail "the control's mutation also deleted the substrate's own explanation of why FORCE is required"
docker cp "$WORK/noforce/substrate.sql" "$C:/tmp/substrate-noforce.sql" >/dev/null

ctl="$(docker exec -e PGPASSWORD=cafaye "$C" psql -U "$ALPHA" -d "$ALPHA" \
  -v ON_ERROR_STOP=1 -q -f /tmp/substrate-noforce.sql >/dev/null 2>&1; \
  run_script "$ALPHA" /tmp/isolation.sql)"
ctl_failures="$(printf '%s\n' "$ctl" | grep -c '@fail@' || true)"

if [ "$ctl_failures" -eq 0 ]; then
  say "FAIL: removing FORCE ROW LEVEL SECURITY changed nothing. The control and the thing it"
  say "      controls agree, which is the one outcome that proves nothing."
  fail "the FORCE assertion is not load-bearing"
fi
# The specific shape, because a control that goes red for an unrelated reason is
# a control that proves something else.
for name in \
  'owner/another-tenants-rows-read-as-none' \
  'owner/no-identity-reads-no-rows' \
  'sweep/the-only-finding-is-the-control'; do
  printf '%s\n' "$ctl" | grep -q "^$name@" || {
    say "FAIL: the control went red, but NOT via $name."
    printf '%s\n' "$ctl_failures" | head -1 | sed 's/^/       /'
    printf '%s\n' "$ctl" | grep '@fail@' | awk -F@ '{print "       red instead: " $1}' | head -8
    fail "the FORCE control is red for the wrong reason"
  }
done
# ...and the login half must stay green, because that is what makes this specific.
login_red="$(printf '%s\n' "$ctl" | grep '@fail@' | grep -c '^login/' || true)"
[ "$login_red" -eq 0 ] || {
  say "FAIL: the login-role assertions went red without FORCE ($login_red of them)."
  say "      They should not: the login role is not the owner, so FORCE is not what denies"
  say "      IT. A control that takes the login half down with it is measuring something else."
  printf '%s\n' "$ctl" | grep '@fail@' | awk -F@ '{print "       " $1}' | head -8 | sed 's/^/       /'
  fail "the FORCE control is not specific to the owner"
}
say "   without FORCE: $ctl_failures assertion(s) red, every one of them an owner/ or sweep/ assertion"
say "   with FORCE:    0 red"
say "   the login-role half stayed green throughout, which is what makes this specific:"
say "   an isolation suite written only against the application role passes on a"
say "   template with no FORCE at all."

# ---------------------------------------------------------------------------
# ASSERTION 5 — THE SWEEP'S OWN CONTROL, INSIDE THE SCOPED SWEEP.
#
# Assertion 0b proves the scope is narrow enough. This proves narrowing it did
# not turn the sweep into a green constant — which is the failure mode of every
# tempting version of this fix. Scope the sweep to `pg_temp` alone, or to
# `cafaye` alone, and all three sweep assertions pass forever while naming no
# real table in any adopter: `sweep/names-an-unprotected-table` finds the
# control, `sweep/every-account-scoped-table-is-protected` counts it, and
# `sweep/the-only-finding-is-the-control` matches it. Three greens, zero
# information, and the sweep's positive control is now a control of nothing.
#
# So: a SECOND unprotected account-scoped table, planted in a schema the
# substrate WAS applied in and left there permanently, must turn the proof red.
# The scope is derived from the policies `protect_table` wrote, so this is the
# honest question -- "is a real account-scoped table in the substrate's own
# territory still named?" -- rather than an artefact of how the scope is spelled.
#
# It is `$ALPHA`'s own public schema, which is exactly where a service's tables
# live and exactly what a service reaches by adding a column to a new table and
# forgetting the substrate.
say ""
say "== assertion 5: the sweep still names an unprotected table in a schema the substrate OWNS"
psql_in "$ALPHA" "$ALPHA" "
  create table if not exists kit_sweep_control (
    id int primary key,
    account_id uuid not null
  )" >/dev/null

ctl_scope="$(run_script "$ALPHA" /tmp/isolation.sql)"
scope_failures="$(printf '%s\n' "$ctl_scope" | grep '@fail@' || true)"
if [ -z "$scope_failures" ]; then
  say "FAIL: an unprotected account-scoped table in the substrate's own schema was NOT named."
  say "      The sweep is scoped to the schemas it was applied in, and this table is in one of"
  say "      them, so it is exactly what the sweep exists to find. A sweep that cannot go red on"
  say "      it is a green constant: it would pass on a service that never protected anything."
  fail "the sweep's control cannot fail inside its own scope"
fi
# ...and by the sweep assertion, not by an unrelated one going red.
printf '%s\n' "$ctl_scope" | grep -q '^sweep/every-account-scoped-table-is-protected@' || {
  say "FAIL: the planted table went red, but NOT via sweep/every-account-scoped-table-is-protected."
  printf '%s\n' "$scope_failures" | awk -F@ '{print "       red instead: " $1}' | head -8
  fail "the scoped sweep's control is red for the wrong reason"
}
dropped="$(psql_in "$ALPHA" "$ALPHA" "DROP TABLE kit_sweep_control" >/dev/null && printf 'dropped')"
[ "$dropped" = "dropped" ] || fail "could not remove the planted table, so every later assertion in this file would run against a red sweep"
say "   one unprotected account-scoped table in the substrate's own schema, and the sweep"
say "   named it: sweep/every-account-scoped-table-is-protected and"
say "   sweep/the-only-finding-is-the-control both went red. The scope is narrow enough for"
say "   an adopter (assertion 0b) and still able to fail (this)."

# Put the substrate back so anything after this sees the real thing.
docker exec -e PGPASSWORD=cafaye "$C" psql -U "$ALPHA" -d "$ALPHA" \
  -v ON_ERROR_STOP=1 -q -f /tmp/substrate.sql >/dev/null 2>&1

# ---------------------------------------------------------------------------
# ASSERTION 3 — the `(select ...)` wrapping, MEASURED rather than asserted.
#
# Two temporary tables with identical rows and identical policies, differing only
# in how the identity is written. A counting function records how many times it is
# called, so the number is the plan's behaviour rather than this file's reading of
# a document.
say ""
say "== assertion 3: the (select ...) wrapping, measured"
cat >"$WORK/initplan.sql" <<'INITPLAN'
begin;
create temp table counter(n bigint);
insert into counter values (0);
create or replace function probe_identity()
returns uuid language plpgsql volatile security definer as $fn$
begin update counter set n = n + 1; return '11111111-1111-1111-1111-111111111111'; end $fn$;
create temp table rows_probe(id int primary key, account_id uuid not null);
insert into rows_probe select g, '11111111-1111-1111-1111-111111111111'
  from generate_series(1, 5) g;
alter table rows_probe enable row level security;
alter table rows_probe force row level security;
grant select on rows_probe to current_user;

create policy wrapped on rows_probe for select to public
  using (account_id = (select probe_identity()));
update counter set n = 0;
select count(*) from rows_probe;
select 'wrapped' as form, (select n from counter) as calls;

drop policy wrapped on rows_probe;
create policy bare on rows_probe for select to public
  using (account_id = probe_identity());
update counter set n = 0;
select count(*) from rows_probe;
select 'bare' as form, (select n from counter) as calls;
rollback;
INITPLAN
docker cp "$WORK/initplan.sql" "$C:/tmp/initplan.sql" >/dev/null
plan_out="$(docker exec -e PGPASSWORD=cafaye "$C" psql -U "$ALPHA" -d "$ALPHA" \
  -A -t -F' ' -v ON_ERROR_STOP=1 -f /tmp/initplan.sql 2>/dev/null | grep -E '^(wrapped|bare) ')"
wrapped_calls="$(printf '%s\n' "$plan_out" | awk '$1=="wrapped"{print $2}')"
bare_calls="$(printf '%s\n' "$plan_out" | awk '$1=="bare"{print $2}')"

[ -n "$wrapped_calls" ] && [ -n "$bare_calls" ] || {
  say "FAIL: the init-plan measurement produced nothing."
  printf '%s\n' "$plan_out" | sed 's/^/       /'
  fail "could not measure the wrapped/bare difference"
}
say "   five rows, one query, identity function invocations:"
say "     (select …) wrapped:  $wrapped_calls"
say "     bare call:           $bare_calls"
if [ "$wrapped_calls" -ge "$bare_calls" ]; then
  fail "the wrapped form called the identity function $wrapped_calls time(s) and the bare form $bare_calls. The wrapping is supposed to be the cheaper one; if this ever inverts, Postgres has changed its mind about InitPlans and every claim about it in substrate.sql is wrong."
fi
say "   the same policy and the same rows; only the wrapping differs."

# ---------------------------------------------------------------------------
# ASSERTION 6 — THE DATABASE GRADES ITSELF.
#
# Assertions 1-5 are the boundary RUN: they execute denials and read verdicts.
# This one asks the opposite question, and it is the one the other five cannot
# ask. Every assertion above is satisfied by a policy that PERMITS everything,
# because a permissive predicate returns rows and a denial cannot tell
# "permitted because the predicate said so" from "permitted by accident". Nor can
# any file scanner see that two permissive policies on one (table, role, command)
# combine with OR and the table is wider than either reads.
#
# So `templates/database/tenancy/advisor.sql` is installed here and RUN, against
# the same cluster, over the same tables the substrate wrote. A rule that cannot
# be executed is a comment.
#
# THE SCOPE IS DERIVED, never named, and for the reason `substrate.sql`'s sweep
# derives its own: the schemas a `protect_table` call actually wrote into. A list
# of schemas here would be a second thing to remember and a thing to forget on
# the first service whose tables live somewhere else.
#
# THE TABLES ARE REAL ONES, and `api_keys` is the interesting one: it carries all
# FIVE of `protect_credential_table`'s policies, so `(api_keys, alpha, SELECT)`
# holds two permissive policies. MD24's fifth policy is therefore the live case
# for `multiple_permissive_policies`, and the advisor is asked about it on every
# run of this suite rather than in a comment claiming the answer.
say ""
say "== assertion 6: templates/database/tenancy/advisor.sql, against this cluster"

docker cp "$ADVISOR" "$C:/tmp/advisor.sql" >/dev/null
if ! docker exec -e PGPASSWORD=cafaye "$C" psql -U "$ALPHA" -d "$ALPHA" \
  -v ON_ERROR_STOP=1 -q -f /tmp/advisor.sql >"$WORK/advisor.log" 2>&1; then
  say "FAIL: advisor.sql did not install. Last lines:"
  tail -20 "$WORK/advisor.log" | sed 's/^/       /'
  fail "advisor install"
fi
say "   installed: cafaye.advisor_findings(p_schemas text[])"

# Two tables, created exactly as a service's migrations create them: a
# membership one, and a credential one. The second is the whole point — it is
# the only table in this fixture that gets a fifth policy for a DIGEST, and
# `multiple_permissive_policies` is going to be asked about it. The first is the
# same shape for the CALLER, and `account_users` is deliberately the real fleet
# name rather than a generic one: it is the table whose missing user scope made
# `GET /v1/accounts` answer `[]` to an owner, and a fixture with a different name
# would let a future reader assume the mechanism had been proven against a
# generic stand-in.
psql_in "$ALPHA" "$ALPHA" "
  set client_min_messages = warning;
  drop table if exists public.api_keys;
  drop table if exists public.account_users;
  create table public.account_users (
    id bigint generated always as identity primary key,
    account_id uuid not null,
    user_id uuid not null,
    email text not null);
  create table public.api_keys (
    id bigint generated always as identity primary key,
    account_id uuid not null,
    token_digest text not null);
" >/dev/null
psql_in "$ALPHA" "$ALPHA" "
  set client_min_messages = warning;
  select cafaye.protect_membership_table('public.account_users', 'user_id')" >/dev/null
psql_in "$ALPHA" "$ALPHA" "
  set client_min_messages = warning;
  select cafaye.protect_credential_table('public.api_keys', 'token_digest')" >/dev/null

# Five from protect_membership_table and five from protect_credential_table, each
# being four from protect_table plus one of its own. Counted, because everything
# below is a claim about those ten policies and a fixture that had silently
# installed nine would still produce a clean advisor run.
policies_now="$(psql_in "$ALPHA" "$ALPHA" "
  select count(*) from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'")"
[ "$policies_now" = "10" ] \
  || fail "expected 10 policies on the substrate's two tables (5 + 5); found $policies_now. The advisor is about to be asked about tables that are not the ones a service would build."

scoped="$(psql_in "$ALPHA" "$ALPHA" "
  select coalesce(array_agg(distinct n.nspname), '{}'::name[])::text
    from pg_namespace n
    join pg_class c on c.relnamespace = n.oid
    join pg_policy p on p.polrelid = c.oid
   where p.polname ~ '_cafaye_(select|insert|update|delete)$'")"
scoped="${scoped#\{}"
scoped="${scoped%\}}"
# The derived list is turned into an array by the SERVER rather than pasted into a
# literal here. A hand-assembled `'{a, b}'` is a second place the scope can be
# wrong, and it is wrong in the direction that matters: a malformed array literal
# is an error, while a malformed one that happens to parse is a quiet scope.
scoped="${scoped// /},cafaye"
say "   scope, read back from the policies protect_table wrote: ${scoped//,/, }"

adv="$(psql_in "$ALPHA" "$ALPHA" "
  select level || '@' || name || '@' || coalesce(metadata->>'name', '') || '@' || detail
    from cafaye.advisor_findings(string_to_array('$scoped', ',')::text[])
   order by cache_key")"

if [ -n "$adv" ]; then
  say "   the advisor's complete output, every level including INFO:"
  printf '%s\n' "$adv" | while IFS= read -r row; do
    level="${row%%@*}"
    rest="${row#*@}"
    rule="${rest%%@*}"
    rest2="${rest#*@}"
    what="${rest2%%@*}"
    detail="${rest2#*@}"
    printf '     [%s] %s\n' "$level" "$rule"
    printf '         on: %s\n' "$what"
    printf '         %s\n' "$detail"
  done
fi

adv_bad="$(printf '%s\n' "$adv" | grep -E '^(ERROR|WARN)@' || true)"
if [ -n "$adv_bad" ]; then
  say "FAIL: the advisor reported ERROR/WARN findings against tables the substrate"
  say "      wrote. The substrate is the thing these rules are about, so a finding"
  say "      here is a defect in the substrate or a defect in a rule — not a service's."
  printf '%s\n' "$adv_bad" | awk -F@ '{print "       [" $1 "] " $2 " on " $3}' | head -12
  fail "the substrate does not pass the substrate's own advisor"
fi
say "   zero ERROR and zero WARN findings against account_users and api_keys."
say "   BOTH of them carry FIVE policies (4 from protect_table, 1 from the"
say "   mechanism that owns them — protect_credential_table, protect_membership_table),"
say "   so (api_keys, alpha, SELECT) and (account_users, alpha, SELECT) each hold"
say "   two permissive policies and multiple_permissive_policies was asked about"
say "   both directly."
say "   It stayed silent because the group is all substrate-written — which is the"
say "   rule's own exemption semantics. That is now checked against BOTH exemptions:"
say "   the fifth policy that reads a digest and the fifth that reads a caller are"
say "   different claims, and a rule exempting only the one it was written for would"
say "   report the other as a finding on the substrate's own table."

# ---------------------------------------------------------------------------
# ASSERTION 6b — THE EXEMPTION'S OWN CONTROL, and it is the MD24 question rather
# than a tidy-up.
#
# `multiple_permissive_policies` is the one rule that has to be exempt for MD24's
# credential mechanism to be allowed to exist: `protect_credential_table` adds a
# fifth policy whose predicate is the digest the CALLER presented, so
# (api_keys, alpha, SELECT) permanently holds two permissive policies and they
# combine with OR. The exemption is that the group is all substrate-written.
#
# An exemption with no control is a rule that has been switched off, and this is
# where that would show: add ONE hand-written permissive policy to `api_keys` and
# the group stops being all-of, so the rule must fire AND NAME the hand-written
# policy specifically. A firing that named only the substrate's two would prove
# the rule is on; a firing that does not name it proves nothing about which policy
# it objected to.
say ""
say "== assertion 6b: the multiple_permissive_policies exemption does not absorb a hand-written policy"
psql_in "$ALPHA" "$ALPHA" "
  create policy hand_written_extra on public.api_keys
    for select to public using (true)" >/dev/null

md24="$(psql_in "$ALPHA" "$ALPHA" "
  select detail from cafaye.advisor_findings(string_to_array('public,cafaye', ',')::text[])
   where name = 'multiple_permissive_policies'
     and metadata->>'name' = 'api_keys'")"
[ -n "$md24" ] || {
  say "FAIL: a hand-written permissive SELECT on api_keys did NOT trip"
  say "      multiple_permissive_policies. The exemption is meant to cover MD24's OWN"
  say "      fifth policy and nothing else, so this is either an exemption that has"
  say "      become a switch, or a rule that stopped recognising a substrate policy."
  fail "the multiple_permissive_policies exemption absorbs a hand-written policy"
}
case "$md24" in
  *"Not written by the substrate: hand_written_extra"*) ;;
  *)
    say "FAIL: the rule fired on (api_keys, SELECT) but did not NAME the hand-written policy."
    say "      A finding that lists both policies leaves the reader to work out which"
    say "      one the rule objected to, which is the work the detail column exists to do."
    say "      reported: $md24"
    fail "the finding does not say which policy was hand-written"
    ;;
esac
say "   one hand-written permissive SELECT added to api_keys, and the rule fired:"
say "     $(printf '%s\n' "$md24")"
say "   the substrate's own five policies were NOT the complaint, and the exemption"
say "   that let them coexist is still letting exactly them coexist."

psql_in "$ALPHA" "$ALPHA" \
  "set client_min_messages = warning; drop policy hand_written_extra on public.api_keys" >/dev/null
still="$(psql_in "$ALPHA" "$ALPHA" "
  select count(*) from cafaye.advisor_findings(string_to_array('public,cafaye', ',')::text[])
   where level in ('ERROR', 'WARN')")"
[ "$still" = "0" ] || fail "removing the hand-written policy left $still finding(s); the control's cleanup did not restore a clean advisor run"
say "   policy dropped, and the advisor is clean again: 0 ERROR, 0 WARN."

# ---------------------------------------------------------------------------
# ASSERTION 7 — THE HONEST NEGATIVES. A detective that has never fired is a
# detective you cannot trust, so every rule is run against a fixture BUILT TO TRIP
# IT, and each must name itself.
#
# Every fixture below is in its own schema, the substrate was never applied to it,
# and the advisor is scoped to that schema alone. That is not tidiness: it is what
# makes the control specific. Scoped to the whole database, a rule that fires
# proves only that the advisor returned rows, and seven of these nine could be
# satisfied by any of the others. Named rule, named fixture, one rule proven able
# to fire.
#
# AND WHAT IT STILL CANNOT PROVE, which is why 7b exists below: that any of them
# is SELECTIVE. A rule that fires on every view, every policy or every table is
# satisfied by this assertion as completely as a rule that fires on exactly the
# right one. `security_definer_view` is the rule where that matters most, because
# the two ways to write it badly are "fires on nothing" and "fires on everything",
# and only one of them is a control.
#
# AND IT IS ALSO WHAT PROVES THE ADVISOR STANDS ALONE. Nothing here calls a
# `cafaye.*` function the substrate owns except the two identity seams a policy
# has to be written against — so these fixtures are a schema on a database where
# the substrate was applied to `public` and nothing else, which is the shape of
# the service that has not finished adopting.
cat >"$WORK/advisor_fixture.sql" <<'FIXTURE'
create schema kit_advisor_fixture;
  set client_min_messages = warning;

-- (3) rls_policy_always_true, and (5) multiple_permissive_policies: the second
-- policy is a SECOND PERMISSIVE policy on the same (table, role, command) as the
-- first, which is what trips the second rule. One fixture, two rules, and the
-- pairing is deliberate: these two are the shapes a single careless migration
-- produces.
create table kit_advisor_fixture.always_true (
  id int primary key, account_id uuid not null);
alter table kit_advisor_fixture.always_true enable row level security;
create policy fixture_write_all on kit_advisor_fixture.always_true
  for all to public using (true) with check (true);
create policy fixture_read on kit_advisor_fixture.always_true
  for select to public using (account_id = (select cafaye.current_account_id()));

-- (1) policy_exists_rls_disabled: a policy that is inert. This reads as correct
-- in review — the policies exist — and enforces nothing.
create table kit_advisor_fixture.policies_without_rls (
  id int primary key, account_id uuid not null);
create policy fixture_only on kit_advisor_fixture.policies_without_rls
  for select to public using (account_id = (select cafaye.current_account_id()));

-- (2) rls_disabled_in_public: no RLS, and a login role can read it. The grant is
-- part of the fixture, not a detail: without it the table is unreachable and
-- there is nothing to report.
create table kit_advisor_fixture.reachable_no_rls (
  id int primary key, note text not null);
grant select on kit_advisor_fixture.reachable_no_rls to public;

-- (4) rls_references_user_metadata, the CATALOG half. `profile_flags` is the
-- service's own `user_metadata`: a predicate that decides access from rows the
-- caller can write. The word `user_metadata` appears nowhere in it, which is the
-- point — the keyword half of the rule cannot find this and the catalog half can.
create table kit_advisor_fixture.profile_flags (
  account_id uuid not null, is_admin boolean not null default false);
create table kit_advisor_fixture.admin_only (
  id int primary key, account_id uuid not null);
alter table kit_advisor_fixture.admin_only enable row level security;
create policy fixture_admin on kit_advisor_fixture.admin_only for select to public
  using (exists (select 1 from kit_advisor_fixture.profile_flags f
                   where f.account_id = admin_only.account_id and f.is_admin));
grant select, insert, update on kit_advisor_fixture.profile_flags to public;

-- (4) rls_references_user_metadata, THE FUNCTION HALF, and its CONTROL. Three
-- objects, and the third is what makes the first two mean anything.
--
-- `writable_flags` is ONE table, caller-writable, and two policies reach it:
--
--   direct_policy   THE CONTROL, and it is not optional. The SAME table, reached
--                   DIRECTLY, no function in the path. Without it, "rule 4 now
--                   fires on a helper-routed policy" and "rule 4 fires on
--                   everything" are the SAME observation -- and this repository
--                   has already shipped a proof that exactly that pair of
--                   readings was indistinguishable (AGENTS.md on breakage 75: a
--                   green control two different checks could satisfy proves
--                   neither). One table, two routes, one rule: the rule has to
--                   answer differently about the ROUTE, or it is counting tables.
--
--   helper_routed   reached through a SECURITY DEFINER function. This is the
--                   shape rule 4 was blind to, and `measure-advisor-pgproc.sql`
--                   is the measurement that says so: pg_depend on the policy
--                   names the FUNCTION, not the relation, so the walk has to
--                   take a pg_proc hop to arrive here.
--
--   helper_opaque   the same table through a helper whose body the catalog does
--                   NOT record -- a `language sql` STRING body, which is how a
--                   hand-written helper is actually written, and the shape the
--                   measurement says pg_depend cannot carry. It is here as a
--                   NEGATIVE, asserted silent below, and it is the reason the
--                   other two mean something: the rule fires on one route and
--                   not the other, so it is reading the ROUTE and not the table.
create table kit_advisor_fixture.writable_flags (
  account_id uuid not null, is_admin boolean not null default false);
create table kit_advisor_fixture.direct_policy (
  id int primary key, account_id uuid not null);
alter table kit_advisor_fixture.direct_policy enable row level security;
create policy fixture_direct on kit_advisor_fixture.direct_policy for select to public
  using (exists (select 1 from kit_advisor_fixture.writable_flags f
                   where f.account_id = direct_policy.account_id and f.is_admin));

create table kit_advisor_fixture.helper_routed (
  id int primary key, account_id uuid not null);
alter table kit_advisor_fixture.helper_routed enable row level security;
-- BEGIN ATOMIC, and the choice is the measurement's: PG14+ parses that body at
-- CREATE FUNCTION time, so pg_depend records pg_proc -> pg_class -> the flags
-- table and the hop has something to follow. `helper_opaque` below is the same
-- helper written the ordinary way, and the difference between the two is the
-- whole finding.
create function kit_advisor_fixture.may_read_admin() returns boolean
  language sql stable security definer begin atomic
  select exists (select 1 from kit_advisor_fixture.writable_flags f where f.is_admin);
end;
create policy fixture_via_helper on kit_advisor_fixture.helper_routed for select to public
  using (kit_advisor_fixture.may_read_admin());

create table kit_advisor_fixture.helper_opaque (
  id int primary key, account_id uuid not null);
alter table kit_advisor_fixture.helper_opaque enable row level security;
create function kit_advisor_fixture.may_read_admin_opaque() returns boolean
  language sql stable security definer
  as $$ select exists (select 1 from kit_advisor_fixture.writable_flags f where f.is_admin) $$;
create policy fixture_via_opaque_helper on kit_advisor_fixture.helper_opaque for select to public
  using (kit_advisor_fixture.may_read_admin_opaque());

grant select, insert, update on kit_advisor_fixture.writable_flags to public;
grant select on kit_advisor_fixture.direct_policy to public;
grant select on kit_advisor_fixture.helper_routed to public;
grant select on kit_advisor_fixture.helper_opaque to public;

-- (6) login_role_security_definer_executable: SECURITY DEFINER, callable without
-- signing in as anything in particular. The substrate writes none — every function
-- it owns is an invoker — which is what assertion 6 measured.
create function kit_advisor_fixture.escalate() returns int
  language sql security definer as $$ select 1 $$;
grant execute on function kit_advisor_fixture.escalate() to public;

-- (7) auth_rls_initplan: the bare form of the call assertion 3 measured at five
-- invocations per five rows. The same shape, written by hand instead of by
-- protect_table, and correct — and slow.
create table kit_advisor_fixture.bare_call (
  id int primary key, account_id uuid not null);
alter table kit_advisor_fixture.bare_call enable row level security;
create policy fixture_bare on kit_advisor_fixture.bare_call for select to public
  using (account_id = cafaye.current_account_id());

-- (7b) rls_policy_correlated_membership. The subquery inside the IN references
-- this table's own row, so the membership lookup runs once per candidate row
-- rather than once per statement. `tests/rls_perf_test.sh` MEASURES the cost of
-- exactly this shape (2000 ms against 18 ms for the inverted one), so this fixture
-- is not a shape somebody imagines: it is the one the number came from.
create table kit_advisor_fixture.correlated_membership (
  id int primary key, account_id uuid not null, member_of_account uuid not null);
alter table kit_advisor_fixture.correlated_membership enable row level security;
alter table kit_advisor_fixture.correlated_membership force row level security;
create table kit_advisor_fixture.membership (
  account_id uuid not null, member_of_account uuid not null);
create policy fixture_correlated on kit_advisor_fixture.correlated_membership
  for select to public
  using ((select cafaye.current_account_id()) in
         (select m.account_id from kit_advisor_fixture.membership m
           where m.member_of_account = correlated_membership.member_of_account));

-- THE CONTROL, and it is the half that makes the rule trustworthy. The same
-- membership table, the same IN, and NO reference to the policy's own table
-- inside the subquery: the direction is inverted, so the lookup is evaluated once.
-- A rule that fired here would fire on the shape `tests/rls_perf_test.sh` measures
-- at 18 ms, which is the same thing as being a rule nobody reads.
create table kit_advisor_fixture.inverted_membership (
  id int primary key, account_id uuid not null, member_of_account uuid not null);
alter table kit_advisor_fixture.inverted_membership enable row level security;
alter table kit_advisor_fixture.inverted_membership force row level security;
create policy fixture_inverted on kit_advisor_fixture.inverted_membership
  for select to public
  using (inverted_membership.member_of_account in
         (select m.member_of_account from kit_advisor_fixture.membership m
           where m.account_id = (select cafaye.current_account_id())));

-- THE OTHER NEGATIVE, and the reason the rule does not fire on correlation in
-- general. An EXISTS whose OUTER hop is correlated and cannot be inverted — this
-- table carries no membership column of its own — measured at 56 ms against the
-- correlated IN's 2000 ms, because with the inner hop inverted the planner
-- re-associates it into a semi-join. The boundary is per HOP.
create table kit_advisor_fixture.linked_only (
  id int primary key, account_id uuid not null);
alter table kit_advisor_fixture.linked_only enable row level security;
alter table kit_advisor_fixture.linked_only force row level security;
create table kit_advisor_fixture.linked_membership (
  linked_id int not null, member_of_account uuid not null);
create policy fixture_linked on kit_advisor_fixture.linked_only
  for select to public
  using (exists (select 1 from kit_advisor_fixture.linked_membership l
                  where l.linked_id = linked_only.id
                    and l.member_of_account in
                        (select m.member_of_account from kit_advisor_fixture.membership m
                          where m.account_id = (select cafaye.current_account_id()))));

-- (8) rls_enabled_no_policy: RLS on, no policy, every row hidden. INFO and not a
-- breach — a fail-closed outage is still an outage, and the catalog is where it
-- shows up first.
create table kit_advisor_fixture.silent (
  id int primary key, account_id uuid not null);
alter table kit_advisor_fixture.silent enable row level security;

-- (9) security_definer_view. FOUR fixtures, not one, because a rule that fires
-- on everything and a rule that fires on nothing both satisfy a single positive
-- assertion, and this rule has two ways to be useless:
--
--   definer_view     POSITIVE. A plain view over the substrate-written
--                    account-scoped table, which IS the hole: its queries run
--                    as its owner, so the policies on `protected_accounts` are
--                    evaluated against a role that is exempt from them.
--   invoker_view     THE NEGATIVE THAT MATTERS. The SAME view over the SAME
--                    table with `security_invoker = true`, which is the whole
--                    remediation. A rule that reports this one is reporting its
--                    own fix as the disease, and a reader who saw both rows
--                    would stop reading both.
--   plain_reads      THE Misfire GUARD. A view over a table with NO row-level
--                    security at all. There is no policy to bypass, so this is
--                    not the finding — and if the rule fired here it would fire
--                    on every reporting view in every schema, which is how a
--                    security rule gets switched off.
--   definer_no_grant A view nobody can reach. The bypass is real and no caller
--                    can reach it, so it is not this rule's finding.
--
-- `definer_no_grant` NEEDS A NOLOGIN OWNER, and that is a measurement rather
-- than a stylistic choice. The fixture is created by `alpha`, which is a LOGIN
-- role, so alpha OWNS the view and `has_table_privilege` is true for the owner
-- alone — `REVOKE ALL … FROM PUBLIC` does nothing, because ownership is not a
-- grant and revoking every grant does not touch it. Measured: with a LOGIN owner
-- the rule fires; with a NOLOGIN owner it is silent. The first run of this
-- fixture failed exactly here, which is why the comment above says what it says.
--
-- THE UNREACHABLE VIEW IS BUILT BY THE CLUSTER ADMIN, and that is a measurement
-- rather than a convenience. Two failed fixtures led here, and both are worth
-- writing down because the rule was right in both cases and the FIXTURE was not:
--
--   1. The fixture is applied as `alpha`, which is a LOGIN role, so alpha OWNS
--      the view. Ownership is not a grant, so `revoke all … from public` does
--      nothing and the rule fires. Measured: ownership alone is enough.
--   2. Giving the view a NOLOGIN owner is not enough either, because reaching
--      that owner needs `grant <owner> to alpha` — MEMBERSHIP, and membership
--      carries the owner's privileges. Measured: with `alpha` a member of the
--      owner role, `has_table_privilege('alpha', …, 'SELECT')` is TRUE through
--      the membership and the rule fires, correctly.
--
-- So the fixture is built by `cafaye`, the cluster's admin role, which is
-- excluded from `api_roles` by exactly the predicate every other rule here uses
-- (`not rolsuper`). A superuser-owned view that no login role can reach is a
-- real and common shape — and it is the shape a reporting view has when it is
-- owned by the migration role and nobody was granted SELECT on it.
--
-- It is a SEPARATE script, applied by the admin after the schema exists, because
-- it cannot be part of the one `alpha` applies: alpha is the schema's owner and
-- a `set role` in the middle of that script would leave the rest of it running
-- as someone else. `advisor_unreachable_fixture.sql` below.
--
-- AND THE TRANSITIVE ONE, because a view over a view is the same hole: Postgres
-- evaluates the outer view with the outer view's owner's privileges and the
-- inner one with the inner one's, and no hop in that chain puts a caller's
-- policies back in force. `nested_definer_view` reads ONLY another view and no
-- table, so a rule that stopped at the first hop would miss it — and it is the
-- view a caller actually queries.
--
-- `over_invoker_view` is the converse and is the guard on the fix: it reads only
-- an invoker view, so the walk must STOP at that hop rather than walking past
-- it and reporting a chain whose innermost link is already correct.
drop table if exists kit_advisor_fixture.protected_accounts cascade;
create table kit_advisor_fixture.protected_accounts (
  id int primary key, account_id uuid not null);
alter table kit_advisor_fixture.protected_accounts enable row level security;
alter table kit_advisor_fixture.protected_accounts force row level security;
create policy fixture_scoped on kit_advisor_fixture.protected_accounts
  for select to public
  using (account_id = (select cafaye.current_account_id()));

drop table if exists kit_advisor_fixture.unprotected_reads cascade;
create table kit_advisor_fixture.unprotected_reads (id int primary key);

-- Every `create view` is `or replace`, and every `create table` is preceded by a
-- drop, because this fixture has failed to install three times while being
-- written and a leftover object from the previous run reads as a new defect. A
-- fixture that only installs on a clean cluster cannot be iterated on, and the
-- person iterating on it is whoever is debugging the rule.
create or replace view kit_advisor_fixture.definer_view as
  select id, account_id from kit_advisor_fixture.protected_accounts;
create or replace view kit_advisor_fixture.invoker_view
  with (security_invoker = true) as
  select id, account_id from kit_advisor_fixture.protected_accounts;
create or replace view kit_advisor_fixture.plain_reads as
  select id from kit_advisor_fixture.unprotected_reads;
create or replace view kit_advisor_fixture.definer_no_grant as
  select id, account_id from kit_advisor_fixture.protected_accounts;
create or replace view kit_advisor_fixture.nested_definer_view as
  select id from kit_advisor_fixture.definer_view;
create or replace view kit_advisor_fixture.over_invoker_view as
  select id from kit_advisor_fixture.invoker_view;
-- THE SPELLING THIS FLEET ACTUALLY WRITES. Postgres stores reloptions
-- VERBATIM and does not canonicalise the boolean, so `security_invoker = on`
-- is stored as `on`, not as `true` — measured, on PG17. `core`'s own conforming
-- fixture uses `on`
-- (`harness/tests/fixtures/tenancy/conforming/migrations/0002_rls.sql:89`), so
-- an equality test against the literal `security_invoker=true` passes kit's own
-- suite and misses the fleet's own idiom. This view is over an `on`-spelled
-- invoker, so the transitive walk must stop there too.
create or replace view kit_advisor_fixture.on_spelled_invoker with (security_invoker = on) as
  select id, account_id from kit_advisor_fixture.protected_accounts;
create or replace view kit_advisor_fixture.over_on_spelled_invoker as
  select id from kit_advisor_fixture.on_spelled_invoker;

-- The GRANT is the fixture, not a detail. `has_table_privilege` includes
-- privileges held through PUBLIC, and the rule asks about capability rather than
-- about grants, so a grant to `public` reaches this view for every login role on
-- the cluster. `definer_no_grant` is created without one and `revoke`d, so the
-- "nobody can reach it" case is actually unreachable rather than merely
-- unwritten.
grant select on kit_advisor_fixture.definer_view to public;
grant select on kit_advisor_fixture.invoker_view to public;
grant select on kit_advisor_fixture.plain_reads to public;
grant select on kit_advisor_fixture.nested_definer_view to public;
grant select on kit_advisor_fixture.over_invoker_view to public;
grant select on kit_advisor_fixture.on_spelled_invoker to public;
grant select on kit_advisor_fixture.over_on_spelled_invoker to public;
revoke all on kit_advisor_fixture.definer_no_grant from public;
FIXTURE

say ""
say "== assertion 7: every rule, on a fixture built to trip it"
docker cp "$WORK/advisor_fixture.sql" "$C:/tmp/advisor_fixture.sql" >/dev/null
if ! docker exec -e PGPASSWORD=cafaye "$C" psql -U "$ALPHA" -d "$ALPHA" \
  -v ON_ERROR_STOP=1 -q -f /tmp/advisor_fixture.sql >"$WORK/fixture.log" 2>&1; then
  say "FAIL: the advisor's negative fixtures did not install. Last lines:"
  tail -20 "$WORK/fixture.log" | sed 's/^/       /'
  fail "the negative fixtures did not install"
fi

# The UNREACHABLE VIEW is a SEPARATE script applied by the cluster admin after the
# main fixture, because it cannot be part of the one `alpha` applies. Two failed
# fixtures led here and the RULE was right both times -- the FIXTURE was wrong:
#
#   1. Applied as `alpha`, which is a LOGIN role, so alpha OWNS the view.
#      Ownership is not a grant: `revoke all ... from public` does nothing.
#   2. Giving it a NOLOGIN owner is not enough either, because reaching that owner
#      requires `grant <owner> to alpha` -- MEMBERSHIP, and membership carries the
#      owner's privileges. `has_table_privilege('alpha', ..., 'SELECT')` is then
#      TRUE through the membership.
#
# So `cafaye` builds it. `cafaye` is excluded from `api_roles` by the same
# `not rolsuper` predicate every other rule here uses, and a superuser-owned view
# no login role can reach is a real shape: it is a reporting view owned by the
# migration role that nobody was granted SELECT on.
cat >"$WORK/advisor_unreachable_fixture.sql" <<'UNREACHABLE'
set client_min_messages = warning;
drop table if exists kit_advisor_fixture.owner_protected cascade;
create table kit_advisor_fixture.owner_protected (
  id int primary key, account_id uuid not null);
alter table kit_advisor_fixture.owner_protected enable row level security;
alter table kit_advisor_fixture.owner_protected force row level security;
create policy fixture_owner_scoped on kit_advisor_fixture.owner_protected
  for select to public
  using (account_id = (select cafaye.current_account_id()));
drop view if exists kit_advisor_fixture.definer_no_grant;
create view kit_advisor_fixture.definer_no_grant as
  select id, account_id from kit_advisor_fixture.owner_protected;
-- The revoke is the FIXTURE, not a detail: without it the view is reachable
-- through PUBLIC and the rule fires, correctly, because it IS the finding then.
revoke all on kit_advisor_fixture.definer_no_grant from public;
revoke all on kit_advisor_fixture.owner_protected from public;
UNREACHABLE
docker cp "$WORK/advisor_unreachable_fixture.sql" "$C:/tmp/advisor_unreachable_fixture.sql" >/dev/null
if ! docker exec -e PGPASSWORD=cafaye "$C" psql -U cafaye -d "$ALPHA" \
  -v ON_ERROR_STOP=1 -q -f /tmp/advisor_unreachable_fixture.sql >"$WORK/unreach.log" 2>&1; then
  say "FAIL: the unreachable-view fixture did not install. Last lines:"
  tail -20 "$WORK/unreach.log" | sed 's/^/       /'
  fail "the unreachable-view fixture did not install"
fi
say "   the unreachable view is built by the cluster admin, not by alpha: measured,"
say "   a LOGIN owner is reachable by ownership alone and a NOLOGIN one is"
say "   reachable by membership, and the rule was right about both."


neg="$(psql_in "$ALPHA" "$ALPHA" "
  select name || '@' || coalesce(metadata->>'name', '')
    from cafaye.advisor_findings(string_to_array('kit_advisor_fixture', ',')::text[])
   order by cache_key")"

# Every rule, and the fixture that must trip it. A rule that has gone quiet here
# is a rule nobody can rely on, and the whole cost of this assertion is that it
# is a list: a count would be satisfied by the same rule firing twice.
tripped=""
for pair in \
  'policy_exists_rls_disabled:policies_without_rls' \
  'rls_disabled_in_public:reachable_no_rls' \
  'rls_policy_always_true:always_true' \
  'rls_references_user_metadata:admin_only' \
  'rls_references_user_metadata:direct_policy' \
  'rls_references_user_metadata:helper_routed' \
  'multiple_permissive_policies:always_true' \
  'login_role_security_definer_executable:escalate' \
  'auth_rls_initplan:bare_call' \
  'rls_policy_correlated_membership:correlated_membership' \
  'rls_enabled_no_policy:silent' \
  'security_definer_view:definer_view' \
  'security_definer_view:nested_definer_view'; do
  rule="${pair%%:*}"
  fixture="${pair#*:}"
  if printf '%s\n' "$neg" | grep -q "^$rule@$fixture\$"; then
    say "   $rule -> $fixture"
    tripped="$tripped $rule"
  else
    say "FAIL: $rule did NOT fire on the fixture built to trip it ($fixture)."
    say "      A rule that has never fired is a rule nobody can trust, and this one is"
    say "      indistinguishable from a rule that does not work."
    printf '%s\n' "$neg" | awk -F@ '{print "       reported instead: " $1 " on " $2}' | head -12
    fail "an advisor rule cannot fire"
  fi
done
say "   10 rules, 13 fixtures, every rule naming itself and the object it fired on."
say "   scoped to kit_advisor_fixture alone, so each one is proven specific and not"
say "   satisfied by whichever other rule happened to return a row."

# ---------------------------------------------------------------------------
# ASSERTION 7c — THE FUNCTION HOP, ITS CONTROL, AND ITS OPPOSITE.
#
# The list above proves rule 4 CAN fire on a helper-routed policy. It cannot
# prove the hop is what made it fire, and those are different defects: a rule
# that fired on `helper_routed` because it fires on EVERY policy in the schema
# satisfies the list identically. Three checks, and the second and third are the
# ones with teeth:
#
#   1. the finding NAMES the function. `via_functions` is not decoration: it is
#      the only column that says the route was a function, and a reader who is
#      told "policy reads kit_advisor_fixture.writable_flags" and nothing else
#      has to go and work out which of the two policies in this fixture is
#      talking about a SECURITY DEFINER helper.
#   2. THE CONTROL answers differently ON THE SAME TABLE. `direct_policy` reaches
#      the SAME `writable_flags` with no function in the path, and its
#      `via_functions` must be EMPTY. One table, two routes, opposite answers --
#      so the rule is reading the route. Delete either check and this pair is
#      one observation instead of two, which is the shape AGENTS.md calls a
#      control two checks could satisfy.
#   3. `helper_opaque` is SILENT, and this is the negative that decides whether
#      the two positives mean anything. It reaches the same table through a
#      helper whose body pg_depend does not record (measured:
#      `measure-advisor-pgproc.sql`, a `language sql` STRING body records
#      pg_namespace and nothing else). The rule must not fire on it, because the
#      only way to fire is to read `prosrc` and match a table name in SQL text,
#      and a rule that does that fires on a table named in a comment. So this
#      silence is the LIMIT of the rule, asserted rather than apologised for, and
#      rule 6 fires on the helper itself -- which is the honest position: a
#      detector sees the helper, this rule does not claim to be the one.
for pair in 'helper_routed:may_read_admin' 'direct_policy:'; do
  obj="${pair%%:*}"
  fn="${pair#*:}"
  row="$(psql_in "$ALPHA" "$ALPHA" "
    select coalesce((metadata->'via_functions')::text, '(null)') || ' | ' || detail
      from cafaye.advisor_findings(string_to_array('kit_advisor_fixture', ',')::text[])
     where name = 'rls_references_user_metadata'
       and metadata->>'name' = '$obj'")"
  [ -n "$row" ] || fail "no rls_references_user_metadata finding for $obj at all"
  case "$row" in
    *"$fn"*) ;;
    *)
      say "FAIL: the finding on $obj does not report via_functions containing '$fn'."
      say "      got: $row"
      fail "the finding does not say which route the policy took"
      ;;
  esac
  say "   $obj -> via_functions ${fn:-'(empty, the control)'} on the SAME table"
done

if printf '%s\n' "$neg" | grep -q '^rls_references_user_metadata@helper_opaque$'; then
  say "FAIL: rls_references_user_metadata fired on helper_opaque, and must not."
  say "      That policy reaches the same caller-writable table through a helper whose"
  say "      body pg_depend does NOT record, so the only way to reach it is to read"
  say "      prosrc and match a table name in SQL text -- which fires on a table named"
  say "      in a comment. A rule that reaches it that way cannot be told apart from a"
  say "      rule that reaches everything."
  fail "rls_references_user_metadata fired on a policy the catalog does not describe"
fi
say "   helper_opaque -> silent, and that is the rule's measured limit: the catalog"
say "      does not carry a string body, so no rule reads one. See the"
say "      \"what this does not find\" block in advisor.sql and REPORT-kit-advisor-pgproc-01.md."

# ---------------------------------------------------------------------------
# ASSERTION 7b — THE HONEST NEGATIVES OF ASSERTION 7.
#
# The list above proves every rule CAN fire. It cannot prove any rule is
# SELECTIVE, and for `security_definer_view` selectivity is the entire value of
# the rule: the two ways to write it are "fires on every view in the schema" and
# "fires on nothing", and only one of those is a security control. The other is
# a report nobody reads — or a detective that has never fired.
#
# Four views in the fixture schema are here to be SILENT, and each one is silent
# for a different reason, so satisfying all four means the rule is reading
# something rather than counting something:
#
#   invoker_view        the same view over the same table, fixed. A rule that
#                       reports its own remedy would print both rows.
#   plain_reads         a view over a table with NO row-level security. Nothing
#                       to bypass, so nothing to report.
#   definer_no_grant    the hole is real and no login role can reach it.
#   over_invoker_view   reads only an invoker view, so the transitive walk must
#                       STOP at that hop rather than walking past it.
#
# The last one is the one that can pass by accident. A walk that ignored the
# invoker flag would report `over_invoker_view`, and a reader would see that as a
# true positive — because the chain below it really is a definer view. It is
# reported here as a misfire because the finding is about a view that is
# reachable only THROUGH an invoker view, and there the caller's policies are
# already in force.
for quiet in invoker_view plain_reads definer_no_grant over_invoker_view \
             on_spelled_invoker over_on_spelled_invoker; do
  if printf '%s\n' "$neg" | grep -q "^security_definer_view@$quiet\$"; then
    say "FAIL: security_definer_view fired on $quiet, and must not."
    say "      Each of these views is one the rule is required to stay silent on, and"
    say "      each is silent for a DIFFERENT reason: it is its own remedy, it reads no"
    say "      protected table, it is unreachable, or it is reachable only through a"
    say "      security_invoker view. A rule that fires on all of them is not a selective"
    say "      rule; it is a rule that reports every view in the schema, which is how a"
    say "      security rule gets switched off."
    printf '%s\n' "$neg" | grep '^security_definer_view@' \
      | awk -F@ '{print "       reported anyway: " $2}' | head -12
    fail "security_definer_view is not selective"
  fi
  say "   $quiet -> silent, as required."
done
say "   six views, six reasons, all silent: the rule reads whether the view is an"
say "   invoker, whether anything it reaches has policies, and whether a caller can"
say "   reach it -- rather than counting views."
say "   the last two are the same view with the option spelled \`on\` rather than"
say "   \`true\`. Postgres stores reloptions verbatim and core's own fixture writes"
say "   \`on\`, so a rule matching only one spelling would pass this suite while"
say "   missing the fleet's idiom."

# The fixtures go, and their going is asserted rather than assumed: everything
# after this point in a shared container should see the cluster the substrate
# left, and a leftover `using (true)` policy is exactly the sort of thing that
# makes a later run's numbers mean something else.
psql_in "$ALPHA" "$ALPHA" \
  "set client_min_messages = warning; drop schema kit_advisor_fixture cascade" >/dev/null
left="$(psql_in "$ALPHA" "$ALPHA" \
  "select count(*) from pg_namespace where nspname = 'kit_advisor_fixture'")"
[ "$left" = "0" ] || fail "the fixture schema survived its drop, so the next assertion would run against it"
say "   kit_advisor_fixture dropped, asserted gone."

# ---------------------------------------------------------------------------
# ASSERTION 8 — THE AUDIT ANSWERS THE SAME TO EVERY ROLE THAT ASKS.
#
# `cafaye.credential_tables()` is the one query that answers "which tables in this
# database can be read with no account", and `isolation.sql` asserts it as the
# session's own role — which on a real cluster is the owner's, a role with no
# schema of its own. So the audit was only ever measured from the one reader it
# happened to be correct for.
#
# The trap is the READER, not the SQL. `pg_get_expr` drops the schema from a name
# the reader can resolve, and what a reader can resolve is their `search_path` —
# and `"$user"` is a search_path entry. So the SAME policy deparses
# `cafaye.current_credential_digest()` for `alpha` (no `alpha` schema exists) and
# `current_credential_digest()` for `cafaye` (whose `"$user"` schema IS the
# `cafaye` schema the substrate creates). An audit written against that text
# returns everything to one role and NOTHING to the cluster's own admin role,
# which reads as "this database has no credential path at all" to exactly the
# reader most likely to act on it.
#
# TWO HALVES, and the second is what stops the first from being vacuous:
#
#   A. THE PROPERTY. Three readers — the owner, the cluster's admin role, and the
#      non-owner LOGIN role — must get the SAME answer, and that answer must be
#      non-empty. Agreement alone is satisfiable by a function that returns
#      nothing to everybody, which is a green assertion about an audit that has
#      stopped working.
#   B. THE CONTROL. The two spellings must actually DIFFER on this cluster, or
#      half A is asserting nothing about the mechanism it names. A red here is
#      true rather than a flake: it says Postgres no longer deparses by the
#      reader's visibility, and this suite's control needs rewriting because the
#      reason it exists has changed.
#
# `public.api_keys` is the fixture — assertion 6's credential table, still in
# place — and the printed column is the deparsed policy itself, because the whole
# claim is about that text differing between two sessions that share one policy.
say ""
say "== assertion 8: the credential audit reports the same tables to every role"

audit_deparse="select coalesce(pg_get_expr(polqual, polrelid), '')
                   from pg_policy
                  where polrelid = 'public.api_keys'::regclass
                    and polname = 'api_keys_cafaye_resolve'"
audit_rows="select coalesce(string_agg(table_schema || '.' || table_name || ' -> ' || digest_column,
                                        ', ' order by table_name),
                           '(no rows)')
              from cafaye.credential_tables()"

alpha_deparse="$(psql_in "$ALPHA" "$ALPHA" "$audit_deparse")"
admin_deparse="$(psql_in cafaye "$ALPHA" "$audit_deparse")"
alpha_rows="$(psql_in "$ALPHA" "$ALPHA" "$audit_rows")"
admin_rows="$(psql_in cafaye "$ALPHA" "$audit_rows")"
login_rows="$(psql_in "${ALPHA}_app" "$ALPHA" "$audit_rows")"

say "   as $ALPHA (owner, \"\$user\" schema does not exist):"
say "     policy reads   : $alpha_deparse"
say "     the audit says : $alpha_rows"
say "   as cafaye (cluster admin, \"\$user\" schema IS cafaye):"
say "     policy reads   : $admin_deparse"
say "     the audit says : $admin_rows"
say "   as ${ALPHA}_app (non-owner LOGIN, owns nothing):"
say "     the audit says : $login_rows"

case "$admin_rows" in
  '(no rows)') say ""; say "FAIL: cafaye.credential_tables() returned NOTHING to the cluster's admin role."
    say "      That is the reading this assertion exists to prevent: an admin auditing"
    say "      credentials is told the database has no table resolvable without an"
    say "      account, because \"\$user\" is a search_path entry and the substrate's"
    say "      policies deparse unqualified for this role. The fix is in"
    say "      templates/database/tenancy/substrate.sql — read its"
    say "      credential_tables() comment — not in this file."
    fail "the credential audit answers one role and not another" ;;
esac
[ "$alpha_rows" = "$admin_rows" ] || {
  say ""; say "FAIL: the credential audit disagrees with itself about the same database."
  say "      as $ALPHA: $alpha_rows"
  say "      as cafaye: $admin_rows"
  say "      An audit whose answer depends on WHO ASKS is not an audit; it is a"
  say "      function of the reader's search_path."
  fail "the credential audit depends on the role reading it"
}
[ "$alpha_rows" = "$login_rows" ] || {
  say ""; say "FAIL: the credential audit disagrees with the non-owner LOGIN role."
  say "      as $ALPHA:     $alpha_rows"
  say "      as ${ALPHA}_app: $login_rows"
  fail "the credential audit depends on the role reading it"
}
say "   three roles, one answer — the audit no longer depends on who is reading."
say "   and it is not the empty answer: the admin role's answer is asserted"
say "   NON-EMPTY, because three roles agreeing on nothing proves only that the"
say "   audit has stopped working."

case "$admin_deparse" in
  *cafaye.current_credential_digest*) admin_qualified=1 ;;
  *) admin_qualified=0 ;;
esac
case "$alpha_deparse" in
  *cafaye.current_credential_digest*) alpha_qualified=1 ;;
  *) alpha_qualified=0 ;;
esac
if [ "$alpha_qualified" = "$admin_qualified" ]; then
  say ""
  say "FAIL: the control for assertion 8 did not fire. The substrate's policy deparses"
  say "      the SAME way for both roles, so the reader-dependence this assertion"
  say "      guards against is not happening on this cluster and half A is asserting"
  say "      nothing about it. Either Postgres changed how it qualifies a name a"
  say "      reader can resolve — in which case this control needs rewriting, because"
  say "      its reason has changed — or the fixture is not the policy it claims to be."
  say "      as cafaye: qualified=$admin_qualified   as $ALPHA: qualified=$alpha_qualified"
  fail "the reader-dependence control cannot fire"
fi
say "   control: the trap is LIVE on this cluster — one policy, two renderings, and"
say "     as cafaye: $admin_deparse     (qualified=$admin_qualified)"
say "     as $ALPHA: $alpha_deparse   (qualified=$alpha_qualified)"
say "   and the audit above is identical for both anyway. That is the whole"
say "   assertion: the function no longer reads the text that differs."

# ---------------------------------------------------------------------------
# ASSERTION 8b — THE SAME CLAIM ABOUT THE SECOND AUDIT, and it is repeated rather
# than generalised because `membership_tables()` is a SEPARATE function rather
# than a parameter of `credential_tables()`. That separation is deliberate (one
# query answering both would report a membership table as resolvable by anybody
# who guesses a digest), and a deliberate separation of two functions that
# already worked is exactly the shape a later change quietly un-proves: someone
# reads `pg_get_expr` rather than `pg_depend` in the new one and it is correct
# on every cluster where the admin role happens not to be named after a schema.
#
# `public.account_users` is the fixture, and it is the same table identity's
# `GET /v1/accounts` reads — which is the point: the second audit's answer has to
# hold for the table whose user scope was missing, not for a stand-in.
say ""
say "== assertion 8b: the membership audit reports the same tables to every role"

m_deparse="select coalesce(pg_get_expr(polqual, polrelid), '')
                   from pg_policy
                  where polrelid = 'public.account_users'::regclass
                    and polname = 'account_users_cafaye_members'"
m_rows="select coalesce(string_agg(table_schema || '.' || table_name || ' -> ' || user_column,
                                   ', ' order by table_name),
                          '(no rows)')
         from cafaye.membership_tables()"

m_alpha_deparse="$(psql_in "$ALPHA" "$ALPHA" "$m_deparse")"
m_admin_deparse="$(psql_in cafaye "$ALPHA" "$m_deparse")"
m_alpha_rows="$(psql_in "$ALPHA" "$ALPHA" "$m_rows")"
m_admin_rows="$(psql_in cafaye "$ALPHA" "$m_rows")"
m_login_rows="$(psql_in "${ALPHA}_app" "$ALPHA" "$m_rows")"

say "   as $ALPHA (owner, \"\$user\" schema does not exist):"
say "     policy reads   : $m_alpha_deparse"
say "     the audit says : $m_alpha_rows"
say "   as cafaye (cluster admin, \"\$user\" schema IS cafaye):"
say "     policy reads   : $m_admin_deparse"
say "     the audit says : $m_admin_rows"
say "   as ${ALPHA}_app (non-owner LOGIN, owns nothing):"
say "     the audit says : $m_login_rows"

case "$m_admin_rows" in
  '(no rows)') say ""; say "FAIL: cafaye.membership_tables() returned NOTHING to the cluster's admin role."
    say "      The same reading assertion 8 exists to prevent, reached by a different"
    say "      function. An admin auditing discoverability is told this database has no"
    say "      caller-scoped read path at all, which is false for every service that"
    say "      has adopted protect_membership_table. The fix is in substrate.sql — read"
    say "      membership_tables()'s comment — not in this file."
    fail "the membership audit answers one role and not another" ;;
esac
[ "$m_alpha_rows" = "$m_admin_rows" ] || {
  say ""; say "FAIL: the membership audit disagrees with itself about the same database."
  say "      as $ALPHA: $m_alpha_rows"
  say "      as cafaye: $m_admin_rows"
  fail "the membership audit depends on the role reading it"
}
[ "$m_alpha_rows" = "$m_login_rows" ] || {
  say ""; say "FAIL: the membership audit disagrees with the non-owner LOGIN role."
  say "      as $ALPHA:     $m_alpha_rows"
  say "      as ${ALPHA}_app: $m_login_rows"
  fail "the membership audit depends on the role reading it"
}

# THE CONTROL, again, and it is a separate control rather than a shared one
# because the two policies could stop differing independently: `membership_tables`
# could be rewritten to read text while `credential_tables` kept reading
# dependencies, and every other row here would still pass.
case "$m_admin_deparse" in
  *cafaye.current_user_id*) m_admin_qualified=1 ;;
  *) m_admin_qualified=0 ;;
esac
case "$m_alpha_deparse" in
  *cafaye.current_user_id*) m_alpha_qualified=1 ;;
  *) m_alpha_qualified=0 ;;
esac
if [ "$m_alpha_qualified" = "$m_admin_qualified" ]; then
  say ""
  say "FAIL: the control for assertion 8b did not fire. The membership policy deparses"
  say "      the SAME way for both roles, so half A above is asserting nothing about"
  say "      the mechanism it names — either Postgres changed how it qualifies a name"
  say "      a reader can resolve, or the fixture is not the policy it claims to be."
  say "      as cafaye: qualified=$m_admin_qualified   as $ALPHA: qualified=$m_alpha_qualified"
  fail "the reader-dependence control cannot fire for the membership audit"
fi
say "   three roles, one answer — and not the empty answer."
say "   control: the trap is live here too, on this cluster, for this policy:"
say "     as cafaye: $m_admin_deparse     (qualified=$m_admin_qualified)"
say "     as $ALPHA: $m_alpha_deparse   (qualified=$m_alpha_qualified)"

# ---------------------------------------------------------------------------
say ""
say "PASS: kit's account boundary is enforced by Postgres, and the enforcement is"
say "      proven able to fail."
say "      $total assertions, every one passing, named identically in assertions.txt."
say "      FORCE ROW LEVEL SECURITY removed: $ctl_failures red, all of them owner/ or sweep/."
say "      identity function calls over five rows: $wrapped_calls wrapped, $bare_calls bare."
say "      an adopter's fixture schema present: 0 of 2 of its tables named."
say "      an unprotected table in the substrate's own schema: named, proof red."
say "      the database's own advisor on the substrate's own two tables: 0 ERROR, 0 WARN."
say "      a hand-written permissive policy on api_keys: the exemption released it."
say "      all 10 rules, each fired on a fixture built to trip it, each naming its object."
say "      security_definer_view's 6 negatives: silent, for 6 different reasons."
say "      the credential audit, read as three roles: one answer, and not an empty one."
say "      the membership audit, read as three roles: one answer, and not an empty one."