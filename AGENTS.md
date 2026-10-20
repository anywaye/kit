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
├── cafaye.yml                           # the manifest: name, language, core range, owner
├── DECISIONS.md                          # the trades this repo has NOT made
├── VERSION                               # the version, and the ONLY place it is written
├── RESERVED                              # tombstones: a retired name stays dead
├── .github/
│   ├── workflows/
│   │   ├── ci.reusable.yml               # the workflow six repos call
│   │   └── ci.yml                        # kit calling its own workflow
│   └── zizmor.yml                        # reasoned baselines, one per finding
├── lint/                                 # configs services RUN, not copy
│   ├── yamllint.yml  golangci.yml
│   ├── rubocop.yml   eslint.config.mjs
│   └── hadolint.yaml                      # argues the one rule it ignores
├── docker/                               # Dockerfile.<lang> templates
├── core/                                 # the cafaye/core fan-out standard
│   ├── tier/skip-allowlist               # one file for the fleet; four hygiene rules
│   ├── tier/README.md                    # the format, the rules, and the limits
│   ├── secrets/                          # runtime credential-leak canary
│   │   ├── README.md                       # the CONTRACT, language-neutral
│   │   └── go/                            # the Go adapter + its five vectors
│   ├── mise.toml                         # toolchain pin template
│   └── AGENTS.md                         # skeleton for a service repo
└── tests/
    ├── validate.sh                       # THE gate
    ├── lint_test.sh                      # the linters RUN, against fixtures
    ├── isolation_test.sh                 # the cluster, RUN; A cannot reach B's database
    ├── onecluster_test.sh                # the one-cluster claim asked of bin/dev, RUN
    ├── tenancy_test.sh                   # the account boundary, RUN; and its FORCE control
    ├── failfast_test.sh                  # a missing variable is refused in seconds, RUN
    ├── zizmor_gate.sh                    # the one zizmor split, ditto
    ├── bootstrap.sh                      # the gate installs its own tools
    ├── classify.py  rules.json           # the change classifier, failing closed
    ├── fingerprint.py                     # the skip record, and whether it can be WRONG
    └── profile_report.py                  # reads a profile.tsv, prints a table

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

**A reusable workflow's `concurrency.group` is namespaced with `kit-`, and that
is the only caller-side rule kit has.** Every caller declares

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

and `ci.reusable.yml` declared the identical block from `8ebf4db`, the commit
that first published it. **Inside a reusable workflow `github.workflow` is the
CALLER's workflow name and `github.ref` is the caller's ref** — GitHub does not
re-scope either to the called file — so both sides computed `ci-refs/heads/master`
and asked for **one lock**. The caller holds it, the callee's request is refused,
and the `uses:` job produces **no job, no check-run and no log line**. Measured in
`parlor`, run 37230458669: two jobs green, the run `failure`, and
`gh run view --log-failed` **empty**, because no step failed.

- **The signal that is not ambiguous is the `language` gate job**, because it has
  no `if:` on purpose. No caller in the fleet had ever produced a job ending
  `/ language`, and that job is where the frozen install, **lint** and the
  coverage step live — so `bin/prime` running the suite meant tests were not
  absent, while **no repository in the fleet had run kit's linter in CI**.
- **Reproduced with one variable changed at a time**, against a byte-identical
  copy of the blob on `master`: caller's group as written → **1 job**, callee
  gone; caller's group prefixed with `caller-` → **13 jobs**, callee present.
- **The control was free.** `image.reusable.yml` declares no `concurrency` block
  at all, and `identity`'s and `site`'s `publish` runs produce
  `image / build (and publish, if asked)` on every run — same mechanism, same org,
  same ref. The one difference between the workflow that works and the one that
  never ran is the block.
- **Renaming the group is not deleting it**, and that was measured because
  *dropping* the block is the other way to stop a collision and it trades a
  missing job for an unbounded pile of superseded runs: push A → called job
  `in_progress`, push B → A's called job `cancelled`. The caller's cancellation
  propagates into the called workflow, so kit's block is a second layer rather
  than the only one.
- **The fix belongs in kit and not in eleven caller PRs**, because it is the only
  one that reaches a repository nobody remembers exists, and it repairs kit's own
  CI with no change to `ci.yml` (`ci-<ref>` vs `kit-ci-<ref>`).
