# REPORT — kit-gate-speed-overlap-01: the overlap has no target

**Branch** `worker/kit-w40-gatespeed` · **base** `08dcccd` · **date** 2026-10-07

**The one-paragraph answer:** the packet asks me to overlap the 73 filtered
child gates so their `self_test` share is paid once in parallel. **Those child
gates no longer exist.** `tests/self_test.sh` — the 94 breakages, 73 of them
running `--only`-filtered child gates — was deleted on 2026-10-05 by the
owner's explicit decision: *"i do not want any tree copies at all in the first
place."* A breakage in that suite **was** a tree copy, so the layer was retired
whole. There is no `self_test` share left to pay, no `KIT_SELF_TEST_SHARD` seam
to widen, and no child gates to overlap. **No change was made to the gate**,
and this report is the deliverable, per the packet's own escape clause: *"a
measured blocker is a good outcome; a gate that got faster by checking less is
not."*

---

## 1. The blocker, with the evidence

### 1.1 The timeline

| when | what | commit |
| --- | --- | --- |
| 2026-10-02 | handoff-03 written; `tests/self_test.sh` exists, 94 breakages, 73 filtered child gates | `6303318` (last touch of `HANDOFF-kit-gate-speed.md`) |
| 2026-10-05 06:45 | **the self-test layer is deleted** — owner: *"i do not want any tree copies at all in the first place"* | `32df467` |
| 2026-10-05 06:57 | the cut finishes itself: 18 orphaned check bodies removed (incl. the `stack_live` tier invocation) | `9c1a55f` |
| 2026-10-07 | this packet dispatched against the post-retirement tree | — |

`32df467` is an ancestor of `08dcccd` (verified: `git merge-base --is-ancestor`).
Its own message states the mechanism and the cost:

> A "breakage" in this suite WAS a tree copy. `tests/self_test.sh` called
> `fresh_copy`, which made a full copy of this repository per breakage, mutated
> it, and ran a whole `tests/validate.sh` against the copy to see whether the
> gate went red. There is no breakage without a copy. So "no tree copies" and
> "keep some breakages" cannot both be true, and the 10 survivors went with the
> other 110.

Deleted with it, because each existed only to police the layer just removed:
`tests/self_test.sh` (5,611 lines), `tests/shard_test.sh` (413), the `self_test`
phase, `RUN_SELF_TEST`, `--no-self-test`, the `KIT_NO_LIVE` env seam whose only
caller was `kit_child_gate`, `self_test_live_tier`,
`self_test_no_version_literal`, and the `KIT_SELF_TEST_SHARD` seam. The
counting (`_st_breakages` / `_st_reds`) went too — **the "94 breakages, 92
reds" this packet says must not move are derived by nothing anymore.**

`CUT-ALL-DISPOSITION.md` is the disposition as it now stands: *"breakages in
`tests/self_test.sh` | 120 | 0 kept | **120 — the whole layer, retired**"*.

### 1.2 The current tree, verified

- `grep -r 'KIT_SELF_TEST_SHARD\|kit_child_gate\|fresh_copy\|_shard_claims'`
  over `tests/validate.sh` — **no matches**.
- `grep 'self_test' tests/validate.sh` — **no matches** (only historical
  comments in `tenancy_test.sh` and the tenant-isolation adapters, unrelated:
  those are the RLS proof recipes, not the breakage recipes).
- No `expect_red` / `expect_green` / `expect_skip` machinery anywhere in
  `tests/`.
- The gate's phases are now: `00 bootstrap`, `10 static`, `30 observability`,
  `40 classifier + fingerprint + fetch + tenancy, executed`, `50 lint`,
  `60 summary`. There is no self-test phase.

### 1.3 Why re-creating the overlap is not an option

The packet's machinery — `check_par()`, `report_par()`, `bounded_check()` —
is all still present and still used inside the static phase. The helpers are
not the blocker. **The blocker is that their largest historical workload was
retired by owner decision.** Re-introducing child gates, even sharded, means
re-introducing per-breakage tree copies, which is the one thing the owner has
ruled out. That is a decision above this packet's pay grade, and this report
does not attempt to route around it.

---

## 2. The measurement — the current tree, twice, with `KIT_PROFILE`

Both runs are full `KIT_PROFILE=… bash tests/validate.sh` on `08dcccd`, on this
shared box (8 cores, 12+ other sessions' containers observed running
concurrently, disk at 91%).

| | run 1 | run 2 |
| --- | ---: | ---: |
| **wall clock (`total` row)** | **869.917 s** | **968.941 s** |
| exit status | **1** — `onecluster_test.sh`, environmental (§4) | **0** — `PASS: every check passed.` |
| `FAIL` lines | 1 (`onecluster`) | 0 |
| `SKIP` lines | 5 (same five, both runs) | 5 (same five) |
| `self_test` rows in the profile | **none** | **none** |

