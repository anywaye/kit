# DECISIONS.md — the trades this repository has **not** made

> A decision document records what was **deliberately not done**, and what it
> costs. Anything here is reversible, and saying so is the point: a trade with no
> stated cost is a preference someone will re-litigate in six months with no
> evidence.

**Referenced from** `AGENTS.md`, `README.md`, `.github/zizmor.yml`,
`.github/workflows/ci.reusable.yml`, and three of the gate's own scripts. It did
not exist until kit-21, and every one of those references pointed at nothing. A
reference to a decision document that is not there tells the reader the trade was
made and then leaves them with nothing to read, which is worse than not claiming
it — the absence looks like they have not looked hard enough.
`tests/validate.sh`'s `DECISIONS.md` check asserts the file exists, records real
entries, and that every reference to it resolves.

---

## MD10 — `unpinned-uses` is counted, not baselined

**Not made:** adding zizmor's `unpinned-uses` finding to `.github/zizmor.yml`'s
ignore list, which is the one-line change that would make the finding disappear.

**What it costs:** thirty-three findings on every run, every time. They are
counted and printed by `tests/zizmor_gate.sh`, never suppressed.

**Why not:** a baseline is a trade made invisibly, in a file that looks like
routine configuration. Pinning thirteen repositories to SHAs and owning the bump
is not free — the diff would be about the pin, not about the thing the pin is
for — and *not* pinning means a change to kit's workflow lands in six services'
CI without review. Both are real costs. The trade-off is a decision, and a
decision belongs in this file rather than in a config key.

**Enforced by:** `tests/validate.sh`'s `unpinned_check`, which fails if
`unpinned-uses` is ever disabled, and `zizmor_reason_check`, which fails if any
ignore entry appears without a reason beside it.

---

## MD10a — no fleet-wide SHA pinning (superseded by MD10)

Recorded because kit-04 costed it in three options under this heading and the
surviving decision is MD10. Kept so a reader looking for the original reasoning
finds it rather than a dangling reference.

---

## MD12 — no second copy of the reusable workflow

**Not made:** mirroring `.github/workflows/ci.reusable.yml` at a convenient
subpath so the `uses:` string reads nicely.

**What it costs:** nothing, and that is the argument. GitHub documents that
subdirectories of the workflows directory are not supported, so
`cafaye/kit/workflows/ci.reusable.yml@master` resolves to nothing and every
caller who copied it has a red build. The file lives where GitHub can call it.

**Enforced by:** the `callable path` check in `tests/validate.sh`, which fails
when the documented `uses:` string and the file's real location disagree.

---

## MD13 — one secret scanner, invoked two ways (superseded by MD34)

**Not made:** a CI-only invocation with a local convenience wrapper that drifted
from it.

**What it costs:** nothing measurable.

**Why not:** a scanner whose CI invocation and local invocation have drifted is
two scanners, and the one that goes red is whichever nobody runs.

Superseded by MD34, which deletes the scanner this decision was about. The
principle is unchanged and now governs `tests/zizmor_gate.sh`, which has the
same two callers: the `zizmor` job and this repository's own gate.

---

## MD21 — **no PgBouncer. One cluster, direct connections, a stated budget.**

This is the trade kit-21 was dispatched to decide, and it is the largest one in
this file.

**Not made:** putting PgBouncer in transaction mode between the fleet and the
shared cluster.

**What it costs:**

- Nine services' connections all land on one server, so a memory-hungry backend
  in one service is a memory-hungry backend on the box. Mitigated by a per-role
  `CONNECTION LIMIT` and per-role timeouts, not prevented.
- The connection budget is a real ceiling: 200 `max_connections`, 10 per role. A
  service that genuinely needs more must raise its share in **two** places and
  say why in the PR.
- No multiplexing. A service with 3 concurrent requests and a pool of 10 holds
  connections it is not using. Free at this scale; not free at ten times it.
- We lose the standard safety valve for connection storms. If the fleet outgrows
  the budget, the answer is a pooler **plus** the per-language flags **plus** the
  `RECONNECT` step — a much bigger decision than it looks today.

**Why not, with the measurements:**

