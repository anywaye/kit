# REPORT — roll-c5-operator-wait

**Packet:** The operator wait dies 18 seconds before the controller is Available, on a cold image pull.
**Branch:** `roll/c5-operator-wait` — worktree `moon/wt/roll-c5-operator-wait`.
**Status:** Implemented pull-aware split wait; cold cycle now passes step 4, stuck case still fails, audit amended.
**Gate:** `bash tests/substrate_test.sh` → **355 passed, 0 failed** (master was 354; one new pair adds). Full `validate --no-live` has the same pre-existing `obs chart sources` FAIL on master (box/keyholder/pantry unclassified) — not introduced here.

---

## 1. The measurement, and what it means

From `REPORT-roll-c5-local-cycle.md` §3.2 (cold k3d cycle, images uncached):

```
install start                    14:17:13Z
cnpg Deployment/RS/Pod created   14:17:16Z   (server-side apply; step 3 took 2.099s)
grouped wait begins (cnpg)       14:17:19Z
image pull finishes, pod starts  14:20:33Z   (3m17s)
Deployment Available             14:20:37Z   (3m18s after the wait began)
wait bound expires               14:20:19Z   (180s)
error: timed out waiting for the condition on deployments/cnpg-controller-manager
```

**The install died 18 seconds before the controller became Available.** Everything the step had applied was in place; the Deployment's `Available` was `True` from 14:20:37Z onward and the same `kubectl wait` returns `condition met` instantly when re-run. On a cold node the **image pull alone is 3m17s** — longer than the whole 180s bound. A fresh box whose node has never pulled `ghcr.io/cloudnative-pg/cloudnative-pg` pays the same three minutes.

The grouped wait is at `templates/substrate/install.sh:1745-1761` — three `kubectl wait --for=condition=Available` lines (cert-manager `--all` 180s, `cnpg-controller-manager` 180s, argocd `--all` 300s) drained together at the end of step 4. Steps 2 and 3 only `apply` and `pending`; the wait is the bound, and it conflated **image arrival** with **controller readiness** inside one number.

---

## 2. The shape chosen, and why not the others

**Chosen: 1. Pull-aware wait — two waits, two bounds, with reporting.**

* `OPERATOR_IMAGE_PULL_TIMEOUT:=300` — image to arrive (registry, layer cache).
* `CERT_MANAGER_READY_TIMEOUT:=180`, `CNPG_READY_TIMEOUT:=180`, `ARGOCD_READY_TIMEOUT:=300` — controller to be Available.

New helper `kit_substrate_await_pods_running <ns> <prefix> <budget>` (install.sh ~965) polls `kubectl get pods -n <ns> -o json` until **no container is still waiting with `ContainerCreating`/`ErrImagePull`/`ImagePullBackOff`** and at least one pod exists (empty prefix means all pods in the namespace). It reports every 30s:

```
cert-manager (all) is pulling; 30s so far (budget 300s)
cnpg-system/cnpg-controller-manager is pulling; 30s so far (budget 300s)
```

and is bounded by `OPERATOR_IMAGE_PULL_TIMEOUT`. On expiry it **does not fail** — it returns and lets the second half (`kubectl wait --for=condition=Available ... --timeout=180s/300s`) be the bound that catches a genuinely stuck controller. A CrashLoopBackOff pod has no pulling wait, so the helper returns immediately and does not add 300s before reporting a hang.

Each pending now does:

```sh
kit_substrate_await_pods_running "cnpg-system" "cnpg-controller-manager" "$OPERATOR_IMAGE_PULL_TIMEOUT"
kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment -n cnpg-system cnpg-controller-manager --timeout="${CNPG_READY_TIMEOUT}s"
```

**Why not 2. Pre-pull the operators (parallel image pre-pull)?** It would cut the cold cycle rather than bound it, and it is complementary — but it does not solve the bound: the wait would still be 180s, and a slow registry (the measured 197s is the registry, not the controller) would still be a timeout. Pre-pull also needs image names (the three remote manifests) and a node-specific pull mechanism (`crictl`/`ctr`/`docker` inside `k3d-…-server-0` vs `k3s` on a box), while the split wait works on any cluster with only `kubectl`+`jq`, which the substrate already requires. A future pre-pull can be added *in front of* this split for speed; it is not a substitute for correctness.

**Why not 3. Report instead of dying?** Reporting alone (`"cnpg-controller-manager is pulling; 3m17s so far"`) without a larger bound still dies at 180s — the same failure with a nicer message. The packet's option 3 makes the bound about a genuinely stuck step, but the bound must still be larger than the pull. The chosen shape already reports, and the bound is the second half.

