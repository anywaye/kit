# templates/substrate — the customer install

**One command, one box.** `curl https://cafaye.com/box/install | sh` installs
customer substrate: k3s → cert-manager → CloudNativePG → Argo CD core →
image pull secret → the first Applications sync → the Let's Encrypt
ClusterIssuers.

The decisions are in [`DEPLOYMENT.md`](../../../DEPLOYMENT.md). This directory
is the executable half of that decision record. Read the decision record first;
this file only describes what is here and what is proven.

## What is in this directory

| Path | What it is |
|---|---|
| `install.sh` | The one command. Installs the substrate in order, idempotently, failing loudly and early. |
| `kit-install.mjs` | The install host: a Cloudflare Worker serving `install.sh` at `GET /` and `GET /install.sh` — the exact bytes, byte-proven in kit's gate. |
| `wrangler.jsonc` | The Worker's config: pinned `compatibility_date`, observability on, a Text-module rule bundling `install.sh`. No `routes` — the domain binding is an operator action. |
| `manifests/applications/` | The Argo CD `Application` manifests: the four launch services (identity, gateway, courier, parlor) and the observability set (Alloy, Grafana, Prometheus). |
| `manifests/tls/` | The two Let's Encrypt `ClusterIssuer` manifests — staging and production, HTTP-01 through Traefik. |
| `manifests/data/` | The data layer, applied by `install.sh` (not by Argo): `postgres-cluster.yaml` — the CNPG `Cluster` reproducing the local `10-cluster.sh` contract — `redis.yaml` — one Deployment + Service + PVC — and `nats.yaml` — one Deployment + Service + PVC running NATS with JetStream, the bus the local stack runs. |

## What `install.sh` does

1. **k3s** — single node, sqlite datastore. No etcd on one box. The step proves
   the `Node` object exists before it waits for it to be Ready, because the
   kubelet registers it a few seconds after k3s starts and a wait on an empty
   list is an error rather than a wait.
2. **cert-manager**
3. **CloudNativePG**
4. **Argo CD core** — no Dex, no SSO, no Redis HA.
   Steps 2–4 are three **independent** operator installs (separate namespaces,
   separate CRDs, applies that reference nothing the others create), so all
   three manifests are **applied back to back** and then **waited on together**
   at the end of step 4. Waiting inside each step would hold CNPG's apply behind
   cert-manager's rollout and Argo CD's behind CNPG's, and the three steps would
   add up; grouped, the controllers roll out concurrently. A component already
   present at its guard is not waited on again, so a warm re-run still skips.
   **The `default` AppProject is applied AFTER the wait and is NOT behind the
   guard.** `manifests/argocd/appproject.yaml` is a file this repo owns and edits
   whenever the Applications' chart paths move; the guard above answers a
   different question — *is the operator installed* — and covering both behind
   one answer was how a box that already had Argo CD kept the pre-glob project
   and refused every Application with `repo … is not permitted in project
   'default'`. A guard on the project's own existence would be worse: it answers
   "present" on the box holding the *wrong* project. So the operator stays
   guarded and the project is re-applied on every run — one local `kubectl
   apply`, which is a no-op round trip when it is unchanged, and the same
   convergence mechanism step 6 uses for the seven Applications.
5. **The GHCR image pull secret** — **redeemed, not supplied.** The box presents
   its own capability (`KIT_SUBSTRATE_REGISTRY_CAPABILITY`, single-use,
   minutes-lived, bound to `KIT_SUBSTRATE_BOX_ID`) and receives ONE short-lived
   dockerconfigjson, held in a shell variable and applied through a pipe. No
   long-lived registry credential is handed over, and nothing reaches disk,
   argv or stdout. Re-running re-redeems, because a credential with minutes of
   life is supposed to be replaced. **The six namespaces that pull are created
   by this step, idempotently, before the secret is written into each of
   them** — the credential has to exist before the first pod that pulls with
   it is scheduled, and five of those six namespaces do not exist until step
   6's Applications create them.
6. **The first Applications** — applied from `manifests/applications/`, so Argo
   starts syncing.
7. **The Let's Encrypt ClusterIssuers** — `letsencrypt-staging` and
   `letsencrypt-prod`, applied from `manifests/tls/` with the operator's
   `KIT_SUBSTRATE_ACME_EMAIL` substituted into a pipe at apply time. Never a
   literal in the repo, never written to disk, never printed.
8. **The Postgres Cluster** — one CNPG `Cluster` (`postgres` in the `data`
   namespace) applied from `manifests/data/postgres-cluster.yaml`, plus the
   eight `postgres-role-*` password secrets it names. Requires
   `KIT_SUBSTRATE_DATABASES` (no default; must equal the manifest's service
   set) and refuses empty in DRY_RUN, naming the fix.
