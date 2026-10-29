#!/usr/bin/env bash

set -euo pipefail

K3S_VERSION="v1.37.1+k3s1"
CERT_MANAGER_VERSION="v1.21.2"
CNPG_VERSION="v1.30.1"
ARGOCD_VERSION="v3.5.4"
NATS_VERSION="2.10.24-alpine"
NATS_BOX_VERSION="0.20.0"
NATS_URL="nats://nats.data.svc.cluster.local:4222"

KIT_SUBSTRATE_MANIFESTS_REF="6e1ba05f639cd517e78aff91cf789d7891080d7d"
KIT_SUBSTRATE_MANIFESTS_URL="https://codeload.github.com/anywaye/kit/tar.gz"

COURIER_URL="http://courier.courier.svc.cluster.local:4000"
IDENTITY_URL="http://identity.identity.svc.cluster.local:8080"
IDENTITY_COURIER_KEYS=(COURIER_BASE_URL COURIER_TOKEN PASSWORD_RESET_LINK_TEMPLATE EMAIL_VERIFICATION_LINK_TEMPLATE EMAIL_CHANGE_LINK_TEMPLATE RECOVERY_LINK_TEMPLATE INVITATION_LINK_TEMPLATE)

# --- the services' telemetry on a box: DELIBERATELY OFF ---------------------
# OTLP IS NOW ENABLED ON THE BOX. Alloy accepts OTLP on 4317/4318 and
# forwards logs to Loki (see alloy Application). Services send telemetry
# via <SERVICE>_OTEL_ENDPOINT (set in each chart's env block). Traces are
# still dropped (no Tempo yet); metrics via spanmetrics are a follow-up.
# OTEL_SDK_DISABLED is NOT set, so services export by default. To disable
# on a specific box, set OTEL_SDK_DISABLED=true in the service secret.
#
# ONE SPELLING, ONE LINE, AND THE ONE EXCEPTION NAMED. The generated charts
# inject env with `envFrom: secretRef`, so a key written into a service secret
# below IS an environment variable; the array is referenced, never retyped.
# gateway's chart is hand-written and reads its CLEAR env from a ConfigMap
# rather than its secret, so its Application carries the same key/value in
# `spec.source.helm.values` — the one service whose chart shape differs, and the
# reason is written at the site that differs.
# SERVICE_OTEL_DISABLED removed: OTLP is now enabled (Alloy accepts OTLP; see alloy Application).

: "${KIT_SUBSTRATE_BOX_ID:=}"

: "${KIT_SUBSTRATE_REGISTRY_CAPABILITY:=}"

: "${KIT_SUBSTRATE_BOX_URL:=https://box.svc.anywaye.com}"

: "${KIT_SUBSTRATE_ACME_EMAIL:=}"

: "${KIT_SUBSTRATE_DATABASES:=}"

: "${KIT_SUBSTRATE_POSTGRES_EXTENSIONS:=vector}"

: "${KIT_SUBSTRATE_SMTP_ADAPTER:=smtp}"
: "${KIT_SUBSTRATE_SMTP_PORT:=587}"
: "${KIT_SUBSTRATE_SMTP_HOST:=}"
: "${KIT_SUBSTRATE_SMTP_USERNAME:=}"
: "${KIT_SUBSTRATE_SMTP_PASSWORD:=}"
: "${KIT_SUBSTRATE_CLOUDFLARE_API_KEY:=}"
: "${KIT_SUBSTRATE_CF_ACCOUNT_ID:=}"
: "${KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET:=}"
: "${KIT_SUBSTRATE_MAIL_FROM:=}"
: "${KIT_SUBSTRATE_MAIL_FROM_NAME:=}"

: "${KIT_SUBSTRATE_STRIPE_API_KEY:=}"
: "${KIT_SUBSTRATE_STRIPE_WEBHOOK_SECRET:=}"


: "${KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER:=}"
: "${KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL:=}"
: "${KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY:=}"
: "${KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY:=}"

: "${KIT_SUBSTRATE_APP_BASE_URL:=}"

DRY_RUN="${DRY_RUN:-0}"

HEADLESS="${HEADLESS:-0}"

RECEIPT_PATH="${KIT_SUBSTRATE_RECEIPT:-/var/lib/kit/substrate-receipt.json}"

KIT_SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
if [ -n "$KIT_SCRIPT_SOURCE" ] && [ -f "$KIT_SCRIPT_SOURCE" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$KIT_SCRIPT_SOURCE")" && pwd)"
fi

MANIFEST_DIR=""
TLS_DIR=""
DATA_DIR=""
ARGOCD_MANIFEST_DIR=""
SUBSTRATE_MANIFEST_ROOT=""
SUBSTRATE_FETCHED_MANIFESTS_DIR=""
if [ -n "$SCRIPT_DIR" ]; then
  SUBSTRATE_MANIFEST_ROOT="$SCRIPT_DIR/manifests"
  MANIFEST_DIR="$SUBSTRATE_MANIFEST_ROOT/applications"
  TLS_DIR="$SUBSTRATE_MANIFEST_ROOT/tls"
  DATA_DIR="$SUBSTRATE_MANIFEST_ROOT/data"
  ARGOCD_MANIFEST_DIR="$SUBSTRATE_MANIFEST_ROOT/argocd"
fi

kit_substrate_point_manifests_at() {
  SUBSTRATE_MANIFEST_ROOT="$1"
  MANIFEST_DIR="$1/applications"
  TLS_DIR="$1/tls"
  DATA_DIR="$1/data"
  ARGOCD_MANIFEST_DIR="$1/argocd"
}

kit_substrate_cleanup_manifests() {
  if [ -n "${SUBSTRATE_FETCHED_MANIFESTS_DIR:-}" ]; then
    rm -rf "$SUBSTRATE_FETCHED_MANIFESTS_DIR"
  fi
  return 0
}

kit_substrate_resolve_manifests() {
  if [ -n "$SUBSTRATE_MANIFEST_ROOT" ] && [ -d "$MANIFEST_DIR" ]; then
    return 0
  fi

  local mkdir_ok=0 tmp root
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/kit-substrate-manifests.XXXXXX" 2>/dev/null)" || mkdir_ok=1
  if [ "$mkdir_ok" -eq 0 ]; then
    kit_substrate_out "      this script was served, not run from a checkout — fetching the manifests at ${KIT_SUBSTRATE_MANIFESTS_REF}"
    if curl -fsSL "${KIT_SUBSTRATE_MANIFESTS_URL}/${KIT_SUBSTRATE_MANIFESTS_REF}" 2>/dev/null | tar -xz -C "$tmp" 2>/dev/null; then
      root="$(find "$tmp" -maxdepth 4 -type d -path '*/templates/substrate/manifests' -print -quit 2>/dev/null)"
      if [ -n "$root" ] && [ -d "$root/applications" ]; then
        SUBSTRATE_FETCHED_MANIFESTS_DIR="$tmp"
        trap kit_substrate_cleanup_manifests EXIT
        kit_substrate_point_manifests_at "$root"
        kit_substrate_out "      fetched ${KIT_SUBSTRATE_MANIFESTS_REF} into ${root}"
        return 0
      fi
    fi
    rm -rf "$tmp"
  fi

  kit_substrate_refuse "" \
    "check that this box can reach ${KIT_SUBSTRATE_MANIFESTS_URL} and re-run — a served install fetches its manifest set, so the fetch is the first thing that must work" \
    "the manifest set could not be fetched from ${KIT_SUBSTRATE_MANIFESTS_URL}/${KIT_SUBSTRATE_MANIFESTS_REF}, and no manifests/ directory exists beside this script (it was served, not run from a checkout)"
}

kit_substrate_now() {
  if [ -r /proc/uptime ]; then
    awk '{printf "%.0f\n", $1 * 1000}' /proc/uptime
    return 0
  fi
  if [ -n "${EPOCHREALTIME:-}" ]; then
    printf '%s' "$EPOCHREALTIME" | awk -F. '{printf "%d%03d\n", $1, substr($2 "000", 1, 3)}'
    return 0
  fi
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'
    return 0
  fi
  printf '%s000\n' "$(date +%s)"
}

kit_substrate_seconds() {
  printf '%d.%03d' "$(( $1 / 1000 ))" "$(( $1 % 1000 ))"
}

kit_substrate_elapsed() {
  kit_substrate_seconds "$(( $(kit_substrate_now) - INSTALL_START_MS ))"
}

kit_substrate_present() {
  local component="$1"
  case "$component" in
    k3s)
      if [ "$CLUSTER_SUPPLIED" -eq 1 ]; then
        [ -n "$(kubectl --kubeconfig="$KUBECONFIG" get nodes --no-headers 2>/dev/null || true)" ]
      else
        [ -x /usr/local/bin/k3s ] && systemctl is-active --quiet k3s 2>/dev/null
      fi
      ;;
    cert-manager)
      kubectl --kubeconfig="$KUBECONFIG" get deployment -n cert-manager cert-manager >/dev/null 2>&1
      ;;
    cloudnative-pg)
      kubectl --kubeconfig="$KUBECONFIG" get deployment -n cnpg-system cnpg-controller-manager >/dev/null 2>&1
      ;;
    argocd)
      kubectl --kubeconfig="$KUBECONFIG" get deployment -n argocd argocd-repo-server >/dev/null 2>&1
      ;;
    clusterissuer)
      kubectl --kubeconfig="$KUBECONFIG" get clusterissuer letsencrypt-prod >/dev/null 2>&1
      ;;
    cluster)
      kubectl --kubeconfig="$KUBECONFIG" get cluster.postgresql.cnpg.io postgres -n data >/dev/null 2>&1
      ;;
    redis)
      kubectl --kubeconfig="$KUBECONFIG" get deployment redis -n data >/dev/null 2>&1
      ;;
    nats)
      kubectl --kubeconfig="$KUBECONFIG" get deployment nats -n data >/dev/null 2>&1
      ;;
    secrets)
      for s in identity/identity-secrets gateway/gateway-secrets courier/courier-secrets parlor/parlor-secrets billing/billing-secrets; do
        kubectl --kubeconfig="$KUBECONFIG" get secret "${s#*/}" -n "${s%/*}" >/dev/null 2>&1 || return 1
      done
      ;;
    *)
      return 1
      ;;
  esac
}

kit_substrate_guard() {
  local component="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    STEP_START_MS="$(kit_substrate_now)"
    return 1
  fi
  if kit_substrate_present "$component"; then
    STEP_SKIPPED=1
    return 0
  fi
  STEP_START_MS="$(kit_substrate_now)"
  return 1
}

kit_substrate_pending() {
  PENDING_WAITS="${PENDING_WAITS} $1"
}

# --- the cluster this install runs against -----------------------------------
# TWO SHAPES, AND THE INPUT DECIDES WHICH ONE, EXACTLY ONCE.
#
#   unset  — a fresh box. The host IS the cluster: this script installs k3s on
#            it, writes /etc/rancher/k3s/k3s.yaml, and every host probe in the
#            preflight (root, Linux, arch, memory) is a real refusal.
#
#   a path — a cluster that is already reachable at that kubeconfig. The host
#            the script runs on is only a workstation: it is not root, it is
#            not Linux, it does not carry the cluster's memory, and none of
#            those facts are this install's business any more. What IS its
#            business is that the kubeconfig is readable and the cluster
#            answers, so those two are refusals.
#
# ENV VAR, NOT A FLAG, and that follows the two precedents already in this
# file: `KIT_SUBSTRATE_RECEIPT` is a path-valued input with no flag, and
# `DRY_RUN` is a runtime switch with no flag. A flag is for a boolean a human
# types (`--headless`); a path is copied out of another tool's output —
# `k3d kubeconfig write`, `kind get kubeconfig`, `export KUBECONFIG=…` — and an
# argument a flag would carry is one the shell would also have to expand.
# It is also the one spelling kubectl itself speaks, so the value is handed
# over in the dialect the operator already has it in.
#
# It is NOT the ambient `KUBECONFIG`, deliberately. A developer's shell has a
# current context for reasons that have nothing to do with this install, and a
# variable that changes whether k3s is installed on the host from some other
# tool's export is a trap. This one is named, kit-scoped, and stated here.
: "${KIT_SUBSTRATE_KUBECONFIG:=}"

CLUSTER_SUPPLIED=0
if [ -n "$KIT_SUBSTRATE_KUBECONFIG" ]; then
  CLUSTER_SUPPLIED=1
fi

KUBECONFIG="${KIT_SUBSTRATE_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

STEP=0
TOTAL=13
CURRENT_PHASE="install"

INSTALL_START_MS=""
STEP_PHASE="install"
STEP_START_MS=""
STEP_SKIPPED=0
STEP_LEDGER=""

PENDING_WAITS=""


json_str() {
  printf '%s' "$1" | jq -Rs '.'
}

kit_substrate_out() {
  if [ "$HEADLESS" -eq 1 ]; then
    printf '%s\n' "$*" >&2
  else
    printf '%s\n' "$*"
  fi
}

kit_substrate_emit() {
  local event="$1" message="$2" extra="${3:-}"
  if [ "$HEADLESS" -eq 1 ]; then
    printf '{"event":"%s","step":%s,"phase":%s,"message":%s%s}\n' \
      "$event" "$STEP" "$(json_str "$CURRENT_PHASE")" "$(json_str "$message")" "$extra" >&3
  else
    case "$event" in
      step.start) echo "[${STEP}/${TOTAL}] $message" ;;
      step.skip)  echo "      already installed, skipping" ;;
      step.plan)  echo "      DRY_RUN: $message" ;;
      step.done)  ;;
      *)          echo "$message" ;;
    esac
  fi
}

kit_substrate_skip() {
  kit_substrate_emit step.skip "already installed, skipping"
}

kit_substrate_step_finalize() {
  [ "$STEP" -gt 0 ] || return 0
  local secs
  if [ "$STEP_SKIPPED" -eq 1 ]; then
    secs="skipped"
  elif [ -n "$STEP_START_MS" ]; then
    secs="$(kit_substrate_seconds "$(( $(kit_substrate_now) - STEP_START_MS ))")"
  else
    secs="unknown"
  fi
  STEP_LEDGER="${STEP_LEDGER}${STEP}	${STEP_PHASE}	${secs}
"
  local saved_phase="$CURRENT_PHASE"
  CURRENT_PHASE="$STEP_PHASE"
  if [ "$secs" = "skipped" ] || [ "$secs" = "unknown" ]; then
    kit_substrate_emit step.done "$STEP_PHASE: $secs" ",\"seconds\":$(json_str "$secs")"
  else
    kit_substrate_emit step.done "$STEP_PHASE: ${secs}s" ",\"seconds\":${secs}"
  fi
  CURRENT_PHASE="$saved_phase"
  STEP_SKIPPED=0
  STEP_START_MS=""
}

kit_substrate_steps_json() {
  printf '%s' "$STEP_LEDGER" | jq -R -s -c '
    split("\n")
    | map(select(length > 0) | split("\t"))
    | map({step: (.[0] | tonumber),
           phase: .[1],
           seconds: (if .[2] == "skipped" or .[2] == "unknown"
                     then .[2] else (.[2] | tonumber) end)})'
}

kit_substrate_print_table() {
  local total="$1" line n phase secs
  kit_substrate_out "  step  phase                seconds"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n="${line%%	*}"
    phase="${line#*	}"
    secs="${phase#*	}"
    phase="${phase%%	*}"
    kit_substrate_out "$(printf '  %-5s %-20s %s' "$n" "$phase" "$secs")"
  done <<EOF
$STEP_LEDGER
EOF
  kit_substrate_out "  total                      ${total}"
}

log_step() {
  kit_substrate_step_finalize
  STEP=$((STEP + 1))
  STEP_PHASE="$CURRENT_PHASE"
  STEP_START_MS="$(kit_substrate_now)"
  R_PHASE="$CURRENT_PHASE"
  R_NEXT="$*"
  R_INPUT=""
  R_HUMAN=""
  R_STATUS="running"
  R_MESSAGE=""
  kit_substrate_write_receipt
  kit_substrate_emit step.start "$*" ",\"seconds\":$(kit_substrate_elapsed)"
}

dry_run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    kit_substrate_emit step.plan "$*"
    return 0
  fi
  return 1
}

kit_substrate_await_list() {
  local budget="$1"; shift
  kit_substrate_out "      waiting up to ${budget}s for: kubectl get $*"
  local deadline list
  deadline=$(( $(date +%s) + budget ))
  while :; do
    list="$(kubectl --kubeconfig="$KUBECONFIG" get "$@" --no-headers 2>/dev/null || true)"
    if [ -n "$list" ]; then
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      kit_substrate_refuse "" \
        "timed out after ${budget}s waiting for: kubectl get $* (the list is empty)" \
        "the object does not exist yet, so there is nothing to wait for — check the controller that owns it (the kubelet for a Node, the CNPG operator for the Cluster's pods, the API server itself), then re-run: every step that already completed is skipped by its guard"
    fi
    sleep 2
  done
}

