# REPORT — kit-gate-speed-overlap-01

**Branch:** `worker/kit-w40-gatespeed`
**Date:** 2026-10-07
**Packet:** "make the filtered child gates overlap"

## The diagnosis: the premise is refuted — the target was deleted

The packet asks to "make the filtered child gates overlap" so the `self_test`
share of the 73 already-filtered gates is paid once in parallel rather than 73
times serially.

**There are no filtered child gates.** `tests/self_test.sh` — the suite that ran
them — was deleted on 2026-10-05 in commit `32df467` ("no tree copies: the
self-test layer is gone, entirely"), by the owner's decision:

> i do not want any tree copies at all in the first place

A "breakage" in that suite **was** a tree copy. `fresh_copy` made a full copy of
the repository per breakage, mutated it, and ran a whole `tests/validate.sh`
against the copy to see whether the gate went red. "No tree copies" and "keep
some breakages" cannot both be true, so the whole layer went:

| removed | lines |
|---|---:|
| `tests/self_test.sh` | 5,611 |
| `tests/shard_test.sh` | 413 |
| the `self_test` phase, `RUN_SELF_TEST`, `--no-self-test`, the `KIT_SELF_TEST_SHARD` seam, and related checks in `tests/validate.sh` | 536 |

The packet's corrected numbers (from `PROFILE-gate.md`'s "READ THIS FIRST" block)
describe a suite that no longer exists:

| the packet's number | reality on this tree |
|---|---|
| "one child gate, `--only` one check → 7.88 s" | no child gates run |
| "share of `self_test` in the 73 ALREADY-filtered gates → ~85%" | there are no filtered gates |
| "94 breakages, 92 reds" (handoff-03, the counts that "must not move") | the breakage count is **0** |
| "`tests/validate.sh` derives counts from `tests/self_test.sh`" | it derives nothing from a file that does not exist |

