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

## What `install.sh` does

1. **k3s** — single node, sqlite datastore. No etcd on one box.
2. **cert-manager**
3. **CloudNativePG**
4. **Argo CD core** — no Dex, no SSO, no Redis HA.
5. **The GHCR image pull secret** — created from `KIT_SUBSTRATE_PULL_SECRET`,
   a value the operator supplies. Never a literal in the repo, never echoed.
6. **The first Applications** — applied from `manifests/applications/`, so Argo
   starts syncing.
7. **The Let's Encrypt ClusterIssuers** — `letsencrypt-staging` and
   `letsencrypt-prod`, applied from `manifests/tls/` with the operator's
   `KIT_SUBSTRATE_ACME_EMAIL` substituted into a pipe at apply time. Never a
   literal in the repo, never written to disk, never printed.

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
manifests in `manifests/applications/`, each pulling
`oci://ghcr.io/cafaye/charts` at `targetRevision: 0.1.0`. **The publish end
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

**What is still true:** the charts themselves do not exist yet. Each service
runs `caf gen chart` and commits `chart/`; until then `targetRevision: 0.1.0`
is a promise, not a published artifact, and the publish workflow has nothing
to push. That is one packet per service, not this one.

## How to run it

```sh
curl https://kit.cafaye.com | sh
```

or, from a kit checkout:

```sh
export KIT_SUBSTRATE_PULL_SECRET='<base64 dockerconfigjson>'
export KIT_SUBSTRATE_ACME_EMAIL='<your-address>'
bash templates/substrate/install.sh
```

`KIT_SUBSTRATE_ACME_EMAIL` is the ACME account contact address — the one
Let's Encrypt sends expiry notices to. It is not a secret, but the script
validates its shape (exactly one `@`, not an `example.com` address) and refuses
to run without it, because a refused registration reads as a network error
from the customer's side.

**`DRY_RUN=1`** prints every step and executes nothing:

```sh
DRY_RUN=1 bash templates/substrate/install.sh
```

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
red. The Worker holds no secret: `install.sh` reads
`KIT_SUBSTRATE_PULL_SECRET` and `KIT_SUBSTRATE_ACME_EMAIL` from the
operator's environment at run time.

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
- `DRY_RUN=1` runs to completion, printing the seven steps in order.
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
- That the Applications actually sync — **the charts they point at do not
  exist yet.** `caf gen chart` (m72) generates them; until then the
  `targetRevision: 0.1.0` is a promise, not a published artifact. The
  publish path that would push them now exists (kit's `chart.reusable.yml`,
  see [The publication half of the loop](#the-publication-half-of-the-loop));
  the charts themselves are one packet per service.
- That the observability stack (Alloy, Loki, Grafana, Prometheus) actually
  deploys and retains.
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

1. `curl https://kit.cafaye.com | sh` completes all seven steps.
2. `kubectl get nodes` shows the node Ready.
3. `kubectl get applications -n argocd` shows all eight Applications synced.
4. The observability stack is reachable and retaining.

Until those four are observed on real hardware, the substrate is a checked
script and a set of manifests — not a running cluster.
