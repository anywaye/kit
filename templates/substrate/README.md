# templates/substrate — the customer install

**One command, one box.** `curl https://kit.cafaye.com | sh` installs the
customer substrate: k3s → cert-manager → CloudNativePG → Argo CD core →
image pull secret → the first Applications sync.

The decisions are in [`DEPLOYMENT.md`](../../../DEPLOYMENT.md). This directory
is the executable half of that decision record. Read the decision record first;
this file only describes what is here and what is proven.

## What is in this directory

| Path | What it is |
|---|---|
| `install.sh` | The one command. Installs the substrate in order, idempotently, failing loudly and early. |
| `manifests/applications/` | The Argo CD `Application` manifests: the four launch services (identity, gateway, courier, parlor) and the observability set (Alloy, Loki, Grafana, Prometheus). |

## What `install.sh` does

1. **k3s** — single node, sqlite datastore. No etcd on one box.
2. **cert-manager**
3. **CloudNativePG**
4. **Argo CD core** — no Dex, no SSO, no Redis HA.
5. **The GHCR image pull secret** — created from `KIT_SUBSTRATE_PULL_SECRET`,
   a value the operator supplies. Never a literal in the repo, never echoed.
6. **The first Applications** — applied from `manifests/applications/`, so Argo
   starts syncing.

Every version is pinned exactly. The pins were verified against the GitHub
releases API on 2026-10-07 and are re-checked by `tests/substrate_test.sh`.

## How to run it

```sh
curl https://kit.cafaye.com | sh
```

or, from a kit checkout:

```sh
export KIT_SUBSTRATE_PULL_SECRET='<base64 dockerconfigjson>'
bash templates/substrate/install.sh
```

**`DRY_RUN=1`** prints every step and executes nothing:

```sh
DRY_RUN=1 bash templates/substrate/install.sh
```

## What is proven, and what is not

**Proven, on any machine, by `tests/substrate_test.sh`:**

- `install.sh` parses (`bash -n`) and is shellcheck-clean.
- `DRY_RUN=1` runs to completion, printing the six steps in order.
- Every pin is exact — a fixture with a `latest` or floating pin goes **red**
  under the same check that the real tree passes.
- Every `Application` manifest parses and carries the fields Argo needs
  (`spec.source`, `spec.destination`).
- No image floats on `latest` anywhere in this tree.
- No secret is a literal in this tree.

**NOT proven here — it needs a customer box:**

- That k3s actually installs and the node becomes Ready.
- That cert-manager, CloudNativePG and Argo CD core actually come up.
- That the pull secret is accepted by GHCR.
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

1. `curl https://kit.cafaye.com | sh` completes all six steps.
2. `kubectl get nodes` shows the node Ready.
3. `kubectl get applications -n argocd` shows all eight Applications synced.
4. The observability stack is reachable and retaining.

Until those four are observed on real hardware, the substrate is a checked
script and a set of manifests — not a running cluster.
