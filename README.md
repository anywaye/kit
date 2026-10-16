# kit

**kit is the shared CI, lint, and toolchain layer every cafaye service repo
adopts.** It contains no runtime code and no dependencies — only conventions
that would otherwise be retyped, and slightly differently, in each of the six
services.

```
github.com/cafaye/cafe     Go       github.com/cafaye/billing  Ruby
github.com/cafaye/identity Go      github.com/cafaye/courier  Elixir
github.com/cafaye/gateway TypeScript  github.com/cafaye/muse   Python
github.com/cafaye/darkroom Rust    github.com/cafaye/parlor   TypeScript
```

Every one of those repos **calls** the same workflow. A change to how we build
lands in kit once, and reaches the next service on its next run.

Every one of those repos also *copies* the same linter configs and the same
scripts — and **how much they actually match is measured, not assumed.** See
[what the fleet actually adopted](#what-the-fleet-actually-adopted) below.

**kit's own version is `VERSION`, and it is the single source of truth for how
safe a version is to consume.** Because services are adopted by copy, "is 2.4.0
safe to take?" is the only question a consumer has, and it used to be answered by
a person reading a diff. The tier is now **derived** from the version string and
**gated on**, not described:

| the bump | the tier | what a consumer may do |
| --- | --- | --- |
| MAJOR | `breaking` | read `MIGRATIONS.md` for that version — a MAJOR without one is a red build |
| MINOR | `additive` | take it; nothing a consumer holds went away |
| PATCH | `invisible` | take it without reading anything |

A version string the derivation cannot place — `1.0.0-rc1`, `v1.4.0`, a backwards
move — is a **red build, not a guess**, and `RESERVED` is the other half: a name
kit has retired, kept dead. Both are below, and both are in `DECISIONS.md`
(MD26, MD27).

## What the fleet actually adopted

**A dated measurement, not a live one.** It was taken on 2026-09-30 against
`41f8bcb` by `tests/staleness.py --scope templates`, which read the nine services
beside this repository and has since been removed along with the rest of the
cross-repo surface (MD36). Nothing re-runs it, so read the numbers below as what
was true on that date. Over those nine services (the fleet the packet counts;
`docs` and `cafaye-{py,rb,ts}` are toolchain repos, not services, and
`pantry` is a registry that has not called kit's workflow). **Nine of 108 cells are
byte-identical.** One of them, `gateway/bin/prime`, is the only copy in the fleet
that matches kit exactly — and it matches because `gateway` is the service that
caused kit's `bun` job to exist, so it is the one service that copied a template
*after* it was written rather than before. That is the whole adoption story in
one cell.

| artefact | byte-identical | diverged | absent | unknown | not applicable |
| --- | --- | --- | --- | --- | --- |
| `ci.reusable.yml` | **8/9** | 0 | 1 | 0 | 0 |
| `bin/prime` | 1/9 | 7 | 0 | 1 | 0 |
| `docker/Dockerfile` | 0 | 7 | 1 | 1 | 0 |
| `mise.toml` | 0 | **9/9** | 0 | 0 | 0 |
| `AGENTS.md` | 0 | **9/9** | 0 | 0 | 0 |
| `bin/dev` | 0 | 1 | **8/9** | 0 | 0 |
| `compose` (12 files) | 0 | 7 | 2 | 0 | 0 |
| `lint/yamllint.yml` | 0 | 0 | **9/9** | 0 | 0 |
| `lint/hadolint.yaml` | 0 | 0 | **9/9** | 0 | 0 |
| `lint/golangci.yml` | 0 | 1 | 1 | 1 | 6 |
| `lint/rubocop.yml` | 0 | 1 | 0 | 1 | 7 |
| `lint/eslint.config.mjs` | 0 | 1 | 1 | 1 | 6 |
| **all twelve** | **9/108** | **43** | **32** | **5** | **19** |

Three findings the packet's brief did not contain, and all three changed what
was built:

1. **`mise.toml` and `AGENTS.md` are 9/9 *diverged*, and the two divergences
   mean opposite things.** `mise.toml` is adoption working: the template is
   kit's **union of every language's tool pins** (19 tools, 74 code lines), so a
   service keeping two of them and raising the versions reads as 80–110 lines of
   divergence by construction — `muse` keeps `python` and `uv` out of nineteen.
   `AGENTS.md` is the opposite: the template is 121 lines and each service
   wrote its own 281–664 line document, keeping only **12–40** of the
   template's lines. `## Observability` — the template's largest section, and
   the one recording the telemetry convention — **survives in none of the
   nine**, including the eight that adopted that convention through kit's own
   workflow. The template was superseded, not filled in.
2. **`lint/*.yml` is not 0/9. It is 3 diverged, 3 absent.** `billing`,
   `parlor` and `identity` each hold their own linter config, all three
   differing from kit's, and none of the three carrying kit's STRICTNESS NOTES
   block — which is where a config records *what* it enforces and why. The
   honest sentence is "nobody lints with kit's rules", not "nobody lints".
3. **The local stack is not "drifted", it is *not there*.** Of the twelve files
   in `templates/compose/`, the fleet holds `docker-compose.yml` in six
   services and `.env.example` in two, and seven services hold at least one
   member. The collector, Tempo, Loki and
   the Grafana provisioning are **0 of 12, in all nine services**. Those six
   compose files are each ~420 lines different from kit's, and the number is
   the least interesting thing about them. They are also **replacements rather
   than broken copies**: none of them mounts a single one of kit's stack files
   (`grep -cE '\./(otel-collector|tempo|loki|grafana)'` is 0 in all
   six), each declares one or two services of its own, and
   `docker compose config` is **green on five of the six** — so they are valid
   stacks that are simply not this one. The reporter calls the state `diverged`
   and reports the member breakdown; it does not claim the stack is broken,
   because comparing bytes cannot tell those two situations apart.

`templates/parity-allowlist` carried all 80 findings — every diverged copy,
every absence and every unmeasurable cell — as one line each, with a reason, an
owner, a `since` and an `until`. **80 was a bad number and it was meant to be
read as one.** It is gone with the reporter, so the count is now history rather
than something a green run prints.

## What is in here

| Path | What it is | Who uses it |
|------|-----------|-------------|
| `.github/workflows/ci.reusable.yml` | One reusable GitHub Actions workflow. Input `language` picks one of seven jobs — install, lint, test, coverage gate. Opt-in `telemetry` input adds the traceparent conformance job; opt-in `required-tier` demands a tier by gate-variable name. **Plus one opt-in security job: `zizmor`.** No job builds or pushes an image — that is the other file. | Every service, via a 6-line `.github/workflows/ci.yml` |
| `.github/workflows/image.reusable.yml` | **The second reusable workflow**, and it exists because `ci.reusable.yml` deliberately does not build an artifact: it is the gate, and a gate that publishes is a gate whose failure is a rollback. It builds the service image and publishes it to ghcr.io, and **the caller grants `packages: write`** — a reusable workflow cannot grant itself a permission. "One file per standard" means three files here, not one — the gate, the image, and now the chart — and a caller reaches each by `uses:`, never by copying. Every workflow file is parsed by the gate's artifact loop and linted by zizmor; the old `REUSABLE_WORKFLOWS` enumeration that used to police callable paths was cut with the self-test layer in w21 (ce12131) and has not been replaced. | A service that ships a deployable artifact, via a 9-line `publish.yml` |
| `.github/workflows/chart.reusable.yml` | **The third reusable workflow — the publish end of the pull-based loop.** `DEPLOYMENT.md`'s loop is pull-based (a commit changes a chart, Argo makes the box agree) and only the consume end existed: eight Argo `Application`s pull each chart's own path under `oci://ghcr.io/cafaye/charts` and nothing in the fleet ever ran `helm push`. This workflow packages the chart directory and pushes it to the OCI registry. The chart's **name and version are read from `Chart.yaml`, never inputs** — the OCI tag of a Helm chart IS its `version`, so the push tag and the pull `targetRevision` are one fact written twice. `push` defaults to **false**, exactly as the image workflow's does; the job refuses to publish from a `pull_request`; helm is pinned (`v4.3.0`), not `latest`; the credential is the workflow's own `GITHUB_TOKEN` and **the caller grants `packages: write`**. | A service that ships a chart, via the composed caller below |
| `.github/workflows/publish.reusable.yml` | **The composition: one caller, two artifacts.** A service publishes the image `config/deploy.yml` deploys and the chart the `Application` pulls; this file calls both `image.reusable.yml` and `chart.reusable.yml` and threads the caller's single `push` input through, so a service's `publish.yml` is one `uses:` and the decision "what does a push publish" is made once, in kit. Its local `uses:` paths are **root-relative** (`./.github/workflows/<file>`) — that is GitHub's grammar, and any other spelling is a run refused at resolution time with no jobs and no logs. It also runs a small `resolve` job that reads `appVersion` from `<chart-dir>/Chart.yaml` and hands it to the image job as `app-version`, so the tag the chart's `values.yaml` pins is a tag the publish produces; empty for a service with an image and no chart, and `sha-<40>` is untouched. It declares the full `contents: read` + `packages: write` set at top level so the nested jobs keep `packages: write` through two levels of `workflow_call`, and its `concurrency.group` is `kit-`-namespaced per the fleet rule. | Called by `templates/publish/publish.yml` |
| `templates/publish/publish.yml` | **The caller, copied into a service's `.github/workflows/publish.yml`.** `on: push: branches: [master]`, `permissions: contents: read` + `packages: write`, a `concurrency` group that does **not** begin with `kit-` (a colliding group is a job refused before it starts — no check-run, no log line), and one `uses: cafaye/kit/.github/workflows/publish.reusable.yml@master` with `push: true`. | Every service that ships an image or a chart |
| `bin/publish` + `templates/bin/publish.sh` | **Actions-free publish** — the same image+chart without GitHub Actions. `docker build -t ghcr.io/cafaye/<svc>:<version> -t ghcr.io/cafaye/<svc>:sha-<sha> .` + push, derive `sha256:<64 hex>` digest, stamp `image.digest` into `values.yaml` (replace-or-insert mirroring `chart.reusable.yml`, refusing malformed digest), `helm package` + `helm push` to `oci://ghcr.io/cafaye/charts`. Digest derived never typed, version NOT bumped (Argo `targetRevision` pins it), visibility REMINDED with URL (not API-flippable with a normal token). `--dry-run` prints every command; all network calls bounded via `timeout`. See `docs/publish.md`. | Any machine with docker + a token |
| `bin/publish-sandbox` + `templates/bin/publish-sandbox.sh` | **One-command sandbox provisioning** for the publish above. Creates or reuses instabox sandbox `cafaye-build` (any name), installs `helm v4.3.0` + `gh` if missing, logs in via `token | ... --password-stdin` (never argv), idempotent. `cat token.txt \| bin/publish --sandbox` provisions+logs-in; `instabox ssh cafaye-build` then `bin/publish`. Wrapper around `bin/publish --sandbox`. See `docs/publish.md`. | A developer needing a remote box |
| `backends/README.md` + `backends/instabox/` | **The runner for a project's pipeline, and why one sandbox hosts many.** A project writes `ci/pipeline.sh` and names a backend in `ci/backend`; this backend polls and runs it. `provision.sh` takes a **list** of projects (`provision.sh cafaye-build billing courier docs identity`), writes one `~/ci-env.d/<project>.env` and one `~/ci/agents/<project>.sh` binding per project, and starts `supervisor.sh`, which keeps one poller per project alive (a poller that exits on a transient error is a project that silently stops building). The agent and the supervisor each hold an atomic `mkdir` lock, so a restart cannot race its predecessor. The README carries the rollout table and the capacity arithmetic measured against `instabox usage` (4 vCPU / 8 GB / 20 GB, 5 sandboxes; N=4 projects per sandbox planned). | Every service, as `ci/backend` = `instabox` |
| `backends/instabox/pipeline.template.sh` | **The `ci/pipeline.sh` a service copies and edits in three marked places.** It reads the environment the backend provides (`WORKSPACE`, `GH_TOKEN`, `CI`), sets up the toolchain the repository pins (`mise install`, then the gate under `mise exec`), runs the gate, publishes with `./bin/publish --service-dir .` when `chart/Chart.yaml` exists, and ends with a line naming what shipped and the commit. Its comments cite `.github/workflows/*.yml` as where the facts come from, and name the three repositories whose gate is **not** `bin/prime`: `box` (`bin/ci`), `keyholder` (`bin/gate`) and `kit`. | Every service, as `ci/pipeline.sh` |
| `.github/zizmor.yml` | zizmor's reasoned baselines. One entry. `unpinned-uses` is deliberately **absent** — see `DECISIONS.md`. | Every service, copied verbatim |
| `lint/yamllint.yml` | YAML style, with the three rules Actions forces us to retune. Read at run time via `yamllint -c`, never copied. | Any repo that lints its own YAML; kit's gate uses it on itself |
| `lint/golangci.yml` | golangci-lint v2, correctness linters on, `errcheck` excluded only for `Close`/`Flush`. Read at run time via `--config`, never copied. | Go services |
| `lint/rubocop.yml` | RuboCop, `NewCops: enable`, Metrics left on. Read at run time via `--config`, never copied. | Ruby services |
| `lint/eslint.config.mjs` | ESLint 9 flat config, type-checked rules on. Read at run time via `--config`, and it must be checked out INSIDE the repo — see below. | Node/TypeScript/Bun services |
| `docker/Dockerfile.<lang>` | Seven multi-stage templates. All run non-root. All start through **`docker/entrypoint.sh`, which applies the service's migrations and `exec`s the service** — so a failed migration is a failed container, and the "service is up, the schema is not" cold-start class is gone. `go` and `rust` finish on `debian:*-slim` rather than distroless, because **no distroless variant ships a shell** (measured: `bin/` is empty in both) and a script needs one; the file says so and gives the escape hatch. Linted by `hadolint -c lint/hadolint.yaml`, plus a non-root/no-`:latest`/no-`ADD` check the linter does not cover. | Every service |
| `docker/entrypoint.sh` | The one entrypoint, shared by all seven templates. POSIX sh, parameterised by environment rather than by copy: resolve the migration command → prove `DATABASE_URL` → migrate → `exec "$@"`. `KIT_MIGRATE=auto\|required\|off`, `KIT_MIGRATE_CMD`, and `KIT_MIGRATE_ADVISORY_LOCK` (a Postgres **session**-level `pg_advisory_lock`, opt-in because it needs `psql`). It does **not** serialize replicas by default and says so on every boot. | Copied with the Dockerfile |
| `lint/hadolint.yaml` | hadolint config, with the two ignored rules (DL3008, DL3067) argued rather than assumed. | Any repo that ships a Dockerfile |
| `templates/bin-prime/<lang>.sh` | The worktree primer: one script per language, exit 0 only when the tree is genuinely ready. | Every service, as `bin/prime` |
| `templates/bin/dev.sh` | The local developer loop: **fetch** the stack from a pinned kit ref, bring it up, wait for health, migrate, seed an admin, print the URLs. Idempotent, fails loudly, works offline. **Refuses an uninterpolatable stack in seconds**, naming the required variable and the line to add — Docker Compose substitutes an empty string for a bare `${VAR}` rather than refusing it, so without this a single missing `.env` line costs the whole readiness deadline before it is reported. The required set is **derived from the compose files**, so a service's own `${VAR}` is caught too. | Every service, as `bin/dev` |
| `templates/compose/docker-compose.yml` | Postgres, NATS+JetStream, the one-shot that defines the stream the fleet publishes to, Redis, the OTel collector, and the four LGTM backing services. Every port parameterized inside kit's claimed `15000-15999` block, every image pinned, every service healthchecked and memory-bounded. **One cluster for all services**, with the database as the isolation boundary. | **Fetched** by `bin/dev` — never copied |
| `templates/compose/postgres/Dockerfile` | The shared cluster's image: the official `postgres:17` plus exactly one pglayers extension layer, composed rather than pulled. **Debian, not alpine** — pgvector is a glibc-linked layer and does not load on musl; the measurement is in the file. | **Fetched** with the stack |
| `templates/compose/postgres/initdb/10-cluster.sh` | Creates **two roles and one database** per named service — `<service>` (the owner, which runs migrations) and `<service>_app` (the LOGIN the application uses, which owns nothing) — and applies the boundary: `REVOKE ALL ON DATABASE … FROM PUBLIC` swept over **every** non-template database, plus per-role `CONNECTION LIMIT`, `statement_timeout` and `idle_in_transaction_session_timeout`. The app role is granted **to** the owner and never the reverse; the other direction hands the application every privilege the owner has. Fails loudly rather than coming up half-provisioned. | The cluster, on first `initdb` |
| `templates/database/README.md` | **The connection contract**: the four settings every service's config carries, and the pooler decision with the PgBouncer and Postgrex measurements behind it. | Read before adopting |
| `templates/database/contract.json` | The contract in the form the gate can read: required settings, bounded-pool spellings, the **forbidden** pooler workarounds, and the `tenancy` block (what the row-level-security substrate must contain, and what it must never contain). Read by `tests/validate.sh` against every generated config and against the substrate. | kit's gate; copied by services that check their own |
| `templates/database/<lang>/` | Six per-language connection configs — go, elixir, python, ruby, node (also bun), rust — each carrying the contract and, deliberately, no pooler workaround. | Copied into the service |
| `templates/database/tenancy/` | **The account boundary.** The row-level-security substrate a service applies once, the assertion set that proves it (three denials and one allowance, run as the login role **and** as the owner), the manifest both are checked against, and the **advisor** — eight RLS rules as one SQL function that grades the live database, because a policy whose predicate is `true` satisfies every denial (a permissive predicate returns rows) and no file scanner can see that two permissive policies on one (table, role, command) combine with OR. Ships `FORCE ROW LEVEL SECURITY`, because without it the owner reads every account's rows while the policies read as if they were in place — 1 row with it, 3 without. | Read before adopting; copied into a service that holds customer rows |
| `tests/isolation_test.sh` | **The proof.** Brings the shipped stack up, creates two service databases, and asserts service A is refused service B's database — printing the query and the server's answer. Includes a **control** cluster without the revoke, which must let A in. | kit's gate (needs docker) |
| `tests/tenancy_test.sh` | **The other proof.** Same cluster, the account boundary: assertions run as the login role **and** as the owner, a **control** that deletes `FORCE ROW LEVEL SECURITY` and requires the owner half to go red while the login half stays green, a **measurement** of the `(select …)` wrapping (1 call against 5 over five rows), and the **advisor** run against the same cluster: zero `ERROR`/`WARN` on the tables the substrate wrote, the credential table's exemption released by one hand-written policy, and every rule fired on a fixture built to trip it. | kit's gate (needs docker) |
| `bin/dev db grant <name>` | Adds one service to an **already-running** cluster. `initdb` only runs on a fresh volume, so naming a service in `KIT_POSTGRES_DATABASES` after the fact creates nothing. It **prints** the statements — including the `REVOKE ALL ON DATABASE … FROM PUBLIC` that makes the database a boundary — and does not run them. | Copied into the service, with `bin/dev` |
| `templates/compose/otel-collector.yml` | The collector: OTLP + container-stderr receivers, the redaction allowlist **derived from core's schemas**, the `spanmetrics` connector, and fan-out to Tempo and Loki. Every endpoint a `${env:}`. Derived metrics go to the collector's own stdout — there is no metrics store. | **Fetched** — never copied |
| `templates/compose/{tempo,loki}/` | Vendor **configuration** for the two stores: retention, limits, paths. Read-only mounts over stock images. | **Fetched** — never copied |
| `templates/compose/grafana/provisioning/` | Datasources, the dashboard provider, the fleet error dashboard and the alert rules — all files, working on first load. Nothing to click together by hand. | **Fetched** — never copied |
| `templates/compose/.env.example` | Every `${KIT_*}` the stack interpolates, each with a default. **Fetched, not copied** — `bin/dev` writes it into `.env` on first run. | `bin/dev`, on first run |
| `templates/kamal/deploy.yml.erb` | The Kamal config: service, registry, servers, proxy, and the postgres and backup accessories. ERB for the four values that differ per operator; **every credential is a `NAME`, never a value**. A missing required variable fails the render by name rather than rendering empty. | Every service, as `config/deploy.yml` |
| `templates/kamal/kamal-backup.yml.erb` | What to back up (ONE database, with the content-vs-working-data reasoning written out), where (restic to R2), and for how long (keep-last 7, daily 7, weekly 4, monthly 6, yearly 2 — stated, not inherited from the gem's defaults). | Every service, as `config/kamal-backup.yml` |
| `templates/kamal/drill.sh` | A restore drill that drops its scratch database on **every** exit path and **asserts** rows rather than printing a count — the two things kamal-backup does not do, both found by reading the gem. | Every service, as `bin/drill` |
| `templates/deploy/` and `templates/bin/deploy.sh` | **A custom deploy distribution, and it overlaps with Kamal on purpose.** It is NOT a remote deployment — no TLS, no reverse proxy, no multi-host, no zero-downtime — and the first line of `templates/deploy/README.md` says so before anything else. What it does that `kamal` does not is deliver secrets into a tmpfs **over stdin**, so no credential is ever in `Config.Env`, and to redact output **by shape** — a JWT, an AWS key, a PEM header — which kamal-backup's own `Redactor` does not (it knows env values whose *key* looks secret, and URL credentials, and nothing else). `templates/deploy/reference/courier.deploy.yml` is the worked example. Read this row next to `AGENTS.md`'s "Deploy and backup are Kamal's": Kamal is the standard, this is the seam that carries credentials, and the overlap is a recorded trade rather than a recommendation. | A service that deploys without a Ruby toolchain on the operator's machine |
| `templates/substrate/install.sh` | **The customer substrate — one command, one box.** The executable half of `DEPLOYMENT.md`: installs k3s (single node, sqlite), cert-manager, CloudNativePG, Argo CD core, the GHCR image pull secret (**redeemed** per run from the box's own short-lived, box-bound capability — never a long-lived credential), and the first Applications, in that order. Every version pinned exactly. Idempotent (`kit_substrate_guard`), fails loudly and early, `DRY_RUN=1` prints every step and executes nothing. **No long-lived secret is an input**: identity's OIDC signing key is generated on the box, and courier's identity credential is minted, patched and restarted inside the same run. | The customer's box, via `curl https://cafaye.com/box/install \| sh` |
| `templates/substrate/manifests/applications/` | The eight Argo CD `Application` manifests: the four launch services (identity, gateway, courier, parlor) and the observability set (Alloy, Loki, Grafana, Prometheus). Traces deferred — no Tempo. These are the artifacts a values commit changes and Argo reconciles. | Applied by `install.sh` step 6 |
| `tests/kamal_test.sh` | The proof: generates the config **from the templates** and runs the **real** `kamal` and the real `kamal-backup` against it. 22 cases, all against the binaries. It exists because a doubled registry host, a missing `builder.arch` and a cross-file secret are all valid YAML that parses clean. | kit |
| `tests/onecluster_test.sh` | **The one-cluster claim, asked of `bin/dev`.** Runs a real `bin/dev up` with `KIT_POSTGRES_DATABASES=alpha,beta` and asserts on the world afterwards: **exactly one** postgres container, two databases with a non-superuser owner role each, two non-owner `LOGIN` roles with the membership running one way only, **both services answering a real query as their own role** in their own database, and neither reaching the other's — matched against `permission denied for database`, not against a non-zero exit, because a cluster with no second service also refuses. `isolation_test.sh` brings its stack up itself; this one runs the command a developer runs, which no other tier did. | kit's gate (needs docker) |
| `tests/grant_surface_test.sh` + `tests/grant_surface.sql` + `tests/grant_surface.out` | **The privilege surface, pinned.** Provisions a fresh cluster for the launch's three database-bearing services, dumps every role attribute including `rolbypassrls`, the per-role `statement_timeout`/`idle_in_transaction_session_timeout`, membership direction, each database's CONNECT surface (default ACLs materialized, so a missing `REVOKE` shows `PUBLIC|CONNECT` rather than nothing) and each `public` schema ACL — and fails on any byte difference from the committed golden. This is the class of defect no file review sees: two services' pools logged in as the OWNER role (found by hand, twice), and a table's owner walks past RLS even with FORCE. Two consecutive dumps must be byte-identical, and the test RUNS the two defects it exists to catch — `ALTER ROLE …_app BYPASSRLS` and `GRANT CONNECT ON DATABASE … TO PUBLIC` — requiring the diff to go red naming the row and the revert to restore the bytes. Regenerate deliberately: `bash tests/grant_surface_test.sh --regenerate`. | kit's gate (needs docker) |
| `tests/substrate_copy_check.py` + `tests/substrate_copy_test.sh` | **The copied substrate, compared.** `templates/database/tenancy/substrate.sql` is COPIED into adopters (unlike the fetched compose stack), and one measured copy drifted: identity's `credential_tables()` predated a kit rewrite and returned ZERO ROWS for the role an operator audits credentials as — an empty result indistinguishable from a correct one. The checker compares an adopter's copy — embedded across migrations (goose Up only, last definition wins) or a standalone file byte-compared — against the template, naming missing functions and semantic body changes as failures and comment-only/extra-function differences as reports. kit's gate may not read sibling repositories (MD36), so the fixture test asserts 46 verdicts over shapes built from the real template; the fleet run is deliberate: `python3 tests/substrate_copy_check.py ../identity ../darkroom`. | kit's gate (executed, no docker) |
| `tests/provisioning_complete_test.sh` | **Provisioning is complete, in both halves.** `10-cluster.sh` creates `<svc>` and `<svc>_app` per declared database and it does that **only on a fresh volume** — so a service whose name joins `KIT_POSTGRES_DATABASES` later, or a cluster provisioned before the two-role split, ends up with the owner and no login role, and every other tier is structurally blind to it because `isolation_test.sh` and `grant_surface_test.sh` each provision their own fresh cluster. Measured on the fleet's live cluster: `select rolname from pg_roles where rolname like 'muse%'` returned ONE row — `muse` present, `muse_app` absent — while muse's application pool logged in as the owner. This tier grades every declared database and **fails by name**: the owner role, `<db>_app` present, LOGIN, NOSUPERUSER, NOBYPASSRLS, membership granted app → owner and never the reverse. It then RUNS four versions of the defect — the app role dropped, the membership reversed, `BYPASSRLS`, `NOLOGIN` — each required to go red NAMING the role and the fact, and each restored with the init script's own statements before the check must go green again. `--cluster <container>` grades a cluster that already exists (the case this exists for), reading the declared list from that container's own `KIT_POSTGRES_DATABASES`. | kit's gate (needs docker) |
| `tests/failfast_test.sh` | Executes the **fail-fast** path: a compose file needing a variable with no default is refused in **seconds, by name, with nothing started** — the container list read back by compose project label. The control is the one that carries it: with the variable set the run must reach compose, or the rest is satisfied by a preflight that refuses unconditionally. Set-and-empty counts as unset, which is what `ensure_env` leaves on a fresh clone. | kit's gate (needs docker) |
| `tests/fetch_test.sh` | Executes the fetch against a local bare remote: a pin resolves and the bytes are identical, a branch is refused **before any network call**, and offline mode is real in all four of its states. | kit |
| `tests/stack_live_test.sh` | Brings the **fetched** stack up, sends real OTLP, reads a trace out of Tempo and a **derived metric** off the collector's own exporter, and finds no canary in either. | kit |
| `tests/canary_test.sh` | Plants a canary in ten leak shapes against a real collector and asserts it reaches no exporter. | kit |
| `tests/no_telemetry_in_readiness.sh` | Kills the collector and proves a service still starts, still serves and still reports healthy. | kit |
| `templates/otel/<lang>/` | W3C traceparent: a stdlib codec, an executed conformance suite, an SDK snippet, and a README. For node the suite also asserts the snippet calls **no API the pinned SDK removed** — a check on the snippet's source shape, because kit vendors no OTel tree. | Every service, per language |
| `templates/tier/<lang>/` | The **declared tier**, per language — the tests that need a real dependency, declared in the test source and read by the runner's own collector. Never grepped for a sentinel: a sentinel fails open. | Every service, per language |
| `templates/tier/skip-allowlist` | One file for the fleet. Four hygiene rules — reason, owner, `since`, `until` — and **an entry matching nothing is a failure**. | Every service; the file itself lives here |
| `templates/tier/README.md` | The normalised result format, the allowlist rules, and what a tier gate **cannot** catch. | Every service |
| `templates/mise.toml` | Toolchain pins, one per language, commented. | Every service, as `mise.toml` |
| `templates/AGENTS.md` | Skeleton repo-conventions file. | Every service, as `AGENTS.md` |
| `core/` | The `cafaye/core` fan-out: a `vendir.yml` per consuming repo, the one shared Renovate policy, and what `core` needs to publish semver tags. | Any repo that consumes core's schemas |
| `tests/classify.py` | Classifies a change to a vendored schema set into `FILE`/`PACKAGE`/`WIRE_JSON`/`WIRE`, and **fails closed** on anything `tests/rules.json` does not name. Stdlib only. | Any repo that vendors core |
| `tests/validate.sh` | kit's own suite — the gate. | kit |
| `tests/zizmor_gate.sh` | The one zizmor split: `unpinned-uses` recorded, every other audit fatal. | Every service, copied verbatim |
| `launch/bin/launch` | **The developer-only launch harness.** Brings up identity + gateway + courier + parlor from source checkouts on kit's stack, with mailpit as the SMTP sink: prerequisite checks, stable generated secrets in `launch/.env`, the courier key minted from identity's API after identity is ready, bounded readiness waits, two-phase bring-up, `status`/`down` (volumes deleted, `.env` survives). Sibling checkouts by explicit `LAUNCH_*_DIR` path — Website and Site are never required — and the stack defaults to this checkout itself (`KIT_STACK_DIR`/`LAUNCH_KIT_REF` override, resolved by kit's own `dev.sh live`). **Not the customer installer** (`templates/substrate/install.sh`) and proves nothing about k3s/Argo/ACME/GHCR/Cloudflare. | A developer, on this checkout |
| `launch/docker-compose.launch.yml` | The launch overlay: the four services' images/ports/environment, the `identity,courier` database list, and mailpit — an **override** on kit's stack, redeclaring nothing kit ships. Every published port a variable in kit's `15000-15999` block, every build context a `LAUNCH_*_DIR` variable, the seam secrets failing closed on `:?`. Project name `kit-launch`. | Composed by `launch/bin/launch` |
| `tests/launch_test.sh` | The shape proof: layout validation, pin behavior, command construction, teardown safety, and the compose/schema invariants — each with a control that must go red — plus the installer split, all with stubbed tools and no daemon. The one real-docker contact is `compose config` (client-side rendering, starts nothing). The teardown claims whose subject is `launch/.env` run against a shadow copy of `launch/` that the suite builds, because the real one is git-ignored and belongs to a stack that may be running. | kit's gate (static phase) |
| `VERSION` | **The version, and the only place it is written.** One line. Three tiers are derived from it by `stability_tier` — MAJOR is `breaking`, MINOR `additive`, PATCH `invisible` — and `stability_gate_check` gates the release on what the tier owes: a MAJOR needs a `MIGRATIONS.md` section, a `### Breaking` heading is legal only under a version whose MAJOR actually moved, and a version string the derivation cannot place is a red build rather than a guess. | Anyone deciding whether to take a version |
| `RESERVED` | **Tombstones: a retired name stays dead.** In the `skip-allowlist` dialect, and the fourth hygiene rule is **inverted** — a reserved path that exists in the tree is the failure. buf's `reserved` and k8s's `+k8s:deprecated` are *not* the same mechanism (a wire tombstone vs a lifecycle marker on a still-present field); kit has no encoding, so only the shared weaker half transfers. See `DECISIONS.md` (MD27). | kit's gate; read before reintroducing any path |
| `LICENSE` | **kit's own grant: MIT, and byte-identical to `cafaye/core/LICENSE`.** The whole grant — the manifest below carries no licence field, so no metadata field can disagree with the file. A gate check reads it *and* every root manifest that can carry a licence field, because a licence is only unambiguous when exactly one place can declare one. | Anyone reading or vendoring kit |
| `cafaye.yml` | **The manifest.** Added when the grant moved to MIT, because OPS-D2 says no grant means "all rights reserved" and `kit` had no manifest — so a repo can be both unlicensed and undescribed. Same keys as `core`/`pantry`/`cafe`, `language: spec` (the enum has no config member), `dependencies: []` (kit is a dependency *of* the fleet), and `name: kit` — which is on the reserved-name list, the same exception core makes for itself. Validated against `core/schemas/cafaye.manifest.schema.json`. | `cafe contract lint`; anyone resolving what kit is |
| `docs/customer-upstream.md` | **The customer path.** How an external app adopts public Kit (one pinned SHA across `uses:`, `kit-lint-ref` and `kit.ref` — branch comments on the YAML lines, bare SHA in `kit.ref` — moved by Renovate PRs via the `github-digest` datasource, no tags needed), merges template updates without losing local work, sends general app fixes upstream to the canonical app as fork + PR (branding stays downstream), and sends Kit improvements back as fork + PR with narrow local verification (CI owns the full gate) — the two upstream directions kept apart. Checked by `tests/customer_upstream_check.sh`. | Anyone building on Kit outside cafaye |

## Secrets — what kit checks, and what it does not

**`zizmor` (opt-in).** The GitHub Actions security audit, on your own workflows.
It answers *what is the shape of your CI*. Off by default because it reads
workflows kit did not write, and a red build for someone else's finding is not a
fair day one.

**Was a credential committed?** kit used to answer this with a full-history scan
of the adopting repository, as a job no service could opt out of. It does not any
more, and `DECISIONS.md` MD34 says why: a control whose subject is somebody
else's repository is not one kit owns, and the finding lands on whoever pushed kit
rather than on the person who can fix it. Your host's push protection catches it at
the push that introduces it, which is the moment it is cheapest to fix.

**`templates/secrets/`** answers the question zizmor does not: *does a
credential leave the process while the tests run?* It plants a fake credential
— `cafaye_canary_` plus 32 bytes, assembled at run time so it is safe to commit
— and sweeps five vectors: log/stdout/stderr, unknown serialisation fields, the
whole error chain, keys that are present-but-empty, and Go type coverage. The
contract is in [`templates/secrets/README.md`](templates/secrets/README.md); the
Go adapter is in `templates/secrets/go/`, and only Go has one so far.

## The core fan-out — `core/`

Six repositories copy bytes out of `cafaye/core` and nothing in the fleet makes
that copy reach them. `core/` is the standard that does, and — as much as
anything else — the record of what is still unproven about it.

**Start at [`core/README.md`](core/README.md).** It opens with what was
*measured* rather than what was assumed, and the measurement is not what the
design was briefed on: one repository declares a core pin at all, two hold
vendored bytes with no recorded origin, and two fetch core at test time on
purpose.

| file | what it is |
| --- | --- |
| [`core/vendir/vendir.yml.{muse,pantry,caf}`](core/vendir/) | The three real consumers, in three languages. `muse` and `pantry` are proven byte-identical (sha256) to what those repos have committed today; `caf` cannot migrate without a rename and its banner says so. |
| [`core/vendir/vendir.yml.template`](core/vendir/) | What a fourth repository copies. Four things to change, each marked. |
| [`core/renovate/renovate.json5`](core/renovate/) | The single `inheritConfig` policy for the whole fleet. |
| [`core/renovate/SETUP.md`](core/renovate/) | The ordered steps to stand the policy repo up, **and what to verify before onboarding a second repository**. |
| [`core/release/release.yml`](core/release/) | The workflow `core` needs before any of it can move. Ships here; belongs in `core/.github/workflows/`. |

## The templates half — `templates/`

Everything in `templates/`, `lint/` and `docker/` is adopted **by copy**, which
means a fix in kit reaches a service only when somebody copies the file again.
Nothing in the fleet made that happen.

**kit used to measure it and no longer does.** `tests/staleness.py` reported each
service's copy of a template as `current`, `diverged`, `absent`, `unknown` or
`n/a`, and `templates/parity-allowlist` recorded eighty reasons why a given copy
was not kit's bytes. Both read repositories beside this one, so both went with the
rest of the cross-repo surface (MD36). The rule that survives is the one worth
having, because it is a rule about how to reason rather than about what to read:

**a copy is never inferred from content.** There is no similarity threshold, no
percentage, no "closest match", and no search for a file that hashes to kit's. A
copy is `current` when the bytes at the declared path are equal and the path is a
real file in the service's own tree, and at no other time — one appended byte
makes it `diverged`, and a symlink to an identical file is `unknown` rather than
`current`, because the bytes are right today and the arrangement is a bet that the
target never moves.

The tempting relaxation was a `quick_ratio() > 0.99` score, because that is the
shape a helpful contributor reaches for, and the reason it is wrong is that it is
unfalsifiable by the thing it is measuring: a ratio that says "close" cannot be
argued with about what close means. If a check like that is ever written again, in
kit or in a service, that is the paragraph to read first.

What is lost is real and worth naming: kit no longer knows which services are
behind, so a template fixed here can sit un-copied indefinitely. That is a cost
this repository accepted deliberately, and MD36 records why. Consent to be checked
does not make it this repository's job — a red there lands on whoever maintains
the service that drifted, which is the wrong owner for a check written down here.

Two things worth knowing before you read any of it, because both were found by
running the tools rather than by reading about them:

- **`includePaths` nested under `git:` is silently ignored.** vendir drops keys
  its schema does not declare, the filter ends up empty, and `vendir sync`
  vendors the *entire* upstream repository while exiting **0**. It reads
  correctly. `tests/core_fanout_check.py` asserted this shape and eight others
  against `core/vendir/` and `core/renovate/`; it had no caller and claimed one
  in its own docstring, so it is gone. **Nothing checks these files now** —
  `core/vendir/README.md` is the only place the rule is written, and a reader
  editing a `vendir.yml` is the only thing standing between them and the whole
  upstream tree.
- **`renovate.json5` uses `constraints.vendir`, not `installTools`.** The first is
  what the vendir manager actually reads; the second is scoped to
  `postUpgradeTasks` and is *also* wrong in shape — it is an object keyed by tool
  name, not an array. Both checked in Renovate's source; see the comments in the
  file.

The change classifier is the one thing here that is a program rather than
configuration, and it is the reason the standard is enforceable. It is
standard-library only and it is not imported by anything. Its conventions are in
[`AGENTS.md`](AGENTS.md#the-classifier-fails-closed-and-that-is-a-rule-about-code).

## The gate declaration, and the two workarounds that are now illegal

`core` publishes a gate declaration format (`gate.yml` against
`schemas/gate.schema.json`) and a checker for it. Nine repositories adopt it.
The checker had two defects that pushed adopters into local workarounds, and
**both are fixed**:

| defect | what it was | fixed in |
| --- | --- | --- |
| **D12** | `RUN_KEY` only matched a `run: \|` block, so `run: ./bin/prime` on one line was invisible to `gate.ci-disagrees`. The step that runs the gate stopped counting as one. | core `63fd319` |
| **D13** | A proof was matched against raw bytes, which carry whatever ANSI colour the gate's own tools emit, so a pattern written by reading a terminal failed on a machine whose tools colourise. | core `c63af27` — core now strips ANSI in exactly one place, before matching |

**A workaround for a fixed defect is not neutral.** It is a second, local,
unpolicied copy of a decision that now lives in `core`, and it is the kind that
rots: a `gate.yml` carrying a hand-rolled escape-tolerant regex is *weaker* than
one without it, because the escape runs absorb characters a stricter pattern
would have rejected.

There was a check here that read the adopting repositories and refused those
three shapes. It is gone, and `core` owns both defects and both fixes now, so
nothing in kit grades a repository it does not own. The lesson it earned is
kept because it generalises: **a check that fires on correct work teaches the
reader to ignore it.** That check's first version reported 4 repositories and 24
findings against the real fleet, nearly all false, including `core/gate.yml` for
the sentence "That is MD12's collect-then-run machinery", because `D12` is a
substring of `MD12`.

## The local stack — `templates/compose/`

Postgres, NATS with JetStream, Redis, the OpenTelemetry collector, and the three
services that make a developer's traces, logs and errors visible: **Grafana,
Loki and Tempo**. One stack, one set of credentials, one command, for
every service.

**`bin/dev up` starts the cheap half.** Postgres, NATS, Redis and the collector,
and nothing else. The three stores are one deliberate variable:

```sh
bin/dev up                                        # postgres, nats, redis, collector
KIT_DEV_PROFILES=observability bin/dev up        # ...and tempo, loki, grafana
```

The reasons are measured rather than asserted — 65s of Tempo's readiness budget,
16s of Loki's, and up to 180s of Grafana's on a cold volume, against a 180s
deadline for the whole stack — and they are in **The reversal** below. Telemetry
itself does not change: the collector is not behind the profile, so a service
with nothing configured still exports into it on the cheap path, and the
redaction allowlist still runs before anything would be stored.

**You do not copy any of it.** There is no `docker-compose.yml` of kit's in your
repository, no `otel-collector.yml`, no `tempo/`, no `loki/`, no
`grafana/`, and no `.env.example`. `bin/dev` fetches all of it from a **pinned**
ref and runs it beside the one compose file you do have:

```sh
cp <kit>/templates/bin/dev.sh ./bin/dev && chmod +x bin/dev
git -C <kit> rev-parse HEAD > kit.ref      # the pin — see below

bin/dev            # fetch kit, compose up --wait, migrate, seed, print URLs
bin/dev stack      # resolve the pin and show what the two files merged into
                   #   (read-only; creates nothing)
bin/dev live       # resolve the pin, sync the service-owned snapshot into
                   #   .kit/live/<ref>, print `resolved: .kit/live/<ref>` —
                   #   the staged-launcher entrypoint: compose from that
                   #   directory, never from the cache
bin/dev pin v0.4.0 # move the pin DELIBERATELY; prints the stack diff first
bin/dev status     # what is running
bin/dev logs tempo # tail one service
bin/dev down       # stop, keep the data
bin/dev nuke       # stop and DELETE the data
```

Everything the stack needs comes from the fetch: `templates/compose/otel-collector.yml`,
and the vendor **configuration** for the two stores — `templates/compose/tempo`,
`templates/compose/loki` — plus
`templates/compose/grafana/provisioning`, which is where the datasources, the
fleet error dashboard and the alert rules live as files. None of it is copied, so
none of it can be a stale copy.

The command that actually runs is:

```sh
docker compose --project-directory . \
  -f <fetched>/templates/compose/docker-compose.yml \
  -f ./docker-compose.yml up -d --wait
```

A compose file cannot be `uses:`-ed — GitHub resolves reusable *workflows* and
nothing else — so `bin/dev` is the callable path, and the pin is what makes it
one. See [`kit.ref`, the pin](#kitref-the-pin).

### `kit.ref`, the pin

One committed line at your repository root, holding the ref of kit you run: a
**40-character commit sha**, or a **`v<MAJOR>.<MINOR>.<PATCH>` tag**. `bin/dev`
refuses a branch — loudly, before any network call.

```sh
$ cat kit.ref
# the stack this service runs; see bin/dev pin
b25bdff23cec89697854b95ac03550baa81de9cc
```

**Why a pin, and why not `master`.** The ref decides which redaction allowlist,
which port block and which Grafana dashboards your dev loop runs. On a branch
those change between two runs of the same command, and a stack that changes under
you between Monday and Tuesday is not a stack you reviewed.

**Why a committed file and not a line in `.env`.** `.env` is git-ignored. A pin
there exists on exactly one machine — the laptop of whoever ran `bin/dev pin`
last — and on no CI runner and no teammate's checkout. `kit.ref` is in the diff,
so the bump is reviewed like any other change to the dev loop, and
and a reviewer sees the bump rather than trusting one laptop's `.env`.

`KIT_STACK_REF` still works, **from the environment only**, as a one-run override
for someone working on kit itself:

```sh
KIT_STACK_REF=$(git -C ../kit rev-parse HEAD) bin/dev up
```

### Offline

`KIT_STACK_OFFLINE=1` uses only what is on the machine — `KIT_STACK_DIR`, the
cache, or a copy you vendored at `.kit/stack` — and **fails loudly**, naming each,
when none of them holds the pinned ref. It never falls back to an unversioned
directory.

### Replacing the cache never breaks a running stack

The cache directory is **bind-mounted into your containers**, so it is not a
directory `bin/dev` may delete out from under them. A fetch that finds a populated
cache **retires** it — `mv` to `<cache home>/.retired/<ref>.<serial>` — and then
`mv`s the new tree into place. Both are renames within one filesystem, so a second
`bin/dev` in another terminal still never sees a half-populated directory.

This is measured rather than asserted. On macOS a bind mount resolves its source
when the container is **created**, so the running process keeps serving off
descriptors it already holds while every **new** open through the mount path fails
`no such file or directory`. Against a real container re-reading its mount once a
second: rename the tree aside → still reading fine; delete the renamed copy →
`no such file or directory` on the very next probe. **So the old tree is kept, not
just moved** — deleting it later would break the mount exactly as deleting it now
did, because it is the same inode.

Space is reclaimed oldest-first, past `KIT_STACK_KEEP_GENERATIONS` (default 3), and
**only for a generation nothing is mounted from** — `bin/dev` asks the daemon.
It retains on every answer it cannot get: no `docker` on `PATH`, no daemon,
`docker info` failing. A machine that cannot answer also has no containers mounted
from those paths, so nothing is lost by keeping them. Each generation is a few
hundred KB (a `--depth 1` checkout of a repository that is almost entirely YAML),
and a fresh cache starts no `docker` process at all, because there is nothing to
prune.

A vendored copy must **say what it is**, and this is the part that is not
optional:

```sh
git clone --depth 1 https://github.com/cafaye/kit.git .kit/stack
git -C .kit/stack checkout "$(cat kit.ref)"
git -C .kit/stack rev-parse HEAD > .kit/stack/.kit-stack-ref
```

A directory that merely *contains* `templates/compose/` is not a kit checkout at a
known version. A mismatched record is refused, a missing one is refused, and only
a matching one is used — because an offline loop that silently runs some other
version is worse than one that refuses to start.

## What stays in your service

Your `docker-compose.yml` is the **second** `-f`, which makes it an **override**:
what is in it wins, and everything you did not mention still comes from kit.

**You may:** set `image:`; add keys to your own service's `environment:`; add a
`depends_on`; declare your own services; change a published port **by changing
the variable in `.env`**.

**You may not:** touch `otel-collector` — not its `image:`, not its `command:`,
and above all not the `volumes:` entry that mounts `otel-collector.yml`. That file
carries the redaction allowlist, **derived from core's schemas**; a service that
overrides the mount is shipping a telemetry boundary nobody derived, and prompt
content leaves the process inside it. Nor may you override the four AGPL backends,
or set `allow_all_keys`, or add an exporter, by any route — nor set
`POSTGRES_USER`, `POSTGRES_DB` or `POSTGRES_PASSWORD` on kit's `postgres`
service, which is explained below and is the reason this list has a second
boundary in it.

**The trap: `ports:` APPENDS, it does not replace.** A second file's `ports:`
list is concatenated with the first's, so this:

```yaml
services:
  postgres:
    ports: ["15433:5432"]     # WRONG
```

publishes postgres on **15500 _and_ 15433**. Move the port in `.env`
(`KIT_POSTGRES_PORT=15433`) and say nothing in the compose file. Measured, not
assumed; the rule is in `templates/compose/docker-compose.yml`'s own header and
the gate fails on a `ports:` entry in a service file.

**Pointing at your own database** is one line in `.env`, and it is not an
override at all:

```sh
# .env
KIT_POSTGRES_DATABASES=courier,billing,yoursvc
```

The init script gives each name in that list its own `NOSUPERUSER` role and a
database that role owns, and then applies the `REVOKE CONNECT ... FROM PUBLIC`
that keeps the other services' databases closed to you. **Measured on `muse`,
the largest adopter: 52 non-comment lines became 22, and the 538-line stack it
used to half-copy is now fetched.**

**Do not override `POSTGRES_USER`, `POSTGRES_DB` or `POSTGRES_PASSWORD` on
kit's `postgres` service.** This section used to tell you to do exactly that.
It is the reason `identity` carries an override that makes the fleet's auth
service a cluster superuser, and it was found by a worker doing an unrelated
migration. Measured on a cluster built from kit's own `initdb/10-cluster.sh`:

- `POSTGRES_USER` is the role the official image creates, and it creates it as a
  **superuser** — measured, `rolsuper = t` where every role the init script made
  holds `f`. Override it and your service can read every other service's
  database — measured, `select count(*) from invoices` against `courier`
  returns `2`, where a properly-provisioned role is refused at the door with
  `FATAL: permission denied for database "identity"`. That refusal is the whole
  isolation contract; see `templates/database/README.md`.
- `POSTGRES_DB` is created by the image too, before any init script runs. Either
  override then makes `CREATE ROLE` / `CREATE DATABASE` in the init script fail,
  and because that failure happens **during initdb**, the whole cluster refuses
  to start — measured, exit status 3 and
  `ERROR:  role "identity" already exists`.
- `POSTGRES_PASSWORD` is the honest exception: it breaks neither the cluster nor
  the boundary. It is the credential *every* role on the cluster is given, so
  overriding it makes your file decide the password all the others authenticate
  with. It is refused for that reason and not for one of the two above.

If it is the cluster's own identity you are changing, the variables are
`KIT_POSTGRES_USER`, `KIT_POSTGRES_DB` and `KIT_POSTGRES_PASSWORD`, and they
are already declared in the compose file. Setting any of the three in your own
file takes the choice away from the services sharing the cluster.

One thing about the `.env` line: `docker-entrypoint-initdb.d` runs **once per
volume**, so after adding your name you need `bin/dev down -v && bin/dev up`.
An existing volume keeps the list it was provisioned with.

**One cluster for every service, and the list is the whole declaration.** That
line above is not a per-service setting — it is the fleet's data topology in one
place. A single `postgres` container serves every service that names itself in
it; each name gets its own database and its own role pair, and the database is
the boundary between them. Nothing else is needed: no container, no port, no
volume per service. **Proven by running it**, not by reading the template:
`tests/onecluster_test.sh` brings up `alpha,beta` through `bin/dev` and asserts
**one** postgres container, two databases, two owner roles and two non-owner
login roles, both services answering a real query as their own role in their own
database, and neither reaching the other's.

And if you forget the line, `bin/dev` says so **before it starts anything**:

```
$ bin/dev up
bin/dev: 1 required by the compose file is not set:
  KIT_POSTGRES_DATABASES

Set it in .env, which is the only file a developer edits:

  KIT_POSTGRES_DATABASES=<value>
```

Docker Compose does not do this itself: it substitutes an **empty string** for a
bare `${VAR}` rather than refusing it, so the postgres container used to come up,
the init script refuse at its guard, the container exit — and the only report
arrive when `up --wait` had already run out its 180-second budget. The check is
**derived from the compose files**, so a service that introduces a required
variable in its own `docker-compose.yml` gets the same refusal by name.

### Working across two services on one laptop

Two checkouts, one cluster — which is the case the topology is for. Declare both
services in **each** service's `.env` (the cluster is declared by whichever
stack brings it up, and both stacks share the machine's ports):

```sh
# .env, in both checkouts
KIT_POSTGRES_DATABASES=alpha,beta
```

**Move the ports, and move all five.** The port block is collision-free across
*databases* but not across *checkouts*: `bin/dev up` publishes five ports
(postgres, nats client, nats monitor, redis, grafana) and each has a fixed default
inside kit's 15000-15999 range. A second checkout beside a running one collides
on the first it reaches — measured, with only postgres moved, on redis:
`Bind for 0.0.0.0:15800 failed: port is already allocated`. Give each checkout
its own block, in `.env`, for all five:

```sh
KIT_POSTGRES_PORT=15500      KIT_NATS_CLIENT_PORT=15600
KIT_NATS_MONITOR_PORT=15700  KIT_REDIS_PORT=15800      KIT_GRAFANA_PORT=15000
```

…offset by a hundred per checkout. Never in a compose override — a `ports:` entry
in a second file **appends** rather than replacing, which is the trap above.

It is a **stack, fetched from a pinned ref**, not a template you copy. Every
published port is `${KIT_*:default}` inside kit's claimed block, every image is
pinned to an exact tag, and every service has a healthcheck so `up --wait` can
mean something. A service joins by writing an **override** file — its own image,
its own port, its own service entry — which `bin/dev` merges with the fetched
stack.

### Telemetry is on by default; the stores to read it back from are not

You did not have to install anything, and you still do not have to. `bin/dev up`
brings up the collector, and a service with nothing configured exports into it,
because `<SERVICE>_OTEL_ENDPOINT` **defaults to the collector that ships with this
stack**. What it does *not* bring up by default is the stores behind it:

```sh
bin/dev up                              # postgres, nats, redis, collector — fast
KIT_DEV_PROFILES=observability bin/dev up   # …and tempo, loki, grafana
```

That is a reversal, and it is worth being explicit about why, because the old
default was a measured decision that turned out to be the wrong one. As a
default, the observability profile cost every developer's cold start: Grafana
downloading a plugin zip on first boot (20s once, over 180s another time), 65s
of Tempo's, 16s of Loki's — against a 180s
deadline for the whole stack and a 76s typical cold start. A fourth service, the
metrics store, cost 130s of readiness budget per cold start on top of those and
was removed outright rather than left half-wired. A default that taxes
everyone's startup to serve a view they did not open is a default that gets
switched off fleet-wide, and the telemetry goes with it. **The escape hatch was
the documented good path the whole time; it is now the default.**

**Nothing about the telemetry boundary changed.** The collector is not behind
the profile, so spans, logs and metrics still arrive and still pass through the
redaction allowlist — which drops high-cardinality dimensions at *ingest*, before
anything would be stored. On the cheap path the data is then dropped because
there is no store to hand it to, which is strictly better than paying 130 seconds
to keep it. If you want to read traces back, ask for them:

| You want | You do | What happens |
|---|---|---|
| **Traces, logs and metrics to read back** | `KIT_DEV_PROFILES=observability bin/dev up` | tempo, loki and grafana come up too; open <http://localhost:15000> and the fleet error dashboard is already there |
| **Your own backend** | set `MUSE_OTEL_ENDPOINT` (or `CAF_OTEL_ENDPOINT`, `BILLING_OTEL_ENDPOINT`, … — `<SERVICE>_OTEL_ENDPOINT`, the name derived from the service) to your Datadog / Honeycomb / Grafana Cloud OTLP endpoint | this service exports there and the shipped stack goes quiet for it. **Bring your own backend is a supported deployment, not a degraded mode** |
| **No telemetry at all** | unset the variable | a genuine no-op: no queue, no retry loop, no warning per request, no dial at boot |
| **Still on, quieter** | `KIT_OTEL_DEBUG_VERBOSITY=basic` | the `debug` exporter stops printing every span to the terminal |

`<SERVICE>_OTEL_ENDPOINT` is the ONLY contract. The shipped collector is just
that variable's default value, which is what makes on-by-default possible without
making it obligatory. All six language templates implement it — see
[`templates/otel/README.md`](templates/otel/README.md).

### The port block: 15000-15999

kit claims this range for the whole stack, one hundred per service, and the gate
asserts every published port is inside it and that no two services reuse one.

| Port | Service | | Port | Service |
|---|---|---|---|---|
| 15000 | Grafana | | 15700 | NATS (monitoring) |
| 15500 | Postgres | | 15800 | Redis |
| 15600 | NATS (client) | | 15900 | Tempo (traces) |
| | | | 15901 | Loki (logs + crash layer) |

Not 5432, 4222 or 6379, and that is the point: those are the two or three most
likely things already listening on a developer's machine. `bin/dev` is the first
command a new person runs on a repo they just cloned, which is the worst possible
moment to find out somebody else owns 5432.

The four backends sit in a compose profile named `observability` so a constrained
machine can opt out; `bin/dev up` includes the profile, so the **default** path
still gets the whole stack. The collector is deliberately NOT in that profile: it
is the default value of the endpoint variable, and a service with nothing
switched on needs somewhere to send.

**Cold `bin/dev up` on a laptop: ~50 seconds**, eight containers, volumes
deleted. Measured, not estimated, and `bin/dev` prints the wall-clock itself so
"the dev loop is slow" is a number in the output rather than a feeling.

**If a port in that block is already taken — by another repo's scratch
container, say — move it in `.env`, not in the template.** That is what `.env` is
for, `bin/dev` prints the URLs it read from `.env` rather than hardcoded ones,
and this is the documented escape hatch rather than a workaround:

```sh
sed -i '' 's/^KIT_POSTGRES_PORT=15500/KIT_POSTGRES_PORT=15501/' .env
bin/dev up
```

Note the block is claimed *fleet-wide*, and nothing coordinates it across repos.
Six services each running their own stack need six of these blocks. See the DECISION
NEEDED in kit-03's report before a second repo adopts it.

### The licence, stated plainly

**Grafana, Loki and Tempo are AGPL-3.0, and kit ships them UNMODIFIED.**
Stock `grafana/*` images, pinned, with read-only *configuration* mounted over
them. Nothing is forked, patched or rebranded — that is the condition the licence
cares about, and the gate fails on a `build:` stanza on any of the three.

AGPL attaches to the Grafana **server**, not to the applications it observes, so
this is compatible with cafaye being MIT/Apache. The obligation runs one way: we
may use these; a self-hoster using our code is not thereby offered a modified
Grafana. If you believe a change to one of these is necessary, that is a
`DECISION NEEDED`, not something to do quietly.

Every image is pinned to an exact tag. `latest` for a log store means a
self-hoster's upgrade path is whatever happened to be cached when their disk
filled.

### kit's own licence

**kit is MIT.** See [LICENSE](LICENSE), which is the whole grant and is
byte-identical to `cafaye/core/LICENSE` — the text seven cafaye repositories
already carry (billing, caf, cafaye-py, cafaye-ts, core, darkroom, docs), all at
1063 bytes and the same md5, so a reader diffing two framework repos sees no
grant and only the repository differing. OPS-D2 puts the framework open under
MIT: their job is adoption.

That is a different question from the AGPL paragraph above, and keeping them
apart is the point. The four backing services are third-party software we
*consume*, unmodified, under their own terms. kit is cafaye's own work and is
granted under MIT. A service adopting kit adopts the conventions under those
terms and pulls the four backends under AGPL-3.0, and neither obligation runs
toward the other — MIT is one-way permissive, so it can never acquire AGPL's
terms and AGPL can never reach kit's.

The grant is not a change to the library question: kit holds no package manifest
in any ecosystem and nothing depends on it (AGENTS.md), so a consumer takes the
conventions by copy or by fetch and the file governs. What changed is what a
reader is allowed to do with it, not how it is delivered.

### Telemetry is never in a readiness path

A service that hangs on startup because telemetry is down is worse than no
telemetry at all. So:

- nothing in the compose file `depends_on` the collector or a store, and no
  healthcheck probes an OTLP port — the gate fails on both;
- `bin/dev` does not wait on the collector before migrating;
- the collector's `health_check` reports healthy with all three backends absent,
  because a collector that has lost spans is not an unhealthy collector;
- every exporter sets `sending_queue` and `retry_on_failure` to **false**, so a
  dead Tempo costs you spans rather than a background thread and a queue.

`tests/no_telemetry_in_readiness.sh` proves it against a real collector: it
starts the collector with Tempo and Loki both refusing connections and
checks it is still healthy, has not restarted, and has not entered a retry loop;
then it stands up a service whose `/readyz` **really** checks a dependency, stops
that dependency, confirms `/readyz` has gone 503 — so the probe is known to be
capable of failing — and only then checks the service is still serving, with a
dead dependency and an OTLP endpoint that does not exist. A readiness test
whose `/readyz` cannot fail is not a readiness test.

### If you edit a provisioned dashboard

The shipped dashboards were correct on arrival and were not correct on the first
attempt, in three ways that are all invisible until you look at the backend. The
gate now holds all of them, but the rules are worth stating because the next
person to add a panel will hit them:

- **Name the datasource on every panel.** A panel with `"datasource": null` goes
  to Grafana's *default* datasource, which is **Tempo** — traces. That is how a
  LogQL panel
  ends up asking the traces API for `{service_name=~"..."} |= "error"` and
  getting `parse error: unexpected character: '|'`. The panel renders red, not
  empty, and every datasource still shows green. (It used to be the metrics
  store, which is the same bug with a different victim; the store went, the flag
  moved to Tempo so that Explore still opens on something, and the rule did not
  change.)
- **Label names lose their dots.** OTLP ingestion mangles `.` in a label name to
  `_`, so the collector's `otel.status_code` reaches Prometheus as
  `otel_status_code`. A matcher on the dotted spelling is a *parse error*, and an
  alert rule that cannot be parsed never fires and never says so.
- **The counter carries `_total` because the collector adds it.**
  `transform/cafaye_metrics_labels` renames a metric whose name ends in `calls`
  to `calls_total`, which is what Prometheus reserves for counters and what stops
  a `rate()` warning banner on every panel. Query `cafaye_calls_total`, not
  `cafaye.calls` and not `cafaye_calls`.

**Where `tenant_id` is visible.** It is a *resource* attribute, so it arrives on
`target_info` and on the resource of every span and log record — and never as a
label on a measurement, which is what keeps core's 2000-combination cap
meaningful. Per-tenant metric totals are a `group by (tenant_id)` **joined
against `target_info`**, not a label on the series. See the DECISION NEEDED in
kit-03's report.

### The redaction boundary, derived from core and proved by canary

The collector applies the allowlist **once, before anything leaves the process**,
and the allowlist is not written here — it is **derived from core's schemas**, and
`tests/validate.sh` reads `core/schemas/telemetry/*.json` off disk and compares
**both** ways:

- every attribute core allows on a signal must be in that signal's
  `allowed_keys` (a missing one is a span that arrives uselessly and nobody
  notices);
- nothing may be in it that core does not allow (an extra one is a leak with a
  check attached);
- no allowed name may contain a word core's redaction schema forbids;
- no resource attribute may appear as a measurement attribute.

The check prints the core commit it compared against, because "it passed" against
a spec from six weeks ago is a different statement from "it passed".

`tests/canary_test.sh` then proves it **behaves**, not that it is configured. A
canary string is planted in ten shapes a leak could take — a banned key, an
SDK-default key, the deprecated `exception` span event, a near-miss key, an
*allowlisted* key's value, a resource attribute, a bearer token, a metric data
point, a log attribute, a log body — and the test asserts the canary reaches no
exporter **and that the allowed data survived**. The second half is the half
that is easy to fake: a collector that drops everything passes a "no canary" test
and is useless.

Two things that test found, both of which are in the config because of it:

- **span events are not attributes**, and the redaction processor does not visit
  them, so `exception.message` on a span event bypassed the allowlist entirely;
- **`ignored_keys` is one flat list** applied to resource and measurement
  attributes alike, so exempting `tenant_id` on the resource would also exempt it
  on every data point — the exact cardinality bomb core's metrics schema exists
  to prevent. The config therefore stashes and restores the two identity
  attributes around the redaction processor, and the gate asserts the ordering.

**The log body is the one place free text is expected, and it is NOT scrubbed.**
core requires a body and bounds it at 2048 characters; the redaction processor is
specified over attributes. The canary test reports this rather than quietly
passing, because a reader who assumes the body is scrubbed is exactly the reader
who puts a prompt in one.

## Trace propagation — `templates/otel/`

Every service speaks the same trace context, so a request crossing four cafaye
services reads as one trace.

Each language ships four files:

| File | Use it when |
|------|-------------|
| `traceparent.*` | You need the header handling on its own: a queue consumer, a webhook signer, a background task, a test that asserts propagation without an SDK. Stdlib only. |
| `test_traceparent.*` | Always. It is the contract. |
| `*.snippet` | You serve HTTP. The upstream OTel SDK already does this and also gives you spans and metrics. Versions in [`templates/otel/pins.md`](templates/otel/pins.md); kit vendors nothing. |
| `README.md` | When you are deciding. |

The contract, identical in all six languages:

- a valid inbound `traceparent` is **continued** — same trace-id, sampled flag
  preserved, parent-id replaced with this hop's span id (§3.4);
- a missing or malformed `traceparent` starts a **new** trace and never throws,
  never 4xxs, never panics — a request is not an error because its trace header
  was garbage (§3.2.2.3, §4.2);
- `tracestate` travels with the trace, capped at 512 characters, truncated on
  whole-entry boundaries only (§3.3.1.5);
- a `traceparent` that fails to parse is **not** rescued by a `tracestate`
  alongside it (§3.3).

Reference: [W3C Trace Context, W3C Recommendation 23 November 2021](https://www.w3.org/TR/trace-context/).
Start at [`templates/otel/README.md`](templates/otel/README.md) for the six-way
comparison and the reason there are six implementations of one algorithm.

### Worked example — `courier` adopting propagation

A service that fans a delivery out to `parlor` and publishes to NATS. Three
steps, in this order.

**1. Copy the codec and its suite.** Keep both. The suite is what makes
propagation a build failure instead of a claim in a README.

```sh
cp -R <kit>/templates/otel/elixir/. lib/courier/telemetry/
cp <kit>/templates/otel/elixir/test_traceparent.exs test/
```

**2. Read the trace at the edge.** In a plug, before the controller:

```elixir
def read_trace(conn, _opts) do
  hop = KitOtel.Traceparent.server_hop(conn.req_headers, KitOtel.Traceparent.new_span_id())
  conn
  |> assign(:trace_id, hop.trace_id)
  |> assign(:outbound_trace, hop.outbound_headers())
end
```

`server_hop/2` cannot fail. That is the design, not an omission — see
[`templates/otel/elixir/README.md`](templates/otel/elixir/README.md).

**3. Put it on the wire outbound.** On the `Req` call to `parlor`:

```elixir
Req.post!("#{parlor_url}/deliveries", json: payload, headers: outbound_trace)
```

`outbound_trace` is `{"traceparent" => "00-<trace-id>-<this hop's span id>-01"}`.
The trace-id is the same one that came in, the parent-id is this hop's span, and
`parlor` continues it. That is §3.4, and it is the whole mechanism.

**4. Turn the suite into a build failure:**

```yaml
    with:
      language: elixir
      telemetry: 'true'
```

`bin/dev` then shows the trace locally, because the collector prints spans to
stdout and the service points at it:

```sh
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318 bin/dev
```

## Platform boundary: what lives here, what lives in services

kit is a platform repository. Substrate/install/bootstrap,
platform-level state, the central Argo desired state, and the proofs of
those platform guarantees live here. Services own their runtime code,
behavior/unit tests, service charts, and chart publication. The selected
deployment design is k3s + Argo CD + CNPG/Redis/OCI as recorded in
`DEPLOYMENT.md`; kit preserves it and does not re-decide it.

Kit's reusable CI/workflow conventions (`ci.reusable.yml`,
`image.reusable.yml`, `chart.reusable.yml`, `publish.reusable.yml`) are
optional and versioned — pin them by ref or SHA in the `uses:` line.
Consuming them is not a condition for a service repo to build: service
workflows are independent, and nothing in kit's gate reads service
repositories.

## CI routing and release policy

kit's own CI routes each pull request by its changed paths
(`tests/route.sh`: pure bash, no venv, proved by `tests/route_test.sh`
without ever launching the gate). Exactly one proving job runs per run,
and `gate` — the stable required check (`ci / gate`) — passes iff that
job passed:

| route | change | what runs |
| --- | --- | --- |
| `docs` | prose only (`*.md`, `*.txt`, `LICENSE*`, …) | `git diff --check` and nothing else |
| `tier` | `templates/tier/**` only | `tests/focused_tier.sh`: family syntax, same tools as the gate |
| `publish` | `templates/publish/**` only | `tests/focused_publish.sh`: family syntax + `tests/chart_publish_check.sh` + `tests/publish_seam_check.sh` (the same files the gate calls; it never invokes the gate) |
| `full` | everything else: platform/runtime artifacts, workflows, tests, mixed families, unknown or empty diffs | `bash tests/validate.sh` with no flags |

Non-PR events — pushes to `master`, the weekly schedule, manual
`workflow_dispatch` runs — always take `full`: they are the release proof
and are never narrowed. A narrowed run says so in its log (`NOT RUN: …`)
and is never reported as a platform-test pass.

## How a service repo adopts kit

Building your **own** application on Kit — outside cafaye, keeping your
commits, taking Kit updates as a reviewable PR, and sending improvements
back — is a separate path with its own page:
[`docs/customer-upstream.md`](docs/customer-upstream.md). It covers the
two update directions (your source merges from a named upstream remote;
Kit's pieces are pinned SHAs with branch comments, moved by Renovate PRs
via `github-digest` — no tags needed, Kit is public), the two upstream
contribution paths kept apart (general app fixes to the canonical app,
branding stays downstream; Kit improvements to Kit per §4), the opt-in Renovate
block, and what the page does not promise (no end-to-end Renovate proof).

A service repo does **not** copy the workflow. It calls it, so a fix in kit
reaches every service on the next run without a per-repo PR.

**1. Call the workflow.** Create `.github/workflows/ci.yml`:

```yaml
---
name: ci
on: [push, pull_request]
permissions:
  contents: read
jobs:
  ci:
    uses: cafaye/kit/.github/workflows/ci.reusable.yml@master
    with:
      language: go          # go | ruby | elixir | python | node | bun | rust | none
      working-dir: .        # the dir holding go.mod / Gemfile / pyproject.toml
```

That path is the whole contract. GitHub resolves a reusable workflow at
`{owner}/{repo}/.github/workflows/{file}@{ref}` and documents that
**subdirectories of the workflows directory are not supported** — so the file
lives at `.github/workflows/ci.reusable.yml` and nowhere else, and `kit`'s gate
asserts that the `uses:` line above is the path the file is actually at, that
the file declares `on: workflow_call`, and that there is no second copy of it
anywhere in the tree. A `uses:` line that does not resolve fails at run time on
the adopting repo's first push, which is thirteen repos and one stale sentence
away.

`{owner}/{repo}/.github/workflows/{file}@{ref}` resolves in **private**
repositories too, so a repo that adopts kit before kit is public is not
blocked; `secrets: inherit` in a caller reaches a private kit from inside the
organization.

Two jobs for two languages? Call it twice with two different `language` values.

**If you declare `concurrency`, your group must not begin with `kit-`.** Every
other spelling is yours. This is the one caller-side rule kit has, and it exists
because its absence is invisible: for four days every caller in the fleet and
`ci.reusable.yml` itself declared

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

Inside a reusable workflow `github.workflow` is the **caller's** workflow name
and `github.ref` is the caller's ref, so both sides computed `ci-refs/heads/master`
and asked for one lock. The caller holds it. The `uses:` job above was then never
created — no job, no check-run, no log line — while the caller's own jobs ran
green and the run concluded `failure`:

```
$ gh api repos/cafaye/parlor/actions/runs/37230458669/jobs \
    --jq '.jobs[] | "\(.name) | \(.status)/\(.conclusion)"'
typecheck + build | completed/success
bin/prime         | completed/success
$ gh api repos/cafaye/parlor/actions/runs/37230458669 --jq '.conclusion'
failure
```

`gh run view --log-failed` returns **nothing at all**, because no step failed.
The signal that is not ambiguous is the `language` gate job, which is
**unconditional**: no caller had ever produced a job ending `/ language`, and
that job is where the frozen install, **lint** and the coverage step live.
`bin/prime` runs the suite, so tests were not entirely absent — but no repository
in the fleet had run kit's linter in CI.

kit's reusable workflows therefore namespace their own group (`kit-…`), and
`reusable_concurrency_check` reads kit's `ci.yml` — which is itself a caller —
and fails on a collision in either direction, after normalising `ref` and
`github.ref` to the same token. Eleven repositories were affected and none of them
had to change: the fix is one line in the shared file, which is also the only fix
that reaches a repository nobody remembers exists. `image.reusable.yml` declares
no `concurrency` block at all, which is why `identity`'s and `site`'s `publish`
runs produce `image / build` on every run while `ci.reusable.yml`'s callers
produced nothing.

**2. Publish the image.** CI proves the tree; it does not produce a deployable
artifact, and `config/deploy.yml` deploys an image rather than a commit. So a
service also calls the second reusable workflow, from its own
`.github/workflows/publish.yml`:

```yaml
---
name: publish
on:
  push:
    branches: [master]
permissions:
  # The CALLER grants this. A reusable workflow can ask for a permission but
  # cannot grant itself one, so a caller that omits it gets a read-only token
  # and a 401 at the push that reads like a wrong password.
  contents: read
  packages: write
jobs:
  image:
    uses: cafaye/kit/.github/workflows/image.reusable.yml@master
    with:
      push: true
```

There is **no image-name input, and that is the point.** The name is derived from
`github.repository` and lowercased, so CI cannot push somewhere other than where
`config/deploy.yml` pulls from. An input would be a string each service copies
into its own repository, and a copied string drifts — the deploy then fails hours
later, at the pull, on a release whose build was green.

Publishing is **opt-in**: `push` defaults to `false`, so a workflow that only
meant to check a Dockerfile still builds does not write to the registry. The tags
are `sha-<full commit>`, `<branch>`, and `latest`; the sha tag is the immutable
one and is what a deploy should be given. The registry is **GitHub Packages**
and the only credential is the workflow's own `GITHUB_TOKEN` — no PAT, no
`secrets:` entry, nothing to rotate. Provenance and an SBOM are attached, because
a registry of launch artifacts that cannot be audited afterwards is not one you
want to be holding those artifacts in.

**Credential in your history? Rotate it.** A credential that was committed and
later deleted is still in the packfile of everyone who cloned, and on every fork.
kit no longer runs a history scanner against your repository — your host's push
protection is where that is caught, on the push that introduces it and attributed
to the author.

**If you hold credentials, copy `templates/secrets/<lang>/` with its suite.** The
canary plants a fake credential and the gate proves the value never appears in any
exporter's output. That is a runtime property, so it holds regardless of what is in
the history.

The `zizmor` job is opt-in, and it is the one to turn on once your own
workflows are clean:

```yaml
    with:
      language: go
      working-dir: .
      zizmor: 'true'          # the GitHub Actions security audit
```

`unpinned-uses` is reported and does **not** fail that job. That is not a
baseline — the finding is counted and printed on every run, and the decision it
is waiting on is costed in [`DECISIONS.md`](DECISIONS.md). Every other audit is
fatal.

`bun` is a first-class `language` value: frozen install from `bun.lock`,
`typecheck`, `bun test`. It exists because `gateway` was hand-rolling an entire
workflow for want of one — a repo that has adopted `bun` here can delete that
file and collapse it to the `uses:` above.

`none` is the eighth value, for a repository with **no service manifest at all**
— no `go.mod`, no `Gemfile`, no `pyproject.toml`. The other seven jobs each
open by reading one, so there was no way for such a repository to call this
workflow; in practice that excluded `kit` itself, which is why `kit`'s own CI is
a `uses: ./.github/workflows/ci.reusable.yml` with `language: none`, and why
the repository that defines the standard is the first one held to it. That job
runs your repository's own `tests/validate.sh` and **fails if it is missing** —
a config gate with no gate in it is the same defect as a coverage threshold left
at `0`.

**2. Lint config: nothing to copy.** There is no step 2 any more, and its
absence is the point — see [Where the lint configs run](#where-the-lint-configs-run)
for the measured reason and the mechanism per linter. The short version: the
reusable workflow checks `lint/` out of kit at run time and passes `--config` at
it, so a service inherits kit's policy with no file in its tree and no action.

**3. Copy the Dockerfile and the two scripts.** Rename the Dockerfile to
`docker/Dockerfile`, the primer to `bin/prime`, and the dev loop to `bin/dev`:

```sh
cp <kit>/docker/Dockerfile.go          docker/Dockerfile
cp <kit>/docker/entrypoint.sh          docker/entrypoint.sh
cp <kit>/templates/bin-prime/go.sh     bin/prime
cp <kit>/templates/bin/dev.sh          bin/dev
chmod +x bin/prime bin/dev
```

Set `SERVICE_NAME` (Go, Rust) or the `:app` release name (Elixir) to your real
binary or application name. `bin/dev` needs no stack files beside it — it fetches
them. Write the pin and commit it:

```sh
git -C <kit> rev-parse HEAD > kit.ref
```

**The entrypoint changes what a deploy does, so read this before you ship it.**
Every Dockerfile now starts through `docker/entrypoint.sh`, which resolves a
migration command, runs it against `DATABASE_URL`, and only then `exec`s your
service. Consequences, all of them the point:

- **A failed migration is now a failed container.** It will crash-loop rather
  than serve requests against a schema it does not understand. Your healthcheck
  and your restart policy see a real failure instead of a 500.
- **Every replica migrates at boot.** That is safe only if your migration step is
  idempotent — which is what a version table buys you. If yours is a bare `for`
  loop of SQL files with no version table, set `KIT_MIGRATE_ADVISORY_LOCK` and
  install `postgresql-client`, or every replica replays every file at once.
- **You can no longer `docker run` the image for a side purpose** without
  `KIT_MIGRATE=off`. A `--help`, a one-off shell, a debug container: set it.
- **`go` and `rust` images no longer finish on distroless.** They finish on
  `debian:*-slim`, because neither distroless variant ships a shell and the
  entrypoint is a script. If you would rather keep distroless, set
  `KIT_MIGRATE=off`, run migrations from a Kamal `pre-deploy` job, and change the
  final stage back — that is a legitimate trade, and the Dockerfile says so.

Set `KIT_MIGRATE=required` for any service that owns a schema, so an image whose
migration command went missing fails loudly at boot instead of quietly serving
the old schema.

See [the local stack](#the-local-stack--templatescompose).

**4. Copy `templates/mise.toml` to `mise.toml`** and raise every placeholder to
the version you actually deploy. kit's values are placeholders, not an org-wide
lockfile — see the comments at the top of that file.

**5. Copy `templates/AGENTS.md` to `AGENTS.md`** and fill in the placeholders.

**6. Provide a coverage command.** The gate is a placeholder (`0`) on day one so
adoption never blocks a repo, but a gate that can never fail is not a gate. Each
language already has the expected command:

| Language | Coverage command the job runs |
|----------|-------------------------------|
| go | `go test -coverprofile=coverage.out ./...` then `go tool cover -func` against `COVERAGE_FAIL_UNDER` |
| rust | `cargo llvm-cov --fail-under-lines` |
| ruby | `bundle exec rake coverage` (add a `coverage` task to the Rakefile) |
| elixir | `mix coveralls --minimum-coverage` (declare the `coveralls` hex dep) |
| python | `pytest --cov --cov-report=xml` then `coverage report --fail-under` |
| node | `npm run coverage` |

Then raise `COVERAGE_FAIL_UNDER` in your CI caller:

```yaml
    with:
      language: go
      coverage-fail-under: '80'   # passed through as an env override
```

**7b. Opt into trace propagation**, once you have copied
`templates/otel/<lang>/`:

```yaml
    with:
      language: go
      telemetry: 'true'          # runs the W3C conformance suite on every push
```

It is opt-in and defaults to `'false'`, so adopting kit never turns a green repo
red. It is a string rather than a boolean on purpose: GitHub coerces the bare
word `false` to a boolean in some positions, and `if: inputs.telemetry` is a trap
as a result.

**7c. Declare your tiers, then demand one.** Copy
`templates/tier/<lang>/` into your test tree and copy the `REQUIRED_<TIER>=1`
gate variable into the suite — a tier that cannot fail is a skip wearing a
green checkmark. Then name it in the caller:

```yaml
    with:
      language: go
      required-tier: 'REQUIRED_DB'   # exported as 1; zero tests then fails
```

Setting it commits you to the normalised result format
(`templates/tier/README.md`) — the `tier demand` step reads a `ran` line out of
the run log and fails **naming the variable** when the tier ran nothing. It is
opt-in and defaults to `''`, so adopting it never turns a green repo red.

**7d. Adopt the runtime credential-leak canary**, once you have copied
`templates/secrets/<lang>/`:

```sh
cp -R <kit>/templates/secrets/go/internal/canary internal/canary   # go
```

Then, in your test bootstrap, plant the canary and sweep for it. Start by
reading [`templates/secrets/go/README.md`](templates/secrets/go/README.md) —
there are three things to wire up (your credential type, your log sinks, your
public keys) and none of them is automatic, because the harness cannot
enumerate a process's loggers and a harness that guesses is a harness asserting
against the wrong contract.
**7e. Adopt Kamal**, once you have something worth deploying.

```sh
cp <kit>/templates/kamal/deploy.yml.erb      ./config/deploy.yml
cp <kit>/templates/kamal/kamal-backup.yml.erb ./config/kamal-backup.yml
cp <kit>/templates/kamal/drill.sh            ./bin/drill && chmod +x bin/drill

kamal init                                # creates .kamal/secrets
kamal registry login --password-stdin     # populates it
```

Then export the five non-secret variables Kamal's ERB reads — `KIT_SERVICE`,
`KIT_REGISTRY_ORG`, `KIT_REPO`, `KIT_WEB_HOST`, `KIT_APP_DOMAIN` — and
`kamal setup`.

**The service image needs no Ruby, and the backup accessory ships its own.** A
service that wants backups and no `kamal-backup` gem on the operator's machine
still gets them, because the accessory's scheduler loop is what takes snapshots;
what it loses is `restore local` and `drill local`, not the backups. The
non-backup deploy path never needed anything kit did not already assume.

**`RESTIC_PASSWORD` is a separate secret from the R2 key**, and that is the point:
someone with the bucket credentials does not thereby have the key the snapshots
are encrypted with.

**Drill it before you need to**, and read the row counts rather than the exit
code:

```sh
bin/drill --table users --table documents
```

It restores into a scratch database, fails if either table is empty, and drops
the scratch database on every exit path including a failure. Full rationale —
including which of your databases is content and which is rebuildable working
data, and what R2's lack of Object Lock costs you — is in
[`templates/kamal/README.md`](templates/kamal/README.md).

**7. Run kit's own gate before you open the PR that adopts it:**

```sh
bash <kit>/tests/validate.sh
```

### Adoption checklist

- [ ] `.github/workflows/ci.yml` calls `cafaye/kit/.github/workflows/ci.reusable.yml@master`
- [ ] If `ci.yml` declares `concurrency`, its `group` does **not** begin with
      `kit-`. Any other spelling is fine, including declaring none. This is the
      only caller-side rule kit has, and it is the one whose absence is
      invisible: a colliding group means the `uses:` job is never created, so the
      run is `failure` with green jobs and an empty `--log-failed`. See
      [the caller contract](#how-a-service-repo-adopts-kit).
- [ ] `.github/workflows/publish.yml` is copied from `templates/publish/publish.yml`
      and calls `cafaye/kit/.github/workflows/publish.reusable.yml@master` with
      `push: true`; the workflow grants `packages: write`. **Without it nothing
      builds the image `config/deploy.yml` deploys and nothing pushes the chart
      the Argo CD `Application` pulls**, and CI stays green the whole time — a
      green CI and an unpublished artifact are not in tension, they are just
      both true. A service whose chart lives somewhere other than `chart/`
      (gateway's is `chart-dir: charts/gateway/`) names the directory; a
      service with no chart at all calls `image.reusable.yml` directly
      rather than the composer, whose `resolve` job then resolves an empty
      `app-version` for it. The chart's name and version are
      read from `Chart.yaml` by the workflow — the `Application`'s
      `targetRevision` must equal the chart's `version`, because the OCI tag of
      a Helm chart is its version and the two are the same fact written twice.
      And `values.yaml`'s `image.tag` must equal the chart's `appVersion`,
      because that is the tag the composer now makes the image workflow
      publish — a chart pinning anything else pulls `ImagePullBackOff`.
- [ ] `working-dir` points at the dir holding the manifest
- [ ] Nothing copied from `lint/` — the workflow passes kit's config at run time.
      If your repo carries a `.golangci.yml`, it must AGREE with kit's; see
      [Where the lint configs run](#where-the-lint-configs-run)
- [ ] `docker/Dockerfile` copied, binary/application name set
- [ ] `docker/entrypoint.sh` copied beside it, `chmod +x`
- [ ] `KIT_MIGRATE` decided: `required` if this service owns a schema, `auto` if
      it does not. A service that owns a schema and leaves this at `auto` is one
      misconfigured image away from serving an old one.
- [ ] `KIT_MIGRATE_CMD` set if there is no `bin/migrate` in the repo (Go, Rust
      and Elixir all need it — the image ships the binary, not the SQL)
- [ ] `KIT_MIGRATE_ADVISORY_LOCK` set, **or** you have checked that your migration
      tool serializes replicas by itself and you can say which mechanism
- [ ] `bin/prime` copied, `chmod +x`, green on a fresh clone
- [ ] `bin/dev` copied, `chmod +x`, `bin/dev up` green on a fresh clone
- [ ] `kit.ref` written and committed: a 40-char sha or a `v<semver>` tag, never a branch
- [ ] `docker-compose.yml` is an OVERRIDE: no `ports:`, no `otel-collector`, no vendor config tree
- [ ] `mise.toml` copied, every placeholder raised to a shipped version
- [ ] `config/deploy.yml` and `config/kamal-backup.yml` copied from
      `templates/kamal/`, and the five `KIT_*` variables exported. **Every secret
      is a NAME in `env.secret`; no credential may appear in either file.**
- [ ] Every secret `config/kamal-backup.yml` names is ALSO in the backup
      accessory's `env.secret` list. `kamal-backup validate` is the check, and it
      is the only thing that can see a disagreement between the two files.
- [ ] `bin/drill` copied, `chmod +x`, and run once with real `--table` names.
      **A backup nobody has restored is a hypothesis.**
- [ ] `kamal-backup evidence` run and its output kept somewhere a human reads.
      **A backup whose failure is silent is a file in a bucket.**
- [ ] `AGENTS.md` copied and filled in
- [ ] A coverage command exists and `COVERAGE_FAIL_UNDER` is above 0
- [ ] If you propagate traces: `templates/otel/<lang>/` copied **with its suite**, `telemetry: 'true'`
- [ ] If you have a tier: `templates/tier/<lang>/` copied, `REQUIRED_<TIER>=1` honoured,
      `required-tier` named in the caller
- [ ] No `actions/cache` step caches a test report
- [ ] **Any credential you have ever committed has been ROTATED**, not just deleted
- [ ] `zizmor: 'true'` set, if your own workflows are clean
- [ ] If you hold credentials: `templates/secrets/<lang>/` copied **with its suite**
- [ ] `CHANGELOG.md` has an entry
- [ ] The workflow is green on the adoption PR

## Where the lint configs run

`lint/` is 249 lines of golangci, rubocop, eslint, yamllint and hadolint
configuration, and until now it was distributed by `cp`. **No service in the fleet
had ever copied it** — the one repository that carries its own golangci config
wrote that file itself, for its own reason, and the difference matters — it was
recorded in a fleet-wide allowlist that no longer exists. The three mechanisms kit
ships are not
equivalent, and the adoption numbers say so:

| mechanism | live? | adoption |
|---|---|---|
| `uses: cafaye/kit/...@master` | **yes** — fetched at run time | **11/11** repos that call it |
| `cp <kit>/lint/golangci.yml ./` | **no** — a snapshot | **1/11** — and that one is `identity`, which added its own in the meantime |
| `cp <kit>/templates/... ./` | no | 1/11 (`bin/dev`), 0/11 (observability) |

Counted, not estimated: a non-worktree directory beside this one that contains a
workflow with a `uses: cafaye/kit/.github/workflows/ci.reusable.yml` line. The
eleven are `billing cafe core courier darkroom docs gateway identity kit muse
parlor`, and `kit` is in the list because it calls its own workflow — the
repository that defines the standard should be the first repository held to it,
and excluding it would make the denominator flattering rather than true.

Adoption correlates **inversely** with how much a file does. The small
self-contained artifacts are universal; the large behavioural ones are used by
nobody. The reason is structural, and it is the whole argument for this section:
a `uses:` is live — change kit and every service gets it with no action — while a
copied config has no propagation at all, so it rots silently.

So the configs now run from kit, in the step that already ran them.

### The mechanism per linter, measured

Every row below was **run**, not read from documentation. The fixture for each is
in `tests/lint_test.sh`, which builds a throwaway service containing a violation
only that linter would catch, runs the same command the workflow runs, and asserts
the linter rejects it — plus a control that must answer differently.

| linter | mechanism | measured, and the part that matters |
|---|---|---|
| **golangci-lint** | `--config=<repo>/.kit/lint/golangci.yml` | With no config present it does **not** fail and does **not** run nothing: it falls back to its own five-linter default set (`errcheck govet ineffassign staticcheck unused`) and **exits 0 on a file kit's config rejects**. `GOLANGCI_LINT_CONFIG` is **not** read by v2 — set it, and the run proceeds on that same default set (measured on 2.6.2). |
| **RuboCop** | `--config=<repo>/.kit/lint/rubocop.yml` | Same shape. Measured: a 13-line method is **green** under kit (`Max: 15`) and **red** on RuboCop's defaults (`Max: 10`), so the flag is what makes the two differ. |
| **ESLint** | `--config=<repo>/.kit/lint/eslint.config.mjs` | Works, and **only because kit is checked out inside the repo**. Node resolves an ESM import from the *config file's* directory upward; a config sitting beside the repository finds no `@eslint/js` and the run dies with `ERR_MODULE_NOT_FOUND` — a red build that has linted nothing. It also needs every linted file inside a tsconfig, and `recommendedTypeChecked` is **unscoped** — see below. |
| **yamllint** | `yamllint -c <repo>/.kit/lint/yamllint.yml --strict` | The one that behaves the way the other three are assumed to. `--strict` is load-bearing: both of kit's retuned rules are warnings by default, so without it `yamllint -c kit's` and plain `yamllint` agree on the exit code and disagree on everything a human reads. |

### Every linted file must be inside a tsconfig, and `files` is load-bearing

A service that adopts kit's ESLint config and has a `.mts` or `.cts` file — which
is what every Vite or Vitest project has, and both `site` and `parlor` have three
at the repo root — used to get a red build before ESLint reported anything:

```
Error: Error while loading rule '@typescript-eslint/await-thenable':
You have used a rule which requires type information, but don't have
parserOptions set to generate type information for this file.
```

`tseslint.configs.recommendedTypeChecked` is **unscoped**, and one config inside it
(`typescript-eslint/eslint-recommended`) declares
`files: ['**/*.ts','**/*.tsx','**/*.mts','**/*.cts']` — which *adds* `.mts` and
`.cts` to the set of files ESLint will lint. The `files` glob that supplies
`parserOptions` — the only source of type information — was narrower than that, so
those files were linted, were given the type-aware rules, and were never given the
type information the rules require.

**If you add a new extension to your service, add it to your `tsconfig.json`'s
`include`.** That is the whole instruction, and it is not kit's to enforce: kit
cannot see your tree. A file outside `include` is reported as `was not found by
the project service`, which names the file and the fix.

**`--config` wins over a local config, in both linters that have one.** This is
measured, and it corrected a claim this repository made before it ran anything:
`golangci-lint run -v` prints exactly one `[config_reader] Used config file`, and
with `--config` it names kit's — a repo-root `.golangci.yml` that disables
`misspell` does not survive it. RuboCop agrees (a local `.rubocop.yml` with
`Max: 40` loses to `--config` on a 17-line method). Discovery is the *fallback*,
not the override.

That matters for what a stale copy actually does, and the honest answer is
narrower than "it hijacks your build". It does not. What it does is **split the
policy**: kit's CI reads kit's file, and every other invocation in that repository
— a developer's `golangci-lint run`, an editor, a `make lint` — reads the local
one. Two policies in one repository, one of them enforced nowhere it is written
down. And the copy becomes live again the moment the `--config` flag goes missing,
silently, because a copy is always weaker than the thing it was copied from.

### What could not be done, and the cost

**ESLint cannot be configured from a URL at all.** Not "we chose not to": the
mechanism does not exist. `import()` of an `https:` URL raises
`ERR_UNSUPPORTED_ESM_URL_SCHEME` — the default ESM loader supports `file` and
`data` only — and the flag that once allowed it, `--experimental-network-imports`,
is **removed in Node 22** (`bad option`). So there is no remote-config path to
weigh, and a flat config must exist as a real file on disk.

**RuboCop does have one, and it works.** A three-line `.rubocop.yml` that says
`inherit_from: [https://raw.githubusercontent.com/cafaye/kit/master/lint/rubocop.yml]`
is genuinely applied — measured, a 17-line method is reported as
`[17/15]` — and it *propagates*, so it does not rot the way a copy does. A bad URL
fails loudly (exit 2, `404 "Not Found" while downloading remote config file`)
rather than falling back to defaults, which is the right direction.

It is **not** what the workflow uses, and the reason is worth stating: it needs
the network on every lint run, it re-downloads a config that is a versioned
artifact in a repository we control, and it puts a per-service file back — the
shape this section exists to remove. `--config` against a checkout is
deterministic, offline, and versioned with the workflow that uses it. The remote
form is recorded here as the honest alternative for a repo that cannot take a
checkout.

### The deviation seam

One input, and it is deliberately narrow:

```yaml
    with:
      language: go
      lint-args: "-E gosec"      # appended AFTER kit's own flags
```

- It comes **last**, so a service can add flags and cannot remove the `--config`
  that precedes it. Anything here is an addition to kit's invocation, not a
  replacement of it.
- It is a **string, not a path**, so there is no service-side config file for a
  linter to read and therefore none to rot. A seam that reintroduces the file
  reinstates the failure this section exists to end.
- It **may not change which config is read, what is linted, or whether a
  finding fails the build.** That is the whole policy in one sentence, and it is
  enforced by the `lint-args guard` step that runs before every linter, in the
  **workflow** rather than in kit's gate — because `lint-args` is the caller's
  value and kit has never got it.

  The guard refuses 15 flags, each read out of the linter's own `--help` on the
  version kit pins:

  | refuses | why |
  |---|---|
  | `--config`, `-c`, `--no-config`, `--no-config-lookup`, `--force-default-config` | which config is read — the last three are golangci-lint's, ESLint's and RuboCop's separate ways of saying "ignore the config you were given" |
  | `--new`, `--new-from-rev`, `--new-from-patch`, `--new-from-merge-base` | what is linted — a diff rather than the tree, so a red file outside the patch is green |
  | `--issues-exit-code`, `--fail-level` | whether a finding fails the build — `--issues-exit-code=0` is a linter that cannot fail |
  | `--quiet`, `--no-error-on-unmatched-pattern` | ESLint's way of reporting less; `--quiet` means *errors only*, which is looser, not stricter |
  | `--auto-gen-config`, `--regenerate-todo` | both **write a config file into the tree** — a linter that generates its own config is the copy mechanism arriving through the back door, and it would be a copy nobody reviews |

  `lint_args_seam_check` in `tests/validate.sh` asserts the guard is present in
  all three lint jobs, that the three copies are byte-identical, that the guard
  runs **before** the linter (a guard after it is decoration), that the linter
  actually receives `$KIT_LINT_ARGS`, and that the refused-token list is the one
  written there. Without that last one, deleting `--no-config` from the guard
  would widen the seam for the whole fleet and leave the workflow looking exactly
  as it did — which is why the guard itself is a check and not a convention.
- If a flag is wanted often enough to be common, it belongs in `lint/` and every
  service gets it for free.

A repo that wants a stricter *rule* rather than a stricter *flag* has no seam, and
that is the intended pressure: the rule belongs in kit, where a change to it
reaches every service that calls the reusable workflow, rather than in each copy.

### The gate that caught a service drifting back, and does not any more

This used to exist and it was a good check, which is worth saying before the
detail of why it is gone.

`lint drift` in `tests/validate.sh` read **both** files and reported the
**difference** between a service's `.golangci.yml` and kit's, linter by linter,
rather than demanding the file be absent. Banning the file was the first version
and it is worse than the drift it prevents: a config that matches kit's has
reached the same policy by another route, and failing it teaches the lesson that
kit's config is a thing you get shouted at for having. An agreeing copy had to
**pass**.

It is gone for the reason every other fleet check is gone. It found services by
walking `../*` for a `.github/workflows` directory containing a `uses:
cafaye/kit/...` line, so a clone of kit — which is what a CI runner is — found
none and reported SKIP on every run of every commit. `lint/drift-allowlist` held
its dated divergences with an `owner=` field naming who was supposed to fix each
one: a file in this repository assigning work to people in other repositories,
which is the fleet boundary in its purest form.

What replaces it is nothing, and the gap is real: kit no longer knows when a
service's lint config drifts away from the one it ships. If that matters to you,
the check belongs in the **adopting** repository, where the finding lands on
whoever can act on it. That is the whole argument of `DECISIONS.md` MD36, stated
here as a recommendation rather than a justification.
## Test tiers — `templates/tier/`

A **tier** is a class of test that needs a real dependency to mean anything: a
database, Redis, a broker. The failure this exists to prevent has already
happened in this fleet — **a green run in which the whole database tier never
executed once**, because the suite reported `ok`, and `ok` is the only thing
anybody read.

Tier membership is **declared in the test source** and read by **the runner's
own collector**. It is never grepped for a sentinel, because a sentinel fails
*open*: Identity derives its database tier by grepping for
`dbtest.Pool|Schema|EnvVar|TEST_DATABASE_URL`, and a test that reaches Postgres
through a helper two files away, or through a fixture, does not match — so its
package never enters the required list, and the run is never required to contain
it. The test is written. It is not gated. Nobody finds out.

| `language` | Declaration | Collector | Adapter? |
|---|---|---|---|
| `rust` | `#[ignore = "cafaye:tier=db reason=…"]` | `cargo test -- --list` | none |
| `go` | `//go:build tier_db` | `go test -tags tier_db -list '.*' ./...` | none |
| `python` | `@pytest.mark.tier_db` | `pytest --collect-only -q -m tier_db` | none |
| `elixir` | `@tier :db` | none — needs one | ~15 lines |
| `node` | `export const TIER` | none — needs one | ~15 lines |
| `bun` | `export const TIER` | `bun test --reporter=junit` (partial) | ~15 lines |
| `ruby` | `tier :db` class macro | none — needs one | ~15 lines |

Two results here were **measured rather than assumed**, and both corrected the
prior claim:

- `cargo test -- --list --format json` is **nightly-only** (`-Z
  unstable-options`, rustc 1.95.0). On stable, `--list` includes ignored tests
  and `--list --ignored` gives the ignored subset — which between them carry
  everything the JSON would have. `--list --include-ignored` lists *everything*
  and filters nothing; it is a trap, and the Rust template says so.
- `bun test --reporter=junit` **does** emit a full inventory — a filtered-out
  test is still present as a `<testcase>` — so the absent-testcase failure mode
  does not occur there. What it lacks is a declared *reason*: `test.skip` takes
  none.

The normalised result format, the skip allowlist and its four hygiene rules, the
`REQUIRED_<TIER>` demand, and **what a tier gate cannot catch** are all in
[`templates/tier/README.md`](templates/tier/README.md). The short version of the
last one: the machinery can prove *"41 tests ran"*; only an assertion **inside**
the test proves *"41 tests hit Postgres"*. A gate whose documentation overstates
it is worse than no gate.

**Floors are decrease detectors, not tier gates.** Identity's
`1254/1166`-style floors are cheap and they catch deletion — keep them. But a
floor is satisfied by *any* 1254 tests, including the wrong 1254, and nothing
about it knows which tier a test belongs to.

### Never cache a test report

`actions/cache` `restore-keys` restores **stale** caches by **prefix match**,
and GitHub documents that the default branch's cache is available to other
branches. So a cache key built from `hashFiles('**/lockfile')` — which does not
contain the gate variable — restores a test report written by a run that **had**
the database into a run that does not.

**A witness restored from a different run is not a witness.**

Cache `target/`, `$GOCACHE`, `node_modules`, `vendor/bundle`. Those are build
products. Do not cache `junit.xml`, `test-results/`, `coverage.*`, or anything
else a gate would read as evidence. `tests/validate.sh` fails when an
`actions/cache` step names one.

There is a second, sharper version of this that no check in a single repo can
catch: **fork pull requests get read-only cache access**, so a workflow using
`actions/cache` lets a fork restore a trusted run's cached report into its own
run. That is a cross-trust-boundary path into the gate, and it exists today in
any workflow that caches at all. Treat a cached report as untrusted input.

## Design rules

These are the rules that keep kit from becoming the thing it exists to prevent.

- **Config only.** No runtime code, no library, no build step. If kit grows a
  dependency, it has stopped being conventions.
- **A caller overrides, it never forks.** Values that differ per service —
  versions, coverage thresholds, service names — are inputs or build args, not
  copies. Six repos that each hold their own copy of a workflow is the drift
  this repo exists to prevent.
- **Boring beats clever.** Flat layout, no framework, no generator. `grep` finds
  everything here.
- **Strictness is documented, not implied.** Every config carries comments
  explaining what is enforced and why, so a future contributor relaxes it
  deliberately instead of by accident.
- **The gate is the contract.** `tests/validate.sh` is the definition of done
  for every artifact here, and it fails on any file that does not parse.

## Working on kit

```sh
bash tests/validate.sh
```

That is the entire procedure on a clean clone. The gate installs its own
dependencies into gitignored directories on first run and prints a `note:` line
saying so — PyYAML, yamllint and zizmor into `.venv/`, and hadolint
into `tests/.bin/`. There is no prerequisite step, because a prerequisite that is
documented rather than automated is one that gets skipped by exactly the machine
you most wanted to hear from.

This bit twice. It used to exit 1 with `no python with PyYAML` because it
preferred `.venv/bin/python` and fell back to `python3`, and `.venv` is
gitignored — so **every fresh clone and every CI runner** hit it, including the
CI job this repository now runs on itself.

The binaries go in `tests/.bin/` rather than `.venv/bin/` so that a checkout's
own tool directory is where a tool lands, and a second run on the same machine
reuses it.

The *language* toolchains are found the same way, one step further: if `mise` is
installed, the gate asks it for the environment this shell would have had, so a
`mise`-managed `go`, `gofmt`, `node`, `ruby`, `elixir`, `golangci-lint` or
`rubocop` is found whether or not the shell that launched the gate was
mise-activated. Without that, `bash tests/validate.sh` — which is neither an
interactive nor a login shell, and so reads no `.zshrc` or `.zprofile` — reported
`gofmt: command not found` on a machine where `gofmt` was installed, and since
the lint phase is fatal on a skip, that was a red build rather than a warning.
There is nothing to install and nothing to export: no `mise` on the box, a shell
that mise has already set up, and mise with nothing configured are all no-ops,
the last of which is exactly the CI case.

`tests/validate.sh` runs in three phases and prints one line per check.

**static** — every artifact parses, and the strictness decisions are still what
we wrote them down to be:

- `.sh` → `bash -n`, plus `shellcheck -S warning` when shellcheck is installed
- `.yml` / `.yaml` → `python` `yaml.safe_load`
- **every** `.yml` / `.yaml` in the tree → `yamllint -c lint/yamllint.yml`,
  enumerated by `git ls-files` rather than a hand-kept list. Required, not
  optional: kit lints its own YAML on day one, so a YAML that breaks the config
  greets the first adopter with a failure nobody authored
- `.mjs` → `node --check`
- `templates/tier/<lang>/*` → parsed in **their own language**, because they are
  files a service copies: `rustc --test` (Rust, and `--list` proves the
  inventory the allowlist reads), `compile()` (Python), `ruby -c`,
  `Code.string_to_quoted!` (Elixir), `gofmt` (Go). TypeScript is a loud `SKIP`
  naming its reason — stock `node --check` cannot read it, and a type-stripping
  parser is a dependency this repo does not have
- `docker/Dockerfile.*` → `hadolint -c lint/hadolint.yaml`, **plus** the
  non-root / no-`:latest` / no-`ADD` rules hadolint does not cover, **plus** a
  requirement that each template's own STRICTNESS NOTES state the non-root
  guarantee. Required, not optional: see
  [what the gate lints the Dockerfiles with](#what-the-gate-lints-the-dockerfiles-with-and-why)
- handed-out scripts → must be executable
- every language in the CI workflow must have a Dockerfile, a `bin/prime` and a
  `[tools]` pin — "half a language is worse than none"
- the collector must have no exporter but `debug`, no literal URL, and every
  `${env:...}` it reads must actually be passed into the container
- every published compose port must be a `${KIT_*:default}` substitution
- the reusable workflow must be **callable**: at the path the docs tell
  callers to use, declaring `on: workflow_call`, with every documented
  `uses:` matching it exactly, `kit`'s own CI calling it with the local `./`
  form, and no second copy anywhere in the tree
- the `telemetry` CI job must stay opt-in and the six original jobs must stay
  gated on their language, or adopting kit breaks every consumer
- every language with a CI job must also ship a **tier declaration** in
  `templates/tier/<lang>/` and have a row in that directory's README naming the
  collector that reads it — see [Test tiers](#test-tiers--templatestier)
- the `required-tier` input must stay opt-in (default `''`), be exported by
  every language job, and be checked by an identical `tier demand` step in each
  one. The six copies are byte-compared, because hand-maintained copies of a
  policy block is the drift this repo exists to prevent
- the skip allowlist must satisfy four rules — **reason, owner, `since`,
  `until`** — and **an entry matching nothing is a failure**. The total is
  printed on every run, green included
- no `actions/cache` step may cache a test report
- **no `run:` body may read a variable it only ever set as a prefix
  assignment.** `VAR=value cmd` puts `VAR` in `cmd`'s environment and in no
  shell variable, so `echo "$VAR"` under `set -euo pipefail` is
  `unbound variable` and exit 1 — which is how
  `image.reusable.yml`'s `stamp provenance` step failed on every run it ever
  had, and why `ghcr.io/cafaye/site` has never been published. A prefix
  assignment that is **never** read back in the same block is left alone: the
  command is its only consumer and the command did receive it. Comments are
  stripped before the body is read, so the fix's own comment — which quotes the
  broken shape — neither satisfies nor falsifies the check
- no workflow may declare `pull_request_target`, `workflow_run` or
  `issue_comment`, read off the **parsed trigger keys** so the comment explaining
  why is not itself a violation
- `.github/zizmor.yml` must not ignore or disable `unpinned-uses`, must not carry
  a blanket `ignore: "*"`, and every ignore entry must carry a reason beside it
- the canary must never appear as a literal anywhere in the tree, and must be
  structurally unmistakably fake: prefixed, the right length, and a repeated
  word rather than something a high-entropy detector would score as random

**telemetry** — the W3C traceparent suites are **executed**, one per language,
and so is the canary harness:

```sh
bash tests/validate.sh --language=go     # one language
bash tests/validate.sh --static-only     # no toolchains needed
```

Stdlib only and offline on purpose: no `go mod download`, no `bundle install`,
no `npm ci`, no `cargo fetch`. If these ever need the network, a template has
grown a dependency and kit has stopped being config-only.

The canary suite runs with `-v` so every vector's red proof is visible in the
output. A proof nobody can see is a proof nobody ran.

**No self_test, and no tree copies.** There is no self-test phase, and the
reason is not an oversight. A self-test here meant: copy this whole repository,
mutate the copy, run an entire gate against it, and assert it went red. That is
a tree copy per defect, and it does not scale — `$WORK` was created once and
swept only by an EXIT trap, so every copy made in minute 1 was still on disk in
minute 15. Measured on this machine: **24 GiB** of leftover copies in one
`TMPDIR`, and 17.5 GiB at load 48 across seven concurrent runs.

So the whole layer is gone — the ~120 breakages, `tests/self_test.sh`,
`tests/shard_test.sh`, and every check that existed only to police them. Nothing
replaced it: there is no mutation-testing tool, no copy machinery behind an env
var, and no `git worktree` variant.

**What a check uses instead is a FIXTURE, and the two are not the same thing.** A
fixture is a small directory the check builds itself to hold one planted value:
a ~4 KB git repo for the secret scan, a service-shaped tree for the linters, a
schema substrate for the tenancy proof. It never contains this repository, and
nothing runs the gate against a modified version of itself.

**The behaviours the self-test existed to protect are all still protected, and
every one was proved able to go RED without a copy:**

| behaviour | how it is proven now | red proof |
|---|---|---|
| the canary is never committed as a literal | greps the real tree | a planted literal, assembled at runtime so the fixture holds no contiguous string; red on the real tree |
| the canary suite never prints what it planted | runs the real Go suite, sweeps all its output | a runtime-assembled `t.Log` in the suite; red on the real tree |
| the Postgres tag agreement | a direct read of `.env.example` and compose | `17` -> `16.6`, the defect that shipped |
| cluster topology and the connection budget | direct reads of compose and `.env.example` | delete the initdb mount; drop the budget to `4` |
| tenancy / account boundary / isolation | **untouched** - already a live docker tier | its own FORCE control, every run |
| the lint gate goes red on a planted error | already so by construction: all 22 assertions assert a linter REJECTS the fixture | - |
| the GREEN control | an ordinary gate run | 168 verdicts, 0 FAIL |

`CUT-ALL-DISPOSITION.md` carries this table with the measurements.

**The honest gap, stated rather than buried:** nothing can now prove the gate is
*able* to fail. A check nobody has ever seen go red is a claim in a comment. The
behaviours above are what stands in that space, and the price of adding a
check from here is that you are the one who has to try to break it.


Any `FAIL` exits 1. A `SKIP` is always reported in the summary, never hidden.
PyYAML, yamllint, zizmor and hadolint are required and are
**bootstrapped by the gate itself**; the seven language toolchains and
`shellcheck` run when present.

**Four counts, because they are four different claims.** `PASS` and `FAIL` are
about the tree. `SKIP` is about the **environment** — no docker, no toolchain,
nothing ran. **`BOUND` is about the run**: the tier started, this machine was too
busy to finish it, and the claim it exists to prove is therefore *unexercised*.
The heavy tiers — the docker stacks, the cluster tiers, the lint phase — carry a
time bound for exactly this reason. A gate
SIGKILLed by the OOM killer reports nothing about the tiers it never reached, so
its green is a claim about how far it got; a bound converts that into a verdict
that is stated rather than a run that stops. The summary prints both how many
tiers ran under a bound and how many reached one.

### What the gate lints the Dockerfiles with, and why

`docker/Dockerfile.*` is the one artifact here that used to have **no parser at
all** — seven lines reading `SKIP ... (no parser for this file type)`, honest,
and completely uncovered. It now has two layers:

- **`hadolint -c lint/hadolint.yaml`** — a real parser, required, pinned to
  2.15.1 and verified against hadolint's published `checksums.sha256`. Not
  optional: hadolint is a single static binary the gate fetches on first run, so
  "it was not installed" is not an excuse available to anyone, and a linter that
  is silently a different version is the same skip wearing a pass.
  `failure-threshold: warning` — hadolint's `info` tier is advisory style, and a
  gate people run with `--no-fail` is not a gate. The **one** ignored rule is
  DL3008 ("pin apt versions"), and the argument for it is written out in
  `lint/hadolint.yaml`: these are templates thirteen repos copy, so a hardcoded
  `build-essential=12.9` is a version thirteen people must remember to bump,
  and the day Debian drops that build every one of them fails at once — a
  correlated outage caused by a security patch landing.
- **`docker/Dockerfile.*  (non-root final stage, no :latest, no ADD)`** — the
  two properties hadolint does **not** cover. DL3002 only fires when a `USER` is
  present and wrong; a *missing* `USER` is silence, and silence is how an image
  ships running as root. `ADD` is refused because it can fetch a URL, so it is a
  way to put unverified content in an image without a hash.

A third check requires each template's `STRICTNESS NOTES` to state the non-root
guarantee in the file itself. All seven do run non-root, and the check above
proves it; this one is about the reader deciding whether to adopt the file, who
reads the notes and not the gate.

hadolint found one real defect on its first run, which is the argument for
having run it: `docker/Dockerfile.python` did `pip install uv` with no version,
so the resolver's own version silently decided what a build resolved. It is now
`ARG UV_VERSION=0.5.11`, in step with the `uv` pin in `templates/mise.toml`.

It also found a documentation bug, which is the argument for the third check:
`Dockerfile.bun`'s notes said *"The official image has no unprivileged user, so
we create one."* The official `oven/bun:1.3.12-slim` image ships `bun` at uid
1000 (verified against the running container), and the `useradd` that note
described was never in the file — so the note described a different Dockerfile
than the one being read.

## License

**MIT.** See [LICENSE](LICENSE).

kit is configuration and documentation — no runtime code, no library, nothing
imported by anything — so the `LICENSE` file is the entire grant. The one
manifest kit carries, `cafaye.yml`, has no licence field: core's manifest schema
declares no such key (`core/schemas/cafaye.manifest.schema.json` sets
`additionalProperties: false` and enumerates its twelve `properties` in full, and
none of them is `license`), and a manifest copied out of a Go, Rust or Node
project would be the one place that could disagree. That is the same shape as Go
modules, where the file is the grant too.

That last sentence is a **claim about the tree**, so a check holds it: the gate
reads the grant, then
inspects every manifest at the repository root that can carry a licence field,
failing on any that declares something else. A licence is only unambiguous when
exactly one place in a repository can declare one — a `package.json` appears, it
carries `"license": "AGPL-3.0-only"` copied out of a service, and now a
compliance tool and a reader are reading different files. The check does **not**
ban the manifest; it requires it to agree, which is the difference between a rule
and a ratchet.

**What that check does not say today is what kit's grant now is.** `license_check`
in `tests/validate.sh` was written for the Cafaye proprietary grant (m172, recorded
in `REPORT-kit-license-check-m172.md`) and still asserts the proprietary sentences
and refuses MIT's permission grant. OPS-D2 re-grants kit, so the check and the
grant disagree; the grant is the file and the check is what has to move. The gate
is red on exactly that one check, which is the honest state of it.

See [kit's own licence](#kits-own-licence) for why this is a separate question
from the AGPL-3.0 backends kit ships unmodified.
