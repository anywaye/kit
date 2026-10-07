# REPORT — kit-w74-substrate: the customer substrate

**Base commit:** `7726561` (Merge worker/kit-w54-deploy)
**Worktree:** `/Users/kaka/Code/any/wt/kit-w74-substrate`, branch `worker/kit-w74-substrate`
**Commit:** `bae2a06` — the substrate, the Applications, and the proof
**Previous attempt:** none recoverable — `git status` was clean at dispatch.

## What landed

`templates/substrate/` — the executable half of `DEPLOYMENT.md`:

- **`install.sh`** — the one command. Installs, in order: k3s (single node,
  sqlite), cert-manager, CloudNativePG, Argo CD core, the GHCR image pull
  secret (from `KIT_SUBSTRATE_PULL_SECRET`, never a literal), and the first
  Applications. Every version pinned exactly:
  - k3s `v1.37.1+k3s1`
  - cert-manager `v1.21.2`
  - CloudNativePG `v1.30.1`
  - Argo CD `v3.5.4`

  All four verified against the GitHub releases API on 2026-10-07 (the Argo
  one needed a retry — the repo is `argoproj/argo-cd`, not `argoproj/argocd`).
  The script is idempotent (`kit_substrate_guard` is the named per-component
  guard), fails loudly and early (no root, no curl, non-Linux, unsupported
  arch, <4GB RAM, unreachable registry each refuse by name before anything is
  half-installed), and `DRY_RUN=1` prints every step and executes nothing.
- **`manifests/applications/`** — eight Argo CD `Application` manifests: the
  four launch services (identity, gateway, courier, parlor) and the
  observability set (alloy, loki, grafana, prometheus). Traces deferred — no
  Tempo Application.
- **`README.md`** — honest about what is not proven.
- **`tests/substrate_test.sh`** — the proof, wired into `validate.sh` as a
  static-phase section.

## What was proven (the checks)

`tests/substrate_test.sh` — 13 assertions, all green, each with a control that
must answer differently:

| Claim | Control that proves it can fail |
|---|---|
| `install.sh` parses (`bash -n`) | — |
| `DRY_RUN=1` runs to completion, six steps in order | — |
| Every pin is exact | fixture with `K3S_VERSION="latest"` goes **red** under the same check |
| Every manifest parses with `spec.source` + `spec.destination` | fixture missing `spec.source` goes **red** |
| No `:latest` image tag | planted `:latest` is **found** by the same grep |
| No inline secret (`stringData:`) | planted `stringData:` is **found** by the same grep |
| Pull secret never echoed | — |

The pin control was additionally verified by hand: substituting `latest` into
the real `install.sh` turned the test red (12 passed, 1 failed); restoring it
returned to 13 passed, 0 failed.

**Gate status:**
- `bash tests/validate.sh --static-only` — **PASS: every check passed.** 6 skips
  (docker/toolchain-dependent checks that skip on this machine). The substrate
  section is fully green.
- `bash tests/validate.sh` (full) — **timed out at 10 minutes** on this
  machine. The docker-based observability tiers are slow here. The log reached
  655 lines with **0 FAILs** and the substrate section fully green before the
  timeout. This is an environment limitation, not a defect in the change; the
  static phase — where the change lives — is green in both runs.

## What remains unexercised (written as unexercised, not done)

This machine is macOS. It cannot run k3s, so **`install.sh` has never been
executed here.** The proof is `DRY_RUN=1` plus the checks above. Specifically
unproven:

- That k3s actually installs and the node becomes Ready.
- That cert-manager, CloudNativePG and Argo CD core actually come up.
- That the pull secret is accepted by GHCR.
- That the Applications actually sync — **the charts they point at do not
  exist yet.** `caf gen chart` (m72, caf worktree) generates them; until then
  `targetRevision: 0.1.0` is a promise, not a published artifact.
- That the observability stack deploys and retains.

`templates/substrate/README.md` carries the same sentence.

## The named gap (recorded, not built)

**Who serves `install.sh` at `kit.cafaye.com`'s root.** `DEPLOYMENT.md` says
the script is served statically from that host, the `get.once.com` shape. The
packet explicitly puts this out of scope: *"Who serves it (the `site` frontend,
a static host, DNS) is a separate concern and a named gap — record it in the
report; do not build a web server in kit."* Recorded here. Not built.

## What a customer box must still prove

The first real run, on a Linux box with 8GB or more:

1. `curl https://kit.cafaye.com | sh` completes all six steps.
2. `kubectl get nodes` shows the node Ready.
3. `kubectl get applications -n argocd` shows all eight Applications synced.
4. The observability stack is reachable and retaining.

Until those four are observed on real hardware, the substrate is a checked
script and a set of manifests — not a running cluster.

## Successor's first move

The charts. `caf gen chart` (m72, caf worktree) must generate the eight charts
the Applications point at, publish them to GHCR as OCI artifacts at
`targetRevision: 0.1.0`, and only then does a customer box have something to
sync. Until then the Applications are a contract waiting for their artifacts.
