# REPORT-kit-m114-platform-check-costs.md — Q1 increment (baseline running)

Packet m114: decide which kit platform checks earn their cost, then remove
avoidable delay. Worktree `kit-gate-costs`, base `23e55f6`.

## Q1: current truth, read from the tree (not from older docs)

Gate: `bash tests/validate.sh`. No `bin/prime`, no `tests/self_test.sh`
(verified absent on this tree — not reintroduced).

CI routes (`ci.yml`, m111, unchanged here): `route` classifies each PR into
exactly one of `docs` (whitespace check only), `tier` (focused tier proof),
`publish` (focused publish proof), `full` (reusable workflow,
`language: none`, i.e. `tests/validate.sh` with no flags). Push, schedule,
workflow_dispatch, empty/uncomputable diffs, mixed families, workflows and
tests changes are all `full`. Required check is `ci / gate` only.

Gate phases in current `tests/validate.sh` (5329 lines):

1. static — parse/semantic checks over every artifact; per-file loops already
   parallelised via `check_par` (cap 4, `KIT_PARALLEL_CHECKS`).
2. telemetry — six W3C traceparent template suites, executed where the
   toolchain exists, else reported SKIP (node suite executed; others parse).
3. observability (docker) — `no_telemetry_in_readiness.sh` (live_check, bound
   900), `isolation_test.sh`, `tenancy_test.sh`, `onecluster_test.sh`
   (bounded_check, 1800 each). SKIP loudly without a daemon.
4. classifier + fingerprint + router + probes + ports-race + provenance +
   fetch (cached) + multi-tenant-split + failfast — executed, outside RUN_*
   guards by design.
5. lint — `tests/lint_test.sh` executes all four linters against fixtures;
   fatal on skip by design.

Stale-comment findings verified against current code (not repeated from old
docs): the observability header still claims "THE THREE BELOW GO THROUGH
`live_check`" (canary 19.1s + readiness 63.6s + stack_live 46.1s = 128.8s of
a 255.2s run), but current code has exactly ONE `live_check` call
(`no_telemetry_in_readiness.sh`). `tests/stack_live_test.sh` exists on disk
and is NOT invoked by the gate; the canary live tier is likewise gone — the
canary is now proven by static `canary_literal_check`, `canary_output_check`
and the executed `canary_test.sh` shape (to be confirmed from the profile).
So the recorded 128.8s/50.5% figure predates the current gate and the
baseline below replaces it.

## Baseline (running)

`KIT_PROFILE=/tmp/gate-kit-gate-costs-baseline.tsv bash tests/validate.sh`,
backgrounded with captured exit, `set -o pipefail` throughout. Phase table,
check-by-check necessity/cost assessment, and any justified change follow in
Q2/Q3 once the profile lands.
