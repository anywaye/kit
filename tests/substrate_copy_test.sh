#!/usr/bin/env bash
#
# tests/substrate_copy_test.sh — the substrate drift checker, exercised.
#
#   bash tests/substrate_copy_test.sh
#
# WHY FIXTURES AND NOT THE REAL REPOSITORIES
#
#   `tests/substrate_copy_check.py` compares an adopting service's copy of
#   `templates/database/tenancy/substrate.sql` against the template. The
#   repositories that would prove it work live OUTSIDE this checkout, and kit's
#   gate may not read them: `tests/fleet_check.py` was deleted in commit 8ac8d41
#   ("kit grades kit: remove every check that read another repository",
#   DECISIONS.md MD36) because a clone of kit has no siblings, so every CI run
#   took the fleet-absent branch — a skip wearing a check's clothes.
#
#   What MD36 keeps is a check whose subject is THIS tree, so the cases below
#   build the shapes as fixtures by TRANSFORMING THE REAL TEMPLATE (never a
#   pasted copy of it, which would drift from the thing under test). The
#   deliberate fleet run is a documented command, not a gate row:
#
#       python3 tests/substrate_copy_check.py ../identity ../darkroom
#
#   Measured at the commit that added this file: identity clean (all 12
#   functions across three migrations, the last definition of each winning),
#   darkroom drifting (the four membership/user functions absent), a standalone
#   adopter byte-compared rather than function-compared.
#
# THE CASES, and what each proves
#
#   clean            a verbatim embedded copy passes. The baseline: a checker
#                    that fails this fails everything.
#   split            functions spread across two migrations pass. Measured on
#                    identity, whose four membership functions arrive in a
#                    later file than the other eight.
#   down-restore     a `-- +goose Down` section restoring an OLDER body passes.
#                    Measured on identity's 00017: a scanner taking the last
#                    definition in the whole FILE reports body drift the
#                    database never sees.
#   down-readds      a function deleted from Up but re-added in Down FAILS by
#                    name. The other side of the same trap: Up is what ran.
#   missing          four functions deleted — darkroom's exact drift — FAILS
#                    naming all four.
#   edited           one semantic token changed FAILS by name and location.
#   comment-only     a comment inserted inside a body is REPORTED, not failed.
#                    Measured on darkroom, which rewrote one comment.
#   extra            a service's own helper is REPORTED, not failed.
#   signature        a changed argument name FAILS as signature drift.
#   unreadable       a block with no closing dollar tag FAILS as unreadable —
#                    never silently compared as empty.
#   standalone       a byte-identical standalone copy passes on bytes.
#   standalone-drift one byte added FAILS on bytes: a file that IS the
#                    substrate must BE the substrate.
#   dump-excluded    a generated pg_dump (`db/structure.sql`) is NOT graded:
#                    measured on inbox, whose dump re-spells every function and
#                    would otherwise fail on pg_dump's formatting.
#   not-adopted      a repository with no cafaye schema passes with a note.
#   bad-path         a path that does not exist is exit 2, never a clean repo.
#   fleet            --fleet reads a directory of repositories and the summary
#                    counts them.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/tests/substrate_copy_check.py"
TEMPLATE="$ROOT/templates/database/tenancy/substrate.sql"

if [ ! -r "$ROOT/tests/bootstrap.sh" ]; then
  echo "substrate_copy_test.sh: tests/bootstrap.sh is missing — cannot resolve a python" >&2
  exit 1
fi
# shellcheck source=tests/bootstrap.sh
. "$ROOT/tests/bootstrap.sh"
kit_bootstrap_python "$ROOT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-substrate-copy.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

passes=0
failures=0
OUT=""
EC=0

pass() { printf 'PASS substrate_copy_test: %s\n' "$1"; passes=$((passes + 1)); }
fail() {
  printf 'FAIL substrate_copy_test: %s\n' "$1"
  failures=$((failures + 1))
}
note_out() { printf '%s\n' "$OUT" | sed 's/^/       /'; }

# run <repo...> — sets OUT and EC from the checker. The exit code is read from
# the command itself, never from a pipe: `cmd | tail` reports tail's status.
run() {
  EC=0
  OUT="$("$PY" "$CHECK" "$@" 2>&1)" || EC=$?
}

