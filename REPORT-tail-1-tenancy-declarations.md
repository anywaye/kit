# TAIL-1 — the honest zeros the fleet-wide check now names

**Verdict: all three repos the sweep named are declared and green.**

```
$ bash core/harness/bin/tenancy-check <repo>
kit          0 failure(s), 3 warning(s)
website      0 failure(s), 2 warning(s)
oauth-stub   0 failure(s), 1 warning(s)
$ bash tenancy-check pantry        # was already declared — see §4
pantry       0 failure(s), 2 warning(s)
```

Commits (one per repo, none merged, none pushed):

| repo | worktree | branch | commit |
| --- | --- | --- | --- |
| kit | `wt/kit-ta1` | `broker/kit-ta1` | `f5017d8` |
| website | `wt/site-ta1` | `tail-1/site-tenancy` | `0ce0742` |
| oauth-stub | `wt/oauth-stub-ta1` | `tail-1/oauth-stub-tenancy` | `d1ce4f2` |

The sweep named these repos with `tenancy.declaration-missing` because the
checker is fleet-wide and mechanical. Each declaration below is the smallest
true thing, measured against the sources rather than assumed.

---

## 1. kit — the substrate installer that owns no table

**What the checker's scan found.** `account_id` appears in code on exactly
**seven lines**, all in `templates/substrate/install.sh` (a `.sh`, which the
scanner cannot parse — every one arrives as `tenancy.enumeration-partial`
residue, so every one must be named or the zero fails). They are two shapes,
and each is vouched for in `scope.nonRowSites` with what it actually is:

- **691, 747, 756 — conductor's capability receipt.** The box redeems its
  box-bound capability at conductor's `POST /v1/capabilities/redeem` and reads
  `.capability.account_id` out of the JSON receipt: the account the
  *capability itself* is bound to — the thing the box redeems. It lands in a
  shell variable, `kit_substrate_refuse` names a receipt that carries none
  (:756), and it is never stored. A capability's own binding is not a row kit
  reads.
- **1472–1483 — kit acting as identity's own HTTP client**
  (`mint_courier_identity_token`). `POST /v1/accounts` registers this box's
  owner account; `POST /v1/accounts/${account_id}/api-keys` mints courier's
  credential. Every row is identity's, written by identity's role inside
  identity's database; kit's only handle is a shell variable and a URL path.

**The declaration.** `accountScoped: false`, `scope.sources:
[templates/substrate]` (the whole runtime code — the directory, not the file,
so a new key-carrying file under it is caught), all seven sites vouched.
`rls.sources: [templates/compose/postgres/initdb]` — the only DDL kit
executes: one database and two roles per service plus the `REVOKE … FROM
PUBLIC` sweep. It creates no table, enables no policy, forces nothing, and
kit owns no table, so `databaseEnforced: false`.

**Sites chosen NOT to be vouched — and why that is not an omission.** The
key also appears in `tests/` (real `select … where account_id = …`
statements) and `templates/database/` (`create policy` DDL). Neither is
declared, and the header says so with the measurement: `tests/` is the
tenant-isolation harness — fixtures executing **the services'** standard
against a throwaway cluster, and declaring them would force kit to declare
entry points for statements its runtime never executes, which is inventing
scoping for a repo that has none. `templates/database/` is the fleet's
standard SQL, adopted and run inside each service's own database; declaring
it in `rls.sources` would fire `tenancy.rls-undeclared` about tables kit does
not own. Docs carry the key in prose only and are not sources, as in all
three model declarations.

**Honest residue, named not hidden.** The checker's verdict is 3 warnings,
all claims about the scanner rather than about kit: `enumeration-partial`
names the seven `.sh` sites; `rls-unreadable` names
`templates/compose/postgres/initdb/10-cluster.sh:25`, which mentions
`ROW LEVEL SECURITY` in *prose* — the design note on why FORCE is a per-table
property done in `templates/database/tenancy/substrate.sql`, not a
cluster-wide act. The statements the bootstrap runs are create database /
create role / grant / revoke, and none of them is a policy.

**kit's own gate.** `mise exec -- bash tests/validate.sh` ran alone in the
background to completion: **0 FAIL rows across the log, final line
`PASS: every check passed.`**, with the honest skips reported (9: rustc and
wrangler absent, SQL parsed by the real-Postgres test, TypeScript needing a
type-stripping parser) and 5 tiers under a time bound, none reached. Caveat,
stated rather than papered over: the numeric exit code was not captured to a
file — the verdict above is read from the gate's own output. **`install.sh`
is untouched by this packet**: `git show --stat f5017d8` is one file,
`tenancy.yml`, 145 insertions — so the `SECRET RECORD` tripwire is untouched
by construction, and the gate's secret-scan phase passed with the rest.

## 2. site (`website`) — a UI over the BFF, declared like parlor

**What the checker's scan found.** `account_id` appears on **69 lines**
across `src` and `e2e` (the checker's own rule: word boundary, `//` comments
stripped, inserts skipped). Measured first: no `.sql` anywhere, no driver
imported and none in `package.json`, `src/lib/{identity,conductor,upstream}.ts`
are HTTP clients transcribing wire contracts, deploy config carries no
`DATABASE_URL`. Rows live in identity, conductor, gateway, courier and
billing — this tree holds none. So the honest zero, in parlor's shape.

