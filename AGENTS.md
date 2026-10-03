# AGENTS.md — kit

> Conventions for this repo. Read before changing anything here. If a rule is
> not written here, it is not a rule.

## What this repo is

- **Name:** `kit` (`github.com/cafaye/kit`)
- **Purpose:** shared CI, lint, and toolchain conventions that every cafaye
  service repo adopts.
- **Contains:** configuration and documentation only. No runtime code, no
  library, no build step, no dependencies.
- **Not:** a CLI, a package, or a service. Nothing here is imported by anything.

## Layout

```
kit/
├── README.md                             # what kit is, how a repo adopts it
├── LICENSE                               # MIT. The whole grant, and nothing can disagree
├── DECISIONS.md                          # the trades this repo has NOT made
├── VERSION                               # the version, and the ONLY place it is written
├── RESERVED                              # tombstones: a retired name stays dead
├── .gitleaks.toml                        # the allowlist, and nothing else
├── .github/
│   ├── workflows/
│   │   ├── ci.reusable.yml               # the workflow six repos call
│   │   └── ci.yml                        # kit calling its own workflow
│   └── zizmor.yml                        # reasoned baselines, one per finding
├── lint/                                 # configs services RUN, not copy
│   ├── yamllint.yml  golangci.yml
│   ├── rubocop.yml   eslint.config.mjs
│   ├── drift-allowlist                   # owned service configs that differ
│   └── hadolint.yaml                      # argues the one rule it ignores
├── docker/                               # Dockerfile.<lang> templates
├── core/                                 # the cafaye/core fan-out standard
│   ├── tier/skip-allowlist               # one file for the fleet; four hygiene rules
│   ├── tier/README.md                    # the format, the rules, and the limits
│   ├── parity-allowlist                  # WHY each service's copy is not kit's bytes
│   ├── secrets/                          # runtime credential-leak canary
│   │   ├── README.md                       # the CONTRACT, language-neutral
│   │   └── go/                            # the Go adapter + its five vectors
│   ├── mise.toml                         # toolchain pin template
│   └── AGENTS.md                         # skeleton for a service repo
└── tests/
    ├── validate.sh                       # THE gate
    ├── self_test.sh                      # proves the gate can go red
    ├── lint_test.sh                      # the linters RUN, against fixtures
    ├── isolation_test.sh                 # the cluster, RUN; A cannot reach B's database
    ├── tenancy_test.sh                   # the account boundary, RUN; and its FORCE control
    ├── gitleaks_gate.sh                  # the one secret scan, for CI and here
    ├── zizmor_gate.sh                    # the one zizmor split, ditto
    ├── bootstrap.sh                      # the gate installs its own tools
    ├── classify.py  rules.json           # the change classifier, failing closed
    ├── staleness.py  artifacts.json      # the staleness reporter, and WHAT it measures
    ├── core_fanout_check.py              # structural checks on core/vendir, core/renovate
    ├── gate_declaration_check.py         # no adopter carries a D12/D13 workaround
    └── self_test.sh                      # every check, broken once, asserted red

templates/ holds everything a service adopts, and it is split by **how a thing
reaches a service**, not by subject:

- `templates/compose/` — **FETCHED**, never copied. One file for every service,
  pinned by `kit.ref`.
- `templates/bin/`, `templates/otel/`, `templates/tier/`,
  `templates/secrets/`, `templates/database/` — **COPIED** into the service, per
  language.
- `templates/compose/postgres/` — the cluster image and its init script, and the
  only place a database, a role or an extension is created. A **role** is now
  plural: `<service>` (the owner, which runs migrations) and `<service>_app` (the
  LOGIN the application uses, which owns nothing), granted to each other in ONE
  direction only.

**One cluster, one database per service, two roles per service.** The DATABASE is
the isolation boundary rather than the machine, and there is **no pooler** — see
`templates/database/README.md` for the argument and `DECISIONS.md` (MD21) for the
measurements behind it.

**There are TWO boundaries, and the second one is the one this packet was written
about.** The database boundary stops `courier` reading `billing`'s rows. It says
nothing about two accounts of the *same* service, and across all nine
account-scoped services that boundary was enforced entirely by hand-written
`WHERE account_id = ?` in six languages: **zero `ROW LEVEL SECURITY`, zero
`CREATE POLICY`, zero non-owner login roles, and no service declaring a
`tenancy.yml`.** `templates/database/tenancy/` is the enforcement:

| | what stops it | how |
|---|---|---|
| service A reading service B | the database | one database per service, `REVOKE … FROM PUBLIC` |
| account 1 reading account 2 | **row-level security, FORCED** | `cafaye.protect_table`, a `<service>_app` login role that owns nothing, and `cafaye.begin_account/1` once per request |

**`FORCE ROW LEVEL SECURITY` is not optional and nothing else in the tree will
tell you so.** Postgres exempts a table's OWNER from its own policies, and every
service runs its migrations as its own role. Measured on this kit, a protected
three-row table read as the owner carrying another tenant's identity: **1 row
with FORCE, 3 without.** It is not in Supabase's guide and **no lint in this
fleet checked for it** before that directory existed.
`tests/tenancy_test.sh` deletes the statement and requires the OWNER half of the
assertion set to go red while the LOGIN half stays green — and that asymmetry is
the point: an isolation suite written only against the application role passes on
a substrate with no FORCE at all.

**And the assertion set is THREE denials and one allowance, never one.** A request
with **no** identity reads zero rows; a request carrying **another tenant's valid**
identity reads zero rows; a request carrying **its own** identity reads its own
rows, and not the other tenant's. The first is satisfied by a table with no policy
at all — which is the bug — and the third by a policy that permits everything.
`templates/database/<lang>/tenancy_test.*` is that set, in each of the six
languages, and each compares the assertion NAMES it got back against
`templates/database/tenancy/assertions.txt` **in both directions**: a count would
be satisfiable by 24 of the wrong 24.

**A service's own `where account_id = ?` stays.** RLS is defence in depth, not a
licence to delete the predicate — the predicate is what makes the query indexable,
it is what catches a `with check` written against the wrong column, and
`core`'s `tenant-isolation.schema.json` still requires it. See `DECISIONS.md`
(MD23).

Flat on purpose. `grep -r` finds everything; there is no plugin system to
learn.

The reusable workflow is at `.github/workflows/ci.reusable.yml` and nowhere
else. That is not a style choice: GitHub documents that **subdirectories of the
workflows directory are not supported**, so a `uses:` line reading
`cafaye/kit/workflows/ci.reusable.yml@master` resolves to nothing, and every
caller who copied it has a red build. A repo that holds the file in a convenient
place and documents a `uses:` string is a repo whose documentation and layout
have silently disagreed — which is the class of defect the `callable path`
check in `tests/validate.sh` exists to catch. The same reasoning forbids a
second copy: one file, and if you ever mirror it, the gate must fail when the
copies differ.

**"One file" means one copy PER STANDARD, and kit now has two.** Besides
`ci.reusable.yml` there is `.github/workflows/image.reusable.yml`, which builds
a service's image and publishes it to ghcr.io. The `REUSABLE_WORKFLOWS` variable
in `tests/validate.sh` is the list of what callers may reach; the gate fails on a
file declaring `workflow_call` that is not on it, and separately on a file that
duplicates one that is. Both branches are proved by breakages 78 and 79, because
a check widened to accommodate a second standard is exactly the kind of thing
that ends up widened into uselessness.

A caller writes exactly this, and nothing else:

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
      language: go
```

And the service that also needs a deployable artifact calls the second one:

```yaml
---
name: publish
on:
  push:
    branches: [master]
permissions:
  # The caller grants it; a reusable workflow cannot grant itself a permission.
  contents: read
  packages: write
jobs:
  image:
    uses: cafaye/kit/.github/workflows/image.reusable.yml@master
    with:
      push: true
```

`kit` itself calls the CI workflow with the local form instead, which is the
whole point of having the file here at all:

```yaml
    uses: ./.github/workflows/ci.reusable.yml
    with:
      language: none
```

## The gate

**`bash tests/validate.sh` must be green before any commit.** It is the whole
test suite — kit has no other tests, because kit has no code.

```sh
bash tests/validate.sh
```

**`--no-live` skips only the observability LIVE tier** — the three docker stacks
the collector platform is proven by — and turns each of them into a `SKIP` naming
the flag. `--no-observability` skips the whole phase, including the two cluster
tiers. They are separate flags because they are separate claims: "the collector
works" and "a service cannot read another service's rows", measured at 128.8s and
23.9s respectively on this machine.

