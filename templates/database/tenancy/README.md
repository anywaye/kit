# `templates/database/tenancy/` — the account boundary, enforced by Postgres

> The substrate a service applies once, the assertion set that proves it works, and
> the two roles between them. Read
> [`../README.md`](../README.md) first for the cluster-level boundary: this
> directory is the OTHER one — inside one service's own database, between two
> accounts of the same customer.

## What this is

Two roles, one GUC, one function that protects a table, one sweep that says
whether the service is still isolated, and one assertion set that proves all of
it.

```
substrate.sql     apply once, as the OWNER role.  the identity seam,
                  protect_table/2, the credential seam
                  (protect_credential_table/3, begin_credential/1,
                  current_credential_digest/0), the credential audit, and the
                  sweep.
assertions.txt    the manifest. What the proof is supposed to assert, by name.
isolation.sql     the assertion set. Run it; it answers with one row per
                  assertion, and a driver compares the NAMES against the manifest.
advisor.sql       the DATABASE grading itself. Load it; call
                  cafaye.advisor_findings(); it answers with one row per
                  finding, each naming a rule, the object it fired on, and the
                  SQL that fixes it.
README.md         this file.
<lang>/tenancy_test.*   six drivers, one per language, that run the assertion
                  set and check it against the manifest.
```

The drivers live in `templates/database/<lang>/` rather than here because a
service copies `templates/database/<lang>/` — that is where its connection config
lives, and the tenancy test goes beside it.

## The two boundaries, and why this is the second

| | what it stops | how |
|---|---|---|
| `templates/database/README.md` | service A reading service B | one database and one role per service, and `REVOKE … FROM PUBLIC` |
| this directory | account 1 reading account 2 | row-level security on every account-scoped table, forced |

Measured, on the cluster kit ships, both directions:

```
$ psql -U courier -d billing -c 'select * from deliveries;'
FATAL:  permission denied for database "billing"          # refused before a query is parsed
```

```
# as courier, carrying a DELIVERY row's account id, on a table whose policies are in place
select count(*) from deliveries where account_id = '…beta…';   ->  0
```

The second is what this directory exists for, and the first is what it exists
*beside*: a fleet where one cluster holds nine databases and every one of them
holds many accounts has two boundaries, and the inner one was the one nobody had.

## Adopting this

1. Copy `substrate.sql` and `isolation.sql` and `assertions.txt` into your
   migrations and your test fixtures, and call `cafaye.protect_table` from the
   migration that creates each account-scoped table:

   ```sql
   select cafaye.protect_table('assets');
   ```

   That is the only call **for an ordinary account-scoped table**. There are two
   others and neither is a weaker version of this one — each protects a table
   whose access path this predicate cannot express, and each has its own step
   below: `protect_credential_table` (step 6) for a table resolved by an
   unguessable value, and `protect_membership_table` (step 7) for a table that
   MAPS people to accounts. There is no fourth, and in particular no
   `protect_table_lite`: a template that offers one is a template the weaker one
   gets chosen from.

2. Point your application at the **`<service>_app`** role rather than
   `<service>`. `templates/compose/postgres/initdb/10-cluster.sh` provisions both
   and grants the first to the second, so impersonating the weaker role works and
   the reverse membership does not exist. A service that has not adopted these
   templates is unaffected: `<service>` is unchanged and still owns everything it
   always did.

3. Call `cafaye.begin_account/1` once per request, inside your transaction, from
   whatever already authenticates the request:

   ```sql
   begin;
   select cafaye.begin_account($1);   -- the account your token resolved to
   select * from assets;              -- scoped, whether or not the query says so
   commit;
   ```

4. Copy `templates/database/<lang>/tenancy_test.*` beside `isolation.sql` and
   `assertions.txt` in your test tree, and make sure your gate demands the tier:
   `REQUIRED_DB=1`. The driver turns a missing `TEST_DATABASE_URL` into a
   **failure** rather than a skip, because a skip here is a green run that
   proved nothing.