- `reusable_concurrency_check` reads kit's own `ci.yml` — which is a caller, and
  held the defect in both files at once — and fails on a collision in either
  direction **after normalising `ref` and `github.ref` to the same token**,
  because `core` writes the short form and a byte comparison would have called
  the one repository that spelled it differently clean. It is deliberately **not**
  a sweep over the repositories beside this one: kit grades this tree and no other.
- Breakages **105 / 105b / 105c** prove the two branches and the normalisation
  separately, and **105 is deliberately not the historical revert** — in kit's own
  tree that spelling also collides with `ci.yml`, so it satisfies both branches
  and a recipe proving two branches proves neither.

**THE SECOND RULE OF THAT FILE IS THAT A REUSABLE WORKFLOW HAS NO LOCATION OF
ITS OWN**, and it is `kit_gate_tree_check` rather than a paragraph.
`GITHUB_ACTION_PATH` is documented as **composite-action-only**, so it is not set
inside a reusable workflow — and under `set -euo pipefail` an unset variable is
not an empty path, it is a fatal on the step's **first line**:

```
…/_temp/9bf3851b-….sh: line 2: GITHUB_ACTION_PATH: unbound variable
```

Measured in `cafaye/site` run 37236386666 and `cafaye/parlor` run 37230458669, on
a job that had never run once.
that had stopped those jobs being created, and two jobs that had **never run
once** were broken: this one could not start at all, and the `node` job crashed on
its first `.mts` file. Four days, eleven repositories, two red jobs and a red run
that said nothing about why.

- **THE FILE ALREADY KNEW.** The `kit-lint-ref` input's own comment names
  `GITHUB_ACTION_PATH` as composite-action-only and explains that kit's configs
  must therefore be **fetched by a name** — and then five lines in three jobs
  contradicted it. The reasoning was applied to the lint configs and not to these.
  A rule written down once, obeyed in one place, and contradicted in another by
  nobody reading the other place.
- The fix is `uses: actions/checkout` of `cafaye/kit` pinned by
  `inputs.kit-lint-ref`, into **`$RUNNER_TEMP`** and not `<working-dir>/.kit`:
  a second git repository nested inside the one under test is a question with no good
  answer, and `$RUNNER_TEMP` is per-job scratch that is emptied when the job ends.
  answer.
- **The second job had a second defect.** `tests/zizmor_gate.sh` ends by piping
  zizmor's report through `"$PY" - …`, which in kit's own gate comes from
  `kit_bootstrap_python`. A reusable workflow makes no such call, so `zizmor`
  would have reached the script's last line and died on `PY: unbound variable`.
  One mistake, two hats: a script written to be called by one caller and run by
  another that had not been read.
- `kit_gate_tree_check` asserts no `run:` body reads a composite-action-only
  variable, that a step reading the fetched tree has a fetch above it, and that
  every checkout is pinned **by the input and not to a literal** — `ref: master`
  is what the input evaluates to when a caller sets nothing, so it looks pinned
  and is not. Breakages **106-106d**, plus **106e** as the green control.
- **The check failed SEVEN JOBS THAT WERE CORRECT** on its first version, by
  looking for `tests/` and `templates/` anywhere in a run body: every language job
  prints `See templates/tier/README.md` in an error message while running the
  *caller's* own gate. The rule is therefore stated as a **coupling** — the
  variable that means "the directory the fetch put it in" — not as a path
  substring. A check that fires on correct work teaches its reader to ignore it.

**AND THE SHARED ESLINT CONFIG HAS THE SAME SHAPE OF DEFECT, FROM A DIFFERENT
CAUSE.** `recommendedTypeChecked` is **UNSCOPED**, and one config inside it adds
`.mts` and `.cts` to the files ESLint lints; kit's `files` glob, which is the only
thing that supplies `parserOptions`, was narrower than that. So every `.mts` file
got the type-aware rules and never got the type information, and the run died at
exit 2 before reporting a finding:

```
Error: Error while loading rule '@typescript-eslint/await-thenable':
You have used a rule which requires type information, but don't have
parserOptions set to generate type information for this file.
```

- **It was blamed on `tsconfigRootDir: import.meta.dirname`, and that was not the
  cause.** Measured on eslint 9.39.5 / typescript-eslint 8: with
  `projectService: true`, setting `tsconfigRootDir` to `/nonexistent-root`, or
  deleting it, leaves the run **byte-identical** — the project service walks **up
  from the linted file** to find a tsconfig and never consults the root. A check
  written for the reported cause would have been green on the defect that
  shipped.
