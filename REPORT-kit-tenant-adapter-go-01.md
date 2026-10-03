# REPORT — kit-tenant-adapter-go-01

The second language, honestly labelled.

Branch `worker/kit-tenant-adapter-go-01`, worktree
`wt-m39-kit-tenant-adapter-go-01`. Three files and two edits:

| | |
|---|---|
| `tests/tenant_isolation/adapters/go.sh` | the five functions, nothing else |
| `tests/tenant_isolation/adapters/go/cross_tenant_probe_test.go` | seven tests, in Go, in the service's own test language |
| `reports/tenant-adapter-go-01/mutations.sh` | six breakages, identity's own anchors |
| `tests/tenant_isolation/adapters/README.md` | the language list, and nothing else |
| `CHANGELOG.md` | the entry |

**`tests/tenant_isolation/cross_tenant_harness.sh` is unchanged, byte for byte.**
`git diff --stat` against the branch point names five files and the harness is
not one of them.

---

## The tallies

Reported separately, because "6 passed" could be six reds or six controls.

```
controls green .................. 1
assertions in the control ....... 7   (7 --- PASS, 0 --- FAIL)
breakages planted ............... 6
breakages observed RED ........... 6
breakages reverted, green again . 6
anchors matching zero times ..... 0
skipped .......................... 0
VACUOUS GREEN (control measured nothing) . no
tree byte-identical at the end .. yes (cmp BEFORE-store.go AFTER-store.go)
```

Recipe exit status **0**. Full transcript:
`reports/tenant-adapter-go-01/` and the `PASS:` summary it prints.

### What the gate said, and what I did about it

`bash tests/validate.sh --static-only` — **447 PASS, 1 FAIL, 6 SKIP.**

The FAIL is `generated stack (no repository commits the file caf dev generates)`
and it is **pre-existing and not mine**, stated rather than assumed: the four
blocking findings are `cafaye-rb`, `cafaye-ts`, `docs` and `guard`, each missing
`/caf.dev.compose.yaml` from its `.gitignore`. All four are on `master`, none is
a worktree, and this packet's diff is eight files, every one of them inside kit
(`git diff --name-only master...HEAD`). The check reads sibling repositories'
`.gitignore` and `git ls-files`; nothing I wrote is an input to it.

It is also **not mine to fix** — four other repositories' trees are not this
packet's to edit. Recorded here rather than quietly green-washed, because a gate
that reported a red and had it dropped is a gate nobody reads.

The 6 SKIPs are `--static-only`'s own, named in the run: `lint_test.sh` and the
five docker/live tiers. The full gate's `self_test` phase is the 90-minute tier
`AGENTS.md` says to run by hand rather than report, and this packet changed
nothing it exercises.

`shellcheck -S warning` is clean on both new shell files.

## The control

```
=== THE CONTROL: an unmodified identity that scopes correctly ===
PASS control 1/1: 7 assertions against a real Postgres, 0 failures.
  the ALLOWANCE ran in the BASE phase: TestCrossTenantListOwnRowsVisible
  the SUBSTRATE was armed and bypassed:  TestTheSubstrateIsNotWhatHoldsThisLine
```

Three separate things are asserted there, and each is a way the base phase could
have been a green that measured nothing:

1. **Exit 0.** A harness that cannot see correct code is not a harness.
2. **Exactly seven `--- PASS:` lines**, counted from the runner's own output
   against the number of tests the probe declares in this recipe's `PROBE_TESTS`.
   A count is a measurement; "it exited 0" is not, because `go test` exits 0 for
   a package with no tests at all.
3. **`TestCrossTenantListOwnRowsVisible` and `TestTheSubstrateIsNotWhatHoldsThisLine`
   both appear as `--- PASS:` in the base phase**, before any mutation. A probe
   whose allowance control exists only after a breakage cannot distinguish
   "identity scopes correctly" from "the probe never ran", and a denial-only base
   phase is satisfied by a service that returns nothing to anybody.

Independently of the recipe, `adapter_install_probe` proves collection with
`go test -list` before anything asserts on the suite, and `adapter_run` refuses
any run that started zero tests — `go test -run` that matches nothing prints `ok`
and **exits 0**, so a needle that stopped matching is a green for a probe that
asserted nothing. Both were exercised during development, not just written: a
compile error in the probe's first draft was caught by the collection guard as a
**hard failure naming the compile error**, not as a zero.

## The six breakages

Every anchor was counted against `identity/internal/accounts/store.go` **before**
the recipe was written. `edit` refuses an anchor that does not occur exactly once
and prints the count, so a stale recipe dies loudly rather than reporting "stayed
green". All six report **1**.