5. Keep your queries' own `where account_id = ?`. RLS is defence in depth, not a
   licence to delete the predicate: the predicate is what makes the query
   indexable, and core's `tenancy.yml` still requires it. **This directory does
   not change core's `schemas/tenant-isolation.schema.json`** — the declaration
   half already existed and is unaffected.

6. **If a table is resolved by an unguessable value** — an API key, an invitation
   token — call `cafaye.protect_credential_table('<table>', '<digest_column>')`
   *instead of* `protect_table`, and open the resolution with
   `cafaye.begin_credential($1)` in the same transaction as the lookup. One call,
   same size as `protect_table`'s, and it is not an extra step: without it every
   scoped credential in the service authenticates as 401 "not found". Read
   [the section below](#the-third-trap-a-credential-table-cannot-be-scoped-by-an-account-it-does-not-have-yet)
   first, including the list of what it cannot do.

7. **If a table maps people to accounts** — a membership table, `account_users` —
   call `cafaye.protect_membership_table('<table>', '<user_column>')` *instead of*
   `protect_table`, and open the caller with `cafaye.begin_user($1)` in the same
   transaction as the lookup. Same size, same shape, same protections; the only
   thing it adds is a fifth `for select` policy predicated on the CALLER rather
   than on an account. Read
   [the section below](#the-fourth-trap-a-membership-table-cannot-be-scoped-by-an-account-the-caller-is-not-yet-in)
   first, because "nothing here breaks, it just always returns empty" is not a
   failure any test in your suite will notice.

## THE THIRD TRAP: a credential table cannot be scoped by an account it does not have yet

A **credential table** — `api_keys`, `account_invitations`, `oidc_clients` — is
scoped by an account like every other table, and it still does not work. Its access
path is *"find the row by an unguessable value and learn the account from it"*, so
the account is **what the query is for**, and a query cannot be scoped by the thing
it is trying to compute. `identity` measured this against its real protected
`api_keys` table, as the OWNER:

| | rows seen |
|---|---|
| **no identity — the state a request presenting a scoped token is in** | **0** |
| identity = the credential's own account | 1 |
| identity = another tenant's identity | 0 |

The first line is the finding. A request presenting `cafaye_…` has not resolved
the token yet, so it has no account, so the lookup authenticating it reads nothing,
`ErrNoRows` becomes "not found", and the HTTP layer answers **401**. Every machine
credential, refused as though it did not exist — the quietest possible failure, and
one a green suite cannot see, because a test fixture built with `LIKE … INCLUDING
ALL` has no policies at all.

### The mechanism: one policy whose qualifier is the digest you presented

```sql
select cafaye.protect_credential_table('api_keys', 'token_digest');
```

One call, the same size as `protect_table`'s. It protects the table exactly as
`protect_table` does — same four policies, same `ENABLE`, same `FORCE`, same index
on `account_id` — and then adds a fifth:

```sql
create policy api_keys_cafaye_resolve on api_keys
  for select to <owner>, <service>_app
  using (token_digest = (select cafaye.current_credential_digest()))
```

and the caller opens the resolution the way it opens the account:

```sql
begin;
select cafaye.begin_credential($1);          -- the digest it already computed
select … from api_keys where token_digest = $1;   -- the row returns
commit;                                     -- the digest expires with it
```

The caller passes the value it was going to query with anyway. Postgres is given a
string to compare against a column: it never learns the secret, never learns how it
was derived, and gains no ability to compute one.

**The predicate is in the policy, not only in the caller's query, and that is the
whole design.** Policies combine permissively, so a policy that merely said *"a
credential session may select this table"* would be the defect: a table-wide
`SELECT`, and every key in the database browsable with the one query this mechanism
exists to prevent. So the honest semantics are:

> **A resolution session may read exactly the credential row whose digest it
> presented, and nothing else in the database.**

`select * from api_keys` inside one of these sessions returns **that one row**.
Every other table reads zero rows.

### What it cannot do — all five, so nobody finds them

1. **It cannot tell a secret from a label.** It widens a read to the row whose
   value you presented; whether that value is *unguessable* is the service's
   knowledge, not the substrate's. On `oidc_clients`, where `client_id` is an
   identifier rather than a secret, **this is the wrong mechanism** — do not apply
   it there on the strength of the invitation case. The invariant that keeps this
   from becoming a general bypass is exactly the limitation: *you can only widen a
   read to a row you could already name.*
2. **It cannot write.** `for select`, and no write counterpart: a resolution session
   meets the ordinary write policies, whose `with check` still demands an account
   identity. A service cannot mint a credential while resolving one.
3. **It does not open any other table.** It is a policy on one named table.
   `account_users` still reads zero rows.
4. **It is a second GUC.** `begin_credential/1` is transaction-local for the same
   reason `begin_account/1` is — the six drivers hold pools, and a session-level
   digest survives the pool and hands one resolution's credential to the next
   connection. It is set in exactly one function, so a service has exactly one
   place that writes it.
5. **It is not audited at runtime, and does not claim to be.** The digest is
   transaction-local and leaves nothing behind. What *is* auditable is the scope:

   ```sql
   select * from cafaye.credential_tables();
   --  table_schema | table_name | digest_column
   ```

   which answers *"which tables in this database can be read with no account"* in
   one query rather than by searching the source. It reads the policies, not a
   list, so it cannot be satisfied by a mechanism that records nothing.

   **It answers the same to every role that asks**, which is a property it had to
   be given rather than one it has by default. `pg_get_expr` deparses a name
   unqualified whenever the *reader's* `search_path` resolves it, and `"$user"` is
   a search_path entry — so an audit written against the rendered policy text
   returns everything to the owner's role and **nothing at all** to the cluster's
   admin role, whose `"$user"` schema is the `cafaye` schema itself. "This database
   has no credential path" is the most expensive sentence in this file to be wrong
   about, so the function resolves the digest function and the column it is
   compared against from `pg_depend`, which records them as OIDs, and
   `tests/tenancy_test.sh` reads it as three roles and requires one answer.

### What it was instead of, and why — `DECISIONS.md` (MD24)

- **A `BYPASSRLS` role.** This is Supabase's answer, and it is right for Supabase's
  topology: `service_role` is created `nologin noinherit bypassrls`, granted only
  to `authenticator`, and holds **no policies of its own** — what bounds it is who
  may assume it and what it has been granted. kit has neither half of that
  structure: there is **one** per-request role and no separate service layer, so a
  bypass role here is a bypass over the whole service database, held by the role
  every request already authenticates as. Read the reference; do not copy the shape.
- **A `SECURITY DEFINER` function.** Does not work under `FORCE` — `FORCE` applies
  to the *definer*, and only `BYPASSRLS` skips RLS. A proposal of this shape is
  the `BYPASSRLS` option wearing a friendlier hat.
- **Dropping `FORCE` on credential tables.** The table above, on the one table
  holding every machine credential.
- **Leaving `api_keys` unprotected.** The boundary stops covering credentials.

## THE FOURTH TRAP: a membership table cannot be scoped by an account the caller is not yet in

A **membership table** — `account_users`, anything shaped like "which people
belong to this account" — is an ordinary account-scoped table and it is the one
table whose most important query is *not* about an account. `protect_table`'s
predicate answers "which of this table's rows belong to the account I am standing
in". That is true, useless, and exactly wrong for the first question a product
asks a signed-in person:

> **which accounts am I in?**

Measured against identity's real `account_users`, as the OWNER, with the
membership row present:

| | rows seen |
|---|---|
| **no account identity — the state every caller is actually in** | **0** |
| identity = one of that person's own accounts | 1 |

The first line is the finding, and it is worse than the credential one rather than
the same. Nothing is denied: the query succeeds, the join is correct, the
membership row is in the database, and the answer is an **empty list**. The
product then renders "you are not a member of any account" to a user who owns one.
`GET /v1/accounts` returned `[]` while every assertion in the suite was green —
the credential trap is loud (a 401) and this one is silent, because "denied" and
"you have nothing" are the same HTTP response and the same empty state.

### The mechanism: one policy whose qualifier is who is asking

```sql
select cafaye.protect_membership_table('account_users', 'user_id');
```

and, in the same transaction, before the query:

```sql
select cafaye.begin_user($1);   -- the users.id your session resolved to
```

One call, the same size as `protect_table`'s. It protects the table exactly as
`protect_table` does — same four policies, same `ENABLE`, same `FORCE`, same
`account_id` index, same role check — and then adds a fifth `for select` policy
whose qualifier is the caller:

```sql
create policy account_users_cafaye_members on account_users
  for select to identity, identity_app
  using (user_id = (select cafaye.current_user_id()));
```

So the table answers both questions it has: *your account's members* (the four
account policies, and a caller standing in an account has one) and *your
memberships* (this one, and a caller who has not chosen an account yet does not).

### What it cannot do — all three

1. **It does not let you write.** The fifth policy is `for select` and nothing
   else. An insert still meets the ordinary `with check`, which demands an account
   identity, so naming yourself is not the ability to add yourself to an account.
   `membership/discovery-cannot-write` asserts this on every run, as both roles.
2. **It does not read another table.** A fifth policy on ONE named table is the
   whole mechanism. `membership/discovery-does-not-open-another-table` asserts
   that a discovery session reads zero rows from every other protected table —
   the ambient-bypass check, and the assertion a `BYPASSRLS` role or a
   table-wide predicate fails while the other eleven pass.
3. **It does not make you a member of anything.** `user_id = current_user_id()`
   is a filter, not a grant: it answers "is this row mine", never "may I have this
   row". Every write still goes through the account policies, which is where the
   account's own membership rules live.

### It is a second audit, and deliberately not an extension of the first

`cafaye.membership_tables()` answers "which tables in this database can be read
with no account because of WHO IS ASKING", and it is a separate function rather
than a parameter of `cafaye.credential_tables()`. One query answering both would
report a membership table as resolvable by anybody who guesses a digest, and that
is the same conflation this directory refuses everywhere else — two different
exemptions are two different claims about who may read what.

Both audits read the **policies** rather than a list (so a mechanism that records
nothing cannot satisfy them) and read them through `pg_depend` rather than
`pg_get_expr` (so the answer does not depend on the reader's `search_path` —
`tests/tenancy_test.sh` measures all three roles and requires the answers to be
equal *and* non-empty, for each audit, with a control proving the reader-dependent
rendering is still live on this cluster).

### What it was instead of, and why

- **A `SECURITY DEFINER` reader.** `FORCE` applies to the definer, so this does
  not work either — and it would be the same bypass MD24 already rejected, with a
  membership-shaped hat.
- **Dropping `FORCE`, or exempting the login role.** Not an account boundary any
  more, a convention.
- **A predicate of the form "a caller may read their own memberships"** — with no
  way to say WHICH caller. That reads every membership row in the fleet, which is
  the reason the scope had to be a third transaction-local GUC rather than a
  fourth boolean.

## THE TRAP: `FORCE ROW LEVEL SECURITY`

Postgres exempts a table's **owner** from its own row-level-security policies.
`ALTER TABLE … FORCE ROW LEVEL SECURITY` removes that exemption, and
`protect_table` issues it.

Without it, a service that has shipped policies, enabled RLS, and declared victory
is **silently wrong on exactly the tables it owns** — which, in this fleet, is all
of them, because every service runs its migrations as its own role and so owns
every table in its database. Measured on this kit, a protected three-row table,
read as the owner carrying another tenant's identity:

| | rows returned |
|---|---|
| with `FORCE ROW LEVEL SECURITY` | **1** — its own |
| without it | **3** — every tenant's |

It is not in Supabase's row-level-security guide, and **no lint anywhere in this
fleet checked for it** before this directory existed (verified across all nine
account-scoped services: zero occurrences of `ROW LEVEL SECURITY`, zero
`CREATE POLICY`). `tests/tenancy_test.sh` deletes the FORCE statement and requires
the assertion set to go red — and requires the red to be on the **owner** half
only. That specificity is the point: the login half passes on a substrate with no
FORCE at all, so an isolation suite written only against the application role
proves nothing about it.

## THE OTHER TRAP: `(select …)` costs nothing to get right

```sql
using (      cafaye.current_account_id() = account_id )      -- per ROW
using ( (select cafaye.current_account_id()) = account_id )  -- per STATEMENT
```

Postgres hoists an uncorrelated scalar subquery into an **InitPlan** and evaluates
it once per statement; a bare call is evaluated once per candidate row. Measured
by `tests/tenancy_test.sh` on every run, five rows and one query:

```
(select …) wrapped:  1 call
bare call:           5 calls
```

Same policy, same rows, order-of-magnitude difference on any account-scoped table
that is more than a handful of rows. `protect_table` only writes the wrapped form,
`isolation.sql` asserts it structurally (both forms return identical rows, so no
denial can detect it), and the measurement above is what stops that assertion
being a comment.

## What the assertion set asserts, and why it is four and not one

The shape, run **twice** — once as the `<service>_app` login role and once as the
owner:

| assertion | expected |
|---|---|
| `no-identity-reads-no-rows` | a request with **no** account set reads **zero** rows |
| `another-tenants-rows-read-as-none` | a request with **another tenant's valid** identity reads **zero** of that tenant's rows |
| `own-rows-are-visible` | a request with **its own** identity reads **its** rows |
| `own-identity-reads-only-its-own-rows` | …and an unqualified read returns only its own |

A test that asserts only the first is satisfied by a table with no policy at all,
which is the bug. A test that asserts only the third is satisfied by a policy that
permits everything. Only the four together are the property — and the reason the
owner half is separate is that those four pass on a substrate with no FORCE.

Around them, twenty more: the write side (each denied write paired with a read
proving the row is intact, because a `using` denial raises nothing and "matched
zero rows" is only a proof once you can see the row), the three refusals that make
the login role's non-ownership real, two assertions about how the policies are
*written*, and three about the sweep — **one of which is the sweep's positive
control**, because an empty sweep result is otherwise satisfied by a sweep that
reports nothing.

And **fifteen more for the credential half**, which is the same dual-role shape
over the one table whose access path is *"find the row by an unguessable value and
learn the account from it"*: six per role — no resolution context reads nothing, a
resolution by digest works **with no account identity at all**, the resolution
**cannot browse**, a digest you did not present resolves nothing, it **does not
open another table**, and it **cannot write** — plus three that no denial can see,
which are the audit query naming the table, the resolve policy naming its roles,
and the resolve policy being written wrapped.

And **fifteen more for the membership half**, which is the same dual-role shape
over the one table whose subject is the CALLER rather than a row: six per role —
no caller context reads nothing, a discovery works **with no account identity at
all**, the discovery **cannot browse**, somebody else's memberships resolve
nothing, it **does not open another table**, and it **cannot write** — plus three
that no denial can see, which are the audit query naming the table, the discover
policy naming its roles, and the discover policy being written wrapped.

That half is here for the **opposite** reason to the credential one. The
credential half proves a path that would otherwise be closed was not left closed;
the membership half proves that a query which was correctly closed was not left
**inexpressible**. Its first row is satisfied by a substrate with no mechanism at
all — which is exactly the state `identity` shipped in, where every denial was
green and `GET /v1/accounts` answered `[]` to an owner. Two of its rows are the
ones a permissive implementation fails: `discovery-cannot-browse` needs a fixture
where the caller's rows and the table's rows are different sets, and
`discovery-cannot-write` is what keeps the mechanism a discovery rather than an
authorisation.

Two of those fifteen are the ones a permissive implementation fails.
`resolution-cannot-browse` is satisfied by nothing except a policy carrying the
digest predicate, and it needs a credential fixture with **two** rows: with one,
"the table" and "that row" are the same set and a table-wide `SELECT` passes it.
`resolution-does-not-open-another-table` is satisfied by nothing except a mechanism
scoped to one table — a `BYPASSRLS` role returns `probe_things`' rows from inside a
resolution session, which is the ambient bypass this directory exists to prevent.

`assertions.txt` is the manifest, and every driver compares the names it got back
against it **in both directions**. A count would not do: 54 is compatible with 54
of the wrong 54.

## Cross-tenant access is absence, not refusal

`cafaye.current_account_id()` returns NULL when no account has been set, so every
policy reads zero rows rather than raising. A `403` tells an attacker the id
exists; `nil`/`[]`/an empty result tells them nothing. This is core's D33
(`core/docs/tenancy.md`) arriving from the other end, and the one place a
synchronous error is correct is `insert`, whose policy has no `using` to filter
with and whose `with check` therefore returns `42501` — about the INSERT, not
about the account.

## Two consequences to know before the first migration runs

1. **The owner reads zero rows from a protected table until it sets an identity.**
   `FORCE` removed its exemption and no policy names it without one. That is the
   correct posture and it is the adoption cost: a migration that backfills rows
   sets the identity (`set local role <service>_app; select
   cafaye.begin_account(…)`) and reads exactly one account's rows. It fails loudly
   and immediately, which is the good direction.

   **It does not get better with a `SECURITY DEFINER` function**, which is the
   natural next thought and is wrong: `FORCE` applies to the **definer** too, so a
   function owned by the table's owner is subject to that table's policies and
   reads zero rows as well. Only `BYPASSRLS` skips RLS, and no service role has
   one. The identity is the whole answer.

2. **`begin_account/1` is transaction-local.** Outside an explicit transaction it
   expires at the end of the statement that set it, so a caller reaching the
   database in autocommit reads zero rows. That cannot leak and it is loud.

## What the advisor is for, and what it is not

`isolation.sql` and the six drivers ask **does the boundary HOLD**. `advisor.sql`
asks the other question — **are these policies WRITTEN correctly** — and it is the
only file here that can ask it.

Every assertion in `isolation.sql` is satisfied by a policy that permits
everything. A permissive predicate RETURNS ROWS, so a denial cannot tell
"permitted because the predicate said so" from "permitted by accident". The same
applies to a policy that is simply *inert*: `policy_exists_rls_disabled` is a table
whose policies exist and whose `relrowsecurity` is false, and it reads as correct
in review. Nor can a file scanner see that two permissive policies on one
(table, role, command) combine with **OR** and the table is wider than either
reads on its own.

Eight rules, all run by `tests/tenancy_test.sh` against a real cluster:

| rule | level | what it finds |
|---|---|---|
| `policy_exists_rls_disabled` | ERROR | policies that exist and enforce nothing |
| `rls_disabled_in_public` | ERROR | no RLS on a table a login role can `SELECT` |
| `rls_policy_always_true` | WARN | a permissive qualifier that is always `true`, or a NULL clause on a permissive write |
| `rls_references_user_metadata` | ERROR | a policy deciding access from rows **the caller can write** |
| `multiple_permissive_policies` | WARN | more than one permissive policy per (table, role, command) |
| `login_role_security_definer_executable` | WARN | a `SECURITY DEFINER` function the login role can run |
| `auth_rls_initplan` | WARN | an identity call not wrapped in `(select …)` |
| `rls_enabled_no_policy` | INFO | RLS on with no policy: nothing leaks, nothing is readable either |

Two of those need their reasoning read rather than skimmed.

**`rls_references_user_metadata` is the reason the rule earns `ERROR`.** The
original rule — the one this is ported from — is that
`auth.users.user_metadata` is editable by the end user, so a policy consulting it
consults something the user controls, and the original *admits it cannot do better
than a string match*. This one does better on the half that matters: Postgres
records a policy's dependencies, so "does this predicate read a table a login role
may `INSERT` or `UPDATE`" is a question about `pg_depend` and not about the text.
A service keeping a `profile_flags` table and writing `using (exists (select 1
from profile_flags f where f.is_admin))` has built its own `user_metadata`; the
word `user_metadata` appears nowhere in it. The keyword half is kept too, caveat
intact, so the rule is the original's findings and one more.

**`multiple_permissive_policies` and MD24.** A credential table carries FIVE
policies, so `(api_keys, <owner>, SELECT)` holds two permissive ones *by design* —
that is the mechanism, and they combine as
`(account_id = the session's account) OR (token_digest = the digest presented)`.
The rule stays at `WARN` and unsoftened, and the exemption is **its own semantics**:
a (table, role, command) group is exempt when **every** policy in it was written
by the substrate. That is an all-of condition, so a hand-written sixth policy on
`api_keys` is not exempt — and `tests/tenancy_test.sh` plants exactly one and
requires the rule to fire and name it. An allowlist of policy *names* would have
been a ratchet instead of an exemption.

## What this does not prove

- **That a policy's predicate is the RIGHT predicate.** The advisor finds `true`,
  and it finds a table the caller can write. It cannot tell a policy that is
  subtly too wide from one that is exactly right, because "right" is a property of
  the service's data model and no catalog holds it.
- **That the login role is not a member of the owner role**, that it holds no
  `BYPASSRLS`, and that a protected table's `FORCE` is set. `advisor.sql` has no
  rule for the last one **on purpose**: `unprotected_tables()` names it and
  `isolation.sql` asserts it by RUNNING the denials as the owner, because a
  catalog reading can be satisfied by a table nobody reads. One file claiming all
  three would mean one file where a reader looks for the proof and finds a column.
- **That a service sets the identity.** `begin_account/1` is one call in one place
  and nothing here can tell a service that never calls it from one that calls it
  in every request. A service that forgets reads zero rows: safe, and extremely
  visible.
- **That a table is account-scoped.** The sweep defines that as "has an
  `account_id` column", which is the fleet's vocabulary (core's D7) and misses a
  service that spells it `tenant_id`. A service holding no customer rows is core's
  **honest zero** and needs none of this.
- **That a schema the substrate was never applied to holds no account-scoped
  table.** The sweep's scope is the schemas `protect_table` protected, plus
  `cafaye` and the session's temporary schema, so customer rows in a schema no
  `protect_table` call named are outside it. The alternative — a whole-database
  scan — was measured on `identity` and it reports **every other test's fixture
  schema**: its test helper clones tables with `LIKE … INCLUDING ALL`, which does
  not copy row-level security, so a correct database produced a red proof and the
  count moved with how many neighbours were mid-flight. A sweep that cannot stay
  green on a correct database is one an adopter works around rather than reads.
- **That the six drivers run.** kit's gate PARSES them and runs the assertion set
  they run; executing each driver needs that language's driver library resolving,
  which is a service's gate's job. The drivers are deliberately thin, which is
  what makes the residual gap small.
- **That the login role is not a MEMBER of the owner role.** The cluster grants
  `<service>_app` TO `<service>` so a proof can impersonate the weaker role; the
  reverse membership would undo the whole design and is asserted where it can be
  — `tests/tenancy_test.sh` checks the cluster's direction, and a service's own
  membership is its `tenancy.yml`'s business.