**The one thing that sets `--no-live` is `tests/self_test.sh`**, because its 104
whole gates each used to bring up three docker stacks to learn one fact about
one named check. Measured: **0 of the 107 recipe invocations name a live tier**,
and only ONE recipe reached it at all — breakage 23b, whose helper is the one
that cannot be `--only`-filtered, because the string it must find is a SKIP's
verdict text rather than a check's label. Every other recipe is either
`--static-only` or narrowed to the single check it asserts, and `bounded_check`
honours `--only`. So contention, not a defect, is what made 23b red at position
23 of 104 in a full suite run while it was green standalone — **reported, not
reproduced**: 23b's gate run is green on this machine, standalone and inside a
full suite run, and the claim being made here is about the *exposure* (one whole
gate, half of it docker, asserting nothing about any of it) rather than about a
failure someone watched.

**A skip that cannot be seen is a silent pass**, so the opt-out is three printed
`SKIP` rows, three in the skip tally, and a summary line naming the claims the
run did not exercise. A patch that deleted the three tiers outright would satisfy
23b's exit-status assertion and fail its name-the-skip one; that asymmetry is the
whole reason this is a `report SKIP` and not an absence. A check derives the live
set from the gate's own `live_check` calls and fails if any recipe names one, if
a second `bash tests/validate.sh` spawn appears outside `kit_child_gate`, or if
that spawn stops carrying `KIT_NO_LIVE=1`. See `live_check` in
`tests/validate.sh`, `kit_child_gate` in `tests/self_test.sh`, and `DECISIONS.md`
(MD30).

**One command, on a clean clone, is the whole procedure.** The gate installs its
own dependencies into the gitignored `.venv/` on first run and prints a `note:`
line saying so. There is no prerequisite step, and a prerequisite step that is
documented rather than automated is a prerequisite that gets skipped by exactly
the machine you most wanted to hear from — a CI runner, or anyone who cloned
without reading this file.

That was the second time this bit. It used to exit 1 with `no python with
PyYAML` because it preferred `.venv/bin/python`, fell back to `python3`, and
`.venv` is gitignored, so **every fresh clone and every CI runner** hit it.

Six phases, and all six must pass:

- **static** — every artifact parses, and the strictness decisions are still
  what we wrote them down to be. A parse is the weakest check; the rest are
  semantic: the collector's redaction allowlist **derived from core's
  schemas** and compared both ways, redaction before every exporter, no literal
  URL, every `${env:...}` the collector reads actually passed into the
  container, every published port a `${KIT_*:default}` inside kit's claimed
  15000-15999 block, telemetry in nobody's readiness path, every language with
  all four artifacts, and every language with a **declared tier** plus a
  documented collector. The skip allowlist's four hygiene rules are enforced
  here too, and **an entry matching nothing is a failure** — modelled on
  ESLint's `reportUnusedDisableDirectives`, because without that rule an
  allowlist is a ratchet that only turns one way.
  Plus the secret scanner: the allowlist is an allowlist and nothing else, every
  entry has a reason, no `.gitleaksignore` exists, the scan redacts and reads
  full history, no workflow declares a dangerous trigger, and the `secrets` job
  is neither advisory nor opt-in.
- **telemetry** — the six W3C traceparent suites are **executed**, one per
  language, and the canary harness is **executed** with all five vectors, each
  printing its own red proof. Stdlib only and offline on purpose. If they ever
  need the network, a template has grown a dependency and kit has stopped being
  config-only.
- **self_test** — **thirty-four breakages** of a throwaway copy, asserting the
  gate goes red each time. Six of them are a semantic mutation of one language
  each, so **every suite is proven able to fail** rather than assumed to.
  **Twenty-one** assert that one *named* check — or, for two of them, one
  *named* proof script — reported the failure, so a check written for a
  specific defect is proven still load-bearing. The count is derived by counting
  the recipe invocations, never written down — the same expression
  `validate.sh` uses for its own label, so the two cannot disagree.

## Secrets

**`bash tests/validate.sh` scans this repository's full history, and so does
`bash tests/gitleaks_gate.sh`.** They are the same script, because they are the
same scan — a scanner whose CI invocation and its local invocation have drifted
is two scanners, and the one that goes red is whichever nobody runs.

Four things about it that are not negotiable, and each has a check that fails
without them:

- **Full history, not the diff.** A secret committed and deleted in one PR is
  still in the history and still on every fork. The default checkout is a
  *shallow clone*; `fetch-depth: 0` is in the `secrets` job for that reason.
- **`--redact`, unconditionally.** A CI log is a place secrets go to be read. The
  scanner finding a secret must never be why the secret is printed. There is no
  flag to turn it off, and `self_test` breakage 43 removes it and proves the
  gate notices.
- **The allowlist is `.gitleaks.toml` and nothing else.** No `-i` flags, no
  `.gitleaksignore`, and every `[[allowlists]]` entry carries a `description` of
  at least 40 characters. `extend.useDefault = true` means the rules stay
  gitleaks'; a repo that redefines a rule has taken responsibility for the regex.
- **No `pull_request_target`, anywhere.** It runs with the base repository's
  secrets and a writable token on a *fork's* code. The scanner is the job that
  most invites "just pull the base branch in so the scan sees the real history",
  and that edit is how a secret scanner becomes the way secrets are taken.

**`DECISIONS.md` records a trade this repository has NOT made.** zizmor's
`unpinned-uses` fires thirty-three times and is **not** baselined: it is counted
and printed on every run, and `tests/validate.sh` fails if anyone adds it to
`.github/zizmor.yml`. A baseline there would be making the trade invisibly, in a
file that looks like routine configuration. If you add *any* zizmor ignore
entry, it needs a reason in a comment beside it, and the gate checks.

**`templates/secrets/` is the other half, and it is not gitleaks.** gitleaks
answers "was a secret committed". Nothing off the shelf answers "does a secret
leave the process while the tests run" — gosec's `credentials.Match` has no
`*ast.CallExpr` case, Bandit matches `ast.Constant` only, Brakeman's check is
off by default, and of 268 Semgrep taint rules zero intersect CWE-532. So the
canary harness plants a fake credential and sweeps for it in five vectors. The
contract is in `templates/secrets/README.md`; the Go adapter is in
`templates/secrets/go/`.

**The canary is assembled, never written out, and that is checked.** A committed
`cafaye_canary_…` literal is a credential-shaped string in a public repository,
which is what this repository's own scanner reports, and allowlisting it teaches
the next reader that allowlisting a credential is normal. Two checks enforce it:
one inside the Go suite, one over the whole tree.

**`.gitleaks.toml` now has one entry, and it is not that.** kit-16's deploy suite
proves the redactor scrubs a JWT **by shape** — a value the filter cannot know by
name, which is the only canary that can fail — so that token is committed and the
`jwt` rule fires on it. The entry is scoped to `targetRules = ["jwt"]` **and**
`paths = ['''^tests/deploy_test\.sh$''']`, measured in both directions: a
`generic-api-key` in that same file and a `jwt` in a different file are both still
reported. The distinguishing property is not the scoping, it is that the string is
a **fixture whose name says so** (`JWT_CANARY`, and its own comment says a value
the redactor cannot know by name is half the test) rather than a credential-shaped
blob wearing a descriptive variable name. `templates/secrets/`'s canary does not
have that option: a redactor can be taught nothing and still be defeated by a
string it does not recognise, but a leaked credential does not become safe because
a test asserts on it. **The rule stays: assemble the canary, do not commit it.**

- **observability** — the claims that are worth nothing unexercised: a canary
  secret in ten leak shapes reaches no exporter (and the allowed data survives),
  a service starts, serves and reports healthy with the collector killed, the
  fetched stack runs, a service cannot reach another service's database, and
  **the account boundary holds with its `FORCE` control**. The last two need a
  real Postgres rather than a real collector, and they live in this phase for the
  same reason: a security property that nothing executes is worth nothing. They
  SKIP loudly without docker — never pass silently.
- **classifier + staleness** — the change classifier and the staleness reporter
  are *executed*, not parsed, and deliberately **outside** the `RUN_STATIC`
  guard: a check that only parsed those two files would pass on a classifier
  that waves every change through. They stay runnable when static analysis is
  skipped, because a gate that skips is not green.
