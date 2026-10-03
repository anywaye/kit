# The adapter contract — five languages from here

`cross_tenant_harness.sh` brings up a database, a throwaway copy of a service,
the service's own migrations, and a negative suite. It then reads what came back.
It contains **no Elixir, no Ecto, and no knowledge of what courier's tables are
called**, and that separation is the whole reason another language is an adapter
away rather than a second harness.

**Exactly one adapter exists: `elixir.sh`.** The other five fleet languages —
Go (identity, guard), Ruby (cafaye-rb), TypeScript (cafaye-ts), Python
(cafaye-py), Rust (darkroom) — are **unproven**. Not "covered by the same rules",
not "nominally supported": unproven, and the report says so in those words.

## Why one, and honestly labelled

The alternative was six nominal adapters and one real one, and a reader would
have had no way to tell which was which from the output. The whole of D18 is that
a reader cannot distinguish a proven claim from an unexercised one, so the honest
claim after this packet is:

> cross-tenant isolation is **proven for Elixir**, on a service that scopes
> correctly. **Five languages remain unproven.**

A working single-language harness, honestly labelled, beats six languages
nominally covered.

## The five functions

An adapter is a shell file that `cross_tenant_harness.sh` sources. It defines
these and nothing else. It may read `$KIT_TENANT_WORK`, `$KIT_TENANT_SERVICE`,
`$KIT_TENANT_PGPORT`, `$KIT_TENANT_ADAPTER_DIR` and `$TIMEOUT_BIN`; it must not
write outside `$KIT_TENANT_WORK`; and it must never touch the service's own
checkout.

| function | contract | non-negotiable |
|---|---|---|
| `adapter_language_tool` | echo the one executable the harness must find, or the run exits 2 naming it | — |
| `adapter_prepare` | make a buildable copy of the service under `$KIT_TENANT_WORK/service`; dependencies may be symlinked, never mutated | must not write into the service checkout |
| `adapter_migrate` | apply **the service's own migrations** to the harness's database | no hand-written schema — a harness that seeds a table it invented is measuring its own DDL |
| `adapter_install_probe` | copy the negative suite in and **prove it was collected** | a probe that never ran reports 0 failures and every breakage looks green |
| `adapter_run <needle>` | run the suite, print its output, exit with the runner's status | exit 0 must mean every assertion passed |

`adapter_prepare` is where the compile happens, and it is bounded and fatal: a
harness that compiled nothing has no query layer to run.

## What a second adapter has to write, and what it does not

**It writes the negative suite.** One file, in the service's own test language,
copied into the copy by `adapter_install_probe`. It must contain one test per
breakage the recipe plants, **each named after the breakage it is the control
for** — the recipe asserts on the name, so a name that changes silently
un-proofs the case.

**It does not write the recipe.** `reports/tenant-isolation-harness/mutations.sh`
is language-neutral except for the six *anchors*, which are the service's own
source text. A second language gets its own `reports/<packet>/mutations.sh` with
its own anchors; the harness, the tally and the four assertions per case are
already written and are not re-implemented.

## The assertion set every adapter must reproduce

**Three denials and one allowance, never three denials.** A probe made only of
denials is satisfied by a service that returns nothing to anybody, and a broken
*bind* — the predicate present, the value under it wrong — reads as "zero rows",
which every denial-only assertion is perfectly happy with.

| arm | what it catches |
|---|---|
| A's own account reads its own rows | the allowance: a bind that resolves to nothing at all |
| A reads B's rows | the predicate is gone |
| A fetches B's row by id | IDOR on fetch-by-id |
| A writes B's row | unscoped update |
| A deletes B's row | unscoped delete |

The fourth arm is the one a fleet that only writes denial tests will forget, and
it is the one `cross_tenant_list_own_row_visible` exists for.

## What the harness does NOT decide, and a language adapter cannot fix

- **Response code.** A cross-tenant read is a **404, never a 403**. A 403
  confirms the id exists to somebody who cannot see it. The probe asserts the
  code the service documents; it does not decide it.
- **Where the predicate lives.** In courier it lives in a context query four
  frames from the write, which is why two of the six breakages are one-word edits
  in a controller. Another service may scope in a repository, an ORM filter, or a
  Postgres policy — and the recipe's anchors move with it, one per breakage.
- **Row-level security.** `tests/tenancy_test.sh` proves the *substrate*
  (`FORCE ROW LEVEL SECURITY`, the `_app` login role) in six languages already.
  This harness is the other half: it proves the **application's** scoping. Both,
  for a service, is the claim D18 wants; one alone is not.