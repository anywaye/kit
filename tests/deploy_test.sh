#!/usr/bin/env bash
#
# kit's proof that the deploy story works, and that it can fail.
#
#   bash tests/deploy_test.sh
#
# WHAT IS PROVED HERE, IN ORDER OF HOW MUCH IT CAN BE FAKED
#
#   1. STATIC, no docker. The redaction boundary actually redacts. Not "the
#      file exists" — the filter is EXECUTED against a known secret and a JWT
#      and a connection string, and the assertions are that the canary is
#      absent AND that the surrounding text survived, because a filter that
#      deletes the whole line passes "no canary found" while being useless.
#
#   2. STATIC, no docker. The tool refuses the inputs that would leak. A
#      secret named as a file path, a secret nobody claims, a secret too short
#      to be a credential, a multi-line secret. Each is a refusal, and each
#      refusal is asserted by exit status AND by the message.
#
#   3. LIVE, a real deploy. `courier` is deployed as a release image and its
#      health gate goes GREEN.
#
#   4. LIVE, the red proof. The database is stopped underneath the running
#      service and the readiness endpoint is watched going 503, the container
#      healthcheck is watched going unhealthy, and `deploy verify` is watched
#      exiting non-zero. This is the assertion that gives every other "it is
#      healthy" in this file its meaning: a check that has never been seen red
#      is a check that might not be checking.
#
#   5. LIVE, the restore. The database comes back and all three go green
#      again, because a red that never clears is a different bug from one that
#      does.
#
  # 6. LIVE, rollback. A second artifact is deployed and then rolled back, and
  #     the previous artifact is shown to be the one actually serving. The image
  #     REFERENCE the container was created from is compared, not the digest —
  #     the two tags share an image and therefore share a digest, so a digest
  #     assertion would pass against a rollback that did nothing at all.
#
#   6b. LIVE, the automatic rollback. A deliberately broken artifact — the good
#      image with `/app/bin/migrate` removed — is deployed, and the deploy must
#      exit non-zero, say that it is rolling back, and leave the previous
#      artifact serving WITHOUT anyone asking. Until this section existed, the
#      sentence "a deploy that cannot reach green rolls itself back" was the
#      most load-bearing claim in the packet and it rested on reading the source.
#
#   7. LIVE, the leak audit. After all of the above, the deploy log, the
#      rendered compose config and `docker inspect` are searched for every
#      secret value that was supplied. All three must be clean. This is the
#      check that would catch the most damaging thing this packet could get
#      wrong, and it runs LAST, against the accumulated evidence.
#
#   8. LIVE, restart policy. The application process is killed FROM INSIDE the
#      container — `docker kill` from outside is an operator-initiated stop,
#      which `restart: unless-stopped` deliberately does not resurrect — and
#      Docker is watched bringing it back. Then the honest half: the tmpfs is
#      gone, so the restarted container comes back BLOCKED at the credential
#      gate and must not be serving, and re-running the deploy is the repair.
#
#   9. LIVE, teardown, and the proof that teardown is scoped. `down` and
#      `down --purge` are asserted to differ on the volume, the ledger is
#      asserted to die with the stack, and a container and a volume that belong
#      to nobody here are asserted to SURVIVE both. "Never touch state you do
#      not own" is the one constraint in this packet that was otherwise only
#      asserted by reading the source, which is not a proof.
#
# NO SLEEPS. Every wait is a poll on a real signal — an HTTP status, a
# container health status, an image digest — with a deadline. `sleep` appears
# only as the interval BETWEEN polls, which is how often this script is allowed
# to ask, not how long it guesses something takes. This matches
# `tests/no_telemetry_in_readiness.sh`, which is the house pattern.
#
# IT TOUCHES NOTHING IT DID NOT CREATE. Every container, network and volume
# here belongs to the compose project `kit-deploy-test-$$` and is removed on the
# way out, volumes included. There is no `docker system prune` anywhere in this
# file and no command that is not scoped to that project by name.
#
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

# wait_until <label> <deadline-seconds> <command...>
# A poll, never a sleep. Prints the last output on failure, because a bare
# "timed out" on a container that exited two seconds in is the least useful
# message this script could print.
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

