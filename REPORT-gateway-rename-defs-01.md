# REPORT — gateway-rename-defs-01

**Branch:** `worker/gateway-rename-kit` (kit) · `worker/gateway-rename-core` (core)
· **Base:** kit `1038f2e`, core `280949b` · **Never pushed, never merged.**

The fleet's gateway service is renamed from `guard` to `gateway`. Two repositories,
each independently committable, each with its own gate and its own before/after
measurement.

---

## 1. The one thing that was hard, and how it was decided

`guard` in these two repositories is **mostly not the service**. The packet
estimated 59 of 302 occurrences in `kit` and 16 of 273 in `core` name the
service; the whole-word counts I measured at the baseline commits are larger
(617 and 480 — the packet counted the word, and `git grep -o` counts every
occurrence inside a line too), but the **ratio** is the finding and it holds.
The rest use the word the way this fleet uses *test* or *lint*: a **tripwire**.

The measurement I actually took, on the live artifacts rather than the whole
tree, is in the table below. The number that mattered most is not either of the
packet's: it is that **`templates/parity-allowlist` holds 22 occurrences of the
word and 8 of them are the service.** One file, 14 that would have been turned
into nonsense.

So the sweep was **done by reading sentences, not by pattern**. The
high-confidence shapes (`guard-`, `guard:`, `GUARD_`, `/guard`, `cafaye/guard`,
`guard_`) were the working set and they held up. For prose the question asked
every time was the packet's: does `guard` name the thing that runs on a port, or
the thing that asserts something?

### Occurrences by sense — measured, at the baseline commits

Counted with `git grep -Ioi 'guard' <baseline> -- <paths>`, so these are
measurements rather than estimates. The historical/live split is by path; the
service/tripwire split within the live set is by reading each sentence (§4).

| repo | total word | live artifacts | historical records |
|---|---|---|---|
| `kit` @ `1038f2e` | 617 | 280 | 337 |
| `core` @ `280949b` | 480 | 319 | 161 |

Within the live sets, after this sweep:

| repo | lines changed to `gateway` | `guard` remaining, all tripwire |
|---|---|---|
| `kit` | 69 | 199 |
| `core` | 151 | 165 |

Note the shape of that table: in **both** repositories the number of remaining
`guard` occurrences is roughly **three times** the number that moved. That is
the packet's central claim, confirmed by the only method that can confirm it —
reading the sentences — and it is why a find-and-replace was never on the
table.

---

## 2. What moved in `kit`, in blast-radius order

kit is the generator every service is built from, so **the templates are the
whole blast radius** and they went first.

1. **`templates/otel/node/hono.ts.snippet`** — the file a new Bun/Hono service is
   generated from. `GUARD_OTEL_ENDPOINT` → `GATEWAY_OTEL_ENDPOINT`,
   `GUARD_TENANT_ID` → `GATEWAY_TENANT_ID`, and the default service name
   `"guard"` → `"gateway"`. A template that still said `guard` would have carried
   the old name into every service scaffolded after this commit, which is the
   whole argument for doing kit before anything else.

2. **`templates/parity-allowlist`** — 8 ratchet rows and their 8 `owner=` fields.
   **The entry count is this file's measurement and it did not move: 80 entries
   across 9 repositories before and after**, verified by running the check,
   which prints its own total on PASS. A rename that had changed that number
   would have deleted or invented a debt record.

3. **`.github/workflows/ci.reusable.yml`** — the `gateway's
   GATEWAY_REDIS_REQUIRED pattern` reference in three language jobs, the `bun`
   job's origin comment, and the `lint-args` input description.

4. **`tests/validate.sh`** — the same `GATEWAY_REDIS_REQUIRED` string inside the
   `tier demand` failure message (a gate that names a stale env var teaches its
   reader to ignore the message), and two comments naming a repository that
   holds a manifest.

5. **`docker/provenance.sh` + `tests/provenance_test.sh`** — the
   `cafaye/guard:e2e` witness becomes `cafaye/gateway:e2e`, 11 occurrences. This
   is a real image name inside a provenance check, so it is a service reference.

6. **`README.md`, `AGENTS.md`, `DECISIONS.md`, `core/README.md`,
   `core/renovate/SETUP.md`** — current-state docs only.

7. **`tests/tenant_isolation/adapters/README.md`,
   `tests/account_scope_fleet_check.py`, `tests/staleness.py`** — a docstring,
   a measured-output example, and a comment quoting a grep.