- **lint** — the four linters are **executed** against a throwaway service built
  to violate exactly one rule, with kit's config, and each is paired with a
  control that must answer differently. `lint/` spent its whole life behind a
  parse check: `yaml.safe_load` on `golangci.yml`, `node --check` on the eslint
  config, and both green on files no linter had ever been pointed at. This phase
  is the one that tells a working config from a valid one, and — unlike every
  other phase — it is **fatal on a skip**, because the claim under test is "kit's
  configs work" and a run in which no linter executed has not tested it.
- **self_test** — one hundred and four breakages of a throwaway copy. One
  hundred and two assert
  the gate goes red; two assert it stays **green** while naming what it said —
  23b a SKIP, because a check that turns a red into an honest skip is
  load-bearing precisely by not going red, and 59 a FINDING, because kit-13's
  adoption ceiling is only a ceiling if its unadopted side is proved green too.
  One further GREEN control (31b) asserts a service config that AGREES with
  kit's does not fail, because a check satisfied by banning the file would train
  every service to delete one. Six are a semantic mutation of one language each,
  so **every suite is proven able to fail** rather than assumed to. Fifty-seven
  assert that one *named* check reported `FAIL`, so a check written for a specific
  defect is proven still load-bearing. Two assert that a *proof* goes red: one
  inverts the classifier's fail-closed property, and one makes the staleness
  reporter call an undeclared pin `current`. A property nobody has tried to break
  is a property nobody has tested.
  Seven are the shared-cluster work (68-74), and **73 is the one worth the
  most**: a generated config carrying `prepare: :unnamed` on a fleet with no
  pooler is slower and looks entirely correct, so the forbidden-list check is the
  only thing that will ever find it.
  - Three are the account boundary (90-92). **90 is the one worth the most of
    those**, and its mutation is `delete`, not `sed`: it removes
    `execute format('alter table %s force row level security', p_table)` from the
    substrate and nothing else. Removing the *word* would satisfy a check that
    read the file as text, because the substrate's comments quote it twice while
    explaining why it exists — which is exactly why the tenancy contract check
    strips SQL comments before looking. 91 is the one about the check rather than
    the templates: a driver that reads `isolation.sql` and stops reading
    `assertions.txt` still runs and still passes, and now asserts "no red rows"
    about an unknown number of assertions, so the check requires the read on the
    **same line** as a read call rather than a mention anywhere in the file.
  - **75 is the one worth the second-most, and it exists because a green control
    was evidencing a different check.** kit-21 turned the cluster into a *built*
    image, which renamed kit's from `postgres` to `kit-postgres` — and
    `check_stale_copy`, whose whole job is naming a service running its own copy
    of the platform, matched on that bare repository name. The two stopped
    matching, and **five repositories in the real fleet carry their own postgres
    while the check that names them reported a clean fleet, silently** (still ran,
    still printed PASS, printed no skip). Breakages 52/59/60 did not catch it
    because their fixture carries a `ports:` entry, and `check_override_surface`
    reports a published port by *service name* — a name the rename never
    touched. So 60 went red on the port half while the image half was dead.
    **75 is the same mutation with the port removed**, which leaves the image
    comparison as the only thing that can go red; it is red on the pre-fix code
    and green after, both measured. The general rule this earns: a control
    satisfiable by two different checks proves the gate can go red and says
    nothing about either.
  - **23b now asserts THREE things, and the third is the one that makes
    `--no-live` honest.** Exit 0, the interpreter skip named — which is what it
    always asserted — and a `SKIP` row that **names `--no-live`**. Deleting the
    three `bounded_check` calls satisfies the first two perfectly: the gate is
    greener than ever and still names the ruby floor, and it has proved nothing
    about the live tier. The assertion is on the ROW, not on the exit status,
    because that is the whole difference between a skip and a deletion, and 23b
    is the only helper in the suite that runs a whole unfiltered gate — so it is
    the only place the property can be watched failing.
  - **76 and 77** are the two ways a documented `bin/dev` command can stop
    existing, and they fail differently — the command gone, and the *subcommand*
    gone. 77 is the harder one: a check that only asks "is `db` dispatched" is
    green on it.
  - **96-100 are the VERSION STRING'S OWN GATE**, one property each: a MAJOR with
    no `MIGRATIONS.md` (96), a MINOR declaring `### Breaking` (97), that same
    heading parked under `## Unreleased` where no version covers it (98), a
    prerelease the derivation refuses rather than tiers (99), and a reserved name
    back in the tree (100). **96 and 97 found a defect in the check itself**: it
    read its predecessor from `git show HEAD:VERSION`, which resolves to nothing
    in a throwaway copy, so both derived `initial` and stayed green — a gate
    whose verdict depends on a `.git` beside it verifies nothing on the machines
    that consume kit the way services do. The predecessor now comes from the
    changelog section below the current one. See `DECISIONS.md` (MD26).
  - **Every version these four write is DERIVED from the copy, and that is a
    rule with a gate behind it.** They used to spell their `edit` anchors as the
    literal `1.0.0`, so `92a1127` — which correctly shipped 98's fix as a
    release, and so moved `VERSION` to `2.0.0` — killed three of them and
    reported each as `the recipe no longer applies to its copy`. That reads as a
    harness complaint; it meant *the only proof that a MAJOR bump owes a
    migration has stopped running*. `92a1127`'s message names 31b, 23b and 59,
    because those had legible symptoms. Rewriting the anchors to `2.0.0` would
    have been green and would have re-armed the bomb for `3.0.0`.
    `copy_version <dir>` reads the version out of the copy and
    `bump <v> <major|minor>` derives the destination, so the recipe means the
    same thing at any version.
    - **The check is over the RECIPES, not over a failure.** `edit` already
      refuses an unmatched anchor loudly, and by the time it does the recipe is
      dead and the damage is done; the new check refuses a bare version literal
      in any argument of an `edit` touching `VERSION` or `CHANGELOG.md`, at
      authoring time, with the line, the file and the literal in the message.
      The files in scope are **derived** from the recipes, so the next version
      recipe covers itself — see `self_test_no_version_literal` in
      `tests/validate.sh`, `DECISIONS.md` (MD31), and the two measured holes in
      `REPORT-kit-version-recipe-drift-01.md`.
    - **98 carried a SECOND literal the version sweep could not see**: its
      anchor was `## Unreleased\n\n### Added`, so `a5f8746` killed it the same
      day for an unrelated reason, and the next release renames that heading to a
      version, at which point the section to mutate is one the recipe has to
      *create*. Both states are handled.
- **A toolchain's floor is checked against the floor the ARTIFACT declares.**
  `KitOtel::RUBY_FLOOR` says what `templates/otel/ruby` needs and the gate reads
  that constant rather than restating the number. Below the floor is a loud,
  counted `SKIP` naming both versions — never a `FAIL`, because the template is
  correct and the interpreter is old, and never a `PASS`, because thirteen
  unexecuted tests are not a pass. `templates/otel/ruby` is the only one of the
  six that needs this: the other five refuse an old toolchain themselves, at
  build time, with a message naming their own requirement. Ruby 2.6 is the only
  one that loads the template happily and raises on first use.
- **A self-test needle must be a thing the check EMITS.** `expect_red_check`
  matches `FAIL $want`, so `$want` has to be the check's **label** — not the
  wording of its finding, and not a paraphrase of either. Two failures on kit-22,
  both from recipes whose *check* was correct:
  - Breakages 75/76/77 asserted the finding's text
    (`"which is the image kit's stack already ships"`,
    `"promises a command the script does not dispatch"`). Those strings are
    printed as **indented detail lines under** the `FAIL <label>` header, so
    `FAIL $want` never matched and all three reported "the gate went red, but NOT
    via …" **while printing the needle two lines above the complaint**. A check
    that works, a mutation that works, and a recipe that cannot tell either from a
    failure.
  - Breakage 71 asserted `the connection budget  (max_connections covers` against
    a label that read `max_connions` — a misspelling of a setting that does not
    exist, in the one line a reader greps for to learn what a check measures.
  - So: the needle is the label, and **a label a self-test asserts is a contract.**
    Renaming one silently un-proofs the breakage, which is the same coupling as
    the `callable path` check. When a recipe reports "red, but not via `<label>`",
    read the actual FAIL line before assuming the check missed the defect — the
    three failures above were all in the recipe.
