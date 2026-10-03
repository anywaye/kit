#!/usr/bin/env bash
#
# Prove that `cafaye.protect_table` makes a table INSERTABLE by the login role,
# and that the grant it adds is no wider than that.
#
#   bash reports/substrate-sequence-grant/mutations.sh
#
# THE DEFECT THIS EXISTS FOR. `protect_table` granted the login role DML on the
# table and nothing on the sequences behind it. A table with a `bigserial` or a
# `generated … as identity` column reads its sequence BEFORE it writes the row,
# and a sequence is a separate object with separate grants, so every protected
# table with an id column was UNINSERTABLE by the very role the substrate exists
# to hand DML to:
#
#     ERROR:  permission denied for sequence notification_preferences_id_seq
#
# Latent until a service connects as its login role instead of running its
# migrations as the owner, which is the adoption step. `courier` carries a copy of
# this substrate and hit it there; the fix belongs in kit because the copy is
# what a fix in kit is FOR.
#
# FIVE CASES, AND EACH ONE HAS A JOB NONE OF THE OTHERS CAN DO.
#
#   1. `bigserial`      the shape the defect was reported on, and the one that
#                       really does lock a table out. MEASURED RED.
#   2. `identity`       the same column spelled the other way. MEASURED, AND THE
#                       MEASUREMENT CORRECTS THE PREMISE: on PostgreSQL 17.11 and
#                       18.6 an `identity` column does NOT need a sequence grant.
#                       An explicit `nextval('…_id_seq')` as the ungranted role IS
#                       refused; the identity column's INSERT is not — so the
#                       fetch happens on a path with no ACL check. Case 2
#                       therefore measures the GRANT, not a lockout, and its
#                       verdict line says which of the two it is reporting.
#   3. BREAKAGE         revoke the grant `protect_table` just made, require the
#                       denial back, re-protect, require the row back. Without
#                       this a reader cannot tell the fix from a coincidence.
#   4. NEGATIVE CONTROL a protected table with NO sequence must gain no grant and
#                       must not raise. Most tables in any service have no serial
#                       column, so the loop has to be quiet on an empty result
#                       set the way `protect_table` is quiet about a table with
#                       no tenancy column.
#   5. NARROWNESS       `USAGE` is the minimum that makes an INSERT work and the
#                       login role must not be able to `SELECT` either sequence,
#                       `setval` either of them, or reach the one belonging to a
#                       table it was never granted DML on. A blanket `grant all on
#                       all sequences in schema public` also makes the insert
#                       work.
#
# WHY THE LOOP STILL GRANTS THE IDENTITY SEQUENCE, GIVEN CASE 2 IS NOT A LOCKOUT.
# Because the grant is `USAGE` on the table's OWN sequence and nothing wider —
# case 5 measures that on both sequences — and because a substrate whose correct
# behaviour rests on an undocumented executor detail is one minor version away
# from the same lockout. A column declared `DEFAULT nextval('…')` by hand rather
# than by `serial` is the `bigserial` case again, and a rule that reads the
# catalog does not have to be re-derived every time a service picks a new
# spelling of the same edge.
#
# THE CONTROL IS ONLY A CONTROL IF IT HAS BEEN SEEN RED, so three mutations run
# at the end and each must change the thing it names:
#
#   M1 blanket        -> the negative control goes red on the unrelated sequence
#   M2 raise-on-null  -> the negative control goes red on "must not raise"
#   M3 deptype = 'a'  -> the granted SET loses the identity sequence. Not a
#                        lockout — see case 2 — but it is the loop failing to
#                        cover the second spelling of one catalog edge, which is
#                        the thing worth proving.
#
# `set -u` and `pipefail` are on and `set -e` is deliberately NOT: the thing being
# measured here is a non-zero exit from psql, and a harness that aborts on the
# first denial has not measured the denial. Every command is bounded by `timeout`
# and every command whose status matters says so explicitly.
#
# NOTHING IS COPIED OUT OF THE TREE. The substrate is read from
# `templates/database/tenancy/substrate.sql` and `docker cp`'d into the container
# on every phase, so a mutation is measured rather than remembered. Teardown
# restores from a byte-identical copy taken at start and checks the sha256 — NOT
# from `git checkout`, because the fix under test is uncommitted and a teardown
# that ran `git checkout` would delete it. Same "assert the edit landed, by text"
# rule `reports/wrapper-tier-scope/mutations.sh` follows.
#
# NO HEREDOC EVER LIVES INSIDE `$( … )`, and that is not a style preference.
# macOS bash is 3.2, and 3.2 mis-lexes a quoted heredoc inside a command
# substitution when the body carries an ODD number of apostrophes: one `it's` in a
# comment is enough, and the failure is reported as `unexpected EOF while looking
# for matching "'" at a line near the end of the file rather than at the line that
# is wrong. Measured on `/bin/bash` 3.2.57 — the identical heredoc at top level
# parses, the same heredoc inside `$( … )` does not, and adding a second apostrophe
# makes it parse again. A hundred lines of harness should not turn on the parity of
# a comment's punctuation, so every multi-line payload here is written to a file
# with a top-level heredoc and read back with a plain `cat`, and the SQL lives in
# `fixture.sql` / `literal-inserts.sql` where it can be `psql -f`'d at all.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

