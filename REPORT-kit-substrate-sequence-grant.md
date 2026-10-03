# REPORT — `kit-substrate-sequence-grant`

**Branch:** `worker/kit-substrate-sequence-grant`, from `master` at `c8d76df`
**Not pushed.**

---

## 1. The defect, measured

`templates/database/tenancy/substrate.sql`, `cafaye.protect_table`. The whole
grant story for the login role was three statements, and none of them mentioned
sequences:

```sql
execute format('grant usage on schema public to %I', login_role);
execute format('grant usage on schema cafaye to %I', login_role);
execute format('grant select, insert, update, delete on table %s to %I', p_table, login_role);
```

A table's `INSERT` reads its sequence **before** it writes the row, and a
sequence is a separate object with separate grants — the table grant does not
carry it. So every protected table with a `bigserial` column was uninsertable by
the very role the substrate exists to hand DML to.

**The red, on the substrate as it stood** (`reports/substrate-sequence-grant/BEFORE.txt`,
substrate sha256 `e2b4917be2a7f7c48964bd40fea0da93db503b4c736a42a44e44425cfbf7bf5e`,
PostgreSQL 18.6, as `probe_app`, inside a transaction carrying an account
identity):

```
--- t_serial — bigserial ---
BEGIN

psql:/tmp/literal-inserts.sql:32: ERROR:  permission denied for sequence t_serial_id_seq
ROLLBACK
```

and the harness's verdict line, which prints the SQLSTATE beside the message:

```
FAIL  bigserial      SQLSTATE 42501 / permission denied for sequence t_serial_id_seq
```

That digest is the one `courier` pins. The red was captured by running the *same*
harness that produced the green, on this tree, with only
`templates/database/tenancy/substrate.sql` reverted — so `BEFORE.txt` and
`AFTER.txt` differ by one file and by nothing else.

**The fix** (sha256 `b566bcb3cfe1d36e0066ae93cf31314d52df7fac902ca41db5e9e28535badf66`),
`AFTER.txt`:

```
PASS  bigserial      insert landed, returning id = 1
PASS  identity       insert landed (id 1); t_identity_id_seq granted USAGE
PASS  breakage       revoked -> permission denied for sequence t_serial_id_seq; re-protected -> id 2
PASS  no-sequence    no grant gained (still [public.t_identity_id_seq public.t_serial_id_seq]), unrelated sequence untouched, insert landed
PASS  narrowness     USAGE only on both sequences; SELECT=f UPDATE=f; setval refused on both
...
8/8 cases green, 0 N/A, 0 failed.
```

and the same literal statement:

```
--- t_serial — bigserial ---
BEGIN

3
INSERT 0 1
COMMIT
```

**The breakage.** `PASS breakage` above: the harness revokes the grant
`protect_table` just made, requires the denial back, re-protects and requires the
row back — `revoked -> permission denied for sequence t_serial_id_seq;
re-protected -> id 2`. Without that a reader cannot tell this fix from a
coincidence.

**The negative control.** `t_plain` has a `bigint primary key` and no sequence at
all. `protect_table('t_plain')` must not raise, and must not change the set of
sequences `probe_app` holds `USAGE` on. It does not, and it is measured twice
over, because that case has two halves that fail differently:

- the granted **set** is unchanged, and
- `probe_app` still holds nothing on `t_unrelated_id_seq` — the sequence behind
  a `bigserial` table nobody ever protected.

`t_unrelated` exists in the fixture for the blanket-form half. A
`grant all on all sequences in schema public` passes both halves of case 1 and
fails this one.

## 2. The trap, and what I chose instead

**The grant is `usage`, on each sequence the table's own columns own, and nothing
else.** The argument that this is sufficient rather than merely convenient:

- `usage` is the privilege `nextval` and `currval` check. It is the minimum that
  makes an `INSERT` into a serial column work.
- It is deliberately **not** `select`, which would let the login role read
  `last_value` and reason about how many rows other tables hold, and **not**
  `update`, which would let it `setval` and forge ids.
- Both refusals are asserted rather than asserted-in-a-comment: case `narrowness`
  runs `has_sequence_privilege` for `SELECT` and `UPDATE` **and** calls `setval`
  as the login role on **both** granted sequences. All four must refuse.

The blanket form was not reached for, and the harness contains a mutation that
proves why: `m1-blanket` substitutes it, and the negative control goes red.

```
PASS  m1-blanket     RED — probe_app holds USAGE on public.t_unrelated_id_seq, a table it was never granted DML on
```

The loop reads the catalog rather than a naming convention, so a table with two
serial columns gets two grants and a sequence called something else is still
found:

```sql
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
```

