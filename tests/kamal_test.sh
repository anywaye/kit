#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

pass=0
fail=0
skip=0

ok() { printf 'PASS %s\n' "$1"; pass=$((pass + 1)); }
no() {
  printf 'FAIL %s\n' "$1"
  shift
  [ "$#" -eq 0 ] || printf '     %s\n' "$@"
  fail=$((fail + 1))
}
sk() { printf 'SKIP %s\n' "$1"; skip=$((skip + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-kamal-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

KAMAL="$(command -v kamal || true)"
KAMAL_BACKUP="$(command -v kamal-backup || true)"
RUBY="$(command -v ruby || true)"

if [ -z "$KAMAL" ] || [ -z "$KAMAL_BACKUP" ] || [ -z "$RUBY" ]; then
  sk 'kamal + kamal-backup + ruby (the real binaries render and validate the config)'
  printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
  echo "SKIP: kamal_test — the real binaries are not installed, so the generated config was not validated by anything."
  exit 0
fi

printf '     kamal %s, kamal-backup %s\n' \
  "$("$KAMAL" version 2>/dev/null | tail -1)" \
  "$("$KAMAL_BACKUP" version 2>/dev/null | tail -1)"

with_secrets() {
  if [ -n "$TIMEOUT_BIN" ]; then
    env "${SECRETS[@]}" "$TIMEOUT_BIN" 120 "$@"
  else
    env "${SECRETS[@]}" "$@"
  fi
}

SERVICE_NAME=kitprobe
REPO=kitprobe
ORG=anywaye
DOMAIN=kitprobe.invalid
WEB_HOST=198.51.100.7

render_service() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$dest/config"
  KIT_SERVICE="$SERVICE_NAME" \
    KIT_REGISTRY_ORG="$ORG" \
    KIT_REPO="$REPO" \
    KIT_WEB_HOST="$WEB_HOST" \
    KIT_APP_DOMAIN="$DOMAIN" \
    "$RUBY" -rerb -e '
      src, dst, subs = ARGV
      subs = subs.split(",").map { |p| p.split("=", 2) }.to_h
      out = ERB.new(File.read(src), trim_mode: "-").result
      out.gsub!(/<%=\s*(\w+)\s*%>/) { subs.fetch(Regexp.last_match(1), Regexp.last_match(0)) }
      File.write(dst, out)
    ' "$ROOT/templates/kamal/deploy.yml.erb" "$dest/config/deploy.yml" "service=$SERVICE_NAME" \
    || return 1

  KIT_SERVICE="$SERVICE_NAME" \
    "$RUBY" -rerb -e '
      src, dst, subs = ARGV
      subs = subs.split(",").map { |p| p.split("=", 2) }.to_h
      out = ERB.new(File.read(src), trim_mode: "-").result
      out.gsub!(/<%=\s*(\w+)\s*%>/) { subs.fetch(Regexp.last_match(1), Regexp.last_match(0)) }
      File.write(dst, out)
    ' "$ROOT/templates/kamal/kamal-backup.yml.erb" "$dest/config/kamal-backup.yml" "service=$SERVICE_NAME"
}

SECRETS=(
  "KAMAL_REGISTRY_PASSWORD=kitprobe-registry-not-a-real-secret"
  "POSTGRES_PASSWORD=kitprobe-postgres-not-a-real-secret"
  "DATABASE_URL=postgres://kitprobe:kitprobe-db-not-real@kitprobe-postgres:5432/kitprobe"
  "DATABASE_PASSWORD=kitprobe-db-not-real"
  "RESTIC_REPOSITORY=s3:https://kitprobe.r2.cloudflarestorage.com/kitprobe-db-backups"
  "RESTIC_PASSWORD=kitprobe-restic-not-real"
  "AWS_ACCESS_KEY_ID=kitprobeaccesskeyid"
  "AWS_SECRET_ACCESS_KEY=kitproposesecretaccesskey"
)


svc="$WORK/kitprobe"
if ! render_service "$svc"; then
  no 'kamal config  (the template renders)' 'ERB rendering of templates/kamal/*.erb failed'
else
  if [ -s "$svc/config/deploy.yml" ]; then
    ok 'kamal config  (the template renders to a non-empty config)'
  else
    no 'kamal config  (the template renders to a non-empty config)' 'config/deploy.yml is empty'
  fi

  out="$(cd "$svc" && with_secrets "$KAMAL" config --version latest 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    ok 'kamal config  (the real binary accepts the generated deploy.yml)'
  else
    no 'kamal config  (the real binary accepts the generated deploy.yml)' \
      "exit ${rc}" "$(printf '%s' "$out" | tail -3)"
  fi

  if printf '%s' "$out" | grep -qE "^:repository: ${REGISTRY_HOST:-ghcr\.io}/ghcr\.io/"; then
    no 'kamal config  (the image name is not double-prefixed with the registry host)' \
      "resolved to $(printf '%s' "$out" | grep -E '^:repository:')"
  elif printf '%s' "$out" | grep -qE "^:repository: ghcr\.io/${ORG}/${REPO}$"; then
    ok 'kamal config  (the image name is not double-prefixed with the registry host)'
  else
    no 'kamal config  (the image name is not double-prefixed with the registry host)' \
      "expected :repository: ghcr.io/${ORG}/${REPO}, got $(printf '%s' "$out" | grep -E '^:repository:')"
  fi

  leaked=''
  for pair in "${SECRETS[@]}"; do
    value="${pair#*=}"
    case "$value" in
      *"$SERVICE_NAME"* | *not-a-real-secret* | *not-real* | *kitprobeaccesskeyid* | *kitproposesecretaccesskey*) ;;
      *) continue ;;
    esac
    if printf '%s' "$out" | grep -qF "$value"; then
      leaked="$leaked ${pair%%=*}"
    fi
  done
  if [ -z "$leaked" ]; then
    ok 'kamal config  (no secret value appears in the rendered config)'
  else
    no 'kamal config  (no secret value appears in the rendered config)' "leaked:$leaked"
  fi