SUBSTRATE="$ROOT/templates/database/tenancy/substrate.sql"
HERE="$ROOT/reports/substrate-sequence-grant"
LITERAL="$HERE/literal-inserts.sql"
FIXTURE_SQL="$HERE/fixture.sql"

# PG18 is what the defect was reported against and it is where the identity
# spelling is measured. Override for another floor; the harness prints the
# version it actually ran on, so a number is never read against the wrong server.
IMAGE="${KIT_SEQGRANT_IMAGE:-postgres:18}"
CONTAINER="kit-seqgrant-$$"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-seqgrant.XXXXXX")"

cases=0
passes=0
failures=0
na=0
mutated=0

say() { printf '%s\n' "$*"; }
ok() { printf 'PASS  %-14s %s\n' "$1" "$2"; }
no() { printf 'FAIL  %-14s %s\n' "$1" "$2"; }
skipcase() { printf 'N/A   %-14s %s\n' "$1" "$2"; }

shasum_of() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

cleanup() {
  restore
  if [ -n "${CONTAINER:-}" ]; then
    timeout 60 docker rm -f -v "$CONTAINER" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# --------------------------------------------------------------------------
# mutate <label> <from> <to>
#
# The edit REFUSES an anchor that is not there exactly once. A mutation that did
# not apply would produce a harness reporting CLEAN over an unchanged tree, which
# is a passing recipe that proves nothing. The count is the assertion; there is no
# second one to drift out of step with it.
# --------------------------------------------------------------------------
mutate() {
  local label="$1" from="$2" to="$3" rc=0
  timeout 60 python3 - "$SUBSTRATE" "$from" "$to" <<'PY' || rc=$?
import sys
path, frm, to = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    body = fh.read()
n = body.count(frm)
if n != 1:
    sys.stderr.write("anchor appears %d times in %s, expected exactly 1\n" % (n, path))
    sys.exit(1)
out = body.replace(frm, to)
if out == body or to not in out:
    sys.stderr.write("the edit did not change the file, or did not introduce its own replacement\n")
    sys.exit(1)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(out)
PY
  if [ "$rc" -ne 0 ]; then
    say "STOP: $label did not apply, so nothing after it was measured."
    exit 1
  fi
  mutated=1
}

# ARMED, NOT INSTALLED: `mutated` is set only once `mutate` has written
# something, so a run that never mutated anything never touches the tree.
restore() {
  [ "$mutated" -eq 1 ] || return 0
  [ -f "$WORK/substrate.pristine" ] || return 0
  cp "$WORK/substrate.pristine" "$SUBSTRATE" || return 0
  if [ "$(shasum_of "$SUBSTRATE")" != "$(shasum_of "$WORK/substrate.pristine")" ]; then
    say "STOP: the substrate was not restored byte-identically. Leaving it dirty on purpose."
    return 1
  fi
  mutated=0
  return 0
}

# --------------------------------------------------------------------------
# psql. `-c` and `-f` only, never a heredoc on stdin: `docker exec` without `-i`
# drops stdin, and a fixture that silently applies nothing is worse than one that
# fails.
#
# `PGOPTIONS=client_min_messages=warning` because the substrate is idempotent by
# design and says so with a NOTICE on every policy it drops, and four lines of
# `policy … does not exist, skipping` between two verdicts is a reader's eye
# spent for nothing. Errors are unaffected — the denials this file exists to
# photograph are ERRORS, not notices.
# --------------------------------------------------------------------------
q() { # q <role> <db> <sql>  — returns psql's exit status
  timeout 120 docker exec -e PGPASSWORD=cafaye -e "PGOPTIONS=-c client_min_messages=warning" \
    "$CONTAINER" psql -U "$1" -d "$2" -tAX -v ON_ERROR_STOP=1 -c "$3" 2>&1
}
qf() { # qf <role> <db> <file in container>
  timeout 180 docker exec -e PGPASSWORD=cafaye -e "PGOPTIONS=-c client_min_messages=warning" \
    "$CONTAINER" psql -U "$1" -d "$2" -tAX -v ON_ERROR_STOP=1 -f "$3" 2>&1
}
# A command whose failure is the measurement. Prints, always exits 0.
q_soft() { q "$1" "$2" "$3" || true; }

# --------------------------------------------------------------------------
# fixture and substrate, in per-phase databases.
#
# One database per phase rather than one shared: case 3 revokes a grant and case 4
# snapshots one, so a phase sharing a database with the next is asserting against
# inherited state — and an inherited grant is exactly what a "must not gain a
# grant" assertion cannot tell apart from one it just made.
# --------------------------------------------------------------------------
build_phase() {
  local phase="$1" out
  q_soft postgres postgres "drop database if exists probe_$phase with (force)" >/dev/null
  q_soft postgres postgres "create database probe_$phase owner probe" >/dev/null
  timeout 60 docker cp "$SUBSTRATE" "$CONTAINER:/tmp/substrate.sql" >/dev/null \
    || { say "STOP: could not copy the substrate into $CONTAINER."; exit 1; }
  timeout 60 docker cp "$FIXTURE_SQL" "$CONTAINER:/tmp/fixture.sql" >/dev/null \
    || { say "STOP: could not copy fixture.sql into $CONTAINER."; exit 1; }
  out="$(qf probe "probe_$phase" /tmp/substrate.sql)"
  case "$out" in *ERROR*) say "STOP: the substrate did not apply in probe_$phase:"; say "$out"; exit 1 ;; esac
  out="$(qf probe "probe_$phase" /tmp/fixture.sql)"
  case "$out" in *ERROR*) say "STOP: fixture.sql did not build in probe_$phase:"; say "$out"; exit 1 ;; esac
  return 0
}