- **`self_test` hits its 90-minute bound on a busy box, and a `BOUND` tier is
  not evidence about the breakages it never reached.** This repository's machine
  runs several kit gates at once, and the self-test is *n* whole gates in
  sequence, so it is the phase that binds first. Measured on kit-22: the full
  gate **exited 0** while `self_test` reported `BOUND` at breakage **56 of 77** —
  so 57-77 were never executed, and a green gate says nothing whatever about
  them.
  - The `BOUND` verdict is what made that legible, and it is why the bound is not
    a failure: the point of the run is to reach the end and say so, and a bound
    reported as a pass would be the silent skip this file forbids. It bought
    nothing here, and the summary line is how a reader finds it.
  - **So a `BOUND` self_test is a gate to run BY HAND, not a gate to report.**
    Take the recipes that were not reached, apply each one's own mutation to a
    throwaway copy, and run the static gate in it. On kit-22 that is how
    breakage 72 was found to be green on a check that could not see the defect
    it was written to catch — the `BOUND` did not hide a failure, it created the
    gap where one was found.
- **A green control that two different checks could satisfy proves neither.**
  This is the `reportUnusedDisableDirectives` rule's other half, and breakage 75
  exists because it was violated by kit's own self-test. The rule above is about
  an allowlist entry that never matches; this one is about a proof that goes red
  for a reason the recipe did not introduce. Both are the same defect — a control
  whose green is not about the thing it names.
  - Measured, on the commit that shipped it: `break_stale_copy`'s fixture gives
    `alpha` a stale `postgres` **with a `ports:` entry**, so two checks can report
    it — `check_stale_copy` on the image, `check_override_surface` on the
    published port. Renaming kit's image to `kit-postgres` killed the first and
    left the second, and breakage 60 stayed green throughout. The check it was
    proving had been dead for the whole run.
  - So a fixture that mutates one thing must mutate **one** thing, and where two
    checks can see the same mutation there is a second fixture with the other
    half removed. Read the fixture and ask what ELSE could go red.
- **Never read the gate's output through a pipe, and fix every occurrence at
  once.** `printf '%s\n' "$out" | grep -q …` is a broken-pipe bug, not a style
  choice: `grep -q` closes the pipe on its first match, `printf` dies of SIGPIPE,
  and `set -o pipefail` promotes 141 to the pipeline's status. So the verdict
  flips on the SIZE of the output rather than on what is in it. Measured, on
  identical content: 2000 lines returns 0, a 239KB report returns **141 with the
  match present**.
  - The threshold is the pipe buffer, so it moves with the machine and returns as
    a flake on somebody else's packet. The fix is to stop piping, not to bound the
    output — `contains` is a shell `case` over a variable already in memory.
  - **This bit twice, and the second time is the reason for the rule.** `1d98e42`
    fixed it in `expect_red_check`'s `FAIL $want` test and left the `env_skips`
    branch four lines below it on the old form. The result was four breakages
    (71, 75, 76, 77) reported as ENVIRONMENT failures on a run where all four had
    been caught, and one (72) reported as "the gate stayed GREEN" — the *worst*
    direction to be wrong in, since the false answer is "this is a machine
    problem", which is the verdict that branch exists to protect.
  - So: when a check reads a captured variable with a pipe, grep the whole file
    for that shape. The seven remaining `printf … | grep` calls in
    `tests/self_test.sh` only **print** diagnostics, where a truncated line costs
    nothing — and that difference is the whole test for which is which.
- **No adopter carries a workaround for a fixed core defect.** `core`'s gate
  checker had two defects that forced adopting repositories into local
  workarounds — D12 (`RUN_KEY` could not see a one-line `run:`, core `63fd319`)
  and D13 (a proof matched against bytes still carrying ANSI colour, core
  `c63af27`). Both are fixed, so a workaround for either is a second, local,
  unversioned copy of a decision that now lives in core, and D13's is *weaker*
  than the declaration it replaced. `tests/gate_declaration_check.py` sweeps the
  adopting repositories for the three shapes those workarounds actually take and
  is wired into the gate as `adopting repositories (no workaround for a fixed
  core defect)`.
  - **Every one of its three rules is structural, and that is the lesson.** The
    first version was a keyword scan over comments — `cannot see`, `only
    matches`, `D12` — and against the real fleet it reported 4 repositories and
    24 findings, nearly all false: `core/gate.yml` for "That is MD12's
    collect-then-run machinery" (`D12` is a substring of `MD12`), and `caf`'s
    declaration for comments arguing a workaround is now *unnecessary*. A check
    that fires on correct work teaches the reader to ignore it, and it had
    taught on the first repository scanned. When a check over this fleet is
    noisy, the fix is to make it measure something.
  - It does **not** prescribe a `run:` spelling. It would be a second copy of a
    decision core owns, and `courier`'s block scalar is correct for three real
    reasons. `core`'s own `gate.ci-disagrees` checks invocation; this checks
    duplication.
  - The fleet root is discovered beside the repository, with a **reported SKIP**
    when there is none. `../..` is deliberately NOT searched: it found a fleet
    once, in a leftover copy of a cafaye repository in a shared temp directory
    whose branch still carried the retired workaround, and the gate went red on
    a tree with nothing wrong with it. A sweep that reaches further than it owns
    is worse than no sweep.
- **The self-test's copies are the fleet.** `fresh_copy` gives every breakage its
  own parent directory, because `lint_drift_check` finds a fleet by globbing
  `$ROOT/..`. Copies sharing one directory would each see the other fifty-five
  as their fleet, and a breakage could be "caught" by a defect it did not
  introduce — a control that goes red for a reason another test created reads as
  evidence and is worse than no control at all.
- **A breakage recipe asserts its own premise before it mutates.** Two of
  kit-14's recipes were wrong and the suite caught both: one named an artefact
  id that `artifacts.json` really declares, so the mutation broke nothing, and
  one asserted that a check would go red when no such check exists in this
  repository. `edit` already refuses an unmatched string; the same instinct
  applies to a recipe whose *subject* has moved. A mutation that has silently
  stopped breaking the thing it names is a proof of nothing.
- Tests are written **first** and watched fail before the artifacts exist. A
  config written from documentation instead of from the pinned image is a config
  that breaks on the first `bin/dev up`: Tempo, Loki and Mimir all reject keys
  with messages that name a Go type rather than a config key. Every vendor
  config in this repo was verified by loading it into its image.
- **Never weaken a check to make the gate green.** If a check is wrong, fix the
  check and say so in the commit message.
- `shellcheck` and `node` run when installed and are skipped when not. A skip is
  reported in the summary, never hidden — and a *skip in self_test* fails the
  run, because a proof nobody ran is not a proof.
- **PyYAML, yamllint, zizmor and hadolint are required and are bootstrapped, not
  required of you.** `tests/bootstrap.sh` resolves an interpreter, builds
  `.venv`, pip installs `tests/requirements.txt`, and fetches pinned hadolint
  and gitleaks releases verified against their published checksums. zizmor is
  pinned in `requirements.txt` and comes from PyPI, because it publishes no
  checksums file and pinning its archives would mean pinning hashes we computed
  ourselves. Resolve
  order: `$KIT_PYTHON` (an override is a promise — if it cannot import yaml
  the gate says so rather than silently substituting a different one), then
  `.venv`, then any `python3` on PATH that already has PyYAML, then bootstrap.
  A required check whose tool path is hardcoded to a directory the resolver may
  have skipped is a gate that fails on arrival; that is a bug this file has
  already had once.
- **Four counts, because they are four different claims.** `PASS` and `FAIL`
  are verdicts about the tree. `SKIP` is a verdict about the **environment** —
  no docker, no toolchain, nothing ran. `BOUND` is a verdict about the **run** —
  the tier started, this machine was too busy to finish it, and the claim it
  exists to prove is therefore unexercised. The heavy tiers (three docker stacks,
  and the self-test, which is *n* whole gates in sequence) carry a time bound for
  exactly this reason: a gate SIGKILLed by the OOM killer reports nothing about
  the tiers it never reached, so its green is a claim about how far it got. A
  bound that is reported as a PASS is the silent skip this file forbids; a bound
  reported as a FAIL is indistinguishable from a defect in the tree. It is its
  own verdict, and the summary prints both the number that ran under a bound and
  the number that reached one. `timeout` is **resolved**, not assumed — GNU
  coreutils calls it `timeout`, macOS has no `/usr/bin/timeout`, Homebrew's
  installs `gtimeout`.
- **A skip is a gap, and the summary line is how you find it.** The seven
  Dockerfiles sat behind `SKIP ... (no parser for this file type)` for the whole
  life of kit-02, and the only reason anyone knew is that the summary printed
  `note: 7 check(s) skipped`. A skip that is honest is still a check that ran
  nothing — and a new file type with no parser is reported, never quietly
  ignored. If you add a file type, add the parser in the same commit.