8. **`CHANGELOG.md`** — a new entry under `## Unreleased`.

## 3. What moved in `core`

1. **`fleet.yml`** — `name: guard` → `name: gateway`, `repository:`,
   `endpointVariable: GUARD_OTEL_ENDPOINT` → `GATEWAY_OTEL_ENDPOINT`, and the
   FINDING prose. **The env var is derived, not chosen**:
   `test_specs.py` asserts
   `telemetry["endpointVariable"] == f"{name.upper()}_OTEL_ENDPOINT"`. Renaming
   the service without it would have been a red gate, which is the right way
   round — the contract should be able to say no.

2. **The manifest fixture corpus** — `examples/valid/telemetry/
   error-type.policy-denied.json` carried a span named
   `guard.request.authorize`; it is now `gateway.request.authorize`. The
   span-name grammar's `ACCEPTED_SPAN_NAMES` moved with it, because the prefix
   is cross-referenced against `fleet.yml` and a span named for a service
   `fleet.yml` no longer declares fails
   `test_span_names_name_a_service_the_fleet_has`.
   `examples/invalid/account-scope.undeclared-key.yml`'s `service:` moved.

3. **`tests/test_specs.py`** — `REQUIRED_FLEET_SERVICES`, `EXAMPLE_OWNERS`, and
   `test_a_service_core_has_not_read_is_reported_rather_than_assumed`, which now
   asserts `"gateway" not in PRODUCER_ID_SHAPES`. That test keeps its entire
   argument: core has read gateway's ids out of no file at no commit, so the
   honest claim is still "unknown" and the rule still **reports** the gap rather
   than skipping it.

4. **The harness** — `account_scope_check.py`, `tenancy_check.py`,
   `cafaye_contract.py`, `db_isolation_check.py`, `gate_check.py`,
   `floors_check.py`, `rules.json`, `account_scope_findings.json`,
   `tenancy_findings.json`, `bin/gate-check`, and every account-scope fixture
   that was copied out of the service's own source (`hono_surface`,
   `hono_composed`, `hono_pipeline`, `shapes/`).

5. **Docs** — all ten under `docs/`, plus `README.md`, `AGENTS.md`,
   `DECISIONS.md`, `gate.yml`, `.github/workflows/ci.yml`, and a `CHANGELOG.md`
   entry.

---

## 4. Left alone on purpose, with the sentence proving it

Every one of these is a **tripwire**. Renaming any of them produces a document
that is wrong, or breaks a gate.

**kit**

| where | the sentence |
|---|---|
| `ci.reusable.yml` ×3, `validate.sh` ×11, `README.md` ×7 | `lint-args guard` — a **step name**, asserted as a string literal at `validate.sh:7687`, `:7695`, `:7702`. Renaming it breaks the check that requires it. |
| `templates/bin/deploy.sh:294,1047,1049` | `` the `${KIT_DEPLOY_IMAGE:?…}` guard refusing to render `` |
| `templates/database/tenancy/advisor.sql:1213` | `` This guard is what stops the rule from becoming "every view … is an ERROR" `` |
| `templates/database/contract.json:173` | `Every other list this check iterates has an empty-list guard` |
| `templates/tier/README.md:237` | `Playwright's guard self-disables` |
| `templates/otel/rust/README.md:87` | `The slicing is guarded by the length check` |
| `templates/otel/ruby/traceparent.rb:143` | `rather than one long guard chain` |
| `templates/secrets/go/print_shape_test.go:365` | `guarded := struct {` — a Go identifier |
| `tests/shard_test.sh:1267,1338,…` ×7 | `Shard guard: a recipe outside this shard is not run at all` |
| `tests/fingerprint.py:23` | `check it guards.` |
| `tests/tenancy_test.sh:1021,1068` | `THE Misfire GUARD` / `is the guard on the fix` |
| `docker/entrypoint.sh:86` | `guarded \`DO\` block` |

**core**

