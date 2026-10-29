#!/usr/bin/env bash

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
        echo "kit-launch-identity-1 anywaye/identity:dev running"
      fi
      exit 0
    fi
  done
fi
exit 0
EOF
chmod +x "$STUB/docker"
for t in curl jq openssl git psql; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB/$t"
  chmod +x "$STUB/$t"
done
export STUB_LOG="$WORK/docker.log"
: >"$STUB_LOG"

SIBS="$WORK/sibs"
mkdir -p "$SIBS/identity/.git" "$SIBS/gateway/.git" "$SIBS/courier/.git" "$SIBS/parlor/.git" "$SIBS/billing/.git"

canon() { (cd "$1" && pwd); }

SHADOW="$WORK/shadow-kit"
mkdir -p "$SHADOW/launch/bin"
cp "$SCRIPT" "$SHADOW/launch/bin/launch"
cp "$OVERLAY" "$SHADOW/launch/docker-compose.launch.yml"
SHADOW_LAUNCH="$(canon "$SHADOW/launch")"
SHADOW_SCRIPT="$SHADOW_LAUNCH/bin/launch"
SHADOW_ENV="$SHADOW_LAUNCH/.env"

shadow_env() {
  env -i PATH="$STUB:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK" \
    STUB_LOG="$STUB_LOG" KIT_STACK_DIR="$ROOT" \
    LAUNCH_IDENTITY_DIR="$SIBS/identity" LAUNCH_GATEWAY_DIR="$SIBS/gateway" \
    LAUNCH_COURIER_DIR="$SIBS/courier" LAUNCH_PARLOR_DIR="$SIBS/parlor" \
    "$@"
}

REAL_ENV="$LAUNCH/.env"
REAL_ENV_BEFORE="$WORK/real-env-before"
[ -f "$REAL_ENV" ] && cp "$REAL_ENV" "$REAL_ENV_BEFORE"

launch_env() {
  env -i PATH="$STUB:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK" \
    STUB_LOG="$STUB_LOG" \
    LAUNCH_IDENTITY_DIR="$SIBS/identity" LAUNCH_GATEWAY_DIR="$SIBS/gateway" \
    LAUNCH_COURIER_DIR="$SIBS/courier" LAUNCH_PARLOR_DIR="$SIBS/parlor" \
    LAUNCH_BILLING_DIR="$SIBS/billing" \
    "$@"
}

run 'CONTROL: the stub bench answers (docker compose version)' green \
  env -i PATH="$STUB:/usr/bin:/bin" docker compose version

run '--check is green on the complete fixture layout' green \
  launch_env bash "$SCRIPT" --check
run 'CONTROL: --check is red with a missing sibling checkout' red \
  env -i PATH="$STUB:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK" \
    STUB_LOG="$STUB_LOG" \
    LAUNCH_IDENTITY_DIR="$SIBS/identity" LAUNCH_GATEWAY_DIR="$SIBS/gateway" \
    LAUNCH_COURIER_DIR="$SIBS/courier" LAUNCH_PARLOR_DIR="$WORK/nowhere" \
    LAUNCH_BILLING_DIR="$SIBS/billing" \
    bash "$SCRIPT" --check
run 'an unknown verb exits non-zero (usage, not a stack)' red \
  launch_env bash "$SCRIPT" frobnicate
check_out="$WORK/check-out.txt"
launch_env bash "$SCRIPT" --check >"$check_out" 2>&1
run '--check resolves the stack to this kit checkout by default' green \
  grep -q "kit stack: $ROOT" "$check_out"
run 'CONTROL: KIT_STACK_DIR at a non-kit tree is refused' red \
  launch_env env KIT_STACK_DIR="$WORK" bash "$SCRIPT" --check

STUB_NO_PSQL="$WORK/stub-bin-no-psql"
mkdir -p "$STUB_NO_PSQL"
cp "$STUB/docker" "$STUB_NO_PSQL/docker"
for t in curl jq openssl git; do
  cp "$STUB/$t" "$STUB_NO_PSQL/$t"