- When adding an artifact, add the check that would catch its absence. A
  validator nobody extends is a validator that quietly rots.
- **Assert the AGREEMENT, not the presence of a file, and never read the gate's
  output through a pipe.** Both halves are the same lesson from two directions.
  A file existing does not mean it agrees with the other four places that state
  the same fact — a licence, a port range, a tier, an allowlist — so a check
  that only asks "is it there" is satisfied by exactly the state where the
  repository has started contradicting itself. And when the harness asserts on
  gate output, match the captured variable with a shell `case`; `printf … |
  grep -q` reads a **match** as a non-match once the output overflows the 64K
  pipe buffer, because `grep -q` closes the pipe, `printf` dies of SIGPIPE, and
  `set -o pipefail` promotes 141 to the pipeline's status. That one cost kit-19 a
  false red on breakage 59 after three correct copies of the defect were already
  documented in the very file that contained them; it is now a `contains` helper
  all three assertion helpers share, because the failure is a property of how the
  harness READS output and has nothing to do with which check it is reading.
- **A gate that reported nothing is not a red gate, and a proof that could not be
  evaluated is not a proof that failed.** The two demand different responses, so
  they get different verdicts: `self_test` counts an environment failure
  (`env_skips`) apart from a missing toolchain (`skips`), and both are fatal.
  Collapsing them is how a busy machine gets filed as a weakened check. The test
  is the finding, not the exit status — `validate.sh` exits 1 on a FAIL and also
  exits 1 from bootstrap when it cannot install its own dependencies, and only
  the first ever ran a check. The same rule as breakage 39, which asserts the
  explanation rather than the status for exactly this reason.
- **Parse what you hand out.** A file a service copies has to parse in its own
  language, and the extension kit gives it must not stop you checking. This is
  not hypothetical: `rack_middleware.rb.snippet` shipped with
  `c.use_all, :auto_instrumentation`, which is not Ruby, and nothing noticed
  because the artifact table only asked whether the file existed. The tier
  templates are parsed the same way — and the tier Go files shipped
  un-gofmt'ed until this packet's own second pass ran `gofmt` over them, which
  is the shape of the same defect one layer down.
- **Run the config against your own files.** Both `Naming/PredicateName` (an
  obsolete RuboCop key that applies nothing) and a duplicate
  `Metrics/MethodLength` block in `lint/rubocop.yml` were invisible until
  rubocop ran on kit's own Ruby with kit's own config. That is the only way an
  obsolete key surfaces before six repos inherit it.
- The suite must be able to fail: `self_test` breaks a throwaway copy of the
  tree ninety-four ways and asserts the run goes red. If you change the suite,
  keep that true.

## The classifier fails closed, and that is a rule about code

A difference `classify.py` cannot place is assigned `rules.json`'s
`unrecognisedTier`, which is `FILE`, and is breaking. **Both facts live in
`rules.json` and nowhere else.** An earlier version stated the tier in the Python
*and* in a rule, and the self-test breakage written to invert it left the suite
**green** — because the headline case never reached the line that was broken. A
property stated in two places is a property asserted in zero times.

So:

- Adding a JSON Schema keyword the classifier does not model is a **decision**,
  not an omission. It falls to `unrecognisedTier` deliberately; make it
  deliberate in the same commit.
- The escape hatch is fenced. A rule may set `breaking: false`, and the
  catalogue **refuses to load** if the operation is not in `advisoryOps`.
  Without that rule the one escape hatch is the first place a fail-open
  classifier reappears, and `advisoryOps` is a closed list on purpose: a list
  that grows by a later commit is not a control.
- `advisoryOps` has three entries — a documentation edit, and a reordering of
  `required` or `enum`, both provably non-semantic because JSON Schema defines
  those two keywords as sets. Each had to argue for itself. Widening the list is
  a deliberate, diffable act in one file.

## The reporter fails closed too, and so does a copy that is missing

`tests/staleness.py` has two scopes. `--scope core` measures a **pin**; the one
kit already had. `--scope templates` measures a **file**, and a file has a state
a pin does not have: it is not there. `templates/` has drifted furthest and the
commonest state in the fleet is `absent` — 0 of 9 services hold the collector,
1 of 9 holds `bin/dev` — so the reporter needed a word for it before anything
else could be said.

Five states, and the vocabulary is the whole design:

| state | meaning | needs a pin? |
| --- | --- | --- |
| `current` | byte-identical to what kit ships, at the declared path | no |
| `diverged` | present, and not byte-identical | **yes** |
| `absent` | kit ships one and the service holds nothing there | **yes** |
| `unknown` | it could not be measured | **yes** |
| `n/a` | kit ships no variant of this artefact for this service's language | no |

`unknown` inherits the rule above rather than copying it. A service that
declares no `language`, a symlink where a copy should be, an unreadable file, an
artefact kit has stopped shipping — each is a finding, because the cheap answer
in every one of those cases is a guess, and a guess reported as a measurement is
the fail-open direction. `n/a` exists so that `unknown` can stay honest: a Go
service has no `.rubocop.yml` because it is not a Ruby service, and calling that
unmeasured would put three permanent, unfixable findings on every service in the
fleet.

**Never infer a copy from its content.** There is no similarity threshold, no
percentage, no "closest match", and no search for a file that hashes to kit's
artefact. A copy is `current` when the bytes at the declared path are equal and
the path is a real file in the service's own tree, and at no other time. One
appended byte makes it `diverged`, and `diverged` needs a pin. This is
self_test breakage 37, written as the well-intentioned patch it would be — a
`quick_ratio() > 0.99` — because that is the shape a helpful contributor
reaches for, and the only way to know the rule holds is to try to break it.

**`templates/parity-allowlist` is the same dialect as
`templates/tier/skip-allowlist`: the same four rules, in the same words, one
entry per line.** Two dialects of "record why" is how one of them goes stale. It
adds one rule the tier file does not need — **an unpinned divergence or absence
is a failure** — because its entries name copies in repositories the gate cannot
read, so the file is a *record of the fleet*, and a record that silently omits a
cell is worse than no record: it reads as "handled".

The count is printed on PASS and it is a measurement, not a ledger to shrink.
It is currently **80**, which is a bad number, and the way to move it is to
re-copy an artefact and delete the entry — never to delete an entry, which the
dead-entry rule turns red.

## One cluster, and the database is the boundary

**Nine services, ONE Postgres, one database and one role per service.** Isolation
between services is the database, not the machine. There is **no pooler**.

Four rules, and each one is load-bearing:

- **The `REVOKE` is the boundary, not the table grants.** Postgres grants
  `CONNECT` on every database to `PUBLIC` by default, so a cluster provisioned
  without `REVOKE ALL ON DATABASE … FROM PUBLIC` has, by default, **no
  isolation at all** — it fails open and silently. Measured both ways: with the
  revoke, `FATAL: permission denied for database "billing"` before a query is
  parsed; without it, the connection succeeds and only the `SELECT` on the other
  service's table is refused, by the accident that nobody granted it. A check
  asserting "A cannot SELECT from B's rows" would therefore pass on a cluster
  with no isolation whatsoever, which is why `tests/isolation_test.sh`'s fourth
  assertion builds a **control** cluster without the revoke and requires it to
  let A in.
- **The boundary is applied by SWEEP, not by a list.** The init script revokes
  `PUBLIC`'s `CONNECT` on *every* non-template database in the cluster, so the
  invariant holds by construction. An earlier version enumerated the databases it
  knew about and printed "PUBLIC holds CONNECT on none of them" while the stock
  `postgres` database still granted it — a closing sentence that was wrong, and
  worse than no closing sentence because it is the one a reader trusts.
- **An init script that cannot apply the boundary does not start.** `ON_ERROR_STOP`
  is on every call and there is no `if` around any of it. `set -e` does not reach
  inside a command substitution used as an `if` condition, and a load-bearing
  statement whose failure is ignored is how a cluster comes up holding two of nine
  databases and reports itself healthy.
- **PG15 is the floor**, because PG15 removed the default `CREATE` grant on the
  `public` schema and that change is what makes database-per-service a boundary
  rather than a naming convention.

**Extensions are a cluster decision.** They live in the image (pglayers) and are
created by the **admin role** into every declared database. A service role cannot
create one: pgvector's control file is not `trusted`, so `CREATE EXTENSION` by a
non-superuser is refused. That is pgvector's own classification — pglayers'
`vector.control` is byte-identical to upstream's — and it is the right shape
anyway, since an extension's binaries are available to every service on the
cluster whether or not anybody creates one.

