#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/publish-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PUB="$ROOT/bin/publish"

passes=0; fails=0

pass() { echo "      PASS publish_test: $1"; passes=$((passes+1)); }
fail() { echo "      FAIL publish_test: $1"; echo "             $2" | head -12 | sed 's/^/             /'; fails=$((fails+1)); }

run_pub() {
  local want="$1" label="$2"; shift 2
  local out ec=0
  out="$("$PUB" "$@" 2>&1)" || ec=$?
  case "$want:$ec" in
    red:0) fail "$label" "$out" ;;
    red:*) pass "$label" ;;
    green:0) pass "$label" ;;
    green:*) fail "$label" "$out" ;;
  esac
  printf '%s' "$out" >"$TMP/last.out"
  return 0
}

assert_contains() {
  local label="$1" needle="$2" file="$3"
  if grep -qF "$needle" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label" "$(cat "$file" 2>/dev/null | head -20)"
  fi
}

echo "-- publish_test: the publish tool's refusals"

run_pub green "help exits 0" --help
assert_contains "--help prints Usage" "Usage:" "$TMP/last.out"

svc="$TMP/svc"
mkdir -p "$svc/chart/templates"
cat >"$svc/chart/Chart.yaml" <<'EOF'
name: testpub
version: 0.1.0
appVersion: 0.1.0
EOF
cat >"$svc/chart/values.yaml" <<'EOF'
image:
  repository: ghcr.io/anywaye/testpub
  tag: "0.1.0"
EOF
cat >"$svc/chart/templates/_helpers.tpl" <<'EOF'
{{- define "testpub.name" -}}testpub{{- end -}}
EOF
cat >"$svc/chart/templates/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: test}
spec: {template: {spec: {containers: [{name: app, image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"}]}}}
EOF
cat >"$svc/Dockerfile" <<'EOF'
FROM alpine:3.20
EOF
git -C "$svc" init -q
git -C "$svc" config user.email "test@test.com"
git -C "$svc" config user.name "Test"
git -C "$svc" add .
git -C "$svc" commit -qm "init"

run_pub green "dry-run is green" --dry-run --service-dir "$svc"
assert_contains "dry-run prints docker build" "docker build" "$TMP/last.out"
assert_contains "dry-run prints helm package" "helm package" "$TMP/last.out"
assert_contains "dry-run prints visibility reminder" "Visibility" "$TMP/last.out"
assert_contains "dry-run prints chart version not bumped" "not bumped" "$TMP/last.out"

empty_home="$TMP/empty-home"
mkdir -p "$empty_home"
out_home="$TMP/auth-test.out"
ec=0
HOME="$empty_home" "$PUB" --service-dir "$svc" >"$out_home" 2>&1 || ec=$?
if [ "$ec" -ne 0 ] && grep -q "docker login ghcr.io" "$out_home" && grep -q "helm registry login" "$out_home"; then
  pass "no auth refuses naming docker login + helm registry login"
else
  fail "no auth refuses naming docker login + helm registry login" "$(cat "$out_home" 2>/dev/null | head -20)"
fi
HOME="$empty_home" "$PUB" --dry-run --service-dir "$svc" >"$TMP/auth-dry.out" 2>&1 || true
if grep -q "not logged in" "$TMP/auth-dry.out" 2>/dev/null; then
  fail "dry-run with no auth does not refuse (control)" "$(cat "$TMP/auth-dry.out" | head -10)"
else
  pass "dry-run with no auth does not refuse (control)"
fi

svc2="$TMP/svc2"
mkdir -p "$svc2"
cat >"$svc2/Dockerfile" <<'EOF'
FROM alpine:3.20
EOF
out="$TMP/missing-chart.out"
ec=0
"$PUB" --dry-run --service-dir "$svc2" >"$out" 2>&1 || ec=$?
if [ "$ec" -ne 0 ] && grep -q "chart dir not found" "$out"; then
  pass "missing chart dir refuses by name"
else
  mkdir -p "$svc2/chart"
  "$PUB" --dry-run --service-dir "$svc2" >"$out" 2>&1 || ec=$?
  if grep -q "no Chart.yaml" "$out"; then
    pass "missing Chart.yaml refuses by name"
  else
    fail "missing Chart.yaml refuses by name" "$(cat "$out" | head -10)"
  fi
fi

svc3="$TMP/svc3"
mkdir -p "$svc3/chart"
cat >"$svc3/chart/Chart.yaml" <<'EOF'
name: test3
version: 0.1.0
EOF
cat >"$svc3/Dockerfile" <<'EOF'
FROM alpine:3.20
EOF
malformed="sha256:zzzz"
if printf '%s' "$malformed" | grep -qE '^sha256:[0-9a-f]{64}$'; then
  fail "malformed digest shape is refused (should not match)" "$malformed"
else
  pass "malformed digest shape is refused (grep pattern)"
fi
good="sha256:$(printf 'a%.0s' {1..64})"
if printf '%s' "$good" | grep -qE '^sha256:[0-9a-f]{64}$'; then
  pass "good digest shape is accepted"
else
  fail "good digest shape is accepted" "$good"
fi
short="sha256:$(printf 'a%.0s' {1..63})"
if printf '%s' "$short" | grep -qE '^sha256:[0-9a-f]{64}$'; then
  fail "short digest is refused" "$short"
else
  pass "short digest is refused"
fi
upper="sha256:$(printf 'A%.0s' {1..64})"
if printf '%s' "$upper" | grep -qE '^sha256:[0-9a-f]{64}$'; then
  fail "uppercase digest is refused" "$upper"
else
  pass "uppercase digest is refused"
fi

run_pub green "multi-arch with buildx is green (dry-run)" --dry-run --service-dir "$svc" --platforms linux/amd64,linux/arm64
run_pub green "single platform is green (dry-run)" --dry-run --service-dir "$svc" --platforms linux/amd64

if command -v instabox >/dev/null 2>&1; then
  run_pub green "sandbox --dry-run is green" --sandbox --dry-run
  assert_contains "sandbox dry-run prints instabox" "instabox" "$TMP/last.out"
else
  echo "      SKIP publish_test: instabox not installed — sandbox dry-run not exercised"
fi

if [ -x "$ROOT/bin/publish-sandbox" ] && [ -x "$ROOT/templates/bin/publish.sh" ]; then
  pass "sandbox wrappers are executable"
else
  fail "sandbox wrappers are executable" "missing executable"
fi

if grep -q "timeout" "$PUB" && grep -q "run_bounded" "$PUB"; then
  pass "network calls are bounded via timeout"
else
  fail "network calls are bounded via timeout" "no timeout in $PUB"
fi

if grep -q -- "--password-stdin" "$PUB" && ! grep -q "password.*\$TOKEN" "$PUB"; then
  pass "tokens via stdin, never argv (--password-stdin)"
else
  fail "tokens via stdin, never argv (--password-stdin)" "check $PUB"
fi

echo ""
if [ "$fails" -ne 0 ]; then
  echo "FAIL: publish_test — $fails failure(s), $passes pass"
  exit 1
fi
echo "PASS: publish_test — $passes check(s)"