done
for u in bash dirname basename; do
  ln -s "$(command -v "$u")" "$STUB_NO_PSQL/$u"
done
nopsql_env() {
  env -i PATH="$STUB_NO_PSQL" HOME="$WORK" TMPDIR="$WORK" \
    STUB_LOG="$STUB_LOG" \
    LAUNCH_IDENTITY_DIR="$SIBS/identity" LAUNCH_GATEWAY_DIR="$SIBS/gateway" \
    LAUNCH_COURIER_DIR="$SIBS/courier" LAUNCH_PARLOR_DIR="$SIBS/parlor" \
    "$@"
}
run 'CONTROL: --check is red when psql is missing from PATH' red \
  nopsql_env bash "$SCRIPT" --check
nopsql_out="$WORK/nopsql-out.txt"
nopsql_env bash "$SCRIPT" --check >"$nopsql_out" 2>&1 || true
run 'the psql refusal names the tool and the host-side migration' green \
  bash -c "grep -q 'psql' \"\$0\" && grep -q 'migration' \"\$0\"" "$nopsql_out"

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

no_start_commands() {
  ! grep -Eq ' (up|run|exec)( |$)' "$STUB_LOG"
}
: >"$STUB_LOG"
run 'down with nothing running: already down, exit 0' green \
  shadow_env bash "$SHADOW_SCRIPT" down
down_out="$WORK/down-out.txt"
shadow_env bash "$SHADOW_SCRIPT" down >"$down_out" 2>&1
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

: >"$STUB_LOG"
run 'down with a live stack exits 0' green \
  shadow_env env STUB_PS_UP=1 bash "$SHADOW_SCRIPT" down
run 'the live down composes BOTH files (kit stack + overlay)' green \
  bash -c "grep -q 'templates/compose/docker-compose.yml' \"\$0\" && grep -q 'docker-compose.launch.yml' \"\$0\"" "$STUB_LOG"
run 'the live down runs in the launch project directory' green \
  bash -c "grep -q -- '--project-directory $SHADOW_LAUNCH' \"\$0\"" "$STUB_LOG"
run 'the live down deletes volumes (down -v, exactly once)' green \
  bash -c "[ \"\$(grep -c 'down -v' \"\$0\")\" = 1 ]" "$STUB_LOG"
run 'the live down starts nothing (no up/run/exec)' green no_start_commands
run 'the live down generates no .env in the tree' green \
  test '!' -e "$SHADOW_ENV"

SEEDED="$WORK/shadow-kit-seeded"
mkdir -p "$SEEDED/launch/bin"
cp "$SCRIPT" "$SEEDED/launch/bin/launch"
cp "$OVERLAY" "$SEEDED/launch/docker-compose.launch.yml"
SEEDED_LAUNCH="$(canon "$SEEDED/launch")"
SEEDED_ENV="$SEEDED_LAUNCH/.env"
printf 'SIGNUP_SIGNING_KEY=seed-signup-key\nMFA_ENCRYPTION_KEY=seed-mfa-key\n' \
  >"$SEEDED_ENV"
cp "$SEEDED_ENV" "$WORK/seeded-env-before"
: >"$STUB_LOG"
shadow_env env STUB_PS_UP=1 bash "$SEEDED_LAUNCH/bin/launch" down \
  >"$WORK/seeded-down.txt" 2>&1 || true
run 'CONTROL: a pre-existing .env survives the live down byte-identical' green \
  cmp -s "$WORK/seeded-env-before" "$SEEDED_ENV"

MINT="$WORK/shadow-kit-mint"
mkdir -p "$MINT/launch/bin"
cp "$OVERLAY" "$MINT/launch/docker-compose.launch.yml"
awk -v mint='  printf "TEMP_KEY=1\n" >>"$LAUNCH_DIR/.env"' \
  '{ print; if ($0 == "  compose down -v") print mint }' \
  "$SCRIPT" >"$MINT/launch/bin/launch"