kit_substrate_await_pods_running() {
  local ns="$1" prefix="$2" budget="$3"
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  if ! command -v kubectl >/dev/null 2>&1; then
    return 0
  fi
  local start deadline elapsed
  start="$(date +%s)"
  deadline=$(( start + budget ))
  while :; do
    local pods_json pod_count pulling
    pods_json="$(kubectl --kubeconfig="$KUBECONFIG" get pods -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')"
    if [ -n "$prefix" ]; then
      pod_count="$(printf '%s' "$pods_json" | jq -r --arg p "$prefix" '[.items[] | select(.metadata.name | startswith($p))] | length' 2>/dev/null || echo 0)"
      pulling="$(printf '%s' "$pods_json" | jq -r --arg p "$prefix" '[.items[] | select(.metadata.name | startswith($p)) | .status.containerStatuses[]? | select(.state.waiting.reason == "ContainerCreating" or .state.waiting.reason == "ErrImagePull" or .state.waiting.reason == "ImagePullBackOff")] | length' 2>/dev/null || echo 0)"
    else
      pod_count="$(printf '%s' "$pods_json" | jq -r '.items | length' 2>/dev/null || echo 0)"
      pulling="$(printf '%s' "$pods_json" | jq -r '[.items[] | .status.containerStatuses[]? | select(.state.waiting.reason == "ContainerCreating" or .state.waiting.reason == "ErrImagePull" or .state.waiting.reason == "ImagePullBackOff")] | length' 2>/dev/null || echo 0)"
    fi
    if [ "$pod_count" -gt 0 ] && [ "$pulling" -eq 0 ]; then
      return 0
    fi
    elapsed=$(( $(date +%s) - start ))
    if [ "$(date +%s)" -ge "$deadline" ]; then
      if [ "$pulling" -gt 0 ]; then
        kit_substrate_out "      $ns/${prefix:-all} still pulling after ${elapsed}s (budget ${budget}s); continuing to readiness wait"
      fi
      return 0
    fi
    if [ "$elapsed" -gt 0 ] && [ $((elapsed % 30)) -eq 0 ]; then
      local msg_prefix
      if [ -n "$prefix" ]; then
        msg_prefix="$ns/$prefix"
      else
        msg_prefix="$ns (all)"
      fi
      if [ "$pod_count" -eq 0 ]; then
        kit_substrate_out "      $msg_prefix — no pods yet; ${elapsed}s so far (image pull budget ${budget}s)"
      elif [ "$pulling" -gt 0 ]; then
        kit_substrate_out "      $msg_prefix is pulling; ${elapsed}s so far (budget ${budget}s)"
      else
        kit_substrate_out "      $msg_prefix — waiting for pods to be Running; ${elapsed}s so far"
      fi
      sleep 5
    else
      sleep 2
    fi
  done
}

kit_substrate_await_port() {
  local port="$1" budget="$2" deadline
  deadline=$(( $(date +%s) + budget ))
  while :; do
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      return 1
    fi
    sleep 1
  done
}

R_PHASE="install"
R_NEXT=""
R_INPUT=""
R_HUMAN=""
R_STATUS="running"
R_MESSAGE=""

kit_substrate_write_receipt() {
  local dir
  dir="$(dirname "$RECEIPT_PATH")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    return 0
  fi
  jq -n \
    --arg phase "$R_PHASE" \
    --arg status "$R_STATUS" \
    --argjson step "$STEP" \
    --argjson total_steps "$TOTAL" \
    --arg next "$R_NEXT" \
    --arg input_needed "$R_INPUT" \
    --arg human "$R_HUMAN" \
    --arg message "$R_MESSAGE" \
    --arg receipt "$RECEIPT_PATH" \
    --argjson headless "$HEADLESS" \
    --argjson dry_run "$DRY_RUN" \
    --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      phase: $phase,
      status: $status,
      step: $step,
      total_steps: $total_steps,
      next: (if $next == "" then null else $next end),
      input_needed: (if $input_needed == "" then null else $input_needed end),
      human: (if $human == "" then null else $human end),
      message: (if $message == "" then null else $message end),
      receipt: $receipt,
      headless: $headless,
      dry_run: $dry_run,
      updated_at: $updated_at
    }' >"$RECEIPT_PATH" 2>/dev/null || true
}

kit_substrate_refuse() {
  local input="$1" human="$2" message="$3"
  printf 'error: %s\n' "$message" >&2
  [ -n "$human" ] && printf '  %s\n' "$human" >&2
  if [ "$HEADLESS" -eq 1 ]; then
    printf '{"event":"refusal","step":%s,"phase":%s,"input_needed":%s,"human":%s,"message":%s}\n' \
      "$STEP" "$(json_str "$CURRENT_PHASE")" "$(json_str "$input")" "$(json_str "$human")" "$(json_str "$message")" >&3
  fi
  R_PHASE="$CURRENT_PHASE"
  R_INPUT="$input"
  R_HUMAN="$human"
  R_STATUS="refused"
  R_MESSAGE="$message"
  kit_substrate_write_receipt
  exit 1
}

READINESS_DNS_SPLIT=""
READINESS_DNS_STATUS=""
: "${KIT_SUBSTRATE_RESOLVED_CONF:=/etc/systemd/resolved.conf.d/99-anywaye.conf}"
kit_substrate_ensure_public_resolver() {
  local hosts
  hosts="$(kit_substrate_intended_hosts "$MANIFEST_DIR")"
  if [ -z "$hosts" ]; then
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    kit_substrate_out "      DRY_RUN: would write $KIT_SUBSTRATE_RESOLVED_CONF with DNS=1.1.1.1 8.8.8.8 (public resolver for boxes serving public names; provider's resolver held stale NXDOMAIN on live box: getent empty, dig @1.1.1.1 169.58.108.209, resolvectl 209.126.15.53)"
    return 0
  fi
  local want="[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=1.0.0.1 8.8.4.4"
  local dir
  dir="$(dirname "$KIT_SUBSTRATE_RESOLVED_CONF")"
  mkdir -p "$dir" 2>/dev/null || true
  if [ -f "$KIT_SUBSTRATE_RESOLVED_CONF" ] && [ "$(cat "$KIT_SUBSTRATE_RESOLVED_CONF" 2>/dev/null)" = "$want" ]; then
    kit_substrate_out "      public resolver already configured at $KIT_SUBSTRATE_RESOLVED_CONF (DNS=1.1.1.1 8.8.8.8)"
    return 0
  fi
  if [ "$(id -u)" -ne 0 ] && [ "$KIT_SUBSTRATE_RESOLVED_CONF" = "/etc/systemd/resolved.conf.d/99-anywaye.conf" ]; then
    kit_substrate_out "      note: would write public resolver to $KIT_SUBSTRATE_RESOLVED_CONF but not running as root (test mode)"
    return 0
  fi
  cat >"$KIT_SUBSTRATE_RESOLVED_CONF" <<EOF
$want
EOF
  kit_substrate_out "      wrote public resolver $KIT_SUBSTRATE_RESOLVED_CONF with DNS=1.1.1.1 8.8.8.8 — the provider's resolver held a stale NXDOMAIN on the live box (getent hosts empty, dig @1.1.1.1 answered 169.58.108.209, resolvectl Current DNS Server: 209.126.15.53)"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart systemd-resolved 2>/dev/null || true
    if command -v resolvectl >/dev/null 2>&1; then
      resolvectl flush-caches 2>/dev/null || true
    fi
  fi
  if command -v kubectl >/dev/null 2>&1 && [ -r "$KUBECONFIG" ]; then
    kubectl --kubeconfig="$KUBECONFIG" -n kube-system rollout restart deployment coredns 2>/dev/null || true
    kubectl --kubeconfig="$KUBECONFIG" -n kube-system rollout restart deployment k3s-coredns 2>/dev/null || true
  fi
}

READINESS_TLS_PENDING=""
OIDC_ROUTE_VERIFIED=""
OIDC_SECRET_PATCHED=""

kit_substrate_url_host() {
  local rest="${1:-}"
  case "$rest" in
    *://*) rest="${rest#*://}" ;;
  esac
  rest="${rest%%/*}"
  rest="${rest%%:*}"
  printf '%s' "$rest"
}

kit_substrate_is_checkable_host() {
  case "$1" in
    "") return 1 ;;
    localhost | *.svc.cluster.local | *.svc | *.local | 127.*) return 1 ;;
  esac
  case "$1" in
    *.*) return 0 ;;
    *) return 1 ;;
  esac
}

kit_substrate_host_resolves() {
  local host="$1"
  [ -n "$host" ] || return 1
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$host" >/dev/null 2>&1
    return $?
  fi
  if command -v dscacheutil >/dev/null 2>&1; then
    dscacheutil -q host -a name "$host" 2>/dev/null | grep -q 'ip_address:'
    return $?
  fi
  python3 -c 'import socket,sys; socket.getaddrinfo(sys.argv[1], None)' "$host" >/dev/null 2>&1
  return $?
}

kit_substrate_cluster_host_resolves() {
  local host="$1"
  [ -n "$host" ] || return 1
  local dns_ip=""
  if command -v kubectl >/dev/null 2>&1 && [ -r "$KUBECONFIG" ]; then
    dns_ip="$(kubectl --kubeconfig="$KUBECONFIG" get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  fi
  if [ -z "$dns_ip" ]; then
    dns_ip="10.43.0.10"
  fi
  if command -v dig >/dev/null 2>&1; then
    dig +short +time=2 +tries=1 "@$dns_ip" "$host" 2>/dev/null | grep -q .
    return $?
  fi
  if command -v nslookup >/dev/null 2>&1; then
    nslookup "$host" "$dns_ip" >/dev/null 2>&1
    return $?
  fi
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$host" >/dev/null 2>&1
    return $?
  fi
  if command -v dscacheutil >/dev/null 2>&1; then
    dscacheutil -q host -a name "$host" 2>/dev/null | grep -q 'ip_address:'
    return $?
  fi
  python3 -c 'import socket,sys; socket.getaddrinfo(sys.argv[1], None)' "$host" >/dev/null 2>&1
  return $?
}

kit_substrate_ingress_hosts() {
  local dir="$1"
  sed 's/#.*//' "$dir"/*.yaml 2>/dev/null \
    | sed -E -n 's/^[[:space:]]*(-[[:space:]]+)?host:[[:space:]]+//p' \
    | sed -E -e 's/[[:space:]]+$//' -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'\$/\1/" \
    | grep -v '^$' 2>/dev/null || true
}

kit_substrate_ingress_host() {
  local v="$1"
  case "$v" in
    http://* | https://*)
      kit_substrate_url_host "$v"
      return
      ;;
  esac
  v="${v%%/*}"
  case "$v" in
    *:[0-9]*) v="${v%:*}" ;;
  esac
  printf '%s' "$v"
}

kit_substrate_intended_hosts() {
  local table
  table="$(kit_substrate_intended_host_table "${1:-$MANIFEST_DIR}")"
  printf '%s' "$table" | cut -f1
}

kit_substrate_intended_host_table() {
  local dir="${1:-$MANIFEST_DIR}" rows="" url h found v tab
  tab="$(printf '\t')"
  if [ -n "$KIT_SUBSTRATE_APP_BASE_URL" ]; then
    h="$(kit_substrate_url_host "$KIT_SUBSTRATE_APP_BASE_URL")"
    if kit_substrate_is_checkable_host "$h"; then
      rows="${rows}${h}${tab}KIT_SUBSTRATE_APP_BASE_URL
"
    fi
  fi
  if [ -n "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ]; then
    h="$(kit_substrate_url_host "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER")"
    if kit_substrate_is_checkable_host "$h"; then
      rows="${rows}${h}${tab}KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER
"
    fi
  fi
  if [ -d "$dir" ]; then
    found="$(sed 's/#.*//' "$dir"/*.yaml 2>/dev/null | grep -vE 'repoURL:|destination:|server: https://' | grep -oE 'https?://[^"'"'"' <>]+' 2>/dev/null || true)"
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      h="$(kit_substrate_url_host "$url")"
      if kit_substrate_is_checkable_host "$h"; then
        rows="${rows}${h}${tab}an https URL in the Applications' helm.values
"
      fi
    done <<EOF
$found
EOF
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      h="$(kit_substrate_ingress_host "$v")"
      if kit_substrate_is_checkable_host "$h"; then
        rows="${rows}${h}${tab}an ingress host in the manifests
"
      fi
    done <<EOF
$(kit_substrate_ingress_hosts "$dir")
EOF
  fi
  printf '%s' "$rows" | awk 'NF && !seen[$1]++'
}

kit_substrate_host_source() {
  local table
  table="$(kit_substrate_intended_host_table)"
  printf '%s' "$table" | awk -F '\t' -v h="$1" '$1 == h { print $2; exit }'
}

kit_substrate_compute_readiness() {
  READINESS_TLS_PENDING=""
  READINESS_DNS_SPLIT=""
  READINESS_DNS_STATUS=""
  local h all pending="" split="" status=""
  all="$(kit_substrate_intended_hosts "$MANIFEST_DIR")"
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    local node_ok=0 cluster_ok=0
    if kit_substrate_host_resolves "$h"; then node_ok=1; fi
    if kit_substrate_cluster_host_resolves "$h"; then cluster_ok=1; fi
    status="${status}${h}	${node_ok}	${cluster_ok}
"
    if [ "$node_ok" -eq 1 ] && [ "$cluster_ok" -eq 1 ]; then
      continue
    fi
    pending="${pending}${h}
"
    if [ "$node_ok" -ne "$cluster_ok" ]; then
      split="${split}${h}
"
    fi
  done <<EOF
$all
EOF
  READINESS_TLS_PENDING="$pending"
  READINESS_DNS_SPLIT="$split"
  READINESS_DNS_STATUS="$status"
}