- `tsconfigRootDir` is still fixed, to `process.cwd()`, because it is load-bearing
  in exactly one place and it is a place kit would otherwise reach for:
  **`allowDefaultProject` globs are matched relative to it**, so with kit's
  directory as the root a pattern meant for the caller's own config files
  resolves to `.kit/lint/*.mts` and matches nothing. `process.cwd()` is the
  caller's workspace by construction — the lint step carries `working-directory:` —
  so **no caller needs a PR**.
- `.jsx` is **deliberately still absent**, and that is a fleet decision rather than
  an oversight: nothing adds it to the linted set, so adding it would widen kit's
  lint everywhere and turn every React service red with `was not found by the
  project service`.
- `eslint_typed_scope_check` asserts both directions, and it **strips JS comments
  before reading** — the file now explains `tsconfigRootDir` in eleven comment
  lines, and the check's first version matched one of those and went red on a
  correct config. "A check that can be satisfied by a comment is not a check" has
  a mirror image that is worse: a check that can be **falsified** by one.
  Breakages **107 / 107b / 107c**.
- `tests/lint_test.sh` **runs** it, and writing those controls found three defects
  in them. The load-bearing one: **two `red` assertions proved nothing**,
  because the crash was also red, so the pair could not tell "the glob resolved and
  the linter found the bug" from "the glob matched nothing and ESLint exited 2
  anyway". Reverting kit's `tsconfigRootDir` left the file **22/22 green** until
  the assertions were moved onto the finding rather than the exit status. That is
  the same confusion as the defect itself — a red run that found nothing.

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

**A skip that cannot be seen is a silent pass**, so the opt-out is a printed
`SKIP` row naming the flag, a row in the skip tally, and a summary line naming
the claims the run did not exercise. A patch that deleted the live tiers outright
would satisfy an exit-status assertion and fail its name-the-skip one; that
asymmetry is the whole reason this is a `report SKIP` and not an absence. See
`live_check` in `tests/validate.sh`.

**There is no self-test, and there is no tree copy.** The suite used to prove
itself by making a full copy of this repository per "breakage", mutating the
copy, and running a whole gate against it. That is gone — see
`CUT-ALL-DISPOSITION.md` § "The breakage layer is RETIRED". A **throwaway
fixture directory** is not a tree copy and is still how the checks that need one
work: the secret scanner plants its credential in a ~4 KB temp git repo, the
lint gate builds a service-shaped fixture, and both are swept on exit. What is
banned is copying *this tree* so the gate can be run against a modified version
of itself.

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
  Plus the workflow-shape half of that audit: no workflow declares a dangerous
  trigger, read off the parsed trigger keys so the comment explaining why is not
  itself a violation.
- **telemetry** — the six W3C traceparent suites are **executed**, one per
  language, and the canary harness is **executed** with all five vectors, each
  printing its own red proof. Stdlib only and offline on purpose. If they ever
  need the network, a template has grown a dependency and kit has stopped being
  config-only.
- **classifier + fingerprint** — both **executed**, not parsed, and deliberately
  outside the `RUN_STATIC` guard: a check that only parsed those two files would
  pass on a classifier that waves every change through.

## Secrets

**kit does not scan committed history, of this repository or anyone else's.** It used
to: a full-history secret scan ran as a `secrets` job that no service could opt out
of. `DECISIONS.md` MD34 records why it is gone — a control whose subject is somebody
else's repository is not one kit owns — and what replaces it, which is the host's
push protection catching the credential on the push that introduced it.

What kit still asserts about CI shape is one rule, and it is checked here:

- **No `pull_request_target`, `workflow_run` or `issue_comment`, anywhere.** Each
  runs with the base repository's secrets and a writable token on a *fork's* code,
  and each is the edit that turns a CI check into a credential-theft primitive. It
  is read off the **parsed trigger keys**, so the comment explaining why the rule
  exists is not itself a violation of it.

The `--redact` and `fetch-depth: 0` properties went with the scanner. `zizmor` and
the trigger check are what remain, and both are about the workflow a service already
wrote rather than about a neighbour's history.

**`DECISIONS.md` records a trade this repository has NOT made.** zizmor's
`unpinned-uses` fires thirty-three times and is **not** baselined: it is counted
and printed on every run, and `tests/validate.sh` fails if anyone adds it to
`.github/zizmor.yml`. A baseline there would be making the trade invisibly, in a
file that looks like routine configuration. If you add *any* zizmor ignore
entry, it needs a reason in a comment beside it, and the gate checks.

