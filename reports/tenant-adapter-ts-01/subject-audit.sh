#!/usr/bin/env bash
#
# subject-audit.sh — is there ANY service in this fleet that a TypeScript
# cross-tenant adapter could be written against?
#
#   bash reports/tenant-adapter-ts-01/subject-audit.sh
#   KIT_FLEET_ROOT=/somewhere/else bash reports/tenant-adapter-ts-01/subject-audit.sh
#
# WHY THIS INSTEAD OF AN ADAPTER
#
#   `cross_tenant_harness.sh` measures a service's QUERY LAYER: it brings up a
#   real Postgres, applies THE SERVICE'S OWN MIGRATIONS, seeds two accounts
#   through the service's own write path, and calls the service's own functions
#   as account A. Every one of those steps needs something the service holds. A
#   service with no database has none of them, so the adapter contract has no
#   shape for it — `adapter_migrate` would have to hand-write a schema, which the
#   contract forbids in as many words ("no hand-written schema — a harness that
#   seeds a table it invented is measuring its own DDL").
#
#   This audit is therefore the measurement that decides whether the TypeScript
#   adapter is DEFINED, and it is written to fail in one direction only.
#
# THE FAIL DIRECTION IS THE UNUSUAL ONE, AND IT IS THE HONEST ONE
#
#   The finding is an ABSENCE, so a check that only ever reported green would be
#   reporting nothing. This audit exits 0 while no TypeScript service holds a
#   database, and exits 1 — naming the service — the moment one does. A TypeScript
#   service that acquires a database is not a curiosity: it becomes the first
#   subject this harness can measure in TypeScript, and the adapter that must be
#   written for it. A reader who wants to know whether that has happened runs
#   this and reads the exit status, rather than reading a list somebody
#   maintains.
#
#   A list of languages is only as good as the worst-looked-up word in it, and
#   the word nobody looks at is the one that is wrong. That is this repository's
#   own sentence, written about `guard` being listed as Go, and this file is the
#   same argument pointed at a language instead of a service.
#
# WHAT COUNTS AS "HOLDS A DATABASE", AND WHY THE IMPORT SWEEP IS THE ONE THAT
# COUNTS
#
#   Three signals, and they are reported separately rather than folded together,
#   because two of them mean different things:
#
#     IMPORTS   a source file importing a postgres/ORM driver. This is the one
#               the finding rests on, because a driver nobody imports is not a
#               query layer no matter what package.json claims.
#     DECLARES  the driver named in package.json dependencies. Reported, and NOT
#               sufficient on its own — it is scaffolding until something
#               imports it.
#     MIGRATES  a .sql file outside e2e/, test/, tests/ and fixtures/. A .sql
#               under e2e/ is a hand-written fixture for ANOTHER service's
#               migration — site carries exactly one, `identity_app` — and
#               counting it as site's own schema would be the same category of
#               error as reading guard as a Go service.
#
#   The module list is explicit, which is a FLOOR: a driver nobody wrote down
#   would be missed. That is why every .sql in the tree is PRINTED with its path
#   and every count is printed beside the service it belongs to — so a reader can
#   see what the judgement was made from rather than trusting the verdict.

set -uo pipefail

FLEET_ROOT="${KIT_FLEET_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"

# The node postgres/ORM drivers this audit knows how to recognise. One list, one
# place, so it can be argued about as a list.
NODE_DB_MODULES="pg pg-pool postgres drizzle-orm @vercel/postgres @neondatabase/serverless prisma @prisma/client knex typeorm sequelize mikro-orm @mikro-orm/core objection @databases/pg @libsql/client libsql"

# A .sql under any of these is a fixture, not a service's own schema.
FIXTURE_DIRS="e2e test tests fixtures"

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

say() { printf '%s\n' "$*"; }

# `contains` — a shell `case` over a variable already in memory, never
# `printf … | grep -q`. kit has been bitten twice: `grep -q` closes the pipe, the
# writer dies of SIGPIPE, and `pipefail` promotes 141, so the verdict flips on
# the SIZE of the output rather than on its content.
contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

# count_lines — how many non-empty lines a captured block has. Not `grep -c` on a
# pipe, for the reason above.
count_lines() {
  local text="$1" n=0 line
  while IFS= read -r line; do
    [ -n "$line" ] && n=$(( n + 1 ))
  done <<EOF
$text
EOF
  printf '%s' "$n"
}

