#!/usr/bin/env bash
#
# kit's proof that the launch harness is shaped right, without running it.
#
#   bash tests/launch_test.sh
#
# WHAT THIS IS FOR
#   `launch/bin/launch` + `launch/docker-compose.launch.yml` bring up the
#   four product services on kit's stack. Actually bringing them up needs the
#   four sibling checkouts, built images, and a Docker daemon — none of which
#   this repository's gate may assume. So this script proves the parts that
#   can be proven without any of that, with every tool the launcher needs
#   replaced by stubs on PATH:
#
#     layout validation  (--check is green on a complete fixture layout,
#                         red on a missing sibling, a branch pin, and a
#                         stack dir that is not a kit tree; an unknown verb
#                         exits 2)
#     pin behavior       (a sha and a v<semver> tag pass validation; a branch
#                         name is refused naming the pin rule; KIT_STACK_DIR
#                         wins over a pin)
#     command safety     (down with nothing running prints "already down" and
#                         issues no `down -v`; down with a live stack issues
#                         exactly one `down -v` against BOTH compose files with
#                         the launch project directory, generates no .env, and
#                         starts nothing; --check and status start nothing —
#                         no `up`, `run` or `exec` anywhere in the stub log)
#     overlay invariants (exactly the six service blocks — postgres,
#                         identity, gateway, courier, parlor, mailpit — and no
#                         re-declaration of anything kit ships; all four build
#                         contexts parameterized; every published port a
#                         ${VAR:-15...} default in kit's block; the seam
#                         secrets fail closed on `:?`; the project name is
#                         kit-launch, never the live site-launch stack's; the
#                         database list is the literal this tier decided)
#     installer split    (no k3s/kubectl/argo/acme/ghcr/cloudflare claim in
#                         the harness; the README says the customer installer
#                         is separate and names what this harness does not
#                         prove)
#
# EVERY CLAIM HAS A CONTROL THAT MUST ANSWER DIFFERENTLY.
#   A check that passes against an empty directory is not a check. Each
#   invariant below runs green against the real tree and red against a
#   fixture built to violate exactly that one property. A control that does
#   not go red is reported as a failure of the test itself.
#
# WHAT IS NOT PROVEN HERE
#   That the stack comes up, that identity mints, that mail flows. Those need
#   the sibling checkouts and a daemon. `launch/README.md` says so in the
#   same words. No test here starts a container — the stub log is the witness
#   — and no test here may address the live `site-launch-*` stack, whose
#   project name the overlay is asserted NOT to carry.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCH="$ROOT/launch"
OVERLAY="$LAUNCH/docker-compose.launch.yml"
SCRIPT="$LAUNCH/bin/launch"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-launch-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

passes=0
skips=0
failures=0

pass() {
  printf '      PASS launch_test: %s\n' "$1"
  passes=$((passes + 1))
}

skip() {
  printf '      SKIP launch_test: %s — %s\n' "$1" "$2"
  skips=$((skips + 1))
}

fail() {
  printf '      FAIL launch_test: %s\n' "$1"
  printf '%s\n' "$2" | head -12 | sed 's/^/             /'
  failures=$((failures + 1))
}

# run <name> <expected: red|green> <command...>
run() {
  local name="$1" want="$2" out ec=0
  shift 2
  out=$("$@" 2>&1) || ec=$?
  case "$want:$ec" in
    red:0)
      fail "$name" "$out"
      ;;
    red:*)
      pass "$name"
      ;;
    green:0)
      pass "$name"
      ;;
    green:*)
      fail "$name" "$out"
      ;;
  esac
}

printf -- '-- launch_test: the harness is shaped right, without running it\n'

# ===========================================================================
# 0. The harness exists where Kit says it does
# ===========================================================================
run 'launch/ owns the harness (script + overlay + README)' green \
  test -x "$SCRIPT" -a -f "$OVERLAY" -a -f "$LAUNCH/README.md"
