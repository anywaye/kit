# kit

**kit is the shared CI, lint, and toolchain layer every cafaye service repo
adopts.** It contains no runtime code and no dependencies — only conventions
that would otherwise be retyped, and slightly differently, in each of the six
services.

```
github.com/cafaye/caf     Go       github.com/cafaye/billing  Ruby
github.com/cafaye/identity Go      github.com/cafaye/courier  Elixir
github.com/cafaye/guard   TypeScript  github.com/cafaye/muse   Python
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

Measured on 2026-09-30 against `41f8bcb`, by `tests/staleness.py --scope
templates --repos-dir …`, over the nine services (the fleet the packet counts;
`docs` and `cafaye-{py,rb,ts}` are toolchain repos, not services, and
`pantry` is a registry that has not called kit's workflow). **Nine of 108 cells are
byte-identical.** One of them, `guard/bin/prime`, is the only copy in the fleet
that matches kit exactly — and it matches because `guard` is the service that
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

`templates/parity-allowlist` carries all 80 findings — every diverged copy,
every absence and every unmeasurable cell — as one line each, with a reason, an
owner, a `since` and an `until`. **80 is a bad number and it is meant to be
read as one.** The way to shrink the file is to re-copy an artefact and delete
the entry; deleting the entry to shrink the file is a hard failure of its own.

## What is in here

| Path | What it is | Who uses it |
|------|-----------|-------------|
| `.github/workflows/ci.reusable.yml` | One reusable GitHub Actions workflow. Input `language` picks one of seven jobs — install, lint, test, coverage gate. Opt-in `telemetry` input adds the traceparent conformance job; opt-in `required-tier` demands a tier by gate-variable name. **Plus two security jobs: `secrets` (no opt-in) and `zizmor` (opt-in).** No job builds or pushes an image. | Every service, via a 6-line `.github/workflows/ci.yml` |
| `.gitleaks.toml` | The secret-scanner allowlist, and nothing else. `extend.useDefault = true`, so the rules stay gitleaks'. Every entry carries a `description`. One entry is here for kit's own test fixture — **delete it when you copy this file**. | Copied verbatim by every service |
| `.github/zizmor.yml` | zizmor's reasoned baselines. One entry. `unpinned-uses` is deliberately **absent** — see `DECISIONS.md`. | Every service, copied verbatim |
| `lint/yamllint.yml` | YAML style, with the three rules Actions forces us to retune. Read at run time via `yamllint -c`, never copied. | Any repo that lints its own YAML; kit's gate uses it on itself |
| `lint/golangci.yml` | golangci-lint v2, correctness linters on, `errcheck` excluded only for `Close`/`Flush`. Read at run time via `--config`, never copied. | Go services |
| `lint/rubocop.yml` | RuboCop, `NewCops: enable`, Metrics left on. Read at run time via `--config`, never copied. | Ruby services |
| `lint/eslint.config.mjs` | ESLint 9 flat config, type-checked rules on. Read at run time via `--config`, and it must be checked out INSIDE the repo — see below. | Node/TypeScript/Bun services |
| `docker/Dockerfile.<lang>` | Seven multi-stage templates. All run non-root. All start through **`docker/entrypoint.sh`, which applies the service's migrations and `exec`s the service** — so a failed migration is a failed container, and the "service is up, the schema is not" cold-start class is gone. `go` and `rust` finish on `debian:*-slim` rather than distroless, because **no distroless variant ships a shell** (measured: `bin/` is empty in both) and a script needs one; the file says so and gives the escape hatch. Linted by `hadolint -c lint/hadolint.yaml`, plus a non-root/no-`:latest`/no-`ADD` check the linter does not cover. | Every service |
| `docker/entrypoint.sh` | The one entrypoint, shared by all seven templates. POSIX sh, parameterised by environment rather than by copy: resolve the migration command → prove `DATABASE_URL` → migrate → `exec "$@"`. `KIT_MIGRATE=auto\|required\|off`, `KIT_MIGRATE_CMD`, and `KIT_MIGRATE_ADVISORY_LOCK` (a Postgres **session**-level `pg_advisory_lock`, opt-in because it needs `psql`). It does **not** serialize replicas by default and says so on every boot. | Copied with the Dockerfile |
| `lint/hadolint.yaml` | hadolint config, with the two ignored rules (DL3008, DL3067) argued rather than assumed. | Any repo that ships a Dockerfile |
| `lint/drift-allowlist` | Known, owned service configs that disagree with kit's: reason, owner, since, until. An entry that expires, duplicates, or stops describing a real difference is a failure. | kit's gate only |
| `templates/bin-prime/<lang>.sh` | The worktree primer: one script per language, exit 0 only when the tree is genuinely ready. | Every service, as `bin/prime` |
| `templates/bin/dev.sh` | The local developer loop: **fetch** the stack from a pinned kit ref, bring it up, wait for health, migrate, seed an admin, print the URLs. Idempotent, fails loudly, works offline. | Every service, as `bin/dev` |
| `templates/compose/docker-compose.yml` | Postgres, NATS+JetStream, Redis, the OTel collector, and the four LGTM backing services. Every port parameterized inside kit's claimed `15000-15999` block, every image pinned, every service healthchecked and memory-bounded. **One cluster for all services**, with the database as the isolation boundary. | **Fetched** by `bin/dev` — never copied |
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
| `tests/kamal_test.sh` | The proof: generates the config **from the templates** and runs the **real** `kamal` and the real `kamal-backup` against it. 22 cases, all against the binaries. It exists because a doubled registry host, a missing `builder.arch` and a cross-file secret are all valid YAML that parses clean. | kit |
| `tests/fetch_test.sh` | Executes the fetch against a local bare remote: a pin resolves and the bytes are identical, a branch is refused **before any network call**, and offline mode is real in all four of its states. | kit |
| `tests/stack_live_test.sh` | Brings the **fetched** stack up, sends real OTLP, reads a trace out of Tempo and a **derived metric** off the collector's own exporter, and finds no canary in either. | kit |
| `tests/fleet_check.py` | Reads the **other** repositories: a stale copy of the stack, a weakened redaction boundary, a collector config nothing starts, a published port on a service kit already ships, an unpinned ref. Under the **adoption ceiling**: a `FAIL` inside a repository that has a `kit.ref`, a named `WARN` inside one that has not. | kit, over the sibling checkouts |
| `tests/generated_stack_check.py` | Asks **git** two questions of every sibling that has a `cafaye.yml` — is `caf.dev.compose.yaml` ignored, is it tracked — and reports the reverse direction too: the generated file with no manifest to have generated it. No adoption ceiling, because this defect has no adopter. A finding in a repository the fleet's scope decision holds **frozen** is printed and does not fail: the frozen set is read from `MVP-SCOPE.md` (`--scope`, default beside the fleet), never written into this repository, and a decision that cannot be read exempts nothing. | kit, over the sibling checkouts |
| `tests/canary_test.sh` | Plants a canary in ten leak shapes against a real collector and asserts it reaches no exporter. | kit |
| `tests/no_telemetry_in_readiness.sh` | Kills the collector and proves a service still starts, still serves and still reports healthy. | kit |
| `templates/otel/<lang>/` | W3C traceparent: a stdlib codec, an executed conformance suite, an SDK snippet, and a README. | Every service, per language |
| `templates/tier/<lang>/` | The **declared tier**, per language — the tests that need a real dependency, declared in the test source and read by the runner's own collector. Never grepped for a sentinel: a sentinel fails open. | Every service, per language |
| `templates/tier/skip-allowlist` | One file for the fleet. Four hygiene rules — reason, owner, `since`, `until` — and **an entry matching nothing is a failure**. | Every service; the file itself lives here |
| `templates/tier/README.md` | The normalised result format, the allowlist rules, and what a tier gate **cannot** catch. | Every service |
| `templates/parity-allowlist` | Why each service's copy of a kit template is **not** kit's bytes. Same four rules, same one-line dialect, and it adds the rule the tier file does not need: **an unpinned divergence or absence is a failure too**. The count is printed on every green run. | The whole fleet; the file itself lives here |
| `templates/mise.toml` | Toolchain pins, one per language, commented. | Every service, as `mise.toml` |
| `templates/AGENTS.md` | Skeleton repo-conventions file. | Every service, as `AGENTS.md` |
| `core/` | The `cafaye/core` fan-out: a `vendir.yml` per consuming repo, the one shared Renovate policy, and what `core` needs to publish semver tags. | Any repo that consumes core's schemas |
| `tests/classify.py` | Classifies a change to a vendored schema set into `FILE`/`PACKAGE`/`WIRE_JSON`/`WIRE`, and **fails closed** on anything `tests/rules.json` does not name. Stdlib only. | Any repo that vendors core |
| `tests/staleness.py` | Two scopes. `--scope core` reads every consuming repo's recorded pin and prints the distance. `--scope templates` reports whether each service's copy of a kit template is `current`, `diverged`, **`absent`**, `unknown` or `n/a`, and whether the reason for it is recorded. | Scheduled, fleet-wide |
| `tests/artifacts.json` | The ONE place kit says what it ships and where a service puts it. Read by the reporter *and* by the gate — a table written down twice is a table that is right in one of the two places. | kit |
| `tests/validate.sh` | kit's own suite — the gate. | kit |
| `tests/gitleaks_gate.sh` | The one secret scan. Run by the `secrets` job **and** by the gate. | Every service, copied verbatim |
| `tests/zizmor_gate.sh` | The one zizmor split: `unpinned-uses` recorded, every other audit fatal. | Every service, copied verbatim |
| `VERSION` | **The version, and the only place it is written.** One line. Three tiers are derived from it by `stability_tier` — MAJOR is `breaking`, MINOR `additive`, PATCH `invisible` — and `stability_gate_check` gates the release on what the tier owes: a MAJOR needs a `MIGRATIONS.md` section, a `### Breaking` heading is legal only under a version whose MAJOR actually moved, and a version string the derivation cannot place is a red build rather than a guess. | Anyone deciding whether to take a version |
| `RESERVED` | **Tombstones: a retired name stays dead.** In the `skip-allowlist` dialect, and the fourth hygiene rule is **inverted** — a reserved path that exists in the tree is the failure. buf's `reserved` and k8s's `+k8s:deprecated` are *not* the same mechanism (a wire tombstone vs a lifecycle marker on a still-present field); kit has no encoding, so only the shared weaker half transfers. See `DECISIONS.md` (MD27). | kit's gate; read before reintroducing any path |
| `LICENSE` | **kit's own grant: MIT.** The whole grant — kit has no package manifest, so there is no metadata field that could disagree with the file. A gate check reads it *and* every root manifest that can carry a licence field, because a licence is only unambiguous when exactly one place can declare one. | Anyone reading or vendoring kit |

