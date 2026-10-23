#!/usr/bin/env bash
# tests/kamal_test.sh — the generated Kamal configuration is EXECUTED, not read.
#
#   bash tests/kamal_test.sh
#
# WHY THIS EXISTS, AND WHY IT RUNS THE REAL BINARIES
#
#   `config/deploy.yml` and `config/kamal-backup.yml` are two files a service
#   copies, and every rule in this repository about parse-what-you-hand-out
#   applies to them. A `yaml.safe_load` on either one would be the same weak
#   check the rest of this project has already rejected once: it says the file is
#   YAML, and nothing about whether Kamal can use it.
#
#   Three defects in this file's own history are the argument for running the
#   binaries, and none of them is a YAML syntax error:
#
#     1. `image: ghcr.io/org/repo` alongside `registry.server: ghcr.io` is valid
#        YAML, and resolves to `ghcr.io/ghcr.io/org/repo`. Measured: `kamal
#        config` reports the doubled host. A parse check is green; the deploy
#        fails at the push.
#     2. A missing `builder.arch` is valid YAML. `kamal` refuses the config
#        outright ("builder: Builder arch not set"), because a wrong
#        architecture surfaces as an exec-format error at run time.
#     3. A secret named in `config/kamal-backup.yml` but missing from the
#        backup accessory's `env.secret` list in `config/deploy.yml` is valid
#        YAML in BOTH files, and each file is internally consistent.
#        `kamal-backup validate` rejects the pair ("RESTIC_REPOSITORY or
#        RESTIC_REPOSITORY_FILE is required") because it builds the accessory
#        environment from the deploy config alone. A per-file parse cannot see
#        a cross-file contract; this test is the only thing that can.
#
#   So: the real `kamal` renders and resolves the deploy config, and the real
#   `kamal-backup` validates the pair. Both are offline and need no docker, no
#   SSH and no credentials — every secret is a throwaway value in a
#   throwaway process's environment, and the assertion is that the value never
#   reaches a file.
#
# WHAT IS AND IS NOT PROVEN HERE
#   Proven: the two files are accepted by the tools that consume them, the ERB
#   renders, every variable a rendered value depends on is required rather than
#   silently empty, the two files agree about secrets, and the drill refuses a
#   production-looking scratch database.
#   NOT proven: that a real deploy works, that a real backup runs, or that a
#   real restore succeeds. Those need a host, credentials and a database. The
#   claim this file makes is the narrow one, and it is the one a template can
#   silently lose.
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

# ---------------------------------------------------------------------------
# Tools. A skip is reported, never silent — the same rule the rest of the gate
# follows, and the reason it is a counted verdict rather than a comment.
# ---------------------------------------------------------------------------
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

# The long-run wrapper, folded into with_secrets rather than sitting beside it.
# It has to be folded in rather than composed (`env ... bounded ...`) because
# `env` execs a BINARY: a shell function is not one, and the first version of
# this test said `env "${SECRETS[@]}" bounded "$KAMAL" config` and got
# "env: bounded: No such file or directory" — a failure that then propagated
# into the cross-file case below, which reported PASS for the wrong reason.
# A control that goes red or green for a reason the test did not introduce is
# worse than no control, so the composition is done once, here, where it can be
# read.
with_secrets() {
  if [ -n "$TIMEOUT_BIN" ]; then
    env "${SECRETS[@]}" "$TIMEOUT_BIN" 120 "$@"
  else
    env "${SECRETS[@]}" "$@"
  fi
}

# ---------------------------------------------------------------------------
# A throwaway service, generated FROM THE TEMPLATE — never hand-written here.
#
# The point is that a change to `templates/kamal/*.erb` changes what is tested.
# A test that carried its own copy of the config would be a test of the copy,
# and the `rack_middleware.rb.snippet` defect in another costume.
# ---------------------------------------------------------------------------
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

# The throwaway credentials. Assembled from parts and never written to a file
# that persists: they exist only in the environment of a process that is about
# to exit, which is the property the templates depend on. They are also
# deliberately SHORT and obviously fake, so a leak of one is unmistakable.
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

# `env "${SECRETS[@]}"` — the whole point is that the values are passed to the
# child process's environment and never to a file on disk. with_secrets is
# DEFINED ABOVE, next to the other secrets, because SECRETS has to exist first.