run 'the launcher parses (bash -n)' green bash -n "$SCRIPT"
if command -v shellcheck >/dev/null 2>&1; then
  run 'the launcher is shellcheck-clean (-S warning)' green \
    shellcheck -S warning "$SCRIPT"
else
  skip 'shellcheck' 'not installed'
fi
broken="$WORK/broken-launch"
cp "$SCRIPT" "$broken"
printf '\nif [ [\n' >>"$broken"
run 'CONTROL: a broken launcher fails the parse' red bash -n "$broken"

# ===========================================================================
# 1. The stub bench — every tool the launcher needs, recording, harmless.
# ===========================================================================
# docker is a log plus canned answers: `compose version` succeeds, `ps`
# prints rows iff $STUB_PS_UP is set, everything else exits 0. curl/jq/
# openssl/git merely exist — --check/down/status never call them for real.
STUB="$WORK/stub-bin"
mkdir -p "$STUB"
cat >"$STUB/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"$STUB_LOG"
if [ "${1:-}" = "compose" ] && [ "${2:-}" = "version" ]; then
  echo "Docker Compose version v-stub"
  exit 0
fi
if [ "${1:-}" = "compose" ]; then
  for a in "$@"; do
    if [ "$a" = "ps" ]; then
      echo "NAME   IMAGE   STATUS"
      if [ -n "${STUB_PS_UP:-}" ]; then
        echo "kit-launch-identity-1 cafaye/identity:dev running"
      fi
      exit 0
    fi
  done
fi
exit 0
EOF
chmod +x "$STUB/docker"
for t in curl jq openssl git; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB/$t"
  chmod +x "$STUB/$t"
done
export STUB_LOG="$WORK/docker.log"
: >"$STUB_LOG"

# The sibling fixture: four git checkouts, nothing else. Website and Site
# are deliberately ABSENT — the harness must not require them.
SIBS="$WORK/sibs"
mkdir -p "$SIBS/identity/.git" "$SIBS/gateway/.git" "$SIBS/courier/.git" "$SIBS/parlor/.git"

# launch_env <command...> — the fixture layout as environment, stubs on PATH,
# HOME/TMPDIR jailed to $WORK so no fetch can touch the real machine.
launch_env() {
  env -i PATH="$STUB:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK" \
    STUB_LOG="$STUB_LOG" \
    LAUNCH_IDENTITY_DIR="$SIBS/identity" LAUNCH_GATEWAY_DIR="$SIBS/gateway" \
    LAUNCH_COURIER_DIR="$SIBS/courier" LAUNCH_PARLOR_DIR="$SIBS/parlor" \
    "$@"
}

run 'CONTROL: the stub bench answers (docker compose version)' green \
  env -i PATH="$STUB:/usr/bin:/bin" docker compose version

# ===========================================================================
# 2. Layout validation
# ===========================================================================
run '--check is green on the complete fixture layout' green \
  launch_env bash "$SCRIPT" --check
run 'CONTROL: --check is red with a missing sibling checkout' red \
  env -i PATH="$STUB:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK" \
    STUB_LOG="$STUB_LOG" \
    LAUNCH_IDENTITY_DIR="$SIBS/identity" LAUNCH_GATEWAY_DIR="$SIBS/gateway" \
    LAUNCH_COURIER_DIR="$SIBS/courier" LAUNCH_PARLOR_DIR="$WORK/nowhere" \
    bash "$SCRIPT" --check
run 'an unknown verb exits non-zero (usage, not a stack)' red \
  launch_env bash "$SCRIPT" frobnicate
check_out="$WORK/check-out.txt"
launch_env bash "$SCRIPT" --check >"$check_out" 2>&1
run '--check resolves the stack to this kit checkout by default' green \
  grep -q "kit stack: $ROOT" "$check_out"