The five skips are environmental and identical in both runs: three
`templates/database/tenancy/*.sql` parses (no `psql` on this box) and two
`templates/tier/{bun,node}/tier.test.ts` (`node --check` cannot read
TypeScript). They are the gate's honest-skip contract working as designed.

**Run-to-run variance is ~100 s on this box** (869.9 vs 968.9), and the tier
rows move accordingly (`isolation_test` 21.3 s → 59.7 s, `the canary suite`
45.0 s → 24.7 s). Every number here carries that contention; `PROFILE-gate.md`
says the same of its own.

### The profile table — run 1, sorted (the packet's requested shape)

`grep -v '^phase' /tmp/w40-p-before.tsv | sort -t"$(printf '\t')" -k3 -rn | head -30`

| # | kind | seconds | check id |
| ---: | --- | ---: | --- |
| — | **total** | **869.917** | **FULL RUN** |
| 1 | tier | 64.614 | `tests/no_telemetry_in_readiness.sh  (collector killed, service still serves)` |
| 2 | check | 44.951 | `the canary suite  (never prints the value it planted)` |
| 3 | check | 23.925 | `tests/lint_test.sh  (every linter runs, and its control disagrees)` |
| 4 | tier | 21.252 | `tests/isolation_test.sh  (service A cannot reach service B's database)` |
| 5 | tier | 21.226 | `tests/tenancy_test.sh  (no identity, another tenant and its own tenant — as the login role AND as the owner; and the same proof with FORCE removed goes red)` |
| 6 | tier | 16.247 | `tests/onecluster_test.sh  (two services, ONE postgres container, each with its own database and roles; both answer as their own role, neither reaches the other's)` |
| 7 | check | 7.623 | `tests/provenance_test.sh  (11 leak shapes refused; both sinks agree; --verify refuses a foreign or ill-shaped stamp; 4/5/6 stay distinct)` |
| 8 | check | 6.392 | `tests/fingerprint_test.sh  (the skip is proven able to be WRONG: outputs deleted, one byte changed, a corrupt record, a foreign version)` |
| 9 | check | 5.591 | `tests/multi_tenant_split_test.sh  (a second tenant is split, not fused; identifiers hold in every locale)` |
| 10 | check | 3.691 | `tests/classify_test.sh  (19 cases, incl. the fail-closed property)` |
| 11 | check | 3.614 | `tests/failfast_test.sh  (a missing required variable is refused in seconds, by name, with nothing started)` |

Rows 12–30 are all `cpu` (parallel `check_par` children — overlapping, their
sum is an upper bound on their region) and sub-2 s checks. **There is no
`self_test` row, no child-gate row, and no `tag` column populated by breakage —
the population the packet targets is not in the table because it is not in
the tree.**

For comparison, run 2's top rows (same shape, different contention):

| # | kind | seconds | check id |
| ---: | --- | ---: | --- |
| — | **total** | **968.941** | **FULL RUN** |
| 1 | tier | 69.802 | `tests/no_telemetry_in_readiness.sh` |
| 2 | tier | 59.719 | `tests/isolation_test.sh` |
| 3 | check | 42.859 | `tests/lint_test.sh` |
| 4 | check | 24.733 | `the canary suite` |
| 5 | tier | 24.368 | `tests/tenancy_test.sh` |
| 6 | tier | 9.738 | `tests/onecluster_test.sh` |

### What the old profile predicted vs. what is actually here

| | `PROFILE-gate.md` (corrected) | measured here |
| --- | ---: | ---: |
| `tests/self_test.sh` | ~774 s after the `--only` reach | **0 s — the phase does not exist** |
| full `tests/validate.sh` | ~4,882 s, projected | **869.9 s / 968.9 s, measured** |

The gate is now **~5.9× smaller** than the old projected full run (5,103 / 869.9). That
reduction came from the retirement (`32df467` + `9c1a55f`), not from any speed
work — and it is the reason this packet has nothing to act on.

---

## 3. What remains in the gate, and why none of it is this packet's target

The current 869.9 s, by phase (run 1):

| phase | seconds | share | what is in it |
| --- | ---: | ---: | --- |
| `40 classifier + fingerprint + fetch + tenancy, executed` | 395.0 | 45% | **the observability tiers** (canary suite 45.0 + no_telemetry 64.6 + isolation 21.3 + tenancy 21.2 + onecluster 16.2 ≈ 168 s) **plus** the executed checks (classify 3.7, fingerprint 6.4, provenance 7.6, fetch 0.2, multi-tenant 5.6, failfast 3.6 ≈ 27 s) — the phase row is named by the marker that *closes* it, so it spans the whole observability block |
| `static: handed-out scripts are executable` | 147.0 | 17% | the `bash -n` / shellcheck sweep over every handed-out script |
| `static: the canary harness parses in Go` | 117.8 | 14% | the Go canary harness build + parse |
| `static: every otel snippet parses in its own language` | 68.1 | 8% | per-language snippet parse loop |
| `30 observability` (tail) + sections | 45.2 | 5% | the redaction-boundary section header interval |
| `static: shellcheck -S warning` | 36.5 | 4% | the shellcheck sweep |
| `60 summary` | 24.0 | 3% | the summary itself |
| `50 lint` | 9.4 | 1% | the four linters against fixtures |
| the rest | < 10 each | — | bootstrap, fetch, tenancy-parse, and the small static sections |