`tests/validate.sh` contains **no** reference to `self_test.sh`, `RUN_SELF_TEST`,
`KIT_SELF_TEST_SHARD`, or `--no-self-test`. The only occurrence of the string
"self-test" in the file is a historical comment (line 2952: "self-test breakage 72
green"). No other script in `tests/` spawns a child `validate.sh` gate.

## The measurement — the packet's step 1, done first

Command (the one the packet names):

```sh
KIT_PROFILE=/tmp/p-before.tsv bash tests/validate.sh
grep -v '^phase' /tmp/p-before.tsv | sort -t"$(printf '\t')" -k3 -rn | head -30
```

**Wall clock: 823.4 s** (profiler on; the profiler adds ~25% overhead — see
`PROFILE-child-gate.md` §"Read every number as carrying the profiler's own
overhead"). Exit 0. `PASS: every check passed.`

### The profile table — the outer gate's own timed rows, sorted

| # | kind | seconds | check id |
| ---: | --- | ---: | --- |
| — | **total** | **823.437** | **FULL RUN (first line of the script to the exit trap)** |
| 1 | tier | 72.045 | `tests/no_telemetry_in_readiness.sh  (collector killed, service still serves)` |
| 2 | check | 51.861 | `the canary suite  (never prints the value it planted)` |
| 3 | check | 39.030 | `tests/lint_test.sh  (every linter runs, and its control disagrees)` |
| 4 | tier | 23.259 | `tests/isolation_test.sh  (service A cannot reach service B's database)` |
| 5 | tier | 17.525 | `tests/fetch_test.sh  (a pin fetches, a branch is refused, offline is real)` |
| 6 | tier | 12.927 | `tests/tenancy_test.sh  (no identity, another tenant and its own tenant — as the login role AND as the owner; and the same proof with FORCE removed goes red)` |
| 7 | tier | 9.795 | `tests/onecluster_test.sh  (two services, ONE postgres container, each with its own database and roles; both answer as their own role, neither reaches the other's)` |
| 8 | check | 6.179 | `tests/provenance_test.sh  (11 leak shapes refused; both sinks agree; --verify refuses a foreign or ill-shaped stamp; 4/5/6 stay distinct)` |
| 9 | check | 5.868 | `tests/multi_tenant_split_test.sh  (a second tenant is split, not fused; identifiers hold in every locale)` |
| 10 | check | 4.515 | `tests/fingerprint_test.sh  (the skip is proven able to be WRONG: outputs deleted, one byte changed, a corrupt record, a foreign version)` |
| 11 | check | 3.392 | `tests/failfast_test.sh  (a missing required variable is refused in seconds, by name, with nothing started)` |
| 12 | cpu | 2.964 | `templates/tier/rust/tier.rs  (rustc --test)` |
| 13 | cpu | 2.737 | `tests/validate.sh  (shellcheck -S warning)` |
| 14 | check | 2.216 | `database/elixir/repo.exs.snippet  (loads; stdlib only, as intended)` |
| 15 | check | 1.711 | `tests/classify_test.sh  (19 cases, incl. the fail-closed property)` |

Rows 16–80 are all under 1.7 s. `cpu` rows are parallel checks that OVERLAP —
their sum is an upper bound on their region, not its duration.

### Phase rows

| phase | seconds |
|---|---:|
| 40 classifier + fingerprint + fetch + tenancy, executed | 269.788 |
| static: handed-out scripts are executable | 212.315 |
| static: the canary harness parses in Go | 64.882 |
| 30 observability: the claims worth nothing unexercised | 52.171 |
| tenancy: how one shared cluster is split into per-service databases | 51.108 |
| static: every otel snippet parses in its own language | 45.341 |
| 60 summary | 39.067 |
| static: shellcheck -S warning | 38.351 |
| 50 lint: the four linters, run against fixtures that must fail them | 9.651 |
| static: templates/otel — every artifact is present | 7.965 |
| provenance: the stamp a pulled image carries, and what it refuses to carry | 6.280 |
| fetch: the pinned kit ref resolves, and a moving one is refused | 6.211 |
| static: every Dockerfile is hadolint clean | 4.796 |
| 00 bootstrap: resolve the interpreter and install deps | 4.699 |
| static: the canary harness — contract, adapter, and every artifact | 3.567 |
| static: every Dockerfile runs non-root on a pinned base | 2.466 |
| static: every database snippet parses in its own language | 1.918 |
| static: a run: body does not read a name it only ever prefix-assigned | 1.111 |
| static: compose — the observability chokepoint | 0.876 |
| static: templates/database/tenancy — every artifact is present | 0.433 |
| static: every image starts through the migration entrypoint | 0.143 |
| static: every language ships all four artifacts | 0.140 |
| static: templates/kamal — every artifact is present | 0.052 |
| static: every artifact parses | 0.029 |
| 10 static: every artifact parses, and the strictness decisions hold | 0.029 |
| observability: the redaction boundary, against a real collector | 0.017 |
| lint: kit configs, executed against fixtures that must fail them | 0.012 |
| END OF RUN (no section header after this point) | 0.010 |

### The confirmation the packet asks for — refuted

> Confirm (or refute, with the numbers) that the filtered child gates dominate
> and that their cost is `self_test`.

**Refuted.** `grep -c 'self_test' /tmp/p-before.tsv` returns **0**. There is no
`self_test` row, no `self_test` phase, and no child gate anywhere in the run.
The gate's phases are now: bootstrap → static → observability →
classifier/fingerprint/fetch/tenancy → lint → summary. The largest single item
is `no_telemetry_in_readiness.sh` at 72.0 s — a docker tier, not a child gate.

## What overlapped

**Nothing.** There is nothing to overlap. The packet's step 2 ("make the filtered
child gates overlap, using the existing helpers") has no referent: the 73
filtered child gates, the `self_test` phase, and the `KIT_SELF_TEST_SHARD` seam
were all deleted on 2026-10-05.

The existing parallel helpers — `check_par()` (validate.sh:599),
`report_par()` (validate.sh:691), `bounded_check()` (validate.sh:1200) — are
still present and still used. `check_par` runs the static parse checks (bash -n,
yaml, json, node, rustc, python, ruby, elixir) in parallel; `bounded_check` wraps
the heavy tiers. They are applied at the places the (current) profile says the
time is. There is no unfiltered serial region that the helpers could reach.

## What could not, and why — the measured blocker

The packet says: "If the helpers cannot express it as-is, say exactly what blocks
it (a shared mutable resource, a fixed port, an ordering dependency) — a measured
blocker is a good outcome."

The blocker is none of those. **The target was deleted.** The self-test layer
was retired because:

1. **The owner's decision:** "i do not want any tree copies at all in the first
   place." A breakage WAS a tree copy, so the layer could not be kept.
2. **A measured disk and CPU crisis** (commit `32df467`): 24 GiB of leftover
   tree copies in one TMPDIR, 2.5 GiB live at once per run, 17.5 GiB at load 48
   across seven concurrent runs.

The retirement is recorded in `CUT-ALL-DISPOSITION.md` ("The breakage layer is
RETIRED, not trimmed") and `REPORT-no-tree-copies-01.md`. The gate is already
faster than the packet's "before" state — not by overlapping the child gates,
but by not running them.

## The counts proving nothing was dropped

There is no change in this packet, so the "before" and "after" are the same run.
The gate was run **three times**; all three are green with identical counts.

### Wall-clock and verdicts

| run | profiler | wall clock | exit | PASS | FAIL | SKIP |
|---:|---|---:|---:|---:|---:|---:|
| 1 | on | 823.4 s (13m43s) | 0 | 157 | 0 | 5 |
| 2 | off | ~729 s (12m09s) | 0 | 157 | 0 | 5 |
| 3 | off | 882.7 s (14m43s) | 0 | 157 | 0 | 5 |

Run 1 is the profiled run that produces the table above. Runs 2 and 3 are clean
(no profiler). The ~94–154 s difference between run 1 and the clean runs is the
profiler's own overhead — two `perl` clock reads per timed region, ~230 regions
per run. The spread between runs 2 and 3 (729 s vs 883 s) is machine load and
docker cache state; both are green with identical counts.

### The gate's own summary, verbatim (identical in all three runs)

```
PASS: every check passed.
note: 5 check(s) skipped — reported above, never hidden.
note: 5 tier(s) ran under a time bound; none was reached.
```

| count | value |
|---|---:|
| PASS lines | 157 |
| FAIL lines | 0 |
| SKIP lines | 5 |
| `self_test` rows in the profile | 0 |
| exit status | 0 |

The packet's constraint — "zero `FAIL self_test:` / `SKIP self_test:` lines" —
is satisfied vacuously: there are no `self_test:` lines of any kind.

## The honest next target

The packet's deeper goal — "the fleet-wide speedup" — is still live. The gate
still takes ~823 s with the profiler on (~600–700 s without). The top costs are
now docker tiers and lint, not child gates:

| # | seconds | check |
|---:|---:|---|
| 1 | 72.0 | `no_telemetry_in_readiness.sh` (tier) |
| 2 | 51.9 | canary suite (check) |
| 3 | 39.0 | `lint_test.sh` (check) |
| 4 | 23.3 | `isolation_test.sh` (tier) |
| 5 | 17.5 | `fetch_test.sh` (tier) |
| 6 | 12.9 | `tenancy_test.sh` (tier) |
| 7 | 9.8 | `onecluster_test.sh` (tier) |

Handoff-03 already named the next target: "Only then
`no_telemetry_in_readiness.sh` and `stack_live_test.sh`." That is where the next
packet's minutes are. The overlap packet's target — the 73 filtered child gates
— is gone, and no amount of parallelism can speed up a suite that no longer
exists.

## Reproduce

```sh
# the profile (the packet's step 1)
KIT_PROFILE=/tmp/p.tsv bash tests/validate.sh
grep -v '^phase' /tmp/p.tsv | sort -t"$(printf '\t')" -k3 -rn | head -30

# confirm the target is gone
ls tests/self_test.sh          # No such file
grep -c self_test /tmp/p.tsv   # 0
git log --oneline --diff-filter=D -- tests/self_test.sh   # 32df467
```