chmod +x "$MINT/launch/bin/launch"
MINT_LAUNCH="$(canon "$MINT/launch")"
: >"$STUB_LOG"
shadow_env env STUB_PS_UP=1 bash "$MINT_LAUNCH/bin/launch" down \
  >"$WORK/mint-down.txt" 2>&1 || true
run 'CONTROL premise: the minting down path really does write .env' green \
  test -f "$MINT_LAUNCH/.env"
run 'CONTROL: a down path that mints an .env is caught' red \
  test '!' -e "$MINT_LAUNCH/.env"
run 'CONTROL premise: the minting fixture is a real down (one down -v, both files)' green \
  bash -c "grep -q -- '--project-directory $MINT_LAUNCH' \"\$0\" && [ \"\$(grep -c 'down -v' \"\$0\")\" = 1 ]" "$STUB_LOG"

WANT="billing courier gateway identity mailpit parlor postgres "
services_of() {
  sed -n '/^services:/,$p' "$1" | grep -E '^  [a-z][a-z0-9-]*:$' |
    sed 's/^  //;s/:$//' | sort | tr '\n' ' '
}
services_match() { [ "$(services_of "$1")" = "$WANT" ]; }
contexts_parameterized() {
  ! grep -Eq '^[[:space:]]*context: \.\./' "$1" &&
    [ "$(grep -c 'context: ${LAUNCH_.*_DIR:-' "$1")" = 5 ]
}
ports_in_block() {
  ! grep -Eq '^[[:space:]]*- "[0-9]+:5432"' "$1" &&
    [ "$(grep -Ec '^[[:space:]]*- "\$\{(KIT|LAUNCH)_[A-Z_]+:-15[0-9]{3}\}:' "$1")" = 5 ] &&
    [ "$(grep -Ec '^[[:space:]]*- "3000:3000"' "$1")" = 1 ]
}
seam_secrets_closed() {
  [ "$(grep -c 'COURIER_TOKEN:?set COURIER_TOKEN' "$1")" = 2 ] &&
    grep -q 'COURIER_SECRET_BOX_KEY: "${COURIER_SECRET_BOX_KEY:?' "$1" &&
    grep -q 'COURIER_ERROR_RELAY_TOKEN: "${COURIER_ERROR_RELAY_TOKEN:?' "$1"
}
substrate_free() { grep -v '^[[:space:]]*#' "$1" | grep -Ei 'k3s|kubectl|argo( |-)?cd|acme|ghcr|cloudflare'; test $? -ne 0; }
project_is_kit_launch() {
  local body
  grep -q '^name: ${LAUNCH_STACK_NAME:-kit-launch}$' "$1" || return 1
  body="$(grep -v '^[[:space:]]*#' "$1")"
  case "$body" in
    *site-launch*) return 1 ;;
  esac
  return 0
}

service_block() {
  awk -v svc="$1" '
    /^  [a-z][a-z0-9_-]*:$/ { inblock = ($0 == "  " svc ":"); next }
    inblock { print }
  ' "$2"
}

dsn_role() {
  service_block identity "$1" |
    sed -n 's/^      DATABASE_URL: "postgres:\/\/\([^:/]*\):.*/\1/p' | head -1
}
identity_login_role() { [ "$(dsn_role "$1")" = "identity_app" ]; }

BUILD_ARGS_CONSUMED="identity/SERVICE_NAME identity/GO_VERSION \
gateway/GO_VERSION \
courier/ELIXIR_VERSION courier/OTP_VERSION courier/DEBIAN_VERSION"
build_args_of() {
  awk '/^  [a-z][a-z0-9_-]*:$/ { svc = substr($0, 3, length($0) - 3) }
       /^      args:$/ { inargs = 1; next }
       /^      [a-z_]+:$/ { inargs = 0 }
       inargs && /^        [A-Za-z_]+:/ { k = $1; sub(/:.*/, "", k); print svc "/" k }' "$1"
}
build_args_consumed() {
  local a
  for a in $(build_args_of "$1"); do
    case " $BUILD_ARGS_CONSUMED " in
      *" $a "*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}
