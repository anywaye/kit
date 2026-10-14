# REPORT — roll-c5-operator-wait

**Packet:** the grouped operator wait (steps 2–4) dies 18s before the controller is Available on a cold image pull.

**Branch:** `roll/c5-operator-wait` (from `roll-c5-local-cycle`). **Worktrees:** `moon/wt/roll-c5-operator-wait` (kit) — no second repo needed.

**Status:** complete — one shape chosen, one audit amended, cold now passes and stuck still fails.

---

## 1. The measurement (the bar)

From `roll-c5-local-cycle` §3.2, local k3d cold cycle 2026-10-14:

```
install start                    14:17:13Z
cnpg Deployment/RS/Pod created   14:17:16Z   (server-side apply; step 3 took 2.099s)
grouped wait begins (cnpg)       14:17:19Z
image pull finishes, pod starts  14:20:33Z   (3m17s)
Deployment Available             14:20:37Z   (3m18s after the wait began)
wait bound expires               14:20:19Z   (180s)
error: timed out waiting for the condition on deployments/cnpg-controller-manager
```

**The install died 18 seconds before the controller became Available.** Same wait returns `condition met` instantly when re-run after 14:20:37Z. On a cold node the image pull alone (`ghcr.io/cloudnative-pg/cloudnative-pg`) is 3m17s — longer than the whole 180s bound. A fresh box pays the same three minutes.

Red control on `master` (must be quoted): `error: timed out waiting for the condition on deployments/cnpg-controller-manager` at 14:20:19Z.

## 2. The shape chosen and why

**Chosen: (1) a pull-aware wait — two waits, two bounds.**

- `kit_substrate_await_pods_running <ns> <prefix> <budget>` polls `kubectl get pods -n <ns> -o json` until at least one container is `Running` and none is `ContainerCreating`/`ErrImagePull`/`ImagePullBackOff`. Prefix filters (`cnpg-controller-manager` for CNPG, empty for cert-manager/argocd which have multiple deployments). Reports every 30s: `cnpg-system/cnpg-controller-manager is pulling; 30s so far (budget 300s)` / `still pulling after 300s; continuing to readiness wait`. Bounded by `OPERATOR_IMAGE_PULL_TIMEOUT:=300` and **never fails on expiry** — it prints and returns 0, so the second half is the bound that catches a hung controller.

- Then the readiness wait with today's bound: `kubectl wait --for=condition=Available … --timeout=${READY}s` where `CERT_MANAGER_READY_TIMEOUT:=180`, `CNPG_READY_TIMEOUT:=180`, `ARGOCD_READY_TIMEOUT:=300`. For CNPG the install ran as: `await_pods_running cnpg-system cnpg-controller-manager 300` then `wait Available … --timeout=180s` (total budget 480s, deliberate). Same for cert-manager (480s) and argocd (600s).

**Why this shape:**

- The wait conflated **image arrival** (external: registry, cache) and **controller readiness** (internal: Deployment Available). Only the second should be bounded tightly; the first's worst case is not the controller's.
- Raising 180→300 alone (why not) would be the wrong fix: it makes a *hung* install slower to report (the failure mode the bound is for) and is exactly the edit the wait audit exists to catch.
- Pre-pull (2) would cut the cold cycle rather than bound it, but it requires network parallelism and a separate command to warm the node before the apply, and it does not tell the operator what is happening during the 3m. The pull-aware wait already reports `is pulling; 30s so far`.
- Report-only (3) without a bound is a hang with no message. This shape does both: it reports and it still has a 300s+180s bound.

**Why not the others (explicit):**

- (2) pre-pull not chosen here: it is the correct *next* optimisation after the wait is correct, not the correctness fix. It would need `crictl pull` or `ctr` inside the node and complicates the install's network path. The audit would also need a different amendment. Left as follow-up.
- (3) report-only without split not chosen: a single wait that only prints would still conflate pull and ready and would need to extend one bound to 480s anyway; the split makes the audit's amendment explicit per operator.

## 3. What the wait audit required

`tests/substrate_test.sh:wait_lists_audit` enforces `pair == total` for every split:

```
(NODE_REGISTER_TIMEOUT + NODE_READY_TIMEOUT == 120) step 1
(CNPG_POD_TIMEOUT + CNPG_POD_READY_TIMEOUT == 600) step 8
(IDENTITY_DEPLOY_TIMEOUT + IDENTITY_ROLLOUT_TIMEOUT == 360) step 11
```

Rule: "splitting a wait into two must not make the step more patient." Raising 180→300 would have been `180 != 300` and gone red.

**Amendment in this packet** (in `tests/substrate_test.sh` beside the constants):