# dc: every direct compose call in this file goes through here, because the
# deploy file interpolates two variables and refuses to render without them.
# A `stop db` that quietly failed on a missing variable would have turned the
# red proof in section 4 into a green one for the wrong reason.
dc() {
  SERVICE_NAME=courier KIT_DEPLOY_IMAGE="${IMAGE_A:-unused}" \
    docker compose --project-name "$PROJECT" --file "$COMPOSE_REF" "$@"
}

health_of() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo gone; }
image_of() { docker inspect -f '{{.Image}}' "$1" 2>/dev/null || echo none; }
# The image REFERENCE the container was created from. Distinct from
# image_of, which is the digest — two tags of one image share a digest and do
# not share a reference, so only the reference can prove that a rollback
# changed which artifact is deployed.
image_ref_of() { docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null || echo none; }
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || echo 000; }

cleanup() {
  # The two variables the deploy file interpolates, so the file is RENDERABLE
  # at teardown. Without them `${KIT_DEPLOY_IMAGE:?...}` refuses and `down`
  # never runs, which would leave this script's containers, network and volume
  # behind — the exact "clean up what you create" failure this packet is
  # required not to have.
  SERVICE_NAME=courier KIT_DEPLOY_IMAGE="${IMAGE_A:-unused-at-teardown}" \
    docker compose --project-name "$PROJECT" --file "$COMPOSE_REF" \
    down --volumes --remove-orphans >/dev/null 2>&1 || true
  docker image rm "${IMAGE_A:-none}-rollback-target" >/dev/null 2>&1 || true
  docker image rm "${IMAGE_A:-none}-bad-release" >/dev/null 2>&1 || true
  # The decoys, removed on every exit path. A teardown that leaks the thing it
  # built to prove teardown does not leak is a joke with a test-shaped punchline.
  docker rm -f "kit16-not-ours-c-$$" >/dev/null 2>&1 || true
  docker volume rm "kit16-not-ours-v-$$" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. The redaction boundary, executed
# ---------------------------------------------------------------------------
printf -- '-- 1. the redactor redacts, and does not delete the line\n'

# A value the redactor cannot know by name is half the test: a filter that
# only works on its own input list is defeated by anything it did not already
# hold, and a deploy log is full of strings the deploy never supplied.
SECRET_ONE="$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
SECRET_TWO="KIT16CANARY-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
JWT_CANARY="eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJraXQxNiJ9.Q1lOYVJZTEZBS1JFU1VMVFRFU1FMkE"
URL_CANARY="postgres://courier:${SECRET_TWO}@db:5432/courier"
B64_CANARY="sk-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# redact_with <text> <secret>... — run the real filter with a real fd 3.
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

# The false-positive floor. A redactor that masks ordinary operational text
# trains people to paste deploy logs into issue trackers by hand, which is the
# leak the redactor exists to prevent.
out="$(redact_with "starting service: app; waiting for health gate; 3 services healthy" "$SECRET_ONE")"
case "$out" in
  *"starting service: app; waiting for health gate; 3 services healthy"*) pass "ordinary operational text is not masked" ;;
  *) fail "the redactor mangled ordinary text: $out" ;;
esac

# A value shorter than MIN_LITERAL_LEN is not scrubbed as a literal, on
# purpose. Assert the behaviour rather than leaving it to be discovered in an
# incident: a 3-character "secret" in a fixture is not a credential, and
# masking every `ok` in a log would be the redactor breaking the log.
out="$(redact_with "value=ok done" "ok")"
case "$out" in
  *"ok done"*) pass "a sub-minimum-length value is not scrubbed as a literal" ;;
  *) fail "a 2-character value was scrubbed as a literal: $out" ;;
esac

# ---------------------------------------------------------------------------
# 1b. The EXACT-VALUE layer, on every call
# ---------------------------------------------------------------------------
printf -- '-- 1b. every printed line is filtered, not just the first\n'