All six are in `internal/accounts/store.go`, in six different functions, and all
six are applied and reverted one at a time.

| # | line | function | anchor text | breakage | caught by |
|---|---|---|---|---|---|
| 1 | **312** | `Store.Members` | `WHERE a.id = $1` | → `WHERE a.id = $1 OR true` | `cross_tenant_probe_test.go:269` — *A's member list carries B's account `b140f4ef-…`: the list query's account predicate is not doing anything* |
| 2 | **303** | `Store.Members` | `func (s *Store) Members(ctx context.Context, q db.Querier, accountID id.UUID) ([]MemberSummary, error) {` | pins `accountID = id.UUID{15: 1}` | `cross_tenant_probe_test.go:248` — *THE ALLOWANCE, and it is the arm a broken bind fails: A's own member list is empty. An empty list is a bind that resolves to nothing, not an isolation.* |
| 3 | **286** | `Store.Member` | `const query = ` `` `SELECT ` `` ` + membershipColumns + ` `` ` FROM account_users WHERE account_id = $1 AND user_id = $2` `` ` `` | `AND` → `OR` | `cross_tenant_probe_test.go:289` — *A fetched B's membership (account `6cc79eac-…`, user `5b2e46d7-…`) by id: the membership lookup is not scoped to the caller's account* |
| 4 | **370** | `Store.SetRole` | `\t\tWHERE account_id = $1 AND user_id = $2` | `AND` → `OR` | `cross_tenant_probe_test.go:309` — *A changing a role on B's membership: got `<nil>`, want `ErrNotAMember`* |
| 5 | **386** | `Store.RemoveMember` | `` \t\t`DELETE FROM account_users WHERE account_id = $1 AND user_id = $2`, `` | `AND` → `OR` | `cross_tenant_probe_test.go:332` — *A removing B from an account: got `<nil>`, want `ErrNotAMember`* |
| 6 | **593** | `Store.RevokePendingInvitation` | `WHERE id = $1 AND account_id = $2 AND accepted_at IS NULL AND revoked_at IS NULL` | → `WHERE id = $1 AND (account_id = $2 OR true) AND …` | `cross_tenant_probe_test.go:354` — *A revoking B's invitation: revoked 1, got `<nil>`; want 0 and `ErrInvitationNotFound`* |

Breakage 2 is the one a grep cannot see and the reason the allowance is a test
of its own: the word `account_id` is still spelled correctly on line 312, the
predicate is present, and **every denial stayed green**. It pins to a **non-zero**
UUID deliberately — `Members` refuses the zero value in its own `IsZero` guard, so
pinning to zero would have measured the guard instead of the bind.

Breakage 6 is on a **different table** (`account_invitations`, not
`account_users`) on purpose: a boundary held on one and dropped on the other is
an ordinary outcome, and a recipe that only ever breaks one function cannot claim
a service scopes correctly.

`go vet`, `golangci-lint` and identity's own `internal/tenancy` suite are blind to
all six. They assert the **substrate**; none of them asserts these clauses.

## What changed in the README

Only the language list, and only what the list says.

- `Exactly one adapter exists: elixir.sh` → **two: `elixir.sh` and `go.sh`**.
- `Go (identity, guard)` → **`TypeScript (cafaye-ts, guard)`**. **`guard` is not
  Go.** Measured: 44 `.ts` files (excluding `node_modules`), 0 `.go` files, no
  `go.mod`.
- The unproven count drops **five → four**, and it drops for two reasons rather
  than one: Go became proven, and one of the entries was never a Go service.
- The claim block now reads *proven for Elixir and Go … four languages remain
  unproven*, and names all four.
- The heading said "five languages from here" and now says four, because a
  document that contradicts itself two paragraphs later is worse than one that
  was wrong once.

## Decisions that were mine, and what I rejected

**1. The probe connects as a SUPERUSER. This is the load-bearing decision.**
Postgres exempts a superuser from row-level security unconditionally, whatever
`FORCE` says. So on this connection every denial in the probe is caused by
identity's own `WHERE account_id = $1` and by nothing else.
*Rejected:* connecting as `identity` or `identity_app`, which is what a
production deployment looks like — all six breakages would then have stayed green
on a tree with every predicate removed, and the harness would have been a second,
worse measurement of the substrate `tests/tenancy_test.sh` already proves. *This
is measured, not argued:* the six reds are only possible because the substrate is
not in the connection's path, and `TestTheSubstrateIsNotWhatHoldsThisLine` asserts
that — with `cafaye.begin_account` called, so it fails both if the substrate
starts scoping **and** if the probe ever stopped arming it.

**2. The store, not the router.** *Rejected:* driving `internal/httpapi`. The
harness's subject is the query layer, and the router adds middleware, a session
credential and a status-code question without changing what any of these five
statements can see. *Also rejected:* driving `accounts.Service`, which would have
brought business rules (last-owner checks, invitation TTLs) into the measurement.

**3. The probe lives in its own package, `internal/kitprobe`.** *Rejected:*
`internal/accounts`, which is the package the mutations recompile — a mutation's
compile failure would then be entangled with the probe's.

**4. Provisioning the login role in `adapter_migrate`, and nothing else.**
*Rejected:* editing the harness (forbidden, and wrong — the seam exists);
hardcoding `identity_app` (a second statement of a fact `protect_table` already
states, free to diverge); seeding the role from the probe (`adapter_migrate` runs
before `adapter_install_probe`); a local `psql` (a machine dependency the
harness does not otherwise need — it already died unless docker is present, and
the postgres image carries `psql`); editing identity (the packet's rule, and the
migration is correct for its own cluster). The container name is **derived** from
`KIT_TENANT_WORK`, which the contract grants, because the contract does not grant
the session.

**5. The sixth breakage is on another table, not a second function on the first.**
*Rejected:* `RevokePendingInvitations` (the batch revoke) — the same statement
shape as the single revoke, so it would have proven less.

**6. A separate recipe rather than a parameterised one.**
`reports/tenant-isolation-harness/mutations.sh` is untouched. *Rejected:* adding
a language parameter to it, which is the same fork by another route — an Elixir
recipe carrying a Go anchor list is a file whose two halves have nothing in
common.

## A finding, reported rather than fixed

**The substrate a migration installs can depend on infrastructure outside the
migration.** `identity/migrations/00016_account_isolation.sql` calls
`cafaye.protect_table('account_users')` with **one** argument. That function
computes `login_role := coalesce(p_login_role, current_user || '_app')` and then
**raises** unless such a role already exists and can log in. Against the
harness's bare `postgres:17`:

```
ERROR:  cafaye.protect_table(account_users, postgres_app):
        postgres_app is not a LOGIN role on this cluster.