**The 69 are five non-row shapes**, all named in the header: wire types
transcribed from the services' JSON contracts; prose naming conductor's
routes; test fixtures (including two deliberately hostile ones offering
another account's id to prove the client forwards it verbatim for conductor
to refuse); screens rendering rows the BFF already scoped (plus the
operator's own grant input); and the client's plumbing (response readers, URL
filter, uuid guard, React Query cache key).

**57 of the 69 are vouched** — every one in a path the schema can name, each
with its reason.

**Sites chosen NOT to be vouched: the other 12, in five files whose paths the
schema cannot express.** TanStack Start puts the route parameter in the
directory name and `PATH_PATTERN` admits no `[`, `]` or `$`, so a site under
them cannot be named in a declaration at all:

- `src/app/accounts/[accountId]/entitlement-panel.tsx:83` — a React key on a
  row conductor already returned;
- `src/app/invitations/[token]/invitation-screen.tsx:197` — a navigation
  target;
- `src/app/invitations/[token]/invitation-screen.test.tsx:83,99,124,136,163,169,355,438`
  — eight scripted identity-client stubs;
- `src/app/releases/$releaseId/release-screen.tsx:12` and
  `src/routes/releases/$releaseId.tsx:12` — two header comments naming
  conductor's releases routes.

They are excluded from the scan and named line-by-line in the header, and the
mechanism that keeps the exclusion honest is **`src/test/tenancy-declaration.test.ts`**,
ported from parlor's ratchet and adapted for website's second hole:
`scope.sources` is capped at 32 paths and the tree holds ~90 expressible
ones, so the declaration covers every key-carrying subtree plus the screens,
libraries and route subtrees around it, and the ratchet asserts the
direction that could hide a scope — a nameable key-carrying file outside the
declared surface — in full. It also re-derives the vouched set from the tree
in both directions, and holds the five-file exception to exactly five files.
Key-free uncovered files (the `src/routes` leaf wrappers, assets, config) are
tolerated and named in the header.

**Red proof.** Appending one *code* line carrying the key to a declared file
turns the ratchet's vouch test red AND `tenancy-check` red (1 failure);
restoring the line turns both green. The first probe was a `//` comment and
went red nowhere — the checker strips comments before the carries-key
decision — so it was discarded rather than reported. The ratchet's own `KEY`
constant is itself a key site inside a declared source and is vouched for as
such; that vouch is what keeps the suite from tripping its own declaration,
and the vitest run caught exactly that before the checker did.

`rls.sources: [src]` — where website's own DDL would live — and deliberately
not `e2e`, whose `docker-compose.yml` quotes the sibling's boundary in prose
and would earn a false "database half unproven" warning about a service with
no database (parlor's argument, re-measured here). Verdict: **0 failures, 2
warnings** (`enumeration-partial` names the 57 `.ts/.tsx` sites,
`scope-key-unused` is the no-SQL answer).

## 3. oauth-stub — a test double, and the smallest true thing

**What the checker's scan found: nothing.** `account_id` appears in exactly
three lines in the whole tree, all prose in
`HANDOFF-social-login-state-2026-10-05.md` (219, 228, 232). Its own README
opens with "THIS IS A TEST DOUBLE. NEVER DEPLOY IT": it impersonates Google
and GitHub as OAuth providers, has no persistence, no session store, no
signing key and no account anybody can own — `newAccount` mints a fresh
person per authorization. The word "account" in `main.go` is a struct in a
process-lifetime map (`tokens map[string]account`) that `/userinfo` answers
from by opaque token; there is no account parameter a caller can substitute
and no statement scoped by one.

**The declaration.** `accountScoped: false`; `scope.sources` is the whole
implementation, two files (`main.go`, `main_test.go`); nothing is vouched
because nothing carries the key. `rls.sources: ["."]` — the root rather than
a code file, so the database half can fail the day a `.sql` appears: the DDL
scanner reads every `.sql` and finds none, and names a non-`.sql` file
unreadable only when it carries policy/enable/force text — measured zero
hits. Verdict: **0 failures, 1 warning** (`scope-key-unused` — the honest "I
found nothing"). Note for the next reader: the first draft of the header
spelled the four grepped patterns literally, and the checker then named the
declaration itself as an unreadable DDL carrier; the sentence is hyphenated
now and the measurement is unchanged.

## 4. pantry — measured, and not a hazard

`pantry` already declares (`tenancy.yml`, key `publisher_id`,
database-enforced) and runs **0 failures, 2 warnings**. The sweep's naming of
`registry/services/parlor/cafaye.yml` is a different checker's surface: the
file is a **service manifest in the `cafaye.yml` format** (its only tenancy
mention is a comment referencing core's schema), and `tenancy_check.py` reads
exactly one path — `<repo>/tenancy.yml` at the root. A vendored manifest in a
subdirectory can never be read as this repository's declaration, so the
hazard does not exist for this checker. No action taken; no commit needed.

## 5. Handoff

- The declarations are line-pinned. An insertion above a vouched line
  silently un-declares it (the drift that bit muse's first attempt).
  website's ratchet re-derives the pins in both directions and will catch it
  there; **kit and oauth-stub have no such guard in their own suites** —
  kit has 7 pins and oauth-stub none, and adding kit's mirror of core's scan
  to `tests/` (muse's Guard 3 shape) is the obvious next packet.
- The five unnameable website files are a **core schema defect**
  (`PATH_PATTERN` cannot express a routing convention the whole frontend
  fleet uses). It belongs to TG-B1's surface, not to any service, and is
  reported here rather than worked around silently.
- Nothing was merged and nothing was pushed. The three branches are the
  relay baton.
