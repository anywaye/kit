#!/usr/bin/env bash
#
# kit's customer substrate — one command, one box.
#
#   curl https://kit.cafaye.com | sh
#
# or, from a kit checkout:
#
#   KIT_SUBSTRATE_PULL_SECRET=<value> \
#   KIT_SUBSTRATE_ACME_EMAIL=<value> bash templates/substrate/install.sh
#
# WHAT THIS INSTALLS, IN ORDER
#   1. k3s            single node, sqlite datastore — no etcd on one box
#   2. cert-manager
#   3. CloudNativePG
#   4. Argo CD core   no Dex, no SSO, no Redis HA
#   5. the GHCR image pull secret, from a value the OPERATOR supplies
#   6. the first Applications, so Argo starts syncing
#   7. the Let's Encrypt ClusterIssuers — staging + prod, from a value the OPERATOR supplies
#
# The decisions are in DEPLOYMENT.md. This file is the executable half of it:
# Argo core (not HA), Traefik (k3s's default) for ingress, traces deferred —
# Tempo slots in later as one more Application. There is no second deploy path.
#
# HOW TO CHOOSE A PIN
#   Every version below is exact. A floating tag in an install script is the
#   defect this whole fleet exists to avoid. Each pin was verified against the
#   GitHub releases API on 2026-10-07 and is re-checked by
#   `tests/substrate_test.sh`, which refuses a `latest` or floating pin.
#
# IDEMPOTENT — THE GUARD
#   `kit_substrate_guard` is the named guard. Each step asks it whether the
#   component is already present and skips it rather than re-installing. A
#   second run is a no-op, not a corruption. The guard is per-component, so a
#   half-finished first run resumes where it stopped instead of restarting.
#
# FAILS LOUDLY AND EARLY
#   No root, no curl, an unsupported arch, a non-Linux kernel, a box too small
#   for the Grafana stack, or an unreachable registry: each says what is wrong
#   and stops before anything is half-installed. The preflight runs before
#   step 1 and there is no `if` around any of its exits.
#
# DRY_RUN=1
#   Prints every step it would take and executes nothing. This is what makes
#   the script testable on a machine that is not a customer box — and a
#   developer machine is not one.
#
# SECRETS
#   The pull-secret value comes from the environment, never a literal in this
#   file. It is never echoed, in any mode.

set -euo pipefail

# --- pins ------------------------------------------------------------------
# Exact, always. Verified against the GitHub releases API on 2026-10-07.
K3S_VERSION="v1.37.1+k3s1"
CERT_MANAGER_VERSION="v1.21.2"
CNPG_VERSION="v1.30.1"
ARGOCD_VERSION="v3.5.4"

# --- operator-supplied values ----------------------------------------------
# KIT_SUBSTRATE_PULL_SECRET is the base64 dockerconfigjson GHCR needs. Read
# from the environment; never printed. The script validates its shape (it must
# decode and carry an `auths` object) without ever showing the value.
: "${KIT_SUBSTRATE_PULL_SECRET:=}"

# KIT_SUBSTRATE_ACME_EMAIL is the ACME account contact address. Read from the
# environment like the pull secret and validated by shape, but it is not a
# secret — it is the address Let's Encrypt sends expiry notices to. A literal
# in the manifests would be wrong, not merely insecure: it would put cafaye's
# address, or a made-up one, on a customer's ACME account. The manifests carry
# the placeholder ACME_EMAIL_PLACEHOLDER; this script substitutes it in a pipe
# at apply time and never prints the value.
: "${KIT_SUBSTRATE_ACME_EMAIL:=}"

DRY_RUN="${DRY_RUN:-0}"

# Where this script lives, so the manifests are found from a checkout and from
# a served copy alike.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$SCRIPT_DIR/manifests/applications"
TLS_DIR="$SCRIPT_DIR/manifests/tls"

# --- the guard --------------------------------------------------------------
# kit_substrate_guard <component> — is this component already installed?
# Returns 0 if present (skip), 1 if absent (install). In DRY_RUN it always
# returns 1, so the step is printed rather than skipped: a dry run shows the
# whole plan every time, which is what makes it a plan and not a no-op.
kit_substrate_guard() {
  local component="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    return 1
  fi
  case "$component" in
    k3s)
      [ -x /usr/local/bin/k3s ] && systemctl is-active --quiet k3s 2>/dev/null
      ;;
    cert-manager)
      kubectl --kubeconfig="$KUBECONFIG" get deployment -n cert-manager cert-manager >/dev/null 2>&1
      ;;
    cloudnative-pg)
      kubectl --kubeconfig="$KUBECONFIG" get deployment -n cnpg-system cnpg-controller-manager >/dev/null 2>&1
      ;;
    argocd)
      kubectl --kubeconfig="$KUBECONFIG" get deployment -n argocd argocd-server >/dev/null 2>&1
      ;;
    clusterissuer)
      # Cluster-scoped, so no -n: the guard asks for the production issuer by
      # name and the staging one is assumed to have come up beside it.
      kubectl --kubeconfig="$KUBECONFIG" get clusterissuer letsencrypt-prod >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

