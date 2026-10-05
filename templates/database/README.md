# `templates/database/` — one cluster, one database and role per service

> The topology, the connection contract every service's generated config carries,
> and the pooler decision with the measurements behind it.

## The short version

| | |
|---|---|
| Clusters | **one**, shared |
| Isolation boundary (between services) | **the database**, not the machine |
| Isolation boundary (between accounts) | **row-level security**, forced. [`tenancy/`](tenancy/README.md) |
| Databases | one per service, named after it |
| Roles | two per service: an owner, and a `<service>_app` LOGIN that owns nothing |
| Pooler | **none.** Direct connections, a stated budget, per-role blast radius |
| Extensions | in the image (pglayers), created by the admin role into every service database |

**There are two boundaries, and they are different subjects.** This file is the
first one: a service cannot reach another service's database. The second is two
accounts of the *same* service, which is `tenancy/` and was, until that directory
existed, enforced entirely by hand-written `WHERE account_id = ?` in six
languages — zero `ROW LEVEL SECURITY` and zero `CREATE POLICY` across all nine
account-scoped services. Read both; a service that reads only this one believes
it is isolated when it has only closed half the boundary.

## Where the pieces live, and why they are in different places

The topology has two halves and they are distributed by two different mechanisms,
because that is what the existing conventions already do.

| | file | how it reaches a service |
|---|---|---|
| the cluster | `templates/compose/postgres/` | **fetched** with the stack, from the `kit.ref` pin |
| the connection config | `templates/database/<lang>/` | **copied** into the service, per language |
| the account boundary | `templates/database/tenancy/` | **copied** into the service: SQL for its migrations, a driver for its tests |

The cluster is shared and identical for all nine services, so it belongs with the
shared stack. The connection config differs per service and per language, so it
belongs with the things a service owns. A service never copies the cluster; it
names itself in `KIT_POSTGRES_DATABASES`.

## The isolation boundary, and the honest version of what it defends

Measured, on a cluster built from `templates/compose/postgres/initdb/10-cluster.sh`:

```console
$ psql -U courier -d courier -c 'create table deliveries(id int)'
$ psql -U courier -d courier -c 'insert into deliveries values (1)'
$ psql -U courier -d billing -c 'select * from deliveries;'
psql: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed:
        FATAL:  permission denied for database "billing"
DETAIL:  User does not have CONNECT privilege.
$ echo $?
2
```

The refusal happens **before a query is parsed**, because `REVOKE ALL ON
DATABASE … FROM PUBLIC` withdraws the `CONNECT` privilege Postgres grants to
`PUBLIC` on every database by default.

**Two things this does and does not defend, because the difference is the whole
argument.** Both were measured on the same cluster shape:

| | with the `REVOKE` | without it |
|---|---|---|
| `SELECT` on another service's table | `FATAL: permission denied for database "billing"` | `ERROR: permission denied for table invoices` |
| reach the other database at all | no | **yes** — `has_database_privilege('public','billing','CONNECT') = true` |

Without the revoke, the *rows* are still protected — by the accident that nobody
granted `SELECT` on them. The *database* is completely open: catalog
enumeration, temp tables, visibility of other services' GUCs, and any future
`GRANT` anywhere in the cluster. Relying on "nobody has granted me anything" is
fail-open in exactly the way this repository's other rules forbid: one careless
grant makes it fail, and nothing warns you at the time.

So: **the `REVOKE` is the boundary, and the table grants are the accident it does
not rely on.**

## Two roles per service, and which one your application logs in as

| role | logs in | owns | may |
|---|---|---|---|
| `<service>` | yes — **for migrations** | the database, and every table in it | anything, including switching RLS off on its own tables |
| `<service>_app` | yes — **this is your application** | nothing | `select`/`insert`/`update`/`delete` on the tables `cafaye.protect_table` has protected |

`<service>` is unchanged, and a service that adopts nothing here is unaffected.
`<service>_app` exists because **Postgres exempts a table's owner from its own
row-level-security policies**: a login role that owns its tables can
`ALTER TABLE … DISABLE ROW LEVEL SECURITY` and can `DROP POLICY`, so an account
boundary enforced only by policies is one privilege away from meaning nothing. The
cluster grants `<service>_app` **to** `<service>` and never the reverse, so a
migration — and `tests/tenancy_test.sh` — can impersonate the weaker role to prove
the boundary from outside it.