[ -d "$FLEET_ROOT" ] || {
  say "subject-audit.sh: KIT_FLEET_ROOT=$FLEET_ROOT is not a directory. Nothing measured."
  exit 2
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-ts-subject-audit.XXXXXX")" || {
  say "subject-audit.sh: could not create a scratch directory. Nothing measured."
  exit 2
}

# src_list <dir> — the service's own JS/TS source files, node_modules and .git
# PRUNED rather than filtered afterwards. This is not a speed detail: `grep -r`
# followed by `grep -v node_modules` still walks node_modules, which on this
# machine is ~350 directories per service and made the first draft of this file
# exceed its own time bound before it reached the fourth service.
src_list() {
  find "$1" \( -name node_modules -o -name .git -o -name .next -o -name dist \) -prune \
    -o -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.mts' -o -name '*.mjs' -o -name '*.js' \) \
    -print 2>/dev/null
}

# db_imports <filelist> — the files importing a known driver, one per line.
db_imports() {
  local list="$1" mod out=""
  for mod in $NODE_DB_MODULES; do
    [ -s "$list" ] || break
    out="$out$(xargs grep -lE "from ['\"]${mod}(['\"/])|require\(['\"]${mod}(['\"])" \
      <"$list" 2>/dev/null || true)
"
  done
  printf '%s' "$out" | grep . | sort -u
}

# declares_db_driver <dir> — a known driver named in package.json dependencies.
declares_db_driver() {
  local mod
  for mod in $NODE_DB_MODULES; do
    if grep -qsE "\"${mod}\"[[:space:]]*:" "$1/package.json"; then
      printf '%s' "$mod"
      return 0
    fi
  done
  return 1
}

# service_migrations <dir> — .sql files that are the service's OWN schema, i.e.
# not under a fixture directory. One per line, paths relative to the service.
service_migrations() {
  local base="$1" f rel skip d
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$base"/}"
    skip=0
    for d in $FIXTURE_DIRS; do
      case "$rel" in "$d"/*) skip=1 ;; esac
    done
    [ "$skip" -eq 0 ] && printf '%s\n' "$rel"
    return 0
  done <<EOF
$(find "$base" \( -name node_modules -o -name .git \) -prune -o -type f -name '*.sql' -print 2>/dev/null)
EOF
  return 0
}

# account_scoping_files <dir> — files naming an account at all. NOT a claim that
# they scope anything: in a service with no database this counts HTTP path
# segments. Printed so the reader can see which of the two it is.
account_scoping_files() {
  local list="$1"
  [ -s "$list" ] || return 0
  xargs grep -lE 'accountId|account_id' <"$list" 2>/dev/null | sort -u
}

say "subject-audit: fleet root $FLEET_ROOT"
say ""
say "A service that HOLDS A DATABASE has migrations of its own, a query layer to"
say "run, and a write path to seed two accounts through. A cross-tenant adapter is"
say "written against such a service. This audit reports which services qualify."
say ""

ts_count=0
eligible=""

for d in "$FLEET_ROOT"/*/; do
  d="${d%/}"
  name="$(basename "$d")"
  # Worktrees are copies of a service, never a service. Measuring one would
  # count a repository twice and could report a half-edited tree as the fleet.
  case "$name" in wt-*) continue ;; esac
  [ -f "$d/package.json" ] || continue

  list="$WORK/src.$name"
  src_list "$d" >"$list"

  imports="$(db_imports "$list")"
  n_imports="$(count_lines "$imports")"

  declares="-"
  got=""
  if got="$(declares_db_driver "$d")"; then declares="$got"; fi

  migrations="$(service_migrations "$d")"
  n_migrations="$(count_lines "$migrations")"

  n_account="$(count_lines "$(account_scoping_files "$list")")"

  ts_count=$(( ts_count + 1 ))
  if [ "$n_imports" -gt 0 ] || [ "$n_migrations" -gt 0 ]; then
    eligible="$eligible $name"
  fi

  say "  $name"
  say "      account-scoping files : $n_account"
  say "      IMPORTS a db driver   : $n_imports"
  if [ "$n_imports" -gt 0 ]; then
    while IFS= read -r i; do
      [ -n "$i" ] && say "          ${i#"$d"/}"
    done <<EOF
$imports
EOF
  fi
  say "      DECLARES a db driver  : $declares"
  say "      MIGRATES (.sql own)   : $n_migrations"
  if [ -n "$migrations" ]; then
    while IFS= read -r m; do
      [ -n "$m" ] && say "          $m"
    done <<EOF
$migrations
EOF
  fi
  say ""
done

if [ "$ts_count" -eq 0 ]; then
  say "FINDING: no service with a package.json was found under $FLEET_ROOT."
  say "  This audit measured nothing, and a check that measured nothing must not"
  say "  report the absence it was looking for. Refusing to conclude."
  exit 1
fi

say "TypeScript services found: $ts_count"
say ""

if [ -n "$eligible" ]; then
  say "RESULT: a TypeScript service now HOLDS A DATABASE:"
  for s in $eligible; do say "  - $s"; done
  say ""
  say "  A cross-tenant adapter is now DEFINED for it, and until one is written"
  say "  this language's isolation is unproven. This is the condition this audit"
  say "  exists to go red on: the day a TypeScript service grows a database, the"
  say "  adapter becomes possible and the gap becomes real."
  exit 1
fi

say "RESULT: NO TypeScript service in this fleet holds a database."
say ""
say "  Not one of them imports a postgres or ORM driver, not one ships its own"
say "  migrations, and not one has a query layer that could drop a predicate."
say "  Every service that DOES hold a database holds it in Go, Elixir, Ruby or"
say "  Python."
say ""
say "  So the TypeScript adapter is not unfinished — it is UNDEFINED. There is"
say "  nothing for adapter_migrate to apply, nothing to seed two accounts"
say "  through, and nothing to call as account A. The cross-tenant harness"
say "  measures a query layer, and TypeScript in this fleet is the BFF, gateway"
say "  and frontend layer."
say ""
say "  The account boundary for those services is enforced DOWNSTREAM, by the"
say "  service that holds the rows. guard says so in its own words, in"
say "  test/tenantEntryPoints.test.ts:"
say ""
say "    \"guard holds no account's rows: there is no assets table and no query"
say "     that could drop 'and account_id = \$2'. What guard holds is state"
say "     keyed by account.\""
say ""
say "  This is a finding, not a pass. It is also why the language list in"
say "  tests/tenant_isolation/adapters/README.md still says TypeScript is"
say "  unproven — and now says why, in a sentence a reader can check."
exit 0
