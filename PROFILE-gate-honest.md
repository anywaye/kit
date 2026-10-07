# Where kit's gate spends its time — the honest profile

> **This is the re-derivation `PROFILE-gate.md` asked for.** That file's table
> came from a truncated run whose top row (`self_test`, ~4,905 s) was a
> projection from a bad mean, and whose top cost — the self-test layer — has
> since been retired whole (`32df467`). This file is measured: one complete
> run, every row a real interval, the rows tiling the run exactly.
>
> **Reproduce:**
>
> ```sh
> KIT_PROFILE=/tmp/honest.tsv bash tests/validate.sh
> python3 tests/profile_report.py /tmp/honest.tsv
> ```

## The run this is from

| | |
| --- | --- |
| commit | `d25e860` (the profiler records a parallel region's own span), on `worker/kit-m44-gateprofile` |
| command | `KIT_PROFILE=/tmp/…/before.tsv bash tests/validate.sh` (attempt 1 of this packet; the raw TSV and log are preserved at `/tmp/kit-m44-preserved/`) |
| **wall clock, measured** | **493.30 s** — the `total` row the outer invocation writes on its EXIT trap |
| **verdicts** | **157 PASS / 0 FAIL / 5 SKIP** — counted from the run's own `PASS`/`FAIL`/`SKIP` lines |
| exit status | 0 |
| reached | the end — `PASS: every check passed.`, `note: 5 check(s) skipped`, `note: 5 tier(s) ran under a time bound; none was reached` |

**The rows tile the run exactly.** The 28 `phase` rows + 2 `par` rows sum to
493.278 s against a `total` of 493.304 s; the 0.026 s difference is argument
parsing and the exit trap. No interval is double-counted and none is dropped.

**A labeling note that matters for reading the table.** A `phase` row is
written by the `section`/`kit_phase` call that *opens* the section, and it
measures the interval *since the previous marker* — i.e. the section that
came *before* it. So the row labeled `60 summary` is really the lint check,
and the row labeled `static: the canary harness parses in Go` is really the
`templates/kamal` section (which holds `kamal_test`). The labels are off by
one section; the intervals are correct.

## The honest top costs — phases and parallel regions (wall clock, tile the run)

Denominator: the run's 493.30 s. These rows contain the `check`/`tier` rows
below them, so the two tables overlap and must not be summed.

| # | kind | seconds | share | what the row actually contains |
| ---: | --- | ---: | ---: | --- |
| 1 | phase | 200.06 | 40.6% | the four observability tiers — `no_telemetry_in_readiness` 63.29 + `isolation_test` 15.74 + `tenancy_test` 12.28 + `onecluster_test` 9.45 = 100.77 — **plus ~99 s no check row claims** (see "The unattributed time" below) |
| 2 | par | 99.20 | 20.1% | the parse region: 55 `cpu` checks in parallel, spawn-latency-bound. Their summed seconds (≈9 s) are an upper bound, not the region's duration |
| 3 | phase | 43.25 | 8.8% | the `templates/kamal` section — `kamal_test`, 24 cases against the real `kamal`/`kamal-backup` binaries |
| 4 | phase | 31.65 | 6.4% | `lint_test.sh` — the four linters, each against a fixture that must fail it |
| 5 | phase | 29.73 | 6.0% | the fetch section — `fetch_test` 7.98 + ~22 s unattributed (see below) |
| 6 | phase | 21.96 | 4.5% | the canary-harness contract section — the canary suite (21.80) |
| 7 | phase | 20.66 | 4.2% | the canary-harness-parses-in-Go section — the six otel traceparent suites, one per language |
| 8 | phase | 19.22 | 3.9% | the shellcheck sweep — 31 `cpu` checks in parallel |
| 9 | phase | 5.82 | 1.2% | the tenancy section — `multi_tenant_split` 3.72 + `failfast` 1.98 |
| 10 | phase | 5.40 | 1.1% | the classifier/fingerprint section — `classify_test` 1.36 + `fingerprint_test` 4.00 |
| 11 | phase | 5.33 | 1.1% | the provenance section — `provenance_test` 5.31 |
| 12 | phase | 4.11 | 0.8% | bootstrap — interpreter resolution + dependency install |
| 13 | par | 2.62 | 0.5% | the shellcheck region: 31 `cpu` checks in parallel |
| 14 | phase | 1.31 | 0.3% | the hadolint section — 7 Dockerfiles |
| 15 | phase | 0.73 | 0.1% | the database-snippet section — 6 language snippets |
| 16 | phase | 0.71 | 0.1% | the non-root/pinned-base section |
| 17 | phase | 0.58 | 0.1% | the database-snippet parse section |
| 18 | phase | 0.42 | 0.1% | the `run:` body prefix-assignment section |
| 19 | phase | 0.14 | 0.0% | the tenancy-presence section |
| 20 | phase | 0.12 | 0.0% | the compose-chokepoint section |

## The honest top costs — the gate's own checks and bounded tiers

The same run, the leaf rows. `tier` is a `bounded_check` (a whole heavy
script); `check` is one command; `cpu` is one parallel child (overlapping).

| # | kind | seconds | check id |
| ---: | --- | ---: | --- |
| 1 | tier | 63.29 | `tests/no_telemetry_in_readiness.sh  (collector killed, service still serves)` |
| 2 | check | 31.62 | `tests/lint_test.sh  (every linter runs, and its control disagrees)` |
| 3 | check | 21.80 | `the canary suite  (never prints the value it planted)` |
| 4 | tier | 15.74 | `tests/isolation_test.sh  (service A cannot reach service B's database)` |
| 5 | tier | 12.28 | `tests/tenancy_test.sh  (no identity, another tenant and its own tenant — as the login role AND as the owner; and the same proof with FORCE removed goes red)` |
| 6 | tier | 9.45 | `tests/onecluster_test.sh  (two services, ONE postgres container, each with its own database and roles; both answer as their own role, neither reaches the other's)` |
| 7 | tier | 7.98 | `tests/fetch_test.sh  (a pin fetches, a branch is refused, offline is real)` |
| 8 | check | 5.31 | `tests/provenance_test.sh  (11 leak shapes refused; both sinks agree; --verify refuses a foreign or ill-shaped stamp; 4/5/6 stay distinct)` |
| 9 | check | 4.00 | `tests/fingerprint_test.sh  (the skip is proven able to be WRONG: outputs deleted, one byte changed, a corrupt record, a foreign version)` |
| 10 | check | 3.72 | `tests/multi_tenant_split_test.sh  (a second tenant is split, not fused; identifiers hold in every locale)` |
| 11 | check | 1.98 | `tests/failfast_test.sh  (a missing required variable is refused in seconds, by name, with nothing started)` |
| 12 | cpu | 1.76 | `templates/tier/rust/tier.rs  (rustc --test)` — overlaps the parse region |
| 13 | check | 1.36 | `tests/classify_test.sh  (19 cases, incl. the fail-closed property)` |
| 14 | cpu | 0.83 | `tests/validate.sh  (shellcheck -S warning)` — overlaps the shellcheck region |
| 15 | cpu | 0.50 | `tests/tenancy_test.sh  (shellcheck -S warning)` — overlaps |
| 16 | cpu | 0.48 | `tests/deploy_test.sh  (shellcheck -S warning)` — overlaps |
| 17 | cpu | 0.41 | `templates/bin/dev.sh  (shellcheck -S warning)` — overlaps |
| 18 | check | 0.34 | `database/elixir/repo.exs.snippet  (loads; stdlib only, as intended)` |
| 19 | cpu | 0.32 | `templates/bin/deploy.sh  (shellcheck -S warning)` — overlaps |
| 20 | cpu | 0.22 | `tests/provenance_test.sh  (shellcheck -S warning)` — overlaps |

**The top three real costs, named:** the observability tiers (200.06 s as a
phase, of which `no_telemetry_in_readiness` alone is 63.29 s — docker stacks
brought up and torn down), the parse region (99.20 s — 55 parallel checks,
bound by process-spawn latency, not by any single check), and `lint_test`
(31.62 s — four linters against fixtures). Together the top three phases are
200.06 + 99.20 + 43.25 = **342.5 s, 69.4% of the run**.

## Which of the old table's rows were artifacts, and what the real cost is

`PROFILE-gate.md`'s table, row by row. "Real" means the check still runs and
its cost is measured in this run; "gone" means the check no longer runs.

| old row | old cost | status | the real cost, measured |
| --- | ---: | --- | --- |
| `self_test` (94 breakages) | ~4,905 s | **gone** — the tree-copy layer was retired in `32df467` | 0 — the check no longer exists. The 4,905 s was also a projection from a bad mean (51.63 s × 94), not a measurement |
| `no_telemetry_in_readiness.sh` | 63.191 s | real | **63.29 s** — unchanged; still the single largest check |
| `stack_live_test.sh` | 43.630 s | **gone** — no longer invoked as a tier; only `bash -n` (0.012 s) and `shellcheck` (0.216 s) remain | 0 as a tier. The script still exists but the gate does not run it |
| `canary_test.sh` | 19.022 s | real | **21.80 s** (now labeled `the canary suite`) |
| `lint_test.sh` | 13.334 s | real | **31.62 s** — 2.4× the old number; the suite has grown (22 assertions, four linters, each with a control) |
| `staleness_test.sh` | 9.779 s | **gone** — removed with the reporter (MD36) | 0 |
| `fetch_test.sh` | 6.827 s | real | **7.98 s** |
| `multi_tenant_split_test.sh` | 4.729 s | real | **3.72 s** |
| `isolation_test.sh` | 4.257 s | real | **15.74 s** — 3.7× the old number; the suite now brings up its own stack with its own `docker compose` call |
| `kamal_test` | 4.116 s | real | inside the 43.25 s `templates/kamal` phase — the 24 real-binary cases dominate that section |
| `tenancy_test.sh` | 3.624 s | real | **12.28 s** — 3.4× the old number; the suite now runs the proof three times (clean, FORCE-removed control, init-plan measurement) |
| `classify_test.sh` | 1.705 s | real | **1.36 s** |
| `templates/otel/rust` | 1.434 s | real | **1.76 s** (`rustc --test`) |
| `gitleaks_gate.sh` | 1.399 s | **gone** — the full-history secret scan was removed (MD34) | 0 |

**The old table's headline — `self_test` at ~96% of the run — is doubly
retired.** The self-test layer is gone, and the number was a projection from
a bad mean anyway. The honest top cost is the observability tiers at 200.06 s
(40.6%), and the single largest check is `no_telemetry_in_readiness` at
63.29 s.

## The unattributed time — real wall clock no check row claims

Two phases are larger than the sum of the check rows inside them. This is not
a profiler bug (the rows tile the run exactly); it is time the gate spends
outside any `check`/`tier` call:

- **The observability phase (200.06 s)** contains the four tiers (100.77 s)
  plus **~99 s unattributed**. The tiers are `bounded_check` calls running
  `docker compose` stacks; the unattributed time is the container lifecycles
  the tier scripts drive but that fall outside the measured `timeout` span —
  stack teardown, port release, and the daemon round-trips between the
  script's own `docker compose` invocations.
- **The fetch section (29.73 s)** contains `fetch_test` (7.98 s) plus **~22 s
  unattributed** — the `kit_cached_check` wrapper's `fingerprint.py`
  manifest/lookup/record calls and the section's own lead-in.

**This is the one part of the profile the leaf table cannot see**, and it is
why the phase table above is the one to quote for "where the time goes": a
reader who sums only the `check`/`tier` rows will under-count the observability
phase by half.
