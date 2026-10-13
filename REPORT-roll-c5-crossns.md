# REPORT — roll-c5-crossns

**Packet:** every chart dials a bare service name, and every service is in its
own namespace, so no cross-service address resolved on a box.
**Branch:** `roll-c5-crossns` (cut from master). **Worktree:**
`moon/wt/roll-c5-crossns`.
**Status:** fix committed (`04296c9`); narrow gate green; issuer pair measured
and reported.

---

## 1. The inventory, measured

The substrate's namespace layout is **one service per namespace** (`identity`,
`gateway`, `courier`, `parlor`) plus the data plane in **`data`** (`redis`,
`postgres-rw`, `nats`). Kubernetes limits a DNS query that names no namespace to
the **caller's** own, so a bare single label resolves only inside a namespace of
that exact name — and the substrate never puts two peers in one namespace.

Three sources were read: **the live box** (`kubectl … -o jsonpath=…`,
read-only), **the charts in their repos** (`cafaye/<svc>/chart`,
`cafaye/gateway/charts/gateway`), and **the installer** (`install.sh`, which
writes the services' secrets).

> **Which box.** The only cluster this worktree can reach is
> `kubectl config current-context` = **`k3d-cafaye-local`** — a *local* helm
> deploy (namespaces `cert-manager default gateway identity pantry parlor
> probe`, a `redis` Service inside `gateway`, no `data`, no `argocd`, no
> `courier`), **not** the completed substrate install the packet measured. So
> the "box today" column below carries two rows: the packet's measured install
> (quoted) where that is the evidence, and the reachable box where I could read
> it. The tree's values are read from the files outright. The distinction is
> kept because a value measured on the wrong box is a value nobody should trust.

| service (ns) | address / key | value on the box today | read from | verdict |
|---|---|---|---|---|
| **gateway** (`gateway`) | `IDENTITY_URL` | `http://identity:8080` (chart default; packet's install and the reachable box agree) | chart `charts/gateway/values.yaml` → ConfigMap `gateway-env` → `envFrom` | **bare — fixed** |
| gateway | `IDENTITY_JWKS_URL` | *unset* → derived from the issuer, `https://auth.cafaye.com/.well-known/jwks.json` | chart leaves it default; runtime `orDefault(issuer+JWKSPath)` | **public origin — fixed to in-cluster** |
| gateway | `IDENTITY_ISSUER` | `https://auth.cafaye.com` (chart default); the reachable box carries `http://auth.cafaye.test` | chart `charts/gateway/values.yaml` → ConfigMap | **public issuer — marked, not changed** (see §3) |
| gateway | `REDIS_URL` | `redis://:pw@redis.data.svc.cluster.local:6379` (installer) — *reachable box holds `redis://10.43.195.200:6379`, a ClusterIP, because it is a local helm deploy, not this installer* | secret `gateway-secrets`, `secretKeyRef` | already FQDN ✔ |
| gateway | `ROUTE_TABLE` `/v1/pantry` + `/v1/pantry-writes` `baseUrl` | `http://pantry:8080` | chart default → ConfigMap | **out of scope** — pantry is not a substrate Service (see §5) |
| **identity** (`identity`) | `COURIER_BASE_URL` | `http://courier.courier.svc.cluster.local:4000` | secret `identity-secrets` (step 12, with the token) | already FQDN ✔ |
| identity | `NATS_URL` | `nats://nats.data.svc.cluster.local:4222` | secret `identity-secrets` (step 9) | already FQDN ✔ |
| identity | `DATABASE_URL` | `postgres://identity_app:…@postgres-rw.data.svc.cluster.local:5432/identity?sslmode=disable` | secret `identity-secrets` (step 9) | already FQDN ✔ |
| identity | `OIDC_ISSUER` | `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER` → **default empty**; the reachable box holds `https://auth.cafaye.test` | secret `identity-secrets` | the mint side of the issuer pair (§3) |
| **courier** (`courier`) | `COURIER_IDENTITY_URL` | `http://identity.identity.svc.cluster.local:8080` | secret `courier-secrets` (step 12, with the token) | already FQDN ✔ |
| courier | `DATABASE_URL` | `ecto://courier_app:…@postgres-rw.data.svc.cluster.local:5432/courier` | secret `courier-secrets` (step 9) | already FQDN ✔ |
| **parlor** (`parlor`) | `IDENTITY_URL` | **nothing set it** — chart `env: {}`, `parlor-secrets` carries only `DATABASE_URL` + `OTEL_SDK_DISABLED` | — | **unset — fixed** |
| parlor | `BILLING_URL` | unset | — | **out of scope** — billing is not a substrate Service; unset is parlor's supported state (§5) |
| parlor | `DATABASE_URL` | `postgres://parlor_app:…@postgres-rw.data.svc.cluster.local:5432/parlor?sslmode=disable` | secret `parlor-secrets` (step 9) | already FQDN ✔ |

**Everything the installer writes was already fully qualified** — an earlier
packet fixed `NATS_URL` and the courier↔identity pair, and `REDIS_URL`/the DSNs
were born FQDN. The **defect is concentrated in the two Applications whose
charts ship a compose default**: gateway's `IDENTITY_URL` (+ the implicit JWKS
origin) and parlor's `IDENTITY_URL` (which nothing set at all).

---

## 2. Each fix's home and reason

**The decision: the substrate spells the box's addresses, in each Application's
`spec.source.helm.values`.** The substrate owns the Applications *and* the
namespace layout, so it is the one place that can know both — a chart cannot
learn a namespace it is deployed into, and hard-coding a box's FQDN into a
chart's default would be the "chart must stay deployable elsewhere" trap the
packet forbids. The otel packet already established this pattern for gateway's
telemetry switch, and Helm merges maps, so each Application **adds** keys to the
chart's `env:` rather than replacing the ones it does not mention.

| home | what | why there |
|---|---|---|
| `manifests/applications/gateway.yaml` `spec.source.helm.values` | `env.IDENTITY_URL: http://identity.identity.svc.cluster.local:8080` | gateway's chart reads clear env from a ConfigMap rendered from `.Values.env`; the chart's default is the compose spelling. |
| `manifests/applications/gateway.yaml` `spec.source.helm.values` | `env.IDENTITY_JWKS_URL: http://identity.identity.svc.cluster.local:8080/.well-known/jwks.json` | gateway VERIFIES with the key set fetched from the issuer's origin. The issuer is a public https origin; fetching the keys over the cluster network makes verification independent of the box's public DNS and of a hairpin through its own edge. gateway's runtime documents the split (`internal/httpapi/runtime.go`: "IDENTITY_JWKS_URL … an explicit key set, when identity publishes it elsewhere"). |
| `manifests/applications/parlor.yaml` `spec.source.helm.values` | `env.IDENTITY_URL: http://identity.identity.svc.cluster.local:8080` | parlor's runtime reads `process.env.IDENTITY_URL` to reach identity's `/auth` endpoints; its chart ships `env: {}` and its secret carries no identity address, so on a box parlor fell back to the compose spelling and **could not serve a sign-in**. |

No port and no path was changed. identity's Service port is 8080 (its chart's
`service.port`) and courier's is 4000; the ports in the addresses are the
peers' own, unchanged.