The two biggest single items are `no_telemetry_in_readiness.sh` (64.6–69.8 s)
and `the canary suite` (24.7–45.0 s). **Both are docker-backed tiers, and
overlapping them is exactly what this packet's own constraint forbids:**
*"Parallelism that races on a port, a container, a temp dir or the shared
stack is worse than slow."* The tiers bring up real stacks on fixed port
blocks (15008–15012 and siblings) on a box where other sessions' stacks are
already running. handoff-03 records the same scoping decision: the tiers are
*"still untouched — last, as planned."* Overlapping them is a later packet's
decision, and it is a safety decision, not a scheduling one.

---

## 4. The onecluster failure in run 1, and what it is

Run 1 exited 1 with:

```
FAIL tests/onecluster_test.sh  (two services, ONE postgres container, …)
       FAIL expected a database named alpha; found 'psql: error: … FATAL:  the database system is shutting down'
       … (same "shutting down" on ~10 assertions)
       PASS both services answer as their OWN role: wrote, read back, and pgvector answered in alpha and in beta
```

The postgres container was **shutting down mid-test** and came back seconds
later (the later PASSes in the same run prove it recovered). Run 2, same tree,
same command: `PASS tests/onecluster_test.sh`, exit 0. **This is an
environmental flake on a shared box**, not a defect in the tree and not
something any change of mine caused — I made none. It is named here because it
is a real risk for any future gate-speed work on this machine: a tier that
brings up a postgres container can have that container killed or restarted
under load from concurrent sessions (12+ foreign containers were observed
running during these runs, disk at 91%). The gate's `bounded_check` machinery
is what keeps this a named `FAIL` with a red proof rather than a silent pass —
and it worked.

---

## 5. The counts, proving nothing was dropped

- **The tree is unchanged.** `git status` was clean at `08dcccd` when this
  packet started (the resume note's "partial work from a previous attempt"
  does not exist — attempt 1 made no change). The only commit this packet
  adds is this report. Nothing was dropped because nothing was touched.
- **The gate's own counts are stable across both runs:** 5 `SKIP` lines, the
  same five, both runs; every other check passes (run 2, exit 0). The
  `note: 5 tier(s) ran under a time bound; none was reached.` line is
  identical in shape.
- **The packet's counts — "94 breakages, 92 reds" — are gone with the layer
  they described.** Nothing in `tests/validate.sh` derives them anymore
  (`grep 'self_test' tests/validate.sh` → no matches). They cannot move
  because nothing computes them; the retirement is the reason, and
  `CUT-ALL-DISPOSITION.md` is the record.
- **The eight behaviours the self-test existed to protect are still
  protected without a tree copy** — `AGENTS.md` §"The suite has no self-test"
  carries the table: the postgres tag, the cluster topology, the connection
  budget and the account boundary are direct reads of the real tree (a defect
  is a one-line edit and a `git checkout`); the secret scan, the canary
  literal and the canary output are proven against fixtures the checks
  assemble themselves; the lint gate is proven by construction. That is the
  owner's chosen replacement, and it is why re-creating child gates would not
  only reverse a decision but duplicate a coverage that already exists.

---

## 6. What a future packet could target, and what it would need

Measured, in order of size, on the current tree:

1. **`no_telemetry_in_readiness.sh` — 64.6–69.8 s.** A docker tier. Any
   overlap races on the stack's port block and the shared docker daemon.
2. **`the canary suite` — 24.7–45.0 s.** Also docker-backed (it plants a
   canary and sweeps exporters against a real collector).
3. **`tests/lint_test.sh` — 23.9–42.9 s.** Runs four linters against
   fixtures; the fixtures are throwaway directories, so this one is
   *technically* overlappable — but it is already inside the lint phase's
   own structure and its cost is four sequential linter invocations, not
   forty serial checks.
4. **The static phase's `bash -n` / shellcheck sweeps (147.0 + 36.5 s).**
   These already run as `check_par` children — they **are** the existing
   parallelism, working as designed.

The honest summary: **the fleet-wide speedup this packet was commissioned for
already happened, by retirement, not by overlap.** The gate went from a
projected ~5,103 s to a measured 869.9 s on the same box. What remains is
docker-tier time that the packet's own flakiness constraint puts out of scope,
and that is where the next speed conversation should start — with the owner,
not with a scheduling change.