1. **The remedy for the pooler's worst failure mode is a manual operator
   command.** From PgBouncer's own configuration documentation, on
   `max_prepared_statements` (<https://www.pgbouncer.org/config.html>):

   > If the return or argument types of a prepared statement changes across
   > executions then PostgreSQL currently throws an error such as
   > `ERROR: cached plan must not change result type` … One of the most common
   > ways of running into this issue is during a DDL migration where you add a
   > new column or change a column type on an existing table. In those cases you
   > can run `RECONNECT` on the PgBouncer admin console after doing the migration
   > to force a re-prepare of the query and make the error go away.

   A migration is the single most common time this fires. Nine services, nine
   independent migration schedules, one forgotten console command each — and the
   symptom is an application error that looks like a code bug.

2. **PgBouncer 1.21 does track named prepared statements, and that does not fix
   it.** `max_prepared_statements` (default 200) makes PgBouncer track and
   re-prepare protocol-level named statements. It also states plainly that
   "this tracking and rewriting of prepared statement commands does not work for
   SQL-level prepared statement commands, so `PREPARE`, `EXECUTE` and
   `DEALLOCATE` are forwarded straight to Postgres." So the version that makes
   the standard advice sound reasonable is the same version whose documentation
   still prescribes `RECONNECT` after a migration.

3. **The per-language flags are the recurring cost, and their failure is late.**
   `prepare: :unnamed` (Postgrex), `default_query_exec_mode=simple_protocol`
   (pgx), and each language's own equivalent. A service that omits one fails only
   after a DDL migration — not at boot, not in CI, not in a smoke test. That is
   the worst possible shape: the config is wrong for weeks and the first symptom
   is a production error four layers from the thing that is wrong.

4. **Transaction pooling withdraws session state, and says so.** On
   `server_reset_query`: "When transaction pooling is used, the `server_reset_query`
   is not used, because in that mode, clients must not use any session-based
   features, since each transaction ends up in a different connection and thus
   gets a different session state." Every setting in the contract is a
   session-scoped GUC. PgBouncer's `track_extra_parameters` does not include
   `statement_timeout`, and the same page warns "Most parameters cannot be fully
   tracked this way."

5. **The arithmetic does not need a pooler yet.** Nine services × the per-role
   limit of 10 = 90, plus reserves, against a raised `max_connections` of 200.
   Postgres's default of 100 genuinely is too low for this topology — raising a
   number is a five-minute change, and a pooler is an architectural change across
   seven languages.

**How the decision stays visible:** the pooler workarounds are **forbidden** in
`templates/database/contract.json`, and the gate fails the build if one appears
in any generated config. A service carrying `prepare: :unnamed` looks correct, is
wrong, is measurably slower, and the only way anyone would notice is by looking
for the flag — so something looks for it.

**What would reverse it:** the connection budget being outgrown, or a service
whose workload genuinely needs multiplexing. Either is a real trigger, and
reversing it means changing `contract.json`, all six snippets, and this entry
together — which is why the check is a list in one file rather than six greps.

---

## MD21b — **pgvector via pglayers on a Debian base**

**Not made:** staying on `postgres:17-alpine`, which is what the stack pinned
until kit-21.

**What it costs:** the Debian base image is larger than alpine.

**Why not:** pgvector is not available on the alpine base at all. pglayers
publishes each extension as a layer built from the PGDG **Debian** packages, so it
is glibc-linked. Measured, on the alpine base:

```
$ # FROM postgres:17-alpine  +  COPY --from=ghcr.io/pglayers/pgx-pgvector:17 / /
$ psql -c 'CREATE EXTENSION vector;'
ERROR:  extension "vector" is not available
$ ldd /usr/lib/postgresql/17/lib/vector.so
Error loading shared library ld-linux-aarch64.so.1: No such file or directory
Error relocating …/vector.so: palloc0: symbol not found
```

Two independent failures, either fatal: the musl loader cannot resolve a glibc
binary, and alpine's PostgreSQL looks under
`/usr/local/share/postgresql/extension` while pglayers writes to
`/usr/share/postgresql/17/extension`. On `postgres:17` the same layer answers a
real query (`'[1,2,3]'::vector <=> '[1,2,4]'::vector < 1` → `t`).

**And the alternative was rejected too.** `ghcr.io/pglayers/pglayers-full:17` is
one line instead of four and carries 80+ extensions. It was not adopted because
it *replaces* the official `postgres` image with a community build, permanently,
for every service — and because "full" means 80 extensions and a raised
`max_worker_processes` on the cluster whether or not any is used. Composing one
layer onto the official image keeps the base official and the extension list to
the one cafaye uses.

**What this depends on:** pglayers is a community project, **not** a PostgreSQL
project. It layers onto the *official* images, which is a weaker claim than being
published by postgres.org, and it carries no PostgreSQL guarantee. That is the
real risk in this entry, and it is why the version is pinned to `17-0.8.6` rather
than tracking `17`. Note that pglayers' own README documents the pin format as
`17-v0.8.3`, which exists but is a **stale** build — the live series is `17-0.8.4`,
`17-0.8.5`, `17-0.8.6`, with no `v`.

---

## MD21c — **extensions are a cluster decision, created by the admin role**

**Not made:** letting a service role `CREATE EXTENSION` in its own database.

**What it costs:** a service needing an extension that is not in
`KIT_POSTGRES_EXTENSIONS` requires an operator to add it and recreate the
volume. That is a deliberate delay rather than a self-service path.

**Why not:** it cannot work anyway. pgvector's control file is not marked
`trusted` (a PostgreSQL 13+ classification), so `CREATE EXTENSION` by a
non-superuser is refused with `HINT: Must be superuser to create this extension`.
Verified against pglayers' layer **and** against upstream pgvector v0.8.6, whose
`vector.control` is byte-identical — so this is pgvector's own classification,
not something the packaging drops.

The shape is right anyway: an extension's binaries live in the image, so they are
available to every service on the cluster whether or not anybody creates one. A
per-service grant would only ever have governed who pays the disk cost, and that
is an operator's call.

---

## MD21d — **the boundary is `REVOKE CONNECT`, not table grants**

**Not made:** relying on "nobody granted this role SELECT on that table" as the
isolation mechanism, which is what a cluster with one database per service gets
for free.

**What it costs:** four statements per database instead of none, and a cluster
that refuses to start if they cannot be applied.

**Why not:** it fails open. Measured on the same cluster shape:

| | with the `REVOKE` | without it |
|---|---|---|
| `SELECT` on another service's table | `FATAL: permission denied for database` | `ERROR: permission denied for table invoices` |
| reach the other database at all | no | **yes** |

Without the revoke the *rows* are still protected — by the accident that nobody
granted `SELECT`. The *database* is completely open: catalog enumeration, temp
tables, visibility of other services' GUCs, and any future `GRANT` anywhere in
the cluster. One careless grant makes it fail and nothing warns you at the time.

**Enforced by:** `tests/isolation_test.sh`, whose fourth assertion builds a
**control** cluster of the same shape without the `REVOKE` and requires it to let
service A in. Without that control a check asserting "A cannot SELECT from B"
would also pass on a cluster with no isolation at all.

---

## MD21e — **the cluster's identity is not a service's to override**

**Not made:** letting a service set `POSTGRES_USER`, `POSTGRES_DB` or
`POSTGRES_PASSWORD` on the shared `postgres` service — which is what kit's own
gate recommended to every service that ran its own database, until this entry.

**What it costs:** a service that needs its own database writes one line in
`.env` instead of three in its compose file. That is not the cost; the cost is
the one below.

**Why not:** three failures, all measured on a cluster built from this
directory's `initdb/10-cluster.sh`, and only the first is the interesting one.

1. **`POSTGRES_USER` makes the overriding service a cluster superuser.** The
   official image creates that role, and it creates it as a superuser. Measured
   on a cluster built from this directory's `initdb/10-cluster.sh` with
   `POSTGRES_USER=identity` and `KIT_POSTGRES_DATABASES=courier` — that is, one
   service provisioned the supported way and one the overridden way, on the same
   cluster:

   ```
   $ psql -U identity -d identity -tAc \
       "select rolname, rolsuper from pg_roles where rolname not like 'pg\_%'"
    courier|f
    identity|t
   ```

   And the boundary stops being a boundary. `identity` reaches `courier`'s
   table:

   ```
   $ psql -U identity -d courier -tAc "select count(*) from invoices"
   2
   ```

   where `courier` reaching `identity`'s is refused **at the door**, by the
   `REVOKE CONNECT` of **MD21d**, before a single table is named:

   ```
   $ psql -U courier -d identity -tAc "select token from sessions"
   psql: error: ... FATAL:  permission denied for database "identity"
   DETAIL:  User does not have CONNECT privilege.
   ```

   That refusal is the whole of MD21d, and this override deletes it for whoever
   sets it — not for the service that set it, but for every service on the
   cluster, whose rows become readable by a role that has no business naming
   their database.
2. **`POSTGRES_USER` and `POSTGRES_DB` also stop the cluster from starting.**
   The image creates both before any init script runs, so `CREATE ROLE` /
   `CREATE DATABASE` fail, `ON_ERROR_STOP=1` (`10-cluster.sh:78`) makes that
   fatal, and it is fatal *during initdb*. Measured, exit status 3.
3. **`POSTGRES_PASSWORD` breaks neither, and is still refused.** It is the
   credential every role is handed (`10-cluster.sh:107`), so one service's file
   would choose it for all the others. Refusing it is a judgement about who owns
   a cluster-wide decision, not a claim that it is dangerous in the same way —
   and the finding kit's gate prints says exactly that, rather than dressing it
   up as one of the first two.

**The thing this entry is actually about: the advice was the defect, and prose
alone does not fix it.** The stale-copy finding and the adoption-path block both
told a service to do (1), in two places, and the second is the one printed on
every run that has findings. `identity` did it, inherited from following kit's
own instruction, and it was found by a worker doing an unrelated migration —
not by a gate, because a service that follows the advice has deleted the very
thing `check_stale_copy` looks for. Correcting the sentence without adding a
check would have left the gate blind in exactly the case the correction created.

**Enforced by:** nothing, and the honest version of that is *nothing was*. The
check was `check_override_surface` in `tests/fleet_check.py`, which read the
adopting repositories and failed one that set any of the three on the shared
cluster. It went with the rest of the cross-repo surface, so the rule above is
now advice that a service is trusted to follow rather than a control kit can
apply — which is the trade MD36 records as deliberate.

---

## MD22 — PostgreSQL 15 is the floor, and the floor is measured not assumed

**Not made:** supporting PostgreSQL 14, which is what several services ran before
kit-21.

**What it costs:** a service that cannot move off 14 has nowhere to go.

**Why not:** PG15 removed the default `CREATE` grant on the `public` schema, and
that change is what makes database-per-service an actual boundary rather than a
naming convention. On PG14 a role that is not the database owner can create
objects in a database it does not own.

**Enforced by:** the schema revoke in `initdb/10-cluster.sh` is stated explicitly
rather than inherited from a version's behaviour, and the cluster image pins a
major.

---

## Things deliberately left to the operator

- **A database added after the cluster was provisioned.** `bin/dev db grant <name>`
  prints the statements rather than running them, and prints the `REVOKE ALL ON
  DATABASE … FROM PUBLIC` among them. That is not a convenience: a database
  created outside `initdb/10-cluster.sh` gets Postgres's default, which grants
  `CONNECT` to `PUBLIC`, so **an operator who creates a database by hand and
  forgets the revoke has opened it to every role in the cluster** — a cluster
  that is now, by the accident of one omitted line, exactly the no-isolation
  cluster MD21d is about.

  This is the one part of the boundary that is genuinely operator-side, and the
  reason is worth stating rather than hiding: `docker-entrypoint-initdb.d` runs
  once per volume, so the sweep at the end of that script cannot re-apply itself
  to a database that does not exist yet. There is no way to make this airtight
  from inside the init script — the only fully automatic version is a periodic
  sweep over `pg_database`, which is a scheduled job and a new thing to operate.

  So the honest position is: **the boundary holds by construction for everything
  declared in `KIT_POSTGRES_DATABASES` on a fresh volume, and a database added
  afterwards is the operator's to close.** `tests/isolation_test.sh` proves the
  first half against a real cluster; the second half is a documented step, not a
  claim. A reader who adopts this should decide now whether that step is
  acceptable, because "we will remember" is the only thing holding it.
- **Credentials in production.** Every dev role takes `POSTGRES_PASSWORD`.
  Isolation is by privilege and never by secret — which is exactly what lets
  `tests/isolation_test.sh` demonstrate the boundary while knowing every password
  in the cluster. Production roles carry distinct passwords from the deployment
  secret store.
- **Backup and restore.** Owned by `templates/kamal/` (kamal + kamal-backup), not
  by this packet. The topology here is one cluster with N databases, and
  kamal-backup's `databases:` is a list, so one job covers all of them.

## MD23 — **the account boundary is Postgres row-level security, forced; application predicates stay**

**The trade.** kit enforces two boundaries and neither is a `WHERE` clause. Between
services, the database (`MD21d`). Between two accounts of the same service,
**row-level security on every account-scoped table, with `FORCE ROW LEVEL
SECURITY`**, and a **login role that owns nothing**.

**What is NOT taken.** The application's own `where account_id = ?` is not
removed, and this is the load-bearing half of the decision rather than a
half-measure. Three reasons:

1. **The predicate is what makes the query indexable.** Postgres evaluates a
   policy per candidate row; a query that relies on the policy alone is a
   sequential scan the moment the planner cannot push the qual down. Measured:
   `cafaye.protect_table` creates an index on the policy column precisely because
   of this, and the predicate is the second half of the same problem.
2. **The predicate is what catches a mistake in the policy expression.** A `with
   check` written against the wrong column is refused by no test that does not
   look for it.
3. **`core`'s `schemas/tenant-isolation.schema.json` requires it.** `enforced.line`
   must carry the tenancy key. This decision changes nothing in `core`; it adds the
   enforcement `core`'s declaration half was written to be honest about.

**Why `FORCE`, and the measurement.** Postgres exempts a table's OWNER from its
own policies. Every service in this fleet runs its migrations as its own role, so
the owner is the role that builds every table in its database — and, in
development, the role the application logs in as. Measured on this kit, a
protected three-row table, read as the owner carrying another tenant's identity:

| | rows returned |
|---|---|
| with `FORCE ROW LEVEL SECURITY` | **1** — its own |
| without it | **3** — every tenant's |

`FORCE` is not documented in Supabase's row-level-security guide, and **before
this packet no lint anywhere in cafaye checked for it** — verified across all nine
account-scoped services: zero `ROW LEVEL SECURITY`, zero `CREATE POLICY`, zero
non-owner login roles. A team that ships policies, enables RLS, declares victory,
and is silently wrong on exactly the tables it owns is the failure this decision
exists to prevent. `tests/tenancy_test.sh` deletes the statement and requires the
**owner** half of the assertion set to go red while the **login** half stays green:
that asymmetry is the whole control, and an isolation suite written only against
the application role passes on a substrate with no FORCE at all.

**Why a non-owner login role, when FORCE is already there.** They are different
attacks. FORCE makes the owner **subject to** the policies; it does nothing about
the owner being able to **remove** them. A login role that owns its tables can
`ALTER TABLE … DISABLE ROW LEVEL SECURITY` and `DROP POLICY`, so the second line
is `<service>_app`, provisioned by the cluster's init script — the one place in
this repository where a role is created.

**Why the membership is one-directional.** `GRANT "<svc>_app" TO "<svc>"` and
never the reverse. The allowed direction lets a migration and
`tests/tenancy_test.sh` impersonate the strictly weaker role, which is how a proof
is written from outside the boundary. The forbidden direction hands the
application every privilege the owner has, which is the entire design undone by
one `GRANT`. `tests/isolation_test.sh` asserts both halves.

**Why the identity is a transaction-local GUC and not a session variable.** Every
one of kit's six drivers holds a **pool**. A session-level tenant variable
survives the pool: the connection goes back still carrying tenant A's identity,
tenant B is handed it, and tenant B reads tenant A's rows. Transaction-local
cannot outlive the request, so a leak needs the caller to forget a transaction,
which is a different bug with a different symptom.

**Why the seam is a function and not a token format.** `cafaye.begin_account/1`
takes a uuid. How a service turns the credential in its hand into an account is
that service's business — `identity` issues opaque session tokens and `gateway`
verifies JWKS bearer JWTs — and a template that picked one of those would be
silently wrong for the other five. `auth.uid()` is therefore **forbidden** in the
substrate, and the gate fails the build on it.

**The cost, stated.** A protected table's owner reads **zero** rows from it until it
sets an identity, so a backfill migration has to set one or use a `SECURITY
DEFINER` function. And `begin_account/1` outside an explicit transaction expires
at the end of the statement, so a caller in autocommit reads nothing. Both fail
loudly and immediately, which is the good direction, and both are documented in
`templates/database/tenancy/README.md` rather than discovered.

**What was NOT taken: `FORCE` on every table in the cluster.** It is a property of
a table, and forcing it on a table with no policies yet — which is every table
between its `CREATE` and its `protect_table` call — makes that table unreadable by
everybody including its owner. The init script therefore does not do it.

---

## MD24 — **a credential resolves by a POLICY, not by a bypass role and not by a `SECURITY DEFINER` function**

**The problem this exists for.** A table whose access path is *"find the row by an
unguessable secret and learn the account from it"* cannot be scoped by an account
you do not have yet. The account **is** what the query is for. `identity` measured
it against its real protected `api_keys` table, as the OWNER role:

| | rows seen |
|---|---|
| **no identity — the state a request presenting a scoped token is in** | **0** |
| identity = the credential's own account | 1 |
| identity = another tenant's identity | 0 |

The first line is the finding, and it is the quietest possible failure: the token
does not resolve, `pgx.ErrNoRows` becomes `ErrNotFound`, and the HTTP layer turns
that into **401 "not found"**. The same shape is `account_invitations` (redemption
by token) and `oidc_clients` (lookup by `client_id`). Those are not three bugs;
they are one property of the design.

**The trade.** A credential table gets **one extra `for select` policy**, and the
qualifier of that policy is the *digest the caller presented*:

```sql
select cafaye.protect_credential_table('api_keys', 'token_digest');
```

which installs, alongside `protect_table`'s four account-scoped policies, a fifth:

```sql
create policy api_keys_cafaye_resolve on api_keys
  for select to <owner>, <service>_app
  using (token_digest = (select cafaye.current_credential_digest()))
```

and the caller opens its resolution the way it opens its account:

```sql
begin;
select cafaye.begin_credential($1);                        -- the digest it computed
select … from api_keys where token_digest = $1;            -- the row returns
commit;
```

**Why a policy, when three other mechanisms are available.** Each was measured or
read in the reference trees first, and each is worse for *this* substrate:

- **A role carrying `BYPASSRLS`** — which is Supabase's answer, and the answer is
  right **for Supabase's topology**. `service_role` is created
  `nologin noinherit bypassrls`
  (`refs/supabase-postgres/migrations/db/init-scripts/00000000000000-initial-schema.sql:31`),
  granted only to `authenticator` alongside `anon` and `authenticated`, and it
  holds **no policies at all** — what bounds it is (a) who may assume the role and
  (b) object **grants** (`alter default privileges … grant all … to service_role`,
  same file, lines 40-42). kit has neither half of that structure: there is **one**
  per-request role (`<service>_app`) and there is no separate service layer to run
  as. A bypass role here would be a bypass over *the whole service database*, held
  by the role every request already authenticates as. That is not a resolution
  path. It is the ambient bypass this directory exists to prevent, wearing a
  credential-shaped name.
- **A `SECURITY DEFINER` function** — **does not work under `FORCE`**, which is the
  trap this decision exists to close rather than to re-open. `FORCE` applies to the
  *definer*, so a definer function on a forced table is subject to that table's
  policies; only `BYPASSRLS` (or superuser) skips RLS, and no kit service role has
  either. A proposal of exactly this shape should be read as the BYPASSRLS option
  wearing a friendlier hat.
- **Dropping `FORCE` on credential tables** — `MD23`'s measurement is the whole
  answer: 1 row with it, 3 without, on the one table holding every machine
  credential.
- **Leaving `api_keys` unprotected** — the boundary stops covering credentials.

**Why the predicate is in the POLICY and not only in the caller's query.** This is
the requirement that decides the shape. RLS policies are combined permissively, so
a `using` clause that said merely *"a credential session may select this table"*
would be exactly the defect: the caller would hold a table-wide `SELECT` and could
browse every key in the database with the one query the mechanism was built to
avoid. So the policy carries the **same predicate the caller's query carries**,
sourced from a GUC rather than from the `WHERE`. The consequence is the property
this needs:

> **A resolution session may read exactly the credential row whose digest it
> presented, and nothing else in the database.**

`select * from api_keys` inside a resolution session returns that one row, not the
table. That is asserted, not argued: `credential/resolution-cannot-browse` and
`credential/resolution-does-not-open-another-table` in
`templates/database/tenancy/assertions.txt`.

**What it costs, stated rather than drifted into.**

1. **The mechanism cannot tell a secret from a label.** It widens a read to the row
   whose value you presented, and whether that value is unguessable is the
   service's knowledge, not the substrate's. On `oidc_clients`, where `client_id`
   is an identifier rather than a secret, this mechanism is the wrong tool and the
   README says so by name. The **invariant** is the reason the mechanism cannot
   become a general bypass: you can only widen a read to a row you could already
   name.
2. **It is a `SELECT` widening and nothing else.** A resolution session cannot
   insert, update or delete: the resolve policy is `for select`, and every write
   policy still demands an account identity. A service cannot mint a credential
   while resolving one.
3. **It does not open the other tables.** The mechanism is a policy on a named
   table. `account_users`, `assets`, everything else still read zero rows in a
   resolution session, and that is asserted as its own row.
4. **Two GUCs, not one.** `begin_credential/1` is a second seam. It is
   transaction-local for the same reason `begin_account/1` is (a pool must not hand
   one resolution's digest to the next connection) and it is set in exactly one
   function, so a service has exactly one place that writes it.
5. **Runtime audit is Postgres's job, not this one's.** What is auditable here is
   the *scope*: `cafaye.credential_tables()` names every table carrying a
   resolution path, so "which tables in this database can be read without an
   account" is one query and not a code search. It answers that **the same to
   every role that asks**, which it has to be given rather than have by default:
   the audit reads the policy's dependencies (`pg_depend`), not its rendered text,
   because `pg_get_expr` deparses a name unqualified whenever the *reader's*
   `search_path` resolves it and `"$user"` is a `search_path` entry — the version
   that read the text reported no credential table at all to the cluster's own
   admin role, whose `"$user"` schema is `cafaye`. Auditing *who* resolved is not
   claimed — the GUC is transaction-local and leaves nothing behind, and a claim
   kit cannot honour is a comment pretending to be a control.

**Enforced by:** `templates/database/tenancy/isolation.sql`, as new named rows in
the existing dual-role loop, so the credential half is measured as the login role
**and** as the owner; and by `tests/tenancy_test.sh`'s existing FORCE control,
which goes red on `owner/credential-no-context-reads-no-rows` and
`owner/credential-resolution-cannot-browse` when `FORCE` is deleted — the owner
bypassing its own table is precisely how a resolution context turns into a
browsing context.

---

## MD25 — **the advisor does not read view TEXT, and the gate does not read rule BODIES**

Two trades this packet made, recorded together because they are the same trade
seen from two files: **a static check reads what it can name, and the thing that
needs a database is run against a database.**

**Not made, twice:**

1. `templates/database/tenancy/advisor.sql`'s `security_definer_view` does not
   parse `pg_get_viewdef` to decide *which columns* a view projects. It asks
   `pg_depend` which **relations** a view reaches, and reports a view that
   projects one non-account column over an account-scoped table exactly as
   loudly as one that projects the whole table.
2. `tests/validate.sh`'s tenancy contract check compares the advisor's **rule
   names** against the fixtures in `tests/tenancy_test.sh` — not rule bodies,
   not conditions, not the shape of a narrowing.

**What each costs:**

1. **False positives on wide-but-harmless views.** A reporting view that selects
   `count(*)` over an account-scoped table is reported. The detail names the
   tables, so the reader can make that judgement in one read, and the alternative
   — a parse of view text — has misses that are *silent*, which is the
   substrate's own standing argument about `pg_get_expr` ("an audit query that
   returns an empty column forever looks exactly like an audit query that found
   nothing"). This is the same trade rule 4's keyword half already makes.
2. **A rule can go from selective to indiscriminate without the static gate
   noticing.** This was measured, not reasoned about: the first version of
   `self_test` breakage 93 deleted the `having` clause that requires the view to
   read something protected, and **the gate stayed green**. The check compares
   names, so a rule that is present, correctly named and no longer narrow is
   invisible to it by construction.

**Why not, in both cases:** the same reason the file already declines to parse
`advisor.sql` at all — it is `SKIP`ped by the parser loop with a note saying
`tests/tenancy_test.sh` is its check, precisely because a SQL file's meaning is
a question for a database. A static check that parsed rule bodies would be a
fourth implementation of a rule rather than a parser of a file, and its misses
would be indistinguishable from a tree with nothing wrong in it.

**What is enforced instead, and why the split is honest rather than a dodge:**
`tests/tenancy_test.sh` runs a real cluster and proves the rule **fires** (two
positives: a plain definer view, and a view over a *view*) and **does not
misfire** (six negatives, silent for six different reasons — its own remedy, no
protected table, unreachable, and reachable only through an invoker view spelled
both `true` and `on`). The static check proves the advisor and its proof
**agree**. A rule whose narrowing was deleted passes the static check; a renamed
rule passes the cluster suite's collection but not the static one. Neither file
covers the other, and the report for this packet names which is which rather
than claiming a single proof of both.

---

## MD26 — **the version string is the promise, and the tier is DERIVED from it**

**The trade this packet did NOT make: the tier is not written down anywhere.**
A consumer's only question about kit is whether a version is safe to take, and
until `VERSION` existed the answer was a person reading a diff — in every
repository, forever. Three tiers are now **derived** from two version strings by
one function, asserted against a published table of ten pairs, and gated on.

**Why three tiers and not four, and not a boolean.** The tiers are the three
sizes of change there are, and the rule of thumb is that the number you do not
have to read is the size of the promise. A fourth tier would be a claim about
the CONSUMER's code, which kit does not have. A boolean — what cafaye has today
— answers "did anything break?" with one bit, so it cannot say WHICH surface
broke, so a reader still opens the diff; the tier is derived from the number the
consumer already holds, which is the property that makes it checkable at all.

**Why the source of truth is `VERSION` and not a service manifest.** A service's
manifest describes that service. Nine of them carry no `version` key on purpose,
`identity` says why in its own comments, and none of them is a place to record
how safe it is to take *kit*. Two different questions, two different files.

**Why `1.0.0` and not `0.x`.** In semver `0.x` *means* "unstable, anything may
change" — the exact sentence this removes. A version a consumer has to re-read
the meaning of is not a source of truth.

**Why a version string this cannot place is a red build.** `2.4.0-rc1` is
refused because a prerelease suffix makes the derived tier change meaning when
the suffix is dropped, so the string stops carrying its own promise; `v2.4.0` is
refused because `v` is the TAG spelling (`kit.ref` takes `v<semver>`) and this is
not a git tag. Both are `unknown`, and `unknown` fails closed.

**Why the tier owes a FILE.** A MAJOR owes a `MIGRATIONS.md` section, because a
consumer who adopted kit by copy cannot apply a sentence. A `### Breaking`
heading is legal only under a version whose MAJOR moved, and never under
`## Unreleased`, where it is covered by no version at all. That last rule needs
no predecessor, so the promise holds for the whole history rather than only for
the bump being released — which is what makes it checkable rather than
documented.

**The defect the breakages found, recorded because the rule is the lesson.** The
gate first read its predecessor from `git show HEAD:VERSION`. It resolves to
nothing in a throwaway copy, so every version bump in an unpacked tarball
derived `initial` and breakages 96 and 97 stayed GREEN. It now reads the
changelog section below the current one — a version a consumer can SEE, and
therefore the same fact the promise is about.

## MD27 — **`RESERVED` adopts buf's tombstone and NOT k8s's deprecation, and says so**

Two references adopted "reserved" independently, which is usually a sign the
idea is load-bearing. Read closely, **they are not the same mechanism**, and the
difference is the finding:

- **buf's `reserved: 3, 7;` is a WIRE tombstone.** The field *number* is what
  travels in the bytes, so a retired number may not be reused — otherwise an old
  message and a new one decode the same bytes into two meanings. Its purpose is
  to make DELETION non-breaking.
- **Kubernetes' `+k8s:deprecated=width,protobuf=3` is a LIFECYCLE marker on a
  field that is still there.** k8s does not delete an API; it deprecates, names
  the replacement and the version, and leaves the type in place.

**kit has no encoding, so buf's justification does not transfer** — there is no
byte whose meaning a reused name would corrupt. What transfers is the weaker
half both of them enforce, which is the half that matters when a service's copy
outlives the decision: **a retired name stays retired.**

**Why the deprecation half does not port either.** A comment in a copied YAML
file is a comment in a copy — the adopter's file never learns it. And kit has no
registry a deprecation could live in, since an artefact is fetched by ref or
copied by hand. `templates/parity-allowlist` already carries that half for the
fleet.

**Why the fourth hygiene rule is INVERTED here.** In a skip allowlist, an entry
matching nothing is a ratchet that only turns one way. For a tombstone the dead
entry and the live name are the same defect with two names: the entry says the
name is gone and the name is in the tree. So `reserved_check` fails when a
reserved path **exists**, and is silent otherwise. Two entries, both from kit-20.

## MD28 — **the 94 copies share ONE cache directory, and the two GREEN-expecting proofs do not use it**

`tests/self_test.sh` runs 94 throwaway copies of the whole tree, one per
breakage, and each copy inherits `KIT_CACHE_DIR`. One line points it at
`$WORK/cache` — a **sibling** of every copy, inside the directory the existing
`trap` already sweeps — and that is the whole mechanism: a record written inside
copy 23 is deleted with copy 23, so without this line every breakage pays full
price for a verdict an earlier breakage already earned.

**The placement is the decision.** A cache *inside* a copy dies with the copy (the
bug). A cache in the real tree is neither shared with the copies nor swept by the
`trap`. `$WORK/cache` is shared for exactly the lifetime of the suite and leaves
nothing behind.

**The two GREEN-expecting helpers run their copies with `KIT_FINGERPRINT=0`.**
`expect_green_check` (breakage 59) and `expect_skip_check` (breakage 23b) assert
that the gate **stays** green and that a named verdict is still printed. A
replayed cache hit is a green that no check ran to produce, so under a shared
directory those two proofs could be satisfied by a record an *earlier* copy wrote,
on a tree the recipe had not yet mutated. That is a control that goes green for a
reason it did not introduce — the same defect as a control that goes red for one,
and the one AGENTS.md refuses in both directions. Two tokens on one line each;
the 92 red-expecting helpers deliberately keep the cache, because for them a
stale green is a **loud** failure ("the gate went red, but NOT via `<check>`"),
never a silent one.

**What this does NOT decide, and what it costs.** No check is wired by this
commit, so the line changes no verdict until a declaration is traced input by
input — a green light with nothing connected to it is not a saving. The cost of
the choice is that the two uncached proofs pay their full gate forever; measured
at one recipe each, that is the right side of the trade.

## MD29 — **a rollout is sized against a MEASUREMENT, and a measurement the last packet made stale is not a measurement**

`REPORT-kit-fingerprint-01.md` §5 handed the successor a rollout "as a list of
declarations", and the brief behind it sized the prize at *"94 throwaway COPIES
of the whole static phase, one per breakage"*.

**Counted on this tree, that is nine copies, not ninety-four.** 103 recipes:
86 `expect_red_check` (each runs `validate.sh --only=<ONE check>`), 8
`expect_red_script` (the script alone, no gate at all), 6 `expect_red_lang`,
1 `expect_red`, and the 2 green-expecting controls. `PROFILE-gate.md` had
already found this in its §4 and its own header says its table should be
re-derived — `kit-gate-speed-02` then converted 73 recipes to `expect_red_check`
and **took the whole static phase out of three quarters of the suite**. The
premise outlived the change that falsified it.

**The measurement it needed is `PROFILE-child-gate.md`**, because a child gate's
rows are attributed by breakage and the outer profile cannot see them. Measured,
one whole-gate copy: the **top seven checks are 69.3 s of 103.2 s (67%)**, and a
gate that runs **zero** checks still takes **11.07 s**.

**What the choice costs, stated plainly.** Sizing the rollout against the stale
premise overstates the prize by roughly 2×, and it misdirects the ORDER as well as
the total: 96 of 118 checks are under 0.1 s and worth ~4 s together, so
"cheapest-value first" spends a whole declaration budget on a tenth of a copy.
A successor that reads the brief and not the profile will write thirty correct
declarations for eleven seconds and call it a rollout.

**The rule.** `DECISIONS.md` (MD21) already holds the line that kit's numbers are
measured rather than argued. This is the same rule one packet downstream: a
number that a later commit made false is a **stale premise**, not a conservative
estimate, and the cost of carrying it is paid in declarations nobody needed to
write.

---

## MD30 — **the self-test's child gates opt OUT of the observability live tier, and no bound was widened**

`REPORT-kit-selftest-live-tier-01.md`, §6. This is a decision about **what the
105 labelled recipes are allowed to run**, and the four available responses were
all worse than the one taken.

**Not made: raising the 900s bounds** on `canary_test.sh`,
`no_telemetry_in_readiness.sh` and `stack_live_test.sh`, or `bin/dev`'s deadline.

**What it costs:** nothing, which is exactly why it is wrong. A bound exists to
answer "did this tier finish on a loaded machine", and `tests/validate.sh` says
of its own numbers: *"a bound set at the observed quiet duration is a bound that
fires on any contention at all, and a bound that fires is a tier that proved
nothing."* The same sentence read the other way is the reason not to widen: a
bound widened until it stops firing on the busiest machine stops answering the
question it was written to answer, and it does so invisibly — the tier still
prints PASS. **Widening a bound is a comment, not a fix.**

**Not made: making the live tier contention-proof.** Three docker stacks tuned
against a machine kit does not control, with `KIT_DEV_PROFILES=observability`
carrying tempo + loki + grafana together — eight containers apiece. The result
would be a 23b that is a coin flip rather than a green, and a coin flip in a
proof is worse than a red because it trains the reader to re-run.

**Not made: running the recipes concurrently.** The recipes share the docker
daemon and kit's 15000-15999 port block, so two shards collide; and a collision
is indistinguishable from a real failure, which is the one thing a self-test
must never be.

**Not made: dropping breakage 23b.** It is the assertion that a green gate can
still be an honest one — the suite is not run, and the gate names why. Removing
it removes the only proof that a skip is named.

**Taken instead, and this is the part that makes the trade reversible.** The
count nobody had asked for: **0 of the 107 recipe invocations name a live tier.**
Every recipe asserts a verdict about one named check — a collector config, a
workflow, a linter, a reporter — and `canary_test.sh` /
`no_telemetry_in_readiness.sh` / `stack_live_test.sh` are not among them. So
`tests/validate.sh` grew `--no-live` (and `KIT_NO_LIVE=1`), which turns those
three into `report SKIP` lines naming the flag, and `tests/self_test.sh` sets it
for every child gate through one wrapper.

**Why the skip and not the deletion.** A patch that deleted the three
`bounded_check` calls would satisfy every exit-status assertion — 23b's included
— while proving nothing. The skip line is printed, counted in the tally and
repeated in the summary, because a skip nobody can see is a silent pass. This is
the same rule as the `reportUnusedDisableDirectives` entry above, applied to an
allowlist of *tiers* rather than of checks.

**What it costs, stated plainly.** The self-test no longer exercises the live
tier at all, so a defect in those three suites can no longer be caught by
`self_test` — it is caught by the top-level gate, which still runs all three and
whose green is the claim. That is a real reduction in what the suite proves and
it is the right reduction: those three tiers are integration tests against a
docker daemon, and a suite that runs 104 copies of them is asserting that the
machine is quiet, which is a property of the machine. The flag is set in exactly
one place, `kit_child_gate`, and a check fails if a second spawn appears without
it or if any recipe ever names a live tier.

**And the honest limit of the evidence.** The red at position 23 of 104 was
*reported*; it did not reproduce on the machine this was built on, where 23b's
gate run is green standalone and inside a full suite run. So the argument above
rests on the **exposure** — measured: one whole gate out of the suite, 128.8 s
of its 255.2 s in three docker stacks, asserting nothing about any of them —
and not on a failure that was watched. The trade stands on the measurement; the
anecdote is the thing that made somebody go and take it.

**The rule.** *Ask what the expensive thing is being run FOR.* Nobody had, and
the answer was "for nothing, 104 times" — which is a different defect from "the
expensive thing is slow", and the only response to the second one that does not
stop measuring is the one that removes the work.

---

## MD31 — **a recipe may not spell a version; it may only DERIVE one, and the rule is a text scan over `tests/self_test.sh`**

**The defect, in one sentence.** Four recipes anchored their `edit` on the
literal `1.0.0`, so one release — `92a1127`, moving `VERSION` to `2.0.0` — killed
the only proofs kit has of its own release discipline, and reported each of them
as `the recipe no longer applies to its copy`, which reads as a harness
complaint rather than as four lost proofs.

**Why derivation and not a corrected literal.** Rewriting the four anchors to
`2.0.0` is a fix that re-arms the identical bomb for `3.0.0`, and it is green in
the meantime. A derived mutation cannot drift: `copy_version <dir>` reads the
version out of the copy and `bump <v> <major|minor>` computes the destination, so
the recipe exercises the same property at whatever version the tree carries. The
forward test is the proof, and it is a separate measurement from the suite's:
simulate the release, then require each recipe to apply AND bite.

**Why the check is a SCAN OF THE SOURCE and not a guard at suite start.** The
packet offered two shapes. Both make the next bump a non-event; they differ in
*when* they say so and in what they cost.

| | scan of the source (chosen) | guard at suite start (rejected) |
| --- | --- | --- |
| when it speaks | at authoring time, in the same gate run | after the copy exists, per recipe |
| cost | one text pass | a full set of throwaway copies |
| what it can name | the recipe, the file, the literal | a resolved anchor, no literal |
| if it is deleted | a vacuous rule, which the check itself catches | a suite that runs anyway |

A guard at suite start is the same information one step later, and it cannot say
*which* recipe or *why* at the moment somebody is writing one — which is the
moment the decision is cheap. It was also the more expensive of the two by the
ratio the self-test already pays 107 times.

**And the check is NOT "be louder".** `edit` already refuses an unmatched anchor
loudly, naming the file; the packet says so explicitly. The job here is not a
louder refusal, it is making the class impossible — and that is the whole reason
the check runs on the source rather than on a failure. At the moment `edit`
refuses, the recipe is already dead and the damage is done. A refusal cannot
catch that; only a rule that runs before anyone writes the recipe can.

**What it derives rather than asserts.** The set of files in scope is read out of
the recipes themselves — every path `edit` is handed that resolves to `VERSION`
or `CHANGELOG.md` — so a version recipe written next year brings itself under the
rule without anybody editing the check. This is `self_test_live_tier`'s move for
the same reason: a list of what is forbidden, written down separately, is a list
that goes stale, and a rule covering only the cases its author remembered has a
hole shaped like the next packet.

****The one literal left standing, and why.** A sweep of all 69 `edit` statements
for a version literal, a prerelease, a `## <version>` heading, a `### <subsection>`
name, a port, a template path and an image tag found: **0, 0, 0, 0** for the first
four, 2 ports (`5432:5432`, `65532:65532`), 29 template paths, and **1** remaining
`## Unreleased` — in breakage 98's create branch. It is left there deliberately,
and the asymmetry is the reason:

    an `## Unreleased` in an ANCHOR       -> the recipe dies at the next release
    an `## Unreleased` in a REPLACEMENT   -> the recipe writes an out-of-date name

Only the first is a lost proof. Deriving a heading name from nothing would mean
deriving it from the convention it is the convention, which is circular; and the
one place it appears is on the replacement side, where a rename changes the text
written and not whether the mutation applies. The recipe says so in a comment,
because a rule with a documented exception is a rule and a rule with an
undocumented one is a surprise.

**The two shapes rejected inside the scan, both measured.**

1. *Only the anchor.* A recipe that anchors on `$v` and writes `3.0.0` as the
   destination has the same fuse — the literal stops existing the moment the tree
   moves past it — and is invisible to an anchor-only rule. So the scan covers
   every argument of the call. Measured red on the anchor alone and on the
   destination alone, separately.
2. *Any `\d+\.\d+\.\d+` anywhere in the file.* That matches the prose — this
   repository's documentation legitimately names versions — and a check that
   fires on the explanation of why a literal is wrong is a check that fires on
   its own documentation. Comments are excluded, measured: a literal moved into a
   comment does not fire.

**The limit, stated rather than caveated.** The scan reads *arguments*, so a
version literal that reaches a recipe through a variable is invisible:

    v_part="2.0"; edit "$baseNN/VERSION" "$v_part" "$v_part.0.0"      -> GREEN
    v96_major="2.0"."0.0"                                            -> GREEN

Both were measured, and both are reported in `REPORT-kit-version-recipe-drift-01.md`
rather than left as a footnote. Neither is obfuscation a careful author reaches
for, and closing them means either re-implementing bash's expansion (which fires
on correct code and teaches the reader to ignore the check) or parsing recipe
blocks by brace and backslash counting — the same fragility `self_test_live_tier`
already removed a containment assertion over. The rule is worth more honest than
airtight: it catches the class as it was actually written.

**The rule.** *A version a recipe writes is a fact about the copy, not a fact
about the day the recipe was typed.* Anything a routine repository change moves —
a version, a changelog heading — is derived from the tree being mutated, and a
check over the recipes says so before the release rather than after it.

---

## MD32 — **a docker tier's shared names are DERIVED from the run, and the guard reads the directory rather than a list**

The trade this packet was dispatched to make. Four namespaces are now derived in
every tier that brings a container up, and `tests/validate.sh` fails when one is
not. What was **not** made: a stronger uniqueness token, a per-run docker network,
and a guard that follows a name through a helper function.

**What it costs:** `$$` is unique among live processes **on one machine** and no
further. Two CI jobs sharing one docker daemon would still collide. That is
accepted rather than overlooked — every job in this repository's workflows runs on
`ubuntu-latest` with its own daemon, so the property that has to hold is
uniqueness among processes on one machine, and `$$` delivers exactly that and
nothing more. The stronger option is real and is discussed below.

**Why `$$` and not `mktemp`.** Three reasons, in order of weight.

1. *It is the convention already here.* Four tiers already derive their project
   name with `$$` (`canary_test.sh`, `stack_live_test.sh`,
   `no_telemetry_in_readiness.sh`, `deploy_test.sh`). Choosing `mktemp` for two
   tiers would leave **two idioms in one directory**, and the reader who has to
   know both is the reader this repository keeps writing checks for. The packet
   asked directly whether the other four should move too: **no**, because `$$`
   is the weaker-but-sufficient option and moving four working files to a
   stronger one is a change with no failure behind it. One idiom, sufficient.
2. *Sufficiency is a property of the threat model, not of the token.* The
   collision to survive is two runs on one machine. `$$` is exactly unique there.
3. *`$$` is what the reader already believes.* `WORK="${TMPDIR:-/tmp}/kit-x.$$"`
   appears throughout these files. A project name derived some other way would
   need its own argument.

**The two claims `$$` does NOT make**, recorded because a decision document that
records only the trade's benefits is a preference:

- it is not unique across machines sharing a docker daemon;
- it is not stable across a re-exec *within* one run, which is why no tier here
  re-execs. A future tier that retries itself by re-running under a new pid would
  leak its first cluster — the fix for that is `mktemp`, and the guard will not
  notice, because the guard checks that a name is derived and not how well.

**Why the HOST PORT is in scope, which the packet did not ask for.** Fixing the
project name alone does not fix the collision; it relocates it. Measured, not
assumed: with only `--project-name` derived, two concurrent runs of
`isolation_test.sh` were still red on `port is already allocated`, because both
bound the hardcoded `KIT_POSTGRES_PORT=15521`. A fixed host port is also *worse*
than a fixed project name, because it collides with **the developer's own running
stack** rather than only with another test run. So the port is derived by the
same dependency-free probe `stack_live_test.sh` uses (`/dev/tcp`, not `nc`, not
python — no tier may assume a tool is installed), seeded from `$$` so two
concurrent runs do not begin their search in the same place.

**Why the guard derives its scope instead of listing the offenders.** A list is a
list that goes stale, and the argument was made concrete by what happened while
this was written: deriving the scope from `tests/` found a **fourth** tier with
the same defect that was on nobody's list and is not in the packet —
`tests/rls_perf_test.sh`, whose container was `C="kit-rlsperf-pg"`. It was fixed
rather than reported, because a guard that reports a defect nobody fixes teaches
everyone to ignore the guard.

**Why an inlined `$$` is accepted at a use site.** The rule as first written
required a namespace flag to carry a bare variable reference, and fired on
`deploy_test.sh`'s `docker volume rm "kit16-not-ours-v-$$"` — a decoy volume that
*is* unique to the run, because it inlines the pid rather than naming a variable
holding it. What actually breaks is two sites **disagreeing**: one deriving
`kit-isolation-$$` and one spelling `kit-isolation`, so the tier queries a
namespace it did not create. Two sites inlining the same `$$` agree, and two
stacks do not collide. Spelling a name twice is untidy; spelling two *different*
names is the defect. A check that fires on correct code teaches a reader to
ignore it, which is this repository's own recorded rule and the mistake
`self_test_live_tier` documents making and then backing out of.

**Why the guard checks declarations as well as call sites.** `CONTROL_C=
"kit-isolation-control"` makes every *use* read `"$CONTROL_C"`, which is derived —
so a rule reading call sites alone passes on a tier whose control container is
shared by every run on the machine. Found by the mutation suite saying NOT
BITTEN on a mutation that had demonstrably been applied.

**The limit, stated rather than caveated.** The guard reads flags at the point of
use. A name reached through a helper function, or built by string concatenation
before being passed, is invisible to it:

    compose_up() { docker compose --project-name "$1" -f "$f" up -d; }
    compose_up kit-isolation                                            -> GREEN

Closing that means re-implementing bash's expansion or interposing a shell parser,
and this repository has already removed one containment assertion (`self_test_
live_tier`'s, over brace counting) precisely because it fired on correct code. The
rule is worth more honest than airtight: it catches the class as it was actually
written, in every tier, on the day the tier lands.

**The rule.** *A name in a shared docker namespace is a fact about the run, not a
fact about the day the tier was typed.* Anything that decides which cluster a run
talks to — project, container, volume, published port — is derived from the run's
own identity, and a check over the tiers says so before CI does.

### A TIER REACHED THROUGH A WRAPPER WAS NOT A TIER AT ALL

`docker_tier_project_name` printed, in its own success line, that *the sixth tier
is covered on the day it lands*. Three tiers under `tests/` bring a compose stack
up and were not in scope, so the sentence was false while the gate was green.

**What the pattern could not see, and why.** `BRING_UP` was
`r"\bdocker\s+(?:compose\b.*\bup\b|run\b)"`, and it needs both halves of a
command on one logical line. `canary_test.sh` and `no_telemetry_in_readiness.sh`
each put `docker compose` in a `compose()` wrapper's body and pass the subcommand
at the call site through `"$@"`, so the two halves are in different places.
`stack_live_test.sh` writes `bash ./bin/dev up` and names the shared project only
from `ps`, `exec`, `port` and `logs`. All three were dropped from `tiers` before any
of the four rules ran. Measured with the mutation asserted by text:
`PROJECT="kit-canary-$$"` → `PROJECT="kit-canary"`, guard exit 0, **zero
findings**.

**The tier set is now three arms, and none of them is an enumeration.** Bring-up
direct, bring-up through a local `compose()`-style wrapper, and — the arm that
widened the count past the number this packet predicted — a script that **names a
shared namespace at all**. The wrapper arm matches the function **definition**
rather than the call sites, because a call-site pattern must know every spelling a
pass-through can take and the sixth idiom is another blind spot, while a definition
has exactly one shape and keeps the docker command on the same line it is hiding.

**The real fix is the emptiness finding one level up.** Widening `BRING_UP` alone
is a one-line patch that regresses silently the next time someone adds a wrapper
idiom. So: *a script under `tests/` that invokes docker but was not counted as a
docker tier is a finding*, named. Its predicate is **deliberately wider** than the
tier set — deriving it from `tiers` would be a tautology that can never fire, which
is the defect this chain exists to kill wearing a new hat. Both halves matter: a
rule that cannot fire is a green that costs its reader trust in the red ones, and a
rule whose scope is written down separately from the code goes stale silently.

**Two consequences the widening forced, both kept rather than tolerated.**
`provenance_test.sh` builds `-t kit-provenance-test:good`, reads labels back out of
it and tears it down with `docker rmi -f` — a bare name no `-p` has any say over,
so an image tag is a **fifth** shared namespace and the file was invisible to a
rule scoped to `… up`. Its two tags are now derived from the pid. And
`deploy_test.sh:456` is a `note` printing an example command, which the new image
rule read as a hardcoded tag; matches are now ignored when the `docker` itself sits
inside a quoted run. `-t` is matched only after `docker build`, because `-t` is
`--tty` to `run` and `exec`.

**The limit this closes, stated separately from the one above.** The entry before
this one records the limit that a *name* reached through a helper is invisible at
the use site (`compose_up kit-isolation` → green). That is unchanged. What changed
is one level up and it is worth not blurring: **before, the whole tier was out of
scope; now the tier is in scope and only indirection inside it remains invisible.**
A wrapper that brings a stack up is a tier. A name the wrapper builds before
passing it is still not something a text scan can read.

**The count is 9, not the 8 this packet predicted**, and the difference is
`provenance_test.sh` — named by the new emptiness finding, closed rather than tuned
away. A guard whose number was adjusted to a target is a guard measuring the
target. Recipe and measurements: `reports/wrapper-tier-scope/mutations.sh`,
8 cases, all bit.

---

## MD33 — **the README's file list is CLOSED UNDER THE README, and the unit is a TREE**

The trade this packet was dispatched to make. `readme_check` walks a
hand-maintained tuple of 25 paths and asserts two things per entry: the README
names it, and it exists. So a documented path that was **deleted** is a finding.
A path that was **added** is not one at all. `readme_closure_check` now walks
the five adoption trees and asks whether every shipped path sits under a path
the README names. What was **not** made: a row per shipped file, a row per
directory, or a check that `tests/` and `reports/` are documented too.

**The two things that were not made, and why.**

1. *A row per shipped file.* Measured on this tree, **145 of the 175** tracked
   files under `reports/`, `tests/` and `templates/` are not on the tuple. A
   README listing 157 paths is a README nobody reads, and a check that demanded
   them would be satisfied by the very thing it exists to prevent. So coverage
   is asserted per **tree**, and the cheapest true case is deliberately green: a
   new file inside `templates/compose/grafana/provisioning/` — a directory the
   README already names — leaves the verdict green, and a recipe proves it.
2. *A row per directory.* Measured, 34 directories under `templates/` are not
   covered by a listed path, and the natural closure — every directory must be
   listed — is the same 157-paths failure with fewer leaves. Listing a
   *directory* covers its whole subtree, which is why three entries in the
   original tuple are directories and why this packet's own new row is
   `` `templates/deploy/` and `templates/bin/deploy.sh` `` rather than six
   leaves.

**Why `tests/` and `reports/` are out of scope, which is a judgement and not a
measurement.** `tests/` is kit's own gate implementation; the README already
names every proof a reader is expected to *run* (`isolation_test.sh`,
`tenancy_test.sh`, `canary_test.sh`, `kamal_test.sh`, `fetch_test.sh`,
`stack_live_test.sh`) and `tests/validate.sh` itself, and naming `fingerprint.py`
and `bootstrap.sh` would add 17 rows that teach a reader nothing. `reports/` is
packet evidence: it is addressed to whoever reads that packet's report, not to a
reader deciding whether to adopt kit, and it is 32 files. Both exclusions are
written into the check rather than left as a gap a future reader mistakes for
coverage.

**The alternative that was rejected outright: extending the tuple by hand.** One
entry per new file is what the list already is, and it is the same ratchet as
`templates/tier/skip-allowlist`, in the opposite direction — it only grows, and
it grows by one line per artefact a fleet of nine services reads once. Worse, it
is satisfied by pasting a path into the README, which is exactly the edit the
tuple's own comment forbids for the `mimir` case. Reading coverage out of the
README instead means a packet that adds `templates/payments/` is caught on the
day it does, with **no edit to `tests/validate.sh` at all**.

**The fail-open trap found while writing it, recorded because the shape is
familiar.** A **one-segment token is not a tree**. `## The templates half —
`templates/`` is how the README introduces the section, so a one-segment token
prefix-matches everything beneath it and the whole adoption tree reports itself
documented by a heading. Measured: with one-segment tokens admitted the walk
found **one** undocumented path where there are **seven** — a green hiding six
real gaps, which is the same direction as a check whose pattern stopped
matching. A rule about coverage is itself a rule about scope, and scope has the
same two halves.

**What it costs.** Coverage is a substring over README prose, so a path named
only in a passing sentence or a code fence satisfies it — the same weakness
`readme_check` has had since it was written. Tightening it means requiring a
table row, which is a different check with a different failure mode. The honest
description of what this asserts is that **the tree is CLOSED**, not that the
prose is good.

---

## MD34 — **no committed-history secret scanner, and kit asserts only its own behaviour**

**Not made:** a scanner over the adopting repository's full git history, wired as
a job no service can opt out of. That was `gitleaks`, `.gitleaks.toml` and the
`secrets` job in `ci.reusable.yml`.

**What it costs:** a secret committed and later deleted is no longer found by
kit. It is still in the packfile of everyone who cloned, and GitHub's own
push-protection and the adopting repository's platform account scanning cover
the case a fleet-wide CI job was duplicating.

**Why not:**

1. *A control that runs against someone else's repository is not a control kit
   owns.* The job's subject is the adopting service's history. When it goes red,
   the person who pushed kit learns that a repository they do not maintain
   contains something they cannot fix from where they are standing. Every other
   job in the file checks kit's own behaviour; this one checked a neighbour's.
2. *The one job with no opt-in is the one that cannot be right for everyone.* It
   was made non-optional precisely because a scanner that can be turned off is a
   report — which is true, and also means the first repository to adopt kit with
   an unrelated finding in an old commit inherits a red build on day one. The
   cost of that choice was written down rather than discovered, and the answer
   recorded in README.md was "rotate first, then allowlist". That is a support
   burden kit had not accepted on purpose; it had accumulated.
3. *It was the slowest job in the file for the least kit-shaped finding.*
   `fetch-depth: 0` on every run, a full-history regex sweep of a repository
   that is not kit, and a bootstrap that fetched a second pinned binary per
   platform on every runner.
4. *It was already red.* `gitleaks (required: could not be installed)` had been
   failing in CI while the gate's own copy of the same scan ran locally, which
   is the failure mode MD13 was written to prevent and the clearest evidence the
   two-caller arrangement had not held.

**What replaces it.** `templates/secrets/` — the runtime canary — was already the
half that answers the question gitleaks could not: not *was a secret committed*
but *does a secret reach an exporter*. That stays, and `canary_test.sh` still
proves a planted value appears in no output. The committed-history half is now
the adopting repository's own platform feature, which is where a credential
should be caught: on the push that introduces it, attributed to the author.

**Enforced by:** nothing in kit, deliberately. There is no check here that the
scanner came back, because the argument above is about whether it belongs, and a
check asserting its absence is the same mistake one layer down.

---

## MD35 — the gate asks mise for the toolchain, and kit pins none of its own

**Decision.** `tests/bootstrap.sh` gained `kit_activate_mise`, which runs before
anything resolves an interpreter and is `eval "$(mise hook-env -s bash)"`
guarded by three no-op conditions (mise absent, shell already activated,
nothing configured). Both entry points call it. kit does **not** gain a
`mise.toml` of its own.

**The defect it fixes is an asymmetry, not a missing tool.** `kit_bootstrap_python`
has always resolved the interpreter through a four-step order with an explicit
override that is treated as a promise, and `have()` — used for docker, elixir,
go, gofmt, kamal, node, python3, ruby, rustc, shellcheck, golangci-lint,
rubocop, eslint — has always been a bare `command -v`. One language was
resolved; the rest were assumed. That assumption holds in an interactive shell
and fails in a non-interactive one, because mise is configured in `~/.zshrc` and
`~/.zprofile` and `bash tests/validate.sh` reads neither. The result was a gate
reporting `gofmt: command not found` and skipping three snippet checks and the
canary suite on a machine where every one of those tools was installed — and
because the lint phase is fatal on a skip ("a skipped lint proof is not a
proof"), a red build. The general form: *a skip that is really "you launched me
wrong" is a false negative, and this gate treats skips as claims about the
environment.*

**Why mise rather than pinning.** Pinning kit's own toolchain would be a second
source of truth that a CI runner with no mise config cannot honour — it would
resolve to nothing, which is the same "fails on arrival" failure the venv was
built to remove, reached from the other direction. The useful property of mise
here is not its pins but its resolution: it answers *what would this environment
have been*, which is a question kit can ask without owning an answer. Which
versions that is depends on config in scope at the time — a repo `mise.toml`,
the user's global one, or none — and kit deliberately stays out of that
decision.

**Why not `.zshenv` or a documented export.** Both push the problem onto the
caller. A gate that only works from a shell someone configured is a gate with an
undocumented prerequisite step, which is the exact property MD13-era bootstrap
work removed for python and which is written down in README.md as the reason
`.venv` exists.

**Cost.** About 70ms per entry point, on a suite that runs in minutes. Three
conditions that must stay no-ops, or CI and any machine without mise break: no
`mise` on PATH, `$MISE_SHELL`/`$__MISE_DIFF` already set, and empty output from
`mise hook-env`.

**What it does not fix.** Three rust checks still SKIP with `rustc not
installed`, and that is honest rather than resolved: rust 1.95.0 and 1.99.0 are
mise-installed on this machine but absent from `~/.config/mise/config.toml`, so
mise does not export it. kit has no business editing a developer's global tool
config to turn three skips green — and a skip that is reported is the gate
working as designed. A developer who wants rustc in the gate adds one line to
their own mise config.

---

## MD36 — kit grades kit, and the fleet surface is gone rather than gated

**Decision.** Every check that read a repository other than this one is removed:
`tests/fleet_check.py` (1169 lines), `tests/account_scope_fleet_check.py` (930),
`tests/generated_stack_check.py` (716), `tests/gate_declaration_check.py` (582),
the `account_scope_fleet_scope.yml` and `account_scope_fleet_ratchet.yml` tables,
the `account-scope-contract` job in `.github/workflows/ci.yml`, and the fleet
section of `tests/validate.sh`. About 3,600 lines.

**This reverses a position taken earlier in the same session, and the reason it
reverses is evidence, not taste.** The argument for keeping `fleet_check.py` was
that it fails only a repository carrying a `kit.ref`, so the promise being graded
is that repository's own. Two facts kill it. First, **it had no test**: the only
thing that ever proved it worked was `tests/self_test.sh`, deleted earlier in the
same session, so 1169 lines of parser had not been exercised by a single
assertion since. A check nobody can demonstrate is not a check. Second, **it
could not run where it is supposed to**: a clone of kit has no siblings, so every
run of every commit in CI took the `FLEET-ABSENT` branch and reported SKIP. The
job it was paired with existed precisely to work around that, by cloning six
repositories into a fleet layout — which is to say, to manufacture the sibling
tree that kit had refused to reach. That is the `secrets` job's shape again, one
layer down, and MD34's argument applies verbatim: the finding lands on whoever
maintains the repository that broke, and on someone who is not them.

**The general form, and it is the line the gate now holds.** *kit's gate asserts
things about kit.* Not about its callers, not about the fleet, not about a
sibling's history. Three reasons, in the order they actually decided it:

1. **A finding nobody in this repository can fix is not this gate's finding.**
   A red build is a request to act. If the person who can act is in another
   repository, the request is misaddressed, and the response is to mute the
   check rather than to fix the code.
2. **An unreachable check is a green that verifies nothing** — the exact phrase
   the `account-scope-contract` job used to justify itself, applied here to the
   check it existed to rescue. SKIP is honest; a SKIP on every run forever is a
   control that has been replaced by its own description of itself.
3. **Adoption is not a licence to be graded by your callee.** The `kit.ref`
   argument was the best one available and it still lost, because it asks a
   question about the *checker* (who consented?) rather than about the *finding*
   (who is affected?). Consent to be checked does not make it this repository's
   job.

**What is kept, and why it is not a contradiction.** `tests/staleness.py` reads
repositories, and it stays: it has 26 assertions in `tests/staleness_test.sh`,
and its other job — grading this repository's own `templates/` against what it
ships — is squarely kit's own behaviour. A check with a test and a subject that
is this tree is exactly the thing the rule keeps. The remaining cross-repo reader
is the lint-drift check in `validate.sh`, which compares a *service's* lint
config to kit's for services that call the reusable workflow; it is narrower
than anything removed here (a machine-checkable opt-in) and it is the next
candidate if this line is drawn further.

**What this costs, written down rather than discovered.** Three rules that were
mechanically enforced are now advice: no adopter carries a D12/D13 workaround;
no service sets `POSTGRES_USER`/`POSTGRES_DB`/`POSTGRES_PASSWORD` on the shared
cluster; a service's `.golangci.yml` and `.rubocop.yml` match kit's. Each is a
real rule that caught real defects. The trade is deliberate and the mitigation is
`core`: the first two are owned and fixed there, and a service that wants them
checked runs the check itself. What is given up is kit noticing when a service
stops obeying.
