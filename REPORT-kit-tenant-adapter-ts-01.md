# REPORT — kit-tenant-adapter-ts-01

**The packet asked for a TypeScript cross-tenant adapter against `parlor`. There
is not one to write, and the reason is measured rather than argued: no
TypeScript service in this fleet holds a database.** This packet delivers the
measurement, a falsification recipe for it, and an honest language list. It does
not deliver a third adapter, and it says in the README that it does not.

The paths in the packet were written `kit/tests/...` and `kit/reports/...`.
This repository *is* kit, so the real paths are `tests/tenant_isolation/...` and
`reports/tenant-adapter-ts-01/...`. Recorded because a worker who took the paths
literally would have concluded the packet referred to a different repository.

---

## 1. The finding

Measured by `reports/tenant-adapter-ts-01/subject-audit.sh`, over the fleet at
`/Users/kaka/Code/any/moon/cafaye`:

| TypeScript repository | account-scoping files | imports a db driver | declares a db driver | own `.sql` |
|---|---|---|---|---|
| `cafaye-ts` | 13 | **0** | – | **0** |
| `docs` | 0 | **0** | – | **0** |
| `guard` | 12 | **0** | – | **0** |
| `parlor` | **12** | **0** | – | **0** |
| `site` | 0 | **0** | – | **0** |

**Not one of the five has a database.** `parlor`'s twelve account-scoping files
are all HTTP path segments built for calls to `identity` —
`send(transport, `${base}/v1/accounts/${accountId}`, "GET", { token })` at
`parlor/src/lib/identity.ts:367-368` and nine siblings — not predicates. The
packet expected anchors of the form `where(eq(t.accountId, accountId))`; that is
Drizzle's spelling and **no service in this fleet uses Drizzle or any ORM**.

Two details worth the reader's attention:

- **The packet's own counts reproduce exactly** — `parlor` 12, `guard` 12,
  `site` 0. The measurement method was right and the *inference* drawn from it
  was not: twelve files naming an account was read as twelve places scoping by
  account, and in a service with no rows there is nothing to scope. That is a
  more interesting failure than a wrong number, because a right number is much
  harder to catch.
- **`site` really does ship one `.sql`** —
  `site/e2e/postgres-initdb/10-identity-app.sql` — and it is a hand-written
  fixture for **identity's** migration. Counting it as site's own schema would
  be the same category of error as reading `guard` as a Go service. The audit
  excludes fixture directories, and `mutations.sh` B4 is the control proving the
  exclusion discriminates rather than swallowing everything.

## 2. Why the adapter is *undefined*, not *unfinished*

`cross_tenant_harness.sh` measures a **query layer**, and its five steps each
need something the subject holds: a real Postgres, **the service's own
migrations**, two accounts seeded **through the service's own write path**, and
**the service's own functions** called as account A. `parlor` has none of these.
Against it:

- `adapter_migrate` has **nothing to apply**. The contract forbids the
  alternative in as many words: *"no hand-written schema — a harness that seeds a
  table it invented is measuring its own DDL."*
- There is **no write path** to seed two accounts through.
- There is **no query layer** for `adapter_run` to call.

The only way to produce a green `ts.sh` was to hand-write `identity`'s schema
into the harness database and point the probe at it. **That would have been a
third measurement of identity's Go SQL, executed through a `.ts` file** — and it
would have let the README say "three languages proven" on the strength of a
second measurement. That is the vacuous green this repository has a written rule
about, wearing a third language's name, so it was not done.

A skeleton `ts.sh` **was** committed early, as the packet's standing instruction
requires, and then **withdrawn in its own commit** (`bd088b9`). A permanently
failing adapter at the adapter path is half a language, and `adapters/README.md`
already rules that "half a language is worse than none" — it would have sat
exactly where a reader scans to answer *is TypeScript covered here*.

## 3. What was built instead

### `reports/tenant-adapter-ts-01/subject-audit.sh`

The measurement, written to fail in **one direction only**. It exits 0 while no
TypeScript service holds a database, and exits **1 naming the service** the
moment one does — because that service is the first subject this harness can
measure in TypeScript, and the adapter that must be written for it.

An absence is the easiest kind of claim to satisfy by accident, so a check that
could only report green would be reporting nothing. Three signals, reported
separately because two of them mean different things: **IMPORTS** (the one the
finding rests on — a driver nobody imports is not a query layer, whatever
`package.json` claims), **DECLARES** (scaffolding until something imports it),
**MIGRATES** (`.sql` outside `e2e/`, `test/`, `tests/`, `fixtures/`).