# ---------------------------------------------------------------------------
# 1. The generated deploy.yml is accepted by the real `kamal`.
# ---------------------------------------------------------------------------
svc="$WORK/kitprobe"
if ! render_service "$svc"; then
  no 'kamal config  (the template renders)' 'ERB rendering of templates/kamal/*.erb failed'
else
  if [ -s "$svc/config/deploy.yml" ]; then
    ok 'kamal config  (the template renders to a non-empty config)'
  else
    no 'kamal config  (the template renders to a non-empty config)' 'config/deploy.yml is empty'
  fi

  # The positive control. If THIS fails, every negative below is meaningless:
  # a test suite whose happy path is broken cannot demonstrate that it detects
  # breakage. So it is asserted, and separately reported.
  out="$(cd "$svc" && with_secrets "$KAMAL" config --version latest 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    ok 'kamal config  (the real binary accepts the generated deploy.yml)'
  else
    no 'kamal config  (the real binary accepts the generated deploy.yml)' \
      "exit ${rc}" "$(printf '%s' "$out" | tail -3)"
  fi

  # The trap that a parse check cannot see: a doubled registry host is valid
  # YAML and a working `kamal config` run. Only the resolved repository is
  # wrong, and only the resolved repository shows it.
  if printf '%s' "$out" | grep -qE "^:repository: ${REGISTRY_HOST:-ghcr\.io}/ghcr\.io/"; then
    no 'kamal config  (the image name is not double-prefixed with the registry host)' \
      "resolved to $(printf '%s' "$out" | grep -E '^:repository:')"
  elif printf '%s' "$out" | grep -qE "^:repository: ghcr\.io/${ORG}/${REPO}$"; then
    ok 'kamal config  (the image name is not double-prefixed with the registry host)'
  else
    no 'kamal config  (the image name is not double-prefixed with the registry host)' \
      "expected :repository: ghcr.io/${ORG}/${REPO}, got $(printf '%s' "$out" | grep -E '^:repository:')"
  fi

  # THE SECRET ASSERTION. `kamal config` must print secret NAMES and never
  # secret VALUES. This is the check that keeps requirement 6 true on the Kamal
  # path, where the alternative — an ERB that renders `ENV['POSTGRES_PASSWORD']`
  # into the file — is one edit away and looks completely reasonable.
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

# ---------------------------------------------------------------------------
# 2. The generated PAIR is accepted by the real `kamal-backup`.
# ---------------------------------------------------------------------------
if [ -d "$svc" ]; then
  out="$(cd "$svc" && with_secrets "$KAMAL_BACKUP" validate -c config/deploy.yml 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qx 'ok'; then
    ok 'kamal-backup validate  (the real binary accepts deploy.yml + kamal-backup.yml)'
  else
    no 'kamal-backup validate  (the real binary accepts deploy.yml + kamal-backup.yml)' \
      "exit ${rc}" "$(printf '%s' "$out" | tail -3)"
  fi

  # The cross-file contract. Deleting one secret from the accessory's
  # `env.secret` list leaves BOTH files valid YAML and each internally
  # consistent; only the pair is wrong, and only the real tool says so. This is
  # the case that motivates running the binaries at all.
  broken="$WORK/crossfile"
  cp -R "$svc" "$broken"
  python3 - "$broken/config/deploy.yml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
# Drop only the first RESTIC_REPOSITORY line that sits in the backup accessory's
# secret list — the kamal-backup.yml still names it.
s = re.sub(r'\n        - RESTIC_REPOSITORY(?=\n        - RESTIC_PASSWORD)', '', s, count=1)
open(p, 'w').write(s)
PY
  out="$(cd "$broken" && with_secrets "$KAMAL_BACKUP" validate -c config/deploy.yml 2>&1)"
  # The error MESSAGE, not merely a non-zero exit. A missing file, a bad
  # timeout wrapper or a syntax error also exits non-zero, and a negative that
  # accepts any non-zero exit passes for all three — which is exactly what the
  # first run of this test did, reporting a PASS while `env` was failing to
  # find a function. The message is what makes the case specific.
  if printf '%s' "$out" | grep -q 'RESTIC_REPOSITORY or RESTIC_REPOSITORY_FILE is required'; then
    ok 'kamal-backup validate  (a secret named in kamal-backup.yml but not the accessory is REJECTED)'
  else
    no 'kamal-backup validate  (a secret named in kamal-backup.yml but not the accessory is REJECTED)' \
      "expected the RESTIC_REPOSITORY complaint, got: $(printf '%s' "$out" | tail -2)"
  fi