**`templates/secrets/` answers the question nothing off the shelf answers: does a
secret leave the process while the tests run.** gosec, Bandit, Brakeman and Semgrep
were all checked first, and none of them does:
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

**Why the canary is assembled rather than written out.** kit-16's deploy suite
proves the redactor scrubs a JWT **by shape** — a value the filter cannot know by
name, which is the only canary that can fail — so that token is committed and it is
credential-shaped. The distinguishing property is not that it is scoped somewhere;
it is that the string is a **fixture whose name says so** (`JWT_CANARY`, and its own
comment says a value the redactor cannot know by name is half the test) rather than
a credential-shaped blob wearing a descriptive variable name.
`templates/secrets/`'s canary does not have that option: a redactor can be taught
nothing and still be defeated by a string it does not recognise, but a leaked
credential does not become safe because a test asserts on it. **The rule stays:
assemble the canary, do not commit it.**

- **observability** — the claims that are worth nothing unexercised: a canary
  secret in ten leak shapes reaches no exporter (and the allowed data survives),
  a service starts, serves and reports healthy with the collector killed, the
  fetched stack runs, a service cannot reach another service's database, and
  **the account boundary holds with its `FORCE` control**. The last two need a
  real Postgres rather than a real collector, and they live in this phase for the
  same reason: a security property that nothing executes is worth nothing. They
  SKIP loudly without docker — never pass silently.
  - **`tests/onecluster_test.sh`** is the one-cluster claim asked of `bin/dev`
    rather than of a compose file, so it runs in this phase beside its two
    siblings. `isolation_test.sh` brings its own stack up with its own
    `docker compose` call, which is why it can move one port and start one
    container — the property was proven and the **developer's path to it** was
    not, since every step between a person and that cluster lives inside
    `bin/dev`. It runs a full `bin/dev up` with `KIT_POSTGRES_DATABASES=alpha,beta`
    and asserts on the world afterwards, including both services answering a real
    query **as their own role** and neither reaching the other's database.
    **The negative half is matched against the refusal text**, not against a
    non-zero exit, because a cluster with no second service also refuses.
- **`tests/failfast_test.sh`** is the **wall clock** claim, and it is a
  measurement rather than a shape: a compose file needing a variable with no
  default must be refused in **seconds, by name, with nothing started** — so the
  elapsed time is read from `date +%s` and the container list is read back **by
  compose project label**. Its control is what carries it: with the variable set
  the run must actually reach compose, or the whole suite is satisfied by a
  preflight that refuses unconditionally. Docker-gated, and a machine with no
  daemon gets one `SKIP` naming the flag rather than a wall of failures that all
  say the same missing thing — **"no container was created" is itself the claim**,
  so a silent skip here would be the defect the suite exists to catch.
- **classifier + fingerprint** — the change classifier and the fingerprint record
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
- **The suite has no self-test, and that is the decision, not an omission.**
  It used to have one: ~120 "breakages", each of which made a full COPY of this
  repository, mutated the copy, and ran a whole gate against it to watch it go
  red. The owner asked for no tree copies at all, and a breakage cannot exist
  without one, so the layer is retired whole — `tests/self_test.sh`,
  `tests/shard_test.sh`, and every check that existed only to police them.
  Measured cost of what went: `$WORK` was created once and swept only by an EXIT
  trap, so 104 copies × 25 MiB sat live simultaneously — **24 GiB** of leftovers
  found in one TMPDIR on this machine, and 17.5 GiB at load 48 across seven
  concurrent runs.

  **What a check does instead is a fixture, and the distinction is not a
  euphemism.** A fixture is a directory this repository *builds* to hold one
  planted value: the secret scanner's ~4 KB git repo, the lint gate's
  service-shaped tree, the tenancy substrate. It never contains this repository,
  and nothing runs the gate against a modified version of itself.

  **The eight behaviours the self-test existed to protect are all still
  protected, and each was proved able to go red without a copy.** `README.md`
  and `CUT-ALL-DISPOSITION.md` carry the table; the short form is that the
  postgres tag, the cluster topology, the connection budget and the account
  boundary are all direct reads of the real tree, so a defect is a one-line edit
  and a `git checkout` — measured, red, restored. The secret scan, the canary
  literal and the canary output are proven against fixtures the checks assemble
  themselves. The lint gate is proven by construction: every assertion in it is
  an assertion that a linter REJECTS the fixture. The GREEN control is now what
  it always should have been, an ordinary gate run.

  **What is genuinely gone: nothing can prove the gate is ABLE to fail any
  more.** A check that has never been seen red is a claim in a comment, and this
  file is full of lessons about checks that had gone blind while still printing
  PASS. That is an honest gap and it is named here rather than papered over.
