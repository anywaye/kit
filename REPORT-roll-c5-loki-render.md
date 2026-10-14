# REPORT-roll-c5-loki-render: the observability Application that was Unknown

## The evidence, from the live box

```
$ kubectl -n argocd get applications
NAME         SYNC STATUS   HEALTH STATUS
alloy        OutOfSync     Healthy
courier      Synced        Healthy
gateway      Synced        Healthy
grafana      OutOfSync     Healthy
identity     Synced        Healthy
loki         Unknown       Healthy
parlor       Synced        Healthy
prometheus   OutOfSync     Healthy
```

`Unknown` sync status means Argo could not even render the chart. Its own reason:

```
kubectl -n argocd get application loki -o jsonpath='{range .status.conditions[*]}{.message}{"\n"}{end}'

ComparisonError=Failed to load target state: failed to generate manifest for source 1 of 1:
rpc error: code = Unknown desc = Manifest generation error (cached): failed to execute helm
template command: failed running helm: `helm template . --name-template loki --namespace
observability --kube-version 1.37.1 <api versions removed> --include-crds` failed exit
status 1: Error: execution error at (loki/templates/write/statefulset-write.yaml:50:28):
Please define loki.storage.bucketNames.chunks
```

The upstream Loki chart 7.3.0 in SimpleScalable mode requires
`loki.storage.bucketNames.{chunks,ruler,admin}` and an object-storage backend
(endpoint/bucket/accessKeyId/secretAccessKey). The substrate's values did not name them.
Every other Application rendered; this one failed at the template.

## Family of fix chosen, and why

**Removed the Loki Application** (family 2) rather than patching its values.

Measured against the live box and the chart:

* `helm template loki grafana/loki --version 7.3.0` with no values → `Please define loki.storage.bucketNames.chunks` (reproduced locally).
* With `loki.storage.bucketNames.{chunks,ruler,admin}` but without `loki.storage.s3.endpoint/accessKeyId/secretAccessKey` → `You must provide a schema_config` or a runtime half-config that stores nothing — the second red control.
* With `deploymentMode=SingleBinary --set loki.storage.type=filesystem --set loki.useTestSchema=true --set singleBinary.replicas=1` → 1207 lines, it renders. But it is a single replica on filesystem/emptyDir, untuned, with no persistence sizing, and unproven on this box. It trades a render error for a persistence decision nobody asked for.
* The substrate provisions **no object store** (no S3, no MinIO, no bucket). Inventing bucket names plus a missing backend is a log pipeline that silently stores nothing — worse than honestly saying it is not installed. `DECISIONS.md` and the installer's own invariant is that a substrate that cannot satisfy a chart should not claim it.

So the Application is gone. Logs remain in **journald / `kubectl -n <ns> logs <pod>`**, and Alloy still runs but ships nowhere centrally. If a future substrate provisions an object store, the Application returns with a complete storage block (bucketNames + endpoint/bucket/keys or SingleBinary filesystem with persistence). The report is the proof: `install.done` now says where logs go, beside the TLS/OIDC verdict the `roll-c5-honest-done` seam opened.

Alternative family (patch values) was measured and rejected.

## What changed

* `templates/substrate/manifests/applications/loki.yaml` — deleted.
* `templates/substrate/manifests/argocd/appproject.yaml` — description "eight Applications" → "seven Applications", sourceRepos comment updated (observability three, not four).
* `templates/substrate/README.md` — observability table and prose: four → three, eight → seven, loki row removed, stack description updated.
* `templates/substrate/install.sh` — observability set comment `alloy + loki + grafana + prometheus` → `alloy + grafana + prometheus`; extended the `honest-done` block (between `# --- honest-done BEGIN` / `END`):
  * `kit_substrate_log_store()` — `loki` if manifest present else `journald`.
  * `kit_substrate_readiness_preflight` — now also prints `logs: centralized Loki not installed — logs in journald / kubectl logs; Alloy runs but ships nowhere centrally`.
  * `kit_substrate_readiness_final` — after the TLS/OIDC `THIS BOX WILL NOT FULLY SERVE UNTIL:` block, prints `logs: centralized Loki not installed — ...` with the `loki.storage.bucketNames.chunks` evidence and the object-storage reason, or `logs: centralized Loki installed` when present.
  * `kit_substrate_readiness_json` — now emits `,"log_store":"journald"|"loki"` beside `tls_pending_hosts` and `oidc_configured`, so headless `readiness` event carries the shape.
