#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/tests/substrate_copy_check.py"
TEMPLATE="$ROOT/templates/database/tenancy/substrate.sql"

if [ ! -r "$ROOT/tests/bootstrap.sh" ]; then
  echo "substrate_copy_test.sh: tests/bootstrap.sh is missing — cannot resolve a python" >&2
  exit 1
fi
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

run() {
  EC=0
  OUT="$("$PY" "$CHECK" "$@" 2>&1)" || EC=$?
}

  if [ "$EC" -eq "$1" ]; then
    pass "$2"
  else
    fail "$2 — exit $EC, wanted $1"
    note_out
  fi
}

  if grep -q "$1" <<<"$OUT"; then
    pass "$2"
  else
    fail "$2 — output does not contain: $1"
    note_out
  fi
}

  if grep -q "$1" <<<"$OUT"; then
    fail "$2 — output contains: $1"
    note_out
  else
    pass "$2"
  fi
}

  local got
  got="$(grep -c '^create or replace function anywaye[.]' "$2" || true)"
  if [ "$got" = "$1" ]; then
    pass "$3"
  else
    fail "$3 — fixture holds $got function definitions, wanted $1"
  fi
}


drop_functions() {
  awk -v re="^create or replace function anywaye[.]($1)[(]" '
    $0 ~ re { drop = 1 }
    drop { if ($0 == "$caf$;") drop = 0; next }
    { print }
  ' "$TEMPLATE" >"$2"
}

keep_functions() {
  awk -v re="^create or replace function anywaye[.]($1)[(]" '
    $0 ~ re { keep = 1 }
    keep { print }
    keep && $0 == "$caf$;" { keep = 0 }
  ' "$TEMPLATE" >"$2"
}

R="$WORK/clean"
mkdir -p "$R/migrations"
cp "$TEMPLATE" "$R/migrations/0001_substrate.sql"
expect_count 12 "$R/migrations/0001_substrate.sql" "clean fixture holds the template's 12 functions"
run "$R"
expect_ec 0 "a verbatim embedded copy passes"
expect_out "PASS  every one of kit's functions" "the clean verdict says so"

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