It is a `for … in select`, so an empty result set is a loop that does not run
rather than a `no rows` exception — the same quiet way `protect_table` degrades
on a table with no tenancy column. Sequences are schema-qualified because a bare
relation name in a `GRANT` resolves through the **caller's** `search_path`, and
the caller of a migration is a role whose `search_path` this function does not
control.

**The second entry point inherits it, measured rather than argued.**
`protect_credential_table` does not repeat `protect_table`'s body — line 334 is
`perform cafaye.protect_table(p_table, p_login_role);`, with the comment "so a fix
to one is a fix to both and there is no second copy of ENABLE/FORCE to drift". That
is a structural argument, so it was also run: a `bigserial api_keys` table,
`cafaye.protect_credential_table('api_keys', 'token_digest')`, and then

```
api_keys_id_seq|t
```

— `probe_app` holds `USAGE` on the credential table's sequence too. There is no
second copy of the grant story in this file to go stale.

## 3. The identity case: the premise is wrong, and here is the measurement

The packet says the identity case must be covered "because a fix that only handles
`bigserial` leaves the same lockout one syntax away". **Measured, the `identity`
case was never locked out.** On both PostgreSQL **17.11** (kit's floor) and
**18.6**, with no RLS, no substrate and no grants beyond table `DML`:

```
-- iso_serial  ERROR:  permission denied for sequence iso_serial_id_seq
-- iso_ident   1 INSERT 0 1
```

And the sequence is genuinely ungranted — its ACL is `<null>` and
`has_sequence_privilege` returns `f`:

```
iso_ident_id_seq|probe|<null>|f|f
iso_serial_id_seq|probe|<null>|f|f
```

The distinction is *which code path fetches the value*. An explicit
`nextval('iso_ident_id_seq')` **as the same ungranted role** is refused:

```
nextval(iso_ident_id_seq  ) ERROR:  permission denied for sequence iso_ident_id_seq
nextval(iso_serial_id_seq ) ERROR:  permission denied for sequence iso_serial_id_seq
```

So `serial` goes through the `DEFAULT nextval(...)` expression and the ordinary
permission check, and `identity` is fetched on a path that does not check. I did
not read PostgreSQL's source to confirm the mechanism — `git.postgresql.org`
answered `429` and the GitHub mirror `404` — so that sentence is a measurement
and not a reading, and it is labelled as such in `CHANGELOG.md`.

The harness therefore measures case 2 as **the grant**, not as a lockout, and
says which it is reporting. On the pre-fix tree:

```
FAIL  identity       insert landed (id 1) but protect_table granted NO USAGE on t_identity_id_seq — the identity edge of the catalog is uncovered
```

**The loop grants it anyway, and that is a decision rather than an oversight.**

- It is `usage` on the table's **own** sequence and nothing wider. Case 5 asserts
  that on both sequences, so "narrow" is a measured claim about every grant the
  loop made, not only the one the reported bug needed.
- A substrate whose correctness rests on an undocumented executor detail is one
  minor version from the same lockout.
- A column declared `DEFAULT nextval('…')` by hand rather than by `serial` is the
  `bigserial` case again, and a rule that reads the catalog does not have to be
  re-derived every time a service picks a new spelling of the same edge.

`m3-deptype-a` is the mutation that shows the coverage is load-bearing:

```
PASS  m3-deptype-a   RED — granted set shrinks to [t_serial_id_seq]; t_identity_id_seq no longer granted (and still nothing on the unrelated one, so this is a coverage loss and not a blanket)
```

## 4. TALLIES, REPORTED SEPARATELY

**The five probes, on the pre-fix substrate** (`BEFORE.txt`, exit 1):

| case | verdict | what it is |
|---|---|---|
| `bigserial` | **FAIL** | `42501 permission denied for sequence t_serial_id_seq` — the lockout |
| `identity` | **FAIL** | insert worked; the grant did not exist. Not a lockout |
| `breakage` | **N/A** | no grant existed to revoke. Counted as N/A, **not** as a pass |
| `no-sequence` | PASS | **vacuous** — green on an empty grant set |
| `narrowness` | PASS | **vacuous** — green on an empty grant set |

`2/8 cases green, 4 N/A, 2 failed.` (The 8 is five probes plus three mutations.)

The harness prints the vacuity rather than the reader having to infer it:

```
note: probe_app holds NO sequence grant at all in the base phase, so cases
      no-sequence and narrowness are green on an EMPTY set. They have not
      measured narrowness here; the three mutations below are what measure it.
```

**The five probes, on the fix** (`AFTER.txt`, exit 0): `8/8 cases green, 0 N/A,
0 failed` — five probes plus three mutated controls.

**The three controls, all observed red** (this is the part that makes the other
three PASS rows readable):

| mutation | must break | observed |
|---|---|---|
| `m1-blanket` | the unrelated sequence | RED — `USAGE` on `t_unrelated_id_seq` |
| `m2-raise-null` | "must not raise" | RED — `ERROR: cafaye.protect_table(t_plain, probe_app): no sequence found for any column` |
| `m3-deptype-a` | the granted set | RED — set shrinks to `[t_serial_id_seq]` |

On the pre-fix tree all three are reported `N/A` and counted as N/A, with the
reason printed: there was no loop to mutate. That is the finding, not a harness
failure.

## 5. The rest of the fleet, reported and not edited

**`courier` — untouched, deliberately.** Its copy is at
`priv/repo/substrate.sql`, sha256 `e2b4917b…`, byte-identical to `master`'s copy
of this file and carrying no sequence grant. The pin lives in
`priv/repo/migrations/20261003090000_protect_account_scoped_tables.exs` as
`@substrate_sha "15cee0e1d5eacaea8e743f65981cd893da7f8873"` plus a sha256 check
that names both digests on mismatch. **Changing kit's file does not change
courier's, and this packet does not touch that mechanism** — that pin is what
stops a substrate edit silently changing a migration in a repository nobody was
looking at. A follow-up packet re-copies from kit and re-pins; editing the copy
here would defeat the pin. The "refuses to run if **both** digests are named"
behaviour is in that migration and is unchanged.

**`identity` — needs the same change, in a different shape, and carries no
lockout today.** I could not find a `substrate.sql` in it. What it has is the
function body **inlined** into `migrations/00016_account_isolation.sql` — same
step-6 grants, no sequence grant (verified by reading it, `grep` for
`for seq_name in` / `grant usage on sequence` finds nothing). So:

- the fix is owed there, but **"re-copy the file" does not apply**: the copy is
  inside a migration, so a follow-up has to edit the migration and pin it by its
  own digest rather than swap a pinned file.
- it is **not** a live lockout today. `identity` has no `bigserial` and no
  `GENERATED … AS IDENTITY` anywhere in its tree; its four protected tables
  (`account_users`, `account_invitations`, `oidc_clients`, `account_audit_log`)
  use `uuid DEFAULT gen_random_uuid()` or composite primary keys. It acquires the
  lockout the first time a protected table grows a serial column — which is a
  smaller and later claim than "identity is broken today", and it is the one I
  can support.

## 6. What else ran, and one FAIL that is not mine

**What ran against which bytes, because two of these ran against an earlier
revision of the substrate than the one committed.** I reworded two comment blocks
in `substrate.sql` after starting the full gate — to remove two claims my own
measurement had refuted (§6a) — which moved the file from `ad3e45e9…` to
`b566bcb3…`. The SQL is byte-identical across that move; only comments moved. So:

| what | bytes it ran against | result |
|---|---|---|
| `bash reports/substrate-sequence-grant/mutations.sh` | `b566bcb3…` (final) | **exit 0**, `8/8 cases green` |
| `bash tests/tenancy_test.sh` | `b566bcb3…` (final) | **exit 0**, 39 assertions, FORCE control red |
| `bash tests/validate.sh --static-only --no-self-test` | `b566bcb3…` (final) | **exit 1**, one FAIL — the pre-existing one below |
| `bash tests/validate.sh` (full, all six phases) | `ad3e45e9…` | **exit 1**, one FAIL — the same one. All 107 breakages held |

The static phase is the phase that reads `substrate.sql`'s content, and it was
re-run on the final bytes, so the comment rewording is covered. The full gate's
self-test (107 breakages of a throwaway copy) ran on the earlier revision; that
phase does not read the substrate at all, which is why re-running the static
phase rather than the whole gate is the right response to a comment-only move.

- `bash tests/tenancy_test.sh` — **PASS**, 39 assertions, and its FORCE control
  went red with FORCE removed (11 red, all `owner/` or `sweep/`). Required by
  `AGENTS.md` for a change under `templates/database/tenancy/`. Worth noting what
  it could **not** see: its fixture tables have no serial column, so it is green on
  both revisions of this file. That is the gap the new probe fills, and it is why
  the proof lives in `reports/` rather than being folded into that suite.
- `bash tests/validate.sh` — one `FAIL`,
  `generated stack (no repository commits the file caf dev generates)`, naming
  `cafaye-rb`, `cafaye-ts`, `docs`, `guard` as blocking and `darkroom`, `muse` as
  frozen. **It is not caused by this packet and I did not weaken it.** The check
  reads sibling repositories' `.gitignore` and their `cafaye.yml`; this packet
  touches one SQL file, one new `reports/` directory and `CHANGELOG.md`.
  Demonstrated rather than asserted: run from the clean `master` worktree
  (`/Users/kaka/Code/any/moon/cafaye/kit`, `git status` empty), the same program
  gives the identical verdict —

      FAIL generated-stack: 4 blocking problem(s) across the fleet, and 2 further
      finding(s) in frozen repositories that do not count against it.

  It arrived with `a5bb277` ("the generated-stack gate failed on two frozen
  repositories") and is fleet state the packet does not own.
- Everything else the gate ran was green, including `self_test` —
  **all 107 breakages hold, 103 assert red, 3 assert a green gate with a named
  skip, 1 with a named finding**, `108 ran against 108 declared`, **0 environment
  failures, 0 skipped for a missing toolchain**.

### 6a. A second finding, in kit's own assertion set — reported, not half-fixed

While correcting an overclaim in my own substrate comment I checked the claim it
was resting on, and it was false in a way worth writing down.

`templates/database/tenancy/isolation.sql`'s `pg_temp.cafaye_observed` is

```sql
exception when others then
  return sqlstate;
```

and four assertions compare the result against the literal `'42501'`. So kit's own
assertion set checks the **code** and not the message — which is precisely the
ambiguity this packet is about, one layer in, and the same shape as the probe in
`courier` that passed on a sequence denial until it also required the message.

**It is not currently armed.** The probe table is

```sql
create temp table cafaye_probe_things (
  id uuid primary key default gen_random_uuid(),
```

— no sequence, so no statement in the file can produce a sequence denial, and 39
assertions have been green straight through this defect. That is the whole reason
the weakness has survived, and it is also the trap: the natural next step for
kit's tenancy suite is to give the probe table a serial column, and on the day
that happens every `'42501'` assertion in the file becomes satisfiable by a
sequence denial, silently.

I did **not** fix it here. `isolation.sql` and `assertions.txt` are one contract
compared in both directions across six language templates, and changing what
`cafaye_observed` returns changes every assertion's meaning — a packet of its own,
with its own six-language blast radius. What this packet owes it is the finding,
and the substrate comment now states the exposure rather than claiming a
protection that is not there.

## 7. Two defects found in the harness while building it, recorded because both
would have produced a clean report

- **bash 3.2 mis-lexes a quoted heredoc inside `$( … )` when the body carries an
  ODD number of apostrophes.** One `it's` in an SQL comment was enough; the whole
  560-line script failed to parse with `unexpected EOF while looking for matching
  "'"` pointing ~30 lines from the end, and `zsh -n` and `shellcheck` both called
  it clean. Measured on `/bin/bash` 3.2.57: identical heredoc at top level parses,
  inside `$( … )` it does not, adding a second apostrophe makes it parse again.
  Fixed by moving every multi-line payload out of `$( … )` — the SQL into
  `fixture.sql` and `literal-inserts.sql`, where it can be `psql -f`'d at all,
  and the mutant payloads into top-level heredocs read back with a plain `cat`.
  The rule is in the file's header so the next reader does not reintroduce it.
- **The first `mutate` over-asserted.** It refused an edit that "left the anchor
  behind", which is wrong for a prefix-style mutation: `m3` appends
  `and d.deptype = 'a'` to a two-line anchor, so the anchor is legitimately still
  present afterwards. The mutation silently did not run and the harness STOPPED
  rather than reporting a tally. Narrowed to "the file changed and the
  replacement is present", which the `count == 1` precondition already carries.

A third, smaller one: `fixture.sql` first wrote `returning id into v_id`, which
is not plpgsql's `EXECUTE` syntax (`INTO` precedes `USING`), so the probe function
never compiled and the harness reported `STOP: fixture.sql did not build` rather
than a green case 1.

## 8. Teardown

One container per harness run, `kit-seqgrant-$$`, removed with `-v` on every exit
path including the failure paths. Every `psql` call is bounded by `timeout`. The
only image touched is `postgres:18`, **pulled, not built**, and left in place:
three other workers share this daemon and removing a base image they may already
have pulled is not this packet's to do. The scratch containers used while
diagnosing were named distinctly (`kit-seqprobe-*`) and each was `docker rm -f -v`'d.
No agent was spawned, no `opencode run`, nothing pushed.

## 9. Files

```
templates/database/tenancy/substrate.sql   +60  the sequence loop
reports/substrate-sequence-grant/
    mutations.sh                              the harness, 5 cases + 3 controls
    fixture.sql                               4 tables + 1 probe function
    literal-inserts.sql                       the statements a service writes
    BEFORE.txt                                the red
    AFTER.txt                                 the green
    README.md                                 what each file is
CHANGELOG.md
```