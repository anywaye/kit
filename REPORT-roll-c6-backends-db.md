# REPORT — `roll-c6-backends-db`

**What the packet asked for.** `backends/instabox/` hosts several projects'
pollers on one sandbox and `pipeline.template.sh` shows a service how to run its
gate — but five services' gates need a Postgres (identity, billing, courier,
darkroom, box) and the sandbox had none, so a project's first run died at its
first migration on a machine nobody provisioned for it. Give the provisioner
per-project databases, put the two URL names in the project's env, record which
projects declare a database in the rollout table, and write down the
shared-sandbox gate-concurrency caveat.

**Verdict: built and proven.** `bash -n` and `shellcheck` are clean on every
script and kit's own gate is green. The database path was exercised for real
against the free test sandbox `box-4c652a`: a container and a project database
were created, a role connected over TCP, the boundary refused a second
database, and a **re-provision left the password byte-identical**.

---

## 1. What changed

One commit at Q1 (`9bbad8b`), plus a two-line guard commit for the empty-password
case:

```
 backends/README.md                    | 100 ++++++++++++++++++++--
 backends/instabox/agent.sh            |  54 ++++++++++++++-
 backends/instabox/pipeline.template.sh|  35 ++++++++-
 backends/instabox/provision.sh        | 175 +++++++++++++++++++++++++++++++----
 tests/validate.sh                     |  38 +++++++++++
 CHANGELOG.md                          |  28 +++++++
 REPORT-roll-c6-backends-db.md         | (this file)
```

### `provision.sh` — `--postgres`

The invocation is now `provision.sh [--postgres] <sandbox> <project> [...]`.
The flag is parsed in a first pass so it may appear before the sandbox name:
`provision.sh --postgres cafaye-build billing courier docs identity`.

With `--postgres` set, provision:

1. **Ensures ONE container**, `ci-postgres`, `postgres:17-alpine`, on
   `CI_POSTGRES_PORT` (default 5432), backing the data with a named volume. If
   the container exists it is *started*, never replaced — `docker inspect` is
   the existence test. This is the `press-pg` shape the rehearsal used
   (`box-4c652a` still runs `press-pg` on 5433 from that run), generalized to
   N projects.
2. **Ensures `<project>` database + `<project>` login role** for every project
   that declares a database, idempotently: `CREATE ROLE` only when the role is
   absent, `CREATE DATABASE ... OWNER` guarded by `\gexec`, then the boundary —
   `REVOKE ALL ON DATABASE <project> FROM PUBLIC` and `GRANT CONNECT` back to
   its own role, plus the per-role timeouts and a connection limit. That is the
   fleet's own one-cluster rule (`docs/architecture/one-cluster.md`,
   `templates/compose/postgres/initdb/10-cluster.sh`) in miniature.
3. **Writes the URL pair into the project's env**, plus `PROJECT_DB=1` and
   `TEST_DATABASE_ADMIN_URL`.

**Which projects declare a database** is `CI_DB_PROJECTS`, whose default is the
five names read from their `.github/workflows/ci.yml` `postgres:17-alpine`
service blocks. The README's rollout table carries the same fact as a column.
`CI_DB_PROJECTS` is overridable, which is how the real verification below gave
`docs` a database without touching a service.

### The password is generated once and kept

The measured trap: a re-provision that rotates the password under a live agent
turns every run red until the container restarts. So the password is stored on
the sandbox at `~/ci/pg-passwords/<project>` (0600) and **re-read** on every
re-run; the role is created only when it is absent, and an existing role's
password is never touched. The only `ALTER ROLE ... PASSWORD` is the case where
the store is *absent* but the role exists (a store somebody deleted), and that is
safe precisely because nothing recorded the old credential. The container is
likewise never recreated.

### `agent.sh` — `CI_GATE_SERIAL`

Two projects' gates running at once is normal and fine: their databases are
separate. A project whose gate cannot run beside another's (a fixed port, a
global temp path) declares `CI_GATE_SERIAL=1` in its env, and `run_pipeline()`
then takes a **sandbox-wide** `mkdir`+pid lock (`$WORKSPACE/.ci-gate-locks/serial.lock`)
that serialises it against every other declaring project and *waits* rather than
exiting. The resource is machine-wide, so the lock is too; the per-agent lock
that already existed only stops a project overlapping itself.

### `pipeline.template.sh`, `backends/README.md`, `tests/validate.sh`