expect_ec() { # expect_ec <want> <label>
  if [ "$EC" -eq "$1" ]; then
    pass "$2"
  else
    fail "$2 — exit $EC, wanted $1"
    note_out
  fi
}

expect_out() { # expect_out <pattern> <label>
  if grep -q "$1" <<<"$OUT"; then
    pass "$2"
  else
    fail "$2 — output does not contain: $1"
    note_out
  fi
}

expect_no_out() { # expect_no_out <pattern> <label>
  if grep -q "$1" <<<"$OUT"; then
    fail "$2 — output contains: $1"
    note_out
  else
    pass "$2"
  fi
}

expect_count() { # expect_count <want> <file> <label> — anchors each fixture
  local got
  got="$(grep -c '^create or replace function cafaye[.]' "$2" || true)"
  if [ "$got" = "$1" ]; then
    pass "$3"
  else
    fail "$3 — fixture holds $got function definitions, wanted $1"
  fi
}

# The two fixture transformations, over the REAL template. `$1` is an ERE
# alternation of function names; the terminator comparison is `== "$caf$;"` so
# it cannot match a line that merely contains the tag.
#
# A GOTCHA WORTH KNOWING: templates/database/tenancy/substrate.sql does NOT end
# with a trailing newline (it ends in a comment ruler). A fixture built with
# `cat "$TEMPLATE"` and then `echo`/`cat` more onto it GLUES the next line onto
# the last comment — which is how the first version of the goose fixtures
# produced a Document with no markers at all. Every `cat "$TEMPLATE"` below is
# followed by an `echo` for exactly this reason.

# drop_functions <names-regex> <out> — name-mining blocks, comment lines above
# them included (they are part of the copy).
drop_functions() {
  awk -v re="^create or replace function cafaye[.]($1)[(]" '
    $0 ~ re { drop = 1 }
    drop { if ($0 == "$caf$;") drop = 0; next }
    { print }
  ' "$TEMPLATE" >"$2"
}

# keep_functions <names-regex> <out> — the complement, for the split fixture.
keep_functions() {
  awk -v re="^create or replace function cafaye[.]($1)[(]" '
    $0 ~ re { keep = 1 }
    keep { print }
    keep && $0 == "$caf$;" { keep = 0 }
  ' "$TEMPLATE" >"$2"
}

# ---------------------------------------------------------------------------
# clean — a verbatim embedded copy.
R="$WORK/clean"
mkdir -p "$R/migrations"
cp "$TEMPLATE" "$R/migrations/0001_substrate.sql"
expect_count 12 "$R/migrations/0001_substrate.sql" "clean fixture holds the template's 12 functions"
run "$R"
expect_ec 0 "a verbatim embedded copy passes"
expect_out "PASS  every one of kit's functions" "the clean verdict says so"

# ---------------------------------------------------------------------------
# split — the identity shape: functions spread across migrations.
R="$WORK/split"
mkdir -p "$R/migrations"
drop_functions 'membership_tables|protect_membership_table|unprotected_tables' \
  "$R/migrations/0001_substrate.sql"
keep_functions 'membership_tables|protect_membership_table|unprotected_tables' \
  "$R/migrations/0002_membership.sql"
expect_count 9 "$R/migrations/0001_substrate.sql" "split fixture: 9 functions in the early migration"
expect_count 3 "$R/migrations/0002_membership.sql" "split fixture: 3 functions in the later migration"
run "$R"
expect_ec 0 "functions spread across two migrations pass, last definition per name"

# ---------------------------------------------------------------------------
# down-restore — the identity 00017 shape: Up carries the current body and Down
# restores an older one. The whole-file last-wins reading is the false positive
# this proves is not taken.
R="$WORK/down-restore"
mkdir -p "$R/migrations"
{
  echo '-- +goose Up'
  cat "$TEMPLATE"
  echo
  echo '-- +goose Down'
  cat <<'SQL'
create or replace function cafaye.credential_tables()
returns table (table_schema text, table_name text, digest_column text)
language sql
stable
as $caf$
  select 1::text as table_schema, 2::text as table_name, 3::text as digest_column
$caf$;
SQL
} >"$R/migrations/0001_substrate.sql"
expect_count 13 "$R/migrations/0001_substrate.sql" "down-restore fixture holds 13 definitions (12 Up + 1 Down)"
run "$R"
expect_ec 0 "a goose Down section restoring an older body does not fail the copy"
expect_no_out "SEMANTIC DRIFT" "and the Down body is not compared as semantic drift"
expect_no_out "defined more than once" "and the Down definition is not even counted as a redefinition"