R="$WORK/down-restore"
mkdir -p "$R/migrations"
{
  echo '-- +goose Up'
  cat "$TEMPLATE"
  echo
  echo '-- +goose Down'
  cat <<'SQL'
create or replace function anywaye.credential_tables()
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

R="$WORK/down-readds"
mkdir -p "$R/migrations"
drop_functions 'begin_user' "$WORK/up-without-begin-user.sql"
{
  echo '-- +goose Up'
  cat "$WORK/up-without-begin-user.sql"
  echo
  echo '-- +goose Down'
  cat <<'SQL'
create or replace function anywaye.begin_user(p_user uuid)
returns void
language plpgsql
as $caf$
begin
  perform set_config('anywaye.user_id', p_user::text, true);
end
$caf$;
SQL
} >"$R/migrations/0001_substrate.sql"
run "$R"
expect_ec 1 "a function re-added only in a goose Down section is MISSING"
expect_out "MISSING function: anywaye.begin_user" "and it is named"

R="$WORK/missing"
mkdir -p "$R/migrations"
drop_functions 'begin_user|current_user_id|membership_tables|protect_membership_table' \
  "$R/migrations/0004_account_isolation.sql"
expect_count 8 "$R/migrations/0004_account_isolation.sql" "missing fixture holds 8 of 12 functions"
run "$R"
expect_ec 1 "four absent functions fail the copy"
for fn in begin_user current_user_id membership_tables protect_membership_table; do
  expect_out "MISSING function: anywaye.$fn" "the failure names anywaye.$fn"
done

R="$WORK/edited"
mkdir -p "$R/migrations"
sed 's/p_account::text/p_account::varchar/' "$TEMPLATE" >"$R/migrations/0001_substrate.sql"
run "$R"
expect_ec 1 "a changed SQL token in one body fails"
expect_out "SEMANTIC DRIFT in anywaye.begin_account" "the drift names the function"
expect_out "first difference at character" "and shows where the normalized bodies diverge"

R="$WORK/comment-only"
mkdir -p "$R/migrations"
awk -v note='  -- a locally-true note this service added' \
  -v anchor="raw := current_setting('anywaye.account_id', true);" \
  '{ print; if (index($0, anchor) > 0) print note }' \
  "$TEMPLATE" >"$R/migrations/0001_substrate.sql"
expect_count 12 "$R/migrations/0001_substrate.sql" "comment-only fixture is otherwise complete"
run "$R"
expect_ec 0 "a comment-only difference passes"
expect_out "comment-only difference in anywaye.current_account_id" "and is REPORTED by name"
expect_no_out "SEMANTIC DRIFT" "and is not reported as semantic drift"

R="$WORK/extra"
mkdir -p "$R/migrations"
{
  cat "$TEMPLATE"
  echo
  cat <<'SQL'
create or replace function anywaye.service_helper()
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
expect_out "extra function not in kit's template: anywaye.service_helper" "and is REPORTED by name"

R="$WORK/signature"
mkdir -p "$R/migrations"
sed 's/begin_account(p_account uuid)/begin_account(p_acct uuid)/' "$TEMPLATE" \
  >"$R/migrations/0001_substrate.sql"
run "$R"
expect_ec 1 "a changed signature fails"
expect_out "SEMANTIC DRIFT in anywaye.begin_account" "the signature drift names the function"
expect_out "signature or body" "and says the signature is what moved"

R="$WORK/unreadable-nested"
mkdir -p "$R/migrations"
awk -v t='$caf$;' '{ if (!done && $0 == t) { done = 1; next } print }' \
  "$TEMPLATE" >"$R/migrations/0001_substrate.sql"
run "$R"
expect_ec 1 "a body that swallows the next definition fails"
expect_out "unreadable function block for anywaye.current_account_id" "and names the block whose terminator is gone"

R="$WORK/unreadable-tail"
mkdir -p "$R/migrations"
awk -v t='$caf$;' '{ n[NR] = $0; if ($0 == t) last = NR } END { for (i = 1; i <= NR; i++) if (i != last) print n[i] }' \
  "$TEMPLATE" >"$R/migrations/0001_substrate.sql"
run "$R"
expect_ec 1 "a body with no closing dollar tag fails"
expect_out "unreadable function block for anywaye.unprotected_tables" "and names the block that never closed"

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

R="$WORK/standalone-missing"
mkdir -p "$R/db/tenancy"
drop_functions 'begin_user|current_user_id|membership_tables|protect_membership_table' \
  "$R/db/tenancy/substrate.sql"
run "$R"
expect_ec 1 "a standalone copy missing four functions fails"
expect_out "NOT byte-identical" "and the byte verdict is still reported"
for fn in begin_user current_user_id membership_tables protect_membership_table; do
  expect_out "MISSING function: anywaye.$fn" "the standalone failure names anywaye.$fn"
done

R="$WORK/standalone-edited"
mkdir -p "$R/db/tenancy"
sed 's/p_account::text/p_account::varchar/' "$TEMPLATE" >"$R/db/tenancy/substrate.sql"
run "$R"
expect_ec 1 "a semantic change in a standalone copy fails"
expect_out "SEMANTIC DRIFT in anywaye.begin_account" "and the standalone drift names the function"
expect_out "first difference at character" "and shows the normalized-body window"

R="$WORK/standalone-comment-only"
mkdir -p "$R/db/tenancy"
awk -v note='  -- a locally-true note this service added' \
  -v anchor="raw := current_setting('anywaye.account_id', true);" \
  '{ print; if (index($0, anchor) > 0) print note }' \
  "$TEMPLATE" >"$R/db/tenancy/substrate.sql"
run "$R"
expect_ec 1 "a comment-only standalone difference still fails on bytes"
expect_out "comment-only difference in anywaye.current_account_id" "and the function pass names it comment-only"
expect_no_out "SEMANTIC DRIFT" "and does not call it semantic drift"

R="$WORK/standalone-extra"
mkdir -p "$R/db/tenancy"
{
  cat "$TEMPLATE"
  echo
  cat <<'SQL'
create or replace function anywaye.service_helper()
returns int
language sql
stable
as $caf$
  select 1
$caf$;
SQL
} >"$R/db/tenancy/substrate.sql"
run "$R"
expect_ec 1 "an extra helper in a standalone copy is still a byte failure"
expect_out "extra function not in kit's template: anywaye.service_helper" "and the extra is reported by name"

run "$ROOT"
expect_ec 0 "kit's own template directory is not graded as an adopted copy"
expect_no_out "MISSING function" "and a sibling template produces no missing-function FAILs"
expect_out "not read" "and the files not read are named"
expect_out "no adopted copy" "and kit is reported as having no adopted copy"

R="$WORK/dump"
mkdir -p "$R/db/tenancy" "$R/db"
cp "$TEMPLATE" "$R/db/tenancy/substrate.sql"
cat >"$R/db/structure.sql" <<'SQL'
CREATE FUNCTION anywaye.begin_account(p_other uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
begin
end
$$;
SQL
run "$R"
expect_ec 0 "a generated schema dump is not graded"
expect_no_out "structure.sql" "and the dump is not even mentioned"

R="$WORK/not-adopted"
mkdir -p "$R/migrations"
printf 'create table widgets(id int);\n' >"$R/migrations/0001_widgets.sql"
run "$R"
expect_ec 0 "a repository with no adopted copy passes"
expect_out "no adopted copy" "and says so rather than reporting agreement"

R="$WORK/schema-only"
mkdir -p "$R/migrations"
printf 'create schema if not exists anywaye;\n' >"$R/migrations/0001_schema.sql"
run "$R"
expect_ec 0 "a bare anywaye schema is not an adopted copy"
expect_out "no adopted copy" "and it is reported as no adopted copy"

run "$WORK/does-not-exist"
expect_ec 2 "a missing repository path is exit 2"
expect_out "does-not-exist" "and the error names the path"

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
printf 'PASS substrate_copy_test: %d cases — missing/edited/comment-only/split/redefined/goose-Down (both directions)/unreadable/standalone (byte, named-missing, edited, comment-only, extra)/template-dir/dump-excluded/not-adopted/schema-only/bad-path/fleet\n' "$passes"