**`postgres:17-alpine` cannot carry pgvector.** pglayers publishes glibc-linked
layers and alpine is musl, so the image builds and then fails to create the
extension. The cluster base is `postgres:17` (Debian); the measurement is in
`templates/compose/postgres/Dockerfile` and the trade is MD21b.

**The four settings every service's config carries**, and none would be needed
with one database per service: `application_name` (the only way to attribute a
query on a shared cluster), `statement_timeout`, `idle_in_transaction_session_timeout`
(the shared-cluster killer), and a bounded pool. The cluster sets the middle two
**per role** as a backstop, so a service that forgets is bounded rather than
unbounded.

**The pooler decision is a CHECK, not a paragraph.** The pooler workarounds are
forbidden in `templates/database/contract.json` and the gate fails the build if
one appears in any generated config. A service carrying `prepare: :unnamed` on a
fleet with no pooler is slower and looks entirely correct, so nothing else would
ever find it.

## Adding a language

1. Add `<lang>` to the `language` **gate job's** `case` statement in
   `.github/workflows/ci.reusable.yml` **first**, and watch the suite go red.
   That one edit is the whole trigger: `validate.sh` reads the case statement
   out of the workflow and, for each value it names, requires a Dockerfile, a
   `bin/prime` and a `[tools]` pin. There is no second list to keep in step —
   that is the point.
2. Add the job: `.github/workflows/ci.reusable.yml`, guarded by
   `if: ${{ inputs.language == '<lang>' }}`.
3. Add the other three artifacts: `docker/Dockerfile.<lang>`,
   `templates/bin-prime/<lang>.sh`, and a `[tools]` entry in
   `templates/mise.toml`.
4. Add the language to the README's adoption table and checklist.
5. Re-run the gate until green.

**Why the gate job and not an `options:` list.** `workflow_call` inputs accept
`description`, `required`, `type` and `default`, and nothing else. `options:` is
a `workflow_dispatch` feature — a dropdown for a human clicking a button — and
writing it under `workflow_call` makes GitHub reject **the whole workflow
file**, not just the input. Every service in the fleet calls this file, so the
result is not one broken repository; it is every repository's CI starting zero
jobs and reporting success. That is not hypothetical: it is what kit carried
from 2026-09-30 until kit-33.

The gate job is also the stronger guarantee. With `options:`, a value outside
the list was not expressible; without it, a typo like `language: golang`
matches no `if:` condition, every language job skips, and the run goes green
having tested nothing. The gate job fails that run instead.

`bun` is the worked example: it was added because `guard` carried a standing
note that it hand-rolled a whole workflow for want of a `bun` job. All four
artifacts landed with it, in one commit.

Half a language is worse than none: the whole point of kit is that every repo
that adopts it gets the same thing.

`none` is not a language and is deliberately exempt from the four-artifacts
rule: it is the value for a repository with no service manifest, and it runs
that repository's own `tests/validate.sh`. It exists because without it `kit`
could not call this workflow — every `language` value named a toolchain this
repository does not have, which left the repository that defines the standard
structurally excluded from using it. If you add a job for a new value, the
`ci_check` block in `tests/validate.sh` must know about it in the same commit:
a value with no `job` is a green build that ran nothing.

## Deploy and backup are Kamal's, and kit generates the CONFIG

`templates/kamal/` is four files: `deploy.yml.erb`, `kamal-backup.yml.erb`, a
`drill.sh`, and a README. kit does not ship a deployment tool or a backup tool,
because `kamal` and `kamal-backup` are both, they are both installed wherever
cafaye deploys, and kit-20 proved the cost of the alternative by building
`templates/backup/` and `templates/bin/backup.sh` — about 3,012 lines
reimplementing a command surface that already existed. **All of it is gone**, and
`tests/validate.sh` asserts its absence, because "we removed it" has no
mechanical form until something checks.

Four things about this arrangement are load-bearing, and each is a check rather
than a comment.

- **The two config files are ONE contract, so the gate EXECUTES them.**
  `kamal-backup validate` builds the backup accessory's environment from
  `config/deploy.yml` and resolves every `{ secret: NAME }` in
  `config/kamal-backup.yml` out of it. A secret named in one file and missing
  from the other is a valid YAML file that fails validation, and **neither file
  is internally inconsistent** — so no per-file parse can see it, and
  `tests/kamal_test.sh` runs the real `kamal` and the real `kamal-backup` to
  find it. This is the one place kit hands out YAML a **third-party binary** has
  to accept, and it is why the check exists at all: three real defects in these
  templates' own first draft — a doubled registry host, a missing
  `builder.arch`, and a cross-file secret — were all invisible to a parse and all
  caught by the binaries within one run each. `self_test` breakages 61, 62 and 65
  are those three, inverted.
- **A missing required variable FAILS THE RENDER, by name.** `<%= ENV['X'] %>`
  with `X` unset renders an empty string, which YAML reads as a null list item
  and which surfaces three layers away as a deploy that cannot find a host. The
  templates `raise` and name the variable.
- **A TAG in the body of an ERB block closes the block early.** Not a kit rule:
  an observation that cost a run. A comment inside `<% … %>` that spells out an
  ERB tag in full is compiled as code, the block ends, and the file fails with
  "undefined local variable or method `service'" pointing at a variable defined
  two lines above. Nothing in the template may contain a literal ERB tag, even in
  a comment.
- **Retention is WRITTEN OUT, not inherited.** kamal-backup 0.5.2's defaults
  happen to be exactly the five numbers `templates/kamal/kamal-backup.yml.erb`
  states, so omitting the block would work today. A retention policy that lives
  in a dependency's defaults is a policy that changes on a version bump, and the
  diff at that moment is about the gem rather than about the thing that decides
  how far back a restore can reach.

**Ruby is the OPERATOR's tool, not the service's, and the difference is a
boundary rather than a caveat.** The service image contains no Ruby. The backup
accessory **ships its own** — it is an ordinary container, which is why the
`backup` block in `deploy.yml.erb` is a normal accessory. `kamal` itself is a
Ruby gem and always has been; an operator deploying with Kamal has Ruby, and that
is not a requirement kit adds. A service that wants backups and no local gem
still gets backups, because the accessory's scheduler loop is what takes
snapshots; what it loses is `restore local` and `drill local`, not the backups.
`templates/kamal/README.md` states all of it, and the ERB costs nothing extra
because Kamal evaluates `config/deploy.yml` through `ERB#result` itself.

**`drill.sh` exists for the two things kamal-backup does not do**, both found by
reading the gem rather than by using it. `restore_to_scratch`
(`databases/base.rb:52-55`) validates and restores and does **not drop the
scratch database** — the only `DROP SCHEMA` in the gem runs against the *live*
database — so cleanup is an operator's job, and a step remembered after a failure
is a step that does not happen after a failure. And the gem decides the drill
passed by the **exit status** of `--check` (`app.rb:307-325`), which makes a
`psql -tAc "SELECT count(*) FROM t"` useless as a check: it exits 0 for zero
rows, so a restore of an empty database is reported as a successful drill. So the
wrapper drops the scratch database on **every** exit path with `WITH (FORCE)`,
and generates a `DO $$ … RAISE EXCEPTION` block under `ON_ERROR_STOP=1` so an
empty table becomes a non-zero exit. There is no default table list: a drill with
no `--table` is a usage error rather than a drill that quietly passes.

**R2 has no object versioning and no Object Lock**, so a deleted object there is
gone. That is not a kit rule, it is a property of the store — read out of
Cloudflare's own compatibility table, where those four APIs are listed as not
implemented. **An operator who deletes a snapshot from the console has destroyed
it and nothing here can bring it back**; the mitigation is bucket access control,
and `templates/kamal/README.md` says so rather than implying the mechanism
prevents it.

**The custom deploy distribution is still here, and the overlap with Kamal is
real.** `templates/bin/deploy.sh` is 1,067 lines implementing `up`, `verify`,
`rollback`, `status` and `down` — all five of which are Kamal commands, and
`templates/deploy/README.md:5-8` says in its own first line that the thing is
**not a remote deployment**: no TLS, no reverse proxy, no multi-host, no
zero-downtime. What it does that Kamal does not is deliver secrets into a tmpfs
over stdin so no credential is ever in `Config.Env`, and redact output **by
shape** — a JWT, an AWS key, a PEM header — which kamal-backup's `Redactor` does
not (it knows env values whose *key* looks secret, and URL credentials, and
nothing else). Removing the distribution would also delete
`tests/deploy_test.sh`, which is where kit-16's live proof that the redactor
catches a JWT by shape lives, and which `.gitleaks.toml`'s only allowlist entry
is scoped to. That is a larger decision than this packet, it is recorded in
`REPORT-kit-20.md` §"not removed", and it is not resolved here.