kit_substrate_readiness_pending_count() {
  local n=0 h
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    n=$((n + 1))
  done <<EOF
$READINESS_TLS_PENDING
EOF
  if [ -z "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ]; then
    n=$((n + 1))
  fi
  printf '%s' "$n"
}

# kit_substrate_readiness_preflight — the preflight half of the report: which
# intended hosts do not resolve and what that means, and the OIDC consequence
# with the one export that turns it on. A report, not a refusal.
# The TLS sentence is unchanged; the cluster-DNS verdict is added so the
# operator sees which path failed. A split (node vs CoreDNS) gets its own
# sentence: that is exactly the state the live box produced (getent empty
# while 1.1.1.1 answered and CoreDNS 10.43.0.10 NXDOMAIN).
kit_substrate_readiness_preflight() {
  kit_substrate_compute_readiness
  local h src tab table
  tab="$(printf '\t')"
  table="$(kit_substrate_intended_host_table)"
  kit_substrate_out "  readiness preflight: resolving the intended public hosts on this box"
  if [ -z "$table" ]; then
    kit_substrate_out "    no checkable public host to resolve (unset or local/in-cluster URLs need no public DNS)"
  else
    kit_substrate_out "    intended hosts, and the source each one came from:"
    while IFS="$tab" read -r h src; do
      [ -n "$h" ] || continue
      kit_substrate_out "      ${h} — from ${src}"
    done <<EOF
$table
EOF
    if [ -z "$READINESS_TLS_PENDING" ]; then
      kit_substrate_out "    every intended host resolves (node and cluster DNS agree)"
      kit_substrate_out "    cluster DNS (CoreDNS at 10.43.0.10:53) agrees with node DNS for every host"
    else
      while IFS= read -r h; do
        [ -n "$h" ] || continue
        src="$(kit_substrate_host_source "$h")"
        line="$(printf '%s' "$READINESS_DNS_STATUS" | awk -F '\t' -v h="$h" '$1==h {print $2" "$3}')"
        node_ok="$(printf '%s' "$line" | cut -d' ' -f1)"
        cluster_ok="$(printf '%s' "$line" | cut -d' ' -f2)"
        if [ "$node_ok" = "1" ] && [ "$cluster_ok" = "0" ]; then
          kit_substrate_out "    ${h}: RESOLVES ON NODE BUT NOT THROUGH CLUSTER DNS (CoreDNS 10.43.0.10:53: no such host; from ${src}) — the ACME HTTP-01 self check (which resolves through CoreDNS) will fail, the Certificate will sit pending, and the Ingress will keep serving plaintext on port 80"
        elif [ "$node_ok" = "0" ] && [ "$cluster_ok" = "1" ]; then
          kit_substrate_out "    ${h}: RESOLVES THROUGH CLUSTER DNS BUT NOT ON NODE (from ${src}) — the two DNS paths disagree; the Certificate may still fail until both agree"
        else
          kit_substrate_out "    ${h}: DOES NOT RESOLVE (node and cluster DNS: no such host; from ${src}) — the ACME HTTP-01 self check will fail, the Certificate will sit pending, and the Ingress will keep serving plaintext on port 80"
        fi
      done <<EOF
$READINESS_TLS_PENDING
EOF
      if [ -n "$READINESS_DNS_SPLIT" ]; then
        kit_substrate_out "    cluster DNS (CoreDNS at 10.43.0.10:53) disagrees with node DNS for: $(printf '%s' "$READINESS_DNS_SPLIT" | tr '\n' ' ' | sed 's/ *$//')"
      else
        kit_substrate_out "    cluster DNS (CoreDNS at 10.43.0.10:53) agrees with node DNS: both report no such host for the pending host(s)"
      fi
    fi
  fi
  if [ -z "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ]; then
    kit_substrate_out "  OIDC: KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER is unset — identity serves no JWKS route, so gateway's /readyz fails and its Deployment never becomes Ready"
    kit_substrate_out "    turn it on with: export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='https://<your-issuer>'"
  else
    kit_substrate_out "  OIDC: issuer is set — identity serves its JWKS route"
  fi
  local store
  store="$(kit_substrate_log_store)"
  if [ "$store" = "journald" ]; then
    kit_substrate_out "  logs: centralized Loki not installed — logs in journald / kubectl logs; Alloy runs but ships nowhere centrally"
  else
    kit_substrate_out "  logs: centralized Loki installed — query via Grafana Explore / Loki API"
  fi
}

kit_substrate_log_store() {
  if [ -f "$MANIFEST_DIR/loki.yaml" ]; then
    printf 'loki'
  else
    printf 'journald'
  fi
}

kit_substrate_readiness_final() {
  local h src
  kit_substrate_out "  THIS BOX WILL NOT FULLY SERVE UNTIL:"
  if [ -n "$READINESS_TLS_PENDING" ]; then
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      src="$(kit_substrate_host_source "$h")"
      line="$(printf '%s' "$READINESS_DNS_STATUS" | awk -F '\t' -v h="$h" '$1==h {print $2" "$3}')"
      node_ok="$(printf '%s' "$line" | cut -d' ' -f1)"
      cluster_ok="$(printf '%s' "$line" | cut -d' ' -f2)"
      if [ "$node_ok" = "1" ] && [ "$cluster_ok" = "0" ]; then
        kit_substrate_out "    - ${h} resolves on node and through cluster DNS (CoreDNS 10.43.0.10:53) (point ${h} at this box; from ${src}) — until then the ACME HTTP-01 self check (which resolves through CoreDNS) fails, the Certificate sits pending, and the Ingress serves plaintext on port 80"
      elif [ "$node_ok" = "0" ] && [ "$cluster_ok" = "1" ]; then
        kit_substrate_out "    - ${h} resolves on node and through cluster DNS (from ${src}) — the two DNS paths disagree; until both agree the Certificate may sit pending"
      else
        kit_substrate_out "    - ${h} resolves (point ${h} at this box; from ${src}) — until then the ACME HTTP-01 self check fails, the Certificate sits pending, and the Ingress serves plaintext on port 80"
      fi
    done <<EOF
$READINESS_TLS_PENDING
EOF
    if [ -n "$READINESS_DNS_SPLIT" ]; then
      kit_substrate_out "    cluster DNS (CoreDNS at 10.43.0.10:53) disagrees with node DNS for: $(printf '%s' "$READINESS_DNS_SPLIT" | tr '\n' ' ' | sed 's/ *$//') — the ACME self check uses the cluster path"
    else
      kit_substrate_out "    cluster DNS (CoreDNS at 10.43.0.10:53) agrees with node DNS: both report no such host for the pending host(s)"
    fi
  fi
  if [ -z "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ]; then
    kit_substrate_out "    - KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER is set (export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='https://<your-issuer>') — until then identity serves no JWKS route, so gateway's /readyz fails and its Deployment never becomes Ready"
  fi
  case "$REGISTRY_PATH" in
    anonymous)
      kit_substrate_out "  registry: every artifact is public; no registry credential was needed" ;;
    capability)
      kit_substrate_out "  registry: at least one artifact is private; the capability exchange was used" ;;
    *)
      kit_substrate_out "  registry: step 5 has not run (no pull secret written by this run)" ;;
  esac
  if [ -z "$READINESS_TLS_PENDING" ] && [ -n "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ]; then
    kit_substrate_out "    (none — every intended host resolves and the OIDC issuer is set)"
    kit_substrate_out "    cluster DNS (CoreDNS at 10.43.0.10:53) agrees with node DNS for every host"
    if [ -n "$OIDC_ROUTE_VERIFIED" ]; then
      kit_substrate_out "    OIDC: this run patched identity-secrets, restarted deployment/identity and watched its JWKS route answer 2xx — the patched surface is serving"
    elif [ -n "$OIDC_SECRET_PATCHED" ]; then
      kit_substrate_out "    OIDC: this run patched identity-secrets but the identity Deployment was not present, so no rollout was watched and the JWKS route is unverified — the next sync boots with the patched secret"
    else
      kit_substrate_out "    OIDC: this run did not verify identity's JWKS route (the secret already carried the OIDC surface, or was freshly created with it) — the issuer is set, but serving was not watched this run"
    fi
  fi
  local store
  store="$(kit_substrate_log_store)"
  if [ "$store" = "journald" ]; then
    kit_substrate_out "  logs: centralized Loki not installed — logs remain in journald / kubectl logs (kubectl -n <ns> logs <pod>); Alloy runs but ships nowhere centrally"
    kit_substrate_out "    reason: loki chart 7.3.0 SimpleScalable requires loki.storage.bucketNames.chunks and an object-storage backend (endpoint/bucket/access_key/secret_key); this substrate provisions no object store"
  else
    kit_substrate_out "  logs: centralized Loki installed — query via Grafana Explore / Loki API"
  fi
}

kit_substrate_readiness_summary() {
  local n
  n="$(kit_substrate_readiness_pending_count)"
  if [ "$n" -eq 0 ]; then
    printf 'readiness: no known unready condition'
  else
    printf 'readiness: %s condition(s) keep this box from fully serving' "$n"
  fi
}

kit_substrate_readiness_json() {
  local hosts_json oidc="false" store split_json cluster_json
  hosts_json="$(printf '%s' "$READINESS_TLS_PENDING" | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  split_json="$(printf '%s' "$READINESS_DNS_SPLIT" | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  cluster_json="$(printf '%s' "$READINESS_DNS_STATUS" | awk -F '\t' '$3==0 && $1!="" {print $1}' | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  if [ -n "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ]; then
    oidc="true"
  fi
  store="$(kit_substrate_log_store)"
  printf ',"tls_pending_hosts":%s,"oidc_configured":%s,"log_store":"%s","dns_split_hosts":%s,"dns_cluster_pending_hosts":%s,"registry_path":%s' "$hosts_json" "$oidc" "$store" "$split_json" "$cluster_json" "$(json_str "$REGISTRY_PATH")"
}


: "${KIT_SUBSTRATE_TRUST_VERIFY_TIMEOUT:=15}"
: "${KIT_SUBSTRATE_TRUST_REFRESH_TIMEOUT:=180}"

if command -v timeout >/dev/null 2>&1; then
  KIT_SUBSTRATE_TIMEOUT_BIN="$(command -v timeout)"
elif command -v gtimeout >/dev/null 2>&1; then
  KIT_SUBSTRATE_TIMEOUT_BIN="$(command -v gtimeout)"
else
  KIT_SUBSTRATE_TIMEOUT_BIN=""
fi

TLS_VERIFY_ERROR=""
TLS_VERIFY_REACHED="no"
TRUST_REFRESH_NOTE=""

kit_substrate_run_bounded() {
  local secs="$1"
  shift
  if [ -n "$KIT_SUBSTRATE_TIMEOUT_BIN" ]; then
    "$KIT_SUBSTRATE_TIMEOUT_BIN" "$secs" "$@"
  else
    "$@"
  fi
}

kit_substrate_tls_verify() {
  local url="$1" rest scheme host port out ec=0
  TLS_VERIFY_ERROR=""
  rest="${url#*://}"
  scheme="${url%%://*}"
  host="${rest%%/*}"
  port=""
  case "$host" in
    *:*) port="${host##*:}"; host="${host%:*}" ;;
  esac
  [ -n "$host" ] || { TLS_VERIFY_ERROR="empty host in origin ${url}"; return 1; }
  if [ -z "$port" ]; then
    case "$scheme" in
      http) port=80 ;;
      *) port=443 ;;
    esac
  fi
  out="$(kit_substrate_run_bounded "$KIT_SUBSTRATE_TRUST_VERIFY_TIMEOUT" \
    openssl s_client -verify_return_error -connect "${host}:${port}" \
    -servername "$host" </dev/null 2>&1)" || ec=$?
  case "$out" in
    *"Verify return code:"*) TLS_VERIFY_REACHED="yes" ;;
    *) TLS_VERIFY_REACHED="no" ;;
  esac
  if [ "$ec" -eq 0 ]; then
    return 0
  fi
  TLS_VERIFY_ERROR="$(printf '%s\n' "$out" | sed -n 's/^Verify return code: //p' | head -n1 | cut -c1-200)"
  [ -n "$TLS_VERIFY_ERROR" ] || TLS_VERIFY_ERROR="$(printf '%s\n' "$out" | sed -n 's/^ *verify error: //p' | head -n1 | cut -c1-200)"
  [ -n "$TLS_VERIFY_ERROR" ] || TLS_VERIFY_ERROR="$(printf '%s\n' "$out" | grep -iE 'error|refused|no route|nodename|unreachable' | head -n1 | cut -c1-200)"
  [ -n "$TLS_VERIFY_ERROR" ] || TLS_VERIFY_ERROR="$(printf '%s\n' "$out" | grep -m1 . | cut -c1-200)"
  [ -n "$TLS_VERIFY_ERROR" ] || TLS_VERIFY_ERROR="(openssl produced no diagnostic)"
  return 1
}

kit_substrate_refresh_trust_store() {
  local ec=0
  TRUST_REFRESH_NOTE=""
  if command -v apt-get >/dev/null 2>&1; then
    if dry_run "apt-get update && apt-get install -y --reinstall ca-certificates && update-ca-certificates --fresh"; then
      TRUST_REFRESH_NOTE="DRY_RUN: would run apt-get update, apt-get install -y --reinstall ca-certificates and update-ca-certificates --fresh"
      return 0
    fi
    kit_substrate_run_bounded "$KIT_SUBSTRATE_TRUST_REFRESH_TIMEOUT" apt-get update >/dev/null 2>&1 ||
      ec=$?
    if [ "$ec" -ne 0 ]; then
      TRUST_REFRESH_NOTE="apt-get update exited ${ec} — the package lists could not be refreshed (network or apt lock)"
    fi
    kit_substrate_run_bounded "$KIT_SUBSTRATE_TRUST_REFRESH_TIMEOUT" apt-get install -y --reinstall ca-certificates >/dev/null 2>&1 ||
      ec=$?
    if [ "$ec" -ne 0 ] && [ -z "$TRUST_REFRESH_NOTE" ]; then
      TRUST_REFRESH_NOTE="apt-get install -y --reinstall ca-certificates exited ${ec}"
    fi
    if command -v update-ca-certificates >/dev/null 2>&1; then
      kit_substrate_run_bounded "$KIT_SUBSTRATE_TRUST_REFRESH_TIMEOUT" update-ca-certificates --fresh >/dev/null 2>&1 ||
        ec=$?
      if [ "$ec" -ne 0 ] && [ -z "$TRUST_REFRESH_NOTE" ]; then
        TRUST_REFRESH_NOTE="update-ca-certificates --fresh exited ${ec}"
      fi
    else
      TRUST_REFRESH_NOTE="apt-get removed the trust bundle, but update-ca-certificates is not on PATH so no bundle was rebuilt"
    fi
    return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    if dry_run "dnf -y reinstall ca-certificates && update-ca-trust"; then
      TRUST_REFRESH_NOTE="DRY_RUN: would run dnf -y reinstall ca-certificates and update-ca-trust"
      return 0
    fi
    kit_substrate_run_bounded "$KIT_SUBSTRATE_TRUST_REFRESH_TIMEOUT" dnf -y reinstall ca-certificates >/dev/null 2>&1 ||
      ec=$?
    if [ "$ec" -ne 0 ]; then
      TRUST_REFRESH_NOTE="dnf -y reinstall ca-certificates exited ${ec}"
    fi
    if command -v update-ca-trust >/dev/null 2>&1; then
      kit_substrate_run_bounded "$KIT_SUBSTRATE_TRUST_REFRESH_TIMEOUT" update-ca-trust >/dev/null 2>&1 ||
        ec=$?
      if [ "$ec" -ne 0 ] && [ -z "$TRUST_REFRESH_NOTE" ]; then
        TRUST_REFRESH_NOTE="update-ca-trust exited ${ec}"
      fi
    fi
    return 0
  fi
  if command -v apk >/dev/null 2>&1; then
    if dry_run "apk add --no-cache ca-certificates"; then
      TRUST_REFRESH_NOTE="DRY_RUN: would run apk add --no-cache ca-certificates"
      return 0
    fi
    kit_substrate_run_bounded "$KIT_SUBSTRATE_TRUST_REFRESH_TIMEOUT" apk add --no-cache ca-certificates >/dev/null 2>&1 ||
      ec=$?
    if [ "$ec" -ne 0 ]; then
      TRUST_REFRESH_NOTE="apk add --no-cache ca-certificates exited ${ec}"
    fi
    return 0
  fi
  TRUST_REFRESH_NOTE="no package manager on PATH (no apt-get, dnf or apk), so the trust store could not be refreshed"
  return 1
}

kit_substrate_trust_preflight() {
  if [ "$DRY_RUN" -eq 1 ]; then
    kit_substrate_emit step.plan "verify the TLS chain of KIT_SUBSTRATE_BOX_URL and KIT_SUBSTRATE_REGISTRY_URL against the system trust store, refreshing ca-certificates only if a chain does not verify"
    return 0
  fi
  local url err
  for url in "$KIT_SUBSTRATE_BOX_URL" "$KIT_SUBSTRATE_REGISTRY_URL"; do
    [ -n "$url" ] || continue
    case "$url" in
      http://*)
        kit_substrate_out "    ${url} is plaintext http — no TLS chain to verify against the system trust store"
        continue
        ;;
    esac
    if kit_substrate_tls_verify "$url"; then
      kit_substrate_out "    TLS chain verified against the system trust store: ${url}"
      continue
    fi
    err="$TLS_VERIFY_ERROR"
    if [ "$TLS_VERIFY_REACHED" != "yes" ]; then
      kit_substrate_refuse "" \
        "check ${url} is reachable from this box (name resolves, port answers, no egress firewall), then re-run this installer" \
        "the box could not complete a TLS handshake with ${url}: ${err} — the origin did not answer, so no certificate chain was verified; this is reachability, not the trust store"
    fi
    kit_substrate_out "    TLS chain NOT verifiable: ${url} — ${err}"
    kit_substrate_out "    refreshing the system trust store and re-checking (a stale or trimmed store is the live-box failure this ends)"
    kit_substrate_refresh_trust_store || true
    if kit_substrate_tls_verify "$url"; then
      kit_substrate_out "    trust store refreshed: ${url} now verifies against the system store"
      continue
    fi
    err="$TLS_VERIFY_ERROR"
    local remedy_note=""
    [ -n "$TRUST_REFRESH_NOTE" ] && remedy_note=" The refresh was attempted and did not fix it — ${TRUST_REFRESH_NOTE}."
    kit_substrate_refuse "" \
      "on the box run: apt-get update && apt-get install -y --reinstall ca-certificates && update-ca-certificates --fresh  (dnf: dnf -y reinstall ca-certificates && update-ca-trust), then re-run this installer" \
      "the box cannot verify the TLS chain of ${url}: ${err} — the OS trust store is stale or trimmed, so every client that uses it (cafe boxd included) fails with 'x509: certificate signed by unknown authority'.${remedy_note}"
  done
}