# ---------------------------------------------------------------------------
# down-readds — the other direction: Up is missing a function, Down re-adds it.
# A whole-file scanner sees it present; the database does not have it.
R="$WORK/down-readds"
mkdir -p "$R/migrations"
drop_functions 'begin_user' "$WORK/up-without-begin-user.sql"
{
  echo '-- +goose Up'
  cat "$WORK/up-without-begin-user.sql"
  echo
  echo '-- +goose Down'
  cat <<'SQL'
create or replace function cafaye.begin_user(p_user uuid)
returns void
language plpgsql
as $caf$
begin
  perform set_config('cafaye.user_id', p_user::text, true);
end
$caf$;
SQL
} >"$R/migrations/0001_substrate.sql"
run "$R"
expect_ec 1 "a function re-added only in a goose Down section is MISSING"
expect_out "MISSING function: cafaye.begin_user" "and it is named"

# ---------------------------------------------------------------------------
# missing — darkroom's exact drift.
R="$WORK/missing"
mkdir -p "$R/migrations"
drop_functions 'begin_user|current_user_id|membership_tables|protect_membership_table' \
  "$R/migrations/0004_account_isolation.sql"
expect_count 8 "$R/migrations/0004_account_isolation.sql" "missing fixture holds 8 of 12 functions"
run "$R"
expect_ec 1 "four absent functions fail the copy"
for fn in begin_user current_user_id membership_tables protect_membership_table; do
  expect_out "MISSING function: cafaye.$fn" "the failure names cafaye.$fn"
done

# ---------------------------------------------------------------------------
# edited — one semantic token changed inside one body.
R="$WORK/edited"
mkdir -p "$R/migrations"
sed 's/p_account::text/p_account::varchar/' "$TEMPLATE" >"$R/migrations/0001_substrate.sql"
run "$R"
expect_ec 1 "a changed SQL token in one body fails"
expect_out "SEMANTIC DRIFT in cafaye.begin_account" "the drift names the function"
expect_out "first difference at character" "and shows where the normalized bodies diverge"

# ---------------------------------------------------------------------------
# comment-only — a locally-true note added inside a body, the darkroom shape.
R="$WORK/comment-only"
mkdir -p "$R/migrations"
awk -v note='  -- a locally-true note this service added' \
  -v anchor="raw := current_setting('cafaye.account_id', true);" \
  '{ print; if (index($0, anchor) > 0) print note }' \
  "$TEMPLATE" >"$R/migrations/0001_substrate.sql"
expect_count 12 "$R/migrations/0001_substrate.sql" "comment-only fixture is otherwise complete"
run "$R"
expect_ec 0 "a comment-only difference passes"
expect_out "comment-only difference in cafaye.current_account_id" "and is REPORTED by name"
expect_no_out "SEMANTIC DRIFT" "and is not reported as semantic drift"

# ---------------------------------------------------------------------------
# extra — a service's own helper function.
R="$WORK/extra"
mkdir -p "$R/migrations"
{
  cat "$TEMPLATE"
  echo
  cat <<'SQL'
create or replace function cafaye.service_helper()
returns int
language sql
stable
as $caf$
  select 1
$caf$;
SQL
} >"$R/migrations/0001_substrate.sql"
run "$R"
expect_ec 0 "an extra service helper does not fail the copy"
expect_out "extra function not in kit's template: cafaye.service_helper" "and is REPORTED by name"

# ---------------------------------------------------------------------------
# signature — an argument renamed in the head, body untouched otherwise.
R="$WORK/signature"
mkdir -p "$R/migrations"
sed 's/begin_account(p_account uuid)/begin_account(p_acct uuid)/' "$TEMPLATE" \
  >"$R/migrations/0001_substrate.sql"
run "$R"
expect_ec 1 "a changed signature fails"
expect_out "SEMANTIC DRIFT in cafaye.begin_account" "the signature drift names the function"
expect_out "signature or body" "and says the signature is what moved"