gateway_toolchain_pinned() { build_args_of "$1" | grep -qx 'gateway/GO_VERSION'; }

PARLOR_PATHS=" / /login /register /forgot-password /reset-password /verify-email \
/verify-email/confirm /invitations /invitations/{token} /settings /accounts \
/admin /healthz /readyz "
link_template_paths() {
  grep -oE '[A-Z_]+_LINK_TEMPLATE: "[^"]*"' "$1" |
    sed -e 's/^[A-Z_]*_LINK_TEMPLATE: "//' -e 's/"$//' \
        -e 's|^\${APP_BASE_URL:-[^}]*}||' -e 's|?token={token}$||'
}
link_paths_served() {
  local p
  for p in $(link_template_paths "$1"); do
    case "$PARLOR_PATHS" in
      *" $p "*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

strip_comments() { sed 's/^[[:space:]]*#.*$//' "$1"; }

no_committed_pin_reader() {
  local body
  body="$(strip_comments "$1")"
  case "$body" in
    *kit.ref*) return 1 ;;
  esac
  return 0
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
cp "$OVERLAY" "$mut"
printf '\n# the retired site-launch stack published these same five ports\n' >>"$mut"
run 'CONTROL: a comment naming the protected stack is not the project name' green \
  project_is_kit_launch "$mut"

run 'the database list is the literal this tier decided' green \
  bash -c "grep -q 'KIT_POSTGRES_DATABASES: \"identity,courier,billing\"' \"\$0\"" "$OVERLAY"

run "identity's runtime DSN logs in as identity_app (the login role)" green \
  identity_login_role "$OVERLAY"
sed 's|postgres://identity_app:|postgres://identity:|' "$OVERLAY" >"$mut"
run 'CONTROL: the OWNER role on the runtime DSN is caught' red identity_login_role "$mut"
run 'the owner and the login role extract as different tokens' green \
  test "$(dsn_role "$OVERLAY")" != "$(dsn_role "$mut")"

run 'every build arg is one the service Dockerfile consumes' green \
  build_args_consumed "$OVERLAY"
run 'gateway pins the Go toolchain its Dockerfile declares' green \
  gateway_toolchain_pinned "$OVERLAY"
sed 's|        GO_VERSION: "1.26"|        BUN_VERSION: "1.3.12"|' "$OVERLAY" >"$mut"
run 'CONTROL: an unconsumed build arg is caught' red build_args_consumed "$mut"

run 'every link template points at a path parlor serves' green \
  link_paths_served "$OVERLAY"
sed 's|/verify-email/confirm?token={token}|/reset?token={token}|' "$OVERLAY" >"$mut"
run 'CONTROL: a link template pointing at an unserved path is caught' red \
  link_paths_served "$mut"

run 'the launcher carries no reader for a committed kit pin' green \
  no_committed_pin_reader "$SCRIPT"
mut_launch="$WORK/mut-launch-kitref"
cp "$SCRIPT" "$mut_launch"
cat >>"$mut_launch" <<'EOF'

kit_ref() {
  sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' kit.ref 2>/dev/null |
    grep -v '^#' | grep -v '^$' | head -1 || true
}
EOF
run 'CONTROL: a committed-pin reader is caught' red no_committed_pin_reader "$mut_launch"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  RENDER="$WORK/render"
  mkdir -p "$RENDER/identity" "$RENDER/gateway" "$RENDER/courier" "$RENDER/parlor" "$RENDER/billing"
  cp "$OVERLAY" "$RENDER/docker-compose.launch.yml"
  render() {
    env "KIT_COMPOSE_DIR=$ROOT/templates/compose" \
      KIT_STACK_NAME=kit-launch-test \
      "KIT_POSTGRES_DATABASES=identity,courier,billing" \
      COURIER_TOKEN=t COURIER_SECRET_BOX_KEY=t COURIER_ERROR_RELAY_TOKEN=t \
      "LAUNCH_IDENTITY_DIR=$RENDER/identity" "LAUNCH_GATEWAY_DIR=$RENDER/gateway" \
      "LAUNCH_COURIER_DIR=$RENDER/courier" "LAUNCH_PARLOR_DIR=$RENDER/parlor" \
      "LAUNCH_BILLING_DIR=$RENDER/billing" \
      STRIPE_API_KEY=sk_test_fixture STRIPE_WEBHOOK_SECRET=whsec_fixture \
      timeout 60 docker compose --project-directory "$RENDER" \
        -f "$ROOT/templates/compose/docker-compose.yml" \
        -f "$RENDER/docker-compose.launch.yml" "$@"
  }
  render_config() { (cd "$RENDER" && render config >/dev/null); }
  render_services() {
    (cd "$RENDER" && render config --services 2>/dev/null |
      sort | tr '\n' ' ' | grep -q 'billing courier gateway identity mailpit .*parlor.*postgres')
  }
  rendered_dsn_role() {
    (cd "$RENDER" && render config |
      sed -n 's|^      DATABASE_URL: postgres://\([^:/]*\):.*|\1|p' | head -1)
  }
  rendered_link_paths() {
    (cd "$RENDER" && render config |
      sed -n 's|^      [A-Z_]*_LINK_TEMPLATE: http://[^/]*\(/.*\)$|\1|p' |
      sed 's|?token={token}$||')
  }
  rendered_paths_served() {
    local p
    for p in $(rendered_link_paths); do
      case " $PARLOR_PATHS " in
        *" $p "*) ;;
        *) return 1 ;;
      esac
    done
    return 0
  }
  run 'the overlay renders against this checkout (compose config)' green render_config
  run 'the render carries all seven services' green render_services
  render_billing_secrets_closed() {
    (cd "$RENDER" && render config >/dev/null 2>&1 &&
     env -u STRIPE_API_KEY -u STRIPE_WEBHOOK_SECRET        KIT_COMPOSE_DIR="$ROOT/templates/compose" KIT_STACK_NAME=kit-launch-test        "KIT_POSTGRES_DATABASES=identity,courier,billing"        COURIER_TOKEN=t COURIER_SECRET_BOX_KEY=t COURIER_ERROR_RELAY_TOKEN=t        "LAUNCH_IDENTITY_DIR=$RENDER/identity" "LAUNCH_GATEWAY_DIR=$RENDER/gateway"        "LAUNCH_COURIER_DIR=$RENDER/courier" "LAUNCH_PARLOR_DIR=$RENDER/parlor"        "LAUNCH_BILLING_DIR=$RENDER/billing"        timeout 60 docker compose --project-directory "$RENDER" config >/dev/null 2>&1 &&
       return 1 || return 0)
  }
  run 'CONTROL: billing renders closed when a Stripe value is absent' green render_billing_secrets_closed
  run 'the RENDERED identity DSN logs in as the login role' green \
    test "$(rendered_dsn_role)" = identity_app
  run 'every RENDERED link template resolves onto a path parlor serves' green \
    rendered_paths_served
else
  skip 'compose config render (2)' 'no docker compose on PATH'
fi

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

if [ -f "$REAL_ENV_BEFORE" ]; then
  run 'the suite leaves the real launch/.env untouched' green \
    cmp -s "$REAL_ENV_BEFORE" "$REAL_ENV"
fi

printf '\nlaunch_test: %d passed, %d skipped, %d failed\n' "$passes" "$skips" "$failures"
[ "$failures" -eq 0 ]