## The stack is FETCHED, and the pin is the only thing that decides what it is

`templates/compose/` is not copied into a service. `bin/dev` fetches it from the
ref named in the service's committed **`kit.ref`** and runs it beside the service's
own `docker-compose.yml`, which is an **override**. A compose file cannot be
`uses:`-ed, so `bin/dev` is the callable path and the pin is what makes it one.

Three rules follow, and each is a thing that has to be true rather than a thing
that is usually true:

- **A pin is a 40-character commit sha or a `v<semver>` tag.** Never a branch.
  The ref decides which redaction allowlist, port block and dashboards a
  developer's loop runs, and on a branch those change between two runs of the
  same command.
- **The pin is `kit.ref`, not `.env`.** `.env` is git-ignored, so a pin there
  exists on one machine and on no CI runner — which turns "one command, always
  current" into "one command, whatever this checkout last fetched".
- **`tests/fleet_check.py` reads the CALLERS, not this repository.** A defect in
  the standard is invisible to a gate that only reads the standard, which is the
  same argument as D4. As measured: six repositories declare local
  infrastructure, **five** carry their own copy of the shared stack (billing,
  courier, darkroom, identity, muse), **all six** have no `kit.ref`, and **two**
  publish a port on a service kit already ships — 13 findings, and the gate names
  every one of them. **All six are currently WARNINGS and none is a FAIL**, because
  the ceiling keys on adoption and not one of them has adopted. That is the state
  to beat, and it is a state the gate is now *about to be able to leave*: the
  first repository to commit `kit.ref` finds its own two or three findings are
  failures, with no change to this repository.

  Do not soften the checks to make this repository green. Do not raise the
  ceiling either — a repository that HAS adopted is judged strictly, and
  `breakage 60` in `self_test.sh` is the recipe that would go red if that ever
  stopped being true. Report the findings; name the repositories.

`README.md` carries the override rules, and one of them is a trap worth knowing
before you write a service compose file: **a second file's `ports:` list is
appended, not substituted.** Move a port in `.env`; never in the override.

## The version is `VERSION`, and the tier is derived from it

One line, one number, and the **only** place the version is written. Three tiers
derived by `stability_tier` from two version strings and asserted against a
published table of ten pairs, so a change to the rule that is not a change to
the table is a red gate:

| the bump | the tier | what a consumer may do |
| --- | --- | --- |
| MAJOR | `breaking` | read `MIGRATIONS.md` for that version — a MAJOR without one is a red build |
| MINOR | `additive` | take it; nothing a consumer holds went away |
| PATCH | `invisible` | take it without reading anything |

Five rules, each of which is a thing that has to be true:

- **The predecessor comes from the CHANGELOG, not from git.** The first version
  read `git show HEAD:VERSION`, which resolves to nothing in a throwaway copy,
  so a bump in an unpacked tarball derived `initial` and breakages 96 and 97
  stayed green. It is the version section below the current one — a version a
  consumer can SEE, and therefore the same fact the promise is about.
- **A string this cannot place is a red build**, not a guess: `1.0.0-rc1` (a
  suffix makes the tier change meaning when it is dropped), `v1.4.0` (that is
  the TAG spelling), `01.4.0` (a leading zero is one string and two numbers), and
  a backwards move. All fail closed.
- **The tier owes a FILE, not a sentence.** A MAJOR owes a `MIGRATIONS.md`
  section, because a consumer who adopted kit by copy cannot apply a sentence.
- **`### Breaking` is legal only under a version whose MAJOR moved**, and never
  under `## Unreleased`, where no version covers it. It holds for the **whole
  history**, not only for the bump being released — which is what makes the
  promise checkable rather than documented.

  It does need a predecessor, though, and this file used to claim it did not:
  the version it is compared against is the one **below** it in the changelog,
  because the changelog is newest-first and the claim is about the bump that
  *produced* the version. The comparison ran against the section **above**, and
  two things followed that nobody could see from a green suite. The clause had
  **never executed** — the only `### Breaking` on this tree sits under
  `## 2.0.0`, the section above it is `## Unreleased`, and `stability_parse`
  refuses that, so it short-circuited every time — and an honest additive
  release (`## Unreleased` renamed to `## 2.1.0`, nothing else changed) went
  **red**, reporting `2.0.0`'s perfectly legal heading against a release
  written after it. So the corrected sentence is the one above, and the clause
  now has red proofs on five trees, one property each; see
  `REPORT-kit-version-recipe-drift-01.md` and `CHANGELOG.md`.

  **A rule that is checked over a list needs the RIGHT element of the list.**
  The comparison was additionally vacuous — `stability_parse` returns no value,
  it sets globals, so parsing the neighbour overwrote the value the test then
  read — and being dead is what hid it. A clause can be simultaneously absent
  and wrong, and a green suite is evidence about neither.
- **`VERSION` is not a service manifest's job.** Nine services carry no `version`
  key on purpose and `identity` says why; that key describes the service, and
  "how safe is kit to take" is a different question. `1.0.0`, not `0.x`: in
  semver `0.x` *means* unstable, which is the sentence this removes.

## `RESERVED` is the tombstone, not the deprecation

Two references adopted "reserved" independently, and reading them closely is the
finding: **they are not the same mechanism.**

- **buf's `reserved: 3, 7;` is a WIRE tombstone.** The field *number* is what
  travels, so a retired number may never be reused — otherwise an old message and
  a new one decode the same bytes two ways. Its purpose is to make DELETION
  non-breaking.
- **Kubernetes' `+k8s:deprecated=width,protobuf=3` is a LIFECYCLE marker on a
  field that is still there.** k8s does not delete an API; it deprecates, names
  the replacement, and leaves the type in place.

**kit has no encoding, so buf's justification does not transfer.** What transfers
is the weaker half both enforce, which is the one that matters when a service's
copy outlives the decision: **a retired name stays retired.** The deprecation
half does not port either — a comment in a copied YAML file is a comment in the
copy, and kit has no registry to hold one (`templates/parity-allowlist` already
carries that half).

**The fourth hygiene rule is INVERTED here.** In a skip allowlist, an entry
matching nothing is a ratchet that only turns one way. For a tombstone the dead
entry and the live name are one defect with two names, so `reserved_check` fails
when a reserved path **exists**. It is silent otherwise, and it permits nothing.
See `DECISIONS.md` (MD26, MD27).

## Rules