It also carries a **"measured nothing" guard** (`subject-audit.sh:246`): a run
that finds no TypeScript service at all refuses to conclude and exits 1. **That
guard caught a bug in this packet's own first draft** — a bad substitution left
`ts_count` at 0, and rather than reporting "no TypeScript service holds a
database" the audit said it had measured nothing. The property worked on its
author.

### `reports/tenant-adapter-ts-01/mutations.sh`

The falsification. It builds a **scratch fleet root** from the real
repositories' manifests and sources — node_modules pruned in `find`, not filtered
afterwards, because `grep -r | grep -v node_modules` still *walks*
node_modules and made the first draft of the audit exceed its time bound before
reaching the fourth service. The **control runs against the real fleet,
read-only**; every breakage runs against the copy. **No checkout was written to.**

## 4. The tallies

```
tally
  controls run                     : 2
  breakages planted                : 6
  breakages caught, assertion named: 4
  greens (controls + reverts + B5) : 9
  failures                         : 0
VERDICT: PASS
```

**Reported separately from the passes, because they are four different claims.**
A control says the audit agrees with the fleet; a red says a breakage was caught
*by name*; a green inside B5 says a check was load-bearing.

### The control

Green, twice: once against the **real fleet** and once against the **scratch
fleet** built from it, and the control additionally asserts the audit printed
`RESULT: NO TypeScript service in this fleet holds a database.` — a green that
arrived by a different sentence is not the control.

### Each breakage, by file and line

| case | mutation | expected | caught by | anchor / assertion |
|---|---|---|---|---|
| **B1** | `pg` added to `parlor`'s `dependencies` | RED | `DECLARES a db driver that nothing imports` | `subject-audit.sh:267` |
| **B2** | a source file importing `drizzle-orm` | RED | `IMPORTS a db driver   : 1` | `subject-audit.sh:198` |
| **B3** | `parlor/src/db/migrations/0001_init.sql` | RED | `MIGRATES (.sql own)   : 1` | `subject-audit.sh:205` |
| **B4** | `parlor/e2e/postgres-initdb/10-identity-app.sql` | **GREEN** | exclusion holds; reports `: 0` | `subject-audit.sh:71` |
| **B5** | migrations **assertion deleted** from a copy of the audit, B3 re-applied | **GREEN** | B3 stops being caught | `subject-audit.sh:205` → `0` |
| **B6** | an anchor matching nothing | **STOP** | `edit` refuses, exits non-zero | `mutations.sh:362` |

**The six are deliberately not six reds**, and a recipe that counted them as such
would be asserting a number rather than a property. B4 must stay green — an
exclusion with no control is an exclusion nobody has tested. B5 must go green —
that is what proves B3's check was load-bearing. B6 must make the recipe stop.

## 5. Breaking my own work, as the packet requires

### Deleting one assertion — B5

The migrations assertion was deleted from a **copy** of the audit
(`n_migrations="$(count_lines …)"` → `0`), B3's breakage re-applied, and the
audit was required to go **green**. It did. B3's breakage is therefore **no
longer caught**, which proves B3 was resting on that check and not on the exit
status. The real audit was then run against the reverted tree and went green
again, so "B5 went green" is evidence about a deliberately crippled copy and not
about a broken one.

### An anchor pointing at nothing — B6

`edit` was given text that is not in the audit. It printed `anchor appears 0
times … expected exactly 1` and returned non-zero; the recipe counted it RED and
**stopped** rather than reporting the remaining cases green over a substrate it
never changed. `edit` is the `go-01` recipe's helper, unchanged in behaviour.

### The recipe found a real defect in the audit it was proving

**This is the result worth the most.** B1 planted a `pg` dependency and **the
audit stayed green** — because `DECLARES` was *printed* and never *acted on*.
A signal the audit displays and ignores is kit's own "add the check that would
catch its absence", and the same shape as `guard` being listed as Go: a word in
a report that looks like coverage and is not load-bearing.

The fix was **not** to widen eligibility, which would have been making the test
pass. A declared driver nothing imports is **not** a query layer, so it does not
make the adapter definable; it now has **its own verdict and its own exit-1
branch** (`subject-audit.sh:267`) naming the service and the driver, because it
means one of two things a reader cannot tell apart from the tree — dead weight
left by a removed query layer, or a half-finished migration **onto** a database.
Had B1 been written after that fix rather than before it, the recipe would have
shipped a green check that could not fail.

### The harness is unchanged

`tests/tenant_isolation/cross_tenant_harness.sh` is **byte-identical to master**,
sha256 `46da0eb4fad234728b62540162df249b59d8e5ac1820fa5828ef05b2635cd760`,
verified with `git diff --quiet master`. **It was never edited, not even in a
comment** — the packet forbids changing it, and a stale header comment is a
report item, not a change.

