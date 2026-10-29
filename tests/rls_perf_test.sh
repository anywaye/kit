#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBSTRATE="$ROOT/templates/database/tenancy/substrate.sql"
WORK="${TMPDIR:-/tmp}/kit-rlsperf.$$"
C="kit-rlsperf-pg-$$"

say() { printf '%s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$C" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

[ -r "$SUBSTRATE" ] || fail "templates/database/tenancy/substrate.sql is not readable"

if ! command -v docker >/dev/null 2>&1; then
  say "SKIP tests/rls_perf_test.sh: docker is not installed, so the policy join direction is unmeasured."
  exit 3
fi
if ! docker info >/dev/null 2>&1; then
  say "SKIP tests/rls_perf_test.sh: the docker daemon is not reachable, so the policy join direction is unmeasured."
  exit 3
fi

IMAGE="$(sed -n 's/^ARG POSTGRES_TAG=//p' "$ROOT/templates/compose/postgres/Dockerfile" | head -1)"
[ -n "$IMAGE" ] || fail "templates/compose/postgres/Dockerfile declares no ARG POSTGRES_TAG, so the perf gate has no image to run on"

mkdir -p "$WORK"

say ""
say "== the cluster, and the substrate on it =="
if ! docker run -d --name "$C" -e POSTGRES_PASSWORD=anywaye -e POSTGRES_DB=rlsperf \
      "postgres:$IMAGE" >/dev/null; then
  say "SKIP tests/rls_perf_test.sh: could not start postgres:$IMAGE."
  exit 3
fi

q() { docker exec -e PGPASSWORD=anywaye "$C" psql -U postgres -d rlsperf -tAX -c "$1"; }

ready=0
for _ in $(seq 1 60); do
  if [ "$(q 'select 1' 2>/dev/null || true)" = "1" ]; then ready=1; break; fi
  sleep 1
done
[ "$ready" = "1" ] || fail "postgres:$IMAGE did not accept a query in 60s"

docker cp "$SUBSTRATE" "$C:/tmp/substrate.sql" >/dev/null
if ! docker exec -e PGPASSWORD=anywaye "$C" psql -U postgres -d rlsperf \
     -v ON_ERROR_STOP=1 -q -f /tmp/substrate.sql >"$WORK/substrate.log" 2>&1; then
  say "FAIL: templates/database/tenancy/substrate.sql did not apply. Last lines:"
  tail -20 "$WORK/substrate.log" | sed 's/^/       /'
  fail "the substrate did not install"
fi

cat >"$WORK/fixture.sql" <<'FIXTURE'
-- See the header of this script for what each table is. The comment that matters:
-- `member_of` is keyed (caller_account, subject_account), so the SLOW and FAST
-- policies are the SAME predicate written in two directions, and the row counts
-- they return are required to be equal.
set client_min_messages = warning;
create schema if not exists perf;
set search_path = perf, public;

-- A deterministic uuid per small integer: the fixture is reproducible, so the
-- numbers are comparable between runs and between machines.
create or replace function perf.uid(i int) returns uuid
  language sql immutable as
  $$ select ('00000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid $$;

drop table if exists perf.member_of cascade;
drop table if exists perf.slow_doc cascade;
drop table if exists perf.fast_doc cascade;
drop table if exists perf.plain_doc cascade;
drop table if exists perf.hop_link cascade;
drop table if exists perf.hop_doc cascade;

create table perf.member_of (
  caller_account uuid not null, subject_account uuid not null,
  primary key (caller_account, subject_account));
insert into perf.member_of
  select uid(c), uid(s) from generate_series(1, 50) c, generate_series(1, 200) s
  where s % 50 = c % 50;

create table perf.slow_doc  (id bigint primary key, account_id uuid not null, subject_account_id uuid not null);
create table perf.fast_doc  (id bigint primary key, account_id uuid not null, subject_account_id uuid not null);
create table perf.plain_doc (id bigint primary key, account_id uuid not null, subject_account_id uuid not null);
insert into perf.slow_doc  select i, uid(7), uid(((i % 200) + 1)) from generate_series(1, 200000) i;
insert into perf.fast_doc  select i, uid(7), uid(((i % 200) + 1)) from generate_series(1, 200000) i;
insert into perf.plain_doc select i, uid(7), uid(((i % 200) + 1)) from generate_series(1, 200000) i;

-- THE INDEXES, on both membership directions and on the row columns. The claim
-- under test is the join DIRECTION, so a fixture in which the slow form is slow
-- only because an index is missing would be measuring a different thing.
create index on perf.member_of (subject_account);
create index on perf.member_of (caller_account);
create index on perf.slow_doc  (subject_account_id);
create index on perf.fast_doc  (subject_account_id);
create index on perf.plain_doc (account_id);

-- THE BOUNDARY. `hop_doc` carries no membership column of its own, so the OUTER
-- hop cannot be inverted — there is no row column to IN against. Only the inner
-- hop is, and whether that is enough is the question this case answers.
create table perf.hop_doc  (id bigint primary key, account_id uuid not null);
create table perf.hop_link (doc_id bigint primary key, subject_account_id uuid not null);
insert into perf.hop_doc  select i, uid(7) from generate_series(1, 200000) i;
insert into perf.hop_link select i, uid(((i % 200) + 1)) from generate_series(1, 200000) i;
create index on perf.hop_link (subject_account_id);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'perf_app') then
    create role perf_app login;
  end if;
end $$;
grant usage on schema perf to perf_app;
grant select on all tables in schema perf to perf_app;

-- FORCE, because protect_table sets it and because a timing taken against an
-- exempt owner measures the owner's privilege rather than the policy.
do $$
declare t text;
begin
  foreach t in array array['slow_doc','fast_doc','plain_doc','hop_doc'] loop
    execute format('alter table perf.%I enable row level security', t);
    execute format('alter table perf.%I force row level security', t);
  end loop;
end $$;

create policy perf_sel on perf.slow_doc for select to perf_app
  using ((select anywaye.current_account_id()) in
         (select m.caller_account from perf.member_of m
           where m.subject_account = perf.slow_doc.subject_account_id));

create policy perf_sel on perf.fast_doc for select to perf_app
  using (perf.fast_doc.subject_account_id in
         (select m.subject_account from perf.member_of m
           where m.caller_account = (select anywaye.current_account_id())));

create policy perf_sel on perf.plain_doc for select to perf_app
  using (account_id = (select anywaye.current_account_id()));

create policy perf_sel on perf.hop_doc for select to perf_app
  using (exists (select 1 from perf.hop_link l
                  where l.doc_id = perf.hop_doc.id
                    and l.subject_account_id in
                        (select m.subject_account from perf.member_of m
                          where m.caller_account = (select anywaye.current_account_id()))));

analyze perf.member_of;
analyze perf.slow_doc;
analyze perf.fast_doc;
analyze perf.plain_doc;
analyze perf.hop_doc;
analyze perf.hop_link;
FIXTURE

docker cp "$WORK/fixture.sql" "$C:/tmp/fixture.sql" >/dev/null
if ! docker exec -e PGPASSWORD=anywaye "$C" psql -U postgres -d rlsperf \
     -v ON_ERROR_STOP=1 -q -f /tmp/fixture.sql >"$WORK/fixture.log" 2>&1; then
  say "FAIL: the measurement fixture did not install. Last lines:"
  tail -20 "$WORK/fixture.log" | sed 's/^/       /'
  fail "the fixture did not install"
fi

say ""
say "== the four policy shapes, run as the LOGIN role that owns nothing =="
cat >"$WORK/measure.sql" <<'MEASURE'
set client_min_messages = warning;
begin;
select anywaye.begin_account('00000000-0000-0000-0000-000000000007');
set local role = perf_app;
set local search_path = perf, public;
\pset format unaligned
\pset tuples_only on
\pset fieldsep '|'
select 'rows_slow', count(*) from perf.slow_doc;
select 'rows_fast', count(*) from perf.fast_doc;
select 'rows_plain', count(*) from perf.plain_doc;
select 'rows_hop', count(*) from perf.hop_doc;
\echo 'PLAN|slow'
explain (analyze, costs off) select count(*) from perf.slow_doc;
\echo 'PLAN|fast'
explain (analyze, costs off) select count(*) from perf.fast_doc;
\echo 'PLAN|plain'
explain (analyze, costs off) select count(*) from perf.plain_doc;
\echo 'PLAN|hop'
explain (analyze, costs off) select count(*) from perf.hop_doc;
rollback;
MEASURE
docker cp "$WORK/measure.sql" "$C:/tmp/measure.sql" >/dev/null
docker exec -e PGPASSWORD=anywaye "$C" psql -U postgres -d rlsperf \
  -f /tmp/measure.sql >"$WORK/measure.out" 2>&1 \
  || { say "FAIL: the measurement did not run. Last lines:"; tail -20 "$WORK/measure.out" | sed 's/^/       /'; fail "the measurement did not run"; }

row() { grep "^rows_$1|" "$WORK/measure.out" | head -1 | cut -d'|' -f2; }
  awk -v want="PLAN|$1" '
    $0 == want { inplan = 1; next }
    inplan && /Execution Time:/ { gsub(/[^0-9.]/, "", $3); print $3; exit }
  ' "$WORK/measure.out"
}
  awk -v want="PLAN|$1" '
    $0 == want { inplan = 1; next }
    inplan && /Scan on member_of/ && match($0, /loops=[0-9]+/) {
      print substr($0, RSTART + 6, RLENGTH - 6); exit
    }
  ' "$WORK/measure.out"
}
  awk -v want="PLAN|$1" '
    $0 == want { inplan = 1; next }
    inplan && /member_of/ && /loops=1/ { print 1; exit }
  ' "$WORK/measure.out"
}