protect() { q_soft probe "$1" "select cafaye.protect_table('$2', 'probe_app')"; }

# the sequences probe_app holds USAGE on, one per line, sorted
seq_grants() {
  q postgres "$1" "select n.nspname||'.'||s.relname
                     from pg_class s
                     join pg_namespace n on n.oid = s.relnamespace
                     join pg_roles r on r.rolname = 'probe_app'
                    where s.relkind = 'S'
                      and has_sequence_privilege(r.oid, s.oid, 'USAGE')
                    order by 1"
}

has_priv() { q postgres "$1" "select has_sequence_privilege('probe_app', '$2'::regclass, '$3')"; }

flat() { printf '%s' "$1" | tr '\n' ' '; }
mentions() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# row is "ok|id|sqlstate|message"
row_ok() { case "$1" in t\|*) return 0 ;; esac; return 1; }
row_id() { printf '%s' "$1" | cut -d'|' -f2; }
row_state() { printf '%s' "$1" | cut -d'|' -f3; }
row_msg() { printf '%s' "$1" | cut -d'|' -f4-; }

# --------------------------------------------------------------------------
# start. Everything that can stop the run stops it LOUDLY, because a harness that
# measured nothing and reported four clean cases is the defect this file was
# written next to.
# --------------------------------------------------------------------------
for f in "$SUBSTRATE" "$LITERAL" "$FIXTURE_SQL"; do
  [ -r "$f" ] || { say "STOP: $(basename "$f") is not readable, so there is nothing to prove."; exit 1; }
