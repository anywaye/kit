#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STAMP="$ROOT/docker/provenance.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/kit-provenance-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

_pass=0
_fail=0
_skip=0

pass() { _pass=$((_pass + 1)); printf 'PASS %s\n' "$1"; }
fail() { _fail=$((_fail + 1)); printf 'FAIL %s\n' "$1"; }
skip() { _skip=$((_skip + 1)); printf 'SKIP %s\n' "$1"; }

contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

stamp() {
  env -u KIT_PROVENANCE_SOURCE -u KIT_PROVENANCE_REVISION -u KIT_PROVENANCE_BUILT_AT \
    -u KIT_PROVENANCE_SOURCE_DIRTY -u KIT_PROVENANCE_TEMPLATE_VERSION \
    "KIT_PROVENANCE_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')=$2" \
    sh "$STAMP" --validate 2>&1
}

GOOD_REV=0123456789abcdef0123456789abcdef01234567

control_out="$(stamp revision "$GOOD_REV")"
if [ $? -eq 0 ] && ! contains "$control_out" refusing; then
  pass "control: a 40-hex revision is accepted, so the refusals below mean something"
else
  fail "control: a 40-hex revision was NOT accepted: $control_out"
fi

refuse() {
  local field="$1" value="$2" why="$3" out ec
  out="$(stamp "$field" "$value")"
  ec=$?
  if [ "$ec" -eq 0 ]; then
    fail "redaction: $field=$value was STAMPED — $why"
    return
  fi
  if ! contains "$out" "refusing to stamp $field"; then
    fail "redaction: $field=$value was refused but not by name (got: $out) — $why"
    return
  fi
  pass "redaction: $field=$value refused ($why)"
}

refuse source 'kaka@anywaye.com' 'a developer identity, and an email-shaped string'
refuse source '/Users/kaka/Code/any/moon' 'a local working directory'
refuse source 'pg.corp.internal:5432' 'an internal hostname'
refuse source 'https://github.corp/anywaye/identity' 'a URL, so a host we do not control'
refuse source '../anywaye/identity' 'a relative path'
refuse revision 'ghp_16C7aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 'a credential in the revision field'
refuse revision 'worker/kit-provenance-01' 'a branch name where a commit is claimed'
refuse revision '0123456' 'a short sha, which git prints by default'
refuse revision '0123456789ABCDEF0123456789ABCDEF01234567' 'uppercase hex, which two consumers would spell differently'
refuse built_at 'kaka@anywaye.com' 'a developer identity in the timestamp field'
refuse built_at '2026-10-03 09:20:00+01:00' 'a non-RFC3339, zone-offset timestamp'
refuse source_dirty 'modified: go/cmd/service/main.go' 'a dirty file list, which is a local path'
refuse source_dirty 'yes' 'a boolean spelled freely rather than clean/dirty'
refuse template_version '0.1.0' 'a template version with no v prefix'

stamp source 'worker/kit-provenance-01' >/dev/null 2>&1
if [ $? -eq 0 ]; then
  pass "the asymmetry, asserted: a branch-shaped source is accepted, because no grammar can tell it from owner/repo and the registry publishes it as a tag anyway"
else
  fail "the asymmetry: a branch-shaped source was refused — if this ever becomes true the header in docker/provenance.sh is WRONG and must be rewritten, not the grammar"
fi

unset_out="$(env -u KIT_PROVENANCE_SOURCE -u KIT_PROVENANCE_REVISION -u KIT_PROVENANCE_BUILT_AT \
  -u KIT_PROVENANCE_SOURCE_DIRTY -u KIT_PROVENANCE_TEMPLATE_VERSION \
  sh "$STAMP" --validate 2>&1)"
if [ $? -eq 0 ]; then
  pass "an unstamped local build is accepted (every field falls back to unknown)"
else
  fail "an unstamped local build was REFUSED: $unset_out"
fi



expected_labels='org.opencontainers.image.source
org.opencontainers.image.revision
org.opencontainers.image.created
com.anywaye.kit.source.dirty
com.anywaye.kit.template.version'

env -u KIT_PROVENANCE_SOURCE -u KIT_PROVENANCE_REVISION -u KIT_PROVENANCE_BUILT_AT \
  -u KIT_PROVENANCE_SOURCE_DIRTY -u KIT_PROVENANCE_TEMPLATE_VERSION \
  sh "$STAMP" --write "$TMP/probe.json" >/dev/null 2>&1