SLOW_MS="$(ms slow)"; FAST_MS="$(ms fast)"; KIT_MS="$(ms plain)"; EDGE_MS="$(ms hop)"
ROWS_SLOW="$(row slow)"; ROWS_FAST="$(row fast)"; ROWS_EDGE="$(row hop)"
SLOW_LOOPS="$(loops_on_member_of slow)"
EDGE_ONCE="$(hashed_or_once hop)"

say ""
say "== P1-24: the policy join direction, on postgres:$IMAGE, 200,000 rows, indexed both ways =="
say "   SLOW  correlated membership, per row    ${SLOW_MS} ms   (membership subquery ran ${SLOW_LOOPS} times, one per candidate row)"
say "   FAST  membership once, IN on the column ${FAST_MS} ms   (membership subquery ran once)"
say "   KIT   protect_table, no membership      ${KIT_MS} ms   (no join in either direction)"
say "   EDGE  outer hop not invertible          ${EDGE_MS} ms   (inner hop inverted; membership resolved once)"
say ""

if [ "$ROWS_SLOW" != "$ROWS_FAST" ] || [ "$ROWS_SLOW" != "$ROWS_EDGE" ] || [ -z "$ROWS_SLOW" ]; then
  say "FAIL: the three delegation shapes did not return the same rows"
  say "      (slow=${ROWS_SLOW:-?} fast=${ROWS_FAST:-?} edge=${ROWS_EDGE:-?})."
  say "      They are the same predicate over one membership table, so a disagreement"
  say "      is a fixture bug — and a harness that only compared timings would report"
  say "      a win for a policy that denies everything."
  fail "the shapes disagree"
