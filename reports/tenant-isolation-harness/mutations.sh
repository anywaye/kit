#!/usr/bin/env bash
#
# Six breakages, each one observed going RED, each reverted and green again.
#
#   bash reports/tenant-isolation-harness/mutations.sh
#
# WHY A SEPARATE HARNESS AND NOT A BREAKAGE IN tests/self_test.sh
#
#   self_test.sh breaks a throwaway copy of THIS repository and asserts kit's own
#   gate goes red, which is the right shape for a check that reads kit's tree.
#   These six breakages edit a DIFFERENT repository's query layer and assert an
#   Elixir suite fails against a real database — a claim self_test.sh has never
#   made, on a tree it has never read. Folding it in would mean one phase
#   answering two questions, and the phase that answers the second is a docker
#   tier that has to be excluded from every self-test recipe anyway.
#
#   What it borrows from that suite is everything about the ORDER:
#
#     * THE CONTROL FIRST. Without an unmodified run that is green, six reds
#       prove nothing at all — a probe that refused everything would satisfy all
#       of them. A harness that cannot see correct code is not a harness.
#     * ONE BREAKAGE AT A TIME, applied to a copy and reverted after. A recipe
#       that left breakage 3's edit in place would make breakage 4's red
#       uninterpretable.
#     * THE MUTATION IS ASSERTED BY TEXT BEFORE IT IS BELIEVED. `edit` refuses an
#       anchor that no longer matches, and `git diff` is the belt: a mutation that
#       silently stopped applying produces a recipe that reports "stayed green"
#       and proves nothing. This is kit's own rule and it is why this file exists.
#     * EVERY COUNTER REPORTED SEPARATELY. "6 passed" could be six reds or six
#       controls. The whole packet turns on a reader being able to tell.
#
# WHY SIX, AND WHY THESE SIX
#
#   They are the six ways scoping gets dropped that a reviewer reading the
#   neighbouring line would not catch. 3-6 are the ones that bite, because in
#   every one of them the account predicate is still visible somewhere — in the
#   function two frames above, in the controller's shared fetch, in the `status`
#   clause on the same line.
#
#   1  missing WHERE              the predicate is gone from a query
#   2  missing bind parameter     the predicate is THERE, and the value under it
#                                 is not the caller's account. Grep sees
#                                 `account_id` on the line and stops.
#   3  unscoped list              a list endpoint answers with every account
#   4  unscoped update            writes to a row the caller does not own
#   5  unscoped delete            removes a row the caller does not own
#   6  IDOR on fetch-by-id        reads a row the caller does not own
#
#   Each is a SEPARATE EDIT in a SEPARATE FUNCTION, so a case can never be
#   "caught" by a defect the previous case left behind. That is kit's own rule
#   about a green control two different checks could satisfy, in the form that
#   matters here: the red for 6 (which unscopes the shared fetch) also turns 4
#   and 5 red, and the recipe says so rather than hiding it in a filtered run.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS="$ROOT/tests/tenant_isolation/cross_tenant_harness.sh"
OUT="$ROOT/reports/tenant-isolation-harness"

mkdir -p "$OUT"

# The harness, sourced rather than shelled out to, so one container and one
# compilation serve all thirteen runs and the service COPY is the same tree
# throughout. `KIT_TENANT_SESSION` is exported because the harness derives its
# container name and its host port from it.
export KIT_TENANT_SESSION="${KIT_TENANT_SESSION:-$$}"
# shellcheck source=/dev/null
. "$HARNESS"

controls=0
breakages=0
observed_red=0
failures=0
skipped=0
MUTATED=""

say() { printf '%s\n' "$*"; }

# `contains` — a shell `case` over a variable already in memory, never
# `printf … | grep -q`. kit has been bitten by that twice: `grep -q` closes the
# pipe on its first match, the writer dies of SIGPIPE, and `pipefail` promotes
# 141, so the verdict flips on the SIZE of the output rather than its content.
# Measured at 2000 lines returning 0 and a 239KB report returning 141 with the
# match present.
contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