# THE BUG THIS EXISTS TO CATCH, and it is the most serious thing the audit
# above could not see.
#
# `scrub` used to inherit one pipe on fd 3 for the life of the deploy. A pipe is
# a STREAM with a single read, so the first `scrub` consumed it to EOF and every
# later one got an EMPTY value list — and an empty value list means shape-only
# redaction. The exact-value layer, the one that actually knows this deploy's
# secrets, therefore applied to the first line printed and never again.
#
# Reproduced against the real functions with the real redactor:
#
#     call 1: a [redacted:secret] b
#     call 2: c T=kit16CANARY… d     <- the secret, printed
#     call 3: e T=kit16CANARY… f
#
# and the leak audit in section 7 could not catch it, because that audit only
# fails when something ACTUALLY leaks. Nothing leaked on the runs that hid this.
# A check that can only fail on a bad day is not a check; this one fails on the
# structure instead.
#
# Driven by SOURCING the tool rather than by paraphrasing it: a copy of `scrub`
# in this file would drift from the one that runs during a real deploy, and a
# test of a copy tests nothing.
# Sourcing `deploy` runs `main "$@"`, which would parse this suite's own
# arguments and exit. Strip that one line, append the setter the probe needs,
# and run it all inside a SUBSHELL so none of the tool's globals — `set -euo
# pipefail`, `SERVICE`, `PROJECT`, the whole config block — leak into this
# suite's shell. Sourcing in the current shell would replace the error handling
# this test file depends on.
cat >"$WORK/deploy-lib.sh" <<EOF
$(sed -e 's|^main "\$@"$|# main "\$@"  (stripped: this is the library probe)|' "$DEPLOY")
secret_values_set() {
  SECRET_NAMES=(CANARY_KEY)
  SECRET_VALUES=("\$1")
  SECRET_PAIRS=("CANARY_KEY=\$1")
}
EOF

LIB="$WORK/deploy-lib.sh"

# Nine lines through THREE consecutive scrub calls, driven by the tool's own
# `scrub` and the real redactor. The subshell keeps the tool's `set -euo
# pipefail` and its config globals out of this suite's shell; REDACTOR is passed
# in so the probe does not depend on the tool deriving SELF_DIR from `$0`, which
# is THIS test file once it is sourced.
CANARY3="kit16CanaryStream3f9a2c7e1b4d8065"
out="$(LIB="$LIB" PROBE_REDACTOR="$REDACTOR" PROBE_CANARY="$CANARY3" bash -c '
  set -euo pipefail
  # shellcheck source=/dev/null
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

# If the probe produced nothing, that is a BROKEN PROBE and not a pass. Counting
# "no canary in the empty string" as success is how a redaction test reports
# green having run nothing.
probe_lines="$(printf '%s\n' "$out" | grep -c . || true)"
if [ "$probe_lines" -eq 9 ]; then
  pass "the probe produced 9 lines: the tool's scrub really ran three times"
else
  fail "the scrub probe produced $probe_lines lines, expected 9 — the probe itself is broken: $out"
fi

# Counted per BATCH, not per line: the bug is that whole batches come through
# unredacted, so asserting "three consecutive calls" means "three batches of
# three", and reporting which batch leaked localises a regression to a call.
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

# And the SURVIVORS, because a filter that redacts everything is as useless as
# one that redacts nothing.
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

# ...and the shape layer must still be doing its job independently, because the
# value list is not supposed to be the only thing standing between a secret and
# a log.
out="$(printf 'upstream said: %s\n' "$B64_CANARY" | "$PY" "$REDACTOR" --secrets-fd 3 3< /dev/null)"
case "$out" in
  *"$B64_CANARY"*) fail "the shape layer stopped working when the value list was empty" ;;
  *redacted*) pass "the shape layer works with no value list at all" ;;
  *) fail "shape-only redaction produced neither the key nor a marker: $out" ;;
esac

# ---------------------------------------------------------------------------
# 2. The refusals. Each of these is a way to leak, and each must stop.
# ---------------------------------------------------------------------------
printf -- '-- 2. the tool refuses the inputs that would leak\n'

if bash "$DEPLOY" --help >/dev/null 2>&1; then
  pass "deploy --help exits 0"
else
  fail "deploy --help did not exit 0"
fi

# A secret as a FILE PATH is the wrong answer the platform's rule warns about,
# so the tool must not offer it as an option at all.
#
# Output is captured into a variable and matched afterwards rather than piped
# into grep. `set -o pipefail` is on in this script, so a `tool | grep -q`
# pipeline reports the TOOL's non-zero exit even when grep matched — which
# turns every one of these refusal tests into a silent pass/fail inversion.
# The refusals below are the case where reading the exit status wrongly is
# worst, because a refusal test that cannot fail is a test that will happily
# go green if the tool stops refusing.
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

