# Where kit's gate spends its time — the profile

> **SUPERSEDED — read `PROFILE-gate-honest.md` first.** That file is the
> measured re-derivation this one asked for: one complete run (493.30 s, 157
> PASS / 0 FAIL / 5 SKIP), every row a real interval, the rows tiling the run
> exactly. This file is kept as the record of the truncated run it was.
>
> **READ THIS FIRST — this file's headline number was wrong, and a later packet
> found out why.** Everything below is kept as the record it was, but the
> "~96% of the run" and the "~4,905 s" are arithmetic from a bad mean: the four
> child gates that finished before that run was killed were **breakages 1, 2, 2b
> and 3**, and all four already paid the full static phase. The 51.63 s mean was
> then applied to all 94 as though none were filtered — which is the thing §4 of
> this file had already counted correctly and then not used.
>
> **The corrected populations, measured (kit-gate-speed-02):**

> | | measured |
> | --- | ---: |
> | one child gate, unfiltered `--static-only` | **42.70 s** |
> | one child gate, `--only` one check | **7.88 s** |
> | `self_test` | **~17 min before the `--only` reach, ~13 min after** — not 82 |
> | share of `self_test` in the 73 ALREADY-filtered gates | **~85%** |
>
> So the target was never the 21 unfiltered recipes; it is the 73 filtered ones,
> and the fix for them is overlap, not filtering. **§4 below is correct and was
> acted on. The table and answers 1–3 should be re-derived before anyone quotes
> them.** The reasoning is in `REPORT-kit-gate-speed-02` §2 and §3.

**What this is.** The measurement `KIT_PROFILE` takes, and the table it produces.
**What this is not.** An optimization. Nothing in this file was made faster; the
next packet fixes whatever this table names, and a fix designed without this
profile is a guess.

Reproduce any run's table with:

```sh
KIT_PROFILE=/tmp/p.tsv bash tests/validate.sh     # write the profile
grep -v '^phase' /tmp/p.tsv | sort -t"$(printf '\t')" -k3 -rn | head -30
```

The TSV is four columns — `kind`, `label`, `seconds`, `tag` — and the five kinds
are **never summed together**: `cpu` rows are parallel checks that OVERLAP, so
their sum is an upper bound on their region rather than its duration.

## The run this table is from

| | |
| --- | --- |
| commit | `4ca039f` (the instrumentation), on `worker/kit-gate-speed-01` |
| command | `KIT_PROFILE=/tmp/gate-full.tsv timeout 1200 bash tests/validate.sh` |
| **wall clock, measured** | **569.0 s** — the `total` row the outer invocation writes on its EXIT trap |
| reached | `self_test`, breakage 3 of 94 |
| exit status | none — the run was terminated externally at 21:22:30, not by a check |

**The run is TRUNCATED and everything below says so.** `self_test` is 94 whole
gates in sequence and this machine runs them at ~52 s each, so `timeout 1200`
was never going to reach the end: 94 × 52 s is 82 minutes on its own. Four child
gates completed inside the 569 s. The numbers below are therefore given twice —
**measured**, from the rows that exist, and **projected**, from the mean of the
four children that did finish. The projection is arithmetic on four samples, and
it is labelled as a projection everywhere it appears.

## The table — the outer gate's own 133 timed rows, sorted

Denominator: the run's 569.0 s. `tier` is a `bounded_check` (a whole heavy
script); `check` is one command.

| # | kind | seconds | share | check id |
| ---: | --- | ---: | ---: | --- |
| — | **self_test** | **~4,905** | **~96.1%** | **`tests/self_test.sh` — 94 breakages + 1 control, measured at 51.63 s each** |
| 1 | tier | 63.191 | 1.24% | `tests/no_telemetry_in_readiness.sh  (collector killed, service still serves)` |
| 2 | tier | 43.630 | 0.85% | `tests/stack_live_test.sh  (the fetched stack runs; a trace and a metric arrive)` |
| 3 | tier | 19.022 | 0.37% | `tests/canary_test.sh  (a canary secret reaches no exporter)` |
| 4 | check | 13.334 | 0.26% | `tests/lint_test.sh  (every linter runs, and its control disagrees)` |
| 5 | check | 9.779 | 0.19% | `tests/staleness_test.sh  (26 cases, incl. the red proof and the absent case)` |
| 6 | check | 6.827 | 0.13% | `tests/fetch_test.sh  (a pin fetches, a branch is refused, offline is real)` |
| 7 | check | 4.729 | 0.09% | `tests/multi_tenant_split_test.sh  (a second tenant is split, not fused)` |
| 8 | check | 4.257 | 0.08% | `tests/isolation_test.sh  (service A cannot reach service B's database)` |
| 9 | check | 4.116 | 0.08% | `kamal_test — 24 case(s), every one against the real binaries.` |
| 10 | check | 3.624 | 0.07% | `tests/tenancy_test.sh  (no identity, another tenant and its own tenant)` |
| 11 | check | 1.705 | 0.03% | `tests/classify_test.sh  (19 cases, incl. the fail-closed property)` |
| 12 | check | 1.434 | 0.03% | `templates/otel/rust  (rustc test suite)` |
| 13 | check | 1.399 | 0.03% | `tests/gitleaks_gate.sh  (finds a real secret, never prints it, reads history)` |