done
command -v docker >/dev/null 2>&1 || { say "SKIP reports/substrate-sequence-grant/mutations.sh: docker is not installed."; exit 3; }
docker info >/dev/null 2>&1 || { say "SKIP reports/substrate-sequence-grant/mutations.sh: the docker daemon is not reachable."; exit 3; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  say "SKIP reports/substrate-sequence-grant/mutations.sh: image $IMAGE is not present locally."
  say "       This harness measures, it does not install: pull it yourself rather than let a proof"
  say "       reach the network."
  exit 3
}

cp "$SUBSTRATE" "$WORK/substrate.pristine" || exit 1
PRISTINE_SHA="$(shasum_of "$SUBSTRATE")"

say "substrate: $SUBSTRATE"
say "sha256:    $PRISTINE_SHA"
say "container: $CONTAINER"

timeout 180 docker run -d --name "$CONTAINER" \
  -e POSTGRES_PASSWORD=cafaye -e POSTGRES_DB=postgres "$IMAGE" >/dev/null \
  || { say "STOP: could not start $CONTAINER."; exit 1; }

ready=0
for _ in $(seq 1 90); do
  if timeout 10 docker exec "$CONTAINER" pg_isready -U postgres -q 2>/dev/null; then ready=1; break; fi
  sleep 1
done
[ "$ready" -eq 1 ] || { say "STOP: $CONTAINER never became ready."; docker logs "$CONTAINER" 2>&1 | tail -20; exit 1; }
say "server:    $(q postgres postgres 'select version()')"

# Two roles, cluster-wide. `probe` owns the tables and runs the migrations;
# `probe_app` is the login that owns nothing, which is the topology the substrate
# exists to create.
q_soft postgres postgres "create role probe login password 'cafaye' nosuperuser" >/dev/null
q_soft postgres postgres "create role probe_app login password 'cafaye' nosuperuser" >/dev/null

say ""
say "== the five probes, against the substrate as it stands =="
say ""

# --------------------------------------------------------------------------
# CASE 1 — bigserial
# --------------------------------------------------------------------------
cases=$((cases + 1))
build_phase base
protect probe_base t_serial
row="$(q probe_app probe_base "select * from probe_insert('t_serial')")"
if row_ok "$row"; then
  passes=$((passes + 1)); ok bigserial "insert landed, returning id = $(row_id "$row")"
else
  failures=$((failures + 1)); no bigserial "SQLSTATE $(row_state "$row") / $(row_msg "$row")"
fi

# --------------------------------------------------------------------------
# CASE 2 — generated always as identity.
#
# TWO HALVES, and only one of them is a lockout. The INSERT half is measured on
# both spellings because that is the question; the GRANT half is asserted because
# the loop is supposed to cover the identity spelling of the same catalog edge,
# and on PostgreSQL 17.11 and 18.6 the INSERT half is green either way. Reporting
# one number for this would hide which half it is.
# --------------------------------------------------------------------------
cases=$((cases + 1))
protect probe_base t_identity
row="$(q probe_app probe_base "select * from probe_insert('t_identity')")"
ident_usage="$(has_priv probe_base public.t_identity_id_seq USAGE)"
if ! row_ok "$row"; then
  failures=$((failures + 1))
  no identity "LOCKOUT — SQLSTATE $(row_state "$row") / $(row_msg "$row")"
elif [ "$ident_usage" != "t" ]; then
  failures=$((failures + 1))
  no identity "insert landed (id $(row_id "$row")) but protect_table granted NO USAGE on t_identity_id_seq — the identity edge of the catalog is uncovered"
else
  passes=$((passes + 1))
  ok identity "insert landed (id $(row_id "$row")); t_identity_id_seq granted USAGE"
fi