## Secrets — two scanners, two questions

Neither of these substitutes for the other, and the second one has no
off-the-shelf implementation at all.

**`secrets` (no opt-in).** gitleaks over the **full history** of the adopting
repo, with `--redact`. It answers *was a credential committed*.

Why gitleaks and not trufflehog: trufflehog is **AGPL-3.0**, which is a
licensing decision with teeth for a product that sells code, and it is the only
candidate that verifies live credentials against the issuer's API — exactly the
wrong behaviour for a fleet whose CI has network access. gitleaks is MIT, a
single static binary, needs no network, and `--redact` is mandatory so CI never
prints the secret it just found.

It is the one job in the workflow with **no opt-in**, and that is deliberate: an
opt-in security control is not a control. `continue-on-error` is the one setting
that would turn it into a report, and `tests/validate.sh` fails if it appears.

> **Adopting this may make your first build red.** If your repository has a
> credential anywhere in its history, the scanner will find it. That is the
> scanner working. **Rotate the credential first** — a scan finding a secret is
> not a plan for it. Then, if it was a false positive, add an entry to your
> `.gitleaks.toml` with a `description` explaining why. Do not add
> `continue-on-error`, and do not add a `.gitleaksignore`: both fail the gate.

**`zizmor` (opt-in).** The GitHub Actions security audit, on your own workflows.
It answers *what is the shape of your CI*. Off by default because it reads
workflows kit did not write, and a red build for someone else's finding is not a
fair day one.

