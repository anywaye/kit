# REPORT-roll-c5-obs-cluster-scope: the substrate's own observability Applications cannot sync against its own AppProject

## The evidence, from the cold box

```
$ kubectl -n argocd get applications
NAME         SYNC STATUS   HEALTH STATUS
alloy        OutOfSync     Missing
courier      Synced        Healthy
gateway      Synced        Healthy
grafana      OutOfSync     Missing
identity     Synced        Healthy
loki         Unknown       Healthy
parlor       Synced        Healthy
prometheus   OutOfSync     Missing
```

```
$ kubectl -n observability get pods
No resources found in observability namespace.
```

Argo's own reason for `alloy`:

```
SyncError=Failed last sync attempt to [1.13.0]: one or more synchronization tasks are not
valid: resource apiextensions.k8s.io:CustomResourceDefinition is not permitted in project
default; resource rbac.authorization.k8s.io:ClusterRole is not permitted in project default;
resource rbac.authorization.k8s.io:ClusterRoleBinding is not permitted in project default
(retried 5 times).
```

The AppProject listed no `clusterResourceWhitelist`, so the default applied
(no cluster-scoped resources) — and its own comment documented the opposite
of what the tree ships:

```
#                      cluster-scoped; the observability charts do the same
#                      inside observability.
```

That sentence is false. The four service Applications converge because they
really are namespaced-only; the three observability ones never could.

## What each chart really creates (measured, not guessed)

Rendered locally with the pinned versions, defaults (the Applications carry
no `helm.values`), `--include-crds` and `--kube-version 1.37.1` — the flags
Argo itself passes (cf. the loki `ComparisonError` quoting Argo's
`helm template ... --include-crds`):

```
helm template alloy grafana/alloy --version 1.13.0 --namespace observability --include-crds
helm template grafana grafana/grafana --version 10.5.15 --namespace observability --include-crds
helm template prometheus prometheus-community/prometheus --version 29.36.0 --namespace observability --include-crds
```

| chart | cluster-scoped resources rendered | namespaced rest |
|---|---|---|
| alloy 1.13.0 | `CustomResourceDefinition podlogs.monitoring.grafana.com`, `ClusterRole alloy`, `ClusterRoleBinding alloy` | DaemonSet, ConfigMap, Service, ServiceAccount |
| grafana 10.5.15 | `ClusterRole grafana-clusterrole`, `ClusterRoleBinding grafana-clusterrolebinding` (no CRDs) | Deployment, Role, RoleBinding, ConfigMaps, Pod (test hook), Secret, Service, ServiceAccounts |
| prometheus 29.36.0 | `ClusterRole` + `ClusterRoleBinding` x2 (`prometheus-kube-state-metrics`, `prometheus-server`; no CRDs) | DaemonSet, Deployments x3, StatefulSet, ConfigMaps, PVC, Services, ServiceAccounts |

Two corrections to the brief this packet was given: grafana also needs
ClusterRole/Binding (the brief named only alloy and prometheus), and
prometheus 29.36.0 renders **no** ServiceMonitor CRDs in its default render
— the brief's "ServiceMonitor CRDs too" is not borne out by the render.
Measuring rather than trusting the brief is why the render commands above
are the evidence, not the chart names.

Distinct `(group, kind)` pairs needed — three, all Argo whitelist entries
are over `(group, kind)`, not over names:

1. `apiextensions.k8s.io / CustomResourceDefinition` — alloy's PodLogs CRD
2. `rbac.authorization.k8s.io / ClusterRole` — alloy, grafana, prometheus
3. `rbac.authorization.k8s.io / ClusterRoleBinding` — alloy, grafana, prometheus

## The whitelist, with its reasons

`templates/substrate/manifests/argocd/appproject.yaml` now carries exactly
those three pairs, each with its reason beside it — and the false sentence
is gone, replaced by the table above in comment form. Not `*/*`: the
manager's original hand-fix shape, which the project's own comment explains
is the wrong default. No kind any Application does not create is added: an
over-grant and an under-grant are the same defect (a policy that does not
describe reality).

Each observability Application declares its own kinds in a
`cafaye.io/cluster-resources` annotation beside the chart version that was
rendered (alloy/grafana/prometheus.yaml); absent means none, and the four
service Applications stay annotation-free and namespaced-only. The
annotation is metadata Argo ignores — sync behaviour is unchanged; the
charts and the services' own resources are untouched, and loki's removal is
untouched (the packet covers the three that remain).

Step 4 (`install_argocd`) needed no change: it re-applies `appproject.yaml`
on every run outside the operator guard (the `roll-c5-appproject-reapply`
packet), so warm boxes converge onto the fixed project with no delete-Argo
dance.

## The checks (`tests/substrate_test.sh` §28)

- `check_appproject_cluster_scope` — every annotation-declared kind is
  whitelisted (completeness: the SyncError), every whitelist entry is
  declared by at least one Application (no over-grant), no entry carries
  `*`, and fewer than seven manifests is red before anything else is read.
- `check_appproject_cluster_scope_pins` — every annotation equals the
  pinned render table above (services: empty); an Application with no pin
  record fails closed, so a new chart's scope is measured, not assumed.
- `check_appproject_no_star` — the no-wildcard verdict on its own line.

Also updated: `check_appproject`'s `*/*` refusal message (it claimed "the
charts need no cluster-scoped resources" — now false) and §21's prose ("no
cluster-scoped whitelist" → the three-kind whitelist).

## Controls' verdicts

Green, real tree (from `bash tests/substrate_test.sh`):

```
PASS substrate_test: every Application-declared cluster-scoped kind is whitelisted, every whitelist entry declared, no wildcards
PASS substrate_test: every Application annotation equals its pinned chart render (services: no cluster scope)
PASS substrate_test: the clusterResourceWhitelist contains no wildcard entry
```

Red controls, each proven red:

```
PASS substrate_test: control: the master-shape project (no whitelist) fails the completeness check
PASS substrate_test: control: a chart growing an unwhitelisted cluster-scoped kind goes red
PASS substrate_test: control: a project whitelisting */* goes red
PASS substrate_test: control: empty apps directory goes red (vacuity guard)
```

- Master-shape: the whitelist stripped from the project (premise asserted:
  the fixture carries no `clusterResourceWhitelist` key) — the live-box
  failure reproduced. Note it is vacuous pre-fix (no annotations yet), which
  is why the packet landed test-first: the first gate run showed the pin
  check red and this control inert, the second run shows all green/red
  correctly.
- Grown-kind: grafana's annotation gains
  `admissionregistration.k8s.io/MutatingWebhookConfiguration` with the
  project untouched (premise asserted by grep) — the case the project's own
  comment anticipates ("If a chart later needs a cluster-scoped kind").
- Star: project whitelisting `{group: *, kind: *}` (premise asserted) —
  over-granting refused, the more dangerous direction.

Full gate: `bash tests/substrate_test.sh` → `330 passed, 0 failed, 0 skipped`;
`bash tests/validate.sh` green (see commit message trailer).

## For the successor

- A chart version bump can introduce new cluster-scoped kinds: re-run the
  three `helm template` commands above and update the annotation + pin +
  whitelist together. §28 fails the run if they disagree, in either
  direction.
- If Loki returns with an object store, its Application needs the same
  treatment: render, annotate, whitelist, extend the pin table (an
  unrecorded Application fails closed, so forgetting is red, not silent).