# --------------------------------------------------------------------------
# CASE 3 — BREAKAGE. An N/A here is NOT a pass: pre-fix there is no grant to
# revoke, and a case that cannot run has measured nothing.
# --------------------------------------------------------------------------
cases=$((cases + 1))
if mentions "$(seq_grants probe_base)" 't_serial_id_seq'; then
  q_soft probe probe_base 'revoke usage on sequence public.t_serial_id_seq from probe_app' >/dev/null
  back="$(q probe_app probe_base "select * from probe_insert('t_serial')")"
  protect probe_base t_serial
  again="$(q probe_app probe_base "select * from probe_insert('t_serial')")"
  if ! mentions "$(row_msg "$back")" 'permission denied for sequence'; then
    failures=$((failures + 1))
    no breakage "after revoke: SQLSTATE $(row_state "$back") / $(row_msg "$back") — a different failure"
  elif ! row_ok "$again"; then
    failures=$((failures + 1))
    no breakage "the denial came back, but re-protecting did not restore it: SQLSTATE $(row_state "$again") / $(row_msg "$again")"
  else
    passes=$((passes + 1))
    ok breakage "revoked -> $(row_msg "$back"); re-protected -> id $(row_id "$again")"
  fi
else
  skipcase breakage "protect_table granted probe_app no USAGE on t_serial_id_seq, so there is nothing to revoke"
  na=$((na + 1))
fi

# --------------------------------------------------------------------------
# CASE 4 — NEGATIVE CONTROL. Two halves that fail differently:
#   (a) the SET of sequences probe_app holds USAGE on is unchanged by
#       protect_table('t_plain'), and the call does not raise
#   (b) probe_app still holds nothing on t_unrelated_id_seq — the sequence behind
#       a table it was never granted DML on. This is the half the blanket form
#       fails, and it is the reason the table is in the fixture at all.
# --------------------------------------------------------------------------
cases=$((cases + 1))
before="$(seq_grants probe_base)"
out="$(protect probe_base t_plain)"
after="$(seq_grants probe_base)"
unrel="$(has_priv probe_base public.t_unrelated_id_seq USAGE)"
row="$(q probe_app probe_base "select * from probe_insert('t_plain', 1)")"
if mentions "$out" 'ERROR'; then
  failures=$((failures + 1)); no no-sequence "protect_table raised on a table with no sequence: $out"
elif [ "$before" != "$after" ]; then
  failures=$((failures + 1))
  no no-sequence "protect_table('t_plain') changed the granted set: [$(flat "$before")] -> [$(flat "$after")]"
elif [ "$unrel" != "f" ]; then
  failures=$((failures + 1))
  no no-sequence "probe_app holds USAGE on public.t_unrelated_id_seq — a table it was never granted DML on"
elif ! row_ok "$row"; then
  failures=$((failures + 1))
  no no-sequence "insert into the no-sequence table failed: SQLSTATE $(row_state "$row") / $(row_msg "$row")"
else
  passes=$((passes + 1))
  ok no-sequence "no grant gained (still [$(flat "$after")]), unrelated sequence untouched, insert landed"
fi

# --------------------------------------------------------------------------
# CASE 5 — NARROWNESS. `USAGE` is the minimum that makes an INSERT work and the
# login role must not be able to read either sequence or move either of them.
# This is the case that says the grant is narrow rather than the comment claiming
# it, and it covers BOTH sequences, because "the narrow grant" is a claim about
# every grant the loop made and not only about the one the reported bug needed.
# --------------------------------------------------------------------------
cases=$((cases + 1))
wide=''
for seq in public.t_serial_id_seq public.t_identity_id_seq; do
  sel="$(has_priv probe_base "$seq" SELECT)"
  upd="$(has_priv probe_base "$seq" UPDATE)"
  sv="$(q_soft probe_app probe_base "select setval('$seq', 1000)")"
  if mentions "$sv" 'ERROR'; then sv=refused; else sv=ACCEPTED; fi
  if [ "$sel" = "t" ] || [ "$upd" = "t" ] || [ "$sv" != "refused" ]; then
    wide="$wide $seq(SELECT=$sel UPDATE=$upd setval=$sv)"
  fi
done
if [ -n "$wide" ]; then
  failures=$((failures + 1))
  no narrowness "wider than USAGE on:$wide"
