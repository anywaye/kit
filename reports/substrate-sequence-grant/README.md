# `protect_table` made a table uninsertable

This directory holds the measurement behind one change to
`templates/database/tenancy/substrate.sql`: `cafaye.protect_table` granted the
login role DML on a table and nothing on the sequences behind it, so a protected
table with a `bigserial` column could not be INSERTed by the role the substrate
exists to hand DML to.

    bash reports/substrate-sequence-grant/mutations.sh

Needs docker and the `postgres:18` image already pulled (`KIT_SEQGRANT_IMAGE`
overrides the tag). It reports `SKIP` and exits 3 rather than pulling: a proof
that reaches the network is a proof whose inputs are not pinned. One container,
`kit-seqgrant-$$`, removed with `-v` on every exit path.

## The four files

| file | what it is |
|---|---|
| `mutations.sh` | the harness. Five cases and three mutated controls |
| `fixture.sql` | four tables and one probe function, run as the OWNER |
| `literal-inserts.sql` | the statements a service actually writes, run as the LOGIN role. Its output is the evidence |
| `BEFORE.txt` | the run against the substrate as it stood: `FAIL bigserial — permission denied for sequence` |
| `AFTER.txt` | the run against the fixed substrate: `8/8 cases green` |

`BEFORE.txt` and `AFTER.txt` are the same script on the same tree, run twice
with `templates/database/tenancy/substrate.sql` at the two revisions. The
digests are printed at the top of each: `e2b4917b…` is `master`, `b566bcb3…` is
the fix. `e2b4917b…` is also the digest `courier` pins, which is how the two
revisions are known to be the two revisions and not two trees.

**The witness for `fixture.sql` and `literal-inserts.sql` is
`mutations.sh`, not `tests/tenancy_test.sh`.** The gate's parse loop names its
SQL paths one by one rather than globbing, so these two files are not in it and
no skip is printed for them either — which means a reader must not assume
`tenancy_test.sh` covers them. It applies both to a real Postgres with
`ON_ERROR_STOP=1` and stops the run naming the file if either one errors, which
is the parser that matters for SQL: a syntax error in a migration is only
observable by a server.

## What each case is for, in one line each

1. **`bigserial`** — the shape the defect was reported on. The only one of the
   five that is a lockout.
2. **`identity`** — the same column spelled the other way. **This case is green
   before the fix**, and that is the measurement that corrects the premise: on
   PostgreSQL 17.11 and 18.6 an `identity` column does not need a sequence grant.
   It asserts the GRANT rather than a lockout, and says which it is reporting.
3. **`breakage`** — revoke the grant `protect_table` just made, require the
   denial back, re-protect, require the row back. `N/A` before the fix, because
   there was no grant to revoke, and an `N/A` is not counted as a pass.
4. **`no-sequence`** — a protected table with no sequence gains no grant and
   does not raise. Green on an empty set before the fix, which the run says out
   loud rather than printing two PASS rows a reader would take for a measurement.
5. **`narrowness`** — `USAGE` only: no `SELECT`, no `setval`, nothing on a
   sequence belonging to a table the login role has no DML on.

## The three mutated controls

A control that has never been red cannot be read, so each of these must change
the thing it names or the run fails:

| mutation | must break |
|---|---|
| `m1-blanket` — `grant all on all sequences in schema public` | case 4, on the unrelated table's sequence |
| `m2-raise-null` — the `select … into` shape, which raises on an empty result | case 4, on "must not raise" |
| `m3-deptype-a` — `and d.deptype = 'a'` | the granted set loses the identity sequence |

On a substrate with no sequence loop at all, all three are reported `N/A` and the
run counts them as N/A rather than as passes. There was nothing there to break,
and that is the finding rather than a harness failure.