`bin/dev db grant` prints both roles. A service that was provisioned before this
existed gets `<service>_app` by running those statements; the init script only
runs on a fresh volume.

`templates/database/tenancy/README.md` is the other half, and it carries the
`FORCE ROW LEVEL SECURITY` measurement: without it, `<service>` — the role your
migrations run as — reads every account's rows while the policies read as though
they were in place.

## The pooler decision: NO

This is the decision this directory exists to make visible, so it is stated
first, argued second, and checked third.

### The decision

**No PgBouncer.** One cluster, `max_connections` raised to 200, a per-role
`CONNECTION LIMIT` of 10, and per-role `statement_timeout` and
`idle_in_transaction_session_timeout`.

### Why, in one sentence

PgBouncer's own documentation describes the remedy for its worst failure mode as
`RECONNECT` on its admin console after a DDL migration, and kit would be
installing a manual operator step after every schema change in nine repositories.

### The argument, with the sources

**1. The DDL failure mode is not fixed by the version that supports named
statements.** PgBouncer 1.21 added `max_prepared_statements` (default 200), so
protocol-level named prepared statements *are* tracked and re-prepared across
server connections. That is a real improvement, and it is what makes the standard
advice — "just use a recent PgBouncer" — sound reasonable.

But the same page, describing the cost of reuse, says:

> If the return or argument types of a prepared statement changes across
> executions then PostgreSQL currently throws an error such as
> `ERROR: cached plan must not change result type` … One of the most common ways
> of running into this issue is during a DDL migration where you add a new column
> or change a column type on an existing table. In those cases you can run
> `RECONNECT` on the PgBouncer admin console after doing the migration to force a
> re-prepare of the query and make the error go away.

The remedy is an operator command. A migration is the single most common time
this fires. Nine services, nine independent migration schedules, one forgotten
console command each — and the symptom is an application error that looks like a
code bug.

**2. The per-language flags are the cost, and there is no version of them that is
free.** Every driver needs its own spelling, and none of them is self-explaining:

| language | the flag | what it costs |
|---|---|---|
| Elixir / Postgrex | `prepare: :unnamed` | no named statements; Ecto caches nothing |
| Go / pgx | `default_query_exec_mode=simple_protocol` | re-parse and re-plan every execution |
| Python / psycopg | disable the prepared-statement threshold | same |
| Ruby, Node, Rust | their own equivalents | same |

Postgrex's documentation is why this is tempting rather than optional-feeling:

> PgBouncer versions 1.21.0 and later support named prepared statements. If you
> are using an older version of PgBouncer with transaction or statement pooling,
> named prepared queries cannot be used … To force unnamed prepared queries in
> such older versions, set the `:prepare` option to `:unnamed`.

So the honest framing is: the flags are the price of a pooler, they differ per
language, and **a service that omits one fails only after a DDL migration** — not
at boot, not in CI, not in a smoke test. That is the worst possible failure shape:
the configuration is wrong for weeks and the first symptom is a production error
whose cause is four layers from the thing that is wrong.

**3. Transaction pooling withdraws session state, and says so.** On
`server_reset_query`:

> When transaction pooling is used, the `server_reset_query` is not used, because
> in that mode, clients must not use any session-based features, since each
> transaction ends up in a different connection and thus gets a different session
> state.

Everything the contract sets is session-scoped GUCs. Under transaction pooling
they are preserved only if PgBouncer is told to track them — and its
`track_extra_parameters` list does **not** include `statement_timeout`, and its
own page warns that "Most parameters cannot be fully tracked this way."

**4. The arithmetic does not need a pooler yet.** Nine services × the per-role
limit of 10 = 90, plus the admin role and headroom, against a raised
`max_connections` of 200. Postgres's own default of 100 is genuinely too low for
this topology — but raising a number is a five-minute change, and a pooler is an
architectural change that touches every driver in seven languages. If the fleet
grows past the budget, the first honest move is to raise the budget again, and
`tests/validate.sh` fails the build when `KIT_POSTGRES_MAX_CONNECTIONS` is set
below what the declared databases actually need.