preflight() {
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$CLUSTER_SUPPLIED" -eq 1 ]; then
      kit_substrate_emit progress "DRY_RUN: would check curl, openssl, jq, the kubeconfig's readability, cluster reachability, registry reachability"
    else
      kit_substrate_emit progress "DRY_RUN: would check root, curl, openssl, jq, Linux, arch, memory, registry reachability"
    fi
    return 0
  fi

  if [ "$CLUSTER_SUPPLIED" -eq 1 ]; then
    if [ ! -r "$KIT_SUBSTRATE_KUBECONFIG" ]; then
      kit_substrate_refuse "KIT_SUBSTRATE_KUBECONFIG" \
        "export KIT_SUBSTRATE_KUBECONFIG='</path/to/kubeconfig>' — the file must be readable by this process" \
        "KIT_SUBSTRATE_KUBECONFIG names a file that is not readable: ${KIT_SUBSTRATE_KUBECONFIG}"
    fi
    if ! kubectl --kubeconfig="$KUBECONFIG" get namespaces >/dev/null 2>&1; then
      kit_substrate_refuse "KIT_SUBSTRATE_KUBECONFIG" \
        "check the cluster behind that kubeconfig is up and reachable, then re-run" \
        "the cluster at KIT_SUBSTRATE_KUBECONFIG does not answer a namespace listing — the substrate cannot be installed into it"
    fi
  else
    if [ "$(id -u)" -ne 0 ]; then
      kit_substrate_refuse "" "run as root — k3s installs to /usr/local and writes the kubeconfig" "must run as root — k3s installs to /usr/local and writes the kubeconfig"
    fi

    if [ "$(uname -s)" != "Linux" ]; then
      kit_substrate_refuse "" "this script installs k3s, which needs Linux" "this script installs k3s, which needs Linux (found $(uname -s))"
    fi

    local arch
    arch="$(uname -m)"
    case "$arch" in
      x86_64 | aarch64) ;;
      *)
        kit_substrate_refuse "" "k3s supports x86_64 and aarch64" "unsupported architecture '$arch' — k3s supports x86_64 and aarch64"
        ;;
    esac

    local mem_kb
    mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    if [ "$mem_kb" -lt 4194304 ]; then
      kit_substrate_refuse "" "DEPLOYMENT.md sizes the box: 8GB comfortable, 4GB no longer qualifies once the Grafana stack lands" "${mem_kb} kB RAM — 4GB no longer qualifies once the Grafana stack lands (DEPLOYMENT.md)"
    fi
    if [ "$mem_kb" -lt 8388608 ]; then
      echo "warning: ${mem_kb} kB RAM — 8GB is comfortable for the full stack" >&2
    fi
  fi

  if ! command -v curl >/dev/null 2>&1; then
    kit_substrate_refuse "" "install curl — every component is fetched over HTTPS" "curl is required — every component is fetched over HTTPS"
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    kit_substrate_refuse "" "install openssl — identity's OIDC signing key is generated on this box rather than supplied" "openssl is required — identity's OIDC signing key is generated on this box rather than supplied"
  fi

  if ! command -v jq >/dev/null 2>&1; then
    kit_substrate_refuse "" "install jq — step 12 reads the minted credential out of identity's response" "jq is required — step 12 reads the minted credential out of identity's response"
  fi


  if ! curl -s --max-time 10 -o /dev/null https://ghcr.io/v2/; then
    kit_substrate_refuse "" "check network access to ghcr.io — the pull secret and charts come from there" "ghcr.io is unreachable — the pull secret and charts come from there"
  fi
}

: "${NODE_REGISTER_TIMEOUT:=90}"
: "${NODE_READY_TIMEOUT:=30}"
: "${OPERATOR_IMAGE_PULL_TIMEOUT:=300}"
: "${CERT_MANAGER_READY_TIMEOUT:=180}"
: "${CNPG_READY_TIMEOUT:=180}"
: "${ARGOCD_READY_TIMEOUT:=300}"
install_k3s() {
  log_step "k3s ${K3S_VERSION} — single node, sqlite datastore"
  if kit_substrate_guard k3s; then
    if [ "$CLUSTER_SUPPLIED" -eq 1 ]; then
      kit_substrate_out "      the cluster at KIT_SUBSTRATE_KUBECONFIG already has a Node; the host's k3s is not installed and nothing here installs it"
    else
      kit_substrate_out "      already installed, skipping"
    fi
    return 0
  fi
  if dry_run "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${K3S_VERSION} sh -"; then
    return 0
  fi
  if [ "$CLUSTER_SUPPLIED" -eq 1 ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_KUBECONFIG" \
      "point it at a cluster with at least one Node — a supplied cluster is never provisioned by this script" \
      "the cluster at KIT_SUBSTRATE_KUBECONFIG has no Node — the substrate installs into a running cluster, it does not create one"
  fi
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -
  kit_substrate_await_list "$NODE_REGISTER_TIMEOUT" node
  kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Ready node --all --timeout="$((NODE_READY_TIMEOUT))s"
}

install_cert_manager() {
  log_step "cert-manager ${CERT_MANAGER_VERSION}"
  if kit_substrate_guard cert-manager; then
    kit_substrate_out "      already installed, skipping"
    return 0
  fi
  if dry_run "kubectl apply --server-side=true --force-conflicts -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"; then
    return 0
  fi
  kubectl --kubeconfig="$KUBECONFIG" apply --server-side=true --force-conflicts -f \
    "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  kit_substrate_pending cert-manager
}

install_cnpg() {
  log_step "CloudNativePG ${CNPG_VERSION}"
  if kit_substrate_guard cloudnative-pg; then
    kit_substrate_out "      already installed, skipping"
    return 0
  fi
  if dry_run "kubectl apply --server-side=true --force-conflicts -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_VERSION}/releases/cnpg-${CNPG_VERSION#v}.yaml"; then
    return 0
  fi
  kubectl --kubeconfig="$KUBECONFIG" apply --server-side=true --force-conflicts -f \
    "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_VERSION}/releases/cnpg-${CNPG_VERSION#v}.yaml"
  kit_substrate_pending cnpg
}

install_argocd() {
  log_step "Argo CD core ${ARGOCD_VERSION}"
  local argocd_present=0
  if kit_substrate_guard argocd; then
    kit_substrate_out "      already installed, skipping"
    argocd_present=1
  fi
  if [ "$argocd_present" -eq 0 ]; then
    if ! dry_run "kubectl apply -n argocd --server-side=true --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/core-install.yaml (the Argo CD core manifest)"; then
      kubectl --kubeconfig="$KUBECONFIG" create namespace argocd --dry-run=client -o yaml |
        kubectl --kubeconfig="$KUBECONFIG" apply -f -
      kubectl --kubeconfig="$KUBECONFIG" apply -n argocd --server-side=true --force-conflicts -f \
        "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/core-install.yaml"
      kit_substrate_pending argocd
    fi
  fi

  local pending waited=0
  for pending in $PENDING_WAITS; do
    case "$pending" in
      cert-manager)
        kit_substrate_await_pods_running "cert-manager" "" "$OPERATOR_IMAGE_PULL_TIMEOUT"
        kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment -n cert-manager --all --timeout="${CERT_MANAGER_READY_TIMEOUT}s"
        waited=1
        ;;
      cnpg)
        kit_substrate_await_pods_running "cnpg-system" "cnpg-controller-manager" "$OPERATOR_IMAGE_PULL_TIMEOUT"
        kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment -n cnpg-system cnpg-controller-manager --timeout="${CNPG_READY_TIMEOUT}s"
        waited=1
        ;;
      argocd)
        kit_substrate_await_pods_running "argocd" "" "$OPERATOR_IMAGE_PULL_TIMEOUT"
        kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment -n argocd --all --timeout="${ARGOCD_READY_TIMEOUT}s"
        waited=1
        ;;
    esac
  done
  PENDING_WAITS=""
  if [ "$waited" -eq 1 ]; then
    STEP_SKIPPED=0
  fi

  if dry_run "kubectl apply -f ${ARGOCD_MANIFEST_DIR}/appproject.yaml (the default AppProject the Applications name)"; then
    return 0
  fi
  kit_substrate_check_manifest_dir "$ARGOCD_MANIFEST_DIR"
  kubectl --kubeconfig="$KUBECONFIG" apply -f "$ARGOCD_MANIFEST_DIR/appproject.yaml"
  STEP_SKIPPED=0
}


: "${KIT_SUBSTRATE_REGISTRY_URL:=https://registry.svc.anywaye.com}"

REGISTRY_PULL_NAMESPACES=(argocd identity gateway courier parlor billing observability)
REGISTRY_PULL_SECRET_NAME="ghcr-pull-secret"

REGISTRY_CREDENTIAL_MIN_SECONDS=60

: "${KIT_SUBSTRATE_REGISTRY_PROBE_TIMEOUT:=10}"

REGISTRY_PRIVATE_ARTIFACTS=""
REGISTRY_PATH=""

registry_derived_artifacts() {
  local f repo rev name
  for f in "$MANIFEST_DIR"/*.yaml; do
    [ -f "$f" ] || continue
    repo="$(sed -n 's/^[[:space:]]*repoURL:[[:space:]]*oci:\/\/ghcr.io\///p' "$f" | head -1)"
    [ -n "$repo" ] || continue
    rev="$(sed -n 's/^[[:space:]]*targetRevision:[[:space:]]*//p' "$f" | head -1)"
    [ -n "$rev" ] || continue
    printf '%s %s\n' "$repo" "$rev"
    case "$repo" in
      anywaye/charts/*)
        name="${repo#anywaye/charts/}"
        printf 'anywaye/%s %s\n' "$name" "$rev"
        ;;
    esac
  done
}

registry_probe_artifact() {
  local repo="$1" ref="$2" tok probe_token code
  tok="$(curl -s --max-time "$KIT_SUBSTRATE_REGISTRY_PROBE_TIMEOUT" --connect-timeout 5 \
    "https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io" 2>/dev/null)" || return 1
  probe_token="$(printf '%s' "$tok" | jq -r '.token // empty' 2>/dev/null)" || return 1
  [ -n "$probe_token" ] || return 1
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$KIT_SUBSTRATE_REGISTRY_PROBE_TIMEOUT" --connect-timeout 5 \
    -H "Authorization: Bearer ${probe_token}" \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    -I "https://ghcr.io/v2/${repo}/manifests/${ref}" 2>/dev/null)" || return 1
  case "$code" in
    2*) return 0 ;;
    *) return 1 ;;
  esac
}

registry_probe_artifacts() {
  local repo="" ref="" probed=0 private=""
  while read -r repo ref; do
    [ -n "$repo" ] && [ -n "$ref" ] || continue
    probed=$((probed + 1))
    if registry_probe_artifact "$repo" "$ref"; then
      kit_substrate_out "      public: ${repo}:${ref} (anonymous fetch)"
    else
      kit_substrate_out "      private: ${repo}:${ref} (anonymous fetch refused)"
      private="${private}${repo}:${ref}
"
    fi
  done <<EOF
$(registry_derived_artifacts)
EOF
  REGISTRY_PRIVATE_ARTIFACTS="$private"
  if [ "$probed" -eq 0 ]; then
    kit_substrate_refuse "" "restore ${MANIFEST_DIR}'s manifests — step 5 derives its artifact list from them" "the registry probe listed no artifacts — refusing rather than installing on an unmeasured claim"
  fi
}

registry_capability_shape_ok() {
  [[ "${1:-}" =~ ^cap_[0-9a-f]{64}$ ]]
}

exchange_registry_credential() {
  local need_line=""
  if [ -n "$REGISTRY_PRIVATE_ARTIFACTS" ]; then
    need_line=" — this install pulls private artifact(s) needing a credential: $(printf '%s' "$REGISTRY_PRIVATE_ARTIFACTS" | tr '\n' ' ' | sed 's/ *$//')"
  fi
  if [ -z "$KIT_SUBSTRATE_BOX_ID" ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_BOX_ID" "export KIT_SUBSTRATE_BOX_ID='<the enrolled uuid of this box>' and re-run — the box's own identity, and what the registry capability is bound to" "KIT_SUBSTRATE_BOX_ID is not set
  export KIT_SUBSTRATE_BOX_ID='<the enrolled uuid of this box>'
  fi
  if ! registry_capability_shape_ok "$KIT_SUBSTRATE_REGISTRY_CAPABILITY"; then
    kit_substrate_refuse "KIT_SUBSTRATE_REGISTRY_CAPABILITY" "re-run 'cafe box enroll' and pass the capability it prints — a dockerconfigjson belongs in the OLD runbook: it is exchanged, not pasted" "KIT_SUBSTRATE_REGISTRY_CAPABILITY is not a minted capability
  export KIT_SUBSTRATE_REGISTRY_CAPABILITY='<cap_… from cafe box enroll>'
  fi
  local raw http_status body encoded expires seconds
  raw="$(curl -sS -X POST \
    -H "Authorization: Bearer ${KIT_SUBSTRATE_REGISTRY_CAPABILITY}" \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg box_id "$KIT_SUBSTRATE_BOX_ID" '{box_id: $box_id}')" \
    -w '\n%{http_code}' \
    "${KIT_SUBSTRATE_REGISTRY_URL}/v1/registry-credentials" 2>/dev/null)" || raw=""
  if [ -z "$raw" ]; then
    kit_substrate_refuse "" "check that the registry exchange is reachable at ${KIT_SUBSTRATE_REGISTRY_URL} and re-run 'cafe box enroll' (the capability lives minutes)" "the registry exchange did not answer — the capability was not spent
  check ${KIT_SUBSTRATE_REGISTRY_URL} is reachable, and re-run 'cafe box enroll' for a fresh capability"
  fi
  http_status="$(printf '%s' "$raw" | tail -n 1)"
  body="$(printf '%s' "$raw" | sed '$d')"
  case "$http_status" in
    2*) ;;
    *)
      local refusal_code refusal_message upstream_status
      refusal_code="$(printf '%s' "$body" | jq -r '.error.code // empty' 2>/dev/null || true)"
      refusal_message="$(printf '%s' "$body" | jq -r '.error.message // empty' 2>/dev/null || true)"
      upstream_status="${refusal_code:-unspecified}"
      kit_substrate_refuse "KIT_SUBSTRATE_REGISTRY_CAPABILITY" "re-run 'cafe box enroll' and pass the capability it prints (it lives minutes) — the exchange refused it with ${upstream_status}" "the registry exchange refused this box's capability (${upstream_status})
  ${refusal_message:-no reason given}
  re-run 'cafe box enroll' and pass the capability it prints (it lives minutes)"
      ;;
  esac
  encoded="$(printf '%s' "$body" | jq -r '.dockerconfigjson // empty' 2>/dev/null || true)"
  expires="$(printf '%s' "$body" | jq -r '.expires_at // empty' 2>/dev/null || true)"
  seconds="$(printf '%s' "$body" | jq -r '.seconds_remaining // empty' 2>/dev/null || true)"
  if [ -z "$encoded" ]; then
    kit_substrate_refuse "" "" "the registry exchange answered ${http_status} but carried no dockerconfigjson"
  fi
  if [ -z "$expires" ]; then
    kit_substrate_refuse "" "" "the registry exchange carried no expires_at for the credential it minted"
  fi
  if ! printf '%s' "$encoded" | base64 -d 2>/dev/null | jq -e '.auths["ghcr.io"].username' >/dev/null 2>&1; then
    kit_substrate_refuse "" "" "the dockerconfigjson the registry exchange returned is not a ghcr.io credential — refused rather than written"
  fi
  if ! [[ "$seconds" =~ ^[0-9]+$ ]] || [ "$seconds" -lt "$REGISTRY_CREDENTIAL_MIN_SECONDS" ]; then
    kit_substrate_refuse "" "re-run this installer — the exchange mints a fresh credential with a full hour of life" "the minted credential has ${seconds:-no} seconds of life left (less than ${REGISTRY_CREDENTIAL_MIN_SECONDS})
  a credential that expires mid-pull fails at image-pull time"
  fi
  if [ -n "$expires" ] && [[ ! "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
    kit_substrate_refuse "" "" "the minted credential's expires_at '${expires}' is not an instant this installer can read"
  fi
  if [ -n "$expires" ] && [ "${#expires}" -eq 20 ] && [[ "$expires" < "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]]; then
    kit_substrate_refuse "" "re-run this installer — the exchange mints a fresh credential" "the minted credential's expires_at '${expires}' is already past"
  fi
  REGISTRY_DOCKERCONFIGJSON="$encoded"
}

apply_pull_secret() {
  local ns
  for ns in "${REGISTRY_PULL_NAMESPACES[@]}"; do
    if ! kubectl --kubeconfig="$KUBECONFIG" create namespace "$ns" --dry-run=client -o yaml |
      kubectl --kubeconfig="$KUBECONFIG" apply -f - >/dev/null; then
      REGISTRY_DOCKERCONFIGJSON=""
      kit_substrate_refuse "" "check that the k3s cluster is reachable from this box and that no admission policy refuses namespace creation, then re-run — the pull secret cannot be written into a namespace that does not exist" "the namespace ${ns} could not be created, so the image pull secret cannot be written into it — every pod scheduled into ${ns} would fail to pull"
    fi
    if kubectl --kubeconfig="$KUBECONFIG" get secret "$REGISTRY_PULL_SECRET_NAME" -n "$ns" >/dev/null 2>&1; then
      kit_substrate_out "      secret ${REGISTRY_PULL_SECRET_NAME} exists in ${ns} — replacing it (the credential is minutes-lived by design; a fresh exchange buys a fresh one)"
    else
      kit_substrate_out "      secret ${REGISTRY_PULL_SECRET_NAME} to be created in ${ns}"
    fi
    printf '%s' "$REGISTRY_DOCKERCONFIGJSON" | base64 -d |
      kubectl --kubeconfig="$KUBECONFIG" create secret docker-registry "$REGISTRY_PULL_SECRET_NAME" -n "$ns"       --from-file=.dockerconfigjson=/dev/stdin --dry-run=client -o yaml |
      kubectl --kubeconfig="$KUBECONFIG" apply -f - >/dev/null
  done
  REGISTRY_DOCKERCONFIGJSON=""
}

install_pull_secret() {
  local private_count=0
  log_step "the GHCR image pull secret (anonymous where every artifact is public, exchanged where one is not)"
  if dry_run "probe every GHCR chart and image the Applications name for anonymous fetch; where all answer, write an empty-auths pull secret, else exchange the registry capability at ${KIT_SUBSTRATE_REGISTRY_URL}/v1/registry-credentials; ensure each of ${REGISTRY_PULL_NAMESPACES[*]} exists, and apply ${REGISTRY_PULL_SECRET_NAME} in it"; then
    return 0
  fi
  registry_probe_artifacts
  if [ -z "$REGISTRY_PRIVATE_ARTIFACTS" ]; then
    REGISTRY_PATH="anonymous"
    REGISTRY_DOCKERCONFIGJSON="$(printf '{"auths":{}}' | base64 | tr -d '\n')"
    apply_pull_secret
    kit_substrate_out "      every artifact is public; no registry credential was needed"
  else
    REGISTRY_PATH="capability"
    private_count="$(printf '%s' "$REGISTRY_PRIVATE_ARTIFACTS" | grep -c .)"
    exchange_registry_credential
    apply_pull_secret
    kit_substrate_out "      ${private_count} artifact(s) are private; the capability exchange was used"
  fi
}

KIT_MANIFEST_FILES=()

kit_substrate_check_manifest_dir() {
  local dir="$1" entry base
  local -a unexpected=() sidecars=()
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$entry" ] || continue
    base="${entry##*/}"
    case "$base" in
      ._*)
        sidecars+=("$base")
        continue
        ;;
    esac
    if [ -f "$entry" ]; then
      case "$base" in
        *.yaml) continue ;;
      esac
    fi
    unexpected+=("$base")
  done
  if [ "${#sidecars[@]}" -gt 0 ]; then
    kit_substrate_out "      ignoring AppleDouble sidecar(s) in ${dir}: ${sidecars[*]} (macOS tar/cp debris, not manifests)"
  fi
  if [ "${#unexpected[@]}" -gt 0 ]; then
    kit_substrate_refuse "" \
      "remove it from ${dir}, or record the convention — a manifest directory holds only its *.yaml manifests" \
      "${dir} holds unexpected entries: ${unexpected[*]}"
  fi
}