**One fact, one spelling.** The installer's `IDENTITY_URL` constant
(`install.sh:252`) and gateway's/parlor's Application values are three
consumers of the same fact. §4's check asserts they all name the same Service in
the same namespace, so a drift in any of them is a red gate.

---

## 3. The issuer pair — reported, not guessed

The packet asked for the pair, because **the value gateway verifies with must
equal the `iss` identity mints with, or no token verifies.**

| half | where | value |
|---|---|---|
| **mint** (identity) | `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER` → `identity-secrets/OIDC_ISSUER` | **no default — empty** (`install.sh:394`). Unset means identity serves **no OIDC surface at all** (`config.go` `OIDCEnabled()` requires issuer+key+keyid; a lone key is a boot refusal). |
| **mint** (identity chart) | `cafaye/identity/chart/values.yaml` | carries **no issuer key** — the issuer rides the secret, not the chart. |
| **verify** (gateway) | `charts/gateway/values.yaml` `env.IDENTITY_ISSUER` | `https://auth.cafaye.com` (a public Phase-C origin). |
| **verify** (gateway runtime fallback) | `internal/auth/jwks.go` `DefaultIdentityIssuer` | `https://identity.localhost` — only when the chart value is *absent*, which it is not. |

**So the pair is `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER` (default: unset) vs.
`https://auth.cafaye.com` (gateway chart default), and they are only equal if
the operator sets the installer variable to `https://auth.cafaye.com`.** A box
that wants OIDC must set **both to the same public origin**, e.g.:

```sh
export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='https://auth.<customer-domain>'
# and set gateway's IDENTITY_ISSUER to the SAME origin in the values commit that
# owns the public surface (the chart's default is auth.cafaye.com).
```

**Measured on the reachable box, the pair is already mismatched** — and it
shows the failure mode concretely:

```
$ kubectl get cm gateway-env -n gateway -o jsonpath='{.data.IDENTITY_ISSUER}'
http://auth.cafaye.test
$ kubectl get secret identity-secrets -n identity \
    -o go-template='{{.data.OIDC_ISSUER | base64decode}}'
https://auth.cafaye.test
```

identity mints `iss: https://auth.cafaye.test`; gateway expects
`http://auth.cafaye.test`. The **scheme differs**, so every id_token is
refused with an `iss` mismatch. (This box is a local helm deploy, not the
substrate installer; it is evidence of the failure mode, not of the tree.)

**WHY `IDENTITY_ISSUER` IS DELIBERATELY NOT SET IN THE APPLICATION.** The
issuer is the customer's own public domain and `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER`
has no default; the Applications are static YAML the installer applies verbatim,
so a value the operator alone knows cannot be written there without templating
the Applications (the TLS step's placeholder path). The correct home for it is
the **values commit** that owns the box's public surface, and it is reported
here with the exact pair so that commit cannot be written blind. **The
successor's move if the fleet wants it wired:** substitute
`IDENTITY_ISSUER_PLACEHOLDER` in `gateway.yaml` from
`KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER` at apply time, exactly as
`install_cluster_issuers` substitutes `ACME_EMAIL_PLACEHOLDER` — one operator
input, both halves.

Also worth flagging: **identity's chart ships `ingress.enabled: false`**, so
identity has no public ingress of its own on a box. A public issuer origin that
must serve `/.well-known/jwks.json` therefore has to be routed to identity
somewhere else (gateway, or a later values commit); that is a fleet-level
question the packet did not open, and `IDENTITY_JWKS_URL` now makes the
*verification* half depend on nothing public.

---

## 4. The check, and its controls

`tests/substrate_test.sh` **§24** — "EVERY CROSS-SERVICE ADDRESS RESOLVES TO A
SERVICE THE MANIFESTS SHIP" — a static check over YAML
(`check_cross_namespace_addresses`), plus five red controls. It asserts:

1. the **shipped Service set is derived, not typed**: each Application's
   `metadata.name` + `spec.destination.namespace` for the launch services;
   every `Service` document in `manifests/data/`; and CNPG's derived
   `<cluster>-rw` from the `Cluster` document;
2. every address the **Applications** set (`spec.source.helm.values`, every
   scalar string, so a URL nested in the route table is found too) is
   `<svc>.<ns>.svc.cluster.local` and names a shipped Service **in the
   namespace it ships in**;
3. **gateway.yaml and parlor.yaml each set at least one** cross-service address
   — a per-Application guard, because a guard on the total would be satisfied by
   gateway's two addresses alone and a service that silently lost its override
   (the exact state this packet fixes for parlor) must be its own failure;
4. every **`.svc.cluster.local` name `install.sh` writes** (comments stripped)
   resolves the same way, and at least five exist (non-vacuity).

**Five red controls, each verified to fail for the *right reason*, not merely a
non-zero exit** (each message printed and read):

| control | fixture | message it must produce |
|---|---|---|
| a bare name | gateway's `IDENTITY_URL` → `http://identity:8080` | "`'identity' is not fully qualified`" |
| wrong namespace | `identity.identity…` → `identity.gateway…` | "`puts 'identity' in namespace 'gateway', but the manifests ship it in identity`" |
| a service no manifest ships | gateway's address → `pantry.pantry…` | "`names Service 'pantry', which the manifests do not ship`" |
| a service loses its address | parlor's `helm` block removed | "`parlor.yaml sets no cross-service address`" |
| drifted installer name | `redis.data…` → `redis.gateway…` | "`puts 'redis' in namespace 'gateway', but the manifests ship it in data`" |

**The `pantry` control is the one that keeps the check honest**: any
well-spelled name is not enough — the substrate may only name Services its own
manifests create. That is why gateway's `ROUTE_TABLE` (pantry) is *not* injected
(§5).

**A harness hazard found while writing §24, and worth a successor's attention:**
`install.sh` defines globals with ordinary names — `DATA_DIR`, `MANIFEST_DIR`,
`ARGOCD_MANIFEST_DIR`, `SCRIPT_DIR`. A few test sections `. "$installer"` a
fixture install in the **test shell** (not a subshell), so `$DATA_DIR` is
silently rebound to `$WORK/manifests/data` for every later check. §24's first
draft used `$DATA_DIR` and its controls "passed" **because the directory did not
exist** — a red for the wrong reason. §24 now names
`"$SUBSTRATE/manifests/data"` literally. The same trap will catch the next
post-§19 check that reaches for `$DATA_DIR`; renaming the installer's globals is
the real fix and is left for its own packet.

---

## 5. What I deliberately did NOT do

- **Did not inject gateway's `ROUTE_TABLE` (pantry).** `pantry` is not a
  `Service` the substrate's manifests ship (it is not one of the four launch
  Applications, and `manifests/` creates it nowhere), so an address to it fails
  §24's own premise. It belongs to the **values commit** that deploys pantry.
  Its chart default `http://pantry:8080` is also a **port** that does not match
  pantry's own Service (`service.port: 80`, `targetPort: http` → 8080) — a
  separate defect the packet forbids me to "fix by changing a port", so it is
  reported here instead: **when pantry is deployed, gateway's `ROUTE_TABLE`
  needs `pantry.pantry.svc.cluster.local:80`, not `:8080`.**