**`templates/secrets/`** answers the question neither of them does: *does a
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
Nothing in the fleet made that happen, and the reporter that now measures it is
`tests/staleness.py --scope templates`.

```sh
tests/staleness.py --repos-dir .. --scope templates
```

A **pin** is a record that a copy is deliberately not kit's bytes. Without one,
a divergence is not "fine", it is **unproven** — and an unproven cell is a
finding, the same way an undeclared `core` pin is. `templates/parity-allowlist`
is the file those records live in, and it uses the tier skip-allowlist's format
exactly:

```
<verb> <repo> <artefact-id> reason="…" owner=… since=YYYY-MM-DD until=YYYY-MM-DD
```

with three verbs — `diverged` (held, and different), `absent` (kit ships it,
the service holds nothing) and `unknown` (kit cannot say what the service would
have copied). **The verb is checked against what the reporter measured**, so an
entry cannot excuse a different finding than the one that exists.

Two directions, and the tier allowlist only needs one:

- **an entry that matches nothing is a failure** — ESLint's
  `reportUnusedDisableDirectives` shape. The artefact is now byte-identical, or
  the entry names an artefact kit does not ship, or a repository that is gone.
- **an unpinned cell is a failure** — the reverse. `pantry`'s
  `ci.reusable.yml` is the example that pays for the rule: it is a real design
  decision (its CI is a workspace-drift job over thirteen repositories, not a
  per-language service build) and it is invisible to every reader of that
  repository until it is written down somewhere.

**A copy is never inferred from content.** There is no similarity threshold and
no search for a file that hashes to kit's: a copy is `current` when the bytes
at the declared path are equal and the path is a real file in the service's own
tree, and at no other time. A symlink to an identical file is `unknown`, not
`current` — the bytes are right today and the arrangement is a bet that the
target never moves. `tests/self_test.sh` breakage 37 is that rule written as
the patch someone would write to relax it, and it has to be tried to be
believed.

Two things worth knowing before you read any of it, because both were found by
running the tools rather than by reading about them:

- **`includePaths` nested under `git:` is silently ignored.** vendir drops keys
  its schema does not declare, the filter ends up empty, and `vendir sync`
  vendors the *entire* upstream repository while exiting **0**. It reads
  correctly. `tests/validate.sh` has a check for exactly this shape and
  `self_test.sh` breaks it on purpose.
- **`renovate.json5` uses `constraints.vendir`, not `installTools`.** The first is
  what the vendir manager actually reads; the second is scoped to
  `postUpgradeTasks` and is *also* wrong in shape — it is an object keyed by tool
  name, not an array. Both checked in Renovate's source; see the comments in the
  file.