fi
say "   same answer from every shape: ${ROWS_SLOW} rows. A speed claim measured against a predicate"
say "   that returns nothing is not a speed claim."

awk -v s="$SLOW_MS" -v f="$FAST_MS" 'BEGIN {
  if (s == "" || f == "" || f + 0 <= 0) { print "no timing captured"; exit 1 }
  r = s / f; printf "   %.1fx\n", r;
  if (r < 10) { printf "below the 10x floor\n"; exit 1 }
}' >"$WORK/ratio" 2>&1 || {
  cat "$WORK/ratio" | sed 's/^/       /'
  fail "the slow shape was not measurably slower than the inverted one"
}
RATIO="$(head -1 "$WORK/ratio")"
say "   measured: ${RATIO} slower, against the reference's 450x on its own data."
say "   450x is not a promise about ours, and this number is not a promise about"
say "   yours: the ratio is set by the membership table's SIZE (a per-row probe over"
say "   a 200-row table is cheap per row and ruinous in aggregate) and by the row"
say "   count. What is claimed here is the direction and the mechanism."

[ -n "$SLOW_LOOPS" ] || fail "the slow shape's plan had no member_of scan to read a loop count from"
if [ "$SLOW_LOOPS" -lt 1000 ]; then
  fail "the slow shape's membership subquery ran ${SLOW_LOOPS} times, not once per candidate row — the fixture no longer measures what this gate claims"
fi
say "   mechanism: the slow form's membership lookup ran ${SLOW_LOOPS} times — one per candidate row."
say "   The inverted form's ran once, which is the whole difference."

if [ "$EDGE_ONCE" != "1" ]; then
  say "FAIL: the boundary case did not resolve its membership once."
  say "      Its OUTER hop is correlated and cannot be inverted, so this was expected"
  say "      to hold only because the INNER hop is inverted. If this regresses, the"
  say "      rule's remediation no longer reaches every shape it was written for."
  fail "the boundary case changed shape"
fi
say ""
say "   WHERE THE FAST FORM IS NOT AVAILABLE, measured: a table with no membership"
say "   column of its own (${EDGE_MS} ms). The outer hop cannot be inverted — there is"
say "   no row column to IN against — but inverting the inner hop was enough for"
say "   Postgres to re-associate the EXISTS into a semi-join and resolve the"
say "   membership once. The boundary is therefore per-HOP, not per-policy."
say ""
say "   WHAT THIS DOES NOT CLAIM: that an uncorrelated IN is always faster. It is"
say "   faster when the membership table is a SET the caller filters by itself. A"
say "   membership predicate whose outer hop must touch every candidate row costs"
say "   the same in either direction, and the shape to reach for there is an index"
say "   on the correlated column, not a rewrite."
say ""
say "PASS: the slow/fast decision is measured, not asserted; ${RATIO} on this fixture."
exit 0