# templates/substrate — the customer install

**One command, one box.** `curl https://kit.cafaye.com | sh` installs the
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
| `manifests/applications/` | The Argo CD `Application` manifests: the four launch services (identity, gateway, courier, parlor) and the observability set (Alloy, Loki, Grafana, Prometheus). |
| `manifests/tls/` | The two Let's Encrypt `ClusterIssuer` manifests — staging and production, HTTP-01 through Traefik. |
| `manifests/data/` | The data layer, applied by `install.sh` (not by Argo): `postgres-cluster.yaml` — the CNPG `Cluster` reproducing the local `10-cluster.sh` contract — `redis.yaml` — one Deployment + Service + PVC — and `nats.yaml` — one Deployment + Service + PVC running NATS with JetStream, the bus the local stack runs. |

## What `install.sh` does

1. **k3s** — single node, sqlite datastore. No etcd on one box.
2. **cert-manager**
3. **CloudNativePG**
4. **Argo CD core** — no Dex, no SSO, no Redis HA.
5. **The GHCR image pull secret** — **redeemed, not supplied.** The box presents
   its own capability (`KIT_SUBSTRATE_REGISTRY_CAPABILITY`, single-use,
   minutes-lived, bound to `KIT_SUBSTRATE_BOX_ID`) and receives ONE short-lived
   dockerconfigjson, held in a shell variable and applied through a pipe. No
   long-lived registry credential is handed over, and nothing reaches disk,
   argv or stdout. Re-running re-redeems, because a credential with minutes of
   life is supposed to be replaced.
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
   values are shape-validated and never echoed. Two guarded halves in one
   step, so a half-finished step 9 resumes the secrets without touching
   Redis.
10. **NATS with JetStream and the fleet's stream** — one Deployment + Service
    + PVC in `data`, applied from `manifests/data/nats.yaml` with the pinned
    image substituted at apply time, then the one-shot stream init defining
    stream `cafaye` (same subjects, retention, storage and replicas as the
    local `nats-stream-init`; the gate refuses drift). The broker half is
    guarded like every other step; the stream init runs on every install and
    is a no-op when the stream exists (`info || add`), failing the install
    loudly when it does not.
11. **Courier's identity credential** — minted on this box from identity's own
    API (the same four calls the local launch harness makes, over a
    port-forward to the cluster-local Service), written as ONE value into both
    `identity-secrets` (`COURIER_TOKEN`) and `courier-secrets`
    (`COURIER_IDENTITY_TOKEN`), and both deployments restarted. Nothing
    crosses a boundary and nothing is printed. This is the loop that used to
    be manual — mint in one terminal, paste into a second run — and a mismatch
    between its two halves surfaced as identity's `403`.

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
chart, Argo makes the box agree. The consume end is the eight `Application`
manifests in `manifests/applications/`, in two halves with different owners:
the four service charts (`identity`, `gateway`, `courier`, `parlor`) pull
`oci://ghcr.io/cafaye/charts` at `targetRevision: 0.1.0`, and the four
observability charts (`alloy`, `grafana`, `loki`, `prometheus`) pull their
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
  `registry` input is `oci://ghcr.io/cafaye/charts`, the exact string every
  `Application` carries as `source.repoURL`. Both files are in kit, which is
  what makes the seam provable: `check_chart_publish` in kit's gate compares
  them and fails on a disagreement, with a control that drifts one
  `repoURL` and must go red.
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

The four observability `Application`s (`alloy`, `grafana`, `loki`,
`prometheus`) once named the same private OCI registry as the service charts
— for charts nothing in the fleet publishes, so four Applications could never
sync. Per `DEPLOYMENT.md` ("Who owns the `Application`", cited rather than
restated so this file cannot drift from it), the private-OCI shape exists for
**our closed-source service charts** — a customer must be able to pull them
without read access to our repositories. It does not cover third-party
components we do not author and do not modify. The observability four
therefore point at their official upstream chart repositories with a pinned
chart version as `targetRevision` — the standard Argo shape — **shipped
unmodified**:

| Application | `repoURL` | `chart` | `targetRevision` |
|---|---|---|---|
| `alloy` | `https://grafana.github.io/helm-charts` | `alloy` | `1.13.0` |
| `grafana` | `https://grafana.github.io/helm-charts` | `grafana` | `10.5.15` |
| `loki` | `https://grafana.github.io/helm-charts` | `loki` | `7.3.0` |
| `prometheus` | `https://prometheus-community.github.io/helm-charts` | `prometheus` | `29.36.0` |