fi

# ---------------------------------------------------------------------------
# 3. A missing required variable is refused AT RENDER TIME, not silently blank.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 4. The retention policy is WRITTEN OUT, not inherited.
#
# kamal-backup 0.5.2's defaults happen to equal these five numbers, so leaving
# the block out would work today and keep working until the gem changed. A
# retention policy that lives in a dependency's defaults is a retention policy
# that changes on a version bump, and the diff at that moment is about the gem.
# So the template states it, and this asserts the template states it.
# ---------------------------------------------------------------------------
for pair in "keep_last: 7" "keep_daily: 7" "keep_weekly: 4" "keep_monthly: 6" "keep_yearly: 2"; do
  if grep -qF "$pair" "$ROOT/templates/kamal/kamal-backup.yml.erb"; then
    ok "kamal-backup.yml.erb  (retention ${pair%%:*} is stated, not inherited)"
  else
    no "kamal-backup.yml.erb  (retention ${pair%%:*} is stated, not inherited)" \
      "missing '${pair}' — it would fall through to the gem's default"
  fi
done

# ---------------------------------------------------------------------------
# 4b. NO ACCESSORY PUBLISHES ITS PORT, and the assertion is on the RESOLVED
#     document rather than on the template.
#
# `port: 5432` on the postgres accessory is valid YAML, and `kamal config` accepts
# it and exits 0 — the two strongest false greens available. Kamal expands it to
# "5432:5432" and hands it to `docker run --publish`, and Docker binds 0.0.0.0
# and :: when no host address is given, so the database lands on every interface
# the host has. Measured: a boot with the line fails with `Bind for 0.0.0.0:5432
# failed` when something else holds 5432, which is Docker naming the bind.
#
# Neither the loopback alternative nor a firewall is the fix, and the loopback one
# does not even work for the application: a container on the `kamal` network has
# its own 127.0.0.1, so `port: "127.0.0.1:5432:5432"` makes the database
# unreachable FROM THE APP while reducing its exposure. The app reaches the
# accessory by container name over that network, with nothing published.
#
# This is the case for which this test file's whole argument applies. A per-file
# grep for "port:" would pass on a template that publishes postgres and fail on one
# that publishes a port the service needs, and it would say nothing about what
# kamal RESOLVES. So it reads the resolved document, the way the retention
# assertions above read the template, and the two are different claims about
# different files on purpose.
# ---------------------------------------------------------------------------
resolved="$svc/config/deploy.yml"
if [ -d "$svc" ] && [ -f "$resolved" ]; then
  # accessories_block is a FUNCTION rather than a sed range inline, and the reason
  # is measured: `sed -n '/^:accessories:/,/^[^-:]/p'` — the obvious spelling —
  # stops on `  postgres:` the very next line, because `p` is neither `-` nor `:`.
  # The block it returned was two lines long, so the case below passed on a
  # document it had barely read and the planted-port control failed with an
  # apparently empty block. `^[^ ]` is a column-0 key, which is what ends a block.
  accessories_block() {
    # `seen` is load-bearing and the second version of this line got it wrong: the
    # "am I at a top-level key" test matches `:accessories:` ITSELF, because `:`
    # is not a space, so without it the block is the start line and nothing else.
    # The end condition is therefore a top-level key that is not the start.
    awk '/^:accessories:/{p=1} p && seen && /^[^ ]/{exit} p{print; seen=1}' "$1"
  }

  # The specific property: the RESOLVED accessories block, not the source. Reading
  # the source would be the false green this file exists to refuse.
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

  # The positive control for the check above, because a grep that finds nothing
  # because it read nothing is the failure mode a negative test has by
  # construction. This plants the line it forbids and asserts the same check
  # catches it — against the real binary, so the control and the case are the
  # same measurement.
  planted="$WORK/planted-port"
  cp -R "$svc" "$planted"
  # Line-based, and deliberately not a search for a substring. The first version
  # of this planted on `    image: postgres:17-alpine\n    host: ` and that string
  # also occurs INSIDE the comment explaining why there is no port line — so the
  # `port: 5432` landed in the middle of a paragraph, the rendered YAML became a
  # syntax error, and the control failed with an empty resolved block. A control
  # that plants into a comment is a control that tests nothing.
  python3 - "$planted/config/deploy.yml" <<'PY'
