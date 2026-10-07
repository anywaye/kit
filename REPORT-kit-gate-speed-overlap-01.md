# REPORT — kit-gate-speed-overlap-01: the overlap has no target

**Branch** `worker/kit-w40-gatespeed` · **base** `08dcccd` · **date** 2026-10-07

**The one-paragraph answer:** the packet asks me to overlap the 73 filtered
child gates so their `self_test` share is paid once in parallel. **Those child
gates no longer exist.** `tests/self_test.sh` — the suite that ran them — was
deleted on 2026-10-05 by the owner's explicit decision: *"i do not want any
tree copies at all in the first place."* A breakage in that suite **was** a
tree copy, so the layer was retired whole. There is no `self_test` share left
to pay, no `KIT_SELF_TEST_SHARD` seam to widen, and no child gates to overlap.
**No change was made to the gate**, and this report is the deliverable, per
the packet's own escape clause: *"a measured blocker is a good outcome; a gate
that got faster by checking less is not."*

**A note on this report's own history.** Two concurrent attempts worked this
packet on this branch. `4e8261d` (03:29) reached the same diagnosis with three
green runs; this attempt measured twice more and documented an environmental
flake. Both are correct; **this file consolidates the two**, keeping the
strongest evidence from each. The conclusion is identical in both: the
premise is refuted with numbers.

---

## 1. The blocker, with the evidence

### 1.1 The timeline

| when | what | commit |
| --- | --- | --- |
| 2026-10-02 | handoff-03 written; `tests/self_test.sh` exists, 94 breakages, 73 filtered child gates | `6303318` (last touch of `HANDOFF-kit-gate-speed.md`) |
| 2026-10-05 06:45 | **the self-test layer is deleted** — owner: *"i do not want any tree copies at all in the first place"* | `32df467` |
| 2026-10-05 06:57 | the cut finishes itself: 18 orphaned check bodies removed (incl. the `stack_live` tier invocation) | `9c1a55f` |
| 2026-10-07 | this packet dispatched against the post-retirement tree | — |

`32df467` is an ancestor of `08dcccd` (verified: `git merge-base
--is-ancestor`). Its own message states the mechanism and the cost:

> A "breakage" in this suite WAS a tree copy. `tests/self_test.sh` called
> `fresh_copy`, which made a full copy of this repository per breakage, mutated
> it, and ran a whole `tests/validate.sh` against the copy to see whether the
> gate went red. There is no breakage without a copy. So "no tree copies" and
> "keep some breakages" cannot both be true.

Deleted with it, because each existed only to police the layer just removed:

| removed | lines |
| --- | ---: |
| `tests/self_test.sh` | 5,611 |
| `tests/shard_test.sh` | 413 |
| the `self_test` phase, `RUN_SELF_TEST`, `--no-self-test`, the `KIT_SELF_TEST_SHARD` seam, `kit_child_gate`, `fresh_copy`, the `_st_breakages`/`_st_reds` counting, and related checks in `tests/validate.sh` | 536 |

**The "94 breakages, 92 reds" this packet says must not move are derived by
nothing anymore** — the counting went with the layer.

`CUT-ALL-DISPOSITION.md` is the disposition as it now stands: *"breakages in
`tests/self_test.sh` | 120 | 0 kept | **120 — the whole layer, retired**"*.
The measured cost that motivated it: 24 GiB of leftover tree copies in one
TMPDIR, 2.5 GiB live at once per run, 17.5 GiB at load 48 across seven
concurrent runs.

### 1.2 The current tree, verified

- `grep -r 'KIT_SELF_TEST_SHARD\|kit_child_gate\|fresh_copy\|_shard_claims'`
  over `tests/validate.sh` — **no matches**.
- `grep 'self_test' tests/validate.sh` — **no matches** (only historical
  comments, e.g. line 2952 "self-test breakage 72 green", and the unrelated
  RLS proof recipes in `tenancy_test.sh` / `tenant_isolation/adapters/`).
- No `expect_red` / `expect_green` / `expect_skip` machinery anywhere in
  `tests/`. No script in `tests/` spawns a child `validate.sh` gate.
- The gate's phases are now: `00 bootstrap`, `10 static`, `30 observability`,
  `40 classifier + fingerprint + fetch + tenancy, executed`, `50 lint`,
  `60 summary`. There is no self-test phase.

### 1.3 The packet's numbers vs. reality

| the packet's number | reality on this tree |
| --- | --- |
| "one child gate, `--only` one check → 7.88 s" | no child gates run |
| "share of `self_test` in the 73 ALREADY-filtered gates → ~85%" | there are no filtered gates |
| "94 breakages, 92 reds" (handoff-03, the counts that "must not move") | the breakage count is **0** |
| "`tests/validate.sh` derives counts from `tests/self_test.sh`" | it derives nothing from a file that does not exist |

### 1.4 Why re-creating the overlap is not an option