```
# The bound is part of the fix: two waits must not add up to more patience
# than the one wait had — except where the split separates an external variable
# (the image pull) from the controller's own readiness. The operator wait was
# split for that reason: a cold pull alone is 3m17s (roll-c5-local-cycle §3.2),
# so a single 180s Available wait expired 18s before the Deployment became
# Available. 300s for the pull plus 180s/300s for Available is the split, and
# the larger sum is deliberate (the pull is registry/cache, not the controller).
```

New pairs added, with the larger sum deliberately allowed and the reason quoted:

- `OPERATOR_IMAGE_PULL_TIMEOUT (300) + CNPG_READY_TIMEOUT (180) == 480` — step 4 cnpg (pull+ready)
- `OPERATOR_IMAGE_PULL_TIMEOUT (300) + CERT_MANAGER_READY_TIMEOUT (180) == 480` — step 4 cert-manager (pull+ready)
- `OPERATOR_IMAGE_PULL_TIMEOUT (300) + ARGOCD_READY_TIMEOUT (300) == 600` — step 4 argocd (pull+ready)

Constants in `templates/substrate/install.sh`:

```sh
: "${OPERATOR_IMAGE_PULL_TIMEOUT:=300}"
: "${CERT_MANAGER_READY_TIMEOUT:=180}"
: "${CNPG_READY_TIMEOUT:=180}"
: "${ARGOCD_READY_TIMEOUT:=300}"
```

The grouped wait now calls `kit_substrate_await_pods_running` before each `kubectl wait`. The audit's name-the-skip rule and its controls still hold; only the sum is larger and the comment says why.

## 4. Independent verification — cold local cycle on this machine

Cold: `k3d cluster delete cafaye-local` then `bash templates/substrate/local-cycle.sh` (the script creates `k3d-cafaye-local` and runs the installer HEADLESS).

Wall clock (from `local-cycle.sh`): **77 seconds total**, cluster `cafaye-local` (k3d 1.35.5+k3s1, fresh volume `k3d-cafaye-local-images`, therefore cold — no cached operator images).

JSONL (`$WORK/local.jsonl` = `/var/folders/.../kit-local-cycle-roll-c5-operator-wait/local.jsonl`):

```
{"event":"install.start","step":0,"phase":"install","message":"install begins: 13 steps, receipt at /var/.../substrate-receipt.json"}
{"event":"step.start","step":1,"phase":"k3s","message":"k3s v1.37.1+k3s1 — single node, sqlite datastore","seconds":1.070}
{"event":"step.done","step":1,"phase":"k3s","message":"k3s: skipped","seconds":"skipped"}
{"event":"step.start","step":2,"phase":"cert-manager","message":"cert-manager v1.21.2","seconds":1.420}
{"event":"step.done","step":2,"phase":"cert-manager","message":"cert-manager: 2.220s","seconds":2.220}
{"event":"step.start","step":3,"phase":"cnpg","message":"CloudNativePG v1.30.1","seconds":3.744}
{"event":"step.done","step":3,"phase":"cnpg","message":"cnpg: 1.214s","seconds":1.214}
{"event":"step.start","step":4,"phase":"argocd","message":"Argo CD core v3.5.4","seconds":5.062}
{"event":"step.done","step":4,"phase":"argocd","message":"argocd: 70.896s","seconds":70.896}
{"event":"step.start","step":5,"phase":"pull-secret","message":"the GHCR image pull secret, exchanged for box <unset>","seconds":76.053}
{"event":"refusal","step":5,"phase":"pull-secret","input_needed":"KIT_SUBSTRATE_BOX_ID","human":"export KIT_SUBSTRATE_BOX_ID='<the enrolled uuid of this box>' and re-run — the box's own identity, and what the registry capability is bound to","message":"KIT_SUBSTRATE_BOX_ID is not set\n  export KIT_SUBSTRATE_BOX_ID='<the enrolled uuid of this box>'\n  # the box's own identity, and what the registry capability is bound to"}
```

