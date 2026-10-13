# REPORT — c3-cnpg-storage: the Cluster named a field CNPG v1.30.1 does not have

Worktree `wt/roll-c3-cnpg-storage`, branch `roll/c3-cnpg-storage`. The packet:
the substrate's Postgres Cluster wrote `spec.storageConfiguration`, an operator
field CNPG renamed before 1.24; the pinned operator is `v1.30.1`, whose CRD is
structural, so the box refused the apply rather than dropping the key — and the
gate was green over the file.

## 1. The field fix

`templates/substrate/manifests/data/postgres-cluster.yaml`:

```diff
-  storageConfiguration:
+  storage:
     size: 20Gi
     storageClass: local-path
```

The fields under it are unchanged; only the parent's name moved.
`storageConfiguration` was CNPG's spelling before 1.24; `storage` is v1.30.1's
(and carries `size`, `storageClass`, `pvcTemplate`, `resizeInUseVolumes` — the
brief's `kubectl explain` list, reproduced offline below). The reason is now a
comment at the code site, quoting the API server's refusal.

## 2. The per-field audit — every CRD-backed field, verified or changed

**Source of truth.** Verified **offline**, against the release manifests the
installer itself applies, fetched at the pinned versions:

- CNPG `v1.30.1` — `raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/v1.30.1/releases/cnpg-1.30.1.yaml`
- Argo CD `v3.5.4` — `raw.githubusercontent.com/argoproj/argo-cd/v3.5.4/manifests/core-install.yaml`
- cert-manager `v1.21.2` — `github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml`

These are the exact URLs `install_cnpg`, `install_argocd` and
`install_cert_manager` apply (checked in `install.sh`), so the source is the
operator the box actually runs, not a newer/older doc. The `kubectl explain`
output on the box reported in the brief agrees; this audit did not need the box.

### `data/postgres-cluster.yaml` → CNPG `clusters.postgresql.cnpg.io` v1 (v1.30.1)

| field path written | verdict | evidence from the pinned CRD |
|---|---|---|
| `spec.storage` | **CHANGED** (was `storageConfiguration`) | The v1 `spec` property set contains `storage`; `storageConfiguration` is **absent**. `spec.storage` declares `pvcTemplate`, `resizeInUseVolumes`, `size`, `storageClass`. |
| `spec.storage.size`, `spec.storage.storageClass` | verified | Both are keys of `spec.storage.properties`. |
| `spec.instances` | verified | `instances` is a key of the v1 `spec` properties. |
| `spec.resources.requests` / `.limits` | verified | `spec.resources` is `{claims, limits, requests}`; `requests`/`limits` are open maps (`additionalProperties`), matching the memory/cpu keys. |
| `spec.postgresql.parameters` | verified | `spec.postgresql` declares `parameters` (a string map) among its properties. |
| `spec.bootstrap.initdb.database` / `.owner` / `.postInitSQL` | verified | `spec.bootstrap.initdb` declares all three (`postInitSQL` is an array of strings). |
| `spec.managed.roles[].name` / `.ensure` / `.login` / `.inRoles` | verified | `spec.managed.roles.items.properties` includes `name`, `ensure`, `login`, `inRoles`. |
| `spec.managed.roles[].passwordSecret.name` | verified | `passwordSecret.properties` declares `name`. |

`storageConfiguration` was the **only** field in this file that the pinned CRD
does not declare. No other CNPG field was recalled from an older release.

### `applications/*.yaml` (8 files) → Argo CD `applications.argoproj.io` v1alpha1 (v3.5.4)

| field path written | verdict | evidence from the pinned CRD |
|---|---|---|
| `spec.project` | verified | v1alpha1 `spec` properties include `project`. |
| `spec.source.repoURL` / `.chart` / `.targetRevision` | verified | `spec.source` declares `repoURL`, `chart`, `targetRevision` (among `helm`, `kustomize`, `path`, …). |
| `spec.destination.server` / `.namespace` | verified | `spec.destination` declares `server` and `namespace`. |
| `spec.syncPolicy.automated.prune` / `.selfHeal` | verified | `syncPolicy.automated` declares `prune`, `selfHeal` (plus `allowEmpty`, `enabled`). |
| `spec.syncPolicy.syncOptions` | verified | `syncPolicy` declares `syncOptions`. |

### `tls/clusterissuer.yaml` (2 documents) → cert-manager `clusterissuers.cert-manager.io` v1 (v1.21.2)

| field path written | verdict | evidence from the pinned CRD |
|---|---|---|
| `spec.acme.server` / `.email` | verified | `spec.acme` declares `server`, `email` among its properties. |
| `spec.acme.privateKeySecretRef.name` | verified | `privateKeySecretRef` declares `name` (and `key`). |
| `spec.acme.solvers[].http01.ingress.ingressClassName` | verified | `solvers[].http01.ingress` declares both `ingressClassName` and the legacy `class` — the file's own comment already says `ingressClassName` is the v1.21.2 field, and the CRD agrees. |

### `data/redis.yaml`, `data/nats.yaml` — no CRD fields

Both are **core Kubernetes** only (`v1/PersistentVolumeClaim`, `apps/v1/Deployment`,
`v1/Service`). They carry **no** CRD-backed field, so they are out of this
audit's scope by design: the source of truth for a core type is `kubectl`'s own
schema, not an operator's CRD, and modelling core API kinds is a different,
larger packet. They are parsed and shape-checked by `check_redis` /
`check_nats_manifest`; the new check counts and skips them explicitly rather
than silently.

## 3. The gate check, and its red control

`tests/substrate_test.sh` §9b — `check_crd_fields`:

- **The model is derived, not typed.** `tests/substrate-crd/schemas.json` is the
  property-name graph of each pinned CRD's `spec`, produced by
  `tests/substrate-crd/regen.py` from the same release URL templates
  `install.sh` applies. The encoding is in the file's own `note`: object →
  `{key: model}`, array → `{"[]": model}`, primitive → `true`, an open-key node
  (`additionalProperties` / preserve-unknown-fields) → `"*"` (or a `"*"` key
  inside a partly-closed object). It is a **name** graph, not a type graph.
- **Why derived and not hand-typed:** the absent check, `check_cluster`,
  asserted `spec.storageConfiguration.size` in so many words. An allow-list
  authored from the manifest contains the manifest's mistakes by construction;
  the CRD's own property set does not.
- **The pin is enforced.** `schemas.json` records the version each graph came
  from, and §9b fails if the pin in `install.sh` disagrees — so bumping
  `CNPG_VERSION` (or Argo's / cert-manager's) without re-deriving the model is a
  red gate, not a manifest graded against a schema nobody re-fetched.
- **It fails closed** on a CRD with no model, and on a modelled CRD no manifest
  currently exercises (a renamed manifest is a silent skip otherwise).

Four `run` assertions, all green on the real tree:

```
PASS substrate_test: every CRD field is declared by the pinned operator CRD
PASS substrate_test: control: spec.storageConfiguration goes red
PASS substrate_test: control: a nested unknown field (storageClassName) goes red
PASS substrate_test: control: a pin bump without re-deriving the model goes red
```

**The red control is the packet's own defect**: the real Cluster manifest with
`storage:` renamed back to `storageConfiguration:` returns:

```
postgresql.cnpg.io/v1/Cluster.spec.storageConfiguration
```

The two further controls exist because a single one can pass for the wrong
reason: the nested `storageClassName` proves the walk descends, and the pin-drift
fixture proves the model is tied to the pin. The control trees mirror the **full**
`manifests/` tree with one line changed, so a "declared CRD not exercised" guard
cannot be the thing that goes red.

## 4. Suite counts

- Baseline before this packet: **167 passed / 0 failed / 0 skipped**; the tree
  was green with the broken field.
- During the packet, with the check added and the manifest **not yet** fixed:
  **170 passed / 1 failed** — the one failure was exactly
  `every CRD field is declared by the pinned operator CRD`, naming
  `Cluster.spec.storageConfiguration`. That is the check proving it can fail.
- Final: **`bash tests/substrate_test.sh` → 171 passed, 0 failed, 0 skipped**
  (4 new assertions: 1 green + 3 controls).
- `bash -n templates/substrate/install.sh` → clean. `shellcheck -S warning` on
  both scripts → clean. `yamllint -c lint/yamllint.yml` on the changed manifest
  and on `tests/substrate-crd/` → clean. (`applications/*.yaml` and `redis.yaml`
  carry pre-existing yamllint findings — missing `---`, one long line — in files
  this packet did not touch; the repo's yamllint runs are fixture-based, not a
  sweep, and those findings pre-date this branch.)
- `tests/validate.sh` §static already runs `tests/substrate_test.sh` (line 4995),
  so the new check is in the full gate without a second wiring. Its one-line
  `check` description was updated to name the new claim. **`validate.sh` itself
  was not run**, per the brief.

## 5. What I deliberately did NOT do

- **Did not run `validate.sh` or touch a cluster.** The narrow gate was the
  brief's instruction; the live box is the manager's.
- **Did not change any operator pin.** The pin is the contract; the manifest
  follows it. (`CNPG_VERSION` stays `v1.30.1`.)
- **Did not grade core Kubernetes fields** (redis/nats) against the CRDs. They
  are not CRD-backed; the new check names and skips them. Modelling core API
  kinds from `kubectl`'s embedded schema is a different packet.
- **Did not vendor the CRD YAMLs** (~4 MB). The committed artifact is the
  distilled name graph; `regen.py` reproduces it.
- **Did not touch `.github/workflows/` or any other repo.**
- **The honest gap:** the model is trusted content. A deliberate edit to
  `schemas.json` could add a wrong name, and the gate cannot prove the model
  matches the CRD without the network. The mitigations are that the file is
  generated, carries its source URL and version, is tied to the installer pin,
  and is regenerated by one committed command — but a diff of `schemas.json` is
  what a reviewer must read, not a proof the gate can run offline.
  Relatedly, the model proves field **names** only: not types, required fields,
  enums, or that a field means what its comment says. Those still need the box.
- **Did not add a script/generator to the gate**: `regen.py` needs the network
  and is not invoked by `validate.sh`; only `schemas.json` is read.