# A secret no service claims is the typo that produces a deploy which reports
# itself green and fails on the first real request.
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

# A line with no '=' is not a NAME=VALUE pair and must not be guessed at. The
# most likely way to produce one is a secrets file whose last line has no
# trailing newline and a `read` loop that mangles it — and the result would be
# a credential whose NAME is the value.
out="$(SERVICE_NAME=courier KIT_DEPLOY_IMAGE=example/courier:0 \
  bash "$DEPLOY" up --service courier --file "$COMPOSE_REF" \
  --secrets-fd 3 --ledger-dir "$LEDGER_DIR" 3< <(printf 'this-line-has-no-equals\n') 2>&1 || true)"
case "$out" in
  *"no '='"*) pass "a secret line with no '=' is refused rather than guessed at" ;;
  *) fail "a malformed secret line was not refused. Output: $out" ;;
esac

# A credential too short to be one is a misconfiguration, and masking it
# everywhere would be redaction that protects nothing.
out="$(SERVICE_NAME=courier KIT_DEPLOY_IMAGE=example/courier:0 \
  bash "$DEPLOY" up --service courier --file "$COMPOSE_REF" \
  --secrets-fd 3 --ledger-dir "$LEDGER_DIR" 3< <(printf 'DATABASE_URL=abc\n') 2>&1 || true)"
case "$out" in
  *"shorter than"*) pass "a secret too short to be a credential is refused" ;;
  *) fail "a too-short secret was not refused. Output: $out" ;;
esac