run 'CONTROL: KIT_STACK_DIR at a non-kit tree is refused' red \
  launch_env env KIT_STACK_DIR="$WORK" bash "$SCRIPT" --check

# ===========================================================================
# 3. Pin behavior
# ===========================================================================
# A sha and a tag must pass VALIDATION; resolution itself needs the network,
# so the stub git makes the fetch fail — the assertion is that the failure
# names the fetch, not the pin rule. A branch must be refused naming it.
GOOD_SHA="0123456789abcdef0123456789abcdef01234567"
pin_out="$WORK/pin-out.txt"
launch_env env LAUNCH_KIT_REF="$GOOD_SHA" bash "$SCRIPT" --check >"$pin_out" 2>&1 || true
run 'a 40-char sha passes pin validation (fails later, at the fetch)' green \
  grep -q 'could not resolve kit' "$pin_out"
launch_env env LAUNCH_KIT_REF='v1.4.0' bash "$SCRIPT" --check >"$pin_out" 2>&1 || true
run 'a v<semver> tag passes pin validation (fails later, at the fetch)' green \
  grep -q 'could not resolve kit' "$pin_out"
launch_env env LAUNCH_KIT_REF='master' bash "$SCRIPT" --check >"$pin_out" 2>&1 || true
run 'CONTROL: a branch pin is refused' red \
  launch_env env LAUNCH_KIT_REF='master' bash "$SCRIPT" --check
run 'the refusal names the moving-reference rule' green \
  grep -q 'MOVING reference' "$pin_out"
run 'CONTROL: a 40-char non-hex pin is refused' red \
  launch_env env LAUNCH_KIT_REF='0123456789abcdef0123456789abcdef0123456Z' bash "$SCRIPT" --check
launch_env env KIT_STACK_DIR="$ROOT" LAUNCH_KIT_REF='master' bash "$SCRIPT" --check >"$pin_out" 2>&1 || true
run 'KIT_STACK_DIR wins over LAUNCH_KIT_REF (explicit dir, ref unchecked)' green \
  grep -q "kit stack: $ROOT" "$pin_out"

# ===========================================================================
# 4. Command construction and teardown safety (the stub log is the witness)
# ===========================================================================
no_start_commands() {
  ! grep -Eq ' (up|run|exec)( |$)' "$STUB_LOG"
}
: >"$STUB_LOG"
run 'down with nothing running: already down, exit 0' green \
  launch_env bash "$SCRIPT" down
down_out="$WORK/down-out.txt"
launch_env bash "$SCRIPT" down >"$down_out" 2>&1
run 'the already-down path reports it, verbatim' green \
  grep -q 'already down' "$down_out"
run 'the already-down path issues no down -v' green \
  bash -c "! grep -q 'down -v' \"\$0\"" "$STUB_LOG"
: >"$STUB_LOG"
launch_env bash "$SCRIPT" --check >/dev/null 2>&1
run '--check starts nothing (no up/run/exec in the log)' green no_start_commands
: >"$STUB_LOG"
launch_env bash "$SCRIPT" status >/dev/null 2>&1
run 'status reads only (ps present, no up/run/exec/down)' green \
  bash -c "grep -q ' ps\$' \"\$0\" && ! grep -Eq ' (up|run|exec|down)( |\$)' \"\$0\"" "$STUB_LOG"

# down with a live stack: exactly one `down -v`, both -f files, the launch
# project directory — and no .env generated, nothing started.
: >"$STUB_LOG"
run 'down with a live stack exits 0' green \
  launch_env env STUB_PS_UP=1 bash "$SCRIPT" down
run 'the live down composes BOTH files (kit stack + overlay)' green \
  bash -c "grep -q 'templates/compose/docker-compose.yml' \"\$0\" && grep -q 'docker-compose.launch.yml' \"\$0\"" "$STUB_LOG"
run 'the live down runs in the launch project directory' green \
  bash -c "grep -q -- '--project-directory $LAUNCH' \"\$0\"" "$STUB_LOG"
