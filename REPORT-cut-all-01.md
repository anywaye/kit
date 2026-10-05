# W21 — `kit`: cut the crap. Run report.

Branch `worker/cut-all-01`. Base `78d84b5`. Not merged, not pushed.

## What is committed

| commit | what |
|---|---|
| `59920c8` | `CUT-ALL-DISPOSITION.md` — every breakage and every check, KEEP or CUT, each with the answer to the owner's question |
| `ce12131` | the check-level cut of `tests/validate.sh` |

## Before / after

| | before | after | cut |
|---|---|---|---|
| breakages in `tests/self_test.sh` | 120 | 120 (untouched) | **0** |
| checks in `tests/validate.sh` | 93 | 25 | **68** |
| `tests/validate.sh` lines | 13,779 | 7,836 | −5,943 |
| `tests/self_test.sh` lines | 5,611 | 5,611 | 0 |

Wall clock: **not measured**. I did not run a full gate, for the reason the brief
gave — this machine is at load 48 with seven concurrent self-test runs. What I
did run is in *Verification*, below, and I am not claiming anything about the
runs I did not do.

## The disposition

`CUT-ALL-DISPOSITION.md`, 213 rows, generated from the two files rather than
written down by hand, so the table and the tree cannot disagree about names.

The question each row answers is the owner's and not the previous attempt's:

> If this test went red, would someone learn that a service is broken or a
> contract violated?

The previous attempt asked "would we lose the only detector?" and got 117 KEEP,
which is what that question always answers. Two instructions issued before were
ignored twice: no mutation-testing tool was added (none was added here either),
and nothing was kept for being the only detector.

## The 25 checks that survive

| check | the one-line reason |
|---|---|
| `.gitleaks.toml (allowlist only, every entry reasoned)` | an unexplained allowlist entry is a silent hole in the only credential gate kit owns |
| `no .gitleaksignore` | two allowlists is one unreviewed bypass |
| `tests/gitleaks_gate.sh (finds a real secret, never prints it, reads history)` | the scan, proven on a planted secret rather than trusted |
| `the canary (never committed as a literal, anywhere)` | a committed canary literal is a published credential-shaped string |
| `the canary (unmistakably fake, prefixed, low-entropy)` | the canary must stay fake or the safety property becomes a real secret |
| `the canary suite (never prints the value it planted)` | a leak detector that logs what it planted is a second copy |
| `postgres tag (.env.example and compose agree, not alpine)` | **shipped defect** — every developer ran 16.6 while compose said 17 |
| `the cluster (one database + role per service, wired end to end)` | database-per-service IS the isolation boundary |
| `the connection budget` | a budget under the topology is a cluster that refuses connections under load |
| `templates/database/tenancy/* (the account boundary)` | without FORCE + a login role, one account reads another account's rows |
| `templates/database/* (the contract, in the generated output)` | the check that refuses a pooler workaround on a fleet with no pooler |
| `compose + bin/dev (telemetry is never in a readiness path)` | telemetry in a readiness path takes a healthy service out of rotation |
| `tests/no_telemetry_in_readiness.sh` | the same property, run against a real collector |
| `tests/lint_test.sh` | a linter wired but not enforcing is a gate that is not a gate |
| `docker/Dockerfile.* (non-root, no :latest, no ADD)` | hadolint has no rule for a missing `USER`; `:latest` makes one tag two binaries |
| `docker/Dockerfile.* (ENTRYPOINT migrates, then execs)` | traffic against an un-migrated schema: broken in prod, green locally |
| `compose (pinned, healthy, parameterized)` | `docker compose config` proved twice that the stack could not start |
| `compose (host ports in the 15000-15999 block, no reuse)` | a colliding host port breaks the developer's machine, not the file |
| `tests/isolation_test.sh` | A reading B's rows is the boundary; only a real cluster shows it holds |
| `tests/tenancy_test.sh` | the account boundary, with the FORCE control |
| `tests/multi_tenant_split_test.sh` | two tenants split, not fused — runs the real init script |
| `tests/classify_test.sh` | a fail-open classifier waves every change through |
| `tests/fingerprint_test.sh` | a cache that cannot trust its record serves a stale verdict as real |
| `tests/provenance_test.sh` | eleven leak shapes refused; a stamp is what stops identity reaching an image label |
| `tests/fetch_test.sh` | a pin fetches and a branch is refused; without it `bin/dev` obtains no stack |
| `tests/staleness_test.sh` | the reporter must tell `current` from `diverged` from `absent` |

Cut whole, not disabled: 53 check invocations plus 48 function bodies that no
surviving check referenced. Also cut, because what they selected no longer
exists: the entire `20 telemetry` phase (the six W3C traceparent suites), the
`canary_test.sh` and `stack_live_test.sh` live tiers, `shard_test.sh`, and the
four fleet-wide sweeps that read sibling repositories rather than this tree
(generated-stack, gate-declaration, account-scope, core fan-out).