# ---------------------------------------------------------------------------
# unreadable — a truncated copy. Both truncation shapes must be NAMED failures,
# never a silent comparison of nothing:
#   first terminator deleted — one body swallows the next definition;
#   last terminator deleted  — the final body never closes.
R="$WORK/unreadable-nested"
mkdir -p "$R/migrations"
awk -v t='$caf$;' '{ if (!done && $0 == t) { done = 1; next } print }' \
  "$TEMPLATE" >"$R/migrations/0001_substrate.sql"
run "$R"
expect_ec 1 "a body that swallows the next definition fails"
expect_out "unreadable function block for cafaye.current_account_id" "and names the block whose terminator is gone"

R="$WORK/unreadable-tail"
mkdir -p "$R/migrations"
awk -v t='$caf$;' '{ n[NR] = $0; if ($0 == t) last = NR } END { for (i = 1; i <= NR; i++) if (i != last) print n[i] }' \
  "$TEMPLATE" >"$R/migrations/0001_substrate.sql"
run "$R"
expect_ec 1 "a body with no closing dollar tag fails"
expect_out "unreadable function block for cafaye.unprotected_tables" "and names the block that never closed"

# ---------------------------------------------------------------------------
# standalone — the inbox shape, clean and drifted.
R="$WORK/standalone"
mkdir -p "$R/db/tenancy"
cp "$TEMPLATE" "$R/db/tenancy/substrate.sql"
run "$R"
expect_ec 0 "a byte-identical standalone copy passes"
expect_out "byte-identical to kit's template" "and the verdict is byte equality"

R="$WORK/standalone-drift"
mkdir -p "$R/db/tenancy"
{ cat "$TEMPLATE"; echo '-- a locally-true note'; } >"$R/db/tenancy/substrate.sql"
run "$R"
expect_ec 1 "a standalone copy with one added line fails"
expect_out "NOT byte-identical" "and the verdict names byte inequality"

# ---------------------------------------------------------------------------
# dump-excluded — a standalone copy plus a generated schema dump. The dump is
# pg_dump's normalized respelling; grading it would fail on formatting.
R="$WORK/dump"
mkdir -p "$R/db/tenancy" "$R/db"
cp "$TEMPLATE" "$R/db/tenancy/substrate.sql"
cat >"$R/db/structure.sql" <<'SQL'
CREATE FUNCTION cafaye.begin_account(p_other uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
begin
end
$$;
SQL
run "$R"
expect_ec 0 "a generated schema dump is not graded"
expect_no_out "structure.sql" "and the dump is not even mentioned"

# ---------------------------------------------------------------------------
# not-adopted — a repository whose SQL has nothing to do with the substrate.
R="$WORK/not-adopted"
mkdir -p "$R/migrations"
printf 'create table widgets(id int);\n' >"$R/migrations/0001_widgets.sql"
run "$R"
expect_ec 0 "a repository with no adopted copy passes"
expect_out "no adopted copy" "and says so rather than reporting agreement"

# ---------------------------------------------------------------------------
# bad-path — a path that does not exist is an INPUT error, not a clean repo.
run "$WORK/does-not-exist"
expect_ec 2 "a missing repository path is exit 2"
expect_out "does-not-exist" "and the error names the path"

# ---------------------------------------------------------------------------
# fleet — the deliberate command's directory mode.
mkdir -p "$WORK/fleet/clean/.git" "$WORK/fleet/drifting/.git"
cp -R "$WORK/clean/migrations" "$WORK/fleet/clean/"
cp -R "$WORK/missing/migrations" "$WORK/fleet/drifting/"
run --fleet "$WORK/fleet"
expect_ec 1 "--fleet fails when one repository drifts"
expect_out "summary: 1 clean, 1 drifting" "and the summary counts both"

printf '\n'
if [ "$failures" -gt 0 ]; then
  printf 'FAIL substrate_copy_test: %d failed, %d passed\n' "$failures" "$passes"
  exit 1
fi
printf 'PASS substrate_copy_test: %d cases — missing/edited/comment-only/split/redefined/goose-Down (both directions)/unreadable/standalone/dump-excluded/not-adopted/bad-path/fleet\n' "$passes"