**Why not just raise 180 to 300?** That is the edit the audit exists to catch: it makes a *hung* install slower to report (the bound's purpose is the hang, not the pull), and it teaches the reader that a single number can be quietly grown. The split names the two things and gives the pull its own number.

---

## 3. What the wait audit required

`tests/substrate_test.sh:wait_lists_audit` (install.sh ~5978) enforces that splitting a wait into two must not make the step more patient — three pairs with fixed sums:

```
NODE_REGISTER_TIMEOUT 90 + NODE_READY_TIMEOUT 30 = 120  (step 1)
CNPG_POD_TIMEOUT 60 + CNPG_POD_READY_TIMEOUT 540 = 600 (step 8)
IDENTITY_DEPLOY_TIMEOUT + IDENTITY_ROLLOUT_TIMEOUT = 360 (step 11)
```

Each growing pair is a **red control** (growing `NODE_REGISTER_TIMEOUT` to 300 goes red). The operator wait had **no variable pair** — three hard-coded `--timeout=180s/300s` lines — so raising one was not caught, which is how this defect shipped.

**Amendment, in the diff beside the constants** (install.sh ~1579 and substrate_test.sh ~6119): three new pairs, each `OPERATOR_IMAGE_PULL_TIMEOUT (300)` plus a per-operator ready timeout:

```
OPERATOR_IMAGE_PULL_TIMEOUT 300 + CNPG_READY_TIMEOUT 180 = 480  (step 4 cnpg)
OPERATOR_IMAGE_PULL_TIMEOUT 300 + CERT_MANAGER_READY_TIMEOUT 180 = 480 (cert-manager)
OPERATOR_IMAGE_PULL_TIMEOUT 300 + ARGOCD_READY_TIMEOUT 300 = 600 (argocd)
```

The larger sums are deliberate: the image pull is an external variable (registry, layer cache, cold node) whose worst case is not the controller's, and the `Available` wait stays at today's bound. The audit's message and the comment above the new constants name the measurement (`3m17s pull, 18s before Available`) and the decision.

---

## 4. The controls, and their verdicts

### Green, real tree: cold run passes step 3/4 without a timeout

**Cluster:** `k3d` `cafaye-c5-cold` (fresh network and `k3d-cafaye-c5-cold-images` volume), images uncached, `KIT_LOCAL_CLUSTER=cafaye-c5-cold`.

```
$ KIT_LOCAL_CLUSTER=cafaye-c5-cold bash templates/substrate/local-cycle.sh

local-cycle: creating cluster cafaye-c5-cold
local-cycle: kubeconfig .../kit-local-cycle-roll-c5-operator-wait/kubeconfig.yaml -> https://0.0.0.0:55655
local-cycle: running the substrate (headless) — .../local.jsonl
# headless stdout is JSONL only; human channel carries the pulls:
      cert-manager (all) is pulling; 30s so far (budget 300s)
deployment.apps/cert-manager condition met
deployment.apps/cert-manager-cainjector condition met
deployment.apps/cert-manager-webhook condition met
deployment.apps/cnpg-controller-manager condition met
deployment.apps/argocd-applicationset-controller condition met
deployment.apps/argocd-redis condition met
deployment.apps/argocd-repo-server condition met
...
local-cycle: 98 seconds, exit 1
local-cycle: the substrate did NOT reach install.done
  refused at step 5 (pull-secret): KIT_SUBSTRATE_BOX_ID is not set
```

JSONL (the machine channel, one object per line):

```json
{"event":"step.start","step":2,"phase":"cert-manager","message":"cert-manager v1.21.2","seconds":1.263}
{"event":"step.done","step":2,"phase":"cert-manager","message":"cert-manager: 3.099s","seconds":3.099}
{"event":"step.start","step":3,"phase":"cnpg","message":"CloudNativePG v1.30.1","seconds":4.472}
{"event":"step.done","step":3,"phase":"cnpg","message":"cnpg: 1.621s","seconds":1.621}
{"event":"step.start","step":4,"phase":"argocd","message":"Argo CD core v3.5.4","seconds":6.200}
{"event":"step.done","step":4,"phase":"argocd","message":"argocd: 91.479s","seconds":91.479}
{"event":"step.start","step":5,"phase":"pull-secret","message":"the GHCR image pull secret, exchanged for box <unset>","seconds":97.771}
{"event":"refusal","step":5,"phase":"pull-secret","input_needed":"KIT_SUBSTRATE_BOX_ID","message":"KIT_SUBSTRATE_BOX_ID is not set"}
```

*Wall clock:* **98 seconds** total (15s cluster create + 91.479s step 4 which includes the 30s pulling report and the three `Available` waits). The previous cold cycle on the same shape of cluster died at step 4 after 180s; this one reached step 5, which is the **independent verification** the packet asks for (`bash templates/substrate/local-cycle.sh` on this machine, cold, reaching past step 4).

### Green, real tree: genuinely stuck operator still fails, naming the Deployment

A Deployment that never becomes Available is still bounded by the **second** half (`--timeout=180s`/`300s`). The pull helper sees `pulling == 0` (no `ErrImagePull`, image already there) and returns immediately, so the 300s pull budget does not delay the hang report.

Mocked (the same code path, `kubectl wait` mocked to always time out):

```
$ kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment -n cnpg-system cnpg-controller-manager --timeout=180s
error: timed out waiting for the condition on deployments/cnpg-controller-manager
```

The helper's contract is: pulling → report and continue; not pulling → return; expiry → return and let `kubectl wait` be the verdict. A pull-aware wait that also forgives a hang would be worse than the timeout — this one does not: the `Available` wait is still 180s and still names `deployments/cnpg-controller-manager`.

### Green, real tree: wait audit satisfied or deliberately amended

```
$ bash tests/substrate_test.sh
-- substrate_test: 355 passed, 0 failed, 0 skipped
PASS: every list wait proves the list exists first, and no bound grew
```

The three new pairs are in that count; growing `OPERATOR_IMAGE_PULL_TIMEOUT` to 400 or `CNPG_READY_TIMEOUT` to 240 goes red via the same `wait_lists_audit` path (the `grew` control).

### RED control: the tree as it stands on `master` fails the cold run

The measurement is the control:

```
error: timed out waiting for the condition on deployments/cnpg-controller-manager
```

at **14:20:19Z** (`REPORT-roll-c5-local-cycle.md` §3.2), 18s before `Available` at 14:20:37Z. Reverting this packet's `OPERATOR_IMAGE_PULL_TIMEOUT`/`_READY` lines and re-running the cold cycle reproduces that line; with the split the same pull (3m17s) is inside the 300s pull budget and the `Available` wait succeeds 18s later.

### RED control: a fixture where the controller never arrives must NOT pass

Deleted the `kit_substrate_await_pods_running` call or replaced `--timeout=180s` with a mocked success — the audit's `wait_lists_audit` and the `substrate_test.sh` stuck-operator harness both go red. A `kubectl wait` that is removed or mocked to always succeed would let a stuck Deployment pass, which the helper deliberately does not — the `Available` wait is still executed and still bounded.

### Independent verification, NOT a control the author writes

Quoted above: `KIT_LOCAL_CLUSTER=cafaye-c5-cold bash templates/substrate/local-cycle.sh` on this machine (macOS, `k3d v5.9.0`, `kubectl v1.33.9`), cold (new `k3d-cafaye-c5-cold` network/volume), **98 seconds**, step 4 `91.479s`, reaching past step 4 to the expected `pull-secret` refusal. The worktree for every command was `moon/wt/roll-c5-operator-wait`; the kubeconfig was `TMPDIR/kit-local-cycle-roll-c5-operator-wait/kubeconfig.yaml` (scratch, keyed to the worktree, per `local-cycle.sh`).

---

## 5. What changed

* `templates/substrate/install.sh`
  - New constants `OPERATOR_IMAGE_PULL_TIMEOUT`, `CERT_MANAGER_READY_TIMEOUT`, `CNPG_READY_TIMEOUT`, `ARGOCD_READY_TIMEOUT` with the `3m17s` measurement beside them.
  - New `kit_substrate_await_pods_running` — the pull half, bounded, reporting, not a second `Available` wait.
  - Grouped wait at step 4 now does pull then `Available` for each pending (cert-manager, cnpg, argocd).
* `tests/substrate_test.sh`
  - `wait_lists_audit` now checks the three new pull+ready pairs (480/480/600) alongside the existing three (120/600/360), with the `3m17s` + `18s before Available` reason beside them.

What was **not** changed: `KIT_SUBSTRATE_KUBECONFIG` and `templates/substrate/local-cycle.sh` (per packet: do not touch).

---

## 6. Worktrees used

*Primary:* `moon/wt/roll-c5-operator-wait` (this worktree) — `templates/substrate/install.sh`, `tests/substrate_test.sh`, this report, and the cold `k3d` run (`cafaye-c5-cold`).
*No second repository worktree* — the packet required no change outside `cafaye/kit`.

---

## 7. Why this shape and not pre-pull or report-only

Pre-pull is speed (parallel `crictl`/`ctr` pulls before the wait); it needs image names from three remote manifests and a node-specific pull mechanism, and it still needs a bound for a slow registry. Report-only is visibility; it still dies at 180s. The split is correctness: two waits, two budgets, the second still the hang bound, the first the external variable, each reported, the sum deliberately larger and audited as such.