- **A toolchain's floor is checked against the floor the ARTIFACT declares.**
  `KitOtel::RUBY_FLOOR` says what `templates/otel/ruby` needs and the gate reads
  that constant rather than restating the number. Below the floor is a loud,
  counted `SKIP` naming both versions — never a `FAIL`, because the template is
  correct and the interpreter is old, and never a `PASS`, because thirteen
  unexecuted tests are not a pass. `templates/otel/ruby` is the only one of the
  six that needs this: the other five refuse an old toolchain themselves, at
  build time, with a message naming their own requirement. Ruby 2.6 is the only
  one that loads the template happily and raises on first use.
- **A needle, when something asserts a check went red, must be the LABEL, not
  the finding's wording.** `FAIL $want` has to match the check's **label** —
  not the text of its finding and not a paraphrase. Two failures on kit-22, both
  from recipes whose *check* was correct:
  - Breakages 75/76/77 asserted the finding's text
    (`"which is the image kit's stack already ships"`,
    `"promises a command the script does not dispatch"`). Those strings are
    printed as **indented detail lines under** the `FAIL <label>` header, so
    `FAIL $want` never matched and all three reported "the gate went red, but NOT
    via …" **while printing the needle two lines above the complaint**. A check
    that works, a mutation that works, and a recipe that cannot tell either from
    a failure.
  - Breakage 71 asserted `the connection budget  (max_connections covers` against
    a label that read `max_connions` — a misspelling of a setting that does not
    exist, in the one line a reader greps for to learn what a check measures.
  - So: the needle is the label, and **a label that something asserts is a
    contract.** Renaming one silently un-proves whatever asserted it. When
    something reports "red, but not via `<label>`", read the actual FAIL line
    before assuming the check missed the defect — all three failures above were
    in the assertion, not the check.
- **A `BOUND` tier is a verdict about the RUN, and it is not evidence about the
  checks it never reached.** A heavy tier that hits its time bound reports
  `BOUND`, which is neither a pass nor a skip, and the summary line says so: the
  point of the run is to reach the end and announce it, and a bound reported as
  a pass is the silent skip this file forbids. A bound reported as a failure is
  no better — it is indistinguishable from a defect in the tree. Four counts,
  because they are four different claims: `PASS`/`FAIL` are verdicts about the
  tree, `SKIP` about the environment, `BOUND` about the run.
- **A green control that two different checks could satisfy proves neither.**
  This is the `reportUnusedDisableDirectives` rule's other half, and it was
  violated by kit's own self-test before that was retired. The rule above is about
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
    for that shape. A `printf … | grep` that only **prints** diagnostics is fine,
    where a truncated line costs nothing — and that difference is the whole test
    for which is which.
- **THE FLEET IS FOUND BESIDE THIS REPOSITORY, and never further.** The checks
  that read service trees glob `$ROOT/..`, so they reach exactly one level of
  siblings and no more. `../..` is deliberately NOT searched: it found a fleet
  once, in a leftover copy of a cafaye repository in a shared temp directory
  whose branch still carried a retired workaround, and a check went red on a
  tree with nothing wrong with it. **A sweep that reaches further than it owns is
  worse than no sweep**, and the same argument now covers the self-test copies
  this repository used to make: a copy has no fleet beside it, which is a limit
  to report and not one to route around.
- **A MUTATION MUST ASSERT ITS OWN PREMISE BEFORE IT MUTATES.** kit-14 had two
  wrong recipes and the suite caught both: one named an artefact id the declared
  table did not actually carry, so the mutation broke nothing, and one asserted
  that a check would go red when no such check existed here. A mutation that has
  silently stopped breaking the thing it names is a proof of nothing. The harness
  that taught this is retired, and so is the table; the rule is not.