# --- helpers ----------------------------------------------------------------
KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

STEP=0
TOTAL=7

log_step() {
  STEP=$((STEP + 1))
  echo "[${STEP}/${TOTAL}] $*"
}

# dry_run <description> — print what would happen and return 0 (skip the real
# work) when DRY_RUN=1, or return 1 (do the real work) when it is not.
dry_run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "      DRY_RUN: $*"
    return 0
  fi
  return 1
}

# --- preflight --------------------------------------------------------------
# Every check here is a refusal, not a warning: a half-installed substrate is
# worse than no substrate, because it looks like it works.
preflight() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY_RUN: would check root, curl, Linux, arch, memory, registry reachability"
    return 0
  fi

  if [ "$(id -u)" -ne 0 ]; then
    echo "error: must run as root — k3s installs to /usr/local and writes the kubeconfig" >&2
    exit 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "error: curl is required — every component is fetched over HTTPS" >&2
    exit 1
  fi

  if [ "$(uname -s)" != "Linux" ]; then
    echo "error: this script installs k3s, which needs Linux (found $(uname -s))" >&2
    exit 1
  fi

  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64 | aarch64) ;;
    *)
      echo "error: unsupported architecture '$arch' — k3s supports x86_64 and aarch64" >&2
      exit 1
      ;;
  esac

  # Memory. DEPLOYMENT.md sizes the box: 8GB comfortable, 4GB no longer
  # qualifies once the Grafana stack lands. Measured from /proc/meminfo.
  local mem_kb
  mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [ "$mem_kb" -lt 4194304 ]; then
    echo "error: ${mem_kb} kB RAM — 4GB no longer qualifies once the Grafana stack lands (DEPLOYMENT.md)" >&2
    exit 1
  fi
  if [ "$mem_kb" -lt 8388608 ]; then
    echo "warning: ${mem_kb} kB RAM — 8GB is comfortable for the full stack" >&2
  fi

  # The registry is where the pull secret and every chart come from. An
  # unreachable ghcr.io is a refusal, not a retry: the install cannot complete.
  if ! curl -s --max-time 10 -o /dev/null https://ghcr.io/v2/; then
    echo "error: ghcr.io is unreachable — the pull secret and charts come from there" >&2
    exit 1
  fi
}

# --- step 1: k3s ------------------------------------------------------------
install_k3s() {
  log_step "k3s ${K3S_VERSION} — single node, sqlite datastore"
  if kit_substrate_guard k3s; then
    echo "      already installed, skipping"
    return 0
  fi
  if dry_run "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${K3S_VERSION} sh -"; then
    return 0
  fi
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -
  kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Ready node --all --timeout=120s
}

# --- step 2: cert-manager ----------------------------------------------------
install_cert_manager() {
  log_step "cert-manager ${CERT_MANAGER_VERSION}"
  if kit_substrate_guard cert-manager; then
    echo "      already installed, skipping"
    return 0
  fi
  if dry_run "kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"; then
    return 0
  fi
  kubectl --kubeconfig="$KUBECONFIG" apply -f \
    "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment -n cert-manager --all --timeout=180s
}

# --- step 3: CloudNativePG --------------------------------------------------
install_cnpg() {
  log_step "CloudNativePG ${CNPG_VERSION}"
  if kit_substrate_guard cloudnative-pg; then
    echo "      already installed, skipping"
    return 0
  fi
  if dry_run "kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_VERSION}/releases/cnpg-${CNPG_VERSION#v}.yaml"; then
    return 0
  fi
  kubectl --kubeconfig="$KUBECONFIG" apply -f \
    "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_VERSION}/releases/cnpg-${CNPG_VERSION#v}.yaml"
  kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment -n cnpg-system cnpg-controller-manager --timeout=180s
}

# --- step 4: Argo CD core ---------------------------------------------------
install_argocd() {
  log_step "Argo CD core ${ARGOCD_VERSION}"
  if kit_substrate_guard argocd; then
    echo "      already installed, skipping"
    return 0
  fi
  if dry_run "kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/core-install.yaml"; then
    return 0
  fi
  kubectl --kubeconfig="$KUBECONFIG" create namespace argocd --dry-run=client -o yaml |
    kubectl --kubeconfig="$KUBECONFIG" apply -f -
  kubectl --kubeconfig="$KUBECONFIG" apply -n argocd -f \
    "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/core-install.yaml"
  kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment -n argocd --all --timeout=300s
}