written_keys="$(sed -n 's/^  "\([a-z_]*\)":.*/\1/p' "$TMP/probe.json" | sort | tr '\n' ' ')"

expected_keys='built_at revision source source_dirty template_version '
if [ "$written_keys" = "$expected_keys" ]; then
  pass "the file sink writes exactly the five fields, and nothing else"
else
  fail "the file sink wrote [$written_keys], expected [$expected_keys]"
fi

langs='bun elixir go node python ruby rust'
for lang in $langs; do
  df="$ROOT/docker/Dockerfile.$lang"
  if [ ! -f "$df" ]; then
    fail "agreement: $df does not exist"
    continue
  fi
  got="$(grep -v '^[[:space:]]*#' "$df" |
    grep -oE '(org\.opencontainers\.image\.[a-z]+|com\.anywaye\.kit\.[a-z.]+)=' |
    sed 's/=$//' | sort -u | tr '\n' ' ')"
  want="$(printf '%s\n' "$expected_labels" | sort | tr '\n' ' ')"
  if [ "$got" != "$want" ]; then
    fail "agreement: Dockerfile.$lang labels [$got] != the script's [$want]"
    continue
  fi
  missing=''
  for key in org.opencontainers.image.source org.opencontainers.image.revision \
    org.opencontainers.image.created com.anywaye.kit.source.dirty \
    com.anywaye.kit.template.version; do
    case "$key" in
      org.opencontainers.image.source) arg='KIT_PROVENANCE_SOURCE' ;;
      org.opencontainers.image.revision) arg='KIT_PROVENANCE_REVISION' ;;
      org.opencontainers.image.created) arg='KIT_PROVENANCE_BUILT_AT' ;;
      com.anywaye.kit.source.dirty) arg='KIT_PROVENANCE_SOURCE_DIRTY' ;;
      com.anywaye.kit.template.version) arg='KIT_PROVENANCE_TEMPLATE_VERSION' ;;
    esac
    grep -q "^ARG $arg=" "$df" || missing="$missing $arg"
  done
  if [ -n "$missing" ]; then
    fail "agreement: Dockerfile.$lang has label(s) with no ARG:$missing — they would expand to empty"
  else
    pass "agreement: Dockerfile.$lang declares all five labels and all five ARGs"
  fi
done

for lang in $langs; do
  df="$ROOT/docker/Dockerfile.$lang"
  grep -q '^LABEL org.opencontainers.image.source=' "$df" ||
    fail "stamp: Dockerfile.$lang declares the provenance ARGs but no LABEL"
  grep -q 'provenance.sh --write' "$df" ||
    fail "stamp: Dockerfile.$lang writes no provenance file"
done
pass "stamp: all seven Dockerfiles write both sinks (per-language findings above, if any)"


