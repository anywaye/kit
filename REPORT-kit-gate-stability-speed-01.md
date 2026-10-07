# REPORT-kit-gate-stability-speed-01 — the port race (fixed) and the speedup (blocked, measured)

Branch `worker/kit-w99-gate`. Q1 commit `a73d5b1` (port-claim fix + race
control + gate wiring); CHANGELOG entry follows it. The full gate was started
in the background at dispatch (`/tmp/gate-kit-w99-gate.log`, exit code to
`/tmp/gate-kit-w99-gate.exit`) and was still in the observability phase at
EOT — its verdicts are therefore NOT in this report and the successor's first
job is to collect them (paths below).

## 1. Deliverable 1 — DONE: the onecluster port race is claimed, red-first

**Red (old code, verbatim loop, two concurrent selectors forced to the same
start offset to model same-seed runs):**

```
run A chose: 15500
run B chose: 15500
RED: same block handed to two live runs
```

**Fix (`tests/onecluster_test.sh`):** block selection `mkdir`-claims
`$CLAIM_DIR/<block>` (default `${TMPDIR:-/tmp}/kit-onecluster-claims`), which
is atomic across runs — the first run to name a block owns it, the second
skips it. A CLAIM, not a LOCK (`flock` around probe *and* bind): a lock held
until the stack is up serializes whole startups (minutes); a claim serializes
only selection (milliseconds) and lets two stacks start in parallel on
different blocks. The claim is released in the EXIT `cleanup` trap; a claim
whose owner pid is dead (`kill -0` fails — kill -9 between mkdir and trap) is
reclaimed, a live holder is never disturbed. The real-port probe still runs
after claiming, for occupants that are not kit runs. `KIT_ONECLUSTER_SEED`
overrides the `$$ % 400` start offset for the control only;
`KIT_ONECLUSTER_CLAIM_DIR` overrides the shared dir (the control points it at
a temp dir so it never touches live claims).

**Green (new code, same concurrency, same seed):**

```
PASS ports race: two concurrent selections with the same seed diverged (15007 vs 15008)   (10.07 s)
```

Edge paths verified individually: claim released on exit (0 leftovers);
stale claim (dead pid) reclaimed (15099 taken); live holder (own pid) skipped
(15100 taken). `bash -n` and `shellcheck -S warning` clean on both files.
`--select-block` holds the claim during a sleep modelling the probe...bind
window — without the hold the first process would exit and release before the
second selects, and the race would never be exercised.

**Wiring:** `tests/onecluster_ports_race_test.sh` (executable, no docker,
~10 s) is a `check` in `tests/validate.sh` phase 40 beside the classifier and
fingerprint proofs. Pre-existing observation, out of scope: `cleanup()` has
`return 0` before `rm -rf "$WORK"`, so the mktemp service dir leaks per run.

## 2. Deliverable 2 — BLOCKED with measurements: the packet's premise is retired

**The 73 filtered child gates do not exist.** `tests/self_test.sh` was deleted
in `32df467` ("no tree copies: the self-test layer is gone, entirely"); all
120 breakages retired with it (`CUT-ALL-DISPOSITION.md`). There is no
`self_test` phase in `tests/validate.sh`, no `--only` consumer left that
matters for speed, and the "94 breakages, 92 reds / ~85% of self_test" counts
constraint is vacuous — it constrains lines the gate no longer prints. The
corrected PROFILE-gate.md populations (42.70 s unfiltered child, 7.88 s
`--only` child, ~13 min self_test) profile runs of a gate this tree no longer
has. Do NOT re-derive `--only`; do NOT re-open breakages. The target must be
re-derived from the current gate, whose shape is: static (already
`check_par`-parallel in regions) → observability (FOUR serial docker tiers:
`live_check` no_telemetry 900 s bound, `bounded_check` isolation / tenancy /
onecluster 1800 s each) → phase 40 serial checks → lint.

**What was measured instead (this box, just now, serial `time -p`):**

| check (phase 40, no docker) | seconds |
| --- | ---: |
| `classify_test.sh` | 1.52 |
| `fingerprint_test.sh` | 4.08 |
| `multi_tenant_split_test.sh` | 4.30 |
| `provenance_test.sh` | 6.54 |
| `fetch_test.sh` | 9.12 |
| `onecluster_ports_race_test.sh` (new) | 10.07 |
| **serial sum → overlapped (`max`)** | **~35.6 → ~10 (~25 s recoverable)** |

All six are hermetic temp-dir fixtures (`mktemp -d`; fetch builds local bare
repos under `$WORK`) with no shared mutable state — overlap-safe via the
existing `check_par`/`par_flush` region shape. `failfast_test.sh` is also
parallel-safe (project-scoped label sweep, asserts nothing created) but needs
docker. **~25 s is not the gate's problem**; the docker tiers are (triple-digit
seconds each, §7 REPORT-kit-13.md quiet-machine numbers 19–64 s apiece, loaded
box far worse). No full `KIT_PROFILE` table was taken: one full gate is
~13+ min on a quiet box and this box is loaded (baseline below still running
at EOT); two profiled runs plus a change plus two verification runs do not fit
any single hour.

**Why the docker tiers cannot overlap as-is (the blocker):** within one gate
run every tier shares `$$`, and `isolation_test.sh:158` (`15500+($$%400)`,
single-port probe, NO claim) and `tenancy_test.sh:166` (same base, same
claim-less probe, `WORK=.../kit-tenancy.$$`) search the same range that
onecluster's claimed 10-blocks (15000+seed, walking +400 → up to ~15798) cover
— overlap region ~15500..15807. Running the observability tiers concurrently
today reintroduces exactly the Deliverable-1 race into the two tiers Deliverable
1 did not touch, plus unmeasured docker-daemon/image-build contention (cold
ghcr pulls, initdb × N). Extending the mkdir-claim to isolation/tenancy is one
Deliverable-1-sized change per file, and the packet's own bar (full gate green
TWICE after the change, counts unmoved) then needs 2+ full-gate runs. None of
that was started; nothing was dropped and nothing got faster-by-checking-less.

## 3. Successor's first move

1. Collect the baseline: `tail -30 /tmp/gate-kit-w99-gate.log; cat
   /tmp/gate-kit-w99-gate.exit`. NOTE: that run started before `a73d5b1` but
   bash reads the script incrementally, so it WILL include the new phase-40
   race check — it measures the committed tree, which is what you want for the
   "before speedup" number, but do not call it pre-port-fix.
2. `KIT_PROFILE=/tmp/p.tsv bash tests/validate.sh` in background (key files
   per worktree), then the `sort -k3 -rn` top-30 table — that is the real
   re-derivation §2 above could not take.
3. Extend the claim to `isolation_test.sh` + `tenancy_test.sh` (copy the
   `claim_port_block` shape; their single-port search becomes a 1-wide claim),
   THEN overlap the four observability tiers (helpers already exist), then full
   gate twice.
4. Cheap independent win: wrap the six phase-40 checks in one
   `par_begin`…`par_flush` region (~25 s, near-zero risk, same verdicts).

## 4. Counts / hygiene

- `bash -n` clean everywhere touched; `shellcheck -S warning` clean on both
  test files and `tests/validate.sh`.
- No other repo modified. Static already parallel; nothing re-derived without
  numbers; no check dropped, weakened, or widened.
- Baseline verdicts: PENDING (gate still running at EOT, in observability —
  consistent with docker tiers dominating, but that sentence is an observation,
  not the profile table).
