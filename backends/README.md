# CI backends

**A project writes a pipeline, kit runs it.** The pipeline is the project's
own — its gate, its build, its deploy — and it lives in the project at
`ci/pipeline.sh`. The backend is how that pipeline gets triggered and with
what environment, and it is chosen once, in `ci/backend`:

```
instabox
```

| backend | what it is | when it is the right one |
| --- | --- | --- |
| `github-actions` | GitHub Actions, via `.github/workflows/` calling kit's reusable workflows | the default; free minutes exist |
| `instabox` | a sandbox that polls the repo and runs the pipeline on new master | Actions minutes are gone, the run needs to reach a private network, or the machine matters |

## The contract

A project's `ci/pipeline.sh` must:

1. be executable (`chmod +x`), run from anywhere, and be idempotent — the
   backend runs it repeatedly;
2. read its inputs from the **environment the backend provides**, never from
   the backend's shape. The variables every backend provides:

   | variable | meaning |
   | --- | --- |
   | `WORKSPACE` | the directory holding `cafaye/<name>` checkouts |
   | `GH_TOKEN` | a token that can read the project's private sources |
   | `CI` | `1`, so a pipeline can skip interactivity |

3. anything else — a deploy host, a key, a bucket — the project declares and
   the backend materializes from its own secret store. The instabox backend
   reads `$HOME/.ci-env` (one `KEY=value` per line, written by provision);
   GitHub Actions reads repository secrets. A pipeline that reads
   `DEPLOY_HOST` works on both without knowing which.

### The database

A project whose gate needs Postgres declares a database and the instabox
backend runs **one Postgres for the whole sandbox** and creates `<project>`
database + `<project>` role for it, so the project's own `bin/dev`-style stack
is replaced by a fixed server it connects to. Provision it with `--postgres`:

```sh
GH_TOKEN=… backends/instabox/provision.sh --postgres cafaye-build billing courier docs identity
```

The projects that declare one are read, never invented: each of `identity`,
`billing`, `courier`, `darkroom` and `box` names a `postgres:17-alpine` service
in its `.github/workflows/ci.yml`, and the rollout table below records the same
column. `provision.sh` reads the declaration from `CI_DB_PROJECTS`, whose
default is exactly that list. A project not in it gets no database and no URL.

For each declared project the env carries two names, **both pointing at the
same database** — the fleet's gates read both:

| variable | who reads it |
| --- | --- |
| `DATABASE_URL` | a migration step; identity's `bin/migrate` proves this name before applying a migration |
| `TEST_DATABASE_URL` | a test tier; identity's `bin/prime` skips its 1,732 database tests when this is unset, and its `bin/provision-testdb` provisions the owner/app roles and applies migrations when it is set |
| `TEST_DATABASE_ADMIN_URL` | a gate that provisions its own roles (the name identity's `bin/provision-testdb` reads) |

Four properties of the sandbox's Postgres, each a check rather than a hope:

- **One container, `postgres:17-alpine`, on `CI_POSTGRES_PORT` (default 5432).**
  Re-running provision starts it; it is never replaced, so its data and its
  roles' passwords survive. `docker inspect` is the existence test.
- **Passwords are generated once and kept.** Each project's password lives at
  `~/ci/pg-passwords/<project>` (0600) on the sandbox and is re-read on every
  re-provision; the role is created only when absent and an existing role's
  password is never rotated. A re-provision that rotated it would turn every
  run red until the container restarted, because the running agent's env still
  named the old credential.
- **The database is the boundary.** `REVOKE ALL ON DATABASE <project> FROM
  PUBLIC` and `GRANT CONNECT` back to its own role: this is the fleet's
  one-cluster rule in miniature (docs: `architecture/one-cluster.md`), and
  without the revoke a project's role could reach another's rows.
- **The timeouts are set per role**, the shared-cluster backstop:
  `statement_timeout` and `idle_in_transaction_session_timeout`, plus a
  `CONNECTION LIMIT`, overridable with `CI_PG_*` variables.

### Gate concurrency on a shared sandbox

Two projects' gates running at once is **normal and fine** here: their
databases are separate, so they share nothing. A project whose GATE cannot run
beside another's — a fixed port, a global temp path — declares it with
`CI_GATE_SERIAL=1` in its env (via provision's `CI_EXTRA_ENV`), and the agent
then serialises it against every other declaring project with a sandbox-wide
lock. The resource is machine-wide, so the lock is too.

**Which projects need it, read from their workflows and READMEs.** On a Linux
sandbox, none of the five database projects does. `box` is the one whose gate
has a serial mode at all: its README says `bin/ci` runs the suite serially
**on macOS**, because parallel workers fork with the `pg` gem connected and
segfault the Ruby VM — and its `.github/workflows/ci.yml` sets
`PARALLEL_WORKERS: '4'` with the note that "CI is Linux, where the fork is
safe". The sandbox is Linux, so box's gate is concurrent-safe there and does
not set the flag. kit's own `tests/validate.sh` is the worked example of a gate
that WOULD set it — its Docker tiers claim a fixed 15000–15999 port block and
stay serial — but kit is not in the rollout table.


## Switching backends

Change the one line in `ci/backend` and, for `github-actions`, ensure the
workflow files exist. The pipeline is unchanged; that is the point. A project
that wants a third backend (a self-hosted runner, a cron on a box) adds
`kit/backends/<name>/` and a line to the table above, and every other
project's pipeline keeps working.

## What kit owns vs what the project owns

| kit | the project |
| --- | --- |
| the poller, the provisioner, the backends' plumbing | `ci/backend` and `ci/pipeline.sh` |
| the secret-store mapping per backend | which secrets it needs, declared in its README |
| the switch, in one file | nothing about the runner's shape |

## One sandbox, many projects

The instabox backend's agent is a **sleep-loop**. It is worth saying why that
matters before any of the arithmetic below: a poller costs a process and ~3 MB
of resident memory and **zero CPU while it sleeps**. What costs real resources
is a **gate run**, and gates are bursty — one every few hours per project, a
few minutes each, and the poll phases of independent projects are not
synchronized. So the sandbox's capacity is not "how many pollers fit"; it is
"how many gate runs can overlap on 4 vCPU, 8 GB and 20 GB", and the pollers
themselves are free.

`backends/instabox/provision.sh` therefore takes a **list** of projects and
writes one agent per project — `~/ci-env.d/<project>.env`,
`~/ci/agents/<project>.sh`, its own log and pid — and a supervisor that starts
and restarts them all. The single-project form still works: the list has one
element. The measured machine and the measured capacity:

```
$ instabox usage
Sandboxes:     2 / 5
Sandbox size:  4 vCPU · 8 GB · 20 GB
```

| resource | a poller | a gate run | so a 4 vCPU / 8 GB / 20 GB sandbox carries |
| --- | --- | --- | --- |
| CPU | ~0 (sleeping) | 1–4 vCPU, in bursts | **4** overlapping gates before CPU is the wall |
| RAM | ~3 MB | 1 GB (Go), ~1 GB (Rails/Elixir), ~1.5 GB (Node `npm ci` + vitest) | 4 gates ≈ 4–5 GB, under 8 GB |
| disk | 0 | 2–3 GB per project (checkout + deps + images) | 4 projects ≈ 12 GB of 20 GB |
| pollers | 3 MB | — | 13 pollers ≈ 40 MB, under 1% of RAM |

**The planning number is N = 4 projects per sandbox, and N = 5 is the
ceiling.** CPU and disk set it, not memory: five concurrent gates fit in RAM
but the twenty-gigabyte disk is the first thing to run out. Five sandboxes ×
four projects = **twenty slots**, against **thirteen services** (plus `kit` and
`core`, which are specs and never publish) — the whole fleet fits on **four
sandboxes, with the fifth spare**. The cap itself is the plan's hard edge:
`instabox usage` reports `5` sandboxes maximum, so a fleet larger than twenty
projects needs a second sandbox only after the disk is measured, not before.

### The rollout table

`cafaye-build` already exists and already runs `docs`; `box-4c652a` is the
test-tier sandbox and is not a CI host. The first wave lands on `cafaye-build`,
and each following sandbox carries the next four. One project per line, and
the gate column is the fact a pipeline's MARKED 1 must carry — read from the
repository's own `.github/workflows/ci.yml`, never assumed. The database column
is the same kind of fact: a project is `yes` when its `ci.yml` names a
`postgres:17-alpine` service, and it is those five names that `provision.sh`'s
`CI_DB_PROJECTS` defaults to.

| sandbox | projects | gate entrypoints | database |
| --- | --- | --- | --- |
| `cafaye-build` (exists) | `docs`, `billing`, `courier`, `identity` | `./bin/prime` ×4 | `billing`, `courier`, `identity` |
| `cafaye-release` (new) | `box`, `pantry`, `parlor`, `website` | `bin/ci`, then `./bin/prime` ×3 | `box` |
| `cafaye-libs` (new) | `gateway`, `cafe`, `core`, `muse` | `./bin/prime` ×4 | none — no `postgres:17-alpine` service in any of the four |
| `cafaye-rest` (new) | `keyholder`, `darkroom`, `cafaye-ts` | `bin/gate`, then `./bin/prime` ×2 | `darkroom` |
| *fifth slot* | spare, or the second wave of the three libraries (`cafaye-py`, `cafaye-rb`) | — | `cafaye-rb` (its own `ci.yml` names `postgres:17`, not `-alpine`) |

Because a sandbox carries at most one or two database projects in this
placement, `--postgres` is given on the first three rows and not on
`cafaye-libs`, which has none. A project that starts one Postgres per job on
Actions (a `services:` block) is exactly the project that needs a database
here; a project that finds Postgres binaries on the runner (`pantry`) is not.


`docs` is already on `cafaye-build` under the **single-project** provisioner.
Re-provisioning it with the multi-project form migrates it: the per-project
env inherits the old `~/.ci-env` (so `DEPLOY_HOST` survives), the supervisor
takes over the agent, and `ci/pipeline.sh` is not touched.

### The order a service adopts this in

1. **Copy the template.** `backends/instabox/pipeline.template.sh` →
   `ci/pipeline.sh`, `chmod +x`. Edit the three MARKED places — the gate
   command, any PATH entries, and the ship step — each of which says in its
   comment where in `.github/workflows/` to read the fact.
2. **Take the publish tool** if this repository ships a chart: copy kit's
   `templates/bin/publish.sh` to `bin/publish`, `chmod +x`. Do not reimplement
   the push; the tool derives the image digest, stamps the chart and refuses a
   malformed one.
3. **Write `instabox`** into `ci/backend`. Commit and push `master`.
4. **Provision.** On the operator's machine, logged into `instabox` and `gh`:
   `GH_TOKEN=… backends/instabox/provision.sh cafaye-build <project>`. A gate
   that needs Postgres takes `--postgres` —
   `… provision.sh --postgres cafaye-build billing courier docs identity` —
   and `DATABASE_URL`/`TEST_DATABASE_URL` land in the project's env. A chart
   publisher is logged in once more —
   `cat token | bin/publish --sandbox --sandbox-name cafaye-build`.
5. **Watch one green run.** `instabox ssh <sandbox> -- tail -f
   ~/ci-logs/<project>.log` until `agent[<project>]: shipped <sha>` and the
   pipeline's own last line agree on what shipped. That is the whole
   verification; a green run on the sandbox is the point of the backend.

The `agent.sh` poller, the `supervisor.sh` restart loop and the per-project
binding are all kit's; a service writes only `ci/backend` and `ci/pipeline.sh`.