if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  skip "build: no docker, so the two sinks were not compared on a real image and --verify was not exercised"
else
  GO=0123456789abcdef0123456789abcdef01234567
  GOOD_IMAGE="kit-provenance-test-$$:good"
  PLAIN_IMAGE="kit-provenance-test-$$:plain"
  BAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  fixture="$TMP/svc"
  mkdir -p "$fixture/docker" "$fixture/cmd/service"
  cp "$ROOT/docker/Dockerfile.go" "$ROOT/docker/entrypoint.sh" "$ROOT/docker/provenance.sh" "$fixture/docker/"
  printf 'module svc\n\ngo 1.24\n' >"$fixture/go.mod"
  : >"$fixture/go.sum"
  printf 'package main\n\nfunc main() {}\n' >"$fixture/cmd/service/main.go"

  if docker build -q -f "$fixture/docker/Dockerfile.go" -t "$GOOD_IMAGE" \
    --build-arg KIT_PROVENANCE_SOURCE=anywaye/identity \
    --build-arg KIT_PROVENANCE_REVISION="$GO" \
    --build-arg KIT_PROVENANCE_BUILT_AT=2026-10-03T09:20:00Z \
    --build-arg KIT_PROVENANCE_SOURCE_DIRTY=clean \
    --build-arg KIT_PROVENANCE_TEMPLATE_VERSION=v0.1.0 \
    "$fixture" >/dev/null 2>&1; then
    pass "build: a real image built from docker/Dockerfile.go with all five build args"
  else
    fail "build: docker/Dockerfile.go did not build with the provenance block in it"
    printf '\n%d passed, %d failed, %d skipped\n' "$_pass" "$_fail" "$_skip"
    exit 1
  fi

  l_rev="$(docker image inspect "$GOOD_IMAGE" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null)"
  cid="$(docker create "$GOOD_IMAGE" 2>/dev/null)"
  f_rev=""
  if [ -n "$cid" ]; then
    f_rev="$(docker cp "$cid:/app/kit-provenance.json" - 2>/dev/null | tar -xO kit-provenance.json 2>/dev/null |
      sed -n 's/.*"revision": "\([^"]*\)".*/\1/p')"
    docker rm -f "$cid" >/dev/null 2>&1
  fi
  if [ -n "$l_rev" ] && [ "$l_rev" = "$f_rev" ] && [ "$l_rev" = "$GO" ]; then
    pass "sinks: the label and the file name the same commit on a real image"
  else
    fail "sinks: label=[$l_rev] file=[$f_rev] expected=[$GO] — a stamp that disagrees with itself is worse than none"
  fi

  sh "$STAMP" --verify "$GOOD_IMAGE" --expect-revision "$GO" >/dev/null 2>&1
  [ $? -eq 0 ] && pass "verify: the expected commit exits 0" || fail "verify: the expected commit did NOT exit 0"

  red="$(sh "$STAMP" --verify "$GOOD_IMAGE" --expect-revision "$BAD" 2>&1)"
  ec=$?
  if [ "$ec" -ne 0 ] && contains "$red" "$BAD"; then
    pass "verify: a WRONG commit exits $ec and names both commits — this is the check being able to fail"
  else
    fail "verify: a wrong commit exited $ec (want non-zero) with [$red]"
  fi

  printf 'FROM debian:12-slim\nCMD ["true"]\n' >"$TMP/plain.Dockerfile"
  docker build -q -f "$TMP/plain.Dockerfile" -t "$PLAIN_IMAGE" "$TMP" >/dev/null 2>&1
  red2="$(sh "$STAMP" --verify "$PLAIN_IMAGE" 2>&1)"
  ec2=$?
  if [ "$ec2" -ne 0 ] && contains "$red2" "no labels"; then
    pass "verify: an image with no stamp exits $ec2 and says so — distinct from the wrong-commit answer"
  else
    fail "verify: an unstamped image exited $ec2 with [$red2]"
  fi

  red3="$(sh "$STAMP" --verify "$GOOD_IMAGE" --expect-revision unknown 2>&1)"
  ec3=$?
  if [ "$ec3" -ne 0 ] && contains "$red3" "unknown"; then
    pass "verify: an image stamped unknown FAILS an assertion — unstamped is fine to create and not fine to assert about"
  else
    fail "verify: asserting `unknown` exited $ec3 with [$red3]"
  fi

  docker rmi -f "$GOOD_IMAGE" "$PLAIN_IMAGE" >/dev/null 2>&1
fi


STUB="$TMP/stubbin"
mkdir -p "$STUB"
cat >"$STUB/docker" <<'STUBEOF'
#!/bin/sh
[ "${1:-}" = 'image' ] || { printf 'stub: unhandled docker %s\n' "$1" >&2; exit 127; }
case "$3" in
  null) printf 'null\n'; exit 0 ;;
  inherit)
    printf '%s\n' '{"org.opencontainers.image.created":"2026-04-10T03:06:38.682Z","org.opencontainers.image.revision":"700fc117a2fd01ac0201deaa6fa69c5557acb04f","org.opencontainers.image.source":"https://github.com/oven-sh/bun"}'
    exit 0 ;;
  inheritshape)
    printf '%s\n' '{"org.opencontainers.image.created":"2026-10-03T09:20:00Z","org.opencontainers.image.revision":"0123456789abcdef0123456789abcdef01234567","org.opencontainers.image.source":"oven-sh/bun"}'
    exit 0 ;;
  ours) printf '%s\n' '{"com.anywaye.kit.source.dirty":"clean","com.anywaye.kit.template.version":"v0.1.0","org.opencontainers.image.created":"2026-10-03T09:20:00Z","org.opencontainers.image.revision":"0123456789abcdef0123456789abcdef01234567","org.opencontainers.image.source":"anywaye/gateway"}'
    exit 0 ;;
  foreign) printf '%s\n' '{"com.anywaye.kit.source.dirty":"clean","com.anywaye.kit.template.version":"v0.1.0","org.opencontainers.image.created":"2026-10-03T09:20:00Z","org.opencontainers.image.revision":"0123456789abcdef0123456789abcdef01234567","org.opencontainers.image.source":"oven-sh/bun"}'
    exit 0 ;;
  badshape) printf '%s\n' '{"com.anywaye.kit.source.dirty":"clean","com.anywaye.kit.template.version":"v0.1.0","org.opencontainers.image.created":"2026-10-03T09:20:00Z","org.opencontainers.image.revision":"0123456789abcdef0123456789abcdef01234567","org.opencontainers.image.source":"https://github.com/anywaye/gateway"}'
    exit 0 ;;
  *) printf 'stub: unhandled fixture %s\n' "$3" >&2; exit 127 ;;
