# roll-c5-timing — every install run now reports its own speed

**Where:** worktree `/Users/kaka/Code/any/moon/wt/roll-c5-timing`, branch
`roll-c5-timing`, repo `cafaye/kit`. Two commits on top of current `master`:

```
ab15fe6 feat(substrate): every install run reports its own step times
507cd9b perf(substrate): apply the three operators first, wait for all three together
```

**Verdict:** all six deliverables done. The narrow gate is green
(`tests/substrate_test.sh`), `bash -n` and `shellcheck -S warning` clean, and the
speed decision is backed by a before/after measurement on `contabo`.

---

## 1. The event schema added

`install.sh`'s JSONL carried no timestamps at all — a step's duration could not
be recovered after the fact. Every event that is about a step now carries
`seconds`, and the final event carries the whole answer.

**Before**

```json
{"event":"step.start","step":1,"phase":"k3s","message":"k3s v1.37.1+k3s1 — single node, sqlite datastore"}
```

**After** (real lines from the `contabo` run)

```json
{"event":"step.start","step":1,"phase":"k3s","message":"k3s v1.37.1+k3s1 — single node, sqlite datastore","seconds":0.580}
{"event":"step.done","step":1,"phase":"k3s","message":"k3s: skipped","seconds":"skipped"}
{"event":"step.done","step":2,"phase":"cert-manager","message":"cert-manager: 4.220s","seconds":4.220}
{"event":"install.done","step":12,"phase":"courier-mint","message":"substrate is up: …","seconds":96.400,"steps":[{"step":1,"phase":"k3s","seconds":4.180},{"step":2,"phase":"cert-manager","seconds":10.020}]}
```

- **`seconds` on `step.start`** is the step's **offset** since the install
  began, so a reader can see a step start serializing.
- **`seconds` on `step.done`** is the step's **duration**, measured from the
  step's **own** boundary. The guard's `kubectl` probe is excluded: the window
  opens after the guard decides the component is absent. A **skipped** step
  reports the string `"skipped"`, never `0` — a skipped step did no work, and
  `0` would read as "this step is free".
- **`seconds` on the final `install.done`** is the run's total, and it carries a
  **`steps[]` table** of `{step, phase, seconds}`. Interactive mode prints the
  same table compactly:

  ```
    step  phase                seconds
    1     k3s                  4.180
    2     cert-manager         10.020
    …
    total                      96.400
  ```