- Tests are written **first** and watched fail before the artifacts exist. A
  config written from documentation instead of from the pinned image is a config
  that breaks on the first `bin/dev up`: Tempo, Loki and Mimir all reject keys
  with messages that name a Go type rather than a config key. Every vendor
  config in this repo was verified by loading it into its image.
- **Never weaken a check to make the gate green.** If a check is wrong, fix the
  check and say so in the commit message.
- `shellcheck` and `node` run when installed and are skipped when not. A skip is
  reported in the summary, never hidden. The **lint** phase is the exception and
  is fatal on a skip: the claim under test is "kit's configs work", and a run in
  which no linter executed has not tested it.
- **PyYAML, yamllint, zizmor and hadolint are required and are bootstrapped, not
  required of you.** `tests/bootstrap.sh` resolves an interpreter, builds
  `.venv`, pip installs `tests/requirements.txt`, and fetches pinned hadolint
  and the pinned hadolint release verified against its published checksums.
  pinned in `requirements.txt` and comes from PyPI, because it publishes no
  checksums file and pinning its archives would mean pinning hashes we computed
  ourselves. Resolve
  order: `$KIT_PYTHON` (an override is a promise — if it cannot import yaml
  the gate says so rather than silently substituting a different one), then
  `.venv`, then any `python3` on PATH that already has PyYAML, then bootstrap.
  A required check whose tool path is hardcoded to a directory the resolver may
  have skipped is a gate that fails on arrival; that is a bug this file has
  already had once.
- **The language toolchains are found through mise, not assumed to be on PATH.**
  `kit_activate_mise` runs before anything resolves an interpreter. It is
  `eval "$(mise hook-env -s bash)"` — mise's own supported way to hand a shell
  that was never activated the environment it would otherwise have had — and it
  is a no-op when mise is absent, when the shell is already mise-activated, or
  when mise has nothing configured, which is the CI case. This is the same class
  of fix as the interpreter resolution above and it was needed for the same
  reason: `.zshrc` and `.zprofile` put mise on PATH for *interactive* and *login*
  shells, so `bash tests/validate.sh` — which is neither — saw no `gofmt`, no
  `go`, and no `rubocop`, and reported a machine that was fully equipped as one
  that was missing three toolchains. A skip that is really "you launched me wrong"
  is a false negative, and this gate is fatal on lint skips, so it was a red
  build too. mise owns the versions; the gate only asks it what the environment
  was. kit deliberately ships no `mise.toml` of its own: pinning kit's
  toolchain here would be a second source of truth a runner with no mise config
  could not honour, and `templates/mise.toml` is where that decision belongs.
- **Four counts, because they are four different claims.** `PASS` and `FAIL`
  are verdicts about the tree. `SKIP` is a verdict about the **environment** —
  no docker, no toolchain, nothing ran. `BOUND` is a verdict about the **run** —
  the tier started, this machine was too busy to finish it, and the claim it
  exists to prove is therefore unexercised. The heavy tiers — the docker stacks,
  the cluster tiers, the lint phase — carry a time bound for exactly this
  reason: a gate SIGKILLed by the OOM killer reports nothing about
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
  they get different verdicts: an environment failure and a missing toolchain
  are different facts and must not be filed as one. Collapsing them is how a busy
  machine gets filed as a weakened check. The test
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
- The suite must be able to fail, and there is no longer anything that proves it
  for us. The self-test that did — by copying the tree once per breakage — is
  gone by decision, because a copy of the tree is exactly what the owner asked
  not to have. What remains is the eight behaviours above, each verified against
  the real tree or a fixture, and each still goable-red by editing the tree and
  restoring it. When you add a check, that is the price of it: nobody will
  automatically try to break it, so you must.

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

## The reporter is gone, and the vocabulary went with it

`tests/staleness.py` had two scopes. `--scope core` measured a **pin**; the one
kit already had. `--scope templates` measured a **file**, and a file has a state a
pin does not have: it is not there. Five states, and the vocabulary was the whole
design — `current`, `diverged`, `absent`, `unknown`, `n/a` — with `absent` there
because the commonest state in the fleet was a service holding nothing.

**Both scopes read repositories beside this one**, so both went with MD36. So did
the two files that existed only to serve them: `tests/artifacts.json`, the table
of what kit ships and where a service puts it, and `templates/parity-allowlist`,
which carried eighty entries each naming a divergence in a repository kit cannot
see. Between them they were the largest remaining piece of kit reading other
people's trees, and neither had a consumer left once the reporter did.