The template's header now explains the database: the sandbox's fixed Postgres
**replaces** the project's own `bin/dev` stack, the two names it reads
(`DATABASE_URL` for a migration step — identity's `bin/migrate`; `TEST_DATABASE_URL`
for a test tier — identity's `bin/prime`), and `TEST_DATABASE_ADMIN_URL`. The
README gains the database section, the rollout table's database column, and the
concurrency note. `tests/validate.sh` gains one semantic check: it **runs**
`provision.sh`'s own usage path and requires `--postgres` in it, and greps the
*code* (not the comments) for the env assignment and `CI_GATE_SERIAL`.

---

## 2. What I ran

Everything, with evidence.

| what | where |
| --- | --- |
| `bash -n` + `shellcheck -S warning` on all four scripts | local, clean |
| kit's own gate `bash tests/validate.sh` | local, **exit 0**, `PASS: every check passed.` |
| the new check | `PASS backends/instabox  (--postgres, the DATABASE_URL/TEST_DATABASE_URL pair, and CI_GATE_SERIAL are present)` |
| a **real** `provision.sh --postgres` | `box-4c652a`, twice |

The real run used `CI_DB_PROJECTS=docs GH_TOKEN=… provision.sh --postgres box-4c652a docs`
so it exercised the whole path — container, role, database, env, supervisor,
agent — with a small clone, without touching a service repository. It finished
`exit 0` and `provision: 1 of 1 project agents are running: docs`. The pollers
were stopped immediately afterwards (they would have re-run `docs`' pipeline
every 120 s) and the container, its volume, and `~/ci*` were removed, leaving
`box-4c652a` as it was: only the pre-existing `press-pg`.

### The database, proven

```
$ ssh box-4c652a 'grep -E "^(DATABASE_URL|TEST_DATABASE_URL)=" ~/ci-env.d/docs.env'
DATABASE_URL=postgres://docs:9aa505…bdadf9d9c@localhost:5432/docs?sslmode=disable
TEST_DATABASE_URL=postgres://docs:9aa505…bdadf9d9c@localhost:5432/docs?sslmode=disable

$ ssh box-4c652a 'PGPASSWORD=$(cat ~/ci/pg-passwords/docs) \
    docker exec -e PGPASSWORD ci-postgres \
    psql "postgres://docs@localhost:5432/docs?sslmode=disable" -tAc \
    "select current_user, current_database()"'
docs|docs

# boundary: the same REVOKE applied to a second database
$ … psql "postgres://docs@localhost:5432/iso?sslmode=disable" -tAc "select 1"
psql: error: … FATAL:  permission denied for database "iso"
DETAIL:  User does not have CONNECT privilege.
```

### Password stability, proven

```
before: sha256 38630209b4ec9d13e56c4858edc431bc12b01c9413c3a5b7538efc4f72f3c30e
        value  9aa505c2d281de13fc0434bd3049a2a760bf841dbadf9d9c
# re-run provision.sh --postgres box-4c652a docs   →  exit 0
after:  sha256 38630209b4ec9d13e56c4858edc431bc12b01c9413c3a5b7538efc4f72f3c30e
        value  9aa505c2d281de13fc0434bd3049a2a760bf841dbadf9d9c
IDENTICAL — password stable across re-provision
```

The second run's own log line records the mechanism:
`provision: ci-postgres exists — started; its data and role passwords are kept`.

---

## 3. The gate-concurrency finding

**On the Linux sandbox, no project in the fleet has a gate that cannot run
beside another's.** The candidate is `box`, and its own files say why it does
not qualify: `box/README.md` states the gate runs the suite serially by default
*on macOS* because "the parallel workers fork with the `pg` gem connected and
segfault the Ruby VM", and `box/.github/workflows/ci.yml` sets
`PARALLEL_WORKERS: '4'` with the note that "CI is Linux, where the fork is safe".
The sandbox is Linux, so `box` is concurrent-safe there. The packet brief says
kit's README already carries this note; it does not — the note is `box`'s — and
the README here records the fact rather than repeating a claim kit's own tree
cannot support. kit's `tests/validate.sh` *would* set `CI_GATE_SERIAL` (its
Docker tiers claim a fixed 15000–15999 port block and stay serial), but kit is
not in the rollout table, so the declaration ships with nothing set.

---

## 4. What I deliberately left alone

- **No service repository.** The five `ci.yml` files and `box`'s README were
  *read* and not modified.
- **The multi-project agent behaviour** this packet builds on — one poller per
  project, the supervisor, the per-agent lock — is unchanged; the serial gate
  lock is additive and off unless `CI_GATE_SERIAL=1`.
- **No new kit dependency.** The container, the roles and the passwords are the
  sandbox's; kit gains nothing. `postgres:17-alpine` is the image the five
  services' CI already runs, not a new choice.
- **`github-actions`** and the single-project provisioner form are unchanged.
- **The app-role split** (`<project>_app` and RLS) is deliberately *not*
  provisioned here: the packet asks for `<project>` database + role, and a
  service that needs its app role provisions it in its own gate — which is what
  identity's `bin/provision-testdb` does, and what `TEST_DATABASE_ADMIN_URL` is
  for.
- **The `press-pg` rehearsal container** on `box-4c652a` is untouched.

## 5. Honest gaps and the successor's first move

- **The serial gate lock is not executed by any test.** It is `bash -n`-clean
  and `shellcheck`-clean, and the acquire/hold/release shape is the same
  `mkdir`+pid shape the per-agent and supervisor locks already use, but no run
  has contended it. The successor's first move is a two-project fixture that
  sets `CI_GATE_SERIAL=1` on both and asserts their pipeline windows do not
  overlap.
- **`TEST_DATABASE_URL` is the same database as `DATABASE_URL`, and one gate
  may not want that.** The packet requires the pair and says both must point at
  the same database; a project that needs a separate test database names its own
  in `CI_EXTRA_ENV`.
- **Nothing migrates.** Provision creates an empty database; the project's gate
  applies its own migrations (identity's `bin/provision-testdb`, `bin/migrate`).
  That is the `press` rehearsal's shape — container, database, the service's own
  migrations, then the gate — and it is left to the service by design.

## 6. Worktrees used

- `moon/cafaye/kit/wt/roll-c6-backends-db` (this branch). No second repository
  was modified; service repos were read only.