# restore — ARMED, not installed. `MUTATED` is set only once a mutation has
# actually written something, so a run that never mutated anything never touches
# the tree. This repository's own mutation script carries the same guard and the
# same reason: the EXIT trap fires on the early-exit path too, and a run that
# refused to start because a tree was dirty still checked it out, discarding the
# edit the caller was about to commit.
restore() {
  [ -n "$MUTATED" ] || return 0
  # shellcheck disable=SC2086
  eval "$RESTORE_CMD" >/dev/null 2>&1 || true
  MUTATED=""
}
trap 'restore; tenant_harness_down' EXIT

# edit <file> <from> <to> — a textual mutation that FAILS LOUDLY if the tree has
# moved past it. A stale recipe that "passes" is the whole class of defect here:
# it reports a breakage stayed green when it never broke anything.
edit() {
  if ! "$PYTHON" - "$1" "$2" "$3" <<'PY'
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
body = open(path, encoding="utf-8").read()
if body.count(old) != 1:
    sys.exit(f"anchor appears {body.count(old)} times in {path}, expected exactly 1:\n{old!r}")
open(path, "w", encoding="utf-8").write(body.replace(old, new, 1))
PY
  then
    return 1
  fi
  return 0
}

PYTHON="$(command -v python3 || true)"
[ -n "$PYTHON" ] || {
  say "mutations.sh: python3 not on PATH. Exiting 2: the recipe cannot be applied, and a recipe that did not apply proves nothing."
  exit 2
}

[ -r "$HARNESS" ] || {
  say "mutations.sh: $HARNESS is missing. Exiting 2."
  exit 2
}

# The tree the six edits are applied to. Read out of the harness's own session
# state rather than reconstructed, because reconstructing it is how a mutation
# pass ends up editing a path it is not reporting on.
tenant_harness_up || exit 2
# shellcheck disable=SC1090
. "${TMPDIR:-/tmp}/kit-tenant-iso.$KIT_TENANT_SESSION/session.env"
export KIT_TENANT_WORK KIT_TENANT_PROJECT KIT_TENANT_PGPORT KIT_TENANT_SERVICE KIT_TENANT_ADAPTER_DIR

SVC="$KIT_TENANT_WORK/service"
CTX="$SVC/lib/courier/webhook_endpoints.ex"
CTL="$SVC/lib/courier_web/controllers/webhook_endpoints_controller.ex"
cp "$CTX" "$OUT/BEFORE-webhook_endpoints.ex"
cp "$CTL" "$OUT/BEFORE-webhook_endpoints_controller.ex"
RESTORE_CMD="cp '$OUT/BEFORE-webhook_endpoints.ex' '$CTX' && cp '$OUT/BEFORE-webhook_endpoints_controller.ex' '$CTL'"

say "=== THE CONTROL: an unmodified service that scopes correctly ==="
say ""
out="$(tenant_harness_run 'control')"
code=$?
printf '%s\n' "$out" | tail -20
if [ "$code" -ne 0 ]; then
  say ""
  say "FAIL: the control is RED on the unmodified service. Nothing below is interpretable:"
  say "  a harness that cannot see correct code is not a harness."
  failures=$(( failures + 1 ))
  restore
  tenant_harness_down
  exit 1
fi
if ! contains "$out" "Result: 6 passed"; then
  say ""
  say "FAIL: the control did not report 6 tests and 0 failures. It reported:"
  printf '%s\n' "$out" | tail -5 | sed 's/^/  /'
  say "  A run that measured nothing must not be reported as a control."
  failures=$(( failures + 1 ))
  restore
  tenant_harness_down
  exit 1
fi
controls=$(( controls + 1 ))
say ""
say "PASS control 1/1: 6 negative assertions against a real Postgres, 0 failures."

