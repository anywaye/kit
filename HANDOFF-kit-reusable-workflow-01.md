# HANDOFF — kit-reusable-workflow-01

**Status:** root cause found, reproduced end to end, fixed in
`.github/workflows/ci.reusable.yml`, checked, and proved falsifiable. Not pushed;
the manager merges and pushes. **Nothing outside this repository had to change**,
and the reason is the first section.

---

## Your first move, exactly this

**Push `master`, then open any `ci` run in any caller and read its job list.**

```
gh api repos/cafaye/parlor/actions/runs/<RID>/jobs \
  --jq '.jobs[].name'
```

You are looking for a job ending **`/ language`**. That job is
`ci.reusable.yml`'s `language` gate, it has **no `if:`** on purpose, and it is
the signal that is not ambiguous: **no caller in the fleet has ever produced
one.** Its appearance is the whole fix, verified.

Before the fix, every one of those runs read:

```
typecheck + build | completed/success
bin/prime         | completed/success
$ gh api repos/cafaye/parlor/actions/runs/<RID> --jq '.conclusion'
failure
```

Both jobs green, the run red, `gh run view <RID> --log-failed` **empty** —
because no step failed and the job that mattered was never created.

---

## The root cause, with the command that shows it

**Caller and callee were asking for the same concurrency lock.**

Every caller in the fleet declares:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

and `.github/workflows/ci.reusable.yml` declared the **identical block** from
`8ebf4db` — the commit that first published the file, 2026-09-30:

```
$ git log --oneline -S'cancel-in-progress' -- .github/workflows/ci.reusable.yml
8ebf4db feat: kit artifacts, and a gate that only checks they parse
```

Inside a reusable workflow `github.workflow` is the **caller's** workflow name
and `github.ref` is the **caller's** ref — GitHub does not re-scope either to the
called file. So caller and callee both evaluated
`ci-refs/heads/master`. The caller holds the lock. The callee's request is
refused, and the `uses:` job is never created.

`core` spells it `${{ github.workflow }}-${{ ref }}`. Same value to GitHub,
different bytes — and it is the reason the check normalises.

### Reproduced, with one variable changed at a time

Byte-identical copy of master's file (git blob `f91df58`) in a throwaway public
repository, called from a second throwaway repository:

| caller's `concurrency.group` | jobs in the run | the `uses:` job |
|---|---|---|
| `${{ github.workflow }}-${{ github.ref }}` | **1** | **gone**, run `failure` |
| `caller-${{ github.workflow }}-${{ github.ref }}` | **13** | present |

Same experiment with the **fixed** callee (`kit-`-prefixed) and the caller left
on the fleet's exact spelling: **14 jobs, `ci (kit, node) / language => success`,
`ci (kit, node) / node` runs.** That is the fix, measured.

---

## What was NOT the cause, and how each was ruled out

The brief named three; all three were checked rather than assumed.

- **Not a workflow parse error.** The blob on `master` parses under
  `yaml.safe_load`, declares `on: workflow_call`, and declares all nine inputs
  (`language`, `kit-lint-ref`, `lint-args`, `working-dir`, `versions`,
  `coverage-fail-under`, `required-tier`, `telemetry`, `zizmor`). Zero tabs; no
  over-120 lines. Calling it **unchanged** produced all thirteen jobs.
- **Not an undeclared input.** Every caller's `with:` was resolved per job
  against the real declared set. `EXTRA=[]` for all eleven callers.
- **Not the `options:` key.** Absent, and `workflow_inputs_check` gates it.
- **Not the old path.** Every caller resolves `.github/workflows/`.

### The fleet's own control, which cost nothing to find

`image.reusable.yml` declares **no `concurrency` block at all** — same
mechanism, same org, same `@master` ref, same `permissions: contents: read`:

```
$ gh api repos/cafaye/identity/actions/runs/37220827008/jobs --jq '.jobs[].name'
image / build (and publish, if asked)
```

That job appears on every run. The one difference between the workflow that
works and the workflow that never ran is the `concurrency` block.

---

## What changed, and why it is the fix rather than a suppression

**One line, in the shared file:**

```diff
 concurrency:
-  group: ${{ github.workflow }}-${{ github.ref }}
+  group: kit-${{ github.workflow }}-${{ github.ref }}
   cancel-in-progress: true
```

It is a fix and not a suppression because:

1. **The job runs.** Measured: 1 job → 14 jobs, and the unconditional
   `language` gate appears.
2. **Nothing was skipped, relaxed or gated off.** No job was added, removed or
   given an `if:`. The jobs that now appear are jobs that always existed and
   never executed — including **lint**, which no repository in the fleet has run
   in CI.
3. **The cancel-on-supersede behaviour survives.** This was measured, because
   *deleting* the block is the other way to stop a collision and it trades a
   missing job for an unbounded pile of superseded runs:

   ```
   push A -> called job in_progress;  push B -> A's called job `cancelled`,
                                            run A `cancelled`
   ```

   The caller's cancellation propagates into the called workflow, so kit's block
   is a second layer rather than the only one. Renaming the group leaves it
   working.
4. **It repairs kit's own CI with no change to `ci.yml`.** `ci.yml`'s group is
   `ci-<ref>`; the callee's is now `kit-ci-<ref>`. Distinct.

### Why kit's side and not thirteen caller PRs

It is the only fix that reaches a repository nobody remembers exists, and it is
one reviewable line instead of eleven. The caller-side rule is documented
instead (`README.md` § *How a service repo adopts kit*, and the header of
`ci.reusable.yml`): **a caller's `concurrency.group` must not begin with `kit-`.**
Every other spelling is the caller's, including declaring none.

