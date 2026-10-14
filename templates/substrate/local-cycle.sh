#!/usr/bin/env bash
# shellcheck disable=SC2317
#
# local-cycle.sh — the substrate, on a cluster that is already on this machine.
#
#   bash templates/substrate/local-cycle.sh              # create or reuse, then run
#   KIT_LOCAL_CLUSTER=cafaye-local bash templates/substrate/local-cycle.sh
#
# WHY THIS EXISTS
#   The substrate install is a customer-box command: it provisions the host it
#   runs on. A cycle against a VPS is therefore a wipe, a setup and an install,
#   over SSH, against a machine on another continent — minutes per iteration
#   and a full pass for every defect found. A developer with a local k3d cluster
#   has the same target one command away, and `KIT_SUBSTRATE_KUBECONFIG` is the
#   installer's entry for it (see install.sh's declaration: no k3s is installed
#   on the host, steps 1-3 ask the cluster, everything else is the same code).
#
#   THIS SCRIPT IS THE DEVELOPER'S ENTRY, AND k3d LIVES HERE AND NOWHERE ELSE.
#   The installer has no k3d dependency — it needs a kubeconfig and nothing
#   more, because a customer with their own Kubernetes has a kubeconfig and no
#   k3d. A git repository nested in a checkout is also not how anybody gets a
#   cluster, so the kubeconfig this writes is a FILE IN A SCRATCH DIRECTORY,
#   keyed to this worktree, and is removed when the machine tidies /tmp.
#
# WHAT IT DOES, IN ORDER
#   1. creates the cluster if it is not there (or reuses it — a warm cycle is
#      the number worth measuring, so reuse is the default),
#   2. writes that cluster's kubeconfig to a scratch file and prints the API
#      server it points at, so "which cluster did I just install into" is a line
#      of output rather than an assumption,
#   3. runs the installer HEADLESS against it — the same script, the same steps,
#      the same guards, the same refusals, the same JSONL,
#   4. prints the per-step table read back out of that JSONL, the wall clock,
#      the receipt, and `kubectl -n argocd get applications` on the cluster.
#
# NOTHING HERE ADDRESSES A REMOTE BOX. Every command names the local cluster:
# k3d talks to docker, the kubeconfig is written from the local k3d cluster's
# own API endpoint, and the installer reads only that file. The script carries
# no IP literal and no SSH — which `tests/substrate_test.sh` asserts, so a
# future edit that reaches for a box's address is a red gate rather than a
# surprise.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/templates/substrate/install.sh"
CLUSTER="${KIT_LOCAL_CLUSTER:-cafaye-local}"

# Scratch, keyed to the worktree: two developers (or two worktrees of the same
# repo) must not share one kubeconfig or one JSONL.
WORK="${TMPDIR:-/tmp}/kit-local-cycle-$(basename "$ROOT")"
mkdir -p "$WORK"

die() {
  printf 'local-cycle: %s\n' "$1" >&2
  exit 1
}

command -v k3d >/dev/null 2>&1 ||
  die "k3d is not installed — https://k3d.io/#installation (the installer itself needs only a kubeconfig; k3d is how a DEVELOPER gets one)"
command -v kubectl >/dev/null 2>&1 || die "kubectl is not on PATH"
[ -r "$INSTALLER" ] || die "no installer at $INSTALLER"

# --- 1. the cluster ---------------------------------------------------------
# REUSE IS THE DEFAULT, because a warm cycle is the one a developer runs
# twenty times a day and the one whose wall clock has to be small. `create` is
# only reached when the cluster is absent, and `--wait` means the create
# returns with a Ready node rather than a shell prompt and a race.
if k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${CLUSTER}\""; then
  printf 'local-cycle: reusing cluster %s (delete it with: k3d cluster delete %s)\n' "$CLUSTER" "$CLUSTER"
else
  printf 'local-cycle: creating cluster %s\n' "$CLUSTER"
  k3d cluster create "$CLUSTER" --wait