The packet's machinery — `check_par()` (validate.sh:599), `report_par()`
(validate.sh:691), `bounded_check()` (validate.sh:1200) — is all still present
and still used; `check_par` runs the static parse checks in parallel and
`bounded_check` wraps the heavy tiers. **The helpers are not the blocker. The
blocker is that their largest historical workload was retired by owner
decision.** Re-introducing child gates, even sharded, means re-introducing
per-breakage tree copies — the one thing the owner has ruled out, for a
measured disk-and-CPU crisis. That is a decision above this packet's pay
grade, and this report does not attempt to route around it.

---

## 2. The measurement — five full-gate runs on `08dcccd`

All runs are full `bash tests/validate.sh` on this shared box (8 cores, 12+
other sessions' containers observed running concurrently, disk at 91%).

| run | profiler | wall clock | exit | PASS | FAIL | SKIP | note |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | --- |
| 1 | on | **823.4 s** | 0 | 157 | 0 | 5 | profiled; the table below |
| 2 | off | **~729 s** | 0 | 157 | 0 | 5 | clean |
| 3 | off | **882.7 s** | 0 | 157 | 0 | 5 | clean |
| 4 | on | **869.9 s** | **1** | 155 | 1 | 5 | `onecluster_test.sh`, environmental — §4 |
| 5 | on | **968.9 s** | 0 | 157 | 0 | 5 | green; onecluster passed |

Runs 1–3 are the concurrent attempt's; runs 4–5 are this attempt's. **Every run
has the same five skips** (three `templates/database/tenancy/*.sql` parses —
no `psql` on this box; two `templates/tier/{bun,node}/tier.test.ts` —
`node --check` cannot read TypeScript). The gate's own summary, verbatim,
identical in every green run:

```
PASS: every check passed.
note: 5 check(s) skipped — reported above, never hidden.
note: 5 tier(s) ran under a time bound; none was reached.
```

The packet's constraint — *"zero `FAIL self_test:` / `SKIP self_test:` lines
are allowed"* — is satisfied vacuously: **there are no `self_test:` lines of
any kind**, because there is no `self_test` phase.

Run-to-run spread is ~240 s (729–968.9) on this box; the profiler adds
~94–154 s of that (two `perl` clock reads per timed region, ~230 regions per
run), and the rest is contention and docker cache state. Every number here
carries that; `PROFILE-gate.md` says the same of its own.

### The profile table — run 1, sorted (the packet's requested shape)

`grep -v '^phase' /tmp/p.tsv | sort -t"$(printf '\t')" -k3 -rn | head -30`

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

Rows 12–80 are all under 3.0 s. `cpu` rows are parallel `check_par` children —
they OVERLAP, so their sum is an upper bound on their region, not its
duration. **There is no `self_test` row, no child-gate row, and no breakage
`tag` anywhere in the table** — the population the packet targets is not in
the profile because it is not in the tree.

This attempt's runs confirm the same shape at different contention
(`no_telemetry` 64.6–69.8 s, `the canary suite` 24.7–51.9 s, `lint_test`
23.9–42.9 s across runs 4–5; the tier order itself moves with the load).

### The confirmation the packet asks for — refuted

> Confirm (or refute, with the numbers) that the filtered child gates dominate
> and that their cost is `self_test`.

**Refuted.** `grep -c 'self_test' /tmp/p.tsv` returns **0**. The largest
single item in the profile is `no_telemetry_in_readiness.sh` at 72.0 s — a
docker tier, not a child gate. The gate's own phases are bootstrap → static →
observability → classifier/fingerprint/fetch/tenancy → lint → summary.

---

## 3. What overlapped, what could not, and why

**Nothing overlapped — there is nothing to overlap.** The packet's step 2
("make the filtered child gates overlap, using the existing helpers") has no
referent: the 73 filtered child gates, the `self_test` phase, and the
`KIT_SELF_TEST_SHARD` seam were all deleted on 2026-10-05.

The blocker is not a shared mutable resource, a fixed port, or an ordering
dependency. **The target was deleted**, by owner decision, for a measured
disk-and-CPU crisis (§1.1). The existing helpers are applied at the places the
current profile says the time is; there is no unfiltered serial region left
that they could reach.

---

## 4. The onecluster failure in run 4, and what it is

Run 4 (this attempt's first) exited 1 with:

```
FAIL tests/onecluster_test.sh  (two services, ONE postgres container, …)
       FAIL expected a database named alpha; found 'psql: error: … FATAL:  the database system is shutting down'
       … (same "shutting down" on ~10 assertions)
       PASS both services answer as their OWN role: wrote, read back, and pgvector answered in alpha and in beta
```

The postgres container was **shutting down mid-test** and came back seconds
later (the later PASSes in the same run prove it recovered). Run 5, same tree,
same command: `PASS tests/onecluster_test.sh`, exit 0 — as did all three of
the concurrent attempt's runs. **This is an environmental flake on a shared
box**, not a defect in the tree and not something any change caused — no
change was made. It is named here because it is a real risk for any future
gate-speed work on this machine: a tier that brings up a postgres container
can have that container killed or restarted under load from concurrent
sessions. The gate's `bounded_check` machinery is what keeps this a named
`FAIL` with a red proof rather than a silent pass — and it worked.

---

## 5. What remains in the gate, and why none of it is this packet's target

The current ~823 s (profiler on), by phase (run 1):

| phase | seconds | share | what is in it |
| --- | ---: | ---: | --- |
| `40 classifier + fingerprint + fetch + tenancy, executed` | 269.8 | 33% | **the observability tiers** (canary 51.9 + no_telemetry 72.0 + isolation 23.3 + tenancy 12.9 + onecluster 9.8 ≈ 170 s) **plus** the executed checks (classify, fingerprint, provenance, fetch, multi-tenant, failfast ≈ 25 s) — the phase row is named by the marker that *closes* it, so it spans the whole observability block |
| `static: handed-out scripts are executable` | 212.3 | 26% | the `bash -n` / shellcheck sweep over every handed-out script |
| `static: the canary harness parses in Go` | 64.9 | 8% | the Go canary harness build + parse |
| `30 observability` (tail) + sections | 52.2 | 6% | the redaction-boundary section header interval |
| `tenancy: how one shared cluster is split…` | 51.1 | 6% | the tenancy parse check section |
| `static: every otel snippet parses in its own language` | 45.3 | 5% | per-language snippet parse loop |
| `60 summary` | 39.1 | 5% | the summary itself |
| `static: shellcheck -S warning` | 38.4 | 5% | the shellcheck sweep |
| `50 lint` | 9.7 | 1% | the four linters against fixtures |
| the rest | < 8 each | — | bootstrap, fetch, and the small static sections |

The biggest single items are `no_telemetry_in_readiness.sh` (64.6–72.0 s) and
`the canary suite` (24.7–51.9 s). **Both are docker-backed tiers, and
overlapping them is exactly what this packet's own constraint forbids:**
*"Parallelism that races on a port, a container, a temp dir or the shared
stack is worse than slow."* The tiers bring up real stacks on fixed port
blocks (15008–15012 and siblings) on a box where other sessions' stacks are
already running. handoff-03 records the same scoping decision: the tiers are
*"still untouched — last, as planned."* Overlapping them is a later packet's
decision, and it is a safety decision, not a scheduling one.

**The honest summary: the fleet-wide speedup this packet was commissioned for
already happened — by retirement, not by overlap.** The gate went from a
projected ~5,103 s to a measured 729–968.9 s on the same box (~5.3–7.0×
smaller). What remains is docker-tier time that this packet's flakiness
constraint puts out of scope.

---

## 6. The counts, proving nothing was dropped

- **The gate is unchanged.** No commit on this branch touches `tests/`,
  `templates/`, `lint/`, `docker/`, or `.github/` — the only changes are this
  report and its CHANGELOG entry. Nothing was dropped because nothing was
  touched.
- **The gate's own counts are stable across all five runs:** 157 `PASS`, 0
  `FAIL`, 5 `SKIP` (run 4's single FAIL is the environmental flake, §4 —
  155 PASS / 1 FAIL / 5 SKIP, same five skips; the flake cost the tier two
  of its PASS lines when it bailed early). The five skips are the same
  environmental five in every run.
- **The packet's counts — "94 breakages, 92 reds" — are gone with the layer
  they described.** Nothing in `tests/validate.sh` derives them anymore
  (`grep 'self_test' tests/validate.sh` → no matches). They cannot move
  because nothing computes them; the retirement is the reason, and
  `CUT-ALL-DISPOSITION.md` is the record.
- **The eight behaviours the self-test existed to protect are still protected
  without a tree copy** — `AGENTS.md` §"The suite has no self-test" carries
  the table: the postgres tag, the cluster topology, the connection budget and
  the account boundary are direct reads of the real tree (a defect is a
  one-line edit and a `git checkout`); the secret scan, the canary literal and
  the canary output are proven against fixtures the checks assemble
  themselves; the lint gate is proven by construction. That is the owner's
  chosen replacement, and it is why re-creating child gates would not only
  reverse a decision but duplicate a coverage that already exists.

---

## 7. Reproduce

```sh
# the profile (the packet's step 1)
KIT_PROFILE=/tmp/p.tsv bash tests/validate.sh
grep -v '^phase' /tmp/p.tsv | sort -t"$(printf '\t')" -k3 -rn | head -30

# confirm the target is gone
ls tests/self_test.sh          # No such file
grep -c self_test /tmp/p.tsv   # 0
git log --oneline --diff-filter=D -- tests/self_test.sh   # 32df467
```