## 6. What changed in the README

`tests/tenant_isolation/adapters/README.md`, and **the language count was not
changed to three**, because that sentence would be false:

- The unproven list keeps TypeScript, now mapped to its actual services:
  **TypeScript (cafaye-ts, guard, parlor, site)**.
- A paragraph states the measured reason and names
  `reports/tenant-adapter-ts-01/subject-audit.sh` as the tripwire.
- The honest-claim block keeps **"Four languages remain unproven"** and adds that
  for TypeScript the reason is structural.
- A new section, *"Where the TypeScript boundary actually is, and what would
  prove it"*, records that **`MVP-SCOPE.md` draws `site → guard → identity(Go)`
  with every arrow pointing down into the service that holds the rows**, and
  quotes `guard`'s own `test/tenantEntryPoints.test.ts`: *"guard holds no
  account's rows: there is no `assets` table and no query that could drop `and
  account_id = $2`. What guard holds is state keyed by account."* The
  TypeScript-layer boundary is a **forwarding** property, and `guard` already
  measures it with its entry points **derived from the source** rather than listed.
- `guard`'s file count was **re-measured at 44 `.ts`, 0 `.go`, no `go.mod`**. The
  packet's "40" is wrong, and wrong in the direction that matters — the smaller
  number would have become the file's.

`CHANGELOG.md` carries an `## Unreleased` → `### Added` entry. `### Breaking`
is the only heading illegal under `Unreleased`, so this one is legal.

## 7. Was `parlor` correctly scoped?

**Not applicable, and the distinction matters.** `parlor` holds no
account-scoped rows, so there is nothing for it to scope. The packet's
premise — *"parlor scopes by account in twelve places and proves nothing about
any of them"* — is half right in a way worth recording: the **"proves nothing"
half is exactly correct**, and `parlor`'s own tests do assert on `accountId`
paths, but they assert on a **forwarder's URL construction**, not on an account
boundary, because there is no boundary there to assert on. The **"scopes by
account in twelve places" half is false**: twelve files name an account and none
of them predicates anything.

Nothing in `parlor` is *broken*. The finding is not "parlor has a defect"; it is
"parlor is not a subject this instrument can measure", which is a statement about
the instrument. Per the packet, nothing in `parlor` was touched.

## 8. What is still unproven after this packet

**Four languages, and the four are now unproven for four different reasons,
which is the honest shape of the claim.** Ruby (`cafaye-rb`), Python
(`cafaye-py`) and Rust (`darkroom`) are unproven in the ordinary sense: nobody
has run this harness against them, and each plausibly *could* be — `darkroom`
ships three `.sql` files and `cafaye-rb` one, so a subject may well exist for
each, and writing those adapters is ordinary kit work with a known shape. The
fourth, **TypeScript, is unproven because no service in the fleet has anything to
prove**: `cafaye-ts`, `guard`, `parlor` and `site` hold no account-scoped rows,
so the assertion set this harness exists to run — three denials and one
allowance — is not expressible against them, and no adapter, probe or recipe can
make it so. That is emphatically **not** a finding that the TypeScript layer is
safe; it is a finding that its cross-tenant exposure is a *forwarding* question
(can a caller reach an account they do not hold by naming it) rather than a
*query* question, and that `guard` already answers it for itself with a negative
case per account-scoped entry point and an enumeration **derived from the
source** rather than maintained by hand. So the real gap is narrower than
"TypeScript is unproven": it is that `parlor` and `site` have **no equivalent
derived enumeration**, and if the fleet wants a fleet-wide forwarding claim the
missing instrument is a forwarding-shaped harness — no database, two
principals, one cross-tenant name — which is a different packet from this one.
Meanwhile `subject-audit.sh` is the tripwire: the day a TypeScript service
acquires a database, this harness has a third language to measure, the count
moves from four to three for a reason, and the adapter this packet withdrew
becomes writable.

---

### Commits on `worker/kit-tenant-adapter-ts-01`

| sha | what |
|---|---|
| `9c1d896` | skeleton `ts.sh`, five functions, three TODO |
| `bd088b9` | **withdraw** the skeleton — the adapter is undefined, not unfinished |
| `c6e3c0c` | `subject-audit.sh` — the measurement, failing in one direction |
| `24d9085` | `mutations.sh` — 6 cases; found the `DECLARES` defect |
| `0f7efe3` | README says four and says why; CHANGELOG entry |
| — | this report |

**Not pushed.** `cross_tenant_harness.sh` untouched; no service checkout written
to; both new scripts `shellcheck -S warning` clean; every command bounded.
