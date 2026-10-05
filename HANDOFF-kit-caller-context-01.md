# HANDOFF — kit-caller-context-01

**Status:** both defects fixed in this repository, measured, checked, and proved
falsifiable. Four commits on `worker/caller-context-01`, based at `ad3e320`.
**Not pushed; the manager merges.** **No repository outside this one needs a PR**
— the reason is in *What a run must still settle*.

Base recorded at cut time: `ad3e320af75a98e2c067d213229b63aaad584d3d`
("Merge worker/reusable-workflow-01: the reusable workflow asked for the caller's
own lock"). That commit was read, not re-derived, and not reverted.

---

## Your first move, exactly this

**Push `master`, then open a `ci` run in `cafaye/site` or `cafaye/parlor` and
read two jobs: `ci (kit, node) / node` and `… / secrets`.**

```
gh api repos/cafaye/site/actions/runs/<RID>/jobs \
    --jq '.jobs[] | "\(.name) | \(.status)/\(.conclusion)"'
```

Before this branch, both read `completed/failure`, and the two log lines to look
for are the ones quoted below. After it, `secrets` should go **green**, and
`node` should stop dying with `Oops! Something went wrong! :)`.

**`node` going red with real ESLint findings is a SUCCESS here, not a
regression** — see *What a run must still settle*.

---

## Defect 1 — `GITHUB_ACTION_PATH` is unbound

### The evidence

```
$ gh api repos/cafaye/site/actions/runs/37236386666/jobs \
    --jq '.jobs[] | "\(.name) | \(.status)/\(.conclusion)"'
bin/prime                    | completed/success
typecheck + build            | completed/success
ci (kit, node) / language    | completed/success
ci (kit, node) / node        | completed/failure
ci (kit, node) / secrets     | completed/failure
```

```
/home/runner/work/_temp/9bf3851b-….sh: line 2: GITHUB_ACTION_PATH: unbound variable
##[error]Process completed with exit code 1.
```

`cafaye/parlor` run `37230458669` is identical. **Both jobs had never executed
once** — `ad3e320` fixed the concurrency collision that had stopped them being
created, and these are the fleet's first real CI signal for them.

Reproduced locally, with the workflow's own two lines and nothing else:

```
$ bash -c 'set -euo pipefail; . "${GITHUB_ACTION_PATH}/tests/bootstrap.sh"'
sim-secrets.sh: line 2: GITHUB_ACTION_PATH: unbound variable
exit=1
```

### Which jobs, measured — the brief asked

| job | had it? | why |
|---|---|---|
| `secrets` | **yes** | lines 1372 / 1375 / 1391. Measured: run 37236386666. |
| `zizmor` | **yes** | line 1430. **Never seen failing in the fleet**, because it is gated on `inputs.zizmor` and no caller sets it. Fixed in the same place. |
| `telemetry` | **yes** | line 1303, the fallback to kit's own copy of the conformance suite. Also gated, also never run. Fixed in the same place. |
| the seven language jobs | no | they already used `uses: actions/checkout`. |

**`zizmor` had a SECOND defect, found by reading the script rather than the
workflow.** `tests/zizmor_gate.sh` ends by piping zizmor's JSON report through
`"$PY" - …`. In kit's own gate `$PY` comes from `kit_bootstrap_python`; a
reusable workflow makes no such call, so the job would have reached the script's
**last line** and died there:

```
$ env -u PY bash -c 'set -euo pipefail; "$PY" -c "print(1)"'
bash: line 1: PY: unbound variable
exit=1
```

That is the same mistake as the first wearing a second hat: a script written to be
called by one caller and run by another that had not been read.

### The fix, and why it is a fix rather than a suppression

`uses: actions/checkout` of `cafaye/kit` pinned by `inputs.kit-lint-ref` — the
mechanism the six language jobs already use — landing in **`$RUNNER_TEMP`**, not
`<working-dir>/.kit`.

**Why `$RUNNER_TEMP` and not `.kit`.** `secrets` runs a full-history git scan
rooted at `$GITHUB_WORKSPACE` (`fetch-depth: 0`, `--log-opts '-p -U0
--full-history --all'`). A second git repository inside the tree being scanned is
a nested-repository question with no good answer, and `.kit` is the obvious place
to put one because it is where the lint configs go. `$RUNNER_TEMP` is per-job
scratch space, emptied at the end of the job — exactly this file's lifetime.

**Why this is the fix and not a suppression.** A suppression would be
`continue-on-error`, `${GITHUB_ACTION_PATH:-}`, or making the variable optional.
Every one of those leaves a job that **cannot scan** and calls it a pass. The
`secrets` job is the one job in this file with **no opt-in**, described in
`AGENTS.md` as the only control a service cannot choose not to run; a scanner that
runs on nothing is the failure this repository is most explicit about. There is
no floor to move, no rule to relax, and no threshold involved — the job now does
the scan.

**The file already said this.** The `kit-lint-ref` input's own comment names
`GITHUB_ACTION_PATH` as composite-action-only and explains that kit's configs must
be **fetched by a name**. Five lines in three jobs then contradicted it. The
reasoning was applied to the lint configs and not to these five: *a rule written
down once, obeyed in one place, and contradicted in another by nobody reading the
other place.*

---

## Defect 2 — the shared ESLint config

### The evidence

```
$ gh api repos/cafaye/parlor/actions/runs/37230458669/jobs \
    --jq '.jobs[] | "\(.name) | \(.status)/\(.conclusion)"'
ci (kit, node) / node | completed/failure
```

```
Error: Error while loading rule '@typescript-eslint/await-thenable':
You have used a rule which requires type information, but don't have
parserOptions set to generate type information for this file.
```

Reproduced locally against a fixture shaped like `site` — a root-level `.mts` file
and a tsconfig that includes it:

```
$ ./node_modules/.bin/eslint --config .kit/lint/eslint.config.mjs ./vite.config.mts
Oops! Something went wrong! :(
ESLint: 9.39.5
Error: Error while loading rule '@typescript-eslint/await-thenable': …
Occurred while linting …/vite.config.mts
exit=2
```

Both services carry **three** root-level `.mts` files — `vitest.config.mts`,
`vite.config.mts`, `vite.node.config.mts` — so this was never marginal. Both
tsconfigs include `**/*.mts`.

### THE REPORTED CAUSE WAS WRONG, and this is the most useful thing here

The brief attributes it to `tsconfigRootDir: import.meta.dirname` — kit's `lint/`
directory rather than the caller's. **That is a real misconfiguration and it is
fixed. It did not produce this error.** Measured on eslint 9.39.5 /
typescript-eslint 8, with `projectService: true`:

| `tsconfigRootDir` | result on the same fixture |
|---|---|
| `import.meta.dirname` (shipped) | `Oops`, exit 2 |
| `/nonexistent-root` | **byte-identical** |
| deleted entirely | **byte-identical** |

The project service walks **up from the linted FILE** to find a tsconfig. It never
consults the root. So *a check written for the reported cause would have been
green on the defect that actually shipped.*

**The real cause is a glob mismatch:**

```
kit's `files`                          **/*.{js,mjs,cjs,ts,tsx}
typescript-eslint/eslint-recommended    **/*.ts, **/*.tsx, **/*.mts, **/*.cts
recommendedTypeChecked (the rules)      no `files` at all
```

The config inside `recommendedTypeChecked` whose `files` names `.mts`/`.cts`
**adds** them to the set of files ESLint will lint; `recommendedTypeChecked`
itself is **unscoped**, so the type-aware rules land on every linted file. Kit's
own `files` supplied `parserOptions` — the only source of type information — to a
strictly *narrower* set. So every `.mts` file was linted, was given the rules, and
was never given what the rules require. `@typescript-eslint/await-thenable` is
simply the first rule constructed.

**The general rule, and it is the one worth keeping: `recommendedTypeChecked` is
UNSCOPED, so `files` is load-bearing.** The file's own header used to warn that
`files` must be scoped or the config "slowly turns into a second tsconfig". That
was half a warning: the scope has to be at least as *wide* as the recommended
sets, or type-aware rules land on files that were never given type information.

### The fix

1. `files` widened to `**/*.{js,mjs,cjs,ts,tsx,mts,cts}`.
2. `tsconfigRootDir` → `process.cwd()`.
3. `.jsx` **deliberately left out**, and that is a decision rather than an
   oversight: nothing above adds `.jsx` to the linted set, so adding it would
   widen kit's lint in every service, and no `.jsx` file is in anyone's tsconfig —
   every React repo would go red with `was not found by the project service`
   (measured). A React service's components are `.tsx`.

**Why `tsconfigRootDir` is fixed even though it was not the cause**, because it is
load-bearing in exactly one place and it is a place kit would otherwise reach for:
**`allowDefaultProject` globs are matched relative to it.** Measured in
`useProgramFromProjectService.js`:

```js
const filePathRelative = node_path_1.default.relative(parseSettings.tsconfigRootDir, filePathAbsolute);
const isDefaultProjectAllowed = filePathMatchedBy(filePathRelative, serviceAndSettings.allowDefaultProject);
```

With kit's directory as the root, a pattern meant to cover the caller's own root
config files resolves to `.kit/lint/*.mts` and matches nothing — and the error
names itself:

```
allowDefaultProject is set to ["*.mts"], which does not match '../vite.config.mts'
```

So it is a **latent** misconfiguration, invisible until the first
`allowDefaultProject` entry is added, which is exactly the kind this repository
does not carry.

**Why `process.cwd()` and not a workflow input**, per the brief's constraint about
conditional fixes. ESLint resolves files relative to its base path and walks up
from the CWD looking for a project root, so the caller's workspace **is** the CWD
by the time the config is read — the lint step already carries
`working-directory: ${{ inputs.working-dir }}`, and `tests/lint_test.sh` asserts
that requirement rather than describing it. An input would mean thirteen
repositories needing a PR to be told where they already are. It must be absolute
(measured: a relative value is rejected with `parserOptions.tsconfigRootDir must
be an absolute path`); `process.cwd()` always is.

**On `working-dir`: it is `.` in the fleet, and this fix does not depend on
that.** The value is never read. `site` and `parlor` both pass `working-dir: .`,
but the mechanism is `working-directory:` on the step, so a caller with
`working-dir: services/api` gets `services/api` as the root with no change here.

---

## The one root cause both defects share — stated, with the caveat

They share a **class**, not a cause, and the class is worth more than a shared
cause would have been:

> **kit's shared assets resolve against kit's own checkout, but a reusable
> workflow executes in the caller's context.**

Both symptoms are a path that named something in kit rather than something in the
caller. **But the mechanism differs and only one of them is a *lookup*:**

| | defect 1 | defect 2 |
|---|---|---|
| kit named | a *directory* (`GITHUB_ACTION_PATH` → `templates/`, `tests/`) | a *set of extensions* (`files`) and a *root* (`tsconfigRootDir`) |
| what went wrong | the path expanded to nothing — the variable is never set | the path resolved fine; the set was **too narrow** and the root was **inert** |
| observable as | `unbound variable`, exit 1, line 2 | `exit 2` before any finding |

I could not make these one cause honestly, and I did not try to. The stronger
statement is the shared one: **both were invisible because nothing in this
repository ever RAN them.** `lint/` sat behind `yaml.safe_load` and `node --check`
for two packets; the `secrets` job sat behind a YAML parse, and an unexpanded
variable is a perfectly good string. The reason there was no check to fail is not
carelessness — **a reusable workflow genuinely cannot know its own path**
(`github.workflow_ref` is the CALLER's workflow, and `github.action_path` is the
composite-action-only variable again). That is why the fix for defect 1 is a
*fetch by name* rather than a variable, and why a static reading could never have
caught either.

---

## What I found and did NOT fix

1. **`allowDefaultProject` conflicts with a tsconfig that covers the file.**
   Measured: a caller whose tsconfig includes `**/*.mts` **and** whose config sets
   `allowDefaultProject: ['*.mts']` gets
   `was included by allowDefaultProject but also was found in the project service`
   — a hard error. So `allowDefaultProject` cannot be kit's unconditional answer
   to "a root config file is outside my tsconfig", and I did not add it. Left for
   whoever hits a caller whose tsconfig genuinely excludes its own root configs;
   the trade is recorded in the config's header.

2. **`.jsx` is still a gap, deliberately.** See above. It is a fleet lint-policy
   decision, not kit's to make silently.

3. **`zizmor_gate.sh` still takes `$PY` from its caller.** I exported `PY:
   python3` in the workflow, which is the smallest change that makes the job work,
   but the underlying contract — a script that reads a variable its caller must
   set, with nothing saying so — is untouched. A `kit_bootstrap_python` call in
   the job would be the fuller fix; it also bootstraps a venv the job does not
   need. Flagging rather than deciding.

4. **`secrets` scans `$GITHUB_WORKSPACE`, not `inputs.working-dir`.** Every other
   step in the file is scoped to `working-dir`. For the eleven callers today
   (`working-dir: .`) these are the same directory, so it is not a live defect —
   but a caller with `working-dir: services/api` would get its **whole
   repository** scanned rather than the service. Out of scope, untouched, and
   named here because it is the same shape as the two defects above: a path that
   names the wrong thing.

5. **`templates/otel` fallback still uses `KIT_TELEMETRY_LANG`**, a variable
   nothing sets, as a `${…:-…}` default. Harmless (the default always applies) but
   dead. Left alone: it is not a defect, and removing it is churn.

6. **Two fleet checks are red and are not mine**: `generated stack` and
   `in-scope repositories`. Verified **in place** on the base commit and after,
   with the same fleet beside the tree, byte-identical output both times. The
   brief's three (`otel/go/otelhttp.go.snippet`, `lint drift`, `the canary suite`)
   are **green** on this base; none is touched by this diff.

---

## What a run must still settle

Five things only a GitHub runner can answer. Each is a claim this branch makes
that has been verified on a laptop and not on a runner.

1. **`${{ runner.temp }}` is usable as an `actions/checkout` `path:` inside a
   reusable workflow.** Context availability permits `runner` in
   `jobs.<job_id>.steps.with`, and `RUNNER_TEMP` is a documented default variable
   in every `run:` body, so both spellings are sound on their face — but no job in
   this file had used either. **This is the load-bearing unknown: if it does not
   resolve, all three fixes fail the same way.** First thing to check on the run.
2. **The `secrets` job goes green.** Specifically that `gitleaks_gate.sh` resolves
   its config from `$KIT_TREE_DIR/tests/../.gitleaks.toml` and that
   `kit_bootstrap_binary` can write into `$KIT_TREE_DIR/tests/.bin` — a
   **sparse** checkout, so `tests/.bin` is being created inside a sparse tree.
   Measured locally that the script's two-step config resolution works from a
   sibling location; not measured on a runner.
3. **The `node` job stops crashing — and may go red on real findings.** With the
   type-aware rules finally reaching `.mts` files, `site` and `parlor` will get
   their first genuine `recommendedTypeChecked` verdicts on `vite.config.mts` and
   friends. Those are **new findings on files that were never linted**, and some
   will need `// eslint-disable` or a tsconfig change in *those* repositories.
   **A red `node` job with ESLint findings is this branch working.** A red one
   still dying with `Oops! Something went wrong` is not.
4. **`zizmor` runs at all.** No caller sets `inputs.zizmor`, so this branch's
   `zizmor` repair has **never executed**. Turn the input on in one repository and
   confirm the job completes rather than dying on `PY: unbound variable`.
5. **`self_test` reaches breakages 106-107c in a full run.** On this machine
   `KIT_SELF_TEST_SHARD=1/107` was **SIGKILLed**, so the shard could not be used.
   Per `AGENTS.md`'s `BOUND` rule, each of the eight recipes was therefore verified
   **by hand** on a `git archive` copy with the real gate and the check's label as
   `--only` — seven red, 106e green, each reported with the exact `FAIL <label>`
   line `expect_red_check` matches on. A green shard on a roomier machine is the
   confirmation; a `BOUND` verdict here is about the machine, not the recipes.

---

## The checks, and the three defects found while writing them

Neither check existed before this branch. Both were written by running their
mutations, and both were wrong first.

**`kit_gate_tree_check`** — no `run:` body reads a composite-action-only
variable; a step reading the fetched tree has a `cafaye/kit` fetch above it; every
checkout is pinned **by `inputs.kit-lint-ref` and not to a literal** (`ref: master`
is what the input evaluates to when a caller sets nothing, so it looks pinned and
is not).

- It **failed seven jobs that were correct.** It first keyed on the path
  substrings `tests/` and `templates/`, and every language job prints
  `See templates/tier/README.md` in an error message while running the *caller's*
  own gate. Restated as a **coupling** — the variable that means "the directory the
  fetch put it in" — and breakage **106e** is the green control for exactly those
  seven jobs. A check that fires on correct work teaches its reader to ignore it.
- The pin was first asserted **inside a per-step loop**, so it reported one
  unpinned checkout once per reading step and would have passed *entirely* for a
  checkout no step referenced. A check whose coverage depends on an unrelated step
  has a hole shaped like the defect it exists for. Breakage **106c** found it.

**`eslint_typed_scope_check`** — every extension the recommended sets can lint is
present; an extension with no stated reason is a finding; `tsconfigRootDir` is the
caller's.

- It **went red on a correct config.** It read `tsconfigRootDir` out of a
  **comment** — the file now explains that value in eleven comment lines, and the
  regex matched the first. AGENTS.md's "a check that can be satisfied by a comment
  is not a check" has a mirror image that is worse: a check that can be
  **falsified** by one. It strips JS comments now, tracking string contents so a
  `//` inside a quoted glob survives.

**`tests/lint_test.sh`** gained six assertions and three controls that **run** it,
because a static reading of a glob cannot tell a set that covers the linted files
from one that does not. Two of those controls were wrong:

- Asserting the pre-fix glob is **red proves nothing** — the crash was also red,
  and was mistaken for the linter working. The control now requires the crash *by
  its own message* and requires the fixed glob to report a real `eqeqeq`.
- The `allowDefaultProject` pair had the same defect: **both runs exit non-zero**,
  so two `red` assertions could not tell "the glob resolved and the linter found
  the bug" from "the glob matched nothing and ESLint exited 2 anyway". Measured:
  reverting kit's `tsconfigRootDir` left the file **22/22 green**. Now asserted on
  the finding rather than the exit status.
- The control's `sed` matched a **comment** line ending in a backtick-quoted
  `*/`, closed a comment that was still open, and produced a syntax error instead
  of the failure it existed to produce — it would have "passed" a `does not match`
  assertion by failing to parse. Anchored on the `parserOptions` line, `.*`
  narrowed to `[^}]*`, and the control is now asserted to **parse**.

Breakages: **106, 106b, 106c, 106d, 106e** (green), **107, 107b, 107c**. Suite is
now 118 recipes, 115 red, 4 green.

**One harness defect, and it is this repository's own rule arriving in a new
place.** All eight recipes first asserted on each check's *detail line* rather than
its **label**, and reported `the gate went red, but NOT via …` plus
`--only='…' selected NO check out of the suite`. Three breakages in this file
already failed that way. The needle is the label, because the label is the only
stable string a check emits. Commit `b3ad420`.

---

## Files touched

| file | what |
|---|---|
| `.github/workflows/ci.reusable.yml` | 3 `kit (…)` checkouts; `GITHUB_ACTION_PATH` → `KIT_TREE_DIR` in 4 `run:` bodies; `PY` exported for `zizmor`; the `kit-lint-ref` comment extended to record that it was right and the code was wrong |
| `lint/eslint.config.mjs` | `files` widened; `tsconfigRootDir` → `process.cwd()`; ~70 lines of header recording the measured cause, the wrong diagnosis, and why `.jsx` stays out |
| `tests/validate.sh` | `kit_gate_tree_check`, `eslint_typed_scope_check` |
| `tests/lint_test.sh` | 6 assertions + 3 controls that execute the ESLint fix |
| `tests/self_test.sh` | breakages 106-107c, header counts |
| `CHANGELOG.md`, `AGENTS.md`, `README.md` | the two rules, the caller-facing half of defect 2, recounted totals |

## Commits

| sha | what |
|---|---|
| `83f160a` | defect 1 + `kit_gate_tree_check` + breakages 106-106e |
| `6abc3c2` | defect 2 + `eslint_typed_scope_check` + `lint_test.sh` proofs + 107-107c |
| `b3ad420` | the needle is the label |
| `8cd31ea` | AGENTS.md / README / recounted totals |

`concurrency:` in `ci.reusable.yml` is **untouched** — that is `ad3e320`, and
`reusable_concurrency_check` still passes. No floor was moved anywhere.