The change classifier and the staleness reporter are the two things here that
are programs rather than configuration, and they are the reason the standard is
enforceable. Both are standard-library only and neither is imported by anything.
Their conventions are in [`AGENTS.md`](AGENTS.md#the-classifier-fails-closed-and-that-is-a-rule-about-code).

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

So the rule is enforced rather than written down, in
[`tests/gate_declaration_check.py`](tests/gate_declaration_check.py):

```sh
python3 tests/gate_declaration_check.py ../cafaye
```

It looks for three shapes — an escape token in a `proof[].match`, a `run:` block
scalar whose whole body is the declared argv, and a comment citing a checker
term while claiming a `run:` spelling the checker cannot see — and it runs as
part of `bash tests/validate.sh` against whatever fleet is found beside the
repository. It does **not** prescribe a `run:` spelling: that would be a second
copy of a decision `core` owns, and `courier`'s block scalar is correct for
three real reasons.

Its first version was a keyword scan and it reported 4 repositories and 24
findings against the real fleet, nearly all false — including `core/gate.yml`
for the sentence "That is MD12's collect-then-run machinery", because `D12` is a
substring of `MD12`. All three rules are structural as a result. A check that
fires on correct work teaches the reader to ignore it, and it had taught on the
first repository scanned.

The one that reads `core/`'s consumers is `--scope core`, and it is documented in
[`core/README.md`](core/README.md). The one that reads **this** repository's
consumers is `--scope templates`, and the difference is not cosmetic: a pin can
be stale and a file can be **gone**, and `templates/` has drifted far enough
that gone is the commonest answer. The seven stacks above are the worked
example — the fleet holds `docker-compose.yml` in six services and none of the
other eleven files each one needs, which is the finding a drift-only reporter
has no word for.

## The account-scope contract, across the whole fleet

Six services declare their account-scoped surface in an `account_scope.yml`.
`core/harness/account_scope_check.py` is what decides whether a declaration
still describes the code — and at the time this was written **not one of the
six ran it against itself**. The only references in the fleet were three
declarations *mentioning* the tool, `core`'s CI running its own self-test over
its own fixtures, and that self-test's script. So the contract was continuous
in nobody's build: a service could add a route, widen a declaration, or delete
`account_scope.yml` entirely and its own gate stayed green. `DEBT.md` D18's
shape, one level up from where D18 had been looking.

So the check that spans services lives here, in the repository that renders
them:

```sh
# the fleet beside this repository
python3 tests/account_scope_fleet_check.py

# any fleet, and the flag a reader needs to re-derive a number in the report
# without editing a file
python3 tests/account_scope_fleet_check.py --repos-dir /path/to/fleet --baseline
python3 tests/account_scope_fleet_check.py --only pantry
```

`--baseline` applies **no** record and reports the raw verdict for every
repository, so a baseline is a measurement rather than something to be believed.
The default applies
[`tests/account_scope_fleet_ratchet.yml`](tests/account_scope_fleet_ratchet.yml),
which is a **row per in-scope repository** — not a list of suppressed
identifiers. A repository with no row is red; a row whose numbers no longer match
is red **in both directions**, so a repository that got better and whose row
nobody retired is as red as one that got worse.

Five rules, and one of them is a refusal:

| rule | what it catches |
| --- | --- |
| **continuity** | a repository that declares a surface and stops declaring one. Derived from `git cat-file -e HEAD:account_scope.yml`, because the checker alone reads a deleted declaration as one that was never written. |
| **entry** | an in-scope repository that has never declared, unless it is on `exempt:` with a `condition:` |
| **propagation** | every `fail` finding core's checker reports, with its exit code and its four counts, per repository |
| **exactness** | any difference from the recorded state, in either direction |
| **blindness** | a run that cannot distinguish "this repository is clean" from "this runner read nothing" |

The last row is the one worth reading. A checker that attributed no entry point
to any registration exits 0 over an empty enumeration, which is byte-identical
to a checker pointed at an empty directory — and **a pattern that matches
nothing is not a pass, it is an error**, a rule this repository has already been
bitten by. `pantry` is the live instance: its routes are generated as
`r.Get(options.BaseURL+"/v1/…"`, the chi recogniser drops them, and its own
declaration says `surface.minimum: 0`, which is the honest way to write down a
surface nobody can read. The runner reports that as `blind.surface-blind` rather
than as a green.

**It runs in two places, because one would have been the defect again.**
`tests/validate.sh` invokes it against the fleet beside the repository, with a
**reported SKIP** when there is none — and a CI runner has none, so a second
check asserts the wiring itself runs everywhere, and a job in
`.github/workflows/ci.yml` assembles a fleet of the nine and runs the contract
for real. That job has no `continue-on-error`: a repository renamed or made
private turns it red, which is the state a reader can act on.

**Which repositories are in scope is read, not written down.**
[`tests/account_scope_fleet_scope.yml`](tests/account_scope_fleet_scope.yml) is
a fingerprinted copy of `moon/MVP-SCOPE.md`'s in-scope table, and it exists only
because a CI runner that cloned nine repositories has no `moon` checkout. When
the directive **is** readable — every developer's machine, and every run of
`bash tests/validate.sh` — the two are compared and a disagreement is exit 2, so
the directive wins and a stale copy is a red build rather than a quietly narrowed
watch.

**The baseline is measured against a frozen copy of the fleet**, because three
sessions share this machine and two of them work in it:
[`reports/account-scope-contract-01/snapshot.sh`](reports/account-scope-contract-01/snapshot.sh)
unpacks all nine at named commits with `git archive` and gives each copy a git
repository of its own, so the numbers in
`REPORT-kit-account-scope-contract-01.md` name the tree they were taken from.

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
`tests/fleet_check.py` reads it to decide whether your repository runs a pin at
all.

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
are already declared in the compose file. `tests/fleet_check.py` fails a service
that sets any of the three, for the reasons above.

One thing about the `.env` line: `docker-entrypoint-initdb.d` runs **once per
volume**, so after adding your name you need `bin/dev down -v && bin/dev up`.
An existing volume keeps the list it was provisioned with.

It is a **stack, fetched from a pinned ref**, not a template you copy. Every
published port is `${KIT_*:default}` inside kit's claimed block, every image is
pinned to an exact tag, and every service has a healthcheck so `up --wait` can
mean something. A service joins by writing an **override** file — its own image,
its own port, its own service entry — which `bin/dev` merges with the fetched
stack.

### The gate on adoption, and the adoption ceiling

`tests/fleet_check.py` reads the **sibling repositories**, not kit's own files,
because the failure this packet exists to catch is in the callers and not in the
callee. Four claims, one check each:

| claim | the defect it catches |
|---|---|
| no stale copy | the service runs its own `postgres` rather than joining kit's |
| no weakened boundary | the service re-points the collector's config mount — the redaction allowlist, derived from core — or overrides `POSTGRES_*` on the shared cluster |
| no dead config | an `otel-collector.yml` that nothing mounts, so editing it changes nothing |
| every ref pinned | a `kit.ref` holding a branch |

**Measured against the current fleet: six repositories declare local
infrastructure, 13 findings.** Five carry their own copy of the shared stack
(billing, courier, darkroom, identity, muse), six have no `kit.ref` at all, and
two publish a port on a service kit already ships. This is the same shape as D4:
three repositories not spelling their gate the same way is invisible to any check
that reads only one of them, so kit's gate reads all of them.

#### The ceiling, and why it is not a softening

| | a repository **with** a `kit.ref` | a repository **without** one |
|---|---|---|
| stale copy · weakened boundary · dead config · published port · bad pin | **FAIL** | **WARN**, naming the adoption path |

Same four checks, same predicates, same messages. **The strictness moves to
where adoption exists; it does not disappear.** The judgement is about **who owns
the debt**, not about how bad it is: a repository that has adopted and still runs
its own `postgres:17-alpine` has made a promise it is breaking, and one that has
adopted nothing has not made a promise yet.

All six repositories in scope are currently **warnings and no failures**, because
not one of them has adopted. That is a deliberate, temporary, named state and it
is a *wave*, not a discount: commit the one line and your own findings become
failures, with no change to this repository and no re-review. Because the FAIL
side is therefore unexercised by any real repository today, it is proved against
a fixture instead — self-test breakages 59 and 60 run the identical mutation
once unadopted (must stay green, must name the finding) and once adopted (must
go red).

```sh
git -C ../kit rev-parse HEAD > kit.ref    # the only thing that decides which kit you run
```

**A warning is a debt with a name.** A gate that has been red for thirteen
findings no repository has agreed to fix stops being read within one release, and
a gate nobody reads catches nothing — which is how the state this packet exists to
remove survived a full round of CI the first time.

The check is keyed on the **image**, not the service name, and reads the set of
images out of kit's own compose file rather than a hand-kept list. Five of the six
copies name their database `db` rather than `postgres`, so a name-keyed check would
report the fleet clean while five copies of the platform stood right there — and a
list that must be edited every time kit adds a service is a list that gets skipped.

A clone of kit with no siblings **skips loudly**. "No fleet was found" is not "the
fleet is clean", and a gate that reports the second when it means the first is a
gate that gets muted.

`bin/dev` is idempotent — run it twice and nothing changes — and it fails loudly
rather than half-starting: if the stack does not become healthy it prints what is
unhealthy and its logs, and stops *before* migrating, so a failed `up` cannot
leave a half-migrated database behind.

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

**kit itself is MIT.** See [LICENSE](LICENSE), which is the whole grant: kit is
configuration and documentation, has no package manifest in any ecosystem, and
therefore has no metadata field that could disagree with the file.

That is a different question from the AGPL paragraph above, and keeping them
apart is the point. The four backing services are third-party software we
*consume*, unmodified, under their own terms. kit is cafaye's own work and is
granted MIT. A service adopting kit adopts the conventions under MIT and pulls
the four backends under AGPL-3.0, and neither obligation runs toward the other.

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

## How a service repo adopts kit

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

**Your first build may be red, and it is probably the secret scanner.** The
`secrets` job has no opt-in, and it reads the **full history** of your
repository. If a credential has ever been committed — even one you deleted in
the same PR — it will find it. That is the scanner working, and it is the reason
the scan is not diff-only: a deleted secret is still in the packfile of anyone
who cloned, and still on every fork.

In order:

1. **Treat the credential as compromised and rotate it.** A scanner finding a
   secret is not a plan for it, and nothing below is a substitute for rotating.
2. If it was a false positive, copy `.gitleaks.toml` into your repo root and add
   one `[[allowlists]]` entry with a `description` saying what is allowed and
   why. A description under 40 characters fails the check, and an entry with
   none fails harder: an allowlist that grows and is never pruned is not an
   allowlist, it is a deferred disclosure.
   - **Delete the entry kit's file already carries.** kit's own allowlist has one
     entry, for a JWT-shaped test fixture at `tests/deploy_test.sh` — a path your
     repository does not have. An allowlist that matches nothing excuses nothing,
     so leaving it cannot weaken your scan, but it is a justification written about
     somebody else's file, and that is the thing to not copy. Write yours for what
     *your* finding actually is.
   - Scope it as narrowly as gitleaks allows: `targetRules` to name the one rule,
     `paths` to name the one file, and `condition = "AND"` **written out** —
     gitleaks' default is `OR`, so an entry with two criteria silently becomes a
     union the day a second one is added.
3. **Never** add `continue-on-error` to the `secrets` job, and **never** create a
   `.gitleaksignore`. Both fail `tests/validate.sh`, and both are the two ways a
   security job becomes a report while the badge stays green.

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
`typecheck`, `bun test`. It exists because `guard` was hand-rolling an entire
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
- [ ] `.github/workflows/publish.yml` calls `cafaye/kit/.github/workflows/image.reusable.yml@master`
      with `push: true`, and the workflow grants `packages: write`. **Without it
      nothing builds the image `config/deploy.yml` deploys**, and CI stays green
      the whole time — a green CI and an unbuilt image are not in tension, they
      are just both true.
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
- [ ] **The `secrets` job ran, and anything it found has been ROTATED**
- [ ] `.gitleaks.toml` copied to your repo root if you need an allowlist entry
- [ ] `zizmor: 'true'` set, if your own workflows are clean
- [ ] If you hold credentials: `templates/secrets/<lang>/` copied **with its suite**
- [ ] `CHANGELOG.md` has an entry
- [ ] The workflow is green on the adoption PR

## Where the lint configs run

`lint/` is 249 lines of golangci, rubocop, eslint, yamllint and hadolint
configuration, and until now it was distributed by `cp`. **No service in the fleet
had ever copied it** — the one repository that carries its own golangci config
wrote that file itself, for its own reason, and the difference matters (it is
recorded in `lint/drift-allowlist`). The three mechanisms kit ships are not
equivalent, and the adoption numbers say so:

| mechanism | live? | adoption |
|---|---|---|
| `uses: cafaye/kit/...@master` | **yes** — fetched at run time | **11/11** repos that call it |
| `cp <kit>/lint/golangci.yml ./` | **no** — a snapshot | **1/11** — and that one is `identity`, which added its own in the meantime |
| `cp <kit>/templates/... ./` | no | 1/11 (`bin/dev`), 0/11 (observability) |

Counted, not estimated: a non-worktree directory beside this one that contains a
workflow with a `uses: cafaye/kit/.github/workflows/ci.reusable.yml` line. The
eleven are `billing caf core courier darkroom docs guard identity kit muse
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
| **ESLint** | `--config=<repo>/.kit/lint/eslint.config.mjs` | Works, and **only because kit is checked out inside the repo**. Node resolves an ESM import from the *config file's* directory upward; a config sitting beside the repository finds no `@eslint/js` and the run dies with `ERR_MODULE_NOT_FOUND` — a red build that has linted nothing. |
| **yamllint** | `yamllint -c <repo>/.kit/lint/yamllint.yml --strict` | The one that behaves the way the other three are assumed to. `--strict` is load-bearing: both of kit's retuned rules are warnings by default, so without it `yamllint -c kit's` and plain `yamllint` agree on the exit code and disagree on everything a human reads. |

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
  as it did — so three self-test breakages cover it (deleted, shortened, moved).
- If a flag is wanted often enough to be common, it belongs in `lint/` and every
  service gets it for free.

A repo that wants a stricter *rule* rather than a stricter *flag* has no seam, and
that is the intended pressure: the rule belongs in kit, where nine services get
it and one written-down entry in `lint/drift-allowlist` is replaced by a change
everyone receives.

### The gate that catches a service drifting back

`lint drift` in `tests/validate.sh` reads **both** files and reports the
**difference**, linter by linter, rather than demanding the file be absent. A
service whose `.golangci.yml` agrees with kit's passes; one that disagrees is told
exactly which linters it dropped or added.

Banning the file was the first version and it is worse than the drift it prevents.
A config that matches kit's has reached the same policy by another route, and
failing it teaches the lesson that kit's config is a thing you get shouted at for
having — which is how a standard stops being adopted. `tests/self_test.sh`
breakage 31b asserts that agreeing copy **passes**, so the check cannot be
satisfied by simply deleting it.

A difference you cannot delete yet goes in `lint/drift-allowlist` with a reason,
an owner, `since` and `until`. Four rules, and the fourth is the one that earns
the other three:

1. reason, owner, `since` and `until` are all required;
2. an **expired** entry fails on the day it expires;
3. a duplicate `(repo, path, key)` fails — one of the two is dead;
4. **an entry that no longer describes a real difference fails.**

Rule 4 is modelled on ESLint's `reportUnusedDisableDirectives`. Without it an
allowlist is a ratchet that only turns one way: the repository gets fixed, the
entry stays, and within two quarters the file lists every repository the fleet has
ever had. One entry is live today — `identity`, whose `.golangci.yml` enables no
linter at all and exists only to exclude one generated file.

Rule 4 is scoped to repositories the run actually looked at, and that scoping is
the correctness of the rule rather than a softening of it: an entry naming a
repository that is not in this checkout's fleet is reported as **unverified**,
never as a pass and never as a failure. A copy of kit checked out on its own has
no fleet beside it, and a rule that reported every entry as unused there would be
red on a correct tree.

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
saying so — PyYAML, yamllint and zizmor into `.venv/`, and hadolint and gitleaks
into `tests/.bin/`. There is no prerequisite step, because a prerequisite that is
documented rather than automated is one that gets skipped by exactly the machine
you most wanted to hear from.

This bit twice. It used to exit 1 with `no python with PyYAML` because it
preferred `.venv/bin/python` and fell back to `python3`, and `.venv` is
gitignored — so **every fresh clone and every CI runner** hit it, including the
CI job this repository now runs on itself.

The binaries go in `tests/.bin/` rather than `.venv/bin/` for the same reason
one level down: `tests/self_test.sh` copies the tree thirty times per gate run —
34 breakages over 29 copies, because the six language mutants share one, plus the
unbroken-tree control's own — and a tool in a directory the copy does not carry
is re-downloaded once per copy.

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
- the `secrets` job must exist, must not be `continue-on-error`, must not be
  opt-in, and must check out with `fetch-depth: 0` — the runner default is a
  *shallow clone*, and a shallow scan cannot see a deleted secret
- no workflow may declare `pull_request_target`, `workflow_run` or
  `issue_comment`, read off the **parsed trigger keys** so the comment explaining
  why is not itself a violation
- `.gitleaks.toml` must extend gitleaks' defaults rather than redefine rules, and
  every `[[allowlists]]` entry must carry a `description` of at least 40
  characters. An entry with no reason is a deferred disclosure
- no `.gitleaksignore` may exist — the allowlist is the committed config
- **the scanner's behaviour, executed**: over a throwaway git repository
  containing a detectable credential, the scan must find it, must name the rule
  that fired, must not print the value, and must still find it after the file is
  deleted. This is a behavioural check, not a `grep`, because a `grep
  -- --redact` is satisfied by the comment that explains why the flag is
  mandatory — and `self_test` breakage 43 proved that
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
output. A proof nobody can see is a proof nobody ran — the same argument the
self_test phase makes, applied to the harness rather than to the gate.

**self_test** — `tests/self_test.sh` breaks a throwaway copy of this tree
**sixty-seven** ways: sixty-five assert the gate goes red, and two assert it
stays **green** while naming what they said — 23b a SKIP that replaced a red, and
59 a FINDING that did not yet fail the build. A further **green control** (31b)
asserts a service config that agrees with kit's is *not* a failure. Fourteen
breakages are for the static checks; one is a semantic mutation of each of the
six language implementations, so **every suite is proven able to fail** rather
than assumed to. A skip fails the run — a self_test that skips half its proofs and
exits 0 is the "0 passed, 14 ignored" shape that verifies nothing. Forty-seven of
the static ones go further and assert that one *named* check reported `FAIL`, so
the check written for a given defect is proven still load-bearing rather than
being one of fifty checks that could have gone red for an unrelated reason.

**The harness shards, and the shard partition is itself checked.**
`KIT_SELF_TEST_SHARD=i/n` runs only the breakages congruent to `i`, with `i` in
`1..n`. `tests/shard_test.sh` proves the property rather than describing it: it
evaluates the real `_shard_claims` out of `tests/self_test.sh` — a second copy of
the modulo would be a second thing to be wrong — and asserts that the `n` shards
partition the suite **exactly once**, that no shard is empty (shard `n/n` named
first, because that is the one an off-by-one empties), and that a shard which
*cannot* be placed is **refused at the door** with both numbers rather than run.

It is in the gate because the harness is the one component no other recipe can
reach: every other breakage proves the *gate* goes red, and the gate is not what
shards. Breakages **94 and 95** are the only two that mutate `self_test.sh`
itself, and they are why the check is load-bearing rather than decorative.

**`n` is bounded by the suite's highest breakage NUMBER, not its count.** The
labels are sparse — they run `1..62` and `68..93`, with `63..67` left by a
renumbering — so the largest `n` with no empty shard is **62**, and for any `n` in
`64..93` shard 64 asks for a residue class no breakage is in. That case is
reported as a `FAIL` by the summary rather than a `PASS`, which is the whole
point: an empty shard must never be indistinguishable from a shard the arithmetic
emptied by mistake.

Breakage 19 is the allowlist one: an entry naming a test that does not exist,
well-formed in every other respect. It is the rule most able to be decorative —a hygiene rule in a data file is exactly the shape of a check nobody has ever
seen fail.

Breakage 23b is the other end of that problem. A check that converts a red into a
skip can be load-bearing precisely by *not* going red, so "the gate went red"
cannot express it and "the gate went green" is satisfied just as well by a check
that was deleted outright. It asserts both halves: exit 0, *and* the named skip
in the output.

Breakages 24-26 are the three shapes a **workaround for a fixed core defect**
takes: a gate step written as a `run:` block scalar with a comment saying the
one-liner is invisible (D12, core `63fd319`), the same comment on an otherwise
correct step, and a proof pattern carrying escape tolerance (D13, core
`c63af27`). They mutate a *synthetic fleet* built in the work directory, since
kit is one repository and the fleet is fifteen — which also makes the control
this file's positive case for the check.

Breakages 61-62 are the licence, in the two ways a grant stops being
unambiguous: `LICENSE` deleted, and a root manifest declaring a licence the file
contradicts. The second is the one that makes the check a check — see
[`## License`](#license).

Two defects in this harness were found by that packet rather than by a reader.

`expect_green_check` asserted on the gate's output with `printf … | grep -qF`,
which reads a **match** as a non-match once the output overflows the 64K pipe
buffer: `grep -q` closes the pipe at the first match, `printf` dies of SIGPIPE,
and `set -o pipefail` promotes that 141 to the pipeline's status. It had been
latent because no check had printed enough to get there, and it reported
breakage 59 — the adoption ceiling — red when that proof had in fact passed.
`expect_red_check` had already been repaired for the identical bug and said so
in a long comment **in the same file**, which is the shape worth naming: three
correct explanations of a defect do not stop the fourth copy of it. All three
assertion helpers now match the captured variable through one `contains`
helper. The alternative fix — making the new check quieter — was worse twice
over: it contradicts `check`'s documented behaviour, and the threshold it hides
behind is a property of the pipe buffer, so it moves with the machine.

And `expect_red_check` had no verdict for a gate that exited non-zero reporting
**no finding at all**, so it fell into "red, but not via the named check" and
blamed a healthy check for a machine that was too busy — `validate.sh` exits 1
on a FAIL *and* exits 1 from bootstrap when it cannot install its dependencies,
and the second never reaches a check. There is now a third verdict, `SKIP`,
counted separately from a missing toolchain because the two need different
responses, and still fatal: a proof nobody ran is not a proof. It widens the
excuse by exactly the case where the gate said nothing, and no further.

Any `FAIL` exits 1. A `SKIP` is always reported in the summary, never hidden.
PyYAML, yamllint, zizmor, hadolint and gitleaks are required and are
**bootstrapped by the gate itself**; the seven language toolchains and
`shellcheck` run when present.

**Four counts, because they are four different claims.** `PASS` and `FAIL` are
about the tree. `SKIP` is about the **environment** — no docker, no toolchain,
nothing ran. **`BOUND` is about the run**: the tier started, this machine was too
busy to finish it, and the claim it exists to prove is therefore *unexercised*.
The four heavy tiers — three docker stacks, and the self-test, which is *n*
whole gates in sequence — carry a time bound for exactly this reason. A gate
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

MIT. See [LICENSE](LICENSE).

kit is configuration and documentation — no runtime code, no library, nothing
imported by anything — so the `LICENSE` file is the entire grant. There is no
`Cargo.toml`, `package.json`, `pyproject.toml` or gemspec here, and therefore no
metadata field that could disagree with the file. That is the same shape as Go
modules and the reason the file is the grant there too.

That last sentence is a **claim about the tree**, so a check holds it: the gate
reads the grant by MIT's own sentences rather than by the string `MIT`, and then
inspects every manifest at the repository root that can carry a licence field,
failing on any that declares something else. A licence is only unambiguous when
exactly one place in a repository can declare one — a `package.json` appears, it
carries `"license": "AGPL-3.0-only"` copied out of a service, and now a
compliance tool and a reader are reading different files. The check does **not**
ban the manifest; it requires it to agree, which is the difference between a rule
and a ratchet.

See [kit's own licence](#kits-own-licence) for why this is a separate question
from the AGPL-3.0 backends kit ships unmodified.