esac
STUBEOF
chmod +x "$STUB/docker"

VERIFY_EC=0
stub_verify() {
  _fx="$1"; shift
  STUB_OUT="$(PATH="$STUB:$PATH" sh "$STAMP" --verify "$_fx" "$@" 2>&1)"; VERIFY_EC=$?
}

verify_exits() {
  local want="$1" label="$2" fixture="$3"
  shift 3
  stub_verify "$fixture" "$@"
  if [ "$VERIFY_EC" -ne "$want" ]; then
    fail "verify/$label: exited $VERIFY_EC, want $want — [$STUB_OUT]"
    return
  fi
  pass "verify/$label: exits $want"
}

verify_says() {
  local needle="$1" label="$2" want="$3" fixture="$4"
  shift 4
  stub_verify "$fixture" "$@"
  if [ "$VERIFY_EC" -ne "$want" ]; then
    fail "verify/$label: exited $VERIFY_EC, want $want — [$STUB_OUT]"
    return
  fi
  if ! contains "$STUB_OUT" "$needle"; then
    fail "verify/$label: exited $want but the message never said \"$needle\" — [$STUB_OUT]"
    return
  fi
  pass "verify/$label: exits $want and names \"$needle\""
}

verify_exits 6 'D1 inherited base-image labels are refused with NO flags at all' inherit
verify_says 'oven-sh/bun' 'D1b the refusal NAMES Bun rather than us' 6 inherit
verify_exits 6 'D2 inherited labels are refused even asserting our own repo' inherit --expect-source anywaye/gateway

verify_exits 6 'D2a a stamp in kit'"'"'s own grammar but with NO kit namespace is refused' inheritshape
verify_says 'BASE' 'D2b and the refusal is the NAMESPACE one, not shape and not the warning' 6 inheritshape

verify_exits 5 'D3 a well-formed FOREIGN source fails --expect-source' foreign --expect-source anywaye/gateway
verify_says 'OWNERSHIP OF THE REPOSITORY WAS NOT ESTABLISHED' 'D4 no --expect-source warns at exit 0' 0 foreign
verify_says 'unknown was expected' 'D5 asserting `unknown` fails and names the expectation' 5 ours --expect-source unknown

verify_exits 6 'D6 a source violating the shape grammar fails on shape' badshape --expect-source anywaye/gateway
verify_says 'it must be owner/repo' 'D7 and the failure carries the expect_* line' 6 badshape --expect-source anywaye/gateway

verify_exits 0 'D8 a correct stamp with matching --expect-source and --expect-revision' ours --expect-source anywaye/gateway --expect-revision 0123456789abcdef0123456789abcdef01234567
verify_says 'no labels at all' 'D9 an image with NO labels still exits 4, not 6' 4 null

bad_expect="$(PATH="$STUB:$PATH" sh "$STAMP" --verify ours --expect-source 'https://github.com/anywaye/kit' 2>&1)"
bad_expect_ec=$?
if [ "$bad_expect_ec" -ne 0 ] && contains "$bad_expect" 'refusing to ASSERT source'; then
  pass "verify/D10 --expect-source is itself grammar-checked, so a URL expectation is refused rather than reported as a mismatch"
else
  fail "verify/D10 --expect-source https://… exited $bad_expect_ec with [$bad_expect]"
fi

stub_verify ours --expect-source anywaye/gateway
if contains "$STUB_OUT" '<absent>'; then
  fail "verify/D11 a fully stamped image reported an absent field: [$STUB_OUT]"
elif contains "$STUB_OUT" 'note:'; then
  fail "verify/D11 a fully stamped image printed an absent-field note: [$STUB_OUT]"
else
  pass "verify/D11 a fully stamped image notes nothing as absent, so the note still carries information"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$_pass" "$_fail" "$_skip"
[ "$_fail" -eq 0 ]