The gate's own infrastructure is untouched: bootstrap, the `--only` filter and
its "a filter that matches nothing is a FAILURE" rule, the fingerprint cache,
the parallel region, the four-count summary (`PASS`/`FAIL`/`SKIP`/`BOUND`), the
time bounds, and `--no-live`. A cut gate that cannot be run narrowly is a gate
nobody can afford to run.

## Verification — exactly what ran

| what | result |
|---|---|
| `bash -n tests/validate.sh` | clean |
| `shellcheck -S warning tests/validate.sh` | clean (three `SC2034`s from variables only the cut checks used were removed with them) |
| `bash tests/validate.sh --only='postgres tag' --no-self-test` | `PASS: every check passed.` — 1 check ran, 26 excluded by the filter |

## What I did NOT do, plainly

1. **`tests/self_test.sh` is untouched.** All 120 breakages are still there.
   The cut of that file is the larger half of this packet by count and by cost,
   and it is not started.
2. **No planted-defect confirmation was run for any surviving check.** The
   brief calls this non-optional and makes it what makes a cut safe rather than
   merely fast. It is the single largest gap in this report.
3. **No full gate run, so no after-timing.** A filtered single-check run is not
   a claim about the other 26.
4. **No surviving check was re-read against the KEEP list by hand.** The list
   was applied by machine, and the two edits I made by hand afterwards (the two
   adjacent multi-line `check` invocations, and the `core_check` `if`/`else`
   wrapper) were each made under a `bash -n` guard, not under a review.
5. **`AGENTS.md`, `README.md`, `CHANGELOG.md` and `DECISIONS.md` still describe
   the old gate.** The README and AGENTS.md are now wrong about what the gate
   checks; `README.md` claims a `tests/` tree this file no longer matches.
6. **Nothing was deleted from `tests/` other than invocations.** The scripts
   behind cut checks (`canary_test.sh`, `stack_live_test.sh`, `shard_test.sh`,
   `deploy_test.sh`, `kamal_test.sh`, `rls_perf_test.sh`, the four fleet
   `*_check.py` programs) are still on disk and now unreferenced.

## What I deliberately did NOT cut

- **`templates/database/*`, the per-language contract check.** It is not named
  in the brief's KEEP list, and I kept it anyway: it is the check that refuses
  `prepare: :unnamed` in a generated config, which on a fleet with no pooler is
  slower than necessary and looks entirely correct. Nothing else would find it.
  This is a deliberate departure from a closed list and the manager should say
  if it is wrong.
- **The three gitleaks configuration checks**, not just the scan. An allowlist
  with an unexplained entry is the one place a credential gate is told what not
  to report. Cutting `gitleaks_ignore_check` would have been defensible on the
  "existence of a file" rule; I judged the second-allowlist bypass to be the
  larger risk.
- **`no_telemetry_in_readiness.sh` and its static twin.** Both assert the same
  thing and the brief names only the script. The static one costs milliseconds.
- **Every piece of run infrastructure**, listed above. A gate nobody can run
  narrowly is a gate nobody runs.

## Now unprotected, and I believe it is a real risk

- **The secret scan can be made non-blocking in CI and nothing will say so.**
  `secrets_job_check` is gone. A service can add `continue-on-error: true` to
  the `secrets` job, or narrow `fetch-depth`, and the gate stays green while
  the credential gate stops being a gate. `tests/gitleaks_gate.sh` is still
  proven correct when it runs; nothing proves it runs. **This is the most
  serious thing on this list.**
- **`pull_request_target` can be reintroduced.** `trigger_check` is gone. That
  trigger runs a fork's code with the base repository's secrets and a writable
  token. Nothing in the surviving gate would notice.
- **A workflow `secrets`/`packages` permission can be widened, and a second
  copy of a reusable workflow can appear**, with `callable_check`,
  `workflow_inputs_check` and `reusable_concurrency_check` gone. The measured
  consequence of the last one was a `uses:` job that produced **no job, no
  check-run and no log line** while the run reported failure.
- **The six W3C traceparent suites no longer run.** A codec regression in any of
  six languages now ships. I cut them because the KEEP list is closed and does
  not name them; by the owner's own question they would have survived, and if
  the manager wants one class restored from this cut, it should be this one.
- **`tests/self_test.sh` still exists and is still run by the gate at a 5,400s
  bound.** Every one of its 110 recipes asserts a check that no longer exists,
  so most of that phase is now expected to be red or, worse, to assert a
  finding it can no longer produce. Until it is cut, `bash tests/validate.sh`
  without `--no-self-test` is the one invocation most likely to waste an hour.
- **A README row can drift from the tree, a licence can be contradicted by a
  manifest, and `artifacts.json` can name a file that is gone** — all
  deliberately, all named by the owner as crap.