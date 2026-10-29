#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT/templates/bin/deploy.sh"
REDACTOR="$ROOT/templates/deploy/redact.py"
COMPOSE_REF="$ROOT/templates/deploy/reference/courier.deploy.yml"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-deploy-test.XXXXXX")"
PROJECT="kit-deploy-test-$$"
LEDGER_DIR="$WORK/ledger"
DEPLOY_LOG="$WORK/deploy.log"

PY="${KIT_PYTHON:-$ROOT/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

failures=0
passes=0
skips=0

pass() {
  printf 'PASS  %s\n' "$1"
  passes=$((passes + 1))
}
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
skip() {
  printf 'SKIP  %s\n' "$1"
  skips=$((skips + 1))
}
note() { printf 'NOTE  %s\n' "$1"; }

wait_until() {
  local label="$1" deadline="$2"
  shift 2
  local start now out
  start=$(date +%s)
  while :; do
    if out="$("$@" 2>&1)"; then
      return 0
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$deadline" ]; then
      printf '      timed out after %ss waiting for: %s\n' "$deadline" "$label"
      printf '%s\n' "$out" | tail -20 | sed 's/^/        /' || true
      return 1
    fi
    sleep 1
  done
}

app_cid() { dc ps --quiet app 2>/dev/null | head -1; }
db_cid() { dc ps --quiet db 2>/dev/null | head -1; }

dc() {
  SERVICE_NAME=courier KIT_DEPLOY_IMAGE="${IMAGE_A:-unused}" \
    docker compose --project-name "$PROJECT" --file "$COMPOSE_REF" "$@"
}

health_of() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo gone; }
image_of() { docker inspect -f '{{.Image}}' "$1" 2>/dev/null || echo none; }
image_ref_of() { docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null || echo none; }
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || echo 000; }

cleanup() {
  SERVICE_NAME=courier KIT_DEPLOY_IMAGE="${IMAGE_A:-unused-at-teardown}" \
    docker compose --project-name "$PROJECT" --file "$COMPOSE_REF" \
    down --volumes --remove-orphans >/dev/null 2>&1 || true
  docker image rm "${IMAGE_A:-none}-rollback-target" >/dev/null 2>&1 || true
  docker image rm "${IMAGE_A:-none}-bad-release" >/dev/null 2>&1 || true
  docker rm -f "kit16-not-ours-c-$$" >/dev/null 2>&1 || true
  docker volume rm "kit16-not-ours-v-$$" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

printf -- '-- 1. the redactor redacts, and does not delete the line\n'

SECRET_ONE="$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
SECRET_TWO="KIT16CANARY-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
JWT_CANARY="eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJraXQxNiJ9.Q1lOYVJZTEZBS1JFU1VMVFRFU1FMkE"
URL_CANARY="postgres://courier:${SECRET_TWO}@db:5432/courier"
B64_CANARY="sk-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"

redact_with() {
  local text="$1"
  shift
  local -a s=("$@")
  printf '%s' "$text" | "$PY" "$REDACTOR" --secrets-fd 3 3< <(printf '%s\n' "${s[@]}")
}

out="$(redact_with "connecting with ${SECRET_ONE} to the database" "$SECRET_ONE")"
case "$out" in
  *"$SECRET_ONE"*) fail "the redactor left a known secret value in the output" ;;
  *)
    case "$out" in
      *"[redacted:"*"database"*) pass "a known secret value is redacted and the sentence survives" ;;
      *) fail "the secret was removed but so was the sentence: $out" ;;
    esac
    ;;
esac

out="$(redact_with "auth header: Bearer ${SECRET_ONE}; user=alice" "$SECRET_ONE")"
case "$out" in
  *"$SECRET_ONE"*) fail "the redactor left a secret inside a bearer token" ;;
  *user=alice*) pass "a secret embedded in a bearer token is redacted, context kept" ;;
  *) fail "the whole line was destroyed: $out" ;;
esac

out="$(redact_with "url=${URL_CANARY}" "$SECRET_ONE")"
case "$out" in
  *"${SECRET_TWO}"*) fail "the redactor left a password inside a connection URL" ;;
  *redacted*) pass "a password inside a connection URL is redacted" ;;
  *) fail "the URL was not recognised: $out" ;;