### What this decision costs, stated plainly

- Nine services' connections all land on one server, so a memory-hungry backend
  in one service is a memory-hungry backend on the box. Mitigated by the
  per-role `CONNECTION LIMIT` and the per-role timeouts, not prevented.
- The connection budget is a real ceiling. A service that genuinely needs more
  has to raise its share in two places (its own config and
  `KIT_POSTGRES_ROLE_CONNECTIONS`) and say why in the PR.
- We lose multiplexing: with no pooler, a service with 3 concurrent requests and
  a pool of 10 holds connections it is not using. At this scale that is free; at
  ten times this scale it is not, and the answer then is a pooler **plus** the
  per-language flags **plus** the `RECONNECT` step, which is a much bigger
  decision than it looks now.

### How the decision stays visible

The pooler flags are **forbidden** in `contract.json`, and the gate fails the
build if one appears in any generated config. That is the check that makes this
a decision rather than a paragraph: a service carrying `prepare: :unnamed` looks
correct, is wrong, and is slower, and the only way anyone would notice is by
looking for the flag.

## The four settings, and why each one exists

None of these would be needed with one Postgres per service. All four are needed
with one Postgres for nine.

| setting | what it prevents |
|---|---|
| `application_name` | an unattributable query. `pg_stat_activity` shows nine services in one list; without this there is no way to say whose query is the slow one. |
| `statement_timeout` | one service's runaway query occupying shared resources until it finishes. |
| `idle_in_transaction_session_timeout` | the shared-cluster killer: one forgotten `BEGIN` holds a snapshot open, blocks `VACUUM`, and grows every table on the box. |
| a bounded pool | one service consuming the connections the other eight need. |

The cluster sets the middle two **per role** as a backstop, and each service sets
all four in its own generated config as the first line. A service that forgets is
still bounded; a service that raises them raises the cluster's backstop too, and
the two are documented as needing to move together.

## Extensions

`postgres:17-alpine` cannot carry pgvector. pglayers publishes each extension as
a glibc-linked layer built from the PGDG **Debian** packages, and the alpine base
is musl. Measured:

```console
$ # FROM postgres:17-alpine + COPY --from=ghcr.io/pglayers/pgx-pgvector:17 / /
$ psql -c 'CREATE EXTENSION vector;'
ERROR:  extension "vector" is not available
$ ldd /usr/lib/postgresql/17/lib/vector.so
Error loading shared library ld-linux-aarch64.so.1: No such file or directory
Error relocating …/vector.so: palloc0: symbol not found
```

Two independent failures, either fatal: the musl loader cannot resolve a glibc
binary, and alpine's PostgreSQL looks under
`/usr/local/share/postgresql/extension` while pglayers writes to
`/usr/share/postgresql/17/extension`. On `postgres:17` the same layer works:

```console
$ psql -c 'CREATE EXTENSION vector;'
CREATE EXTENSION
$ psql -tAc "select '[1,2,3]'::vector <=> '[1,2,4]'::vector < 1"
t
```

So the cluster image is Debian-based. That is a real cost, paid deliberately,
and the whole measurement is in `templates/compose/postgres/Dockerfile`.

**What the image does and does not do.** The image makes `CREATE EXTENSION vector`
*possible* in every database on the cluster, because an extension's binaries are
cluster-wide. It does not create one. `initdb/10-cluster.sh` creates them, as the
**admin role**, into every declared database.

Two consequences worth stating:

- **A service role cannot create an extension.** pgvector's control file is not
  marked `trusted`, so `CREATE EXTENSION` by a non-superuser is refused with
  `HINT: Must be superuser to create this extension`. Checked against pglayers'
  layer *and* upstream pgvector v0.8.6, whose `vector.control` is byte-identical
  — this is pgvector's own classification, not something the packaging drops.
- **Extension availability is a cluster decision, not a per-service one.** Which
  is the right shape here anyway: the binaries are available to every service
  regardless, so a per-service grant would only have governed who pays the disk
  cost.

`templates/parity-allowlist` and `DECISIONS.md` carry the rest.

## Adopting this