kit_substrate_manifest_files() {
  local dir="$1" f
  KIT_MANIFEST_FILES=()
  kit_substrate_check_manifest_dir "$dir"
  for f in "$dir"/*.yaml; do
    [ -f "$f" ] || continue
    KIT_MANIFEST_FILES+=("$f")
  done
  if [ "${#KIT_MANIFEST_FILES[@]}" -eq 0 ]; then
    kit_substrate_refuse "" "restore ${dir}'s manifests" "${dir} holds no *.yaml manifests — refusing to apply nothing"
  fi
}

install_applications() {
  log_step "the first Applications (identity, gateway, courier, parlor, billing, observability)"
  if dry_run "kubectl apply -f ${MANIFEST_DIR}"; then
    return 0
  fi
  kit_substrate_manifest_files "$MANIFEST_DIR"
  local -a apply_args=()
  local f
  for f in "${KIT_MANIFEST_FILES[@]}"; do apply_args+=(-f "$f"); done
  kubectl --kubeconfig="$KUBECONFIG" apply "${apply_args[@]}"
}

install_cluster_issuers() {
  log_step "the Let's Encrypt ClusterIssuers (staging + prod, from KIT_SUBSTRATE_ACME_EMAIL)"
  if kit_substrate_guard clusterissuer; then
    kit_substrate_out "      already installed, skipping"
    return 0
  fi
  if dry_run "substitute the ACME email and apply ${TLS_DIR} (letsencrypt-staging, letsencrypt-prod)"; then
    return 0
  fi
  if [ -z "$KIT_SUBSTRATE_ACME_EMAIL" ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_ACME_EMAIL" \
      "export KIT_SUBSTRATE_ACME_EMAIL='<your-address@example.com>' on the box and re-run" \
      "KIT_SUBSTRATE_ACME_EMAIL is not set"
  fi
  local ats local_part domain_part
  ats="${KIT_SUBSTRATE_ACME_EMAIL//[^@]/}"
  local_part="${KIT_SUBSTRATE_ACME_EMAIL%%@*}"
  domain_part="${KIT_SUBSTRATE_ACME_EMAIL##*@}"
  if [ "${#ats}" -ne 1 ] || [ -z "$local_part" ] || [ -z "$domain_part" ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_ACME_EMAIL" \
      "export KIT_SUBSTRATE_ACME_EMAIL='<your-address@example.com>' on the box and re-run" \
      "KIT_SUBSTRATE_ACME_EMAIL must be an email address — exactly one '@', with something on either side"
  fi
  case "$domain_part" in
    example.com | example.org | example.net)
      kit_substrate_refuse "KIT_SUBSTRATE_ACME_EMAIL" \
        "export KIT_SUBSTRATE_ACME_EMAIL='<your-address@example.com>' on the box and re-run" \
        "KIT_SUBSTRATE_ACME_EMAIL is a $domain_part address — it must be real; Let's Encrypt sends expiry notices to it"
      ;;
  esac
  kit_substrate_manifest_files "$TLS_DIR"
  sed "s/ACME_EMAIL_PLACEHOLDER/$KIT_SUBSTRATE_ACME_EMAIL/" "${KIT_MANIFEST_FILES[@]}" |
    kubectl --kubeconfig="$KUBECONFIG" apply -f -
  kit_substrate_out "      applied letsencrypt-staging and letsencrypt-prod"
}

create_postgres_role_secrets() {
  local svc role secret_name pw
  for svc in identity gateway courier parlor billing; do
    for role in "$svc" "${svc}_app"; do
      case "$role" in
        *_app) secret_name="postgres-role-$svc-app" ;;
        *) secret_name="postgres-role-$svc" ;;
      esac
      if kubectl --kubeconfig="$KUBECONFIG" get secret "$secret_name" -n data >/dev/null 2>&1; then
        kubectl --kubeconfig="$KUBECONFIG" -n data patch secret "$secret_name" \
          --type=merge --patch-file=/dev/stdin >/dev/null <<JSON
{"stringData":{"username":"$role"}}
JSON
        kit_substrate_out "      secret $secret_name exists, keeping its password (never regenerated, never printed)"
      else
        pw="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        kubectl --kubeconfig="$KUBECONFIG" create secret generic "$secret_name" -n data \
          --from-literal=username="$role" --from-literal=password="$pw" >/dev/null
        kit_substrate_out "      secret $secret_name created (generated once — a re-run reads it back)"
      fi
    done
  done
}

cnpg_cluster_phase() {
  kubectl --kubeconfig="$KUBECONFIG" get cluster.postgresql.cnpg.io postgres -n data \
    -o jsonpath='{.status.phase}' 2>/dev/null || true
}

: "${CNPG_CLUSTER_READY_TIMEOUT:=600}"
install_postgres_cluster() {
  log_step "the Postgres Cluster (from KIT_SUBSTRATE_DATABASES, in the data namespace)"
  if [ -z "$KIT_SUBSTRATE_DATABASES" ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_DATABASES" \
      "export KIT_SUBSTRATE_DATABASES='identity,gateway,courier,parlor,billing' on the box and re-run" \
      "KIT_SUBSTRATE_DATABASES is not set"
  fi
  local want have
  want="$(grep -oE 'CREATE DATABASE "[a-z_]+"' "$DATA_DIR/postgres-cluster.yaml" | sed -E 's/.*"(.*)"/\1/' | sort -u | tr '\n' ',' )"
  have="$(printf '%s' "$KIT_SUBSTRATE_DATABASES" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | sort -u | tr '\n' ',')"
  if [ -z "$have" ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_DATABASES" \
      "export KIT_SUBSTRATE_DATABASES='identity,gateway,courier,parlor,billing' on the box and re-run" \
      "KIT_SUBSTRATE_DATABASES names no services (empty after trimming)"
  fi
  if [ "$want" != "$have" ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_DATABASES" \
      "export KIT_SUBSTRATE_DATABASES='identity,gateway,courier,parlor,billing' on the box and re-run — it must equal the service set manifests/data/postgres-cluster.yaml provisions" \
      "KIT_SUBSTRATE_DATABASES does not match the Cluster manifest (it provisions: ${want%,})"
  fi
  local ext ext_list
  IFS=',' read -r -a ext_list <<<"$KIT_SUBSTRATE_POSTGRES_EXTENSIONS"
  for ext in "${ext_list[@]}"; do
    if ! printf '%s' "$ext" | LC_ALL=C grep -q '^[a-z_][a-z0-9_]*$'; then
      kit_substrate_refuse "KIT_SUBSTRATE_POSTGRES_EXTENSIONS" \
        "export KIT_SUBSTRATE_POSTGRES_EXTENSIONS='vector' on the box and re-run" \
        "'$ext' in KIT_SUBSTRATE_POSTGRES_EXTENSIONS is not a bare identifier ([a-z_][a-z0-9_]*)"
    fi
  done
  if dry_run "create namespace data, create 10 postgres-role-* password secrets (generated once), apply ${DATA_DIR}/postgres-cluster.yaml"; then
    return 0
  fi
  kubectl --kubeconfig="$KUBECONFIG" create namespace data --dry-run=client -o yaml |
    kubectl --kubeconfig="$KUBECONFIG" apply -f -
  create_postgres_role_secrets
  if kit_substrate_guard cluster; then
    kit_substrate_out "      already installed, skipping"
    return 0
  fi
  kit_substrate_check_manifest_dir "$DATA_DIR"
  kubectl --kubeconfig="$KUBECONFIG" apply -f "$DATA_DIR/postgres-cluster.yaml"
  if ! kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Ready cluster.postgresql.cnpg.io/postgres -n data --timeout="${CNPG_CLUSTER_READY_TIMEOUT}s"; then
    local cluster_phase
    cluster_phase="$(cnpg_cluster_phase)"
    kit_substrate_refuse "the CNPG Cluster postgres in namespace data" \
      "check the CNPG operator (kubectl -n cnpg-system logs deploy/cnpg-controller-manager) and the Cluster's phase, then re-run — every step that already completed is skipped by its guard" \
      "the Postgres Cluster did not become Ready within ${CNPG_CLUSTER_READY_TIMEOUT}s (phase: '${cluster_phase:-unknown}')"
  fi
}

install_redis_and_secrets() {
  log_step "Redis (single instance) and the services' secrets (identity, gateway, courier, parlor)"
  if kit_substrate_guard redis; then
    kit_substrate_out "      already installed, skipping"
  elif dry_run "create secret redis-password (generated once) and apply ${DATA_DIR}/redis.yaml"; then
    :
  else
    if ! kubectl --kubeconfig="$KUBECONFIG" get secret redis-password -n data >/dev/null 2>&1; then
      kubectl --kubeconfig="$KUBECONFIG" create secret generic redis-password -n data \
        --from-literal=password="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')" >/dev/null
      kit_substrate_out "      secret redis-password created (generated once — a re-run reads it back)"
    else
      kit_substrate_out "      secret redis-password exists, keeping its password (never regenerated, never printed)"
    fi
    kit_substrate_check_manifest_dir "$DATA_DIR"
    kubectl --kubeconfig="$KUBECONFIG" apply -f "$DATA_DIR/redis.yaml"
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment redis -n data --timeout=180s
  fi
  install_service_secrets
}

read_secret_key() {
  kubectl --kubeconfig="$KUBECONFIG" get secret "$2" -n "$1" -o jsonpath="{.data.$3}" 2>/dev/null |
    base64 -d 2>/dev/null || true
}

database_url_for() {
  local pw
  pw="$(read_secret_key data "postgres-role-$1-app" password)"
  if [ -z "$pw" ]; then
    kit_substrate_refuse "run step 8 (the Postgres Cluster) first" \
      "re-run 'cafe box apply --phase 8' on the box, then this step" \
      "secret postgres-role-$1-app is missing in namespace data"
  fi
  if [ "$1" = "courier" ]; then
    printf 'ecto://%s_app:%s@postgres-rw.data.svc.cluster.local:5432/%s' "$1" "$pw" "$1"
  else
    printf 'postgres://%s_app:%s@postgres-rw.data.svc.cluster.local:5432/%s?sslmode=disable' "$1" "$pw" "$1"
  fi
}

owner_database_url_for() {
  local pw
  pw="$(read_secret_key data "postgres-role-$1" password)"
  if [ -z "$pw" ]; then
    kit_substrate_refuse "run step 8 (the Postgres Cluster) first" \
      "re-run 'cafe box apply --phase 8' on the box, then this step" \
      "secret postgres-role-$1 is missing in namespace data"
  fi
  if [ "$1" = "courier" ]; then
    printf 'ecto://%s:%s@postgres-rw.data.svc.cluster.local:5432/%s' "$1" "$pw" "$1"
  else
    printf 'postgres://%s:%s@postgres-rw.data.svc.cluster.local:5432/%s?sslmode=disable' "$1" "$pw" "$1"
  fi
}

oidc_key_id_for() {
  printf 'box-%s' "$(printf '%s' "$1" | openssl dgst -sha256 -hex | sed 's/^.*= *//' | cut -c1-16)"
}

resolve_oidc_signing_key() {
  local stored
  stored="$(read_secret_key identity identity-secrets OIDC_SIGNING_KEY)"
  if [ -n "$stored" ]; then
    OIDC_SIGNING_KEY="$stored"
    stored="$(read_secret_key identity identity-secrets OIDC_SIGNING_KEY_ID)"
    if [ -n "$stored" ]; then
      OIDC_SIGNING_KEY_ID="$stored"
    else
      OIDC_SIGNING_KEY_ID="$(oidc_key_id_for "$OIDC_SIGNING_KEY")"
    fi
    return 0
  fi
  OIDC_SIGNING_KEY="$(openssl genrsa 2048 2>/dev/null)" || {
    echo "error: openssl could not generate identity's OIDC signing key on this box" >&2
    exit 1
  }
  OIDC_SIGNING_KEY_ID="$(oidc_key_id_for "$OIDC_SIGNING_KEY")"
}

resolve_gateway_assertion_key() {
  ASSERTION_SIGNING_KEY="$(read_secret_key gateway gateway-secrets ASSERTION_SIGNING_KEY)"
  if [ -n "$ASSERTION_SIGNING_KEY" ]; then
    return 0
  fi
  ASSERTION_SIGNING_KEY="$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)" || {
    echo "error: openssl could not generate gateway's assertion signing key on this box" >&2
    exit 1
  }
}

reconcile_gateway_assertion_key() {
  local stored
  stored="$(read_secret_key gateway gateway-secrets ASSERTION_SIGNING_KEY)"
  if [ -n "$stored" ]; then
    return 0
  fi
  if ! kubectl --kubeconfig="$KUBECONFIG" get secret gateway-secrets -n gateway >/dev/null 2>&1; then
    return 0
  fi
  resolve_gateway_assertion_key
  printf '%s' "$(jq -nc --arg k "$ASSERTION_SIGNING_KEY" '{"stringData":{"ASSERTION_SIGNING_KEY":$k}}')" |
    kubectl --kubeconfig="$KUBECONFIG" -n gateway patch secret gateway-secrets --type=merge --patch-file=/dev/stdin >/dev/null
  kit_substrate_out "      secret gateway-secrets existed without ASSERTION_SIGNING_KEY — patched it in (gateway's pod mounts this key; without it the mount never resolves)"
}

validate_oidc_login_ui_url() {
  if [ -z "$KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" ]; then
    return 0
  fi
  local url="$KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL"
  local why=""
  case "$url" in
    http://* | https://*) ;;
    *)
      why="its scheme is not http or https"
      ;;
  esac
  if [ -z "$why" ]; then
    local hostpart="${url#*://}"
    case "$hostpart" in
      "" | "/"* | "?"* | "#"* | "@"*)
        why="it has no host, so there is nowhere to send a browser"
        ;;
    esac
  fi
  if [ -z "$why" ]; then
    case "$url" in
      *\?*)
        why="it carries a query"
        ;;
    esac
  fi
  if [ -z "$why" ]; then
    case "$url" in
        why="it carries a fragment, which is not sent to a server"
        ;;
    esac
  fi
  if [ -z "$why" ]; then
    local without_scheme="${url#*://}"
    local host_and_rest="${without_scheme%%/*}"
    host_and_rest="${host_and_rest%%\?*}"
    host_and_rest="${host_and_rest%%\#*}"
    case "$host_and_rest" in
      *@*)
        why="it has a userinfo section, so the host in it is not the host it resolves to"
        ;;
    esac
  fi
  if [ -n "$why" ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" \
      "export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL='https://app.example.com/sign-in/oidc' — an http(s) URL with a host, no query, no fragment and no userinfo — and re-run" \
      "KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL $why"
  fi
}