esac

out="$(redact_with "token payload ${JWT_CANARY} rejected" "$SECRET_ONE")"
case "$out" in
  *"$JWT_CANARY"*) fail "the redactor left a JWT in the output" ;;
  *rejected*) pass "a JWT the deploy never supplied is redacted by shape alone" ;;
  *) fail "the JWT line was destroyed: $out" ;;
esac

out="$(redact_with "upstream said: ${B64_CANARY}" "$SECRET_ONE")"
case "$out" in
  *"$B64_CANARY"*) fail "the redactor left a provider-style key in the output" ;;
  *upstream*) pass "a provider key is redacted by shape alone" ;;
  *) fail "the provider key line was destroyed: $out" ;;
esac

out="$(redact_with "starting service: app; waiting for health gate; 3 services healthy" "$SECRET_ONE")"
case "$out" in
  *"starting service: app; waiting for health gate; 3 services healthy"*) pass "ordinary operational text is not masked" ;;
  *) fail "the redactor mangled ordinary text: $out" ;;
esac

out="$(redact_with "value=ok done" "ok")"
case "$out" in
  *"ok done"*) pass "a sub-minimum-length value is not scrubbed as a literal" ;;
  *) fail "a 2-character value was scrubbed as a literal: $out" ;;
esac

printf -- '-- 1b. every printed line is filtered, not just the first\n'

cat >"$WORK/deploy-lib.sh" <<EOF
$(sed -e 's|^main "\$@"$|# main "\$@"  (stripped: this is the library probe)|' "$DEPLOY")
secret_values_set() {
  SECRET_NAMES=(CANARY_KEY)
  SECRET_VALUES=("\$1")
  SECRET_PAIRS=("CANARY_KEY=\$1")
}
EOF

LIB="$WORK/deploy-lib.sh"

CANARY3="kit16CanaryStream3f9a2c7e1b4d8065"
out="$(LIB="$LIB" PROBE_REDACTOR="$REDACTOR" PROBE_CANARY="$CANARY3" bash -c '
  set -euo pipefail
  . "$LIB"
  REDACTOR="$PROBE_REDACTOR"
  DEFAULT_REDACTOR="$PROBE_REDACTOR"
  setup_redaction
  secret_values_set "$PROBE_CANARY"
  for tag in one two three; do
    {
      printf "%s-a k=%s\n" "$tag" "$PROBE_CANARY"
      printf "%s-b k=%s\n" "$tag" "$PROBE_CANARY"
      printf "%s-c k=%s\n" "$tag" "$PROBE_CANARY"
    } | scrub
  done
' 2>&1 || true)"

probe_lines="$(printf '%s\n' "$out" | grep -c . || true)"
if [ "$probe_lines" -eq 9 ]; then
  pass "the probe produced 9 lines: the tool's scrub really ran three times"
else
  fail "the scrub probe produced $probe_lines lines, expected 9 — the probe itself is broken: $out"
fi

leaked_batches=""
for tag in one two three; do
  case "$out" in
    *"$tag-a k=$CANARY3"* | *"$tag-b k=$CANARY3"* | *"$tag-c k=$CANARY3"*)
      leaked_batches="$leaked_batches $tag"
      ;;
  esac
done

if [ -z "$leaked_batches" ]; then
  pass "all three consecutive scrub calls filtered the exact value, not only the first"
else
  fail "scrub call(s)$leaked_batches printed the secret verbatim — the value list is being consumed"
fi

kept=0
for tag in one two three; do
  case "$out" in
    *"$tag-a k=[redacted:"* | *"$tag-b k=[redacted:"* | *"$tag-c k=[redacted:"*)
      kept=$((kept + 1))
      ;;
  esac
done
if [ "$kept" -eq 3 ]; then
  pass "each of the three calls replaced the value in place and kept the line readable"
else
  fail "only $kept of 3 scrub calls left a readable redacted line"
fi