9. **Redis and the services' secrets** — one Deployment + Service + PVC in
   `data`, applied from `manifests/data/redis.yaml`, with the generated
   `redis-password` secret; then `identity-secrets`, `gateway-secrets`,
   `courier-secrets`, `parlor-secrets`, one per service namespace, each
   exactly the keys its chart reads (see [The services' secrets](#the-services-secrets)
   below). Generated values are once-only with read-back; externally-sourced
   values are shape-validated and never echoed; `NATS_URL` is a constant, so
   this step reads back nothing that step 11's broker would have had to
   create. Two guarded halves in one
   step, so a half-finished step 9 resumes the secrets without touching
   Redis.
10. **The services' database schemas** — one one-shot migrate Job per
    schema-owning service (`identity`, `courier`), in that service's own
    **running image** (read back from the Deployment Argo synced, so there is
    no second pin) and connected as its **OWNER** role (a migration is DDL;
    `<svc>_app` owns nothing). The pod's phase is waited to completion, its
    logs are printed on failure, and the step fails the install naming the
    service and its OWNER DSN — never a pod `Ready` over an empty schema.
    `gateway` (an explicit no-op `bin/migrate`) and `parlor` (no database at
    all) are named in the plan and skipped. Idempotent twice over: the tools'
    version tables make a replay a no-op, and a marker Secret records the
    image whose schema was applied so a re-run does not even launch the pods.
    See [The services' database schemas](#the-services-database-schemas).
11. **NATS with JetStream and the fleet's stream** — one Deployment + Service
    + PVC in `data`, applied from `manifests/data/nats.yaml` with the pinned
    image substituted at apply time, then the one-shot stream init defining
    stream `cafaye` (same subjects, retention, storage and replicas as the
    local `nats-stream-init`; the gate refuses drift). The broker half is
    guarded like every other step; the stream init runs on every install and
    is a no-op when the stream exists (`info || add`), failing the install
    loudly when it does not.
12. **Courier's identity credential** — minted on this box from identity's own
    API (the same four calls the local launch harness makes, over a
    port-forward to the cluster-local Service), and written as a WHOLE PAIR
    into each side: `identity-secrets` gets `COURIER_BASE_URL` +
    `COURIER_TOKEN`, `courier-secrets` gets `COURIER_IDENTITY_URL` +
    `COURIER_IDENTITY_TOKEN`, both deployments restarted. The two tokens are
    one value; each base URL is the peer's in-cluster Service, read from that
    service's chart. identity refuses to boot on half a pair, and courier's
    introspection URL otherwise falls back to the compose spelling — so no
    path writes one key without the other. Nothing crosses a boundary and
    nothing is printed. This is the loop that used to be manual — mint in one
    terminal, paste into a second run — and a mismatch between its two halves
    surfaced as identity's `403`.

Every version is pinned exactly. The pins were verified against the GitHub
releases API on 2026-10-07 and are re-checked by `tests/substrate_test.sh`.

## The ACME solver: HTTP-01 through Traefik

`DEPLOYMENT.md` settles the substrate — Traefik (k3s's default ingress
controller) and cert-manager — but not the challenge solver. The decision
taken here is **HTTP-01, answered by an Ingress cert-manager creates with
`ingressClassName: traefik`**, and the reasons in order of weight:

1. **It needs no credential.** `DEPLOYMENT.md:28` says Cloudflare in front is
   a DNS change, never infrastructure — so the install must not require a
   Cloudflare API token. A token committed to this repository is precisely
   the thing the pull-based deploy loop exists to prevent, and a token the
   operator must paste into a `curl | sh` pipeline is a second secret where
   one already exists.
2. **Traefik is already there.** k3s ships it as the default ingress
   controller, so the HTTP-01 solver has an ingress to answer challenges with
   and adds no component. DNS-01 would mean a second solver deployment and a
   scoped token.
3. **The cost is wildcards, which this product does not need.** HTTP-01
   cannot issue a wildcard certificate. Each service here has its own host, so
   a wildcard is not a capability we are giving up.

**DNS-01 is not implemented**, for reason 1: it cannot work without a DNS
provider's API token, and that token is the one thing this install refuses to
carry. If Cloudflare ever becomes infrastructure rather than a DNS change,
that is the packet that adds a second solver — not a half-built one here.

**Why two issuers.** Let's Encrypt's production limits are 5 duplicate
certificates per week and 5 failed validations per hour. A customer whose DNS
record is wrong on the first install can burn a week of TLS with one afternoon
of debugging. `letsencrypt-staging` is where the mistake is found; the two
issuers are identical but for the ACME directory URL, and their account keys
are distinct because staging and production are separate ACME accounts.

**The names are a contract.** The generated service charts annotate their
Ingresses with `ingress.clusterIssuer: letsencrypt-prod`, and caf's chart
tests use that exact string — an issuer named anything else here is an
annotation pointing at nothing, and every chart's TLS breaks at once.

## The publication half of the loop

The deploy loop this substrate serves is **pull-based**: a commit changes a
chart, Argo makes the box agree. The consume end is the seven `Application`
manifests in `manifests/applications/`, in two halves with different owners:
the four service charts (`identity`, `gateway`, `courier`, `parlor`) pull
their own chart's path in `oci://ghcr.io/cafaye/charts` — e.g.
`oci://ghcr.io/cafaye/charts/identity` — at `targetRevision: 0.1.0`, and the
three observability charts (`alloy`, `grafana`, `prometheus`) pull their
official upstream chart repositories at pinned chart versions (see [The
observability half of the loop](#the-observability-half-of-the-loop)). **The publish end
is kit's `.github/workflows/chart.reusable.yml`**, and a service adopts it by
copying `templates/publish/publish.yml` to `.github/workflows/publish.yml` —
one caller that publishes both the image and the chart.

Three facts about that loop, each load-bearing:

- **The OCI tag is the chart's `version`.** `Chart.yaml`'s `version` is what
  `helm push` tags the artifact with, and it is what the `Application`'s
  `targetRevision` names. The two are the same fact written twice: a chart
  pushed as `0.1.1` while the `Application` says `0.1.0` is a service that
  never deploys, and Argo reports no error — it just never finds the artifact.
  The workflow therefore reads the name and version from `Chart.yaml` and
  refuses when either is empty; neither is an input, because an input is a
  string a service copies into its own repo and a copied string drifts from
  the chart it names.
- **The registry string is one fact in two files.** The workflow's default
  `registry` input is `oci://ghcr.io/cafaye/charts` — the **prefix**, the root
  `helm push` appends the chart's name to. Every `Application` therefore
  carries `source.repoURL: oci://ghcr.io/cafaye/charts/<its chart name>`, and
  the registry root is **not** a valid `repoURL`: Argo resolves an OCI source's
  revision against `repoURL` itself, so the root asks for an artifact named
  after nothing and the sync never finds the chart (measured on the fleet's
  first end-to-end install: `HEAD https://ghcr.io/v2/cafaye/charts/manifests/
  0.1.0` → 403, every service Application un-synced). Both files are in kit,
  which is what makes the seam provable: `check_chart_publish` in kit's gate
  asserts `repoURL == registry + "/" + chart` for every service `Application`
  and fails on a disagreement, with controls that set a `repoURL` back to the
  registry root, make a `repoURL` path disagree with `chart:`, and drift the
  registry — each of which must go red.
- **Publishing is opt-in and refuses forks.** `push` defaults to `false`, so
  a caller that only meant to check the chart still packages it but publishes
  nothing; the job refuses to publish from a `pull_request` regardless of what
  the caller asks, because a fork's token is read-only and publishing from a
  PR is a registry write by untrusted code. The credential is the workflow's
  own `GITHUB_TOKEN` — no PAT, nothing to rotate — and the caller grants
  `packages: write`.

**What is still true:** the service charts themselves do not exist yet. Each service
runs `caf gen chart` and commits `chart/`; until then `targetRevision: 0.1.0`
is a promise, not a published artifact, and the publish workflow has nothing
to push. That is one packet per service, not this one.

## The observability half of the loop

The three observability `Application`s (`alloy`, `grafana`,
`prometheus`) once named the same private OCI registry as the service charts
— for charts nothing in the fleet publishes, so four Applications could never
sync. Per `DEPLOYMENT.md` ("Who owns the `Application`", cited rather than
restated so this file cannot drift from it), the private-OCI shape exists for
**our closed-source service charts** — a customer must be able to pull them
without read access to our repositories. It does not cover third-party
components we do not author and do not modify. The observability three
therefore point at their official upstream chart repositories with a pinned
chart version as `targetRevision` — the standard Argo shape — **shipped
unmodified**:

| Application | `repoURL` | `chart` | `targetRevision` |
|---|---|---|---|
| `alloy` | `https://grafana.github.io/helm-charts` | `alloy` | `1.13.0` |
| `grafana` | `https://grafana.github.io/helm-charts` | `grafana` | `10.5.15` |
| `prometheus` | `https://prometheus-community.github.io/helm-charts` | `prometheus` | `29.36.0` |

Each pin was verified to exist in its upstream repository's `index.yaml`
before it was written. No vendoring, no publish pipeline for charts we do not
own, and the pin keeps "the stack you get on Tuesday is the stack you
reviewed on Monday". Kit's gate states the whole rule over all seven
manifests — every `Application` resolves to either a fleet publication or its
pinned upstream, and anything else fails closed.

## How to run it

```sh
curl https://cafaye.com/box/install | sh
```

or, from a kit checkout:

```sh
export KIT_SUBSTRATE_BOX_ID='<the enrolled uuid of this box>'
export KIT_SUBSTRATE_REGISTRY_CAPABILITY='<cap_… from caf box enroll>'
export KIT_SUBSTRATE_ACME_EMAIL='<your-address>'
export KIT_SUBSTRATE_DATABASES='identity,gateway,courier,parlor'
export KIT_SUBSTRATE_SMTP_HOST='<relay-host>'
export KIT_SUBSTRATE_SMTP_USERNAME='<relay-user>'
export KIT_SUBSTRATE_SMTP_PASSWORD='<relay-password>'
export KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET='<provider-signing-secret>'
# Optional: the public origin a browser reaches. Set it and identity's five
# recovery/invitation mail links are derived from it; leave it unset and the
# box boots with its mail path deliberately off (see below).
export KIT_SUBSTRATE_APP_BASE_URL='https://app.example.com'
bash templates/substrate/install.sh
```

### Shipping the tree to a box from a macOS workstation

The script reads `manifests/` from beside itself, so a box that runs it from a
checkout needs the whole tree there. **A macOS `tar` leaves AppleDouble
sidecars** — `._identity.yaml` beside every Application — and `kubectl apply -f
<dir>` reads dotfiles, which is how a Mac-shipped tree died at step 6:

```
error parsing …/manifests/applications/._identity.yaml:
error converting YAML to JSON: yaml: control characters are not allowed
```

The installer now swallows `._*` and refuses anything else unexpected (see
`install.sh`'s note above `install_applications`), so a sidecar cannot defeat
the install. Ship the tree clean anyway:

```sh
COPYFILE_DISABLE=1 tar --no-xattrs -czf - . | ssh box 'tar xzf -'
rsync -a --exclude '._*' --exclude '.DS_Store' ./ box:/var/lib/cafaye/substrate/
ditto -c -k --norsrc --noextattr . - | ssh box 'ditto -x -k --norsrc - /var/lib/cafaye/substrate'
```

`COPYFILE_DISABLE=1` stops BSD `tar` writing the sidecars and `--no-xattrs`
drops extended attributes; `ditto --norsrc --noextattr` and `rsync`'s
`--exclude` are the equivalents.

`KIT_SUBSTRATE_SMTP_ADAPTER` (default `smtp`) and `KIT_SUBSTRATE_SMTP_PORT`
(default `587`) are validated, not required. `KIT_SUBSTRATE_MAIL_FROM` /
`_NAME` are optional passthroughs — unset stays unwired (a reduced surface,
never a placeholder). Setting `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER` wires
identity's OIDC surface **with a key this box generates itself**; leaving it
unset leaves the surface absent. `KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY`
is an optional passthrough on the same all-or-nothing rule.
`KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY` is an optional override with a
different default: unset means the install **generates** a random 32-byte
base64url-no-padding key on first creation (the exact shape identity's
config parser accepts), so a clean install always boots an identity whose
MFA surface works. A supplied value is validated by shape and refused,
naming the variable, when it is not 43 base64url characters decoding to
32 bytes — a key identity would refuse at boot is refused here instead.

`KIT_SUBSTRATE_APP_BASE_URL` is the public origin a browser reaches — where
identity's recovery and invitation mail links point. It is the one input that
makes identity's mail path **true**, because identity refuses to boot with a
courier base URL and token but no link template
(`internal/config/config.go`, `loadCourier` → `resolveLinkTemplates`: the case is
named *"a base URL and a token with no link template"* → `ErrInvalidCourier`).
When it is set, step 12 derives the five templates from it — `reset-password`,
`verify-email/confirm` (also the honest target for an address change), the
recovery default, and `invitations/{token}` — and writes them **in the same
patch** as `COURIER_BASE_URL` + `COURIER_TOKEN`, so no path can write a token
without its base URL or a base URL without its templates. When it is **unset**,
step 12 writes no identity courier key at all: that is identity's own supported
"no mail path" state (`loadCourier`'s `present == 0` branch), identity boots, and
every recovery route answers `503` rather than a rollout that never goes Ready.
There is **no default** — a localhost or guessed origin would mail a reader to a
screen that is not theirs. A malformed value (not `http(s)://`, or carrying a
query or fragment) is refused by shape, naming the variable, before the mint
does anything. Courier still gets its own required pair
(`COURIER_IDENTITY_URL` + `COURIER_IDENTITY_TOKEN`) either way, because
courier's runtime demands a credential regardless of whether identity sends.

**No long-lived secret is an input to this install.** The registry credential
is redeemed per run from a capability that is single-use, minutes-lived and
bound to the box (invariant 2), which is what makes handing one over harmless.
`KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET` is the ONE long-lived secret an
operator still supplies, because the provider is the only party that can hold
it. Everything else — the eight Postgres role passwords, the Redis password,
`SIGNUP_SIGNING_KEY`, `MFA_ENCRYPTION_KEY`, `SECRET_KEY_BASE`,
`COURIER_SECRET_BOX_KEY`, `COURIER_ERROR_RELAY_TOKEN`, identity's OIDC signing
key, and courier's identity credential — is **born on this box**, stored here,
and never printed.

`KIT_SUBSTRATE_ACME_EMAIL` is the ACME account contact address — the one
Let's Encrypt sends expiry notices to. It is not a secret, but the script
validates its shape (exactly one `@`, not an `example.com` address) and refuses
to run without it, because a refused registration reads as a network error
from the customer's side.

**`DRY_RUN=1`** prints every step and executes nothing:

```sh
DRY_RUN=1 bash templates/substrate/install.sh
```

Note: step 8 validates before its dry-run early-return, so a bare
`DRY_RUN=1` without `KIT_SUBSTRATE_DATABASES` is refused (naming the fix)
rather than planned — the refusal is the contract, and
`tests/substrate_test.sh` asserts it. Courier's SMTP and paired values are
validated on the live path only: a plan does not need credentials to print.
The full plan needs only the database list.

### `--headless` — the mode an agent drives

```sh
bash templates/substrate/install.sh --headless          # or HEADLESS=1
```

`caf box apply --phase N` runs the installer with this flag and reads stdout as
a **stream of JSONL progress events, one object per line, and nothing else**:

```
{"event":"install.start","step":0,"phase":"install","message":"install begins: 13 steps, receipt at /var/lib/kit/substrate-receipt.json"}
{"event":"step.start","step":1,"phase":"k3s","message":"k3s v1.37.1+k3s1 — single node, sqlite datastore","seconds":0.052}
{"event":"step.done","step":1,"phase":"k3s","message":"k3s: 4.180s","seconds":4.180}
{"event":"refusal","step":8,"phase":"cluster-issuers","input_needed":"KIT_SUBSTRATE_ACME_EMAIL","human":"export … on the box and re-run","message":"…"}
```

Interactive mode is unchanged and prints the same plain text, byte for byte,
plus the timing table below.

**Every run reports its own speed, and the numbers are the step's own.** The
installer used to carry no timestamps at all, so "how long did this take, and
which step was the cost" could only be reconstructed from the cluster's
object-creation times — archaeology that says nothing about a cold box or a bad
change. Now:

- **`seconds` on `step.start`** is the step's **offset** since the install
  began, so a reader can see a step start serializing (two steps whose windows
  no longer touch are two steps that stopped overlapping).
- **`seconds` on `step.done`** is the step's **duration**, measured from the
  step's **own** boundary: the guard's `kubectl` probe is excluded (the window
  opens after the guard decides the component is absent) and a **skipped** step
  reports the string `"skipped"`, never `0` — a skipped step did no work, and
  `0` would read as "this step is free".
- **`seconds` on the final `install.done`** is the run's total, and it carries a
  **`steps` array** of `{step, phase, seconds}` — the per-step table, in the
  JSONL. The same table is printed in interactive mode, compactly:

  ```
    step  phase                seconds
    1     k3s                  4.180
    2     cert-manager         10.020
    …
    total                      96.400
  ```

The clock is monotonic: on the box it reads `/proc/uptime`, so an NTP step or a
clock edit does not move it; off Linux the highest-resolution wall clock the
machine has is used, because only differences are ever taken. The measurement
is exercised by `tests/substrate_test.sh`, whose controls require a step with no
timing and a total smaller than its own steps to go red.

**The split between the two writers is the property.** `kit_substrate_emit`
owns stdout — JSONL, headless only. `kit_substrate_out` owns human text — stdout
interactively, **stderr** in headless mode, so the operator (and `caf box logs`)
still reads it while stdout stays machine-parseable. Nothing else in the file
writes to the process stdout; a `printf … | kubectl apply -f -` is a pipe, not a
stdout write, and that is the good path — the credential travels into kubectl,
not into a terminal. `tests/substrate_test.sh` parses every `echo` and `printf`
in `install.sh` and FAILS on one that reaches stdout from anywhere but those two
functions, or that expands a variable holding secret material. **A stdout that
is progress-only is the claim; that check is the proof**, and it holds for code
paths no run reaches.

**The install-receipt file** (`KIT_SUBSTRATE_RECEIPT`, default
`/var/lib/kit/substrate-receipt.json`) is rewritten at every state change:

```json
{
  "phase": "cluster-issuers",
  "status": "refused",
  "step": 7,
  "total_steps": 11,
  "next": "the Let's Encrypt ClusterIssuers …",
  "input_needed": "KIT_SUBSTRATE_ACME_EMAIL",
  "human": "export KIT_SUBSTRATE_ACME_EMAIL='<you@example.com>' on the box and re-run",
  "message": "KIT_SUBSTRATE_ACME_EMAIL is not set",
  "receipt": "/var/lib/kit/substrate-receipt.json",
  "headless": true,
  "dry_run": false,
  "updated_at": "2026-10-09T09:24:03Z"
}
```

A refusal writes a `refusal` event *and* a receipt with `status: "refused"`, the
**input needed** and **where the human goes**. That is the whole point of the
mode: the agent's only touchpoint with a person is the receipt's `human` field,
and every operator-input refusal — the box id, the capability, the ACME email,
the database list, courier's relay settings, the MFA override, a step run out of
order — is routed through it. W5-P4's resumable install reads it; `caf box
apply --phase N` (W2-P6) reads it to know where to resume. It is rewritten on
every state change, so a crashed install leaves one naming where it stopped.
Writing it is best-effort and never stops the install: the receipt is a report,
not a gate.

## The data layer: Postgres, Redis and NATS

`manifests/data/` holds three files, and all three are applied by `install.sh`
(steps 8–11), not by Argo: the Postgres cluster, Redis and NATS are platform state,
not services, and the install already carries that class of component
(cert-manager, CNPG's operator).

**Postgres** is one CNPG `Cluster` (`postgres`, namespace `data`) with one
database and two roles per launch service — the local
`templates/compose/postgres/initdb/10-cluster.sh` contract reproduced through
CNPG's bootstrap: per-service `CREATE DATABASE`, `REVOKE ALL … FROM PUBLIC`
(the isolation), `GRANT CONNECT, TEMPORARY` to both roles, `CONNECTION LIMIT
10` and the two timeouts, and the `GRANT <svc>_app TO <svc>` membership in
its declarative `inRoles` form. `spec.imageName` is unset on purpose: CNPG's
standard image already carries pgvector, so the substrate needs no custom
image and no build step. Storage is explicit (`20Gi` on `local-path`, k3s's
default) and resources are stated as a share of the 8GB box — both numbers
are the box's, not Postgres's. Step 8 proves the labelled pods EXIST before it
waits on their Ready condition, and then waits on that condition rather than on
a Cluster phase string this script does not own. Both halves are needed: the
Cluster CR is applied synchronously, but the pods are created asynchronously by
CNPG's operator, so the selector can match nothing at the instant the apply
returns — and a `kubectl wait` on an empty list is `error: no matching
resources found`, not a wait.

**What the Cluster does NOT reproduce: per-database `CREATE EXTENSION`.**
The local script creates the extension list (compose default: `vector`)
inside every service database as the cluster admin. CNPG's bootstrap hooks
execute in the single initdb database — `postInitSQL` as the superuser
(which cannot reach the other databases from there) and
`postInitApplicationSQL` as the non-superuser app owner (which is *refused*
an untrusted extension, failing the whole bootstrap) — so neither hook can
create extensions per database, and the manifest carries neither. The list
is still declared and validated (`KIT_SUBSTRATE_POSTGRES_EXTENSIONS`,
default `vector`, step 8 refuses a non-identifier), none of the four launch
services reads vector, and a service that needs an extension is a named
follow-up with a box to prove it on. An earlier revision of this manifest
shipped the `postInitApplicationSQL` hook claiming per-database creation;
that claim was false on both counts (wrong user, wrong database) and would
have failed the first real boot.

**Redis** is one Deployment (replicas exactly 1 — a second replica with no
sentinel is a split brain) + Service + PVC at the exact tag
`redis:7.4.1-alpine`, with `--appendonly yes` and the `redis-cli ping`
healthcheck the local stack runs. The password is a `secretKeyRef` to the
generated `redis-password` secret, never a literal `--requirepass`.

**NATS** is one Deployment (replicas exactly 1 — one box, one broker) +
Service + PVC running the broker with `-js` and file storage on the
`nats-data` volume, with `/healthz` probes on the monitor port — the same
signal the local stack's healthcheck uses. The manifest carries
`NATS_IMAGE_PLACEHOLDER` where the tag goes; install.sh step 11 substitutes
the pinned image at apply time, so the pin lives in exactly one place. The
fleet's stream (`cafaye`: `identity.>`, `billing.>`, `courier.>`, `muse.>`,
`darkroom.>` — file storage, `limits` retention, 7d max-age, `old` discard,
1 replica) is defined by step 11's one-shot init, mirroring the local
`nats-stream-init` flag for flag; `tests/substrate_test.sh` parses both
renders and refuses drift.

## The services' database schemas

**Step 10 runs the migrations, and it exists because nothing did.** The
Postgres Cluster (step 8) creates an **empty** database per service; the
Applications (step 6) boot the services against it; the fleet's charts assume a
migrated database because in CI the migrate step is explicit. So a box that
"finished" the substrate booted identity against a schema with no
`outbox_events`, and identity's own logs said so forever:

```
level=ERROR msg="outbox publisher pass failed; retrying"
  error="outbox: claiming a batch: ERROR: relation \"outbox_events\" does not exist (SQLSTATE 42P01)"
```

Step 12's integration probe then caught it from outside — `identity would not
mint a signup timestamp`, a 500 on the missing table.

**The mechanism.** One one-shot Job per schema-owning service, and two facts
are read from the running world rather than restated:

- **The image is the Deployment's own image**, read back from the Deployment
  Argo synced. A migration must come from the same build as the service it
  migrates for, so there is no second pin here to keep in step.
- **The DSN is the OWNER role.** A migration is DDL; the application's
  `<svc>_app` role owns nothing and cannot create a table. The Job connects as
  `postgres-role-<svc>` (the role step 8 provisions and the tool records its
  version table under), while the service keeps connecting as `<svc>_app`.

The pod is run with `--restart=Never`, its phase is watched to `Succeeded`, and
a `Failed` phase prints the pod's logs and **fails the install**, naming the
service and its OWNER DSN. There is no `kubectl exec … migrate || true`, no
sleep, and no "the service migrates at boot" assumed — that last one is
checked, not believed.

**The inventory, which is a finding and not an assumption:**

| service | migrations? | entrypoint | DSN env | notes |
| --- | --- | --- | --- | --- |
| `identity` | yes — `migrations/*.sql`, 35 files | `bin/migrate` (a `psql` loop over the Up sections) | `DATABASE_URL` | **the repository ships the entrypoint; the image does not.** `ghcr.io/cafaye/identity` is `gcr.io/distroless/static-debian12:nonroot` — no shell, no `psql`, no migration files — so it cannot migrate from the image it runs. The service-repo edit is named in `REPORT-roll-c5-migrations.md`. |
| `gateway` | no | `bin/migrate` is an explicit no-op | — | no driver, no pool, no `DATABASE_URL`; the file says so out loud. |
| `courier` | yes — `priv/repo/migrations`, Ecto | `/app/bin/migrate` (release overlay → `courier eval Courier.Release.migrate`) | `COURIER_OWNER_DATABASE_URL` (+ `DATABASE_URL`) | the release eval loads `runtime.exs`, which raises without `DATABASE_URL`, and configures `Courier.OwnerRepo` only from the owner variable — both are passed. |
| `parlor` | no | — | — | a front end: its runtime reads `IDENTITY_URL` / `BILLING_URL` / `OTEL_*`, no database. Its database and roles exist only because the Cluster provisions one per named service. |

**Idempotent twice over.** The migrate tools keep a version table
(`goose_db_version`, `schema_migrations`), so applying an already-applied
migration is a no-op — but a re-run should not even launch the pods. A marker
Secret (`substrate-migrations` in `data`) records, per service, the **image**
whose schema was applied; the guard skips the whole step while every marker
still matches the running Deployment, and a new image re-enters the step and
lets the tool apply what is pending.

**The broker's address reaches the services through their secrets.** The
local compose stack sets `NATS_URL: nats://nats:4222` on every service that
publishes; on the box the address is written into `identity-secrets` instead,
because the generated chart's only env injection is `envFrom: secretRef` — so
this secret IS identity's environment. It is the key that turns identity's
outbox loop on at all: identity builds its NATS publisher only when
`NATS_URL` is set, so without it the local stack publishes and a real box
does not. The address is the broker's **fully qualified** name,
`nats.data.svc.cluster.local`, and not the compose spelling: identity runs in
the `identity` namespace, a query naming no namespace is limited to the
caller's own, and `nats://nats:4222` on a box is a pod that starts and a loop
that connects to nothing. Step 10's own stream-init pod reads the same
constant, so the two writers cannot drift. courier, muse, billing and darkroom
take the same key in their own secrets when their publishers land.

## The services' secrets

One secret per service namespace, each exactly the keys its chart reads —
the generated charts use `envFrom: secretRef`, so every key becomes an
environment variable and the key list IS the service's env list:

| Secret | Keys | Provenance |
|---|---|---|
| `identity-secrets` | `DATABASE_URL`, `SIGNUP_SIGNING_KEY`, `MFA_ENCRYPTION_KEY`, `NATS_URL` (+ `COURIER_TOKEN` written by step 12; `OIDC_ISSUER`, `OIDC_SIGNING_KEY`, `OIDC_SIGNING_KEY_ID`, `OAUTH_ENCRYPTION_KEY` only when the operator sets those surfaces) | first three generated, as is the OIDC signing key when an issuer is set; `COURIER_TOKEN` is the value step 12 minted; the rest from the environment |
| `identity-secrets` | `DATABASE_URL`, `SIGNUP_SIGNING_KEY`, `MFA_ENCRYPTION_KEY`, `NATS_URL`, `COURIER_BASE_URL`, `COURIER_TOKEN` (`OIDC_ISSUER`, `OIDC_SIGNING_KEY`, `OIDC_SIGNING_KEY_ID`, `OAUTH_ENCRYPTION_KEY` only when the operator sets those surfaces) | first three generated, as is the OIDC signing key when an issuer is set; `COURIER_TOKEN` is the value step 11 minted and `COURIER_BASE_URL` is courier's Service, written in the same patch; the rest from the environment |
| `gateway-secrets` | `REDIS_URL` | built from step 9's password |
| `courier-secrets` | `DATABASE_URL`, `SECRET_KEY_BASE`, `COURIER_SECRET_BOX_KEY`, `COURIER_ERROR_RELAY_TOKEN`, `COURIER_IDENTITY_TOKEN`, `COURIER_MAIL_ADAPTER`, `COURIER_SMTP_HOST`, `COURIER_SMTP_PORT`, `COURIER_SMTP_USERNAME`, `COURIER_SMTP_PASSWORD`, `COURIER_INBOUND_RESEND_SECRET` (+ `MAIL_FROM`, `MAIL_FROM_NAME` only when set) | first four generated; `COURIER_IDENTITY_TOKEN` minted on this box in step 12; the rest from the environment |
| `identity-secrets` | `DATABASE_URL`, `SIGNUP_SIGNING_KEY`, `MFA_ENCRYPTION_KEY`, `NATS_URL`, `OTEL_SDK_DISABLED` (+ `COURIER_TOKEN` written by step 11; `OIDC_ISSUER`, `OIDC_SIGNING_KEY`, `OIDC_SIGNING_KEY_ID`, `OAUTH_ENCRYPTION_KEY` only when the operator sets those surfaces) | first three generated, as is the OIDC signing key when an issuer is set; `COURIER_TOKEN` is the value step 11 minted; `OTEL_SDK_DISABLED` is the telemetry kill switch (see below); the rest from the environment |
| `gateway-secrets` | `REDIS_URL`, `ASSERTION_SIGNING_KEY` | `REDIS_URL` built from step 9's password; `ASSERTION_SIGNING_KEY` generated on the box (a PKCS#8 RSA-2048 PEM the chart mounts as `signing.pem`) |
| `courier-secrets` | `DATABASE_URL`, `SECRET_KEY_BASE`, `COURIER_SECRET_BOX_KEY`, `COURIER_ERROR_RELAY_TOKEN`, `COURIER_IDENTITY_TOKEN`, `COURIER_MAIL_ADAPTER`, `COURIER_SMTP_HOST`, `COURIER_SMTP_PORT`, `COURIER_SMTP_USERNAME`, `COURIER_SMTP_PASSWORD`, `COURIER_INBOUND_RESEND_SECRET` (+ `MAIL_FROM`, `MAIL_FROM_NAME` only when set) | first four generated; `COURIER_IDENTITY_TOKEN` minted on this box in step 11; the rest from the environment |
| `courier-secrets` | `DATABASE_URL`, `SECRET_KEY_BASE`, `COURIER_SECRET_BOX_KEY`, `COURIER_ERROR_RELAY_TOKEN`, `COURIER_IDENTITY_TOKEN`, `COURIER_IDENTITY_URL`, `COURIER_MAIL_ADAPTER`, `COURIER_SMTP_HOST`, `COURIER_SMTP_PORT`, `COURIER_SMTP_USERNAME`, `COURIER_SMTP_PASSWORD`, `COURIER_INBOUND_RESEND_SECRET`, `OTEL_SDK_DISABLED` (+ `MAIL_FROM`, `MAIL_FROM_NAME` only when set) | first four generated; `COURIER_IDENTITY_TOKEN` minted on this box in step 11 and `COURIER_IDENTITY_URL` is identity's Service, written in the same patch; `OTEL_SDK_DISABLED` is the telemetry kill switch; the rest from the environment |
| `parlor-secrets` | `DATABASE_URL`, `OTEL_SDK_DISABLED` | generated agreement with the Cluster (parlor's chart names the secret but documents no required keys); `OTEL_SDK_DISABLED` is the telemetry kill switch |

**The services' telemetry is DELIBERATELY OFF on a box, and the switch is
`OTEL_SDK_DISABLED=true`.** The services' compiled default OTLP endpoint is the
*compose* stack's name (`http://otel-collector:4318`, `:4317` for gateway), and
the box deploys no such Service and no OTLP endpoint at all: alloy is pinned at
chart `1.13.0` with no values, so its default config
(`config/example.alloy`) declares no `otelcol.receiver.otlp` and its Service
exposes only `http-metrics` on `12345`, and the substrate ships no Tempo
(`DEPLOYMENT.md`: "Traces | deferred"). Without the switch every service
retries forever and logs a DNS failure every ten seconds. The switch is core's
`otel-endpoint.schema.json` no-op mechanism — free: no queue, no retry, no
warning per export, no dial at boot — written once as `SERVICE_OTEL_DISABLED`
and referenced by identity/courier/parlor's secrets, whose generated charts
`envFrom` them. **gateway is the one exception:** its hand-written chart reads
clear env from a ConfigMap rather than its secret, so its Application carries
the same key/value in `spec.source.helm.values`. When Tempo becomes an
Application this comes out and `<SERVICE>_OTEL_ENDPOINT` goes in, one fact in
one place.

The key lists were enumerated from the code, not guesswork: identity's
`internal/config` + README variable table (`SIGNUP_SIGNING_KEY` is base64url
exactly 32 bytes, an unconditional startup failure when absent);
gateway's `charts/gateway/values.yaml` (`REDIS_URL` as the required
`secretKeyRef`, `ASSERTION_SIGNING_KEY` as the required `volumes.secret` item the
Deployment mounts as `/etc/gateway/assertion/signing.pem`) + `internal/httpapi`
(no `REDIS_URL`, no browser surface);
courier's `chart/values.yaml` (the eight documented keys) +
`config/runtime.exs` (the three mail-adapter settings it refuses to boot
without); parlor's `process.env.*` reads (no secret keys — the secret exists
because the chart's `envFrom` requires it to).

**The split is by provenance.** A random, self-contained value
(`SIGNUP_SIGNING_KEY`, `MFA_ENCRYPTION_KEY`, `SECRET_KEY_BASE`, `COURIER_SECRET_BOX_KEY`,
`COURIER_ERROR_RELAY_TOKEN`, the Redis password, each Postgres role's
password) is **generated on the box, never printed, generated ONCE and read
back on a re-run** — a second `install.sh` never rotates a live system's
keys, and no step overwrites an existing secret (rotation is replace-the-
secret plus restart-the-pods, never re-run-the-install). The MFA override
(`KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY`) is honoured only at creation:
once `identity-secrets` exists its stored key wins over any override, because
the stored key is a persistent encryption key and re-running with a different
value must not fork it. **Minted on this box** — courier's
`COURIER_IDENTITY_TOKEN`, and the same value written into identity's
`COURIER_TOKEN` beside it, both by step 12. **Generated on this box** — the
OIDC signing key and its key id, when an issuer is set (the key is the
customer's own; it is born here, and the id is a thumbprint of the key so a
verifier's cached `kid` keeps matching), and gateway's `ASSERTION_SIGNING_KEY`
(the PKCS#8 RSA-2048 PEM the chart mounts as a file; see below for why a
re-run patches a legacy secret with it). What is left comes **from the
environment, shape-validated and never echoed**: courier's SMTP settings,
the provider's signing secret, and the optional OAuth surface. **`NATS_URL`
is in neither bucket** — it is configuration, not a secret: the broker's
address is not sensitive (the broker carries no credentials on this
substrate, and the stream it reaches holds no customer data), and it is not
operator-supplied either. It rides the secret-shaped slot because the
chart's `envFrom` has no other door, and it is recorded in the SECRET RECORD
as a non-secret key so the tripwire still sees it.
`DATABASE_URL` agrees with the `Cluster` by construction: CNPG's
`postgres-rw.data` service, the service's own database, the `<svc>_app`
login role the local compose files use (`postgres://` for identity and
parlor, `ecto://` for courier — each service's own spelling), and the
password read back from step 8's role secret. `gateway-tls` is NOT created
here — cert-manager fills it from the ClusterIssuer.

**`ASSERTION_SIGNING_KEY` is a mount, and a mount with no key is a pod that
never starts.** gateway's chart points a `volumes.secret` item at
`gateway-secrets`/`ASSERTION_SIGNING_KEY`; a secret without that key leaves the
pod in `ContainerCreating` forever (`FailedMount … references non-existent
secret key`) while every other step reports success. It is generated on the box
and read back on a re-run. A box installed before the key existed holds a
`gateway-secrets` with only `REDIS_URL`, and the `secrets` guard would skip the
whole step on a re-run — so the key is reconciled **above** that guard, by a
merge patch that adds only the missing key (the assertion key is a signing key,
not a persistent encryption key: nothing is sealed under it, so generating one
heals the box rather than forking it). The public half goes to the verifier out
of band.

**Each `postgres-role-<role>` secret carries the ROLE's name in `username`,
not the secret's.** CNPG's managed-role reconciler sets a role's password from
the Secret named in `passwordSecret` only when that Secret's `username` key
equals the **role's** name; when it does not, the operator records the refusal
in the Cluster's `status.managedRolesStatus.cannotReconcile` and leaves
`pg_authid.rolpassword` NULL for that role — which surfaces far from its cause
as `FATAL: password authentication failed … (SQLSTATE 28P01)` in every pod.
The secret is named for the service (`postgres-role-identity-app`, a hyphen)
while the role is `identity_app` (an underscore), so the two spellings are
distinct on purpose and `install.sh` writes the role's. A re-run keeps the
stored password and repairs the `username` key in place, so a box installed
before this fix heals on the next pass without a new password — the role's
password is derived from the Secret, and CNPG re-reconciles when it changes.

**`COURIER_IDENTITY_TOKEN` and identity's `COURIER_TOKEN` must be the SAME
value** — courier's own README says so, and two different keys produce
identity's `403` and courier's `503`, a symptom that reads like a network
fault. It used to be the operator's job to get that right by hand, because
the value was minted outside the box and pasted into a second run. Step 11
does it inside one run: the key is minted on this box from identity's own API
(`POST /v1/accounts/{id}/api-keys`), written into both secrets, and both
deployments are restarted. The guard is the VALUE — a re-run that finds the
credential already minted has nothing to mint.

**Each token is written WITH its base URL, because they are one fact.**
identity's courier block is all-or-nothing: `COURIER_BASE_URL` and
`COURIER_TOKEN` together, or neither (`internal/config/config.go`,
`loadCourier` — a lone token is a refusal to boot, the live defect that
produced this rule). courier's `COURIER_IDENTITY_URL` defaults to
`http://identity:8080` (`config/runtime.exs`), the compose-network spelling,
which does not resolve across the `courier`/`identity` namespace boundary. So
step 11 writes `COURIER_BASE_URL=http://courier.courier.svc.cluster.local:4000`
(courier's chart: Service `courier`, port 4000) beside identity's token, and
`COURIER_IDENTITY_URL=http://identity.identity.svc.cluster.local:8080`
(identity's chart: Service `identity`, port 8080) beside courier's — each in
ONE merge patch, so no path writes half a pair. And `COURIER_ERROR_RELAY_TOKEN` is generated here, but it is a
*shared* secret every service presents to the relay — sibling services do
not read it yet, so wiring them to this value is a named follow-up, not a
second copy of it.

**An install that predates the generated MFA key keeps running unwired,
and the installer will not fix that for you.** A re-run refuses to
overwrite (or patch) an existing `identity-secrets`, so a legacy secret
without `MFA_ENCRYPTION_KEY` stays without it — deliberately, because an
imported database could hold TOTP ciphertext sealed under a key that is no
longer present, and writing a fresh key in would fork it rather than heal
it. The operator path, when the install never carried the key (so no factor
was ever enrolled and no ciphertext exists under it):

```sh
MFA="$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')"
kubectl -n identity get secret identity-secrets -o yaml >identity-secrets.backup.yaml
kubectl -n identity patch secret identity-secrets -p \
  "$(printf '{"stringData":{"MFA_ENCRYPTION_KEY":"%s"}}' "$MFA")"
kubectl -n identity rollout restart deployment/identity  # the chart's deployment name
```

Generate the value with the same spelling the installer uses, back up the
existing secret before touching it, and restart identity's pods afterwards
(the chart reads secrets through `envFrom`, so a patch without a restart
changes nothing). If the database was imported from anywhere that may have
sealed factors under a *different* key, do not invent one — recover that
key instead; a second key does not decrypt the first key's rows.

**The same refusal leaves `NATS_URL` off a pre-existing `identity-secrets`** —
a re-run will not patch a secret that already exists, so an install made
before this key keeps identity's outbox loop dark until an operator adds it.
There is no ciphertext to fork here (the address is configuration, and the
broker it names is fixed by its own Service), so the rotate-by-replacement
path is the cheap one:

```sh
kubectl -n identity get secret identity-secrets -o yaml >identity-secrets.backup.yaml
kubectl -n identity patch secret identity-secrets -p \
  '{"stringData":{"NATS_URL":"nats://nats.data.svc.cluster.local:4222"}}'
kubectl -n identity rollout restart deployment/identity  # the chart's deployment name
```

The SECRET RECORD comment block on `install_secrets` is the drift tripwire:
`tests/substrate_test.sh` parses it and fails if any recorded name is not
created or any recorded key is not set, with a key-removed fixture that must
go red.

## Cross-namespace addresses

**One service, one namespace, and the data plane in `data` — so every
cross-service name a service dials must be qualified.** The substrate puts
`identity`, `gateway`, `courier` and `parlor` each in a namespace of its own and
postgres/redis/nats in `data`. Kubernetes limits a DNS query that names no
namespace to the CALLER's, so the compose spelling — `identity`, `pantry`,
`redis`, `postgres-rw` as bare single labels — resolves only inside a namespace
of that exact name. From gateway's pod, `http://identity:8080` reaches nothing,
gateway boots, and `/readyz` answers `identity: unavailable` forever; the same
defect appears at every peer, and each one is a service that starts and never
becomes Ready.

**Two writers set these addresses, and both were fixed to the same rule.**

| address | who writes it | where |
|---|---|---|
| gateway → identity (`IDENTITY_URL`, `IDENTITY_JWKS_URL`) | the **substrate**, in gateway's Application | `manifests/applications/gateway.yaml` `spec.source.helm.values` |
| parlor → identity (`IDENTITY_URL`) | the **substrate**, in parlor's Application | `manifests/applications/parlor.yaml` `spec.source.helm.values` |
| gateway → redis (`REDIS_URL`) | the installer | `gateway-secrets`, built from step 9's password |
| identity → courier (`COURIER_BASE_URL`), identity → nats (`NATS_URL`) | the installer | `identity-secrets` |
| courier → identity (`COURIER_IDENTITY_URL`) | the installer | `courier-secrets` (step 12, with the token) |
| identity/courier/parlor → postgres (`DATABASE_URL`) | the installer | each service's secret |

**The substrate owns the topology, so the Applications carry the box's
topology.** gateway's and parlor's charts read their clear env from
`.Values.env` (gateway through a ConfigMap, parlor through the Deployment's
`env:`), and their defaults are the COMPOSE spelling — correct for the flat
stack they were generated for, wrong for the box. The override lives in the
Application (`spec.source.helm.values`), the file the substrate already owns, so
no chart learns a namespace it cannot know: gateway gets
`http://identity.identity.svc.cluster.local:8080` and parlor the same, and the
installer's own addresses (already fully qualified) agree with them. `helm`
merges maps, so each Application **adds** keys to the chart's `env:` rather than
replacing the ones it does not mention.

**`IDENTITY_JWKS_URL` is set because the issuer's origin is public and the key
set is not.** gateway verifies tokens against the public issuer
(`IDENTITY_ISSUER`, the `iss` identity mints) but fetches the key set from
identity's in-cluster Service, so verification does not depend on the box's
public DNS or a hairpin through its own edge; gateway's runtime documents this
exact split ("an explicit key set, when identity publishes it elsewhere"), and
resolving it once keeps `/readyz` and the verifier asking the same URL.

**The issue/verify pair is an operator fact, and it is reported rather than
guessed.** `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER` has **no default**: unset means
identity serves no OIDC surface at all. gateway's chart default is the fleet's
production origin, `https://auth.cafaye.com`. A box that sets the installer's
issuer must set the **same** origin as gateway's `IDENTITY_ISSUER` — otherwise
identity mints `iss` the gateway will not accept — so the two are the same fact
spelled in two places and are set together. `IDENTITY_ISSUER` is deliberately
**not** fixed in gateway's Application: it is the customer's own public domain,
which a static manifest cannot hold. See `REPORT-roll-c5-crossns.md` for the
measured pair and the exact commands.

**`BILLING_URL` and gateway's `ROUTE_TABLE` are deliberately out of scope.**
parlor treats an unset `BILLING_URL` as the supported "no billing deployed"
state, and gateway's `ROUTE_TABLE` points at `pantry` — a service the substrate
does not ship. The substrate may only name Services its own manifests create
(that is what `tests/substrate_test.sh` §24 asserts), so a box that deploys
pantry or billing writes those addresses in its **values commit**, the
pull-based loop's documented write path, not here.

`tests/substrate_test.sh` §24 is the check: every cross-service address the
Applications set, and every `.svc.cluster.local` name `install.sh` writes, must
parse as `<svc>.<ns>.svc.cluster.local` and name a Service the manifests ship
in the namespace they ship it in — with red controls for a bare name, a name in
the wrong namespace, a name no manifest ships, a service that loses its
address, and a drifted name in the installer.

## The install host: `cafaye.com/box/install`

`install.sh` is served at `https://cafaye.com/box/install` by
`kit-install.mjs`, a Cloudflare Worker in this directory — the fleet's
established mechanism (`site` and `parlor` are Workers). The Worker serves
the **exact bytes** of `install.sh` with `content-type: text/x-shellscript`
and no transformation: `curl | sh` executes whatever bytes arrive, so a
Worker that reformats, wraps or minifies the script is a Worker that
breaks the install. Every other path 404s, including traversal, and
`GET /healthz` is 200 so the host itself is observable.

The script is **imported, not copied**: `wrangler.jsonc`'s Text-module rule
bundles `install.sh`'s bytes into the Worker at deploy time, so the served
bytes and this file are one fact with one author — there is no hand-copied
second copy of the script in this tree. `check_install_host` in kit's gate
proves the equality offline, with no wrangler, no network and no account:
it imports the Worker's handler as a plain module and compares the served
body's SHA-256 against the file's — not a prefix, so a truncated or
re-encoded body reds — with a control that truncates one byte and must go
red. The Worker holds no secret: `install.sh` reads the box id and the
capability from the operator's environment at run time, and everything else
it needs it generates itself.

**The operator step (an action, not a file):** publish the Worker
(`wrangler deploy` from this directory) and bind the route
`cafaye.com/box/install` to `kit-install` — a Cloudflare route / custom
domain, the same way `cafaye.com` is bound to `site` today. The Worker
itself is hostname-agnostic: it serves `/box/install` under whatever host it
is reached on, so the plan's path and the host binding are two separate
moves and only the second one is the operator's. Measured:
`site/wrangler.jsonc` carries no `routes` block, so the binding is done
outside the repositories and **cannot be asserted from this repository** —
which is why `wrangler.jsonc` does not invent one.

**What is not proven here:** that `https://cafaye.com/box/install` answers.
The Worker, its config and the byte-equality are proven; binding the route
is an operator action, and the URL works only when observed.

## What is proven, and what is not

**Proven, on any machine, by `tests/substrate_test.sh`:**

- `install.sh` parses (`bash -n`) and is shellcheck-clean.
- `DRY_RUN=1` runs to completion with the database list set,
  printing the thirteen steps in order, each with an action.
- `KIT_SUBSTRATE_DATABASES` unset, empty, or disagreeing with the Cluster
  manifest is refused in DRY_RUN, naming the fix — with the matching list
  accepted as the control.
- **Every manifest directory is read deliberately.** Step 6 applies the
  `*.yaml` manifests it resolves, ignores AppleDouble `._*` sidecars (and names
  them in the output), and refuses any other entry by name; the `tls/` and
  `data/` sites route through the same check. A tree carrying `._identity.yaml`
  applies cleanly, a stray non-sidecar YAML goes **red** naming the file, and a
  fixture with the glob filter removed hands the sidecar to kubectl and breaks
  the apply again (**red**) — so the filter is proven load-bearing.
- The Cluster manifest names one cluster (`data/postgres`) and carries the
  per-role provisioning (`REVOKE … FROM PUBLIC`, the `inRoles` membership,
  the connection limit, the timeouts, no `imageName`, and pointedly no
  `postInitApplicationSQL` — a fixture with the `REVOKE` removed goes
  **red** under the same check, as does a manifest re-adding the hook).
- **Every field the manifests write under `spec` is declared by the CRD the
  operator ships.** `tests/substrate-crd/schemas.json` is the property graph of
  the pinned CNPG v1.30.1, Argo CD v3.5.4 and cert-manager v1.21.2 CRDs,
  derived from the same release URLs `install.sh` applies, and
  `tests/substrate_test.sh` §9b refuses a field name the pinned version does not
  declare at that path. The `storageConfiguration` name the box refused goes
  **red**, as does a nested retired spelling (`storageClassName`) and a pin bump
  with no re-derivation. This is the class the Cluster defect belonged to; it
  proves field NAMES, not types or semantics. A CRD with no model fails closed.
- The extension list defaults to `vector` and is validated as identifiers in
  `install.sh` — a fixture with no default goes **red**.
- The Redis manifest parses with the exact tag `redis:7.4.1-alpine` and the
  password by `secretKeyRef` only — a floating-tag fixture goes **red**.
- The NATS manifest carries one Deployment + Service + PVC with `-js` file
  storage and monitor-port probes, its image the `NATS_IMAGE_PLACEHOLDER`
  `install.sh` substitutes — fixtures without `-js` or floating on `latest`
  go **red** — and step 11 defines stream `cafaye` idempotently
  (`info || add`) with the local stack's subject set and flags, while the
  drift check parses both renders and refuses divergence (a fixture missing a
  publisher, or with a drifted `max-age`, goes **red**).
- The recorded secret name-and-key list matches what `install.sh` creates —
  a fixture with a key removed goes **red** either way (and an unrecorded
  key the other way) — and no operator value is ever echoed.
- **No long-lived secret is an input**, and every value that replaced one is
  proven: the retired variable names do not appear in the installer's code
  (comments stripped, the same strip the record check uses — a comment naming
  a retired value is the record of the change, and a comment cannot read a
  variable); the capability is validated by shape before any network call, so
  a pasted dockerconfigjson is refused rather than sent as a bearer; the
  redeemed dockerconfigjson reaches the cluster as a dockerconfigjson Secret
  in all six namespaces — each namespace made by the step, and made BEFORE the
  secret that goes into it — and the capability and the credential are both absent
  from the output; identity's OIDC signing key is a 2048-bit RSA PEM with a
  `box-`-plus-16-hex key id, generated on the box, distinct on a second box,
  never regenerated on a re-run, and absent from the output; and step 12's
  mint writes ONE value into both secret halves, restarts both deployments,
  and leaves that value out of the output. Every one of the no-print claims
  has a control that plants the value in a log and must go **red**.
- `identity-secrets` always carries `MFA_ENCRYPTION_KEY`: first creation
  generates a random 32-byte base64url-no-padding key (the exact shape
  identity's config parser accepts, proven by decoding it in the test), a
  valid `KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY` override is stored
  exactly, an invalid override is refused naming the variable with no secret
  written, reruns never rotate the stored value even under a different
  override, two fresh installs generate distinct keys, and a legacy
  `identity-secrets` without the key is left unpatched — proven locally by
  running `install_service_secrets` against a file-backed mocked kubectl
  (no k3s, no box), each case with red-first controls.
- Every pin is exact — a fixture with a `latest` or floating pin goes **red**
  under the same check that the real tree passes.
- Every `Application` manifest parses and carries the fields Argo needs
  (`spec.source`, `spec.destination`).
- The two `ClusterIssuer` manifests are staging and production, distinct in
  server URL and account key, with the email still the placeholder — fixtures
  with a shared key or an empty solver list go **red** under the same check.
- No image floats on `latest` anywhere in this tree.
- No secret is a literal in this tree.
- The install host serves the exact bytes of `install.sh` at `GET /` and
  `GET /install.sh` (SHA-256, not a prefix), 404s every other path
  including traversal, and answers `/healthz` — proven by
  `check_install_host` in kit's gate, with a one-byte-shorter control that
  must go red.

**NOT proven here — it needs a customer box:**

- That k3s actually installs and the node becomes Ready.
- That cert-manager, CloudNativePG and Argo CD core actually come up.
- That the pull secret is accepted by GHCR.
- That Let's Encrypt actually issues — the issuers are applied and the
  challenges are solved on a customer box with real DNS. Whether the first
  certificate lands is a box-level claim, not a property of these manifests.
- That the Applications actually sync — **the service charts they point at do not
  exist yet.** `caf gen chart` (m72) generates them; until then the service
  `targetRevision: 0.1.0` is a promise, not a published artifact. The
  publish path that would push them now exists (kit's `chart.reusable.yml`,
  see [The publication half of the loop](#the-publication-half-of-the-loop));
  the charts themselves are one packet per service. The observability three,
  by contrast, resolve to pinned upstream charts (see [The observability half
  of the loop](#the-observability-half-of-the-loop)) — what remains unproven
  for them is the live sync and retention on a customer box, below.
- That the observability stack (Alloy, Grafana, Prometheus) actually
  deploys and retains.
- That the Postgres Cluster ever reaches Ready, that Redis answers, or that
  any service secret decrypts into a working boot. What is proven is **a
  checked script and a set of manifests — not a running cluster**: the install
  needs root, a Linux kernel and a reachable registry, none of which this
  machine (or any development machine) is. The `DATABASE_URL`↔Cluster
  agreement, the once-only generation and the refusal paths are all asserted
  without a box; the live boot is a customer-box claim.
- That `https://cafaye.com/box/install` answers. The Worker, its config and
  the byte-equality are proven; binding the route to the Worker is a
  Cloudflare route/custom-domain action outside every repository, so the URL
  works only when observed.

This machine is macOS. It cannot run k3s, so `install.sh` has never been
executed here. The proof is `DRY_RUN=1` plus the checks above. **A claim you
cannot exercise is written as unexercised, not as done** — and every claim in
this paragraph is unexercised.

## What a customer box must still prove

The first real run, on a Linux box with 8GB or more:

1. `curl https://cafaye.com/box/install | sh` completes all ten steps.
2. `kubectl get nodes` shows the node Ready.
3. `kubectl get applications -n argocd` shows all seven Applications synced.
4. The observability stack is reachable and retaining.

Until those four are observed on real hardware, the substrate is a checked
script and a set of manifests — not a running cluster.