| where | the sentence |
|---|---|
| `schemas/account-scope.schema.json:139` | `` `via` is the middleware, guard or decorator `` — a guard is a **third** thing alongside middleware and decorator, not the service |
| `schemas/account-scope.schema.json:145` | `` `tenantGuard` `` — a **symbol name** in a list of example symbols |
| `harness/tests/account_scope_self_test.sh:1228` | `guard = '    tail = symbol.rsplit(".", 1)[-1]\n    if tail:'` — a **Python local**, mutated by the depth proof |
| `harness/tests/fixtures/tenancy/substrate/migrations/0002_substrate.sql:191,208,221,335` | `THE COLUMN GUARD IS NOT IN THIS COPY` |
| `harness/tests/fixtures/account-scope/hono_surface/src/index.ts:52` | `a gate mounted after the route it exists to guard` — about **ordering** |
| `test_specs.py:2002`, `:10869`, `gate.yml:293`, `bin/prime:644`, and ~90 more | `A guard that cannot find its target is not a guard` — core's own refrain |

---

## 5. Left alone because they are RECORDS, not references

`REPORT-*`, `HANDOFF-*`, `CHANGELOG.md`'s released sections, `reports/**`, and
`measurement-*.out` are **records of what was measured at a commit**. Rewriting
a transcript of a past run makes it a fiction: `measurement-provenance-ownership-01.out`
is cited **by commit hash** (`2540726`) in `HANDOFF-provenance-ownership-01.md:8`,
so editing its output would break the citation that makes it evidence.

The live fixture it records **did** move — `tests/provenance_test.sh` now builds
`cafaye/gateway:e2e` — and the transcript still says what the run at `2540726`
printed. Those are two different claims and only one of them is a record.

**A judgment call a reader might have made differently:** one could argue the
CHANGELOG's released sections are current-facing documentation and should move
too. I did not, because a changelog entry that says *"`guard` was hand-rolling a
workflow"* is a statement about a version that shipped; rewriting it under a
release that is already out would misdescribe that release. The **new**
`## Unreleased` entry does name the rename, which is where a reader looking for
it will look.

---

## 6. Two things I did not rename, and why — one of them a measurement

**`tests/account_scope_fleet_ratchet.yml`'s `- repo: guard` row, and
`tests/account_scope_fleet_scope.yml`'s `inScope` entry.**

I did not rename these because renaming them is a **red gate today**, and I
measured both halves rather than assuming it.

```
EXPERIMENT A — rename the ratchet row only:
  guard         1       0       6     0     1     1     7     0  UNRECORDED
  guard: UNRECORDED
  TALLY: 9 in-scope repositories checked — 8 match their recorded state exactly, 1 do not.
  FAIL account-scope-fleet: guard UNRECORDED

EXPERIMENT B — also rename inScope and recompute the fingerprint:
  COULD NOT RUN: kit's vendored in-scope table and
    /Users/kaka/Code/any/moon/MVP-SCOPE.md disagree.
  MVP-SCOPE.md says: identity, courier, guard, site, parlor, pantry, caf, kit, core
```

The runner resolves each name as `os.path.join(repos_dir, name)` — the row is
keyed on the **directory on disk** — and the scope table is a fingerprint-checked
**cache of `MVP-SCOPE.md`**, which is one directory above the fleet, in no
repository, and not mine. Both were restored byte-for-byte
(`git status` clean on both).

**These three files must move together, and only when the directory rename
lands:** `MVP-SCOPE.md`, `tests/account_scope_fleet_scope.yml` (+ its
fingerprint), `tests/account_scope_fleet_ratchet.yml`. That is the manager's
sequence, and it is written down here rather than left as a red gate for
whoever runs this next.

---

## 7. Measurements

### `core`

```
before   ./bin/prime  ->  299/299 passed, exit 0
after    ./bin/prime  ->  299/299 passed, exit 0
```

Same count, same zero failures. The rename is worth nothing if it moves the
number, and it did not.

### `kit`

`bash tests/validate.sh --static-only --no-live`

```
baseline (before any edit)   248 PASS / 2 FAIL / 6 SKIP, exit 1
after                        248 PASS / 2 FAIL / 6 SKIP, exit 1
```

Every check's verdict and label is **byte-identical** between the two runs:

```
$ diff <(grep -E '^(PASS|FAIL|SKIP) ' baseline | sed 's/\s\+/ /g' | sort) \
       <(grep -E '^(PASS|FAIL|SKIP) ' after    | sed 's/\s\+/ /g' | sort)
IDENTICAL: every check's verdict and label unchanged
```

`tests/provenance_test.sh` on its own: **46 passed, 0 failed**, unchanged.

### What was skipped, named and counted