out="$(printf 'upstream said: %s\n' "$B64_CANARY" | "$PY" "$REDACTOR" --secrets-fd 3 3< /dev/null)"
case "$out" in
  *"$B64_CANARY"*) fail "the shape layer stopped working when the value list was empty" ;;
  *redacted*) pass "the shape layer works with no value list at all" ;;
  *) fail "shape-only redaction produced neither the key nor a marker: $out" ;;
esac

printf -- '-- 2. the tool refuses the inputs that would leak\n'

if bash "$DEPLOY" --help >/dev/null 2>&1; then
  pass "deploy --help exits 0"
else
  fail "deploy --help did not exit 0"
fi

out="$(bash "$DEPLOY" up --service courier --file "$COMPOSE_REF" --secrets-file /tmp/creds 2>&1 || true)"
case "$out" in
  *"unknown argument"*) pass "there is no --secrets-file: a credential file on disk is not a supported input" ;;
  *) fail "deploy accepted an option that would read credentials from disk. Output: $out" ;;
esac

out="$(bash "$DEPLOY" up --service courier --file "$COMPOSE_REF" 2>&1 || true)"
case "$out" in
  *"no secret source"*) pass "a deploy with no secret source is refused rather than run with none" ;;
  *) fail "a deploy with no secret source was not refused. Output: $out" ;;
esac

out="$(SERVICE_NAME=courier KIT_DEPLOY_IMAGE=example/courier:0 \
  bash "$DEPLOY" up --service courier --file "$COMPOSE_REF" \
  --secrets-fd 3 --ledger-dir "$LEDGER_DIR" 3< <(
    printf 'DATABASE_URL=ecto://u:%s@db/courier\n' "$SECRET_ONE"
    printf 'SECRET_KEY_BASE=%s\n' "$SECRET_ONE"
    printf 'COURIER_SECRET_BOX_KEY=%s\n' "$SECRET_ONE"
    printf 'UNCLAIMED_THING=%s\n' "$SECRET_ONE"
  ) 2>&1 || true)"
case "$out" in
  *"is not claimed by any service"*) pass "a secret no service claims is refused before anything is created" ;;
  *) fail "an unclaimed secret was not refused. Output: $out" ;;
esac

out="$(SERVICE_NAME=courier KIT_DEPLOY_IMAGE=example/courier:0 \
  bash "$DEPLOY" up --service courier --file "$COMPOSE_REF" \
  --secrets-fd 3 --ledger-dir "$LEDGER_DIR" 3< <(printf 'this-line-has-no-equals\n') 2>&1 || true)"
case "$out" in
  *"no '='"*) pass "a secret line with no '=' is refused rather than guessed at" ;;
  *) fail "a malformed secret line was not refused. Output: $out" ;;
esac

out="$(SERVICE_NAME=courier KIT_DEPLOY_IMAGE=example/courier:0 \
  bash "$DEPLOY" up --service courier --file "$COMPOSE_REF" \
  --secrets-fd 3 --ledger-dir "$LEDGER_DIR" 3< <(printf 'DATABASE_URL=abc\n') 2>&1 || true)"
case "$out" in
  *"shorter than"*) pass "a secret too short to be a credential is refused" ;;
  *) fail "a too-short secret was not refused. Output: $out" ;;
esac

IMAGE_A="${KIT_DEPLOY_TEST_IMAGE:-}"

if ! docker info >/dev/null 2>&1; then
  skip "live proofs (the docker daemon is not reachable)"
  note "every live proof is 3-8 below: deploy, red, restore, rollback, leak audit, restart"
elif [ -z "$IMAGE_A" ]; then
  skip "live proofs (no image; set KIT_DEPLOY_TEST_IMAGE)"
  note "build one with:"
  note "  docker build -t anywaye-kit16/courier:35c6a27 /path/to/courier"
  note "then re-run with KIT_DEPLOY_TEST_IMAGE=anywaye-kit16/courier:35c6a27"
else
  printf -- '-- 3. a real deploy reaches green\n'

  PORT="${KIT_DEPLOY_TEST_PORT:-16877}"
  if ! "$PY" -c "
import socket
import sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(('127.0.0.1', $PORT))
except OSError as exc:
    print(exc)
    sys.exit(1)
finally:
    s.close()