# breakage <n> <label> <needle> <file> <from> <to>
#
# Four assertions per case, and the fourth is the one that makes the first three
# mean something:
#
#   1. the mutation IS IN THE FILE   (text, not exit status)
#   2. the NAMED test went RED       (the test written for this defect, not
#                                     "something went red")
#   3. the literal failure line is on the record
#   4. REVERTED, AND GREEN AGAIN     (the cost of the deletion, measured)
breakage() {
  local n="$1" label="$2" needle="$3" file="$4" from="$5" to="$6"
  local out code line

  restore
  say ""
  say "=== BREAKAGE $n: $label ==="

  if ! edit "$file" "$from" "$to"; then
    printf 'NO ANCHOR  breakage %s: %s\n' "$n" "$label"
    failures=$(( failures + 1 ))
    return
  fi
  MUTATED="planted"

  # (1) BY TEXT. `grep -q` would exit on the first match; `grep -c` prints the
  # count and can be read.
  local after
  after="$(grep -c -F -- "$to" "$file" 2>/dev/null)" || after=0
  if [ "$after" -lt 1 ]; then
    printf 'NO MUTATION breakage %s: the edit reported success and left the file byte-identical\n' "$n"
    failures=$(( failures + 1 ))
    restore
    return
  fi

  # (2) THE NAMED ASSERTION FAILED.
  out="$(tenant_harness_run "$needle")"
  code=$?
  if [ "$code" -eq 0 ]; then
    printf 'NOT BITTEN breakage %s: %s — the suite stayed GREEN\n' "$n" "$label"
    printf '%s\n' "$out" | tail -6 | sed 's/^/  /'
    failures=$(( failures + 1 ))
    restore
    return
  fi
  if ! contains "$out" "$needle"; then
    printf 'WRONG FAILURE breakage %s: %s — it went red as something else and never said `%s`\n' \
      "$n" "$label" "$needle"
    printf '%s\n' "$out" | tail -8 | sed 's/^/  /'
    failures=$(( failures + 1 ))
    restore
    return
  fi

  # (3) THE LITERAL LINE, kept rather than paraphrased. "the harness covers
  # unscoped lists" is a claim about the recipe; this is a receipt.
  # No bare `(` inside the quoted needle: bash 3.2, which this fleet's macOS
  # runners ship, mis-parses an unbalanced `(` inside a double-quoted string
  # inside a command substitution and reports it as a missing `"` two lines
  # further on. The needles therefore carry a TRAILING SPACE, which is also what
  # keeps `cross_tenant_list ` from matching `cross_tenant_list_own_row_visible`.
  line="$(printf '%s\n' "$out" | grep -F -m1 "$needle" || true)"
  printf 'BITTEN     breakage %s: %s\n' "$n" "$label"
  printf '  %s\n' "${line:-needle $needle red, line not recoverable from the output}"
  breakages=$(( breakages + 1 ))
  observed_red=$(( observed_red + 1 ))

  # (4) REVERTED, AND GREEN AGAIN.
  restore
  out="$(tenant_harness_run "$needle")"
  code=$?
  if [ "$code" -ne 0 ]; then
    printf 'NOT REVERTED breakage %s: green before, red planted, still red after the revert\n' "$n"
    printf '%s\n' "$out" | tail -8 | sed 's/^/  /'
    failures=$(( failures + 1 ))
    return
  fi
  printf '  reverted: green again\n'
}

# --------------------------------------------------------------------------
# 1. missing WHERE. `enabled/1` keeps `endpoint.status == :enabled` and loses the
#    account predicate, so the line still reads like a scoped query — the whole
#    difficulty, in one clause.
# --------------------------------------------------------------------------
breakage 1 "the delivery fan-out query loses its account predicate" \
  'test cross_tenant_enabled_list ' "$CTX" \
  '|> where([endpoint], endpoint.account_id == ^account_id and endpoint.status == :enabled)' \
  '|> where([endpoint], endpoint.status == :enabled)'

# --------------------------------------------------------------------------
# 2. missing bind parameter. `list/1` keeps the predicate and pins a constant
#    instead of the caller's account. This is the one a grep cannot see, and it is
#    why the probe has an ALLOWANCE test of its own: a broken bind reads as "zero
#    rows", which every denial-only assertion is perfectly happy with.
# --------------------------------------------------------------------------
breakage 2 "the list query pins a constant instead of the caller's account" \
  'test cross_tenant_list_own_row_visible ' "$CTX" \
  '  def list(account_id) do
    WebhookEndpoint' \
  '  def list(account_id) do
    account_id = "00000000-0000-0000-0000-000000000000"
    WebhookEndpoint'