validate_oidc_all_or_nothing() {
  local has_issuer has_login
  has_issuer=0; [ -n "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ] && has_issuer=1
  has_login=0; [ -n "$KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" ] && has_login=1
  if [ "$has_issuer" -eq 1 ] && [ "$has_login" -eq 0 ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" \
      "export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL='https://app.example.com/sign-in/oidc' — the page that asks a person for their password — and re-run" \
      "KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER is set but KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL is not — the OIDC surface is all-or-nothing (issuer + signing key + id + login UI, or none of them)"
  fi
  if [ "$has_issuer" -eq 0 ] && [ "$has_login" -eq 1 ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" \
      "export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='https://auth.example.com' — the URL identity publishes as its issuer — and re-run, or leave both unset for no OIDC surface" \
      "KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL is set but KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER is not — the OIDC surface is all-or-nothing (issuer + signing key + id + login UI, or none of them)"
  fi
  if [ "$has_login" -eq 1 ]; then
    validate_oidc_login_ui_url
  fi
}

reconcile_oidc_identity_secrets() {
  if [ -z "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ] || [ -z "$KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" ]; then
    return 0
  fi
  if ! kubectl --kubeconfig="$KUBECONFIG" get secret identity-secrets -n identity >/dev/null 2>&1; then
    return 0
  fi
  local stored_issuer stored_login
  stored_issuer="$(read_secret_key identity identity-secrets OIDC_ISSUER)"
  stored_login="$(read_secret_key identity identity-secrets OIDC_LOGIN_UI_URL)"
  if [ -n "$stored_issuer" ] && [ -n "$stored_login" ]; then
    return 0
  fi
  resolve_oidc_signing_key
  local oidc_key="$OIDC_SIGNING_KEY" oidc_key_id="$OIDC_SIGNING_KEY_ID"
  printf '%s' "$(jq -nc --arg issuer "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" --arg key "$oidc_key" --arg kid "$oidc_key_id" --arg login "$KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" '{"stringData":{"OIDC_ISSUER":$issuer,"OIDC_SIGNING_KEY":$key,"OIDC_SIGNING_KEY_ID":$kid,"OIDC_LOGIN_UI_URL":$login}}')" |
    kubectl --kubeconfig="$KUBECONFIG" -n identity patch secret identity-secrets --type=merge --patch-file=/dev/stdin >/dev/null
  kit_substrate_out "      secret identity-secrets existed without OIDC surface — patched in OIDC_ISSUER, OIDC_SIGNING_KEY, OIDC_SIGNING_KEY_ID, OIDC_LOGIN_UI_URL (signing key reused if stored)"
  local got_issuer got_login got_key got_kid
  got_issuer="$(read_secret_key identity identity-secrets OIDC_ISSUER)"
  got_login="$(read_secret_key identity identity-secrets OIDC_LOGIN_UI_URL)"
  got_key="$(read_secret_key identity identity-secrets OIDC_SIGNING_KEY)"
  got_kid="$(read_secret_key identity identity-secrets OIDC_SIGNING_KEY_ID)"
  if [ "$got_issuer" != "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ] || [ "$got_login" != "$KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" ] || [ -z "$got_key" ] || [ -z "$got_kid" ]; then
    echo "error: identity-secrets patch did not round-trip — OIDC keys not readable" >&2
    exit 1
  fi
  OIDC_SECRET_PATCHED=1
  if kubectl --kubeconfig="$KUBECONFIG" get deployment identity -n identity >/dev/null 2>&1; then
    kubectl --kubeconfig="$KUBECONFIG" -n identity rollout restart deployment/identity
    kit_substrate_out "      restarted deployment/identity so the patched OIDC surface reaches the pod (envFrom is read at pod start)"
    kit_substrate_await_list "$IDENTITY_DEPLOY_TIMEOUT" deployment identity -n identity
    if ! kubectl --kubeconfig="$KUBECONFIG" -n identity rollout status deployment/identity --timeout="$((IDENTITY_ROLLOUT_TIMEOUT))s"; then
      echo "error: deployment/identity did not roll out after the OIDC patch — the JWKS route is unverified, re-run once the Deployment is healthy" >&2
      exit 1
    fi
    verify_oidc_jwks_route || exit 1
  else
    kit_substrate_out "      identity Deployment not present — restart skipped (the secret is already converged; the next sync boots with the patched secret, and the JWKS route is unverified by this run)"
  fi
}

verify_oidc_jwks_route() {
  local forward_port="${KIT_SUBSTRATE_IDENTITY_LOCAL_PORT:-18080}"
  kubectl --kubeconfig="$KUBECONFIG" -n identity port-forward "svc/identity" "${forward_port}:8080" >/dev/null 2>&1 &
  local forward_pid=$!
  trap 'kill "$forward_pid" 2>/dev/null || true; trap - RETURN' RETURN
  if ! kit_substrate_await_port "$forward_port" 30; then
    echo "error: the port-forward to svc/identity never accepted a connection on 127.0.0.1:${forward_port} — the forward itself failed, not identity" >&2
    return 1
  fi
  local code=""
  if ! code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "http://127.0.0.1:${forward_port}/.well-known/jwks.json" 2>/dev/null)"; then
    echo "error: identity's JWKS route is unreachable after the OIDC restart — curl could not complete against the forwarded svc/identity" >&2
    return 1
  fi
  case "$code" in
    2*)
      OIDC_ROUTE_VERIFIED=1
      kit_substrate_out "      identity's JWKS route answers ${code} after the OIDC restart — the patched surface is serving"
      return 0
      ;;
    *)
      echo "error: identity's JWKS route answers ${code} after the OIDC restart — expected 2xx; the patched surface is not serving" >&2
      return 1
      ;;
  esac
}

validate_mfa_override() {
  if [ -z "$KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY" ]; then
    return 0
  fi
  local key="$KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY"
  local why=""
  case "$key" in
    *[!A-Za-z0-9_-]*)
      why="it carries characters outside base64url (A-Z a-z 0-9 - _), or padding"
      ;;
  esac
  if [ -z "$why" ] && [ "${#key}" -ne 43 ]; then
    why="it is ${#key} characters, want 43 (32 bytes as base64url, no padding)"
  fi
  if [ -z "$why" ]; then
    local n=""
    if n="$(printf '%s=' "$key" | tr -- '-_' '+/' | base64 -d 2>/dev/null | wc -c | tr -d ' \n')"; then
      [ "$n" = "32" ] || why="it decodes to ${n:-0} bytes, want exactly 32"
    else
      why="it does not base64-decode"
    fi
  fi
  if [ -n "$why" ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY" \
      "export KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY='<43 base64url characters>' on the box and re-run, or leave it unset so the install generates one on first creation and keeps it" \
      "KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY is not a 32-byte base64url-no-padding key — $why"
  fi
}

install_service_secrets() {
  if dry_run "ensure gateway-secrets carries ASSERTION_SIGNING_KEY (gateway's chart mounts it; generated on the box, read back on a re-run)"; then
    :
  else
    reconcile_gateway_assertion_key
  fi
  if dry_run "ensure identity-secrets carries OIDC_LOGIN_UI_URL when the OIDC surface is wired (the fourth member of the all-or-nothing surface)"; then
    :
  else
    reconcile_oidc_identity_secrets
  fi
  if kit_substrate_guard secrets; then
    kit_substrate_out "      already installed, skipping"
    return 0
  fi
  if dry_run "create identity-secrets, gateway-secrets, courier-secrets, parlor-secrets, billing-secrets (generated values once-only, sourced values validated on the live path)"; then
    return 0
  fi
  case "$KIT_SUBSTRATE_SMTP_ADAPTER" in
    smtp | postmark) ;;
    cloudflare) ;;
    *)
      kit_substrate_refuse "KIT_SUBSTRATE_SMTP_ADAPTER" \
        "export KIT_SUBSTRATE_SMTP_ADAPTER='smtp' (or 'postmark' or 'cloudflare') on the box and re-run" \
        "KIT_SUBSTRATE_SMTP_ADAPTER must be smtp, postmark, or cloudflare"
      ;;
  esac
  if [ "$KIT_SUBSTRATE_SMTP_ADAPTER" = "cloudflare" ]; then
    if [ -z "$KIT_SUBSTRATE_CLOUDFLARE_API_KEY" ] || [ -z "$KIT_SUBSTRATE_CF_ACCOUNT_ID" ]; then
      kit_substrate_refuse \
        "KIT_SUBSTRATE_CLOUDFLARE_API_KEY, KIT_SUBSTRATE_CF_ACCOUNT_ID" \
        "export KIT_SUBSTRATE_CLOUDFLARE_API_KEY='<cloudflare-token>' and KIT_SUBSTRATE_CF_ACCOUNT_ID='<account-id>' on the box and re-run — the API token is a Cloudflare API token with Email Sending:Edit from dash.cloudflare.com → My Profile → API Tokens, the account id is the account the token belongs to" \
        "courier's externally-sourced settings are incomplete for the cloudflare adapter — both are required"
    fi
  else
    if [ -z "$KIT_SUBSTRATE_SMTP_HOST" ] ||
       [ -z "$KIT_SUBSTRATE_SMTP_USERNAME" ] || [ -z "$KIT_SUBSTRATE_SMTP_PASSWORD" ] ||
       [ -z "$KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET" ]; then
      kit_substrate_refuse \
        "KIT_SUBSTRATE_SMTP_HOST, KIT_SUBSTRATE_SMTP_USERNAME, KIT_SUBSTRATE_SMTP_PASSWORD, KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET" \
        "export the four above on the box and re-run — the signing secret comes from the PROVIDER's dashboard (Resend: the webhook endpoint's Signing Secret)" \
        "courier's externally-sourced settings are incomplete — all of these are required"
    fi
  fi
  case "$KIT_SUBSTRATE_SMTP_PORT" in
    '' | *[!0-9]*)
      kit_substrate_refuse "KIT_SUBSTRATE_SMTP_PORT" \
        "export KIT_SUBSTRATE_SMTP_PORT='587' on the box and re-run" \
        "KIT_SUBSTRATE_SMTP_PORT must be numeric"
      ;;
  esac

  if [ -n "$KIT_SUBSTRATE_STRIPE_API_KEY" ] && [ -z "$KIT_SUBSTRATE_STRIPE_WEBHOOK_SECRET" ] ||
     [ -z "$KIT_SUBSTRATE_STRIPE_API_KEY" ] && [ -n "$KIT_SUBSTRATE_STRIPE_WEBHOOK_SECRET" ]; then
    kit_substrate_refuse \
      "KIT_SUBSTRATE_STRIPE_API_KEY, KIT_SUBSTRATE_STRIPE_WEBHOOK_SECRET" \
      "export BOTH on the box and re-run — the secret key is at dash.stripe.com → Developers → API keys (sk_test_… or sk_live_…), and the signing secret is the webhook endpoint's Signing Secret (whsec_…); one without the other is half a door" \
      "billing's Stripe settings are half-present — exactly one of the two is set"
  fi
  if [ -z "$KIT_SUBSTRATE_STRIPE_API_KEY" ] || [ -z "$KIT_SUBSTRATE_STRIPE_WEBHOOK_SECRET" ]; then
    kit_substrate_refuse \
      "KIT_SUBSTRATE_STRIPE_API_KEY, KIT_SUBSTRATE_STRIPE_WEBHOOK_SECRET" \
      "export BOTH on the box and re-run — billing is in KIT_SUBSTRATE_DATABASES, so this box sells; the secret key is at dash.stripe.com → Developers → API keys and the signing secret is the webhook endpoint's Signing Secret" \
      "billing's Stripe settings are required when billing is deployed (KIT_SUBSTRATE_DATABASES names it)"
  fi

  validate_oidc_all_or_nothing

  local ns
  for ns in identity gateway courier parlor billing; do
    kubectl --kubeconfig="$KUBECONFIG" create namespace "$ns" --dry-run=client -o yaml |
      kubectl --kubeconfig="$KUBECONFIG" apply -f - >/dev/null
  done

  validate_mfa_override
  local signup_key mfa_key identity_args oidc_key="" oidc_key_id=""
  signup_key="$(read_secret_key identity identity-secrets SIGNUP_SIGNING_KEY)"
  if [ -z "$signup_key" ]; then
    signup_key="$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')"
  fi
  if [ -n "$KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY" ]; then
    mfa_key="$KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY"
  else
    mfa_key="$(read_secret_key identity identity-secrets MFA_ENCRYPTION_KEY)"
    if [ -z "$mfa_key" ]; then
      mfa_key="$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')"
    fi
  fi
  identity_args=(--from-literal=DATABASE_URL="$(database_url_for identity)"
    --from-literal=SIGNUP_SIGNING_KEY="$signup_key"
    --from-literal=MFA_ENCRYPTION_KEY="$mfa_key"
    --from-literal=NATS_URL="$NATS_URL")
  if [ -n "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ]; then
    resolve_oidc_signing_key
    oidc_key="$OIDC_SIGNING_KEY"
    oidc_key_id="$OIDC_SIGNING_KEY_ID"
    identity_args+=(--from-literal=OIDC_ISSUER="$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER"
      --from-literal=OIDC_SIGNING_KEY="$oidc_key"
      --from-literal=OIDC_SIGNING_KEY_ID="$oidc_key_id"
      --from-literal=OIDC_LOGIN_UI_URL="$KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL")
  fi
  [ -n "$KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY" ] &&
    identity_args+=(--from-literal=OAUTH_ENCRYPTION_KEY="$KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY")
  if kubectl --kubeconfig="$KUBECONFIG" get secret identity-secrets -n identity >/dev/null 2>&1; then
    kit_substrate_out "      secret identity-secrets exists — refusing to overwrite (rotate by replacing the secret and restarting the pods)"
  else
    kubectl --kubeconfig="$KUBECONFIG" create secret generic identity-secrets -n identity \
      "${identity_args[@]}" >/dev/null
    kit_substrate_out "      secret identity-secrets created (generated values once-only; rotate by replacing the secret)"
    if [ -n "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ]; then
      local verify_issuer verify_login verify_key verify_kid
      verify_issuer="$(read_secret_key identity identity-secrets OIDC_ISSUER)"
      verify_login="$(read_secret_key identity identity-secrets OIDC_LOGIN_UI_URL)"
      verify_key="$(read_secret_key identity identity-secrets OIDC_SIGNING_KEY)"
      verify_kid="$(read_secret_key identity identity-secrets OIDC_SIGNING_KEY_ID)"
      if [ "$verify_issuer" != "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ] || [ "$verify_login" != "$KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" ] || [ -z "$verify_key" ] || [ -z "$verify_kid" ]; then
        echo "error: identity-secrets does not carry the OIDC surface after creation — OIDC keys not readable or mismatched" >&2
        exit 1
      fi
    fi
  fi

  local redis_pw
  redis_pw="$(read_secret_key data redis-password password)"
  if [ -z "$redis_pw" ]; then
    echo "error: secret redis-password is missing in namespace data — run step 9 first" >&2
    exit 1
  fi
  resolve_gateway_assertion_key
  if kubectl --kubeconfig="$KUBECONFIG" get secret gateway-secrets -n gateway >/dev/null 2>&1; then
    kit_substrate_out "      secret gateway-secrets exists — refusing to overwrite (rotate by replacing the secret and restarting the pods)"
  else
    kubectl --kubeconfig="$KUBECONFIG" create secret generic gateway-secrets -n gateway \
      --from-literal=REDIS_URL="redis://:$redis_pw@redis.data.svc.cluster.local:6379" \
      --from-literal=ASSERTION_SIGNING_KEY="$ASSERTION_SIGNING_KEY" >/dev/null
    kit_substrate_out "      secret gateway-secrets created (REDIS_URL and a generated ASSERTION_SIGNING_KEY — the chart's two required references)"
  fi

  local secret_base secret_box relay_token
  local -a courier_extra_args=() courier_adapter_args=()
  secret_base="$(read_secret_key courier courier-secrets SECRET_KEY_BASE)"
  [ -n "$secret_base" ] || secret_base="$(head -c 64 /dev/urandom | base64 | tr -d '\n')"
  secret_box="$(read_secret_key courier courier-secrets COURIER_SECRET_BOX_KEY)"
  [ -n "$secret_box" ] || secret_box="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
  relay_token="$(read_secret_key courier courier-secrets COURIER_ERROR_RELAY_TOKEN)"
  [ -n "$relay_token" ] || relay_token="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  [ -n "$KIT_SUBSTRATE_MAIL_FROM" ] &&
    courier_extra_args+=(--from-literal=MAIL_FROM="$KIT_SUBSTRATE_MAIL_FROM")
  [ -n "$KIT_SUBSTRATE_MAIL_FROM_NAME" ] &&
    courier_extra_args+=(--from-literal=MAIL_FROM_NAME="$KIT_SUBSTRATE_MAIL_FROM_NAME")
  [ -n "$KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET" ] &&
    courier_extra_args+=(--from-literal=COURIER_INBOUND_RESEND_SECRET="$KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET")
  if [ "$KIT_SUBSTRATE_SMTP_ADAPTER" = "cloudflare" ]; then
    courier_adapter_args=(
      --from-literal=COURIER_MAIL_ADAPTER="$KIT_SUBSTRATE_SMTP_ADAPTER"
      --from-literal=COURIER_CLOUDFLARE_API_KEY="$KIT_SUBSTRATE_CLOUDFLARE_API_KEY"
      --from-literal=COURIER_CF_ACCOUNT_ID="$KIT_SUBSTRATE_CF_ACCOUNT_ID"
    )
  else
    courier_adapter_args=(
      --from-literal=COURIER_MAIL_ADAPTER="$KIT_SUBSTRATE_SMTP_ADAPTER"
      --from-literal=COURIER_SMTP_HOST="$KIT_SUBSTRATE_SMTP_HOST"
      --from-literal=COURIER_SMTP_PORT="$KIT_SUBSTRATE_SMTP_PORT"
      --from-literal=COURIER_SMTP_USERNAME="$KIT_SUBSTRATE_SMTP_USERNAME"
      --from-literal=COURIER_SMTP_PASSWORD="$KIT_SUBSTRATE_SMTP_PASSWORD"
    )
  fi
  if kubectl --kubeconfig="$KUBECONFIG" get secret courier-secrets -n courier >/dev/null 2>&1; then
    kit_substrate_out "      secret courier-secrets exists — refusing to overwrite (rotate by replacing the secret and restarting the pods)"
  else
    kubectl --kubeconfig="$KUBECONFIG" create secret generic courier-secrets -n courier \
      --from-literal=DATABASE_URL="$(database_url_for courier)" \
      --from-literal=SECRET_KEY_BASE="$secret_base" \
      --from-literal=COURIER_SECRET_BOX_KEY="$secret_box" \
      "${courier_adapter_args[@]}" \
      --from-literal=COURIER_ERROR_RELAY_TOKEN="$relay_token" \
      --from-literal=NATS_URL="$NATS_URL" \
      \
      ${courier_extra_args[@]+"${courier_extra_args[@]}"} >/dev/null
    kit_substrate_out "      secret courier-secrets created (COURIER_IDENTITY_TOKEN follows in step 12 — minted on this box)"
  fi

  if kubectl --kubeconfig="$KUBECONFIG" get secret parlor-secrets -n parlor >/dev/null 2>&1; then
    kit_substrate_out "      secret parlor-secrets exists — refusing to overwrite (rotate by replacing the secret and restarting the pods)"
  else
    kubectl --kubeconfig="$KUBECONFIG" create secret generic parlor-secrets -n parlor \
      --from-literal=DATABASE_URL="$(database_url_for parlor)" \
      >/dev/null
    kit_substrate_out "      secret parlor-secrets created (DATABASE_URL only — see the comment above)"
  fi

  if kubectl --kubeconfig="$KUBECONFIG" get secret billing-secrets -n billing >/dev/null 2>&1; then
    kit_substrate_out "      secret billing-secrets exists — refusing to overwrite (rotate by replacing the secret and restarting the pods)"
  else
    local billing_secret_base
    billing_secret_base="$(read_secret_key billing billing-secrets SECRET_KEY_BASE)"
    [ -n "$billing_secret_base" ] || billing_secret_base="$(head -c 64 /dev/urandom | base64 | tr -d '\n')"
    kubectl --kubeconfig="$KUBECONFIG" create secret generic billing-secrets -n billing \
      --from-literal=DATABASE_URL="$(database_url_for billing)" \
      --from-literal=SECRET_KEY_BASE="$billing_secret_base" \
      --from-literal=NATS_URL="$NATS_URL" \
      --from-literal=BILLING_IDENTITY_ISSUER="http://identity.identity.svc.cluster.local:8080" \
      --from-literal=BILLING_IDENTITY_AUDIENCE="billing" \
      --from-literal=STRIPE_API_KEY="$KIT_SUBSTRATE_STRIPE_API_KEY" \
      --from-literal=STRIPE_WEBHOOK_SECRET="$KIT_SUBSTRATE_STRIPE_WEBHOOK_SECRET" \
      >/dev/null
    kit_substrate_out "      secret billing-secrets created (SECRET_KEY_BASE generated once-only; the Stripe pair from the environment)"
  fi
}

KIT_SUBSTRATE_MIGRATE_MARKER="${KIT_SUBSTRATE_MIGRATE_MARKER:-substrate-migrations}"

migration_service_has_schema() {
  case "$1" in
    identity | courier | billing) return 0 ;;
    *) return 1 ;;
  esac
}