- **Config only.** No runtime code, no dependencies, no generated output. If
  kit grows a dependency it has stopped being conventions.
  - **The one carve-out, and why it is a carve-out rather than a precedent.**
    `core/` ships a change classifier and a staleness reporter, which are
    programs rather than configuration. They are here because a standard
    without a thing that enforces it is a standard enforced by whoever reads
    it. They stay inside the boundary deliberately: **standard library only,
    no import outside `json`/`os`/`re`/`sys`/`argparse`/`subprocess`/`difflib`/`glob`/`urllib`/`hashlib`/`__future__`**,
    no installable dependency, and **nothing imports them** — the real test of
    this rule is that nothing here is a library, and a classifier is not. The
    reporter prints a table for a scheduled job and **never commits its
    output**, because a committed report is the "generated output" this rule
    forbids and the kind of file that rots. If a third program is proposed, the
    default answer is no.
  - **`tests/gate_declaration_check.py` and `tests/core_fanout_check.py` are the
    same carve-out, used twice, and a fourth is still a fourth.**
    **`tests/generated_stack_check.py` is a third use of it, and the argument
    for it is not that it is also a parser — it is not.** It parses no file
    type at all: it asks GIT two questions (`check-ignore`, `ls-files`) about
    whether `caf.dev.compose.yaml` is ignored and whether it is tracked, in
    every repository beside this one that has a `cafaye.yml`. It is here
    because the alternative is worse than a fourth program: re-implementing
    gitignore semantics in Python is wrong on `!` negation, on anchored
    paths, on `**`, and on a `core.excludesFile` in one developer's global
    config, and it would disagree with git on every case that matters. It is
    stdlib for the same reason the others are, it is named in the
    `carve-out boundary` check's list in the same commit that added it, and
    its population is read off the filesystem rather than written down. It also
    reads ONE file — `MVP-SCOPE.md`, the fleet's scope decision, beside the
    fleet and in no repository — for the set of repositories held frozen, and
    **that read is a scope decision and not an allowlist**: the out-of-scope
    list is the only exemption, a repository it does not name is blocking, and
    a decision that cannot be read exempts nothing and says so with a
    `SCOPE-ABSENT:` marker. A hardcoded frozen list would have the same defect
    as the hand-written dirty list this check was written to replace, with the
    opposite polarity: it goes stale silently, and the day the scope lifts the
    exemptions outlive the decision that granted them.
    `fleet_check.py` would have been the wrong home for it on two counts and
    both are argued at the top of that file: its scope predicate is "declares
    local infrastructure", which EXCLUDES `core` — the repository that had
    this file committed — and its adoption ceiling would have made a hard FAIL
    a WARN in every repository, forever, on the grounds that none of them has
    adopted `kit.ref`. That defect has no adopter. They are
    real parsers over real file types, and inlining either into the 4,000-line
    `validate.sh` would bury the failure modes. The boundary they hold to is the
    classifier's: nothing imports them, and neither is installable. The one
    thing that changed is that they import PyYAML, which `tests/requirements.txt`
    already carries and the gate already bootstraps — so this is the existing
    carve-out rather than a widened one.
  - **`tests/account_scope_fleet_check.py` is a FOURTH program, and the rule
    above says the default answer is no. It got a yes for one reason, stated
    here so a reader can disagree with it.**
    Six services declare their account-scoped surface in an `account_scope.yml`.
    `core/harness/account_scope_check.py` is what decides whether a declaration
    still describes its code. Measured at the time of writing, **not one of the
    six ran it against itself** — the only references in the fleet were
    declarations *mentioning* the tool and `core`'s CI running its own self-test
    over its own fixtures. So the contract was continuous in nobody's build: a
    service could add a route, widen a declaration, or delete
    `account_scope.yml` entirely and its own gate stayed green. `DEBT.md` D18's
    shape, one level up from where D18 had been looking.
    The argument for a program rather than an inline block is the same one the
    third use makes, at one more remove: it has to run **in CI**, and CI has no
    fleet beside the repository, so the step has to assemble one, name it, and
    invoke a program that is not the 620,000-line gate. Inlining it would mean
    either a second copy for the CI job or a `validate.sh` flag that changes
    what the gate is, and both of those are the mechanism this packet exists
    against. It is not a fifth: it is the same shape, and the boundary is
    unchanged — **standard library plus `yaml` (PyYAML, which
    `tests/requirements.txt` already carries and the gate already bootstraps) and
    `hashlib`, and nothing imports it.**
    A **fifth** program is still refused, and this paragraph is not a precedent.
  - **The allowed-import list is ENFORCED, not aspirational.**
    `difflib` and `glob` arrived with the templates half of the staleness
    reporter — the first counts the lines two copies differ by, the second
    resolves a `{lang}` source — and `urllib` was already there and already
    unnamed, so the sentence was out of date before anybody checked it.
    `tests/validate.sh`'s `carve-out boundary` check walks the **AST** of both
    programs, not their text, so a function-local import is read the same as a
    top-level one, and it asserts that every module it finds is named in **this
    paragraph**. Widening the list is a deliberate, diffable act in this file
    *and* a red gate until the check agrees with it. A list that grows by a later
    commit is not a control — the same argument `advisoryOps` rests on.
- **Callers override, they never fork.** Anything that differs per service —
  versions, thresholds, names — is an input or a build arg, never a copy of a
  file. Six repos each holding their own workflow is the drift this repo
  prevents.
  - **And a seam is only as narrow as the control on it.** `lint-args` is the
    worked example and the rule is general: the seam's limits are a list of
    refused flags, and that list lives in the **workflow**, not here — because
    the value is the caller's and kit has never got it. A control in
    `tests/validate.sh` that asserted the seam would be asserting the input
    exists and defaults to empty, and nothing about what a service puts in it.
    The promise that kit's gate would catch a bad `lint-args` was written down
    once, in a comment, and was **false**: the check did not exist. What kit's
    gate can do is assert the guard is in every lint job, that the three copies
    are byte-identical, that it runs BEFORE the linter, and that its token list
    is the one written here — so shortening the seam is a red build rather than
    a quiet widening of it.
- **Boring beats clever.** No frameworks, no generators, no clever YAML. A
  file that needs a paragraph to explain is a file that will be misread.
- **Strictness is documented.** Every config carries comments saying what is
  enforced and why, so it is relaxed deliberately or not at all.
- **Never weaken a check to make the gate green.** If a check is wrong, fix
  the check and say so in the commit message.
- **A check that a comment can satisfy is not a check.** The `-count=1`
  assertion was a plain substring test, the go step's own comment block names
  the flag twice while explaining why it is mandatory, and deleting the flag
  from the command left the check green. `strip_shell_comments` exists because
  of it. Any check that greps a `run:` body strips comments first.
- **kit ships the convention; `caf` ships the checker.** The declared tier per
  language, the normalised result format, the skip allowlist and its four rules,
  and the `REQUIRED_<TIER>` demand are kit's. The per-language collector
  adapters, the inventory-vs-run set difference, and the production of the
  normalised format are `caf gate`'s — runtime code, in a runtime repo. If you
  find yourself writing a collector here, you have left your scope.
- **A test count is not a tier gate, and a floor is not a tier gate.** The
  machinery can prove "41 tests ran"; only an assertion *inside* the test
  proves "41 tests hit Postgres". A pass-count floor is a decrease detector: it
  is satisfied by any N tests, including the wrong N, and nothing in it knows
  which tier a test belongs to.
- **Never cache a test report.** `restore-keys` matches by PREFIX and the
  default branch's cache is documented as available to other branches, so a key
  built from a lockfile hash restores a report written by a run that *had* the
  dependency into a run that did not. A witness from a different run is not a
  witness. Cache build products — `target/`, `$GOCACHE`, `node_modules`,
  `vendor/bundle` — and never a witness.
- **Never copy code from `moon/refs/`** into this repo or into any cafaye
  repo. Those trees are behavioral references; every line here is ours.
- **Pins are placeholders.** `templates/mise.toml` and the Dockerfiles carry
  placeholder versions on purpose. A service raises them in its own repo; kit
  does not become an org-wide lockfile.
- **The licence is MIT, and it lives in exactly one place.** `LICENSE` is the
  grant, and `license_check` asserts it *and* walks every root manifest that can
  carry a licence field. It does not ban those manifests — it requires them to
  agree, because a check satisfied by "kit has no `package.json`" would be
  satisfied by deleting one and would be a `FAIL` the day kit legitimately grew
  one. A licence is only unambiguous when exactly one place in a repository can
  declare it; a manifest copied out of a service is how that stops being true,
  and it looks like a build decision rather than a legal one. `templates/` is
  out of scope by design — a licence in a template is that template's business.
- **No `latest`.** Every base image and action ref is pinned or floating-major
  deliberately, never `latest`.

## Style

- `shellcheck -S warning` clean; `set -euo pipefail` in every shell script;
  `chmod +x` on every script kit hands out.
- `yamllint -c lint/yamllint.yml` clean on every YAML, including this repo's
  own. The config is dogfooded, not aspirational.
- Comments explain *why*, not *what*. A comment restating the line below it is
  noise; a comment recording a decision that would otherwise be relitigated is
  the point.

## Before you commit

- [ ] `bash tests/validate.sh` is green, and you have pasted the output
- [ ] Every claim about a third-party tool is verified against its source or an
      actual run, and anything you could not verify is written down as such
- [ ] You did not add a file type without adding the check that lints it
- [ ] New or changed config is covered by a check that would catch its absence
- [ ] `README.md` still matches the tree (every language, every file)
- [ ] `CHANGELOG.md` has an entry
- [ ] You did not weaken a check, a threshold, or a pin to get green
- [ ] If you touched `templates/database/tenancy/`, you ran
      `bash tests/tenancy_test.sh` — the FORCE control and the init-plan
      measurement are the only things that can see two of those changes
- [ ] If you touched the secret scanner, you did not add an allowlist entry
      without a reason, you did not add one to `continue-on-error`, and if you
      added one you **proved the thing it excuses can still fail** — an allowlist
      entry that silences a live proof is not an allowlist entry, it is a deleted
      test with a comment attached