run 'the live down deletes volumes (down -v, exactly once)' green \
  bash -c "[ \"\$(grep -c 'down -v' \"\$0\")\" = 1 ]" "$STUB_LOG"
run 'the live down starts nothing (no up/run/exec)' green no_start_commands
run 'the live down generates no .env in the tree' green \
  test '!' -e "$LAUNCH/.env"

# ===========================================================================
# 5. Overlay invariants, each with a control that must go red
# ===========================================================================
# Service blocks: top-level `  <name>:` lines under `services:`.
WANT="courier gateway identity mailpit parlor postgres "
services_of() {
  sed -n '/^services:/,$p' "$1" | grep -E '^  [a-z][a-z0-9-]*:$' |
    sed 's/^  //;s/:$//' | sort | tr '\n' ' '
}
services_match() { [ "$(services_of "$1")" = "$WANT" ]; }
contexts_parameterized() {
  ! grep -Eq '^[[:space:]]*context: \.\./' "$1" &&
    [ "$(grep -c 'context: ${LAUNCH_.*_DIR:-' "$1")" = 4 ]
}
ports_in_block() {
  ! grep -Eq '^[[:space:]]*- "[0-9]+:' "$1" &&
    [ "$(grep -Ec '^[[:space:]]*- "\$\{(KIT|LAUNCH)_[A-Z_]+:-15[0-9]{3}\}:' "$1")" = 5 ]
}
seam_secrets_closed() {
  [ "$(grep -c 'COURIER_TOKEN:?set COURIER_TOKEN' "$1")" = 2 ] &&
    grep -q 'COURIER_SECRET_BOX_KEY: "${COURIER_SECRET_BOX_KEY:?' "$1" &&
    grep -q 'COURIER_ERROR_RELAY_TOKEN: "${COURIER_ERROR_RELAY_TOKEN:?' "$1"
}
# substrate_free <path> — no production-substrate claim outside comments.
# Comments are stripped first (kit's own strip-comments lesson): the launcher
# NAMES k3s/Argo/ACME/GHCR in the paragraph explaining what it is not, and a
# check that fires on that paragraph teaches its reader to delete the
# explanation. A claim in executable text or YAML values is what fails.
substrate_free() { grep -v '^[[:space:]]*#' "$1" | grep -Ei 'k3s|kubectl|argo( |-)?cd|acme|ghcr|cloudflare'; test $? -ne 0; }
project_is_kit_launch() {
  grep -q '^name: ${LAUNCH_STACK_NAME:-kit-launch}$' "$1" &&
    ! grep -q 'site-launch' "$1"
}

run 'the overlay owns exactly six service blocks' green services_match "$OVERLAY"
mut="$WORK/mut.yml"
cp "$OVERLAY" "$mut"
printf '\n  redis:\n    image: redis:evil\n' >>"$mut"
run 'CONTROL: re-declaring a kit service is caught' red services_match "$mut"
cp "$OVERLAY" "$mut"
printf '\n  nats-stream-init:\n    image: evil\n' >>"$mut"
run 'CONTROL: re-adding the one-shot is caught' red services_match "$mut"

run 'all four build contexts are parameterized (no bare ../ literal)' green \
  contexts_parameterized "$OVERLAY"
sed 's|context: ${LAUNCH_IDENTITY_DIR:-../../identity}|context: ../identity|' "$OVERLAY" >"$mut"
run 'CONTROL: a literal sibling context is caught' red contexts_parameterized "$mut"

run 'every published port is a 15000-15999 default (no literal)' green \
  ports_in_block "$OVERLAY"
sed 's|"${LAUNCH_PARLOR_PORT:-15083}:3000"|"15083:3000"|' "$OVERLAY" >"$mut"
run 'CONTROL: a literal published port is caught' red ports_in_block "$mut"

run 'the seam secrets fail closed (:? on both TOKEN reads + both box keys)' green \
  seam_secrets_closed "$OVERLAY"
sed 's|${COURIER_TOKEN:?set COURIER_TOKEN|${COURIER_TOKEN:-oops|' "$OVERLAY" >"$mut"
run 'CONTROL: a soft-defaulted seam secret is caught' red seam_secrets_closed "$mut"

run 'the project name is kit-launch (never the live site-launch stack)' green \
  project_is_kit_launch "$OVERLAY"
sed 's/:-kit-launch}/:-site-launch}/' "$OVERLAY" >"$mut"
run 'CONTROL: the protected live project name is caught' red project_is_kit_launch "$mut"

run 'the database list is the literal this tier decided' green \
  bash -c "grep -q 'KIT_POSTGRES_DATABASES: \"identity,courier\"' \"\$0\"" "$OVERLAY"

# ===========================================================================
# 6. The overlay renders: `docker compose config` (client-side, no daemon)
# ===========================================================================
# A throwaway project directory holding a COPY of the overlay, sibling dirs
# beside it, the required database list exported. Real `docker compose
# config` — parsing only, it contacts no daemon — or a SKIP naming why not.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  RENDER="$WORK/render"
  mkdir -p "$RENDER/identity" "$RENDER/gateway" "$RENDER/courier" "$RENDER/parlor"
  cp "$OVERLAY" "$RENDER/docker-compose.launch.yml"
  render() {
    env "KIT_COMPOSE_DIR=$ROOT/templates/compose" \
      KIT_STACK_NAME=kit-launch-test \
      "KIT_POSTGRES_DATABASES=identity,courier" \
      COURIER_TOKEN=t COURIER_SECRET_BOX_KEY=t COURIER_ERROR_RELAY_TOKEN=t \
      "LAUNCH_IDENTITY_DIR=$RENDER/identity" "LAUNCH_GATEWAY_DIR=$RENDER/gateway" \
      "LAUNCH_COURIER_DIR=$RENDER/courier" "LAUNCH_PARLOR_DIR=$RENDER/parlor" \
      timeout 60 docker compose --project-directory "$RENDER" \
        -f "$ROOT/templates/compose/docker-compose.yml" \
        -f "$RENDER/docker-compose.launch.yml" "$@"
  }
  render_config() { (cd "$RENDER" && render config >/dev/null); }
  render_services() {
    (cd "$RENDER" && render config --services 2>/dev/null |
      sort | tr '\n' ' ' | grep -q 'courier gateway identity mailpit .*parlor.*postgres')
  }
  run 'the overlay renders against this checkout (compose config)' green render_config
  run 'the render carries all six services' green render_services
else
  skip 'compose config render (2)' 'no docker compose on PATH'
fi

# ===========================================================================
# 7. The installer split — the harness claims no production deployment
# ===========================================================================
run 'the launcher names no production substrate' green substrate_free "$SCRIPT"
run 'the overlay names no production substrate' green substrate_free "$OVERLAY"
cp "$OVERLAY" "$mut"
printf '\n      KUBECTL_APPLY_PROD: "true"\n' >>"$mut"
run 'CONTROL: a production claim in the overlay is caught' red substrate_free "$mut"
mut_bin="$WORK/mut-launch"
cp "$SCRIPT" "$mut_bin"
printf '\necho "kubectl applies prod"\n' >>"$mut_bin"
run 'CONTROL: a production claim in the launcher is caught' red substrate_free "$mut_bin"
run 'the README names the customer installer as separate and unproven here' green \
  bash -c "grep -q 'templates/substrate/install.sh' \"\$0\" && grep -q 'proves nothing about k3s' \"\$0\"" "$LAUNCH/README.md"

printf '\nlaunch_test: %d passed, %d skipped, %d failed\n' "$passes" "$skips" "$failures"
[ "$failures" -eq 0 ]