### The check, and why it is not the check `callable_check` already was

`reusable_concurrency_check` in `tests/validate.sh` asserts two separable
claims:

1. every standard kit hands out namespaces its group with `kit-`;
2. a caller must not **normalise** to the same expression as one of kit's.

(1) alone would not have caught the historical shape — a byte-identical group
*with* the prefix on both sides still collides, which is what 105b is. (2) is
read from kit's own `ci.yml` because kit is a caller of itself and held the
defect in **both** files at once. It is deliberately **not** a fleet sweep:
`fleet_check.py` already reads the repositories beside this one and reports a
loud SKIP when there are none, so a second reader of the same fleet would be a
second answer to a question kit already asks.

The gate was green for the whole four days and **every claim it made was true**:
the path resolved, `workflow_call` was declared, the inputs matched, the
workflow was valid. The defect is two valid workflows asking for one lock, and
the only place both sides are visible at once is the gate.

**Three breakages, 105 / 105b / 105c**, each one line in one file, each provable
only by its own branch. All three measured red:

| | mutation | fires |
|---|---|---|
| 105 | callee suffixes rather than prefixes | the prefix rule |
| 105b | a caller adopts the `kit-` prefix | the comparison |
| 105c | `ref` one side, `github.ref` the other | the normalisation |

**105 is deliberately not the historical revert.** Putting the bare group back is
the truest mutation available and it is the wrong one: in kit's own tree it also
collides with `ci.yml`, so it satisfies the comparison branch too, and a recipe
proving two branches proves neither. Measured — that spelling reports **both**
messages. The suffix is the shape a "make the group more specific" patch actually
takes, and it is unprefixed without colliding.

---

## Every repository affected

**Eleven, and none of them had to change.** All eleven call
`ci.reusable.yml` and all eleven declared a colliding group at their own head
sha. The `language` gate job was absent from every one of them.

| repository | most recent `ci` run with jobs | conclusion | `/ language` |
|---|---|---|---|
| `parlor` | 37230458669 | failure | **absent** |
| `site` | 37235063518 | failure | **absent** |
| `identity` | 37220827002 | failure | **absent** |
| `gateway` | 37215479603 | failure | **absent** |
| `darkroom` | 37233020339 | failure | **absent** |
| `muse` | 37202118604 | failure | **absent** |
| `caf` | 37162524504 | failure | **absent** |
| `kit` (itself) | 37203762081 | failure | **absent** |
| `billing` | — (see below) | failure | — |
| `core` | — (see below) | failure | — |
| `courier` | — (see below) | failure | — |

`docs` was checked and is **not** affected: its only two hits for the
`uses:` string are a comment and a generator, and it declares no caller job.

---

## What I found and did NOT fix

**1. Three repositories render the same defect differently, and I could not
reproduce the second rendering.** `billing`, `core` and `courier` — on runs dated
2026-10-02/03 — report `This run likely failed because of a workflow file issue`
with **zero** jobs, rather than the caller's own jobs running green. Their
`ci.yml` at the run's own head sha carries the identical colliding group
(verified by fetching the blob at each `head_sha`), so the **defect is the
same**. What I could not reproduce is the *rendering*: the collision, the
cancel-before-jobs race, and a heavy 12-job callee all produce the
jobs-listed shape in the probe. **A run settles it** — see below.

**2. `kit`'s own `account-scope contract` job is separately red**, failing at
`assemble the fleet beside kit` with exit 128 (a `git clone` that did not
succeed). Unrelated to this defect and untouched.

**3. Two gate checks are red on this worktree and are not mine**, both reading
sibling repositories rather than any file this packet touched:

```
FAIL generated stack  (no repository commits the file caf dev generates)
       - cafaye-ts: caf.dev.compose.yaml is not ignored
       - gateway:   caf.dev.compose.yaml is not ignored
FAIL in-scope repositories  (every one declares its account-scoped surface)
       gateway  exit 1  ... 1 undcl 1 fails
```

Both are other agents' in-flight work in the fleet beside this checkout.

**4. The probe repositories still exist** and should be deleted before merge:

```
gh repo delete kaka-ruto/kitprobe --yes
gh repo delete kaka-ruto/kitcaller --yes
```

**5. `zizmor` was not re-run.** It is unchanged by this diff (no action refs
touched), but the `secrets`/`zizmor` jobs in the called workflow will now
actually execute for the first time, so their first real output is unmeasured.

---

## What a run must still settle

Nothing below is a claim this packet can make from here. Each is settled by
pushing `master` and reading a run.

1. **The `language` gate appears** in a caller's run. This is the fix, and one
   command reads it:
   ```sh
   gh api repos/cafaye/parlor/actions/runs/<RID>/jobs --jq '.jobs[].name' | grep '/ language'
   ```
2. **kit's own CI goes green** and its `gate` job (the `uses:` call with
   `language: none`) appears at all. It has never appeared.
3. **Lint runs for the first time in CI** in any caller. Expect the first run to
   be **red** — `bin/prime` never ran the linter either, so any repository with
   pre-existing lint findings turns red on the run that fixes this. That is the
   gate working, not a regression, and it should be said out loud in the merge
   message rather than discovered by whoever pushed.
4. **`billing`, `core`, `courier`** — whether the zero-job rendering becomes the
   jobs-listed one. If any of the three still reports `workflow file issue` with
   zero jobs **after** this lands, the collision was not their only problem and
   that is a fresh investigation with a much smaller fleet.
5. **`zizmor`'s first real output** inside the called workflow, and `secrets`'
   first real gitleaks run against each caller's full history.