# --------------------------------------------------------------------------
# 3. unscoped list. The `where` is gone from `page/3`, which is the query the HTTP
#    index ACTUALLY runs — an earlier draft broke `list/1` and the recipe caught
#    it, because the endpoint's own assertion stayed green: courier's controller
#    paginates rather than calling `list/1`, so unscoping `list/1` proves nothing
#    about the list endpoint. A breakage aimed at a function no entry point calls
#    is a breakage of a function, not of a surface.
# --------------------------------------------------------------------------
breakage 3 "the LIST ENDPOINT's query returns every account's rows" \
  'test cross_tenant_list ' "$CTX" \
  '        WebhookEndpoint
        |> where([endpoint], endpoint.account_id == ^account_id)
        |> order_by([endpoint], asc: endpoint.inserted_at, asc: endpoint.id)
        |> limit(^Kernel.+(limit, 1))' \
  '        WebhookEndpoint
        |> order_by([endpoint], asc: endpoint.inserted_at, asc: endpoint.id)
        |> limit(^Kernel.+(limit, 1))'

# --------------------------------------------------------------------------
# 4. unscoped update. The controller's shared `fetch/2` is correct; what goes
#    wrong is that `update/2` stops USING it and loads by id. The scoping is four
#    frames from the write and no per-query lint looks there.
# --------------------------------------------------------------------------
breakage 4 "the update action resolves its row by id alone" \
  'test cross_tenant_update ' "$CTL" \
  'def update(conn, %{"id" => id} = params) do
    with {:ok, endpoint} <- fetch(conn, id) do' \
  'def update(conn, %{"id" => id} = params) do
    with {:ok, endpoint} <- {:ok, Courier.Repo.get(Courier.WebhookEndpoint, Ecto.UUID.cast!(id))} do'

# --------------------------------------------------------------------------
# 5. unscoped delete. Same shape as 4 and the same blindness, on the one action
#    where the damage is irreversible.
# --------------------------------------------------------------------------
breakage 5 "the delete action resolves its row by id alone" \
  'test cross_tenant_delete ' "$CTL" \
  'def delete(conn, %{"id" => id}) do
    with {:ok, endpoint} <- fetch(conn, id) do' \
  'def delete(conn, %{"id" => id}) do
    with {:ok, endpoint} <- {:ok, Courier.Repo.get(Courier.WebhookEndpoint, Ecto.UUID.cast!(id))} do'

# --------------------------------------------------------------------------
# 6. IDOR on fetch-by-id. `Repo.get_by(WebhookEndpoint, id: id, account_id:
#    account_id)` becomes a plain `Repo.get`, and one word of the query is the
#    entire authorization boundary.
# --------------------------------------------------------------------------
breakage 6 "the fetch-by-id query drops its account predicate" \
  'test cross_tenant_fetch_by_id ' "$CTX" \
  '{:ok, id} -> Repo.get_by(WebhookEndpoint, id: id, account_id: account_id)' \
  '{:ok, id} -> Repo.get(WebhookEndpoint, id)'

say ""
say "=== BASELINE: the tree, reverted, one more time ==="
restore
out="$(tenant_harness_run 'baseline')"
printf '%s\n' "$out" | tail -6
cp "$CTX" "$OUT/AFTER-webhook_endpoints.ex"
cp "$CTL" "$OUT/AFTER-webhook_endpoints_controller.ex"

say ""
if [ "$failures" -ne 0 ]; then
  say "FAIL: mutations.sh — $failures of $(( controls + breakages + failures )) cases failed."
  exit 1
fi
# The two "nothing ran" guards. A self-test whose recipes have gone stale reports
# zero breakages and exits 0, which is the exact failure this repository's rules
# forbid: a checker that has stopped checking, reported as one that passed.
if [ "$breakages" -eq 0 ] || [ "$controls" -eq 0 ]; then
  say "FAIL: mutations.sh — $breakages breakages and $controls controls ran. A run with a zero in it proved nothing, not that nothing was wrong."
  exit 1
fi
# The two counts, separately, always. "6 passed" could be six reds or six
# controls; the whole packet turns on a reader being able to tell which.
say "PASS: mutations.sh — $controls control(s) green, $breakages breakages planted and all $observed_red observed RED with the assertion they were written for named, each reverted and green again. $skipped skipped."