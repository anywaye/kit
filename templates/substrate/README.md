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

**NOT proven here — it needs a customer box:**

- That k3s actually installs and the node becomes Ready.
- That cert-manager, CloudNativePG and Argo CD core actually come up.
- That the pull secret is accepted by GHCR.
- That Let's Encrypt actually issues — the issuers are applied and the
  challenges are solved on a customer box with real DNS. Whether the first
  certificate lands is a box-level claim, not a property of these manifests.
- That the Applications actually sync — **the charts they point at do not
  exist yet.** `caf gen chart` (m72) generates them; until then the
  `targetRevision: 0.1.0` is a promise, not a published artifact.
- That the observability stack (Alloy, Loki, Grafana, Prometheus) actually
  deploys and retains.

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