fi

if [ -d "$svc" ]; then
  out="$(cd "$svc" && with_secrets "$KAMAL_BACKUP" validate -c config/deploy.yml 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qx 'ok'; then
    ok 'kamal-backup validate  (the real binary accepts deploy.yml + kamal-backup.yml)'
  else
    no 'kamal-backup validate  (the real binary accepts deploy.yml + kamal-backup.yml)' \
      "exit ${rc}" "$(printf '%s' "$out" | tail -3)"
  fi

  broken="$WORK/crossfile"
  cp -R "$svc" "$broken"
  python3 - "$broken/config/deploy.yml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\n        - RESTIC_REPOSITORY(?=\n        - RESTIC_PASSWORD)', '', s, count=1)
open(p, 'w').write(s)
PY
  out="$(cd "$broken" && with_secrets "$KAMAL_BACKUP" validate -c config/deploy.yml 2>&1)"
  if printf '%s' "$out" | grep -q 'RESTIC_REPOSITORY or RESTIC_REPOSITORY_FILE is required'; then
    ok 'kamal-backup validate  (a secret named in kamal-backup.yml but not the accessory is REJECTED)'
  else
    no 'kamal-backup validate  (a secret named in kamal-backup.yml but not the accessory is REJECTED)' \
      "expected the RESTIC_REPOSITORY complaint, got: $(printf '%s' "$out" | tail -2)"
  fi
fi

unsetvar="$WORK/unset"
rm -rf "$unsetvar"
mkdir -p "$unsetvar/config"
if KIT_SERVICE="$SERVICE_NAME" KIT_REGISTRY_ORG="$ORG" KIT_REPO="$REPO" KIT_APP_DOMAIN="$DOMAIN" \
  "$RUBY" -rerb -e 'puts ERB.new(File.read(ARGV[0]), trim_mode: "-").result' \
  "$ROOT/templates/kamal/deploy.yml.erb" >"$unsetvar/config/deploy.yml" 2>"$unsetvar/err"; then
  no 'deploy.yml.erb  (a missing KIT_* variable fails the render with a named error)' \
    'the template rendered successfully with KIT_WEB_HOST unset'
else
  if grep -q 'KIT_WEB_HOST' "$unsetvar/err"; then
    ok 'deploy.yml.erb  (a missing KIT_* variable fails the render with a named error)'
  else
    no 'deploy.yml.erb  (a missing KIT_* variable fails the render with a named error)' \
      "the error does not name the variable: $(tail -2 "$unsetvar/err")"
  fi
fi

for pair in "keep_last: 7" "keep_daily: 7" "keep_weekly: 4" "keep_monthly: 6" "keep_yearly: 2"; do
  if grep -qF "$pair" "$ROOT/templates/kamal/kamal-backup.yml.erb"; then
    ok "kamal-backup.yml.erb  (retention ${pair%%:*} is stated, not inherited)"
  else
    no "kamal-backup.yml.erb  (retention ${pair%%:*} is stated, not inherited)" \
      "missing '${pair}' — it would fall through to the gem's default"
  fi
done

resolved="$svc/config/deploy.yml"
if [ -d "$svc" ] && [ -f "$resolved" ]; then
  accessories_block() {
    awk '/^:accessories:/{p=1} p && seen && /^[^ ]/{exit} p{print; seen=1}' "$1"
  }

  published="$(cd "$svc" && with_secrets "$KAMAL" config --version latest 2>/dev/null |
    accessories_block /dev/stdin | grep -cE '^[[:space:]]+(port:|:port):' || true)"
  if [ "$published" -eq 0 ]; then
    ok 'kamal config  (no accessory publishes a port on the host)'
  else
    no 'kamal config  (no accessory publishes a port on the host)' \
      "the resolved accessories block has ${published} port line(s). A `port:` on an accessory becomes
       docker run --publish, which binds 0.0.0.0 and :: when it names no host address, so the
       database is on every interface the host has. Delete the line: the app reaches the accessory by
       container name on the kamal network, and nothing needs it published."
  fi

  planted="$WORK/planted-port"
  cp -R "$svc" "$planted"
  python3 - "$planted/config/deploy.yml" <<'PY'
