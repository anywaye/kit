# REPORT — roll-c5-otel

**Packet:** every service's telemetry points at a collector nobody deploys.
**Branch:** `roll/c5-otel` (cut from master). **Worktree:** `moon/wt/roll-c5-otel`.
**Status:** fix committed; narrow gate green; decision measured.

## The decision, and how it was measured

**Telemetry on a box is DELIBERATELY OFF.** The services are told to disable
their OTel SDK (`OTEL_SDK_DISABLED=true`) instead of retrying an endpoint that
does not exist. This is the packet's second branch, chosen because the first
branch ("wire them to alloy") fails on three independent measurements.

### Evidence 1 — the live box has no endpoint

The live box is the `k3d-cafaye-local` cluster (context `k3d-cafaye-local`),
which is what the packet's `10.43.0.10:53` DNS line comes from.

```
$ kubectl get svc -n observability
No resources found in observability namespace.
```

There is no `otel-collector` Service and no alloy Service on the box at all.
The namespaces that exist are `cert-manager default gateway identity
kube-node-lease kube-public kube-system pantry parlor probe` — observability was
never synced here. So "prove the endpoint exists on a live box" cannot be
satisfied for the wired branch on the box the packet points at.

The failure is live and repeating, on both the service the packet names and one
it does not:

```
$ kubectl logs -n identity deploy/identity --tail=5
… level=INFO msg="traces export: Post \"http://otel-collector:4318/v1/traces\":
  dial tcp: lookup otel-collector on 10.43.0.10:53: no such host"   (every 10s)

$ kubectl logs -n gateway deploy/gateway --tail=5
… traces export: rpc error: code = Unavailable desc = name resolver error:
  produced zero addresses                                    (every 5–10s)
```

`identity-secrets` on the box carries `DATABASE_URL LOG_LEVEL OIDC_ISSUER
OIDC_LOGIN_UI_URL OIDC_SIGNING_KEY OIDC_SIGNING_KEY_ID PORT SIGNUP_SIGNING_KEY`
— **no OTEL variable at all** — so identity falls to its compiled default.

### Evidence 2 — alloy as shipped does not accept OTLP

Read from the exact chart the substrate pins (`alloy` `1.13.0`, fetched from
`grafana.github.io/helm-charts`):

- `values.yaml` → `alloy.configMap.content: ''`, so the ConfigMap renders
  `config/example.alloy`: a `logging` block and `discovery.kubernetes.*`
  components. **There is no `otelcol.receiver.otlp`.**
- `values.yaml` → `alloy.extraPorts: []` and `service.enabled: true`, so the
  rendered Service exposes **only** `http-metrics` on `listenPort: 12345`.
  4317/4318 are not on it.

So the packet's hypothesis — "alloy … merely needs the Service name/port the
services use" — is false: alloy needs a new config *and* new ports, and even
then there is nowhere for a span to land.

### Evidence 3 — there is no trace store, by the fleet's own decision

The substrate's observability Applications are `alloy`, `grafana`, `loki`,
`prometheus` — **no Tempo**. `DEPLOYMENT.md`'s stack table says:

| Traces | **deferred** | services already emit OTLP (`caf gen telemetry`); Tempo slots in later as one more Application. Nothing re-architects |

Loki is a log store (its OTLP intake is for OTLP *logs*); Prometheus takes
remote-write; Grafana is a UI. There is no component for a span to land in, so
"wired … with the data landing somewhere a person can look" is unsatisfiable for
traces today. Turning the SDK off is the honest state, and it is what core
already anticipated.

### The mechanism, which is core's, not a new one

`core/schemas/telemetry/otel-endpoint.schema.json` pins the no-op path:

- `noOp.implementedBy` is `const "OTEL_SDK_DISABLED"` — "the OTel spec's own
  kill switch … Using it is what makes the no-op genuinely free in six
  languages."
- `noOp.buffering/retry/warnings/startupCost` are each `const "none"`.
- `endpoint.required` is `const false`.

`OTEL_SDK_DISABLED=true` is therefore the fix, not a log-level change and not a
re-point at another name that does not resolve.

## The fix, and why it is shaped this way

| site | what | why there |
|---|---|---|
| `templates/substrate/install.sh` | one constant, `SERVICE_OTEL_DISABLED=(--from-literal=OTEL_SDK_DISABLED=true)`, referenced by `identity-secrets`, `courier-secrets` and `parlor-secrets` | the generated charts inject env with `envFrom: secretRef`, so a key in the secret **is** an environment variable. One spelling, referenced — not retyped. |
| `templates/substrate/manifests/applications/gateway.yaml` | `spec.source.helm.values` → `env.OTEL_SDK_DISABLED: "true"` | **gateway's chart is hand-written and is the one exception.** It reads its clear env from a ConfigMap rendered from `.Values.env`, and its secret only through a `secretKeyRef` (REDIS_URL) and a `volumes.secret` item (the assertion key). A key in `gateway-secrets` never reaches the pod, so the switch rides the Application — kit's own file. |

The reason is written at both code sites, and the exception is named at the
site that differs. `templates/substrate/README.md` and `CHANGELOG.md` carry the
decision in prose.