migration_command_for() {
  case "$1" in
    identity) printf '%s' "${KIT_SUBSTRATE_MIGRATE_CMD_identity:-/app/bin/migrate}" ;;
    courier) printf '%s' "${KIT_SUBSTRATE_MIGRATE_CMD_courier:-/app/bin/migrate}" ;;
    billing) printf '%s' "${KIT_SUBSTRATE_MIGRATE_CMD_billing:-/rails/bin/migrate}" ;;
    *) return 1 ;;
  esac
}

migration_env_args_for() {
  case "$1" in
    identity)
      printf '%s\n' "--env=DATABASE_URL=$(owner_database_url_for identity)"
      ;;
    courier)
      printf '%s\n' "--env=COURIER_OWNER_DATABASE_URL=$(owner_database_url_for courier)"
      printf '%s\n' "--env=DATABASE_URL=$(database_url_for courier)"
      ;;
    billing)
      printf '%s\n' "--env=DATABASE_URL=$(owner_database_url_for billing)"
      printf '%s\n' "--env=SECRET_KEY_BASE=$(read_secret_key billing billing-secrets SECRET_KEY_BASE)"
      printf '%s\n' "--env=OTEL_SDK_DISABLED=true"
      ;;
    *) return 1 ;;
  esac
}

migration_guard_applied() {
  if [ "$DRY_RUN" -eq 1 ]; then
    return 1
  fi
  local svc image marked
  for svc in identity courier billing; do
    migration_service_has_schema "$svc" || continue
    image="$(kubectl --kubeconfig="$KUBECONFIG" get deployment "$svc" -n "$svc" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    [ -n "$image" ] || return 1
    marked="$(read_secret_key data "$KIT_SUBSTRATE_MIGRATE_MARKER" "$svc")"
    [ "$marked" = "$image" ] || return 1
  done
  return 0
}

install_migrations() {
  log_step "the database schemas of the services that own one (identity, courier, billing)";
  if migration_guard_applied; then
    kit_substrate_out "      every schema already applied at the running image, skipping (a new image re-enters this step)"
    return 0
  fi
  if dry_run "run one migrate Job per schema-owning service, in that service's own running image, connected as its OWNER role (identity/identity, courier/courier, billing/billing), and wait for completion; gateway and parlor own no schema and are skipped"; then
    return 0
  fi

  if ! kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Ready cluster.postgresql.cnpg.io/postgres -n data --timeout="${CNPG_CLUSTER_READY_TIMEOUT}s"; then
    cluster_phase="$(cnpg_cluster_phase)"
    kit_substrate_refuse "the CNPG Cluster postgres in namespace data" \
      "re-run 'cafe box apply --phase 8' on the box once the Cluster is Ready, then this step" \
      "the Postgres Cluster is not Ready (phase: '${cluster_phase:-unknown}') — refusing to migrate into a half-ready cluster"
  fi

  local svc image cmd
  local cluster_phase=""
  local -a marker_args=() failed=() launched=()
  for svc in identity courier billing; do
    migration_service_has_schema "$svc" || continue
    local image_tries=24
    image=""
    while [ -z "$image" ] && [ "$image_tries" -gt 0 ]; do
      image="$(kubectl --kubeconfig="$KUBECONFIG" get deployment "$svc" -n "$svc" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
      [ -n "$image" ] || sleep 5
      image_tries=$((image_tries - 1))
    done
    if [ -z "$image" ]; then
      echo "error: deployment/${svc} does not exist yet — Argo has not synced it, so the image to migrate with is unknown; re-run step ${STEP}" >&2
      exit 1
    fi
    cmd="$(migration_command_for "$svc")"
    local -a env_args=()
    while IFS= read -r arg; do
      env_args+=("$arg")
    done < <(migration_env_args_for "$svc")

    kit_substrate_out "      migrating ${svc} as its OWNER role, in ${image}"
    kubectl --kubeconfig="$KUBECONFIG" delete pod "kit-migrate-${svc}" -n "$svc" --ignore-not-found >/dev/null 2>&1 || true
    if ! kubectl --kubeconfig="$KUBECONFIG" run "kit-migrate-${svc}" -n "$svc" \
      --restart=Never \
      --image="$image" \
      "${env_args[@]}" \
      --command -- $cmd; then
      :
    fi
    launched+=("$svc:$image")
  done

  local entry phase tries svc_image
  for entry in ${launched[@]+"${launched[@]}"}; do
    svc="${entry%%:*}"
    svc_image="${entry#*:}"
    image="$svc_image"
    phase=""
    tries=36
    while [ "$tries" -gt 0 ]; do
      phase="$(kubectl --kubeconfig="$KUBECONFIG" get pod "kit-migrate-${svc}" -n "$svc" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      case "$phase" in
        Succeeded)
          kubectl --kubeconfig="$KUBECONFIG" delete pod "kit-migrate-${svc}" -n "$svc" >/dev/null 2>&1 || true
          kit_substrate_out "      ${svc}'s schema is applied"
          break
          ;;
        Failed)
          break
          ;;
      esac
      tries=$((tries - 1))
      sleep 5
    done
    if [ "$phase" != "Succeeded" ]; then
      echo "error: the migration for ${svc} did not succeed (last pod phase: '${phase:-Unknown}')" >&2
      echo "error:   service: ${svc}" >&2
      echo "error:   dsn:     $(owner_database_url_for "$svc" | sed 's#://[^:]*:[^@]*@#://OWNER:<redacted>@#') (role ${svc}, the OWNER)" >&2
      echo "error:   image:   ${image}" >&2
      cluster_phase="$(cnpg_cluster_phase)"
      echo "error:   cluster: postgres in namespace data (phase: '${cluster_phase:-unknown}')" >&2
      echo "error: the pod is left in namespace ${svc} for diagnosis; its logs follow:" >&2
      kubectl --kubeconfig="$KUBECONFIG" logs "pod/kit-migrate-${svc}" -n "$svc" >&2 2>&1 || true
      failed+=("$svc")
      continue
    fi
    marker_args+=("--from-literal=${svc}=${image}")
  done

  if [ "${#failed[@]}" -gt 0 ]; then
    echo "error: the substrate will not report a finished install while a service's schema is empty: ${failed[*]}" >&2
    echo "error: fix the migrate entrypoint for the service(s) named above, then re-run — every completed step is skipped by its guard" >&2
    exit 1
  fi

  kubectl --kubeconfig="$KUBECONFIG" delete secret "$KIT_SUBSTRATE_MIGRATE_MARKER" -n data --ignore-not-found >/dev/null 2>&1 || true
  kubectl --kubeconfig="$KUBECONFIG" create secret generic "$KIT_SUBSTRATE_MIGRATE_MARKER" -n data \
    "${marker_args[@]}" >/dev/null
  kit_substrate_out "      schemas applied for: identity, courier (marker secret ${KIT_SUBSTRATE_MIGRATE_MARKER} in data)"
}

install_nats() {
  log_step "NATS with JetStream ${NATS_VERSION} and stream anywaye (in the data namespace)"
  if kit_substrate_guard nats; then
    kit_substrate_out "      already installed, skipping the broker (the stream init still runs)"
  elif dry_run "substitute NATS_IMAGE_PLACEHOLDER with nats:${NATS_VERSION} and apply ${DATA_DIR}/nats.yaml, then wait for deployment nats"; then
    :
  else
    kubectl --kubeconfig="$KUBECONFIG" create namespace data --dry-run=client -o yaml |
      kubectl --kubeconfig="$KUBECONFIG" apply -f -
    kit_substrate_check_manifest_dir "$DATA_DIR"
    sed "s/NATS_IMAGE_PLACEHOLDER/nats:${NATS_VERSION}/" "$DATA_DIR/nats.yaml" |
      kubectl --kubeconfig="$KUBECONFIG" apply -f -
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment nats -n data --timeout=180s
  fi
  if dry_run "run one-shot pod nats-stream-init (image natsio/nats-box:${NATS_BOX_VERSION}) ensuring stream anywaye"; then
    return 0
  fi
  kubectl --kubeconfig="$KUBECONFIG" delete pod nats-stream-init -n data --ignore-not-found >/dev/null
  kubectl --kubeconfig="$KUBECONFIG" run nats-stream-init -n data \
    --restart=Never \
    --image="natsio/nats-box:${NATS_BOX_VERSION}" \
    --env="NATS_URL=$NATS_URL" \
    --command -- sh -c 'nats stream info anywaye >/dev/null 2>&1 || nats stream add anywaye --subjects "identity.>,billing.>,courier.>,muse.>,darkroom.>" --storage file --retention limits --max-age 7d --discard old --replicas 1 --defaults'
  local phase="" tries=24
  while [ "$tries" -gt 0 ]; do
    phase="$(kubectl --kubeconfig="$KUBECONFIG" get pod nats-stream-init -n data -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in
      Succeeded)
        kubectl --kubeconfig="$KUBECONFIG" delete pod nats-stream-init -n data >/dev/null
        kit_substrate_out "      stream anywaye exists (created or already present)"
        return 0
        ;;
      Failed)
        echo "error: the NATS stream init failed — the pod is left in namespace data for diagnosis:" >&2
        kubectl --kubeconfig="$KUBECONFIG" logs pod/nats-stream-init -n data >&2 || true
        exit 1
        ;;
    esac
    tries=$((tries - 1))
    sleep 5
  done
  echo "error: timed out waiting for pod nats-stream-init (last phase: '${phase:-unknown}') — the pod is left for diagnosis" >&2
  exit 1
}

: "${IDENTITY_DEPLOY_TIMEOUT:=180}"
: "${IDENTITY_ROLLOUT_TIMEOUT:=180}"
validate_app_base_url() {
  [ -n "$KIT_SUBSTRATE_APP_BASE_URL" ] || return 0
  case "$KIT_SUBSTRATE_APP_BASE_URL" in
    http://* | https://*) ;;
    *)
      kit_substrate_refuse "KIT_SUBSTRATE_APP_BASE_URL" \
        "export KIT_SUBSTRATE_APP_BASE_URL='https://app.example.com' — the public origin a browser reaches (scheme and host, no query and no fragment) — and re-run" \
        "KIT_SUBSTRATE_APP_BASE_URL must be an absolute http(s) URL"
      ;;
  esac
  case "${KIT_SUBSTRATE_APP_BASE_URL#*://}" in
      kit_substrate_refuse "KIT_SUBSTRATE_APP_BASE_URL" \
        "export KIT_SUBSTRATE_APP_BASE_URL='https://app.example.com' — scheme, host and nothing with a query or a fragment (identity appends each link's own path) — and re-run" \
        "KIT_SUBSTRATE_APP_BASE_URL must be an origin: a host, and no query or fragment"
      ;;
  esac
}