- **`--no-live`** — the observability live tier (canary, collector-killed,
  fetched stack) did NOT run. Three claims are UNEXERCISED. The gate prints
  this itself and counts it: `note: --no-live: … three claims are UNEXERCISED`,
  and `6 check(s) skipped` appears in both runs, identically.
- **`lint_test.sh`** — `SKIP lint_test.sh (--no-lint)`, in both runs. The four
  linters are not executed here.
- **`shellcheck`, `gofmt`** — not installed on this machine; the gate reports
  `SKIP shellcheck (not installed)` and `SKIP templates/secrets/go (gofmt not
  installed — cannot parse)` in both runs.
- **`self_test.sh`** — did not run (not part of `--static-only`). This is the
  one I would most want run on the merge, and it is the reason the next section
  matters.
- **`core`'s CI-only red proofs** (`numeric_self_test.sh`,
  `tenancy_self_test.sh`, `self_test.sh`) are not in `bin/prime` by core's own
  design and were not run here.

### The 2 FAILs are pre-existing and not mine

```
FAIL generated stack  (no repository commits the file caf dev generates); 2 in frozen repositories
FAIL in-scope repositories  (every one declares its account-scoped surface)
```

Both name the `guard` repository **on disk**
(`- guard: caf.dev.compose.yaml is not ignored`). The directory rename is the
manager's, not this packet's. Neither FAIL is caused by this change and neither
is fixed by it — they were red on the baseline run before a single byte was
edited, and they are red now for the same reason.

---

## 8. Findings outside the packet

1. **`tests/account_scope_fleet_ratchet.yml` and
   `tests/account_scope_fleet_scope.yml` are keyed on the directory name, not
   the service name** — so the rename cannot land in kit until the directory
   rename does. Measured both ways in §6. **This is the single most important
   thing in this report for the manager**, because it is a three-file atomic
   change and two of the three are here.

2. **`EXAMPLE_OWNERS` in `core/tests/test_specs.py:805` is dead code.** Defined
   at line 805 and referenced nowhere — `grep -n 'EXAMPLE_OWNERS'` returns
   exactly one hit, the definition. I renamed its `guard` key for consistency
   with the rest of the sweep, but a reader should know the mapping is not
   currently load-bearing, so nobody treats it as a live index.

3. **`kit`'s `tests/lint_test.sh` is the one gate phase that is fatal on a
   skip**, and it skipped here with `--no-lint`. I did not run it: it is not in
   `--static-only`, and standing up four linters against a fixture fleet was
   outside a rename. **It should be run once on the merge.**

4. **No defect found in either repository.** The sweep was mechanical, the two
   gates held their counts, and nothing surfaced that needed a fix beyond the
   rename itself. I am reporting that plainly rather than manufacturing a
   finding.

---

## 9. What I would do next

1. **Run `bash tests/self_test.sh`** on both branches. It is 100+ whole gates,
   it is the phase this packet most exercises (it greps templates), and it was
   out of scope for `--static-only`. If it comes back `BOUND`, that is a
   machine fact and the un-reached recipes are the gap — `kit`'s own AGENTS.md
   says a `BOUND` self-test is a gate to run by hand, not a gate to report.
2. **Run `tests/lint_test.sh` without `--no-lint`** — the one phase that is
   fatal on a skip.
3. **Merge the directory rename atomically** with `MVP-SCOPE.md`,
   `tests/account_scope_fleet_scope.yml` (fingerprint recomputed) and
   `tests/account_scope_fleet_ratchet.yml`. §6 has the measurement.
4. **After the merge**, `git mv` the two `REPORT-kit-guard-*` filenames if the
   manager wants the historical filenames to match the new name. I left the
   filenames alone: a renamed report is a report whose subject you can no
   longer find by its old name, and those files are how kit-19 was diagnosed.

## 10. Housekeeping

- Committed to `worker/gateway-rename-kit` and `worker/gateway-rename-core`.
  **Not pushed, not merged, not tagged.**
- Worktrees: `wt-m39-kit-gateway-rename-defs-01`,
  `wt-m39-core-gateway-rename-defs-01` (the `wt-m39-` prefix per the standing
  contract; the packet's own example used an unprefixed name).
- No container, image or volume was started. No docker command was run at all.
- Every command was bounded by `timeout` or the tool's own timeout.
- No other session's worktree, branch or container was touched.
