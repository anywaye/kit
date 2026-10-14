# REPORT-roll-c5-cnpg-ready: the Postgres readiness wait reads the Cluster

Worktree: `moon/wt/roll-c5-cnpg-ready` (branch `roll/c5-cnpg-ready`; the only
worktree used — no second repository was touched).
Commits: `0273e49` (the fix), `3de6361` (the proof).

## The defect, with the live evidence

Step 8 of `templates/substrate/install.sh` waited on the CNPG instance pods
with a label selector:

```
kit_substrate_await_list 60 pod -l cnpg.io/cluster=postgres -n data
kubectl wait --for=condition=Ready pod -l cnpg.io/cluster=postgres -n data --timeout=540s
```

That selector also matches CloudNativePG's bootstrap Job pod. First cycle on
a fresh box (2026-10-14) logged:

```
pod/postgres-1-initdb-s5lq8 condition met          ← THE INITDB JOB POD
      migrating identity as its OWNER role, in ghcr.io/cafaye/identity:0.1.0
      migrating courier as its OWNER role, in ghcr.io/cafaye/courier:0.1.0
error: the migration for identity did not succeed (last pod phase: 'Failed')
  dsn:   postgres://OWNER:<redacted>@postgres-rw.data.svc.cluster.local:5432/identity?sslmode=disable
  logs:  identity migrate: connecting to the database: failed to connect to
         `user=identity database=identity`: 10.43.66.142:5432
         (postgres-rw.data.svc.cluster.local): dial error: dial tcp 10.43.66.142:5432:
         connect: connection refused
```

A pod wait is satisfied by the pods that exist at that moment — the initdb
Job pod alone, before the instance pod is created. **courier's migration
succeeded and identity's failed**, the two Jobs having launched together
(`roll-c5-migrations-parallel`): the first to reach Postgres lost the race,
and by the second the primary was up. That ordering is the proof the cluster
was healthy and the signal was wrong, not that Postgres was broken.

## The fix

Wait on the object that means what the step needs: the CNPG Cluster's own
readiness (`templates/substrate/install.sh`, step 8, `install_postgres_cluster`).

- **The wait is now**
  `kubectl wait --for=condition=Ready cluster.postgresql.cnpg.io/postgres -n data --timeout="${CNPG_CLUSTER_READY_TIMEOUT}s"`.
  No pod is listed at all — excluding the initdb pod by name would be a
  second thing to drift, and the Cluster object is the authority. No
  existence probe precedes it: the Cluster is applied synchronously two
  lines above (a `kubectl apply` is a round trip), unlike step 1's Node or
  the operator Deployments.
- **What the pinned CNPG version reports** (read from v1.30.1's own sources,
  fetched during the run — `api/v1/cluster_types.go`, `internal/controller/`
  status wiring — not assumed):
  - `ConditionClusterReady ClusterConditionType = "Ready"` — a `Ready`
    condition on the Cluster, managed by the operator from the instances'
    reported state, which no initdb Job can satisfy.
  - `PhaseHealthy = "Cluster in healthy state"` — the settled phase.
  - The wait reads the CONDITION, not the phase string: `Ready` is the
    generic Kubernetes readiness convention (the same predicate every Pod
    and Deployment wait in the file already uses); the phase vocabulary is
    CNPG's own and stays informational, in the refusal.
- **The bound and the audit.** One bound, `CNPG_CLUSTER_READY_TIMEOUT:=600`
  — the same 600s total the pod wait always had, not a second longer. The
  `wait_lists_audit` population follows the code: `awaited` 2→1 (the node;
    the CNPG pod list wait was the defect and the Cluster wait is NAMED),
    the step-8 pair becomes one 600s single, and the drop-pod-await control
    becomes a grow-the-Cluster-bound control. Step 10's pre-wait reuses the
    same bound rather than adding its own.
- **Step 10 (`install_migrations`) pre-waits on the same condition** before
  launching a single migrate pod: a re-run skips step 8 at its guard (the
  object exists) and "exists" is not "Ready". No retry loop around the
  migrations — the wait is the fix, and a retry would only make a genuinely
  broken cluster slower to report.
- **The honest refusal survives and names more.** The migration failure still
  names the service, the redacted OWNER DSN, the image, and leaves the pod
  for diagnosis — plus a new line,
  `error:   cluster: postgres in namespace data (phase: '…')`,
  read by the new `cnpg_cluster_phase` helper (failure messages only, never
  a wait predicate). A `connection refused` that is really "the primary is
  not up yet" now reads as one. Both step 8 and step 10 refusals go through
  `kit_substrate_refuse` (stderr + JSONL refusal + receipt), naming the
  Cluster and its phase.

## Controls and verdicts

Executed in `tests/substrate_test.sh` §17b plus the step-10 half of §13g,
against the file-backed mock (extended: a `wait` verb where the
`<ns>/cluster-<name>-ready` file is the Ready condition; `-o
jsonpath={.status.phase}` answered from the phase file; `apply` of a
`kind: Cluster` manifest plants the existence marker, because a real apply
is a round trip — without it the step's own phase query 404s on an object
it just created and the refusal names 'unknown' for a cluster that is
really 'Setting up primary'):

- GREEN: step 8 on a cold cluster succeeds once the Cluster reports Ready —
  the argv holds `wait --for=condition=Ready
  cluster.postgresql.cnpg.io/postgres -n data --timeout=600s` and no
  `cnpg.io/cluster` pod query at all. A pod list holding only the initdb
  pod cannot satisfy a wait that never lists pods.
- GREEN: step 10 pre-waits under the 600s bound, then migrates both
  services as their OWNER roles.
- GREEN: a stuck Cluster fails step 8 with the bound, naming the Cluster
  and `Setting up primary`.
- RED: the master pod-selector wait restored goes red under the static
  check.
- RED: the Cluster wait deleted goes red (a wait that forgives a stuck
  cluster is worse than the race).
- RED: a half-ready Cluster refuses step 10, naming `Setting up primary`,
  launching zero migrate pods.
- RED: growing `CNPG_CLUSTER_READY_TIMEOUT` to 900 goes red, naming the bound.

Full `tests/substrate_test.sh`: **390 passed, 0 failed, 0 skipped.**

## What is NOT proven here (successor's first move)

- **The live cycle.** There is no test box from this machine (macOS dev
  workstation, no k3s, no cluster). The packet's independent verification —
  a full cycle reaching past step 10 with the JSONL quoted — still needs a
  fresh box: run the installer headless there and confirm step 8 waits past
  the initdb pod (`kubectl get events`/JSONL offsets will show the wait
  spanning bootstrap) and step 10's first migration connects first try.
- **The pinned-source reads** (`/tmp/cnpg-*.go` on this machine) are not in
  the tree and are not pinned by the gate; if CNPG is ever bumped past
  v1.30.1, re-read `ConditionClusterReady`/`PhaseHealthy` at the new tag —
  the §9b CRD-derived check grades the manifest, not the installer's
  condition name.

## Files changed

- `templates/substrate/install.sh` — Cluster wait (step 8), pre-wait + phase
  line (step 10), `cnpg_cluster_phase` helper, one 600s bound.
- `tests/substrate_test.sh` — §17b, mock `wait`/phase/apply-marker support,
  `migrate_seed_fixture` plants a Ready cluster, audit populations updated.
- `CHANGELOG.md` — Unreleased/Substrate entry quoting the live evidence.