converge_identity_courier_block() {
  local k v orphans=""
  IDENTITY_MAIL_PATH_KEPT=""
  local base_present="" token_present=""
  for k in ${IDENTITY_COURIER_KEYS[@]+"${IDENTITY_COURIER_KEYS[@]}"}; do
    v="$(read_secret_key identity identity-secrets "$k")"
    if [ -n "$v" ]; then
      orphans="${orphans:+$orphans }$k"
      case "$k" in
        COURIER_BASE_URL) base_present=1 ;;
        COURIER_TOKEN) token_present=1 ;;
      esac
    fi
  done
    kit_substrate_out "      identity carries a working mail path (COURIER_BASE_URL and COURIER_TOKEN are both present): this run has no KIT_SUBSTRATE_APP_BASE_URL to rewrite it with, so the mail path stays, nothing removed, and every recovery route keeps answering — set KIT_SUBSTRATE_APP_BASE_URL to rewrite the pair and its link templates on a later run"
    IDENTITY_MAIL_PATH_KEPT=1
    return 0
  fi
  if [ -z "$orphans" ]; then
    kit_substrate_out "      identity's mail path is NOT configured (KIT_SUBSTRATE_APP_BASE_URL unset): no identity courier keys written, nothing removed, so identity boots into its supported no-mail state and every recovery route answers 503"
    return 0
  fi
  local orphan_patch
  orphan_patch="$(printf '%s' "$orphans" | tr ' ' '\n' | jq -Rn '[inputs | select(length > 0)] | map({(.): null}) | add | {data: .}')"
  printf '%s' "$orphan_patch" |
    kubectl --kubeconfig="$KUBECONFIG" -n identity patch secret identity-secrets \
    --type=merge --patch-file=/dev/stdin
  kit_substrate_out "      identity's mail path is NOT configured (KIT_SUBSTRATE_APP_BASE_URL unset): removed orphaned courier key(s):$orphans — leftovers from an installer that wrote half a pair, and each one is either a half-pair that crashloops identity or a template pointing at a base this box no longer declares"
  if kubectl --kubeconfig="$KUBECONFIG" get deployment identity -n identity >/dev/null 2>&1; then
    kubectl --kubeconfig="$KUBECONFIG" -n identity rollout restart deployment/identity
  else
    kit_substrate_out "      identity Deployment not present — restart skipped (the secret is already converged; the next sync boots clean)"
  fi
  local leftover=""
  for k in ${IDENTITY_COURIER_KEYS[@]+"${IDENTITY_COURIER_KEYS[@]}"}; do
    v="$(read_secret_key identity identity-secrets "$k")"
    if [ -n "$v" ]; then
      leftover="${leftover:+$leftover }$k"
    fi
  done
  if [ -n "$leftover" ]; then
    echo "error: identity-secrets still carries courier key(s) after the orphan sweep:$leftover — the patch did not converge" >&2
    return 1
  fi
}

mint_courier_identity_token() {
  log_step "courier's identity credential, minted on this box"
  if [ -z "$KIT_SUBSTRATE_APP_BASE_URL" ]; then
    converge_identity_courier_block || return 1
  fi
  if [ -n "$(read_secret_key courier courier-secrets COURIER_IDENTITY_TOKEN)" ]; then
    kit_substrate_out "      credential already minted on this box, skipping (rotate by replacing the secret and restarting the pods)"
    return 0
  fi
  validate_app_base_url
  if dry_run "mint courier's API key from identity's own API (register → session → account → api-key), then patch identity-secrets (COURIER_BASE_URL + COURIER_TOKEN + link templates when KIT_SUBSTRATE_APP_BASE_URL is set) and courier-secrets (COURIER_IDENTITY_URL + COURIER_IDENTITY_TOKEN) and restart both deployments"; then
    return 0
  fi

  kit_substrate_await_list "$IDENTITY_DEPLOY_TIMEOUT" deployment identity -n identity
  kubectl --kubeconfig="$KUBECONFIG" -n identity rollout status deployment/identity --timeout="$((IDENTITY_ROLLOUT_TIMEOUT))s"

  local forward_port="${KIT_SUBSTRATE_IDENTITY_LOCAL_PORT:-18080}"
  kubectl --kubeconfig="$KUBECONFIG" -n identity port-forward "svc/identity" "${forward_port}:8080" >/dev/null 2>&1 &
  local forward_pid=$!
  trap 'kill "$forward_pid" 2>/dev/null || true; trap - RETURN' RETURN

  if ! kit_substrate_await_port "$forward_port" 30; then
    echo "error: the port-forward to svc/identity never accepted a connection on 127.0.0.1:${forward_port} — the forward itself failed, not identity" >&2
    return 1
  fi

  local base="http://127.0.0.1:${forward_port}" out token
  out="$(curl -fsS -X POST "${base}/v1/signup-timestamp")" || {
    echo "error: identity would not mint a signup timestamp" >&2
    return 1
  }
  local mint_timestamp mint_signature owner_password
  mint_timestamp="$(printf '%s' "$out" | jq -r '.timestamp // empty')"
  mint_signature="$(printf '%s' "$out" | jq -r '.signature // empty')"
  if [ -z "$mint_timestamp" ] || [ -z "$mint_signature" ]; then
    echo "error: identity's signup-timestamp response carried no pair" >&2
    return 1
  fi
  sleep 3
  owner_password="$(openssl rand -hex 24)"
  out="$(curl -fsS -X POST "${base}/v1/users" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg email "owner+substrate@anywaye.local" \
      --arg password "$owner_password" \
      --argjson timestamp "$mint_timestamp" --arg signature "$mint_signature" \
      '{email: $email, password: $password, website: "", timestamp: $timestamp, signature: $signature}')")" || {
    echo "error: identity would not register this box's owner account" >&2
    return 1
  }
  local session
  session="$(curl -fsS -X POST "${base}/v1/session" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg email "owner+substrate@anywaye.local" --arg password "$owner_password" \
      '{email: $email, password: $password}')")" || {
    echo "error: identity would not open a session for this box's owner account" >&2
    return 1
  }
  local session_token
  session_token="$(printf '%s' "$session" | jq -r '.token // empty')"
  if [ -z "$session_token" ]; then
    echo "error: identity's session response carried no token" >&2
    return 1
  fi
  local account_id
  account_id="$(curl -fsS -X POST "${base}/v1/accounts" \
    -H "Authorization: Bearer ${session_token}" -H 'Content-Type: application/json' \
    -d '{"name":"courier"}' | jq -r '.id // empty')" || {
    echo "error: identity would not create this box's account" >&2
    return 1
  }
  [ -n "$account_id" ] || {
    echo "error: identity's account response carried no id" >&2
    return 1
  }
  token="$(curl -fsS -X POST "${base}/v1/accounts/${account_id}/api-keys" \
    -H "Authorization: Bearer ${session_token}" -H 'Content-Type: application/json' \
    -d '{"name":"courier","scopes":["accounts:read"]}' | jq -r '.token // empty')" || {
    echo "error: identity would not mint courier's credential" >&2
    return 1
  }
  [ -n "$token" ] || {
    echo "error: identity's mint response carried no token" >&2
    return 1
  }

  if [ -n "$KIT_SUBSTRATE_APP_BASE_URL" ]; then
    local base reset verify change invite identity_patch
    base="${KIT_SUBSTRATE_APP_BASE_URL%/}"
    reset="${base}/reset-password?token={token}"
    verify="${base}/verify-email/confirm?token={token}"
    change="$verify"
    invite="${base}/invitations/{token}"
    identity_patch="$(jq -nc \
      --arg url "$COURIER_URL" --arg t "$token" \
      --arg reset "$reset" --arg verify "$verify" --arg change "$change" \
      --arg invite "$invite" \
      '{"stringData":{
        "COURIER_BASE_URL":$url,
        "COURIER_TOKEN":$t,
        "PASSWORD_RESET_LINK_TEMPLATE":$reset,
        "EMAIL_VERIFICATION_LINK_TEMPLATE":$verify,
        "EMAIL_CHANGE_LINK_TEMPLATE":$change,
        "INVITATION_LINK_TEMPLATE":$invite
      },"data":{
        "RECOVERY_LINK_TEMPLATE":null
      }}')"
    printf '%s' "$identity_patch" |
      kubectl --kubeconfig="$KUBECONFIG" -n identity patch secret identity-secrets \
      --type=merge --patch-file=/dev/stdin
    kubectl --kubeconfig="$KUBECONFIG" -n identity rollout restart deployment/identity
  else
    converge_identity_courier_block || return 1
  fi
  printf '%s' "$(jq -nc --arg url "$IDENTITY_URL" --arg t "$token" \
    '{"stringData":{"COURIER_IDENTITY_URL":$url,"COURIER_IDENTITY_TOKEN":$t}}')" |
    kubectl --kubeconfig="$KUBECONFIG" -n courier patch secret courier-secrets \
    --type=merge --patch-file=/dev/stdin
  kubectl --kubeconfig="$KUBECONFIG" -n courier rollout restart deployment/courier
  if [ -n "$KIT_SUBSTRATE_APP_BASE_URL" ]; then
    kit_substrate_out "      credential minted on this box; identity has a TRUE mail path (four link templates derived from ${KIT_SUBSTRATE_APP_BASE_URL}, legacy shared default deleted) and courier holds the same credential, both deployments restarted"
  elif [ -n "${IDENTITY_MAIL_PATH_KEPT:-}" ]; then
    kit_substrate_out "      credential minted on this box; courier holds it, identity KEEPS its working mail path (this run had no KIT_SUBSTRATE_APP_BASE_URL to rewrite it with, so nothing was rewritten) — every recovery route keeps answering; courier restarted"
  else
    kit_substrate_out "      credential minted on this box; courier holds it, identity's mail path is OFF BY DESIGN (set KIT_SUBSTRATE_APP_BASE_URL to turn it on), courier restarted"
  fi
}

converge_residual_replicasets() {
  log_step "the residual ReplicaSets of the four service Deployments (identity, gateway, courier, parlor)"
  if dry_run "list the ReplicaSets of identity, gateway, courier and parlor, report each one holding a pod under an old pod template, and scale it to 0"; then
    return 0
  fi
  local pair
  for pair in identity/identity gateway/gateway courier/courier parlor/parlor; do
    converge_one_deployment_rs "${pair%%/*}" "${pair#*/}" || return 1
  done
  STEP_SKIPPED=0
}

converge_one_deployment_rs() {
  local ns="$1" dep="$2"
  local dep_json
  dep_json="$(kubectl --kubeconfig="$KUBECONFIG" -n "$ns" get deployment "$dep" -o json 2>/dev/null)" || return 0
  [ -n "$dep_json" ] || return 0
  local desired
  desired="$(printf '%s' "$dep_json" | jq -r '.spec.replicas // 1')"
  if [ "$desired" = "0" ]; then
    kit_substrate_out "      ${ns}/${dep} is scaled to 0 by its operator — leaving its ReplicaSets alone"
    return 0
  fi
  local updated
  updated="$(printf '%s' "$dep_json" | jq -r '.status.updatedReplicas // 0')"
  if [ "$updated" != "$desired" ]; then
    kit_substrate_out "      ${ns}/${dep} is mid-rollout (updated ${updated} of ${desired}) — leaving its ReplicaSets to the controller"
    return 0
  fi
  local current_spec
  current_spec="$(printf '%s' "$dep_json" | jq -c '.spec.template.spec')"
  local current_hash
  current_hash="$(kubectl --kubeconfig="$KUBECONFIG" -n "$ns" get rs -o json |
    jq -r --arg dep "$dep" --argjson current "$current_spec" '
      [(.items // [])[]
       | select(((.metadata.ownerReferences // []) | map(select(.name == $dep)) | length) > 0)
       | select((.spec.replicas // 0) > 0)
       | select(.spec.template.spec == $current)
       | .metadata.labels."pod-template-hash" // empty]
      | .[0] // empty
    ')"
  local rs_json
  rs_json="$(kubectl --kubeconfig="$KUBECONFIG" -n "$ns" get rs -o json)"
  if [ -z "$current_hash" ]; then
    local live_count
    live_count="$(printf '%s' "$rs_json" | jq -r --arg dep "$dep" '
      [(.items // [])[]
       | select(((.metadata.ownerReferences // []) | map(select(.name == $dep)) | length) > 0)
       | select((.spec.replicas // 0) > 0)] | length')"
    if [ "$live_count" != "0" ]; then
      kit_substrate_out "      ${ns}/${dep} has ${live_count} live ReplicaSet(s) and none matches the current pod template — leaving them to the controller"
    fi
    return 0
  fi
  local residual_found=0
  local rs_name rs_hash rs_image rs_created
  while IFS=$'\t' read -r rs_name rs_hash rs_image rs_created; do
    [ -n "$rs_name" ] || continue
    residual_found=1
    kit_substrate_out "      residual ${ns}/${rs_name} (deployment ${dep}, image ${rs_image}, created ${rs_created}, pod-template-hash ${rs_hash}): scaling to 0"
    if dry_run "scale replicaset/${rs_name} -n ${ns} to 0 (residual: image ${rs_image}, created ${rs_created}, pod-template-hash ${rs_hash})"; then
      continue
    fi
    kubectl --kubeconfig="$KUBECONFIG" -n "$ns" scale "replicaset/${rs_name}" --replicas=0
  done <<EOF
$(printf '%s' "$rs_json" | jq -r --arg dep "$dep" --arg hash "$current_hash" '
  (.items // [])[]
  | select(((.metadata.ownerReferences // []) | map(select(.name == $dep)) | length) > 0)
  | select((.spec.replicas // 0) > 0)
  | select((.metadata.labels."pod-template-hash" // "") != $hash)
  | [.metadata.name,
     (.metadata.labels."pod-template-hash" // "unlabelled"),
     ((.spec.template.spec.containers // [])[0].image // "unknown"),
     (.metadata.creationTimestamp // "unknown")]
  | @tsv')
EOF
  if [ "$residual_found" -eq 0 ]; then
    kit_substrate_out "      ${ns}/${dep}: no residual ReplicaSets (live generations match pod-template-hash ${current_hash})"
  fi
}

main() {
    case "$1" in
      --headless) HEADLESS=1; shift ;;
      *)
        printf 'error: unknown argument "%s"\n' "$1" >&2
        printf '  usage: install.sh [--headless]\n' >&2
        printf '  note: the cluster this installs into is chosen by the KIT_SUBSTRATE_KUBECONFIG environment variable\n' >&2
        exit 1
        ;;
    esac
  done

  if [ "$HEADLESS" -eq 1 ]; then
    kit_substrate_open_jsonl_channel
  fi

  INSTALL_START_MS="$(kit_substrate_now)"

  kit_substrate_resolve_manifests

  R_PHASE="install"
  if [ "$CLUSTER_SUPPLIED" -eq 1 ]; then
    R_NEXT="the operators (cert-manager, CloudNativePG, Argo CD) into the cluster at KIT_SUBSTRATE_KUBECONFIG"
  else
    R_NEXT="k3s ${K3S_VERSION} — single node, sqlite datastore"
  fi
  R_STATUS="running"
  kit_substrate_write_receipt
  if [ "$HEADLESS" -eq 1 ]; then
    kit_substrate_emit install.start "install begins: ${TOTAL} steps, receipt at ${RECEIPT_PATH}"
  fi

  CURRENT_PHASE="preflight"
  preflight
  CURRENT_PHASE="k3s"
  install_k3s
  CURRENT_PHASE="cert-manager"
  install_cert_manager
  CURRENT_PHASE="cnpg"
  install_cnpg
  CURRENT_PHASE="argocd"
  install_argocd
  CURRENT_PHASE="pull-secret"
  install_pull_secret
  CURRENT_PHASE="applications"
  install_applications
  CURRENT_PHASE="cluster-issuers"
  install_cluster_issuers
  CURRENT_PHASE="postgres"
  install_postgres_cluster
  CURRENT_PHASE="redis-and-secrets"
  install_redis_and_secrets
  CURRENT_PHASE="migrations"
  install_migrations
  CURRENT_PHASE="nats"
  install_nats
  CURRENT_PHASE="courier-mint"
  mint_courier_identity_token
  CURRENT_PHASE="rs-residual"
  converge_residual_replicasets

  kit_substrate_step_finalize
  local total_seconds
  total_seconds="$(kit_substrate_seconds "$(( $(kit_substrate_now) - INSTALL_START_MS ))")"

  R_PHASE="complete"
  R_STATUS="complete"
  R_NEXT=""
  R_INPUT=""
  R_HUMAN="watch Argo CD reconcile the fleet: kubectl -n argocd get applications"
  if [ "$CLUSTER_SUPPLIED" -eq 1 ]; then
    R_MESSAGE="substrate is up on the cluster at ${KIT_SUBSTRATE_KUBECONFIG}: cert-manager ${CERT_MANAGER_VERSION}, CloudNativePG ${CNPG_VERSION}, Argo CD ${ARGOCD_VERSION}"
  else
    R_MESSAGE="substrate is up: k3s ${K3S_VERSION}, cert-manager ${CERT_MANAGER_VERSION}, CloudNativePG ${CNPG_VERSION}, Argo CD ${ARGOCD_VERSION}"
  fi
  kit_substrate_write_receipt
  if [ "$HEADLESS" -eq 1 ]; then
    kit_substrate_emit install.done "$R_MESSAGE" \
      ",\"seconds\":${total_seconds},\"steps\":$(kit_substrate_steps_json)"
  else
    kit_substrate_out ""
    kit_substrate_out "$R_MESSAGE"
    kit_substrate_out "Argo CD state:  kubectl -n argocd get applications"
    kit_substrate_out ""
    kit_substrate_print_table "$total_seconds"
  fi
}

kit_substrate_open_jsonl_channel() {
  if [ "${KIT_JSONL_CHANNEL:-0}" -eq 1 ]; then
    return 0
  fi
  KIT_JSONL_CHANNEL=1
  exec 3>&1 1>&2
}

if [ "$HEADLESS" -eq 1 ]; then
  kit_substrate_open_jsonl_channel
fi

main "$@"