- **Did not set parlor's `BILLING_URL`.** Unset is parlor's supported "no
  billing deployed" state, and the substrate ships no billing.
- **Did not edit any service chart.** The fix is entirely in kit's own
  Applications; the charts stay deployable to their compose stack and to any
  other cluster.
- **Did not set `IDENTITY_ISSUER`**, for the reason in §3.
- **Did not change a port or a URL path.**
- **Did not touch `.github/workflows/`, another repo, or the box** (the
  `kubectl` reads above are read-only; no port-forward succeeded because the
  reachable box's gateway is `0/1`).
- **Did not weaken a check.** §24 is new; nothing existing was relaxed.

---

## 6. Suite counts

- `bash tests/substrate_test.sh` → **253 passed, 0 failed, 0 skipped** (green).
  §24 contributes **6** checks (one green + five controls), so the suite was
  **247** before this packet — the same count the otel packet reported after the
  linktpl rebase, i.e. nothing earlier was disturbed.
- `bash -n tests/substrate_test.sh` → clean. `bash -n
  templates/substrate/install.sh` → clean.
- `shellcheck -S warning tests/substrate_test.sh templates/substrate/install.sh`
  → clean.
- `yamllint -c lint/yamllint.yml` on the two edited Applications → one
  **pre-existing** `missing document start "---"` warning each (every sibling
  manifest has it), no errors.

---

## 7. The box commands a successor should run

On a completed substrate install, confirm all four services are green. Each
service's readiness is `/readyz`; forward it and ask:

```sh
# gateway — its /readyz names its deps (identity, redis)
kubectl -n gateway port-forward deploy/gateway 8080:8080 &
curl -sS http://127.0.0.1:8080/readyz; echo

# identity
kubectl -n identity port-forward deploy/identity 8081:8080 &
curl -sS http://127.0.0.1:8081/readyz; echo

# courier (Elixir container port 4000)
kubectl -n courier port-forward deploy/courier 8082:4000 &
curl -sS http://127.0.0.1:8082/readyz; echo

# parlor (container port 3000)
kubectl -n parlor port-forward deploy/parlor 8083:3000 &
curl -sS http://127.0.0.1:8083/readyz; echo
```

**What "green" looks like now:** gateway's `/readyz` answers
`{"deps":{"identity":"ok","redis":"ok"}}` (previously
`{"identity":"unavailable","redis":"unavailable"}`), identity's `/readyz`
answers 200, and parlor's `/readyz` answers 200 — which it could not do before
this packet, because `IDENTITY_URL` was unset and parlor's runtime refuses to
serve a sign-in without it. A `500` from parlor's sign-in path with a message
naming `IDENTITY_URL` is the *pre-fix* symptom.

Also worth reading straight off the box, because it is the whole packet in two
commands:

```sh
kubectl -n gateway get cm gateway-env -o jsonpath='{.data.IDENTITY_URL}{"\n"}{.data.IDENTITY_JWKS_URL}{"\n"}'
kubectl -n gateway get secret gateway-secrets -o go-template='{{.data.REDIS_URL | base64decode}}{{"\n"}}'
```