* `tests/substrate_test.sh` — added `kit_substrate_log_store` to `VALUE_PRODUCERS` allowlist (so the stdout-via-command-substitution check stays green), added section 27 `check_loki_honest`:
  * **Green**: no `loki.yaml`, DRY_RUN human output contains `centralized Loki not installed` + `loki.storage.bucketNames.chunks` + `journald`, headless readiness contains `log_store:journald` beside `tls_pending_hosts`/`oidc_configured`.
  * **Red 1**: fixture re-adding the master `loki.yaml` with no `helm.values` (no bucketNames) → red.
  * **Red 2**: fixture with `bucketNames.{chunks,ruler,admin}` but without `endpoint/accessKeyId/secretAccessKey` (half object-storage config) → red.
  * **Vacuity guard**: empty apps dir → red (count <7).
* `tests/validate.sh` — observability `EXPECTED` table removed `loki` entry (now alloy/grafana/prometheus only), updated prose (four → three, eight → seven), updated registry red-control to use `alloy.yaml` instead of the deleted `loki.yaml`.
* `tests/substrate_test.sh` shellcheck header — added `# shellcheck disable=SC1090,SC2034` to keep the `shellcheck -S warning` gate green on newer shellcheck (SC1090 non-constant source).

## Controls' verdicts

Green, real tree:

```
check_loki_honest "$MANIFESTS" "$SUBSTRATE/install.sh"
loki absent, install.done honest: journald + bucketNames evidence, headless log_store journald
PASS substrate_test: loki Application absent and install.done reports journald + bucketNames evidence (headless log_store journald)
```

Red control 1 (broken tree — no bucketNames, the shape master carried):

```
fixture_loki_broken/loki.yaml (no helm.values)
control: the broken loki values (no bucketNames) go red — PASS (went red as required)
control fixture premise: broken loki carries no bucketNames (master shape) — PASS
```

Red control 2 (half config — bucketNames without endpoint/keys):

```
fixture_loki_half/loki.yaml (bucketNames chunks/ruler/admin, region only, no endpoint/accessKeyId/secretAccessKey)
control: half object-storage config (bucketNames without endpoint/keys) goes red — PASS (went red as required)
```

Vacuity guard:

```
empty apps dir (0 manifests) → red — PASS (apps_dir has 0 manifest(s), expected 7)
```

Full substrate_test run:

```
-- substrate_test: 323 passed, 0 failed, 0 skipped
PASS: 323 passed, 0 failed, 0 skipped
```

Validate static (representative):

```
PASS tests/substrate_test.sh  (shellcheck -S warning)
PASS obs chart sources  (service charts stay on private OCI registry; alloy/grafana/prometheus carry their pinned upstream repoURL, chart and targetRevision; anything else fails closed)
              sources: 7 Application(s) resolve to a published chart
```

## What replaces Loki

* **Centralized log search is not available** on this substrate. Query per-pod logs with `kubectl -n <namespace> logs <pod>` and node logs with `journalctl` on the box.
* **Alloy** remains deployed (alloy 1.13.0) but its default config is `config/example.alloy` — discovery + logging, no `loki.write` — so it ships nowhere centrally. This is measured, not assumed (`templates/substrate/install.sh` telemetry-off comment).
* **Grafana** remains but has no Loki datasource on this substrate; Prometheus remains for metrics.
* Future work to re-add Loki is one commit: restore `loki.yaml` with a complete storage block (either SingleBinary filesystem with `singleBinary.replicas:1` + `loki.storage.type:filesystem` + persistence, or SimpleScalable s3 with `bucketNames` + `endpoint`/`bucket`/`accessKeyId`/`secretAccessKey` pointing at a provisioned object store) and extend `kit_substrate_log_store` / `kit_substrate_readiness_final` to report `loki` again. The `check_loki_honest` branch for a present, valid loki already covers that shape.

## Honest done

Both human and headless paths now report the log store:

* Human (DRY_RUN or live `install.done`):
  ```
  logs: centralized Loki not installed — logs remain in journald / kubectl logs (kubectl -n <ns> logs <pod>); Alloy runs but ships nowhere centrally
    reason: loki chart 7.3.0 SimpleScalable requires loki.storage.bucketNames.chunks and an object-storage backend (endpoint/bucket/access_key/secret_key); this substrate provisions no object store
  ```
* Headless JSONL `readiness` event:
  ```
  {"event":"readiness","message":"readiness: ...","tls_pending_hosts":[...],"oidc_configured":true|false,"log_store":"journald"}
  ```
  alongside the existing `install.done` timing/steps table.

Preflight also prints the log store, so a plan (`DRY_RUN=1`) shows the same shape the live box will have before any `kubectl apply`.

## Verification

* `bash tests/substrate_test.sh` — 323 passed, 0 failed (see above).
* `bash tests/validate.sh --static-only` (representative) — static phase PASS including `substrate_test.sh  (shellcheck -S warning)` and `obs chart sources  (7 Application(s) ...)`.
* `helm template` reproduction: `helm template loki grafana/loki --version 7.3.0` → `Please define loki.storage.bucketNames.chunks`; with `deploymentMode=SingleBinary` + filesystem → renders (1207 lines) — measured, noted, not shipped.