Rows 133 and below are all under 1.2 s; **the longest tail row is 1.2 s and the
shortest is 6 ms**, so the distribution is not a long tail — it is one enormous
phase and then nothing. Full profile: the commit that added `KIT_PROFILE`.

**`cpu` rows are not in this table and must not be added to it.** 92 parallel
checks ran in the outer gate and 92 in every child gate; their summed seconds
(9.4 s outer, 10.8 s per child) exceed the regions they ran in, because they ran
at the same time as each other.

## The four answers

### 1. Which single check is the biggest cost?

**`tests/self_test.sh` — ~4,905 s of a ~5,103 s run, about 96%.**

Measured, not argued: it ran four complete child gates inside this run, at
**51.63 s mean** (56.559 / 49.016 / 52.324 / 48.631), and it had reached
breakage 3 of 94. It is **26× the next item** (`no_telemetry_in_readiness.sh`,
63.2 s) and it is the only thing in the gate whose cost is a multiple of the
run's length rather than a share of it.

The reason is structural, and the profile makes it precise: **each child gate is
a whole `tests/validate.sh`**, and it runs **113.6 timed checks** — essentially
the entire static phase — to learn one fact about one named check.

### 2. How much of the run is the top three together?

**98.2%** (projected: 4,905 + 63.191 + 43.630 = 5,012 s of 5,103 s).
On the truncated run as measured, the same three are **84.0%** of 569.0 s.

### 3. How many processes does one full run spawn?

| | count | how it was counted |
| --- | ---: | --- |
| the outer gate's own timed spawn sites | **129** | `check` + `tier` rows with an empty tag — one `$(…)` or one fork each, measured |
| per child gate | **113.6** | measured over the four that completed |
| child gates in a full run | 95 | 94 breakages + the unbroken-tree control, counted from the recipes |
| **the gate's own forks, projected** | **~19,650** | 129 outer + 95 × (113.6 `check`/`tier` + 92 parallel `cpu` children) |
| the profiler's own, when `KIT_PROFILE` is set | **~41,000** | 2 `perl` clock reads per timed region — exact, one per measurement point |
| **total with the profiler on** | **~60,700** | |
| **total with the profiler off** | **~19,650 + the untimed tail** | see below |

**The untimed tail, named rather than hidden.** Each `check` body is itself a
shell function, and most of them spawn: a heredoc-to-Python check is one more
`$PY`, and every check with output on PASS is piped to `sed` (one spawn each —
this gate's own rules forbid reading that output through a pipe, and the `sed` is
there to indent it). So 19,650 is a **floor**, not a total. The profiler's
~41,000 is not a rounding error on top of it either: it is *twice* the thing
being measured, which is why `KIT_PROFILE` is off by default and why the next
packet should treat any measurement taken with it on as carrying that overhead.

### 4. (bonus, and it is the actionable one) `--only` is not reaching 21 of 94 recipes

`expect_red_check` appends `--only=<the named check>` to the child gate's
command line; **`expect_red`, `expect_red_lang`, `expect_red_script`,
`expect_green_check` and `expect_skip_check` do not.** Counted from the recipes:

| recipe | count | adds `--only`? |
| --- | ---: | --- |
| `expect_red_check` | 73 | yes |
| `expect_red` | 7 | **no** |
| `expect_red_lang` | 6 | **no** |
| `expect_red_script` | 6 | **no** |
| `expect_green_check` | 1 | **no** |
| `expect_skip_check` | 1 | **no** |

Breakage 1 is an `expect_red`, and its profile shows the whole static phase —
`tests/fetch_test.sh` 11.6 s, `tests/staleness_test.sh` 8.8 s, `kamal_test`
4.7 s — none of which is the check breakage 1 is about. The mechanism the code
comments call "the 60×" is applied to 73 of 94 recipes, so the 60× is 60 ×
(73/94) ≈ **47×, not 60×**, and 21 recipes pay the full price.

## What this profile does NOT tell you

- **Where the time goes inside a child gate.** Every child runs 113.6 checks and
  the table above is the outer gate's rows; a child's rows are attributed by
  breakage (`tag`), and the four that finished say only that they cost 51.63 s
  each, not which of their 113 checks.
- **Anything about a run that completes.** The projection is four samples.
- **Whether the tail below 1.2 s matters in aggregate.** It is 133 rows of
  0.006–1.2 s, which is real time spent, but no single one of them is a target.
- **Anything about a quiet machine.** This box runs several kit gates at once,
  and every number here carries that.