The clock (`kit_substrate_now`) is **monotonic**: `/proc/uptime` on the box, so
an NTP step or an operator's clock edit does not move it; off Linux the
highest-resolution wall clock the machine has is used (bash 5 `EPOCHREALTIME`,
then perl `Time::HiRes`, then `date +%s`, the packet's accepted floor), because
only differences are ever taken. The boundary lives in one place — the next
step's `log_step` closes the previous one, and `main` closes the last — so there
are not twelve end-of-step calls for a later edit to forget.

`templates/substrate/README.md` and the script's own header comment document the
field, the table, and the clock.

## 2. Why the numbers are trustworthy — what a fabricated one would have to do

`tests/substrate_test.sh` §24 parses the real headless run and requires:

- every `step.done` to carry `seconds`, and every `step.start` to carry a
  non-negative `seconds`;
- each `seconds` to be a non-negative number **or exactly `"skipped"`**;
- the `install.done` total to be a non-negative number **at least the sum of the
  numeric step durations it names**, and at least the sum of its own `steps[]`
  table;
- **at least one positive duration** somewhere — twelve zeroes satisfy
  "present and non-negative and not more than the total", so the check refuses a
  run in which nothing was measured;
- `step.start` offsets to be **non-decreasing** — they come off a monotonic
  clock, so a decrease is a clock that was edited or a number that was not
  measured.

So a fabricated constant would have to be present on every step, non-negative,
strictly positive somewhere, and have a total at least as large as its own sum.
The three controls prove the check can fail:

| control | fixture | goes red because |
| --- | --- | --- |
| a step reports no timing | a `step.done` with no `seconds` | §24's named red control |
| a fabricated total | total `0.500` against a step of `5.000` | total < sum of its steps |
| a run of constant zeroes | every duration `0.000` | no step reports a positive duration |
| a skipped step | guard forced to answer "present" | the run says `"skipped"`, not `0` |

**What this does NOT prove, stated plainly:** that a number equals the true
wall-clock duration. No offline test can prove that without a stopwatch. What
the test proves is that the field is *wired* — present, ordered, non-negative,
and internally consistent with the total — and what makes it *trustworthy* is
that it comes off a monotonic clock at the step's own boundary. The real-run
numbers in §3 are the evidence that the clock reads real time.

## 3. The steps' measured times from a real run (`contabo`)

`contabo` (169.58.108.209) was fully installed, so a re-run skips steps 2–4. To
measure them the three Deployments the guards probe were deleted —
`cert-manager/cert-manager`, `cnpg-system/cnpg-controller-manager`,
`argocd/argocd-repo-server` — and the installer re-applied each manifest,
recreating them. **This is the one write beyond re-running the installer**, and
the installer restored the box: after both runs all three Deployments were
`1/1` (`argocd-repo-server` 16s, `cert-manager` 25s,
`cnpg-controller-manager` 22s), the CNPG Cluster reported
`Cluster in healthy state`, and Argo CD still held its 8 Applications. (The
`gateway` `ImagePullBackOff` and `identity` `CrashLoopBackOff` pods were already
there — ages 5h19m and 150m — and predate this run; it stops at step 5.)

Each run stopped at step 5 with the expected `KIT_SUBSTRATE_BOX_ID` refusal, so
steps 1–4 emitted their timings:

| step | phase | before (serial) | after (grouped) |
| --- | --- | --- | --- |
| 1 | k3s | skipped | skipped |
| 2 | cert-manager | **4.220s** | **2.810s** |
| 3 | cnpg | **18.220s** | **2.860s** |
| 4 | argocd | **24.350s** | **20.170s** (holds the grouped waits) |
| | **steps 2–4 total** | **46.79s** | **25.84s** |

**~21s, about 45%, off the three operator steps.** One sample each on the
manager's test box; the shape (not the exact milliseconds) is the claim.

## 4. The parallelization decision, and its evidence

**Decided from the file: it is safe.** cert-manager, CNPG and Argo CD are three
independent installs — separate namespaces (`cert-manager`, `cnpg-system`,
`argocd`), separate CRDs, and applies that reference nothing the others create.
The waits are on separate namespaces/objects, and every waited object is created
**synchronously** by its own `kubectl apply` (an apply is a round trip: the
objects exist when it returns), so applying all three before waiting on any of
them cannot race the empty-list case `kit_substrate_await_list` exists to guard
against. Waiting inside each step instead serialized the rollouts: CNPG's apply
sat behind cert-manager's wait, Argo CD's behind CNPG's.

**Implemented:** steps 2 and 3 apply and register their component in
`PENDING_WAITS`; step 4 applies Argo CD, waits for all three, then applies the
AppProject. A component present at its guard is never registered, so a warm
re-run waits on nothing and step 4 stays a true skip; if step 4's own guard hits
but another step's operator is pending, step 4 is timed rather than reported as
a skip (it did the wait).

`tests/substrate_test.sh` §25 pins the shape: steps 2–3 wait on nothing, step 4
carries all three waits, all three applies still register, and step 4 drains
`PENDING_WAITS`. Two controls go red — a wait put back into step 2 (the serial
shape) and one of the three waits dropped from step 4.

**Not weakened:** the grouped waits are written *inline* in `install_argocd`
rather than in a helper, because `wait_lists_audit` requires every list wait to
have an apply above it *in the same function*; keeping them there leaves that
audit green on its own terms rather than editing the check to accommodate the
change.

## 5. Suite counts

`bash tests/substrate_test.sh` — **258 passed, 0 failed, 0 skipped** (255 before
this packet; §24 and §25 add the timing and grouping checks and their controls).
`bash -n templates/substrate/install.sh` and
`shellcheck -S warning templates/substrate/install.sh` are clean.

## 6. What I deliberately did NOT do

- **Did not merge steps 2–4 into one step.** The literal shape "apply all three,
  then wait all three" as a single phase would renumber all twelve steps, change
  `TOTAL`, and churn every step number in the README, the receipt examples and
  the suite. The waits are grouped inside step 4 instead, which keeps the twelve
  steps and the phase names while getting the overlap.
- **Did not edit `wait_lists_audit` or any other check** to make the change fit.
  See §4.
- **Did not run the full `tests/validate.sh`.** The packet's narrow gate is
  `tests/substrate_test.sh` plus `bash -n` and `shellcheck`; the full six-phase
  gate is the manager's and CI's to run.
- **Did not add a check that the timing equals wall-clock reality.** It is not
  falsifiable in a test; §2 states the limit rather than papering over it.
- **Did not touch `.github/workflows/`, another repo, or another service.**
- **Did not fix the pre-existing `gateway`/`identity` pod failures** on
  `contabo` — they predate this run and are out of this packet's scope.
- **Did not leave the box degraded.** The only destructive action was deleting
  the three operator Deployments to force a cold measurement; the installer
  recreated them, and the box was verified healthy afterwards.