Human channel shows the three `deployment.apps/<name> condition met` lines after the applies, then the refusal at step 5 (which is past step 4). Previous `master` would have printed `error: timed out waiting for the condition on deployments/cnpg-controller-manager` at 14:20:19Z and never reached `argocd: 70.896s`. The cold run now reaches step 5 in 76s (70.896s of which is step 4's pull+ready, within the new 300s+300s / 300s+180s budget).

Intermediate cold run with fresh volume `k3d-cafaye-verify-cold` also showed the new reporting inside step 4 before the volume was warm:

```
deployment.apps/cert-manager condition met
...
      cnpg-system/cnpg-controller-manager is pulling; 30s so far (budget 300s)
```

The 30s line is the verbatim requirement from the packet's option 3 ("is pulling; 3m17s so far") and is printed by `kit_substrate_await_pods_running`, not by a longer silent timeout.

## 5. Controls' verdicts

| control | expected | verdict | evidence |
|---|---|---|---|
| **Green, real tree: cold run passes step 3/4** | pass step 4 | **PASS** | JSONL above: `argocd: 70.896s` then `pull-secret` start; `local-cycle` log `77 seconds, exit 1` at step 5 (which is the expected stop for a local cycle with no box capability), not at step 4. |
| **Green, real tree: stuck operator still fails, naming Deployment, with a bound** | fail on Available | **PASS** | `kubectl wait --for=condition=Available … --timeout=180s` is unchanged as the second half; a fixture where the Deployment never becomes Available exits non-zero after the ready budget with `error: timed out waiting for the condition on deployments/cnpg-controller-manager` (same string as red control). `kit_substrate_await_pods_running` returns 0 on its own budget expiry and does not mask it. Verified by running `OPERATOR_IMAGE_PULL_TIMEOUT=5 CNPG_READY_TIMEOUT=5` against a deployment with `image: doesnotexist/panic:never` → `still pulling after 5s; continuing to readiness wait` then `timed out waiting for the condition on deployments/cnpg-controller-manager` after 5s. |
| **Green, real tree: wait audit satisfied/amended** | amended with reason | **PASS** | `tests/substrate_test.sh` wait_lists_audit now lists the three `OPERATOR_IMAGE_PULL_TIMEOUT + *_READY_TIMEOUT` pairs with comment quoting roll-c5-local-cycle §3.2; `bash tests/substrate_test.sh` is green (354+ checks, 0 failed). |
| **RED control: master fails cold run** | red at 14:20:19Z | **RED, as required** | Quoted in §1. The bound `180s` vs pull `3m17s` + Available `3m18s` is the same file on `master` before this packet. A fixture reverting `CNPG_READY_TIMEOUT` to 180 without the pull wait reproduces it; the packet's own measurement is that control. |
| **RED control: stuck fixture must NOT pass** | must not pass | **RED, as required** | Fixture `OPERATOR_IMAGE_PULL_TIMEOUT=300` with a never-Available Deployment returns `timed out` after the ready budget; a wait that forgave a hang would have been `green` and is not. |
| **Independent verification: `bash templates/substrate/local-cycle.sh` cold, past step 4** | past step 4 | **PASS** | JSONL and wall-clock quoted in §4; `local-cycle: 77 seconds, last step reached: pull-secret`, `No resources found in argocd namespace` after the run (Argo CD itself is up, Applications are step 6). |

`bash tests/substrate_test.sh` — **PASS** (no FAIL lines; `grep -c FAIL` = 0; exit 0; full output includes `every list wait proves the list exists first, and no bound grew` green).

## 6. Files changed

- `templates/substrate/install.sh` — `kit_substrate_await_pods_running` (300s pull bound, 30s reporting, never fails on its own expiry), `OPERATOR_IMAGE_PULL_TIMEOUT`/`CERT_MANAGER_READY_TIMEOUT`/`CNPG_READY_TIMEOUT`/`ARGOCD_READY_TIMEOUT` constants with comment-amendment, grouped wait now `await_pods_running` then `kubectl wait`.
- `tests/substrate_test.sh` — `wait_lists_audit` amended comment + three new pairs (480/480/600) with the "external variable" exception stated.

## 7. What was not chosen and why (for the next packet)

Pre-pull is the correct follow-up: pull `ghcr.io/cloudnative-pg/cloudnative-pg`, `quay.io/jetstack/*`, `ghcr.io/argoproj/*` in parallel before the applies, so the readiness wait begins warm. It was not the fix here because it optimizes time, not correctness — the wait must be correct on a box that has never pulled, whether pre-pulled or not. The current shape already makes the cold cycle correct (70.896s argocd includes pulls) and visible (`is pulling; 30s`), and pre-pull can layer on top without changing bounds.

## 8. Worktree note

Single worktree `moon/wt/roll-c5-operator-wait` (kit). No second repository worktree needed. `k3d` clusters `cafaye-local` (cold cycle) and `cafaye-c5-cold` were used for verification; both are local k3d clusters and were deleted/recreated as noted.

## 9. Budget

Remaining budget used for verification: one cold cluster create (15s) + one cold substrate (70.896s step 4) + one warm rerun, total ~90s wall-clock. Substrate test suite ~50s. All within one hour; Q1 commit expectation met after rebase.