else
  passes=$((passes + 1))
  ok narrowness "USAGE only on both sequences; SELECT=f UPDATE=f; setval refused on both"
fi

# --------------------------------------------------------------------------
# THE VACUOUS-GREEN NOTE, and it is computed rather than asserted.
#
# Cases 4 and 5 both pass on a substrate that grants NO sequence at all, because
# "nothing changed" and "nothing is too wide" are the same observation when the
# set is empty. That is this repository's own recorded rule — a green that is not
# about the thing it names proves nothing — so a run on an empty set says so out
# loud rather than printing two PASS rows a reader would otherwise take as a
# measurement of narrowness.
# --------------------------------------------------------------------------
if [ -z "$(seq_grants probe_base)" ]; then
  say "note: probe_app holds NO sequence grant at all in the base phase, so cases"
  say "      no-sequence and narrowness are green on an EMPTY set. They have not"
  say "      measured narrowness here; the three mutations below are what measure it."
  say ""
fi

# --------------------------------------------------------------------------
# the literal statements, verbatim, on the base phase. This is the evidence a
# reader looks at, and it is the same run on a pre-fix and a post-fix tree — the
# comparison is the whole packet.
# --------------------------------------------------------------------------
timeout 60 docker cp "$LITERAL" "$CONTAINER:/tmp/literal-inserts.sql" >/dev/null
LITERAL_OUT="$WORK/literal.out"
qf probe_app probe_base /tmp/literal-inserts.sql >"$LITERAL_OUT" 2>&1 || true

say "--- literal INSERTs as probe_app, verbatim --------------------------------"
sed 's/^/    /' "$LITERAL_OUT"
say "--------------------------------------------------------------------------"
say ""

# --------------------------------------------------------------------------
# THE CONTROLS, MUTATED. Each must break the case it names, or it is a control
# that has never been red and therefore cannot be read.
#
# The three need the sequence loop to be present to mutate. On a substrate with
# no loop at all they cannot be applied, and that is not a harness failure to
# paper over — it is the finding: there was nothing there to break.
# --------------------------------------------------------------------------
say "== the controls, mutated: each must break the case it names =="

# Written to files with TOP-LEVEL heredocs and read back with a plain `cat`, for
# the reason in the header: this is bash 3.2 and a heredoc inside `$( … )` with
# an odd number of apostrophes in it does not parse.
cat >"$WORK/loop.txt" <<'LOOPEOF'
  for seq_name in
    select format('%I.%I', n.nspname, s.relname)
      from pg_class s
      join pg_namespace n on n.oid = s.relnamespace
      join pg_depend d on d.classid = 'pg_class'::regclass
                       and d.refclassid = 'pg_class'::regclass
                       and d.objid = s.oid
                       and d.refobjid = p_table::regclass
      join pg_attribute a on a.attrelid = d.refobjid
                         and a.attnum = d.refobjsubid
     where s.relkind = 'S'
  loop
    execute format('grant usage on sequence %s to %I', seq_name, login_role);
  end loop;
LOOPEOF
LOOP_ANCHOR="$(cat "$WORK/loop.txt")"

# M2's replacement, the `select … into` shape a careful author reaches for and
# which is quiet on a populated table and an exception on every table in the
# fleet that has no serial column at all.
cat >"$WORK/m2.txt" <<'M2EOF'
  declare
    v_seqs text;
  begin
    select string_agg(format('%I.%I', n.nspname, s.relname), ',')
      into v_seqs
      from pg_class s
      join pg_namespace n on n.oid = s.relnamespace
      join pg_depend d on d.classid = 'pg_class'::regclass
                       and d.refclassid = 'pg_class'::regclass
                       and d.objid = s.oid
                       and d.refobjid = p_table::regclass
      join pg_attribute a on a.attrelid = d.refobjid
                         and a.attnum = d.refobjsubid
     where s.relkind = 'S';
    if v_seqs is null then
      raise exception 'cafaye.protect_table(%, %): no sequence found for any column', p_table, login_role;
    end if;
  end;
M2EOF
M2_TO="$(cat "$WORK/m2.txt")"