# --- step 5: the image pull secret ------------------------------------------
# The value comes from the environment. It is validated by shape — it must
# decode from base64 and carry an `auths` object — and never echoed.
install_pull_secret() {
  log_step "GHCR image pull secret (from KIT_SUBSTRATE_PULL_SECRET)"
  if dry_run "create secret ghcr-pull-secret in: argocd identity gateway courier parlor observability"; then
    return 0
  fi
  if [ -z "$KIT_SUBSTRATE_PULL_SECRET" ]; then
    echo "error: KIT_SUBSTRATE_PULL_SECRET is not set" >&2
    echo "  export KIT_SUBSTRATE_PULL_SECRET='<base64 dockerconfigjson>'" >&2
    echo "  # the value is never written to disk by this script" >&2
    exit 1
  fi
  # Shape check without echoing: decode and look for the `auths` key. The
  # decoded value is captured into a variable and never printed.
  local decoded
  if ! decoded="$(printf '%s' "$KIT_SUBSTRATE_PULL_SECRET" | base64 -d 2>/dev/null)"; then
    echo "error: KIT_SUBSTRATE_PULL_SECRET is not valid base64" >&2
    exit 1
  fi
  if ! printf '%s' "$decoded" | grep -q '"auths"'; then
    echo "error: KIT_SUBSTRATE_PULL_SECRET is not a dockerconfigjson (no \"auths\" key)" >&2
    exit 1
  fi
  local ns
  for ns in argocd identity gateway courier parlor observability; do
    kubectl --kubeconfig="$KUBECONFIG" create secret docker-registry ghcr-pull-secret \
      --from-file=.dockerconfigjson=<(printf '%s' "$KIT_SUBSTRATE_PULL_SECRET" | base64 -d) \
      --namespace="$ns" --dry-run=client -o yaml |
      kubectl --kubeconfig="$KUBECONFIG" apply -f -
  done
}

# --- step 6: the first Applications ----------------------------------------
install_applications() {
  log_step "the first Applications (identity, gateway, courier, parlor, observability)"
  if dry_run "kubectl apply -f ${MANIFEST_DIR}"; then
    return 0
  fi
  kubectl --kubeconfig="$KUBECONFIG" apply -f "$MANIFEST_DIR"
  kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment -n argocd argocd-server --timeout=120s
}

# --- step 7: the Let's Encrypt ClusterIssuers --------------------------------
# Two issuers — staging and production — identical but for the ACME directory
# URL. The email comes from the environment, is validated by shape, and is
# substituted into the manifests in a pipe: never written to disk, never
# printed. The email is not a secret, but the step prints what it did, not
# the value it did it with.
install_cluster_issuers() {
  log_step "the Let's Encrypt ClusterIssuers (staging + prod, from KIT_SUBSTRATE_ACME_EMAIL)"
  if kit_substrate_guard clusterissuer; then
    echo "      already installed, skipping"
    return 0
  fi
  if dry_run "substitute the ACME email and apply ${TLS_DIR} (letsencrypt-staging, letsencrypt-prod)"; then
    return 0
  fi
  if [ -z "$KIT_SUBSTRATE_ACME_EMAIL" ]; then
    echo "error: KIT_SUBSTRATE_ACME_EMAIL is not set" >&2
    echo "  export KIT_SUBSTRATE_ACME_EMAIL='<your-address@example.com>'" >&2
    echo "  # the ACME account contact address — Let's Encrypt sends expiry notices to it" >&2
    exit 1
  fi
  # Shape check without echoing the value: exactly one `@`, with something on
  # either side, and not one of the domains Let's Encrypt documents as
  # placeholders. A refused registration reads as a network error from the
  # customer's side; catch it here where the message can say what is wrong.
  # The count is the whole test: `%%@*` splits at the LAST `@`, so a second
  # `@` in the local part is invisible to the split and must be counted.
  local ats local_part domain_part
  ats="${KIT_SUBSTRATE_ACME_EMAIL//[^@]/}"
  local_part="${KIT_SUBSTRATE_ACME_EMAIL%%@*}"
  domain_part="${KIT_SUBSTRATE_ACME_EMAIL##*@}"
  if [ "${#ats}" -ne 1 ] || [ -z "$local_part" ] || [ -z "$domain_part" ]; then
    echo "error: KIT_SUBSTRATE_ACME_EMAIL must be an email address — exactly one '@', with something on either side" >&2
    exit 1
  fi
  case "$domain_part" in
    example.com | example.org | example.net)
      echo "error: KIT_SUBSTRATE_ACME_EMAIL is a $domain_part address — it must be real; Let's Encrypt sends expiry notices to it" >&2
      exit 1
      ;;
  esac
  # The placeholder is substituted in a pipe, never with `sed -i`: the value
  # reaches the API server and is never written to disk, so no copy of the
  # operator's address is left in a file on this box.
  sed "s/ACME_EMAIL_PLACEHOLDER/$KIT_SUBSTRATE_ACME_EMAIL/" "$TLS_DIR"/*.yaml |
    kubectl --kubeconfig="$KUBECONFIG" apply -f -
  echo "      applied letsencrypt-staging and letsencrypt-prod"
}

# --- main -------------------------------------------------------------------
main() {
  preflight
  install_k3s
  install_cert_manager
  install_cnpg
  install_argocd
  install_pull_secret
  install_applications
  install_cluster_issuers
  echo
  echo "substrate is up: k3s ${K3S_VERSION}, cert-manager ${CERT_MANAGER_VERSION}, CloudNativePG ${CNPG_VERSION}, Argo CD ${ARGOCD_VERSION}"
  echo "Argo CD UI:  kubectl -n argocd port-forward svc/argocd-server 8443:443"
  echo "             kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

main "$@"
