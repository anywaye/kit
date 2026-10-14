# REPORT-roll-c5-rs-residual: converge the ReplicaSets the box no longer names

## The live-box evidence

The gateway namespace on Contabo, with a Deployment at `spec.replicas: 1`:

```
NAME                DESIRED  CURRENT  READY  AGE
gateway-6d5d9495df  1        1        1      2m52s   <-- the digest-pinned RS
gateway-6f9c8bfdd   0        0        0      10h     <-- the bare cafaye/gateway:0.1.0 (Docker Hub) RS
gateway-7cd45d569   0        0        0      6h52m
gateway-858665c58b  1        1        0      93m     <-- a tag-based RS Argo keeps making current
gateway-8977f6fcb   0        0        0      4m23s   <-- a mis-transcribed digest
```

One Deployment at `replicas: 1`, two live ReplicaSets each holding a pod.
`gateway-858665c58b` burns CPU and memory on a readiness probe that can never
succeed, against an image nobody asked for. The Docker Hub generation sat in
`ImagePullBackOff` for seven hours and 46 minutes before it was retired. Each
Deployment generation leaves one RS behind; nothing shrinks the number as the
box ages, because Argo CD converges the Applications (Helm's objects), not the
ReplicaSets a previous Deployment revision left behind.

## The seam

Step 13 of `templates/substrate/install.sh`: `converge_residual_replicasets`,
called from `main` after the courier mint (`CURRENT_PHASE="rs-residual"`),
with per-Deployment work in `converge_one_deployment_rs`. `TOTAL` moves from
12 to 13; the DRY_RUN order check, the two `TOTAL=` static checks, the timing
start/done count, and the two README step counts move with it.

A new step rather than an extension of step 6: the packet demands the step's
own `step.start`/`step.done` timing, and only a `log_step` of its own
produces it. The step carries no `kit_substrate_guard` — no single object's
presence answers "converged" — so it always runs its reads and reports timed,
clearing `STEP_SKIPPED` the way the AppProject reapply does.

Scope is the four service Deployments only (`identity/identity`,
`gateway/gateway`, `courier/courier`, `parlor/parlor`). Argo CD's and the
observability stack's Deployments converge through Argo and are never listed.

## The decision: scale to 0, not delete

The box was fixed by hand this circle by scaling the residual RS to 0, and
the step does the same: `kubectl -n <ns> scale replicaset/<name>
--replicas=0`. Three reasons, in order:

1. The RS object stays, so `kubectl rollout history` keeps working — the
   revision the step just retired remains inspectable.
2. Pods terminate gracefully through the controller. Deleting pods
   explicitly would either race the live RS (respawn) or bypass graceful
   termination; scaling lets the controller do its job.
3. The write is reversible where a delete is not, and idempotent: a second
   run finds no live residual and changes nothing (asserted by the suite).

## The safety rules

- **Current is decided by pod-spec equality, the hash is read off the match.**
  The Deployment object carries no `pod-template-hash` (the controller stamps
  it on the RS, never on the Deployment), so "current" is the owned live RS
  whose `.spec.template.spec` equals the Deployment's. Comparing whole
  templates would never match (the RS carries the hash label the Deployment
  lacks). If no owned live RS matches, the step converges nothing and says
  so — guessing is the defect this step could introduce.
- **A Deployment at `spec.replicas: 0` is operator intent, never a defect.**
  The whole Deployment is skipped with a message. This subsumes the packet's
  "replicas 0 with a live RS" clause: deleting that operator's pods would
  destroy a state someone asked for.
- **A mid-rollout Deployment (`status.updatedReplicas != spec.replicas`)
  belongs to its controller** for the duration; the step reports it and
  moves on. This is the "do not delete what the controller is about to
  scale anyway" rule, enforced rather than promised.
- **A Deployment Argo has not synced yet is skipped quietly** (steps 7–11
  sit between the Applications apply and here); the next re-run meets it.
- **Orphan RSs (no ownerReference to the Deployment) are not judged** —
  without an owner the step cannot attribute them to its Deployment.

## The tests (`tests/substrate_test.sh`, section 26)

Sourced installer + file-backed `kubectl` mock (`rs_mock_kubectl`:
`deploy-<name>.json`, `rs.json`, scale mutates the store and appends to
`scaled`), following the file's `run green/red` idiom with `case`
assertions, never pipes.

- Green: residual reported with image, age and Deployment, scaled to 0,
  current RS untouched.
- Green: second run reports no residual and scales nothing new.
- Green: current-only, scaled-to-zero (named as operator intent),
  mid-rollout, and unsynced Deployments all untouched; nothing scaled.
- Green: dry run prints the residual plus the plan line and changes
  nothing (store byte-identical).
- Green: whole step over all four Deployments — `step.start`/`step.done`
  with numeric seconds on stdout, residual on the human channel,
  `STEP_SKIPPED` cleared, only the residual scaled.
- Red: master shape (step deleted, premise asserts the removal and the
  parse) leaves the residual — the converge check goes red against it.
- Red: inverted hash comparison (`!=` → `==`, premise asserts the
  inversion and the parse) converges the current RS — the
  current-untouched check goes red against it.
- Red: empty store — the converge check needs its fixture.

Two things found while proving the controls:

1. The suite sources the real installer into its **main** shell (the
   registry section does), so the step's functions are inherited by every
   later subshell — sourcing a fixture *without* them does not undefine
   them, and the master control went green on the leak. Every RS check
   now `unset -f`s both functions before sourcing, with the reason in a
   comment.
2. `var=$(...) 2>file` does **not** redirect the substitution's stderr
   into the file (verified: the file stayed empty while stderr leaked).
   The whole-step block redirects a group inside the substitution
   (`{ ...; } 2>file`) instead. The marker uses an explicit `>&2`, the
   file's convention — a bare `printf` writes to stdout, which is how one
   debugging round chased its own tail.

## Controls' verdicts

`bash tests/substrate_test.sh`: 318 passed, 0 failed, 0 skipped — all greens
passing, both red controls proven red (section 26: 6 green + 3 red-control
passes).