fi

# --- 2. the kubeconfig ------------------------------------------------------
# Written from THIS cluster, by name. Never the ambient ~/.kube/config: a
# developer's current context is theirs, and a cycle that changed it would be a
# cycle with a side effect nobody asked for.
KUBECONFIG_FILE="$WORK/kubeconfig.yaml"
kubectl config view --minify --raw --context="k3d-${CLUSTER}" >"$KUBECONFIG_FILE"
SERVER="$(kubectl --kubeconfig="$KUBECONFIG_FILE" config view -o jsonpath='{.clusters[0].cluster.server}')"
printf 'local-cycle: kubeconfig %s -> %s\n' "$KUBECONFIG_FILE" "$SERVER"

# --- 3. the substrate, headless, against that cluster -----------------------
# Every value below is an OVERRIDABLE DEFAULT, not a decision: the operator's
# own environment wins, so a cycle can be pointed at a different database list,
# a different ACME address or a different issuer without editing this file.
export KIT_SUBSTRATE_KUBECONFIG="$KUBECONFIG_FILE"
export KIT_SUBSTRATE_DATABASES="${KIT_SUBSTRATE_DATABASES:-identity,gateway,courier,parlor}"
export KIT_SUBSTRATE_ACME_EMAIL="${KIT_SUBSTRATE_ACME_EMAIL:-dev@cafaye.test}"
export KIT_SUBSTRATE_RECEIPT="$WORK/substrate-receipt.json"
export HEADLESS=1
JSONL="$WORK/local.jsonl"
HUMAN="$WORK/local.human"

printf 'local-cycle: running the substrate (headless) — %s\n' "$JSONL"
START_MS="$(date +%s)"
set +e
bash "$INSTALLER" >"$JSONL" 2>"$HUMAN"
EXIT_CODE=$?
set -e
ELAPSED=$(( $(date +%s) - START_MS ))

# --- 4. what the run said ---------------------------------------------------
# The table is READ BACK OUT OF THE JSONL, the same events a box emits, so a
# local cycle and a VPS cycle are compared on one shape. A run that refused
# mid-way has no `install.done`, and printing the step events it did emit is
# the useful answer — the number a developer acts on is the step it died on.
printf '\nlocal-cycle: %d seconds, exit %d\n' "$ELAPSED" "$EXIT_CODE"
if grep -q '"event":"install.done"' "$JSONL"; then
  printf 'local-cycle: the substrate reached install.done on this cluster\n'
  jq -r 'select(.event == "install.done") | .steps[] | "  \(.step)  \(.phase)"' "$JSONL" |
    while read -r step phase; do
      seconds="$(jq -r --arg p "$phase" 'select(.event == "install.done") | .steps[] | select(.phase == $p) | .seconds' "$JSONL" | head -1)"
      printf '  %2s  %-20s %ss\n' "$step" "$phase" "$seconds"
    done
  printf '  total: %ss\n' "$(jq -r 'select(.event == "install.done") | .seconds' "$JSONL")"
else
  printf 'local-cycle: the substrate did NOT reach install.done\n'
  jq -r 'select(.event == "refusal") | "  refused at step \(.step) (\(.phase)): \(.message)"' "$JSONL"
  printf '  last step reached: %s\n' \
    "$(jq -r 'select(.event == "step.start") | .phase' "$JSONL" | tail -1)"
fi

printf '\nlocal-cycle: the state of the cluster\n'
kubectl --kubeconfig="$KUBECONFIG_FILE" -n argocd get applications 2>&1 || true
kubectl --kubeconfig="$KUBECONFIG_FILE" get nodes 2>&1 || true

printf '\nlocal-cycle: receipt %s, events %s, human channel %s\n' \
  "$KIT_SUBSTRATE_RECEIPT" "$JSONL" "$HUMAN"
printf 'local-cycle: %d seconds total (cluster %s)\n' "$ELAPSED" "$CLUSTER"
exit "$EXIT_CODE"
