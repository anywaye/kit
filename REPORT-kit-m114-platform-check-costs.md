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

## Q2: what the two profiles say (baseline 199s wall, final 154s wall)

Two full runs, same command `KIT_PROFILE=<tsv> bash tests/validate.sh`, no
flags, both exit 0 (`/tmp/gate-kit-gate-costs-baseline.{wall,exit,log,tsv}`,
`/tmp/gate-kit-gate-costs-final.{wall,exit,log,tsv}`). Profile totals track
wall: 198.64s baseline, 153.93s final. Caution on arithmetic: `phase` rows are
inter-mark spans and nest (e.g. phase 40 contains the provenance/fetch/tenancy
sub-phases), so they are NOT additive — the additive truth is wall plus the
per-command `tier`/`check` rows below. All durations are command runtimes from
the profile TSVs, baseline -> final:

| expensive command (tier/check row) | baseline | final | catches |
| --- | --- | --- | --- |
| tier `no_telemetry_in_readiness.sh` | 63.95 | 63.96 | service starts, serves and reports healthy with the collector killed (live redaction-boundary runtime proof) |
| check `lint_test.sh` | 21.04 serial | 21.04 overlapped (span row 131.87 = spawn-to-verdict, not CPU) | kit's four lint configs WORK against fixtures built to violate exactly one rule, each paired with a disagreeing control |
| tier `isolation_test.sh` | 15.90 | 13.74 | service A cannot reach service B's database; 4th assertion runs a control cluster WITHOUT the revoke and requires it to let A in |
| tier `tenancy_test.sh` | 10.82 | 10.82 | account boundary: no-identity / wrong-tenant / own-tenant as login AND owner roles, plus the FORCE-removed control going red while login stays green |
| check `onecluster_ports_race_test.sh` | 10.07 | 10.09 | two concurrent port-block selections with the same seed never share a block (the reason docker tiers stay serial) |
| tier `onecluster_test.sh` | 9.91 | 9.67 | `bin/dev up` path (not a compose file): two services, one container, each answers as its own role, neither reaches the other |
| tier/check `fetch_test.sh` | 8.99 (tier, cache miss) | 0.12 (check, cache hit) | pinned kit ref resolves, branch refused, offline real (`kit_cached_check` on `fetch_test.sh,bin/dev.sh,VERSION` — none changed between runs, so the hit is by-design) |
| check `failfast_test.sh` | 8.28 | 8.55 | missing required variable refused in seconds, by name, with nothing started; control run with the variable set must reach compose |
| check `install host bundle` (wrangler build) | 6.14 | 1.89 | Worker bundle serves `install.sh` byte-exact; build-cache variance, not a change |
| phase `canary harness parses in Go` | 5.32 | 4.77 | canary adapter compiles (static; the live canary tiers are gone — proven by static literal/output checks + executed `canary_test.sh` shape) |
| check `provenance_test.sh` | 5.37 | 5.11 | 11 leak shapes refused; both sinks agree; `--verify` refuses foreign stamps |
| phase 00 bootstrap (venv build) | 4.88 | 0.04 | interpreter resolve + dep install; second run reused gitignored `.venv/` — environmental, not a change |
| check `multi_tenant_split_test.sh` | 4.35 | 3.96 | second tenant is split, not fused |
| check `fingerprint_test.sh` | 4.11 | 3.87 | skip record can be WRONG (deleted outputs, one changed byte, corrupt record, foreign version) |
| par regions (82 + 42 static checks) | ~3.5 + ~3.9 wall | same shape | per-file parse loops already parallel via `check_par` (cap 4) — static is done being optimized |

Final-gate verdicts (authoritative: the manager's full merged-worktree run,
not a worker claim): exit 0, wall 154s, 206 PASS, 0 FAIL, 0 BOUND,
`note: 5 check(s) skipped`, `note: 5 tier(s) ran under a time bound; none was
reached`. The 5 SKIP lines in the final log are exactly the 5 expected
explicit skips: three SQL files parsed only against live Postgres
(`tenancy/{advisor,isolation,substrate}.sql`, via `tenancy_test.sh`) and two
TS files `node --check` cannot read (`tier/{bun,node}/tier.test.ts`). All
docker tiers passed. The 5 bounded tiers are the one live tier
(`no_telemetry_in_readiness`, `live_check` bound 900) plus the three cluster
tiers (`isolation`, `tenancy`, `onecluster`, `bounded_check` 1800 each) plus
`failfast` (bounded where it runs).

Equivalent coverage, per expensive check — the short version is that every one
has a cheap static counterpart that is necessary but NOT sufficient, which is
why the live half survives:

- Readiness: static `compose + bin/dev (telemetry never in a readiness path)`
  (0.06s) states the rule; only the 64s live tier proves a service serves with
  the collector dead.
- DB boundaries: static `contract`, `tenancy/*`, `cluster`, `connection
  budget` checks (~0.03s each) assert the wiring; only the live tiers execute
  the denial, and only their controls (no-revoke cluster; FORCE removed) prove
  the suite can go red.
- Lint: `yaml.safe_load` / `node --check` on the configs prove they parse;
  only `lint_test.sh` proves a linter REJECTS a violation with kit's config.
  Fatal on skip by design.
- Fetch/failfast/ports-race/provenance/fingerprint/route/classify: executed by
  design outside the `RUN_*` guards; each carries its own red control (refused
  branch, unconditional-refusal control, collided-blocks proof, foreign stamp,
  corrupt record, fail-closed routing cases).