Each pin was verified to exist in its upstream repository's `index.yaml`
before it was written. No vendoring, no publish pipeline for charts we do not
own, and the pin keeps "the stack you get on Tuesday is the stack you
reviewed on Monday". Kit's gate states the whole rule over all eight
manifests — every `Application` resolves to either a fleet publication or its
pinned upstream, and anything else fails closed.

## How to run it

```sh
curl https://kit.cafaye.com | sh
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
bash templates/substrate/install.sh
```

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

## The data layer: Postgres, Redis and NATS

`manifests/data/` holds three files, and all three are applied by `install.sh`
(steps 8–10), not by Argo: the Postgres cluster, Redis and NATS are platform state,
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
are the box's, not Postgres's. Step 8 waits on the labelled pods' Ready
condition, not on a Cluster phase string this script does not own.

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
`NATS_IMAGE_PLACEHOLDER` where the tag goes; install.sh step 10 substitutes
the pinned image at apply time, so the pin lives in exactly one place. The
fleet's stream (`cafaye`: `identity.>`, `billing.>`, `courier.>`, `muse.>`,
`darkroom.>` — file storage, `limits` retention, 7d max-age, `old` discard,
1 replica) is defined by step 10's one-shot init, mirroring the local
`nats-stream-init` flag for flag; `tests/substrate_test.sh` parses both
renders and refuses drift.

## The services' secrets

One secret per service namespace, each exactly the keys its chart reads —
the generated charts use `envFrom: secretRef`, so every key becomes an
environment variable and the key list IS the service's env list:

| Secret | Keys | Provenance |
|---|---|---|
| `identity-secrets` | `DATABASE_URL`, `SIGNUP_SIGNING_KEY`, `MFA_ENCRYPTION_KEY` (+ `COURIER_TOKEN` written by step 11; `OIDC_ISSUER`, `OIDC_SIGNING_KEY`, `OIDC_SIGNING_KEY_ID`, `OAUTH_ENCRYPTION_KEY` only when the operator sets those surfaces) | first three generated, as is the OIDC signing key when an issuer is set; `COURIER_TOKEN` is the value step 11 minted; the rest from the environment |
| `gateway-secrets` | `REDIS_URL` | built from step 9's password |
| `courier-secrets` | `DATABASE_URL`, `SECRET_KEY_BASE`, `COURIER_SECRET_BOX_KEY`, `COURIER_ERROR_RELAY_TOKEN`, `COURIER_IDENTITY_TOKEN`, `COURIER_MAIL_ADAPTER`, `COURIER_SMTP_HOST`, `COURIER_SMTP_PORT`, `COURIER_SMTP_USERNAME`, `COURIER_SMTP_PASSWORD`, `COURIER_INBOUND_RESEND_SECRET` (+ `MAIL_FROM`, `MAIL_FROM_NAME` only when set) | first four generated; `COURIER_IDENTITY_TOKEN` minted on this box in step 11; the rest from the environment |
| `parlor-secrets` | `DATABASE_URL` | generated agreement with the Cluster (parlor's chart names the secret but documents no required keys) |

The key lists were enumerated from the code, not guesswork: identity's
`internal/config` + README variable table (`SIGNUP_SIGNING_KEY` is base64url
exactly 32 bytes, an unconditional startup failure when absent);
gateway's `charts/gateway/values.yaml` (`REDIS_URL` as the one required
`secretKeyRef`) + `internal/httpapi` (no `REDIS_URL`, no browser surface);
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
`COURIER_TOKEN` beside it, both by step 11. **Generated on this box** — the
OIDC signing key and its key id, when an issuer is set (the key is the
customer's own; it is born here, and the id is a thumbprint of the key so a
verifier's cached `kid` keeps matching). What is left comes **from the
environment, shape-validated and never echoed**: courier's SMTP settings,
the provider's signing secret, and the optional OAuth surface. `DATABASE_URL` agrees with the `Cluster` by construction: CNPG's
`postgres-rw.data` service, the service's own database, the `<svc>_app`
login role the local compose files use (`postgres://` for identity and
parlor, `ecto://` for courier — each service's own spelling), and the
password read back from step 8's role secret. `gateway-tls` is NOT created
here — cert-manager fills it from the ClusterIssuer.

**`COURIER_IDENTITY_TOKEN` and identity's `COURIER_TOKEN` must be the SAME
value** — courier's own README says so, and two different keys produce
identity's `403` and courier's `503`, a symptom that reads like a network
fault. It used to be the operator's job to get that right by hand, because
the value was minted outside the box and pasted into a second run. Step 11
does it inside one run: the key is minted on this box from identity's own API
(`POST /v1/accounts/{id}/api-keys`), written into both secrets, and both
deployments are restarted. The guard is the VALUE — a re-run that finds the
credential already minted has nothing to mint. And `COURIER_ERROR_RELAY_TOKEN` is generated here, but it is a
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

The SECRET RECORD comment block on `install_secrets` is the drift tripwire:
`tests/substrate_test.sh` parses it and fails if any recorded name is not
created or any recorded key is not set, with a key-removed fixture that must
go red.

## The install host: `kit.cafaye.com`

`install.sh` is served at `https://kit.cafaye.com/` (and `/install.sh`) by
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
(`wrangler deploy` from this directory) and bind `kit.cafaye.com` to it —
a Cloudflare route / custom domain on `kit-install`, the same way
`cafaye.com` is bound to `site` today. Measured: `site/wrangler.jsonc`
carries no `routes` block, so the binding is done outside the repositories
and **cannot be asserted from this repository** — which is why
`wrangler.jsonc` does not invent one.

**What is not proven here:** that `https://kit.cafaye.com` answers. The
Worker, its config and the byte-equality are proven; the binding is an
operator action, and the URL works only when observed.

## What is proven, and what is not

**Proven, on any machine, by `tests/substrate_test.sh`:**

- `install.sh` parses (`bash -n`) and is shellcheck-clean.
- `DRY_RUN=1` runs to completion with the database list set,
  printing the eleven steps in order, each with an action.
- `KIT_SUBSTRATE_DATABASES` unset, empty, or disagreeing with the Cluster
  manifest is refused in DRY_RUN, naming the fix — with the matching list
  accepted as the control.
- The Cluster manifest names one cluster (`data/postgres`) and carries the
  per-role provisioning (`REVOKE … FROM PUBLIC`, the `inRoles` membership,
  the connection limit, the timeouts, no `imageName`, and pointedly no
  `postInitApplicationSQL` — a fixture with the `REVOKE` removed goes
  **red** under the same check, as does a manifest re-adding the hook).
- The extension list defaults to `vector` and is validated as identifiers in
  `install.sh` — a fixture with no default goes **red**.
- The Redis manifest parses with the exact tag `redis:7.4.1-alpine` and the
  password by `secretKeyRef` only — a floating-tag fixture goes **red**.
- The NATS manifest carries one Deployment + Service + PVC with `-js` file
  storage and monitor-port probes, its image the `NATS_IMAGE_PLACEHOLDER`
  `install.sh` substitutes — fixtures without `-js` or floating on `latest`
  go **red** — and step 10 defines stream `cafaye` idempotently
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
  in all six namespaces and the capability and the credential are both absent
  from the output; identity's OIDC signing key is a 2048-bit RSA PEM with a
  `box-`-plus-16-hex key id, generated on the box, distinct on a second box,
  never regenerated on a re-run, and absent from the output; and step 11's
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
  the charts themselves are one packet per service. The observability four,
  by contrast, resolve to pinned upstream charts (see [The observability half
  of the loop](#the-observability-half-of-the-loop)) — what remains unproven
  for them is the live sync and retention on a customer box, below.
- That the observability stack (Alloy, Loki, Grafana, Prometheus) actually
  deploys and retains.
- That the Postgres Cluster ever reaches Ready, that Redis answers, or that
  any service secret decrypts into a working boot. What is proven is **a
  checked script and a set of manifests — not a running cluster**: the install
  needs root, a Linux kernel and a reachable registry, none of which this
  machine (or any development machine) is. The `DATABASE_URL`↔Cluster
  agreement, the once-only generation and the refusal paths are all asserted
  without a box; the live boot is a customer-box claim.
- That `https://kit.cafaye.com` answers. The Worker, its config and the
  byte-equality are proven; binding the host to the Worker is a Cloudflare
  route/custom-domain action outside every repository, so the URL works
  only when observed.

This machine is macOS. It cannot run k3s, so `install.sh` has never been
executed here. The proof is `DRY_RUN=1` plus the checks above. **A claim you
cannot exercise is written as unexercised, not as done** — and every claim in
this paragraph is unexercised.

## What a customer box must still prove

The first real run, on a Linux box with 8GB or more:

1. `curl https://kit.cafaye.com | sh` completes all ten steps.
2. `kubectl get nodes` shows the node Ready.
3. `kubectl get applications -n argocd` shows all eight Applications synced.
4. The observability stack is reachable and retaining.

Until those four are observed on real hardware, the substrate is a checked
script and a set of manifests — not a running cluster.