if ! grep -Fq 'for seq_name in' "$SUBSTRATE"; then
  say ""
  say "    N/A  m1/m2/m3  the substrate has no sequence loop to mutate — cases 1 and 2 above are"
  say "                   the finding, and there is no control to demonstrate."
  na=$((na + 3))
  cases=$((cases + 3))
else
  say ""

  # M1. The blanket form. It makes the INSERT work too, which is the whole reason
  # it is tempting, and it hands the login role every sequence in the database.
  cases=$((cases + 1))
  mutate m1-blanket "$LOOP_ANCHOR" \
    "  execute format('grant all on all sequences in schema public to %I', login_role);"
  build_phase m1
  protect probe_m1 t_plain
  unrel="$(has_priv probe_m1 public.t_unrelated_id_seq USAGE)"
  restore
  if [ "$unrel" = "t" ]; then
    passes=$((passes + 1))
    ok m1-blanket "RED — probe_app holds USAGE on public.t_unrelated_id_seq, a table it was never granted DML on"
  else
    failures=$((failures + 1)); no m1-blanket "NOT RED — the blanket form was not caught"
  fi

  # M2.
  cases=$((cases + 1))
  mutate m2-raise-null "$LOOP_ANCHOR" "$M2_TO"
  build_phase m2
  out="$(protect probe_m2 t_plain)"
  restore
  if mentions "$out" 'ERROR'; then
    passes=$((passes + 1))
    ok m2-raise-null "RED — $(printf '%s' "$out" | grep -m1 ERROR)"
  else
    failures=$((failures + 1)); no m2-raise-null "NOT RED — the raise-on-empty shape was not caught"
  fi

  # M3. `deptype = 'a'`. `serial` writes an auto dependency and `identity` an
  # internal one, so this filter is a loop that covers exactly the spelling it
  # was written against. It does NOT lock a table out — case 2 measured that, and
  # PostgreSQL does not check the identity sequence's ACL — so what it breaks is
  # COVERAGE, and that is what this asserts: the granted set loses
  # t_identity_id_seq. A rule written this way has to be re-derived the first time
  # a service declares an id column by hand as `DEFAULT nextval(…)`, which is the
  # `bigserial` case and does lock out.
  cases=$((cases + 1))
  mutate m3-deptype-a \
    "                       and d.objid = s.oid
                       and d.refobjid = p_table::regclass" \
    "                       and d.objid = s.oid
                       and d.refobjid = p_table::regclass
                       and d.deptype = 'a'"
  build_phase m3
  protect probe_m3 t_serial
  protect probe_m3 t_identity
  m3_s="$(has_priv probe_m3 public.t_serial_id_seq USAGE)"
  m3_i="$(has_priv probe_m3 public.t_identity_id_seq USAGE)"
  m3_unrel="$(has_priv probe_m3 public.t_unrelated_id_seq USAGE)"
  restore
  if [ "$m3_s" = "t" ] && [ "$m3_i" = "f" ] && [ "$m3_unrel" = "f" ]; then
    passes=$((passes + 1))
    ok m3-deptype-a "RED — granted set shrinks to [t_serial_id_seq]; t_identity_id_seq no longer granted (and still nothing on the unrelated one, so this is a coverage loss and not a blanket)"
  else
    failures=$((failures + 1))
    no m3-deptype-a "expected serial=t identity=f unrelated=f, got serial=$m3_s identity=$m3_i unrelated=$m3_unrel"
  fi
fi

restore
if [ "$(shasum_of "$SUBSTRATE")" != "$PRISTINE_SHA" ]; then
  say "STOP: the substrate did not come back byte-identically. Leaving it dirty on purpose."
  exit 1
fi
say ""
say "substrate restored: sha256 $PRISTINE_SHA"

say ""
if [ "$failures" -eq 0 ] && [ "$na" -eq 0 ]; then
  say "$passes/$cases cases green, 0 N/A, 0 failed."
  exit 0
fi
say "$passes/$cases cases green, $na N/A, $failures failed."
[ "$na" -gt 0 ] && say "note: an N/A is not a pass. It is a case that could not run, which measured nothing."
exit 1