**What this does NOT reach, and why it is not hidden:** it is a *fresh-box*
fix. An existing box holds a `identity-secrets`/`courier-secrets`/
`parlor-secrets` the installer refuses to overwrite, so those pods keep their
old (absent) key until the secret is rotated by replacement — the installer's
documented rotation path, not a re-run. The gateway Application is re-applied on
every install, so gateway is fixed on the next sync.

## The test, and its controls

`tests/substrate_test.sh` §23 ("THE SERVICES' TELEMETRY IS OFF ON THE BOX, ON
ONE SPELLING") asserts:

1. the switch is **defined once**, with the spec's own key and value
   (`OTEL_SDK_DISABLED=true`);
2. identity/courier/parlor's secrets carry it **by reference**, not by retyping;
3. gateway's Application carries the **same** key/value through
   `spec.source.helm.values` (so the two sites agree);
4. all four services have a secret, so none is dropped from the config step.

Five red controls, each of which must answer differently:

- the switch dropped from the constant (`SERVICE_OTEL_DISABLED=()`);
- the switch **name drifted** (`OTEL_TELEMETRY_OFF=true` — a name no SDK reads);
- identity's secret losing its reference (falls back to the compose name);
- gateway's Application with a drifted switch name;
- gateway's Application with the value drifted to `false`.

The packet's point 3 was written for the wired branch ("the OTLP endpoint …
asserted to be a Service the observability manifests actually ship"). That
branch was ruled out by measurement, so §23 asserts the off branch's equivalent
and its red control drifts the switch **name**, which is the same property (a
name nothing honours).

## The rebase onto master (the linktpl merge)

After the fix was committed, the manager's integration step rebased
`roll/c5-otel` onto `master` (`db42bd7`, the `roll/c5-linktpl` merge). Two
conflicts, both because master and this packet edited the same lines:

- `install.sh` — the `RECORD identity-secrets:` line: master added the five
  `*_LINK_TEMPLATE` keys, this packet added `OTEL_SDK_DISABLED`. Resolved as the
  **union** (both sets of keys; they are independent).
- `CHANGELOG.md` — two new `### Substrate` bullets at the top. Resolved by
  keeping both.

The rebased tip is `c00e68c` (this packet's two commits, `afbe7a2` + `c00e68c`).
`git diff master roll/c5-otel` is exactly this packet's six files.

## Suite counts

- `bash tests/substrate_test.sh` → **247 passed, 0 failed, 0 skipped** (green;
  244 before the rebase, +3 from the linktpl checks master brought in).
- `bash -n` on `install.sh` and `substrate_test.sh` → clean.
- `shellcheck -S warning` on both → clean.
- `.venv/bin/yamllint -c lint/yamllint.yml` on `gateway.yaml` → one pre-existing
  `missing document start "---"` warning (every sibling manifest has it), no
  errors.
- `bash tests/validate.sh --static-only` → **one FAIL, and it is pre-existing
  and unrelated.** The finding is
  `.github/workflows/image.reusable.yml :: jobs/build/steps/6: tags is set as a
  PREFIX assignment …` — the check's own `prefix_assignments` mis-reads the
  multiline quoted assignment `tags="$tags` / `$IMAGE:$APP_VERSION"` as
  `tags= $tags` and reports it. That file is untouched by this packet
  (`git diff HEAD~1 HEAD -- .github/` is empty), and the packet forbids touching
  `.github/workflows/`, so it is reported and left alone. Everything this packet
  could break passed: the substrate section (which runs `substrate_test.sh`
  inside the static phase) and `check_obs_chart_sources`, which asserts the
  `(repoURL, chart, targetRevision)` triple for the gateway Application and
  ignores extra `source` keys such as the new `helm.values`.

## What I deliberately did NOT do

- **Did not add an OTel Collector release or alloy values.** Alloy as shipped
  does not accept OTLP, and there is no trace store for the data to land in;
  adding a receiver that drops spans would be the same defect made quieter.
- **Did not point the services at a name that does not resolve.** No
  `alloy.observability…:4318` endpoint was written, because alloy exposes no
  such port and a pre-staged endpoint that cannot receive is a fiction.
- **Did not touch `.github/workflows/`, another repo, or the live box.** The
  gateway fix is in kit's own Application manifest, not in gateway's chart.
- **Did not lower a log level in a service I do not own**, and did not edit any
  sibling service repo. No service-side edit is needed for this fix.
- **Did not weaken any check**, and did not silence the `unpinned-uses` or any
  other gate finding.

## The successor's first move

If the packet is revisited, the move is **not** more kit-side work: it is the
Tempo Application. Add `templates/substrate/manifests/applications/tempo.yaml`
(pinned upstream chart, namespace `observability`), then add alloy values
(`alloy.configMap.content` with `otelcol.receiver.otlp` + `alloy.extraPorts`
for 4317/4318 + an exporter to Tempo), remove `SERVICE_OTEL_DISABLED` from the
three secrets and gateway's `helm.values`, and set `<SERVICE>_OTEL_ENDPOINT` to
the alloy Service **once**. §23 becomes the check that the endpoint names a
Service the manifests ship, with the switch-name control repurposed to the
Service-name control the packet originally described.