```

The hint the migration ships with names the provider — *"kit's cluster provisions
`<service>` and `<service>_app`"* — so a harness that brings up a bare Postgres
**cannot apply identity's own migrations at all**. `adapter_migrate` provisions
that role and nothing else: no table, no policy, no column. It is not the
"hand-written schema" the adapter contract forbids, because a LOGIN role is not a
schema and is exactly what the migration's own error message asks for. The name
is derived **by the database**, with the same expression `protect_table` uses, so
the adapter cannot become a second, divergent statement of it.

Two readers of this repository should know it: anyone bringing up a service's
migrations outside kit's cluster will hit this, and the migration's dependence on
a role kit's init script creates is invisible from the migration file alone.

## What is STILL unproven after this packet

**Four of six fleet languages have no cross-tenant proof whatsoever** — Ruby
(`cafaye-rb`), TypeScript (`cafaye-ts` and `guard`), Python (`cafaye-py`) and
Rust (`darkroom`). Nothing in this packet says anything about them, and their
absence from the unproven list's *reasons* is not progress: they are on it
because nobody has built an adapter, not because a measurement put them there.
**Even for Go the claim is narrow, and the narrowness is not a formality.**
identity spells an account predicate in fourteen places — thirteen
`account_id = $N` and one `a.id = $1` — and this packet plants a breakage in
**five** of them. Nine are unexercised: `CountOwners`, `RevokePendingInvitations`
and `classifyUnrevocable` in `internal/accounts`, all three in `internal/apikeys`,
`internal/admin`, and both in `internal/oidc`. The harness proves that five
statements scope themselves; it does not prove that identity scopes, and a
predicate dropped from any of the other nine would be caught by nothing here.
The measurement is also taken at the **store**, so an IDOR introduced purely in
the HTTP layer — a handler passing the wrong account id, a route with no row in
`accountRouteScopes`, the authorization matrix — is outside it. And the substrate
half is not re-proved here at all: that is `tests/tenancy_test.sh`, and this
packet deliberately measured the two halves **separately**, which means this
packet says nothing about whether they hold *together* in a deployment. The honest
sentence after this packet is "cross-tenant isolation is proven for Elixir and Go,
on services that scope correctly", and the part of it most likely to be
over-read is the part about which *statements* were exercised.