Where routed in CI (`tests/route.sh`, verified header + `focused_tier.sh`
"WHAT IT DOES NOT RUN"): `docs` runs a whitespace check only; `tier` and
`publish` run focused parse proofs with NO telemetry, observability, lint,
tenancy, substrate or chart-publish. Everything else — push, schedule, manual,
empty/uncomputable diffs, mixed families, workflow and test changes,
unrecognised paths (fails closed) — is `full`: the reusable workflow,
`language: none`, i.e. `tests/validate.sh` with no flags. Required check is
`ci / gate` only. So the expensive rows above run ONLY in `full`, which is
every push plus the PRs most likely to break the platform. There is no
cheaper route that still exercises them, and the focused routes already skip
them.

## Q3: the one change (commits `f9746c8`, `21fcd4c`) — overlap lint with docker

Exact optimization, and the only product-code change in this packet:
`tests/lint_test.sh` (~21s deterministic fixture test: throwaway service in a
private tempdir, no containers, no published ports, no daemon) now starts in
the background just above the observability phase (`tests/validate.sh:4995-5049`)
and its verdict is collected at the lint section in the same position with the
same label (`:5319-5350`). Same command, same arguments, same verdict mapping
as `check` (including `SKIP_EXIT` and the `set -e`-safe `wait`-in-`if`), same
output position — gate output order is unchanged. `--only` runs that exclude
lint spawn nothing (mirroring `check`'s early return, including
`ONLY_SKIPPED` accounting); `--no-lint` is untouched. Docker tiers stay serial
among themselves: they share the daemon and the fixed port block, and the
ports-race control exists because concurrent runs collided — overlapping one
NON-docker check with them is the shape that rule permits.

Evidence, measured not argued. Baseline (original tree): exit 0, wall 199s.
Final (merged worktree, after both commits): exit 0, wall 154s — the manager's
run, `KIT_PROFILE=/tmp/gate-kit-gate-costs-final.tsv bash
tests/validate.sh`. Decomposition of the ~45s wall delta: ~21s is the change
(serial lint 21.04s removed from the critical path; lint work still executed —
final log shows `PASS tests/lint_test.sh` with all 22 sub-assertions at the
lint section). The remainder is rerun warmth, not the change: bootstrap
`.venv/` reuse 4.8s, `kit_cached_check` fetch hit 8.9s, wrangler build cache
4.2s, isolation/docker variance 2.2s, substrate/canary ~2.4s. The final
profile's lint row reading 131.87s is the spawn-to-verdict span across the
overlapped phases, not lint CPU — lint's own runtime is unchanged.

Incident record, kept because the alternative is a mystery the next reader
re-litigates: one manager attempt at the full gate failed on a syntax error
from a stale apostrophe in a comment label introduced with the overlap commit.
Fixed in `21fcd4c`, full gate re-run after it: exit 0, 154s. The failed syntax
attempt is NOT a gate result; the manager's post-fix full gate above is the
authoritative final result. No further gate runs after that (per instruction).

Per-check verdicts — keep, remove, or move — with the risk stated plainly:

- `no_telemetry_in_readiness` (64s, 42% of wall): KEEP in `full`. Removal risk
  HIGH — it is the only runtime proof behind the redaction boundary; the static
  rule cannot serve a request. Cannot move earlier (needs the live stack) or
  parallelize (shares the daemon/ports with the cluster tiers).
- `isolation` / `tenancy` / `onecluster` (~35s combined): KEEP in `full`.
  Removal risk HIGH — the database boundary and the account boundary are the
  two isolation claims kit makes, and unexercised security properties are worth
  nothing (their controls prove the suite bites). Serial by rule (see
  ports-race row).
- `lint_test` (21s, now overlapped): KEEP in `full`, keep overlapped. Removal
  risk HIGH — it is the only proof the lint configs work; parse checks cannot
  reject anything. This packet took the last safe saving; further moving (e.g.
  into a focused route) would make `full` assert configs nobody executed.
- `fetch` / `failfast` / `ports-race` / `provenance` / `fingerprint` /
  `multi-tenant-split` / `install-host` / `substrate` / `chart-publish` /
  `nats-stream` / `route` / `classify` (all <11s, most <6s, fetch cached):
  KEEP as-is. Each is the executed half of a fail-closed property with its own
  red control; none has an overlapping execution partner left to hide behind,
  and their sum outside docker is noise next to the 64s live tier.
- Static/par phases (~8s wall for 124 checks): DONE — already parallel at cap
  4. No action.

Conclusion: no further safe removal or move exists. The expensive rows run
only in `full` (every push + risky PRs — exactly where the cost is the point),
the focused routes already skip them, the one overlap-safe check is overlapped,
and the remaining wall is one 64s live proof plus serial docker tiers that are
serial by rule. Any future saving is a smaller live tier, not a routing change.

## Q4: limitations and handoff

- Single machine, one baseline run and one final run, with five other workers'
  gates sharing the box (the bounds — 900/1800 — exist for exactly this).
  The ~24s non-change delta is warmth + contention variance; re-runs will
  differ by single-digit seconds per docker tier (isolation moved 2.2s between
  the two runs with no code change touching it).
- `phase` rows nest and are not additive; wall + per-command rows are the
  evidence. The final lint span row (131.87s) measures overlap span, not cost.
- The stale-comment fix (`21fcd4c`) also corrected the live-tier split the old
  comment recorded (128.8s/50.5% predated the current gate: canary and
  stack_live live tiers are gone): measured on this tree, live tier ~64s
  (~42% of the 154s wall), cluster tiers ~34s (~22%).
- Q1 baseline above is preserved as the packet's starting truth; nothing in it
  was edited.
- This commit is report-only: no product source or test changed here. Prior
  commits on this branch hold the change (`f9746c8` overlap, `21fcd4c`
  comment correction).
- NO REMAINING ACTION except manager review (merge decision). No further gate
  runs needed or instructed; do not push from this worktree.