import re, sys
p = sys.argv[1]
lines = open(p).read().split("\n")
for i, line in enumerate(lines):
    # The accessory's own `host:`, not the one in the `ssh:` block above it and
    # not the one inside a comment.
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
    # The message is single-quoted throughout: a backtick inside double quotes is
    # a command substitution, and a `port:` in backticks is a shell trying to run
    # a command named `port` — which is exactly what the first run of this case
    # did, printing "port:: command not found" and failing for a reason that had
    # nothing to do with the case.
    no 'kamal config  (a planted accessory port line reaches the resolved document — the check above can see it)' \
      'planted a "port: 5432" line and the resolved accessories block did not carry it, so the
       check above would pass for the wrong reason. Resolved block:' \
      "$(printf '%s' "$planted_out" | accessories_block /dev/stdin)"
  fi
fi

# ---------------------------------------------------------------------------
# 5. The drill refuses a production-looking scratch database, and builds a
#    content assertion rather than a row report.
#
#    Everything here is argument handling and string building, so it needs no
#    database and no docker — which is the point of `--print-check` existing.
# ---------------------------------------------------------------------------
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

# The specific property: a `SELECT count(*)` that exits 0 for zero rows is not
# an assertion, and the whole point of the check is that an empty restore fails.
case "$check_out" in
  *"RAISE EXCEPTION"*)
    ok 'drill.sh  (an empty restored table raises, so an empty restore fails the drill)'
    ;;
  *)
    no 'drill.sh  (an empty restored table raises, so an empty restore fails the drill)' \
      'the generated check contains no RAISE EXCEPTION'
    ;;
esac

# The refusal, which is the safety property the brief names first. Each name is
# one that must be refused; the exit code is asserted so a future edit cannot
# turn a refusal into a warning.
#
# `kitprobe_drill` — the DEFAULT scratch name — is deliberately NOT in this list,
# and its absence is the point. The first version of this test listed it as
# hostile, on the reasonable-sounding grounds that it is derived from the service
# name. It is not hostile: it contains no production marker, it is what the
# script generates when `--scratch` is not passed, and the script correctly let
# it through to the next check. The case failed, and the script was right. A
# refusal list that includes a name the tool must accept trains the next reader
# to make the rule match more than it means to.
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

# A legitimate scratch name must NOT be refused — the control for the rule
# above. A check satisfied by refusing everything is a check that has stopped
# testing what it names, which is the same property self_test asserts about the
# gate itself.
#
# No `--scratch`, so this is the DEFAULT name the script derives from the
# service — the case an operator actually hits, and the one that would break
# first if the refusal list were ever widened by accident.
out="$(SERVICE_ROOT="$svc" bash "$DRILL" --table users --print-check 2>&1)"
if [ "$?" -eq 0 ] && printf '%s' "$out" | grep -q -- '--dbname=kitprobe_drill'; then
  ok 'drill.sh  (the default scratch name is accepted — the control for the refusals)'
else
  no 'drill.sh  (the default scratch name is accepted — the control for the refusals)' \
    "got: $(printf '%s' "$out" | head -2)"
fi

# No table means nothing is asserted, so it is a usage error rather than a drill
# that quietly passes.
out="$(SERVICE_ROOT="$svc" bash "$DRILL" --print-check 2>&1)"
if [ "$?" -ne 0 ] && printf '%s' "$out" | grep -q 'usage:'; then
  ok 'drill.sh  (a drill with no content table is a usage error, not a silent pass)'
else
  no 'drill.sh  (a drill with no content table is a usage error, not a silent pass)' \
    "got: $(printf '%s' "$out" | head -2)"
fi

# The generated check must contain no credential, because it is passed as an
# argument to kamal-backup and therefore lands in a process listing.
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