import re, sys
p = sys.argv[1]
lines = open(p).read().split("\n")
for i, line in enumerate(lines):
    if re.fullmatch(r"    host: \S+", line) and any("postgres:17-alpine" in x for x in lines[max(0, i - 5):i]):
        lines.insert(i + 1, "    port: 5432")
        break
else:
    raise SystemExit("no accessory host line to plant after")
open(p, "w").write("\n".join(lines))
PY
  planted_out="$(cd "$planted" && with_secrets "$KAMAL" config --version latest 2>&1)"
  if printf '%s' "$planted_out" | accessories_block /dev/stdin | grep -qE '^[[:space:]]+port: 5432$'; then
    ok 'kamal config  (a planted accessory `port:` reaches the resolved document — the check above can see it)'
  else
    no 'kamal config  (a planted accessory port line reaches the resolved document — the check above can see it)' \
      'planted a "port: 5432" line and the resolved accessories block did not carry it, so the
       check above would pass for the wrong reason. Resolved block:' \
      "$(printf '%s' "$planted_out" | accessories_block /dev/stdin)"
  fi
fi

DRILL="$ROOT/templates/kamal/drill.sh"

check_out="$(SERVICE_ROOT="$svc" bash "$DRILL" --table users --print-check 2>&1)"
case "$check_out" in
  *"ON_ERROR_STOP=1"*)
    ok 'drill.sh  (the check asserts rather than reports)'
    ;;
  *)
    no 'drill.sh  (the check asserts rather than reports)' "got: $(printf '%s' "$check_out" | head -3)"
    ;;
esac

case "$check_out" in
  *"RAISE EXCEPTION"*)
    ok 'drill.sh  (an empty restored table raises, so an empty restore fails the drill)'
    ;;
  *)
    no 'drill.sh  (an empty restored table raises, so an empty restore fails the drill)' \
      'the generated check contains no RAISE EXCEPTION'
    ;;
esac

for hostile in kitprobe_production prod_kitprobe myprodkitprobe kitprobe_live kitprobe_proddata; do
  out="$(SERVICE_ROOT="$svc" bash "$DRILL" --table users --scratch "$hostile" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    no "drill.sh  (refuses the production-looking scratch name '${hostile}')" 'it proceeded'
  elif printf '%s' "$out" | grep -q 'refusing to drill'; then
    ok "drill.sh  (refuses the production-looking scratch name '${hostile}')"
  else
    no "drill.sh  (refuses the production-looking scratch name '${hostile}')" \
      "exit ${rc} but the message was: $(printf '%s' "$out" | head -1)"
  fi
done

out="$(SERVICE_ROOT="$svc" bash "$DRILL" --table users --print-check 2>&1)"
if [ "$?" -eq 0 ] && printf '%s' "$out" | grep -q -- '--dbname=kitprobe_drill'; then
  ok 'drill.sh  (the default scratch name is accepted — the control for the refusals)'
else
  no 'drill.sh  (the default scratch name is accepted — the control for the refusals)' \
    "got: $(printf '%s' "$out" | head -2)"
fi

out="$(SERVICE_ROOT="$svc" bash "$DRILL" --print-check 2>&1)"
if [ "$?" -ne 0 ] && printf '%s' "$out" | grep -q 'usage:'; then
  ok 'drill.sh  (a drill with no content table is a usage error, not a silent pass)'
else
  no 'drill.sh  (a drill with no content table is a usage error, not a silent pass)' \
    "got: $(printf '%s' "$out" | head -2)"
fi

case "$check_out" in
  *kitprobe-db-not-real* | *not-a-real-secret* | *kitproposesecretaccesskey*)
    no 'drill.sh  (the generated check carries no credential)'
    ;;
  *)
    ok 'drill.sh  (the generated check carries no credential)'
    ;;
esac

printf '\n'
if [ "$fail" -ne 0 ]; then
  printf 'FAIL: kamal_test — %d of %d case(s) failed.\n' "$fail" "$((pass + fail))"
  exit 1
fi
if [ "$skip" -ne 0 ]; then
  printf 'FAIL: kamal_test — %d case(s) skipped. A skipped proof is not a proof.\n' "$skip"
  exit 1
fi
printf 'PASS: kamal_test — %d case(s), every one against the real binaries.\n' "$pass"
