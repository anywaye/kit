#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/templates/substrate/install.sh"
CLUSTER="${KIT_LOCAL_CLUSTER:-anywaye-local}"

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

CLUSTER_JSON="$(k3d cluster list -o json 2>/dev/null || true)"
case "$CLUSTER_JSON" in
  *"\"name\":\"${CLUSTER}\""*)
    printf 'local-cycle: reusing cluster %s (delete it with: k3d cluster delete %s)\n' "$CLUSTER" "$CLUSTER"
    ;;
  *)
    printf 'local-cycle: creating cluster %s\n' "$CLUSTER"
    k3d cluster create "$CLUSTER" --wait
    ;;
esac

KUBECONFIG_FILE="$WORK/kubeconfig.yaml"
k3d kubeconfig get "$CLUSTER" >"$KUBECONFIG_FILE"
SERVER="$(kubectl --kubeconfig="$KUBECONFIG_FILE" config view -o jsonpath='{.clusters[0].cluster.server}')"
printf 'local-cycle: kubeconfig %s -> %s\n' "$KUBECONFIG_FILE" "$SERVER"

export KIT_SUBSTRATE_KUBECONFIG="$KUBECONFIG_FILE"
export KIT_SUBSTRATE_DATABASES="${KIT_SUBSTRATE_DATABASES:-courier,gateway,identity,parlor}"
export KIT_SUBSTRATE_ACME_EMAIL="${KIT_SUBSTRATE_ACME_EMAIL:-dev@anywaye.test}"
export KIT_SUBSTRATE_SMTP_ADAPTER="${KIT_SUBSTRATE_SMTP_ADAPTER:-smtp}"
export KIT_SUBSTRATE_SMTP_HOST="${KIT_SUBSTRATE_SMTP_HOST:-smtp.invalid}"
export KIT_SUBSTRATE_SMTP_PORT="${KIT_SUBSTRATE_SMTP_PORT:-587}"
export KIT_SUBSTRATE_SMTP_USERNAME="${KIT_SUBSTRATE_SMTP_USERNAME:-local-cycle-placeholder}"
export KIT_SUBSTRATE_SMTP_PASSWORD="${KIT_SUBSTRATE_SMTP_PASSWORD:-local-cycle-placeholder}"
export KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET="${KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET:-local-cycle-placeholder}"
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

printf '\nlocal-cycle: %d seconds, exit %d\n' "$ELAPSED" "$EXIT_CODE"
if grep -q '"event":"install.done"' "$JSONL"; then
  printf 'local-cycle: the substrate reached install.done on this cluster\n'
  jq -r 'select(.event == "install.done") | .steps[] | "  \(.step)  \(.phase)  \(.seconds)s"' "$JSONL"
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