What is worth keeping from that work is not the reporter. It is the sentence
underneath it: **never infer a copy from its content.** There is no similarity
threshold, no percentage, no "closest match", and no search for a file that hashes
to kit's artefact. That was the tempting alternative — a `quick_ratio() > 0.99`
score is the shape a helpful contributor reaches for — and the reason it is wrong
is that it is unfalsifiable by the thing it is measuring: a ratio that says "close"
cannot be argued with about what close means. If a check like that is ever written
again, in kit or in a service, that is the sentence to read first.

The rest is now advice rather than a control, and the honest description of that
is that nothing enforces it.

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

`bun` is the worked example: it was added because `gateway` carried a standing
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
  caught by the binaries within one run each. Each of the three was found this
  way, once, and the mechanism is what found them.
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
catches a JWT by shape lives. That is a larger decision than this packet,
it is recorded in
`REPORT-kit-20` §"not removed", and it is not resolved here.

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
  `REPORT-kit-version-recipe-drift-01` and `CHANGELOG.md`.

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
copy, and kit has no registry to hold one — the file that used to, recording
eighty fleet-wide deprecations, went with the reporter it served.

**The fourth hygiene rule is INVERTED here.** In a skip allowlist, an entry
matching nothing is a ratchet that only turns one way. For a tombstone the dead
entry and the live name are one defect with two names, so `reserved_check` fails
when a reserved path **exists**. It is silent otherwise, and it permits nothing.
See `DECISIONS.md` (MD26, MD27).

## Rules

- **Config only.** No runtime code, no dependencies, no generated output. If
  kit grows a dependency it has stopped being conventions.
  - **The one carve-out, and why it is a carve-out rather than a precedent.**
    `core/` ships a change classifier, which is a program rather than
    configuration. It is here because a standard without a thing that enforces
    it is a standard enforced by whoever reads it. It stays inside the boundary
    deliberately: **standard library only, no installable dependency**, and
    **nothing imports it** — the real test of this rule is that nothing here is
    a library, and a classifier is not. If a second program is proposed, the
    default answer is no. The other two that were here, a staleness reporter
    and a fingerprint record, no longer are: both read repositories beside this
    one, and a program whose subject is somebody else's tree is not this
    repository's business whatever else it is.
  - **Every program in `tests/` is stdlib-only, and that is now a convention
    rather than a control.** Three remain — `classify.py`, `fingerprint.py` and
    `profile_report.py` — and between them they import `argparse`, `glob`,
    `hashlib`, `json`, `os`, `sys`, `time` and `__future__`. There was a
    `carve-out boundary` check that walked the AST of every Python file here and
    asserted each module it found was named in this paragraph; it went with the
    cross-repo programs, and this paragraph outlived it, which is the failure
    mode this repository keeps warning about in other places. So nothing
    enforces the list now, and the honest description of that is that nothing
    enforces it. That is defensible only because the population is three files
    and every import is stdlib: a reader adding a fourth is trusted to have read
    this bullet.
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
  normalised format are `cafe gate`'s — runtime code, in a runtime repo. If you
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

  **The check is stale against the grant, and that is named rather than hidden.**
  kit's grant was the Cafaye proprietary text until OPS-D2 made the framework
  MIT (2026-10-10); `license_check` still asserts the proprietary sentences and
  still refuses MIT's permission grant, so the gate is red on exactly that one
  check. **Do not weaken it to get green** — the grant is the file and the check
  is what has to move, in its own commit, with a reason. The successor's move is
  to re-point the three required phrases and the README assertions at MIT, to
  keep the two-direction shape (the file grants MIT; the `## License` section
  states MIT and links it), and to keep point 4 exactly as it is: `cafaye.yml`
  declares no licence field and core's schema has no key for one, so "manifests
  inspected, none disagreeing" is still the measurement the check prints.
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

## Secrets
- No `.env` files with values. Use `cafe secret set/get/list` (dev) and `cafe dev` (injects). See `docs/secrets.md`.

## Packet identifiers

`REPORT-x`, `HANDOFF-x` and `MEASUREMENTS-x` name **work packets, not
files**. The written reports were removed on 2026-10-20: duplicated across
repositories, owned by nobody, rotting faster than they were read. What
survives of a packet is its entry in `CHANGELOG.md` and, where a decision was
made, in `DECISIONS.md`. A citation to a packet id points at that entry.