1. Add your service's name to `KIT_POSTGRES_DATABASES` in your `.env`.
2. `bin/dev down -v && bin/dev up` **once**. `docker-entrypoint-initdb.d` runs
   only on a fresh volume, so adding a database to a running stack does nothing.
   For an existing database, `bin/dev db grant <name>` prints the statements
   rather than telling you to delete your data.
3. Copy `templates/database/<lang>/` from the ref your `kit.ref` names, and change
   the service name in it.
4. If you hold customer rows, adopt `templates/database/tenancy/`: apply
   `substrate.sql`, call `cafaye.protect_table` from each account-scoped table's
   migration, point the application at `<service>_app`, and copy the
   per-language `tenancy_test.*` beside `isolation.sql` and `assertions.txt` with
   `REQUIRED_DB=1`. A service holding **no** customer rows is core's honest zero
   and needs none of it — `tenancy.yml` says `accountScoped: false` and that is
   the whole declaration.

**Step 1 is the whole of step 1, and it is not an override.** `KIT_POSTGRES_DATABASES`
is where a database and a `NOSUPERUSER` role come from, and reaching it through
`.env` is what gets you both. kit used to tell services to get their database
instead by overriding `POSTGRES_DB` / `POSTGRES_USER` on the shared `postgres`
service, and that advice was wrong in two ways at once, measured on a cluster
built from this directory's `initdb/10-cluster.sh`:

- the official image creates `POSTGRES_USER` as a **superuser**, so the override
  makes the overriding service's role a cluster superuser — measured, it reads
  another service's table (`select count(*) from invoices` against `courier`
  returns `2`) where a provisioned role is refused at the door with
  `FATAL: permission denied for database "identity"`;
- the image creates that role and that database before any init script runs, so
  `CREATE ROLE` / `CREATE DATABASE` in `10-cluster.sh` then fail, `ON_ERROR_STOP=1`
  makes it fatal, and it fails during initdb — the **whole cluster** refuses to
  start. Measured, exit status 3 and `ERROR:  role "identity" already exists`.

`POSTGRES_PASSWORD` is refused for the weaker reason that it is the credential
every role on the cluster is handed, so one service's file would choose it for
all the others. The cluster's own identity and credential are
`KIT_POSTGRES_USER` / `KIT_POSTGRES_DB` / `KIT_POSTGRES_PASSWORD`, all declared
in `templates/compose/docker-compose.yml`. Setting any of the three in your own
compose file takes the choice away from the services sharing the cluster.

**Step 2 is the one to read twice, because it prints a `REVOKE` and the revoke
is the boundary.** A database created outside the init script gets Postgres's
default, which grants `CONNECT` to `PUBLIC` — so a database added by hand and not
revoked is reachable by **every role in the cluster**, whatever the table grants
say. `bin/dev db grant` prints that statement alongside the others precisely so
it is impossible to run the provisioning and miss the boundary. The two
properties that make this worth the paragraph: the boundary holds **by
construction** for every database declared in `KIT_POSTGRES_DATABASES` on a fresh
volume, and a database added afterwards is **the operator's to close**. It is
the one part of the contract an init script cannot make airtight, because
initdb runs once and cannot sweep a database that does not exist yet.

## The two properties to read before trusting any of it

- **`docker-entrypoint-initdb.d` runs once per volume.** Everything above is
  re-applied by recreating the volume, and nothing above is re-applied by
  restarting a container. A cluster that was provisioned before a service existed
  will not gain that service's database on `bin/dev up`.
- **The init script's role topology is asserted, in both directions.**
  `<service>_app` existing is checked, `<service>` being able to impersonate it is
  checked, and **`<service>_app` NOT being a member of `<service>` is checked** —
  because a claim that a membership direction is allowed is worth nothing without
  the claim that the other one is not, and the other one hands the application
  every privilege the owner has. `tests/isolation_test.sh` asserts all three.

- **The init script fails loudly, and it is designed to.** A cluster that cannot
  apply the boundary does not start. This was learned the hard way: an earlier
  version tested for a database's existence with a command substitution inside an
  `if` condition, `set -e` could not see the failure, and the script exited 0
  reporting a boundary it had not applied.