" >"$WORK/port.txt" 2>&1; then
    fail "port $PORT is already in use — refusing to run, because this script would otherwise assert against a stack it did not create ($(cat "$WORK/port.txt"))"
    note "re-run with KIT_DEPLOY_TEST_PORT set to a free port"
    docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E "[:.]${PORT}->" | sed 's/^/        /' || true
  fi
  IMAGE_B="${IMAGE_A}-rollback-target"
  IMAGE_BAD="${IMAGE_A}-bad-release"
  if docker image tag "$IMAGE_A" "$IMAGE_B" >/dev/null 2>&1; then
    pass "a second artifact tag exists to roll back to"
  else
    fail "could not tag $IMAGE_B; section 6 would be testing nothing"
  fi

  DB_PASSWORD="kit16DB-${SECRET_ONE}"
  APP_DB_URL="ecto://courier:${DB_PASSWORD}@db/courier"
  KEY_BASE="kit16Key-${SECRET_ONE}"
  BOX_KEY="$(openssl rand -base64 32 2>/dev/null | tr -d '\n')"

  secrets_stream() {
    printf 'DATABASE_URL=%s\n' "$APP_DB_URL"
    printf 'SECRET_KEY_BASE=%s\n' "$KEY_BASE"
    printf 'COURIER_SECRET_BOX_KEY=%s\n' "$BOX_KEY"
    printf 'POSTGRES_PASSWORD=%s\n' "$DB_PASSWORD"
  }

  deploy_up() {
    local image="$1" rc=0
    : >"$DEPLOY_LOG"
    SERVICE_NAME=courier \
      KIT_DEPLOY_IMAGE="$image" \
      KIT_DEPLOY_PORT="$PORT" \
      KIT_DEPLOY_HOST=localhost \
      KIT_READY_TIMEOUT=180 \
      bash "$DEPLOY" up --service courier --file "$COMPOSE_REF" \
      --secrets-fd 3 --ledger-dir "$LEDGER_DIR" --project "$PROJECT" \
      --image "$image" 3< <(secrets_stream) >"$DEPLOY_LOG" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '      --- deploy %s failed (rc=%s) ---\n' "$image" "$rc" >&2
      sed 's/^/      /' "$DEPLOY_LOG" | tail -25 >&2
    else
      cid="$(app_cid)"
    fi
    return "$rc"
  }

  if deploy_up "$IMAGE_A" >/dev/null; then
    pass "deploy up reached green on $IMAGE_A"
  else
    fail "deploy up did not reach green"
  fi

  cid="$(app_cid)"
  if [ -n "$cid" ]; then
    if [ "$(http_code "http://127.0.0.1:$PORT/readyz")" = "200" ]; then
      pass "/readyz answers 200 with the database up"
    else
      fail "/readyz did not answer 200 with the database up"
    fi
    if wait_until "app healthy" 90 sh -c "[ \"\$(docker inspect -f '{{.State.Health.Status}}' '$cid' 2>/dev/null)\" = healthy ]"; then
      pass "the container healthcheck reports healthy"
    else
      fail "the container healthcheck never reported healthy"
    fi
  else
    fail "no app container was created"
  fi

  printf -- '-- 4. the health gate can go RED\n'

  DB_CID="$(db_cid)"
  if [ -n "$DB_CID" ] && docker pause "$DB_CID" >/dev/null 2>&1; then
    pass "the database was paused: it is now not answering queries"
  else
    fail "could not pause the database, so nothing below is a real red proof"
  fi

  if wait_until "readyz goes 503" 90 sh -c \
    "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 'http://127.0.0.1:$PORT/readyz' 2>/dev/null || echo 000)\" = 503 ]"; then
    pass "/readyz reports 503 with its database stopped — it really checks"
  else
    fail "/readyz stayed green with its database stopped — it checks nothing"
  fi

  if [ -n "$cid" ] && wait_until "container goes unhealthy" 90 sh -c \
    "[ \"\$(docker inspect -f '{{.State.Health.Status}}' '$cid' 2>/dev/null)\" = unhealthy ]"; then
    pass "the container healthcheck reports unhealthy with its database stopped"
  else
    fail "the container healthcheck stayed healthy with its database stopped"
  fi

  if bash "$DEPLOY" verify --service courier --file "$COMPOSE_REF" \
    --project "$PROJECT" --ledger-dir "$LEDGER_DIR" >"$WORK/verify-red.log" 2>&1; then
    fail "deploy verify exited 0 while the readiness endpoint was 503"
  else
    pass "deploy verify exits non-zero while the readiness endpoint is 503"
  fi

  if [ "$(http_code "http://127.0.0.1:$PORT/healthz")" = "200" ]; then
    pass "/healthz stays 200 with the database down — liveness consults nothing"
  else
    fail "/healthz went down with the database — a liveness probe must not check a dependency"
  fi

  printf -- '-- 5. and it comes back green\n'

  if [ -n "$DB_CID" ] && docker unpause "$DB_CID" >/dev/null 2>&1; then
    pass "the database was unpaused and is answering again"
  else
    fail "could not unpause the database"
  fi
  if wait_until "readyz returns to 200" 120 sh -c \
    "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 'http://127.0.0.1:$PORT/readyz' 2>/dev/null || echo 000)\" = 200 ]"; then
    pass "/readyz returns to 200 after the database comes back"
  else
    fail "/readyz did not return to 200 after the database came back"
  fi

  DB_CID="$(db_cid)"
  if wait_until "the database container reports healthy again" 120 sh -c \
    "[ \"\$(docker inspect -f '{{.State.Health.Status}}' '$DB_CID' 2>/dev/null)\" = healthy ]"; then
    pass "the database container's own healthcheck is green again"
  else
    fail "the database container's healthcheck never recovered"
  fi

  if wait_until "the app container reports healthy again" 120 sh -c \
    "[ \"\$(docker inspect -f '{{.State.Health.Status}}' '$cid' 2>/dev/null)\" = healthy ]"; then
    pass "the app container's own healthcheck is green again"
  else
    fail "the app container's healthcheck never recovered"
  fi

  printf -- '-- 6. rollback actually changes what is serving\n'

  ref_before="$(image_ref_of "$cid")"
  digest_before="$(image_of "$cid")"
  if deploy_up "$IMAGE_B" >/dev/null; then
    pass "a second artifact deployed and reached green"
  else
    fail "the second artifact did not reach green"
  fi
  ref_mid="$(image_ref_of "$cid")"

  if [ "$ref_mid" = "$IMAGE_B" ]; then
    pass "the container is now running the second artifact's reference ($ref_mid)"
  else
    fail "after the second deploy the container runs '$ref_mid', not '$IMAGE_B'"
  fi

  if SERVICE_NAME=courier KIT_DEPLOY_PORT="$PORT" KIT_READY_TIMEOUT=180 \
    bash "$DEPLOY" rollback --service courier --file "$COMPOSE_REF" \
    --secrets-fd 3 --ledger-dir "$LEDGER_DIR" --project "$PROJECT" \
    3< <(secrets_stream) >"$WORK/rollback.log" 2>&1; then
    cat "$WORK/rollback.log" >>"$DEPLOY_LOG"
    pass "deploy rollback reported success"
  else
    cat "$WORK/rollback.log" >>"$DEPLOY_LOG"
    fail "deploy rollback did not report success"
    sed 's/^/      /' "$WORK/rollback.log" | tail -20
  fi
  cid="$(app_cid)"
  ref_after="$(image_ref_of "$cid")"
  digest_after="$(image_of "$cid")"

  if [ "$ref_after" = "$IMAGE_A" ] && [ "$ref_before" = "$IMAGE_A" ]; then
    pass "after rollback the container runs the first artifact's reference again ($ref_after)"
  else
    fail "after rollback the container runs '$ref_after'; expected '$IMAGE_A' (was '$ref_before', then '$ref_mid')"
  fi

  if [ "$digest_after" = "$digest_before" ]; then
    pass "the rolled-back artifact is the same image, re-used rather than rebuilt ($digest_after)"
  else
    fail "the digest changed across the rollback ($digest_before -> $digest_after)"
  fi

  if [ "$(http_code "http://127.0.0.1:$PORT/readyz")" = "200" ]; then
    pass "the rolled-back artifact is serving and ready"
  else
    fail "the rolled-back artifact is not serving"
  fi

  printf 'FROM %s\nUSER root\nRUN rm -f /app/bin/migrate\n' "$IMAGE_A" >"$WORK/bad.Dockerfile"
  if docker build -q --tag "$IMAGE_BAD" -f "$WORK/bad.Dockerfile" "$WORK" >/dev/null 2>&1; then
    pass "a deliberately broken artifact was built: $IMAGE_BAD (no /app/bin/migrate)"
  else
    fail "could not build the broken artifact; the self-rollback below would prove nothing"
  fi

  : >"$WORK/bad-deploy.log"
  bad_rc=0
  SERVICE_NAME=courier \
    KIT_DEPLOY_IMAGE="$IMAGE_BAD" \
    KIT_DEPLOY_PORT="$PORT" \
    KIT_DEPLOY_HOST=localhost \
    KIT_READY_TIMEOUT=180 \
    bash "$DEPLOY" up --service courier --file "$COMPOSE_REF" \
    --secrets-fd 3 --ledger-dir "$LEDGER_DIR" --project "$PROJECT" \
    --image "$IMAGE_BAD" 3< <(secrets_stream) >"$WORK/bad-deploy.log" 2>&1 || bad_rc=$?
  cat "$WORK/bad-deploy.log" >>"$DEPLOY_LOG"

  if [ "$bad_rc" -ne 0 ]; then
    pass "deploy up reported failure for the broken artifact (rc=$bad_rc)"
  else
    fail "deploy up reported SUCCESS for an artifact whose migration does not exist"
    sed 's/^/      /' "$WORK/bad-deploy.log" | tail -25
  fi

  if grep -q 'rolling back to the previous artifact' "$WORK/bad-deploy.log"; then
    pass "the failed deploy said it was rolling back"
  else
    fail "the failed deploy did not report attempting a rollback"
  fi

  if grep -q 'ROLLBACK ALSO FAILED' "$WORK/bad-deploy.log"; then
    fail "the self-rollback also failed — the broken artifact was left in place"
  else
    pass "the self-rollback did not report failure"
  fi

  cid="$(app_cid)"
  ref_back="$(image_ref_of "$cid")"
  if [ "$ref_back" = "$IMAGE_A" ]; then
    pass "the stack is serving the previous artifact again, unprompted ($ref_back)"
  else
    fail "after a failed deploy the stack runs '$ref_back', not '$IMAGE_A'"
  fi

  if [ "$(http_code "http://127.0.0.1:$PORT/readyz")" = "200" ]; then
    pass "the auto-rolled-back stack is serving and ready"
  else
    fail "the auto-rolled-back stack is not serving"
  fi

  if grep -F "$IMAGE_BAD" "$LEDGER_DIR/courier.ledger" 2>/dev/null | grep -q 'ok'; then
    fail "the ledger recorded the broken artifact as a successful deploy"
  else
    pass "the ledger recorded no successful deploy of the broken artifact"
  fi

  docker image rm "$IMAGE_BAD" >/dev/null 2>&1 || true

  printf -- '-- 7. no secret value reached any artefact a human can read\n'

  rendered="$WORK/compose-config.txt"
  dc config >"$rendered" 2>/dev/null || true
  inspected="$WORK/inspect.txt"
  docker inspect "$cid" >"$inspected" 2>/dev/null || true

  for artefact in "$DEPLOY_LOG" "$rendered" "$inspected"; do
    label="$(basename "$artefact")"
    leaked=0
    for canary in "$DB_PASSWORD" "$KEY_BASE" "$BOX_KEY" "$APP_DB_URL"; do
      if grep -qF "$canary" "$artefact" 2>/dev/null; then
        leaked=1
      fi
    done
    if [ "$leaked" -eq 0 ]; then
      pass "$label contains no secret value"
    else
      fail "$label contains a secret value"
    fi
  done

  if docker exec -u 0 "$cid" sh -c 'test -s /run/secrets/DATABASE_URL' 2>/dev/null; then
    pass "the secret really was delivered (the negatives above are real negatives)"
  else
    fail "no secret reached the container — the leak audit proved nothing"
  fi

  if docker exec -u 0 "$cid" sh -c 'mount | grep -q "tmpfs on /run/secrets"' 2>/dev/null; then
    pass "/run/secrets is a tmpfs — RAM, not a block device"
  else
    fail "/run/secrets is not a tmpfs; the credential is somewhere durable"
  fi

  dbid="$(db_cid)"
  inspected_db="$WORK/inspect-db.txt"
  docker inspect "$dbid" >"$inspected_db" 2>/dev/null || true
  if [ -n "$dbid" ] && ! grep -qF "$DB_PASSWORD" "$inspected_db" 2>/dev/null; then
    pass "the database's own docker inspect contains no database password"
  else
    fail "the database password is present in docker inspect for the database"
  fi
  if [ -n "$dbid" ] && docker exec -u 0 "$dbid" sh -c 'test -s /run/secrets/POSTGRES_PASSWORD' 2>/dev/null; then
    pass "the database password really was delivered to the database (so the negative above is real)"
  else
    fail "no database password reached the database — the audit above proved nothing"
  fi
  if [ -n "$dbid" ] && ! docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$dbid" 2>/dev/null |
    grep -q '^POSTGRES_PASSWORD='; then
    pass "no POSTGRES_PASSWORD in the database's environment block"
  else
    fail "POSTGRES_PASSWORD is in the database's environment — docker inspect would print it"
  fi

  printf -- '-- 8. the restart policy is real, and a restart empties the secret store\n'

  if [ -n "$cid" ]; then
    policy="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid" 2>/dev/null || echo unknown)"
    if [ "$policy" = "unless-stopped" ]; then
      pass "the app container's restart policy is unless-stopped"
    else
      fail "the app container's restart policy is '$policy', not unless-stopped"
    fi

    before_restarts="$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null || echo 0)"
    if docker exec -u 0 "$cid" sh -c 'kill 1' >/dev/null 2>&1; then
      pass "the application's own process was terminated from inside the container"
    else
      skip "could not terminate the application process from inside"
    fi

    if wait_until "docker restarts the exited container" 120 sh -c \
      "[ \"\$(docker inspect -f '{{.RestartCount}}' '$cid' 2>/dev/null || echo 0)\" -gt $before_restarts ]"; then
      pass "docker restarted the container after it exited on its own (restarts $before_restarts -> $(docker inspect -f '{{.RestartCount}}' "$cid"))"
    else
      fail "the exited container was not restarted — the restart policy is not doing anything"
    fi

    if wait_until "the restarted container is running again" 120 sh -c \
      "docker inspect -f '{{.State.Status}}' '$cid' 2>/dev/null | grep -q running"; then
      pass "the restarted container is running"
    else
      fail "the restarted container is not running"
    fi

    if wait_until "the restarted container serves without credentials" 8 \
      sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 'http://127.0.0.1:$PORT/readyz' 2>/dev/null || echo 000)\" = 200 ]"; then
      fail "the restarted container served WITHOUT credentials — the secret gate is not a gate"
    else
      pass "the restarted container is blocked at the credential gate, not serving"
    fi

    if deploy_up "$IMAGE_B" >/dev/null; then
      pass "re-running the deploy delivers the credentials again and the service recovers"
    else
      fail "re-running the deploy did not recover the service"
    fi
    if [ "$(http_code "http://127.0.0.1:$PORT/readyz")" = "200" ]; then
      pass "the recovered service is ready again"
    else
      fail "the recovered service is not ready"
    fi
  fi

  printf -- '-- 9. down takes this project and nothing else\n'

  DECOY_C="kit16-not-ours-c-$$"
  DECOY_V="kit16-not-ours-v-$$"
  docker rm -f "$DECOY_C" >/dev/null 2>&1 || true
  docker volume rm "$DECOY_V" >/dev/null 2>&1 || true
  if docker run -d --name "$DECOY_C" -v "$DECOY_V:/data" alpine:3.20 sleep 300 >/dev/null 2>&1 &&
    docker volume inspect "$DECOY_V" >/dev/null 2>&1; then
    pass "a decoy container and volume outside the project exist to be spared"
  else
    fail "could not create the decoy; everything below would be vacuous"
  fi

  if SERVICE_NAME=courier KIT_DEPLOY_PORT="$PORT" \
    bash "$DEPLOY" status --service courier --file "$COMPOSE_REF" \
    --project "$PROJECT" --ledger-dir "$LEDGER_DIR" >"$WORK/status.log" 2>&1; then
    if grep -q 'ledger (courier)' "$WORK/status.log"; then
      pass "deploy status renders and prints the ledger"
    else
      fail "deploy status exited 0 but printed no ledger"
      sed 's/^/      /' "$WORK/status.log" | tail -15
    fi
  else
    fail "deploy status did not exit 0"
    sed 's/^/      /' "$WORK/status.log" | tail -15
  fi

  OWN_VOLUME="$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E "^${PROJECT}_" | head -1)"
  if [ -n "$OWN_VOLUME" ]; then
    pass "the project's own volume is $OWN_VOLUME"
  else
    fail "no volume found for project $PROJECT; the purge assertions below would prove nothing"
  fi

  if SERVICE_NAME=courier KIT_DEPLOY_PORT="$PORT" \
    bash "$DEPLOY" down --service courier --file "$COMPOSE_REF" \
    --project "$PROJECT" --ledger-dir "$LEDGER_DIR" >"$WORK/down.log" 2>&1; then
    pass "deploy down exited 0"
  else
    fail "deploy down did not exit 0"
    sed 's/^/      /' "$WORK/down.log" | tail -15
  fi

  if [ -z "$(app_cid)" ] && [ -z "$(db_cid)" ]; then
    pass "deploy down removed the project's containers"
  else
    fail "containers are still there after deploy down"
  fi

  if [ -n "$OWN_VOLUME" ] && docker volume inspect "$OWN_VOLUME" >/dev/null 2>&1; then
    pass "a plain deploy down KEPT the volume, as it says it does"
  else
    fail "the project's volume is gone after a plain down; --purge is a lie"
  fi

  if [ ! -r "$LEDGER_DIR/courier.ledger" ]; then
    pass "deploy down removed the ledger, so the next deploy knows it is the first one"
  else
    fail "the ledger survived deploy down; a later rollback would target a stack that is gone"
  fi

  if SERVICE_NAME=courier KIT_DEPLOY_PORT="$PORT" \
    bash "$DEPLOY" down --purge --service courier --file "$COMPOSE_REF" \
    --project "$PROJECT" --ledger-dir "$LEDGER_DIR" >"$WORK/purge.log" 2>&1; then
    pass "deploy down --purge exited 0"
  else
    fail "deploy down --purge did not exit 0"
    sed 's/^/      /' "$WORK/purge.log" | tail -15
  fi

  if [ -n "$OWN_VOLUME" ] && ! docker volume inspect "$OWN_VOLUME" >/dev/null 2>&1; then
    pass "deploy down --purge removed the project's volume"
  else
    fail "the project's volume survived --purge"
  fi

  if docker inspect "$DECOY_C" >/dev/null 2>&1; then
    pass "a container outside the project survived down AND --purge"
  else
    fail "deploy down removed a container that is not in the project — it is not scoped"
  fi
  if docker volume inspect "$DECOY_V" >/dev/null 2>&1; then
    pass "a volume outside the project survived down --purge"
  else
    fail "deploy down --purge removed a volume that is not in the project — it is not scoped"
  fi

  leftover="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${PROJECT}_" || true)"
  if [ -z "$leftover" ]; then
    pass "no container named for the project remains"
  else
    fail "containers remain after --purge: $leftover"
  fi

  docker rm -f "$DECOY_C" >/dev/null 2>&1 || true
  docker volume rm "$DECOY_V" >/dev/null 2>&1 || true

  docker image rm "$IMAGE_B" >/dev/null 2>&1 || true
fi

printf '\n'
note "passed: $passes  failed: $failures  skipped: $skips"
if [ "$failures" -ne 0 ]; then
  echo "FAIL: deploy — $failures claim(s) not proved."
  exit 1
fi
if [ "$skips" -ne 0 ]; then
  echo "PASS (with $skips skipped): deploy, with every live proof accounted for."
  exit 0
fi
echo "PASS: deploy, and every health gate was demonstrated red and green."