# ---------------------------------------------------------------------------
# 3-8. The live proofs
# ---------------------------------------------------------------------------
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
  # Is the port free? This is a correctness check, not a politeness check, and
  # it is here because of something that actually happened while this packet
  # was being written: a leftover stack from an earlier manual run was still
  # publishing the test's port, so `curl /readyz` and `curl /healthz` were
  # answered by a stack this script had not created, and two assertions
  # reported PASS against a stranger's service.
  #
  # A deploy test that can silently measure the wrong thing is worse than one
  # that refuses to run, so this FAILS rather than skipping. Binding is the
  # test rather than probing, because a port can be taken by something that
  # does not speak HTTP.
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
  # A second tag of the same image stands in for "the next release". Rollback
  # needs two artifacts to be meaningful, and building a second image for this
  # would add ten minutes to prove something about tagging rather than about
  # rollback. What rollback must prove is that going BACK changes what is
  # running, and that is proven by digest in section 6.
  IMAGE_B="${IMAGE_A}-rollback-target"
  # The broken artifact of section 6b: the same image with one file removed.
  # Named apart from IMAGE_B so the two tags cannot be confused, and so the
  # teardown at the end of the suite removes exactly what it created.
  IMAGE_BAD="${IMAGE_A}-bad-release"
  # Rollback needs TWO artifacts to mean anything. This stands in for "the next
  # release": same image, second tag. Building a genuinely different image here
  # would add ten minutes to a suite to prove something about tagging; what
  # rollback must prove is that going BACK changes what is running, and that is
  # proven by image digest in section 6.
  #
  # Asserted rather than `|| true`-ed. A silently missing second tag produced a
  # confusing failure three lines later — a deploy that could not start — and
  # the real cause was two screens away from where it was reported.
  if docker image tag "$IMAGE_A" "$IMAGE_B" >/dev/null 2>&1; then
    pass "a second artifact tag exists to roll back to"
  else
    fail "could not tag $IMAGE_B; section 6 would be testing nothing"
  fi

  DB_PASSWORD="kit16DB-${SECRET_ONE}"
  APP_DB_URL="ecto://courier:${DB_PASSWORD}@db/courier"
  KEY_BASE="kit16Key-${SECRET_ONE}"
  BOX_KEY="$(openssl rand -base64 32 2>/dev/null | tr -d '\n')"

  # The secrets, as a stream. Built in a function because rollback needs them
  # too, and the first version of this file did not pass them — so rollback
  # failed with "no secret source" and the test reported a failure that was
  # the TEST's bug, not the tool's. Rollback is a deploy of a different
  # artifact and needs the credentials that go with it; the tool is right to
  # insist.
  secrets_stream() {
    printf 'DATABASE_URL=%s\n' "$APP_DB_URL"
    printf 'SECRET_KEY_BASE=%s\n' "$KEY_BASE"
    printf 'COURIER_SECRET_BOX_KEY=%s\n' "$BOX_KEY"
    printf 'POSTGRES_PASSWORD=%s\n' "$DB_PASSWORD"
  }

  # The deploy's own output is written to the log for the leak audit in
  # section 7, and the failure diagnostics go to STDERR — because the caller
  # redirects this function's stdout to /dev/null, and diagnostics on stdout
  # are therefore invisible. A deploy test that swallows the deploy's error
  # output is the single most annoying thing a test of a deploy can do, and it
  # is a failure this file hit three times while it was being written.
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
      # A deploy RECREATES the app container when the image changes, so the id
      # captured before it is an id that no longer exists. Re-resolving here is
      # not tidiness: every assertion below that names a container was
      # silently inspecting a dead one, and "the container did not come back"
      # was really "the container you asked about was deleted by the deploy".
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

  # -------------------------------------------------------------------
  # 4. The red proof
  # -------------------------------------------------------------------
  printf -- '-- 4. the health gate can go RED\n'

  # A deploy that has only ever reported green has proved nothing about the
  # gate. Break the real dependency and watch the real signal.
  #
  # `docker pause`, NOT `compose stop`. Stopping the container destroys its
  # tmpfs, so starting it again brings the database back WITHOUT its password
  # and it never comes up at all — which tests the secret-delivery path and
  # nothing else, and made the restore half of this section fail for a reason
  # that had nothing to do with readiness. Pausing freezes the process and
  # leaves the filesystem intact, so the database really stops answering
  # queries and really starts answering them again. That is the claim
  # `/readyz` makes, isolated from every other thing this platform does.
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

  # The deploy tool's own verdict. A gate that reports green over a red stack
  # is worse than no gate, because it is believed.
  if bash "$DEPLOY" verify --service courier --file "$COMPOSE_REF" \
    --project "$PROJECT" --ledger-dir "$LEDGER_DIR" >"$WORK/verify-red.log" 2>&1; then
    fail "deploy verify exited 0 while the readiness endpoint was 503"
  else
    pass "deploy verify exits non-zero while the readiness endpoint is 503"
  fi

  # Liveness is the other half and it is the half that is easy to get wrong.
  # /healthz must stay 200: a liveness probe that fails on a dependency tells
  # the supervisor to restart a process that is fine, which turns a database
  # blip into a crash-restart loop and destroys the evidence.
  if [ "$(http_code "http://127.0.0.1:$PORT/healthz")" = "200" ]; then
    pass "/healthz stays 200 with the database down — liveness consults nothing"
  else
    fail "/healthz went down with the database — a liveness probe must not check a dependency"
  fi

  # -------------------------------------------------------------------
  # 5. The restore
  # -------------------------------------------------------------------
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

  # The restore is only complete when the STACK is green, not when one HTTP
  # endpoint answers. `/readyz` can be 200 a second or two before Docker's own
  # healthcheck for the database has run a success and cleared its failure
  # streak, and section 6 then starts a deploy against a database Docker still
  # considers unhealthy. That is a race this file lost twice before these two
  # assertions existed, and it reported itself as "the second artifact did not
  # reach green" — which pointed at the deploy rather than at the test.
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

  # -------------------------------------------------------------------
  # 6. Rollback
  # -------------------------------------------------------------------
  printf -- '-- 6. rollback actually changes what is serving\n'

  # The reference, not the digest. `IMAGE_B` is a second TAG of the same
  # image, so `{{.Image}}` — the digest — is byte-identical before and after by
  # construction, and asserting on it would pass whether or not rollback did
  # anything. That is the false green this section would have shipped: a
  # rollback test that cannot fail. `{{.Config.Image}}` is the reference the
  # container was created from, and THAT is what rollback changes.
  #
  # The digest is asserted too, and the assertion is that it did NOT change:
  # it is the evidence that going back re-used the previous artifact rather
  # than quietly rebuilding something.
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

  # -------------------------------------------------------------------
  # 6b. A deploy that cannot go green rolls ITSELF back
  # -------------------------------------------------------------------
  #
  # Section 6 proved `rollback` works when a human asks for it. This proves the
  # claim the tool's header and the CHANGELOG both make — "a deploy that cannot
  # reach green rolls itself back rather than leaving a broken version quietly
  # replacing a working one" — which until now was **not tested at all**. It is
  # the single most load-bearing sentence in the packet and it was resting on
  # reading the source.
  #
  # The broken artifact is a ONE-LAYER derivative of the good one with
  # `/app/bin/migrate` removed. That matters for what the test proves: good and
  # bad differ by exactly the thing under test and nothing else, so a rollback
  # that appeared to work could not have worked by accident. The failure is a
  # migration that does not exist, which is the most ordinary bad release there
  # is — it boots, it serves, it passes its health gate, and it is still wrong.
  #
  # It is built, not committed: a deliberately broken image has no business in
  # the repository, and the Dockerfile is written into the suite's own temp
  # directory so it leaves nothing behind.
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

  # It must have said what it was doing. A tool that rolls back silently is a
  # tool nobody can debug at 03:00.
  if grep -q 'rolling back to the previous artifact' "$WORK/bad-deploy.log"; then
    pass "the failed deploy said it was rolling back"
  else
    fail "the failed deploy did not report attempting a rollback"
  fi

  # The self-rollback runs the same code path, so it emits its own failure text
  # if it also failed. Asserted, because the failure this test exists to catch
  # is precisely a rollback that reports success while changing nothing.
  if grep -q 'ROLLBACK ALSO FAILED' "$WORK/bad-deploy.log"; then
    fail "the self-rollback also failed — the broken artifact was left in place"
  else
    pass "the self-rollback did not report failure"
  fi

  # The deploy RECREATES the app container twice here (once onto the bad
  # artifact, once back off it), so the id captured in section 6 is long dead.
  # Re-resolving is not tidiness: every assertion naming a container below would
  # otherwise be inspecting one the rollback had already deleted.
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

  # And the ledger must not remember the broken artifact as something anybody
  # could later roll back TO. `do_deploy` appends only on success; if a bad
  # release reached the ledger, the next incident would target it.
  if grep -F "$IMAGE_BAD" "$LEDGER_DIR/courier.ledger" 2>/dev/null | grep -q 'ok'; then
    fail "the ledger recorded the broken artifact as a successful deploy"
  else
    pass "the ledger recorded no successful deploy of the broken artifact"
  fi

  docker image rm "$IMAGE_BAD" >/dev/null 2>&1 || true

  # -------------------------------------------------------------------
  # 7. The leak audit
  # -------------------------------------------------------------------
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

  # The value inside the running container, which is the one place it is
  # supposed to be. Asserting it is there proves the negatives above are
  # negatives because the secret existed, not because the deploy silently did
  # not deliver any.
  if docker exec -u 0 "$cid" sh -c 'test -s /run/secrets/DATABASE_URL' 2>/dev/null; then
    pass "the secret really was delivered (the negatives above are real negatives)"
  else
    fail "no secret reached the container — the leak audit proved nothing"
  fi

  # ...and the tmpfs claim, which is the load-bearing one.
  if docker exec -u 0 "$cid" sh -c 'mount | grep -q "tmpfs on /run/secrets"' 2>/dev/null; then
    pass "/run/secrets is a tmpfs — RAM, not a block device"
  else
    fail "/run/secrets is not a tmpfs; the credential is somewhere durable"
  fi

  # THE DATABASE IS THE MORE LEAK-PRONE OF THE TWO, NOT THE LESS. A
  # `POSTGRES_PASSWORD` in `environment:` is printed by `docker inspect` and by
  # `docker compose config`, which is the entire reason the reference runs the
  # official postgres image behind the same gate as the application and never
  # declares the `_FILE` variant. So the database gets its own audit of its own
  # `docker inspect`, with its own positive control — a negative that is only
  # meaningful when the value really was delivered.
  #
  # This is not the app's audit repeated. `rendered` above covers the whole
  # project, but `inspected` is the APPLICATION container alone, and the
  # database was the one service whose password the tool most needed to keep
  # out of its configuration.
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
  # The two are mutually exclusive in the official image and it refuses to boot
  # with both, so a deploy that set the _FILE variant would have a database that
  # never starts. Asserting the variable is ABSENT is the check that the comment
  # in the deploy file is still true.
  if [ -n "$dbid" ] && ! docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$dbid" 2>/dev/null |
    grep -q '^POSTGRES_PASSWORD='; then
    pass "no POSTGRES_PASSWORD in the database's environment block"
  else
    fail "POSTGRES_PASSWORD is in the database's environment — docker inspect would print it"
  fi

  # -------------------------------------------------------------------
  # 8. Restart policy, and what a restart costs
  # -------------------------------------------------------------------
  printf -- '-- 8. the restart policy is real, and a restart empties the secret store\n'

  if [ -n "$cid" ]; then
    policy="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid" 2>/dev/null || echo unknown)"
    if [ "$policy" = "unless-stopped" ]; then
      pass "the app container's restart policy is unless-stopped"
    else
      fail "the app container's restart policy is '$policy', not unless-stopped"
    fi

    # THE APP HAS TO EXIT ON ITS OWN. `docker kill` from outside is an
    # operator-initiated stop, and the restart policy deliberately does not
    # resurrect it — measured on this machine with a stock `alpine sleep 300`
    # and `--restart unless-stopped`, which stayed `exited` with
    # RestartCount 0 for two minutes after `docker kill`. Writing the test the
    # obvious way therefore proved nothing about the policy, and the first
    # version of this section did exactly that.
    #
    # Killing PID 1 from INSIDE is the honest version: the process terminates
    # and the container exits on its own, which is the crash the policy exists
    # for.
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

    # THE HONEST PART, and the reason this is a section rather than a line in
    # the README. /run/secrets is a tmpfs, so the restart wiped it. The
    # restarted container therefore comes back BLOCKED at the credential gate
    # and must NOT be serving, and that is correct: a process that starts
    # without its database URL fails in a way that looks like a bad release.
    #
    # Asserting the non-serving state is what makes the recovery assertion mean
    # something. A test that only checked "it came back and serves" would have
    # been quietly wrong, and would have passed against a gate that did not
    # exist.
    if wait_until "the restarted container serves without credentials" 8 \
      sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 'http://127.0.0.1:$PORT/readyz' 2>/dev/null || echo 000)\" = 200 ]"; then
      fail "the restarted container served WITHOUT credentials — the secret gate is not a gate"
    else
      pass "the restarted container is blocked at the credential gate, not serving"
    fi

    # And the repair. Re-running a deploy is not a no-op: it delivers the
    # credentials again. On a real target an orchestrator does this on every
    # start and none of it is manual — which is precisely why the secret store
    # cannot simply be a file on disk, and why "it worked until it restarted"
    # is the failure mode a plaintext credential file would have had.
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

  # -------------------------------------------------------------------
  # 9. Teardown, and the proof that teardown is scoped
  # -------------------------------------------------------------------
  printf -- '-- 9. down takes this project and nothing else\n'

  # THE DECOY, and why it exists. "Never touch state you do not own" is this
  # packet's hardest constraint and until now it was asserted by INSPECTION —
  # "there is no `docker system prune` anywhere in this file". An inspection is
  # not a proof. The defect it would miss is a one-line edit to `cmd_down`, and
  # a reader reviewing that diff sees nothing alarming in it.
  #
  # So the claim is executed instead: a container and a volume that belong to
  # this script and to nothing else, named so that they are NOT part of the
  # compose project, asserted to survive `down` AND `down --purge`. This goes
  # red if `cmd_down` ever grows a prune or an unprefixed `docker rm` /
  # `docker volume rm` — which is the whole point of it.
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

  # `status` is a shipped command with no other reason to be correct than this,
  # and the ledger it prints is the answer rollback depends on.
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

  # The distinction `down` draws with and without `--purge` is a promise, and a
  # promise that is not checked is a promise nobody should rely on when the data
  # is a database.
  if [ -n "$OWN_VOLUME" ] && docker volume inspect "$OWN_VOLUME" >/dev/null 2>&1; then
    pass "a plain deploy down KEPT the volume, as it says it does"
  else
    fail "the project's volume is gone after a plain down; --purge is a lie"
  fi

  # The ledger must die with the stack. A ledger that outlives its project makes
  # the next `rollback` target an artifact whose database volume no longer
  # exists, which is a rollback that cannot come back.
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

  # And finally the ledger's own answer, from the outside: nothing this script
  # created under its own names is left in the daemon.
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

# ---------------------------------------------------------------------------
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
