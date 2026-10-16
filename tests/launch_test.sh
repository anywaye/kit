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
#                         red on a missing sibling, a PATH without psql, a
#                         branch pin, and a stack dir that is not a kit
#                         tree; an unknown verb exits 2)
#     pin behavior       (a sha and a v<semver> tag pass validation; a branch
#                         name is refused naming the pin rule; KIT_STACK_DIR
#                         wins over a pin)
#     command safety     (down with nothing running prints "already down" and
#                         issues no `down -v`; down with a live stack issues
#                         exactly one `down -v` against BOTH compose files with
#                         the launch project directory, generates no .env, and
#                         starts nothing; --check and status start nothing —
#                         no `up`, `run` or `exec` anywhere in the stub log)
#     credential home    (the teardown claim is asked of a SHADOW copy of
#                         launch/, whose .env this suite created, because the
#                         real one is git-ignored and belongs to a stack that
#                         may be running — see the shadow fixture in §1)
#     overlay invariants (exactly the six service blocks — postgres,
#                         identity, gateway, courier, parlor, billing, mailpit —
#                         and no re-declaration of anything kit ships; all five build
#                         contexts parameterized; every published port a
#                         ${VAR:-15...} default in kit's block; the seam
#                         secrets fail closed on `:?`; the project name is
#                         kit-launch, never the live site-launch stack's; the
#                         database list is the literal this tier decided)
#     contract fixes    (identity's runtime DSN is the LOGIN role
#                        `identity_app` and not the owner — extracted as a
#                        token, because `postgres://identity_app:` contains
#                        `postgres://identity:`; every build arg is one the
#                        service's own Dockerfile consumes; every link
#                        template resolves to a path parlor serves — checked
#                        on the literal AND on the `compose config` render;
#                        the launcher reads no committed kit pin)
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
# NOTHING HERE READS STATE THE SUITE DID NOT CREATE.
#   A check that reads a path the suite does not own is a check about the
#   machine, not about the tree: the launch assertions whose subject is
#   `launch/.env` went red on every checkout that had ever launched the stack,
#   because the operator did the right thing and generated the file the
#   launcher documents. Those claims run against a shadow copy of `launch/`
#   (§1) with no `.env` in it, and the real one is asserted untouched at the
#   end. A mutation that changes behaviour still turns them red — that is what
#   the two controls in §4 are for.
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
# openssl/git/psql merely exist — --check/down/status never call them for
# real. psql is on the bench because `--check` requires it: the launcher
# runs identity's migrations on the host through identity's own bin/migrate
# (m201), so a bench WITHOUT the stub would fail the green layout case.
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
for t in curl jq openssl git psql; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB/$t"
  chmod +x "$STUB/$t"
done
export STUB_LOG="$WORK/docker.log"
: >"$STUB_LOG"

# The sibling fixture: five git checkouts, nothing else. Website and Site
# are deliberately ABSENT — the harness must not require them.
SIBS="$WORK/sibs"
mkdir -p "$SIBS/identity/.git" "$SIBS/gateway/.git" "$SIBS/courier/.git" "$SIBS/parlor/.git" "$SIBS/billing/.git"

# canon <dir> — an absolute path, spelled the way the launcher spells its own.
#
# `mktemp -d "$TMPDIR/..."` inherits macOS's trailing-slash TMPDIR, so $WORK is
# literally `.../T//kit-launch-test.XXXX`, while the launcher's own
# `SELF="$(cd "$(dirname "$0")" && pwd)/…"` collapses that to a single slash.
# A check comparing the two strings therefore fails on any machine whose
# TMPDIR ends in `/` and passes on every machine where it does not — which is
# the shape of a check that is green for the wrong reason. Every shadow
# directory the suite compares against launcher output is canonicalised here,
# once, so the comparison is about the path the command was given.
canon() { (cd "$1" && pwd); }

# THE SHADOW LAUNCH TREE — `launch/` copied to a directory whose credential
# home the suite owns. `LAUNCH_DIR` is not an input: the launcher derives it
# from its own location (`KIT_ROOT/launch`, launch/bin/launch:30), so the only
# way to ask the down path a question ABOUT `.env` is to ask it of a `launch/`
# directory whose state this suite created. The script and the overlay are
# copied; `.env` is NOT, and that absence is the fixture.
#
# WHY THE REAL TREE CANNOT BE THE SUBJECT, and why it must not be emptied to
# become one: `launch/.env` is generated by `up`, is git-ignored, and is the
# credential home of a stack that may be RUNNING right now — SIGNUP_SIGNING_KEY
# and MFA_ENCRYPTION_KEY are exactly the two values the launcher keeps stable
# across a teardown on purpose (launch/bin/launch:327-341). An assertion that
# reads `test ! -e "$LAUNCH/.env"` in the real tree therefore reads state the
# suite did not create: it goes red for the person who did the right thing and
# launched first, which is the population this suite exists for. Measured on
# this checkout with a live launch's `.env` in place: 60 passed, 1 failed; with
# it moved aside, 61 passed. A suite that trains its readers to ignore red is
# worse than the gap it was written to close.
SHADOW="$WORK/shadow-kit"
mkdir -p "$SHADOW/launch/bin"
cp "$SCRIPT" "$SHADOW/launch/bin/launch"
cp "$OVERLAY" "$SHADOW/launch/docker-compose.launch.yml"
SHADOW_LAUNCH="$(canon "$SHADOW/launch")"
SHADOW_SCRIPT="$SHADOW_LAUNCH/bin/launch"
SHADOW_ENV="$SHADOW_LAUNCH/.env"

# shadow_env <command...> — the shadow tree as the launcher's OWN tree, kit's
# real checkout as the stack it runs on, stubs on PATH. Every teardown claim
# below runs through here, so no down-path assertion reads the real `launch/`.
shadow_env() {
  env -i PATH="$STUB:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK" \
    STUB_LOG="$STUB_LOG" KIT_STACK_DIR="$ROOT" \
    LAUNCH_IDENTITY_DIR="$SIBS/identity" LAUNCH_GATEWAY_DIR="$SIBS/gateway" \
    LAUNCH_COURIER_DIR="$SIBS/courier" LAUNCH_PARLOR_DIR="$SIBS/parlor" \
    "$@"
}

# The real credential home, recorded so the suite can prove it leaves it alone.
# `down` runs in the shadow; nothing else here writes; this is the tripwire
# that keeps both true, and it is a no-op on a checkout that has never
# launched (where there is nothing to preserve).
REAL_ENV="$LAUNCH/.env"
REAL_ENV_BEFORE="$WORK/real-env-before"
[ -f "$REAL_ENV" ] && cp "$REAL_ENV" "$REAL_ENV_BEFORE"

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

# ---- the migration client: psql on the HOST, needed by identity's migrate --
# Identity's image is distroless and migrates nothing itself, so the launcher
# runs identity's own bin/migrate on the host (§3a) against the published
# cluster port, and identity's migrate pipes each migration's Up section into
# psql (identity/bin/migrate:82-83). This is the prerequisite the manager hit
# for real: every other tool was in place, `--check` said so, and the run died
# at 'psql: command not found' AFTER both images were built.
#
# The control bench is HERMETIC rather than merely PATH-edited, and that is
# deliberate: a PATH of "$STUB:/usr/bin:/bin minus psql" is not hermetic,
# because a machine whose postgresql-client package puts psql in /usr/bin
# (Debian) would resolve the real tool and answer green where the fixture
# means red. So this bench carries ONLY the launcher's own stubs plus the
# three real utilities the script shells out to before the check — bash,
# dirname, basename — and no /usr/bin, no /bin, no psql.
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
# The refusal must NAME the tool and the host-side step, not merely exit
# non-zero: a preflight that dies elsewhere (a sibling test's refusal, a
# broken fixture) would answer red without proving the psql check exists.
nopsql_out="$WORK/nopsql-out.txt"
nopsql_env bash "$SCRIPT" --check >"$nopsql_out" 2>&1 || true
run 'the psql refusal names the tool and the host-side migration' green \
  bash -c "grep -q 'psql' \"\$0\" && grep -q 'migration' \"\$0\"" "$nopsql_out"

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
# Both teardowns run in the SHADOW tree, not this checkout: the `.env` claim is
# a claim about the launcher's own credential home, and the real one belongs to
# a stack that may be running. The stack named in the log is still kit's real
# checkout, through $KIT_STACK_DIR.
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

# down with a live stack: exactly one `down -v`, both -f files, the launch
# project directory — and no .env generated, nothing started.
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
# THE CLAIM, and precisely what it is about: a teardown must not MINT
# credentials. Not "the file happens to be absent" — a down path that wrote a
# `.env` full of freshly generated keys on its way out is the defect, and it is
# what the two controls below are built to be. Asserted against the shadow's
# credential home, which is absent before the run and therefore can only be
# present because the down path put it there.
run 'the live down generates no .env in the tree' green \
  test '!' -e "$SHADOW_ENV"

# ---- CONTROL 1: the claim is about the WRITE, not about the absence ---------
# A pre-existing `.env` must not answer for the claim in either direction: the
# check above must not be satisfied by an empty directory (there is nothing
# there to satisfy it), and a teardown must leave an existing credential home
# BYTE-IDENTICAL — one appended line is one minted key, and a rewritten key is
# a key that moved under a stack that is already running. This is the operator's
# real situation, run as a fixture instead of as pollution.
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

# ---- CONTROL 2: the assertion above is still able to go RED -----------------
# The defect the claim exists to catch, built as a fixture: a down path that
# appends one line to the credential home on its way out, inside the teardown
# branch, before the exit. Its own premise is asserted first so that a red
# answer below cannot be red for some other reason — a mutation that has
# silently stopped breaking the thing it names proves nothing.
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

# ===========================================================================
# 5. Overlay invariants, each with a control that must go red
# ===========================================================================
# Service blocks: top-level `  <name>:` lines under `services:`.
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
  # FIVE variables in the block — identity, gateway, courier, parlor, mailpit
  # — and billing's own 3000 is NOT one of them, so the literal check's total
  # is FIVE and not six. The literal allowance is billing's: its port is a
  # service contract (the one its image listens on) rather than a slot in
  # kit's shared 15000-15999, and the check below is written so that adding
  # a SECOND literal anywhere else still fails.
  ! grep -Eq '^[[:space:]]*- "[0-9]+:5432"' "$1" &&
    [ "$(grep -Ec '^[[:space:]]*- "\$\{(KIT|LAUNCH)_[A-Z_]+:-15[0-9]{3}\}:' "$1")" = 5 ] &&
    [ "$(grep -Ec '^[[:space:]]*- "3000:3000"' "$1")" = 1 ]
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
# project_is_kit_launch — the project name, and NEVER the protected live name.
#
# THE COMMENT IS NOT THE CLAIM, and that is not a technicality. This file's
# header explains the port collision with the `site-launch-*` stack — which is
# the one thing a reader of the port block most needs told — so the string is
# present in PROSE, and a check grepping the whole file reads that prose as the
# project name. It went red on exactly that the moment the explanation landed,
# which is the same lesson `substrate_free` above already encodes from the other
# side: a check that a comment can satisfy is not a check, and a check a comment
# can FALSIFY is worse, because it teaches its reader to delete the explanation.
# Comments are stripped, and the executable `name:` line is what is asserted.
project_is_kit_launch() {
  local body
  grep -q '^name: ${LAUNCH_STACK_NAME:-kit-launch}$' "$1" || return 1
  body="$(grep -v '^[[:space:]]*#' "$1")"
  case "$body" in
    *site-launch*) return 1 ;;
  esac
  return 0
}

# service_block <service> <path> — the body of one service block, and nothing
# else. A range rather than a `grep -A`, because the four services each name
# `DATABASE_URL` and a check that reads the whole file answers for whichever
# block it happened to match first.
service_block() {
  awk -v svc="$1" '
    /^  [a-z][a-z0-9_-]*:$/ { inblock = ($0 == "  " svc ":"); next }
    inblock { print }
  ' "$2"
}

# ---- F2: identity's runtime DSN is the LOGIN role, never the owner --------
# The role is extracted as the run of characters between `postgres://` and the
# next colon, and that is the whole point of the test: `postgres://identity_app:`
# CONTAINS `postgres://identity:`, so a substring match answers "owner" for both
# spellings and a check that cannot tell the login role from the owner is not a
# check. Two roles, one prefix — the trap this exists to close.
dsn_role() {
  service_block identity "$1" |
    sed -n 's/^      DATABASE_URL: "postgres:\/\/\([^:/]*\):.*/\1/p' | head -1
}
identity_login_role() { [ "$(dsn_role "$1")" = "identity_app" ]; }

# ---- F3: every build arg is one the service's Dockerfile consumes ---------
# The four services are built from sibling checkouts this repository cannot
# see, so the overlay cannot be diffed against their Dockerfiles here. What it
# can be checked against is the LIST of args those Dockerfiles declare, with its
# provenance below — because the defect was not a wrong value, it was an arg for
# a toolchain the image does not build with. `BUN_VERSION` sat on a Go,
# distroless gateway, BuildKit warned rather than refused, and the build
# proceeded under a comment asserting a pin that did not exist.
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

# ---- F4: every link template points at a path parlor serves --------------
# The paths are the front door's routes, read from `parlor/src/app` (one
# `page.tsx` per route) on 2026-10-08 and listed here because the launch stack
# cannot read parlor. What it can be checked against is the list, because the
# defect was a template pointing at `/reset` — a path parlor has never served.
# `/verify-email/confirm` appears twice on purpose: parlor carries no
# email-change screen, so the email-change purpose resolves there, which is the
# closest served path and is what F4's comment in the overlay says.
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

# strip_comments <path> — the launcher's EXECUTABLE lines, and only those.
#
# A check that greps the whole file is falsified by the comment explaining a
# removal: the paragraph recording why `kit_ref()` is gone names the file it
# read, and the first version of this check went red on the prose. That is kit's
# own lesson from the other side — a check that a comment can SATISFY is not a
# check, and a check a comment can FALSIFY is worse, because it teaches its
# reader to delete the explanation.
strip_comments() { sed 's/^[[:space:]]*#.*$//' "$1"; }

# ---- F5: no reader for a committed pin the tree does not carry -----------
# `kit_ref()` read a committed pin file, was never called, and this worktree
# carries no such file. A reader who believed the launcher honoured a pin was
# reading a function that did not participate, so the function is deleted and
# no executable line may name the file again: `resolve_stack`'s three sources
# are the whole resolution.
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
# The mirror of that control, and it is the one that failed first: this file's
# header names the protected stack to explain the port collision, and stripping
# comments is what keeps that prose from being read as the project name. With
# the whole-file grep this fixture is RED.
cp "$OVERLAY" "$mut"
printf '\n# the retired site-launch stack published these same five ports\n' >>"$mut"
run 'CONTROL: a comment naming the protected stack is not the project name' green \
  project_is_kit_launch "$mut"

run 'the database list is the literal this tier decided' green \
  bash -c "grep -q 'KIT_POSTGRES_DATABASES: \"identity,courier,billing\"' \"\$0\"" "$OVERLAY"

# ===========================================================================
# 5b. The contract corrections — the overlay against the services' own current
#     declarations. Each is a check the packet m199 added, and each carries a
#     control built to violate exactly that one property.
# ===========================================================================
run "identity's runtime DSN logs in as identity_app (the login role)" green \
  identity_login_role "$OVERLAY"
sed 's|postgres://identity_app:|postgres://identity:|' "$OVERLAY" >"$mut"
run 'CONTROL: the OWNER role on the runtime DSN is caught' red identity_login_role "$mut"
# The two spellings share a prefix — `postgres://identity_app:` CONTAINS
# `postgres://identity:` — so a check that could not tell them apart would pass
# on the defect. This asserts the extraction answers differently for each.
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

# The pin reader, the way kit's own stack_ref reads it: the first
# non-blank, non-comment line, trimmed.
kit_ref() {
  sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' kit.ref 2>/dev/null |
    grep -v '^#' | grep -v '^$' | head -1 || true
}
EOF
run 'CONTROL: a committed-pin reader is caught' red no_committed_pin_reader "$mut_launch"

# ===========================================================================
# 6. The overlay renders: `docker compose config` (client-side, no daemon)
# ===========================================================================
# A throwaway project directory holding a COPY of the overlay, sibling dirs
# beside it, the required database list exported. Real `docker compose
# config` — parsing only, it contacts no daemon — or a SKIP naming why not.
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
  # The RESOLVED DSN, not the literal: `${KIT_POSTGRES_PASSWORD:-cafaye}` and
  # `${APP_BASE_URL:-…}` are interpolated by compose, so what a container would
  # actually receive is only visible here. The role token is read the same way
  # the static check reads it — between `postgres://` and the next colon.
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
  # BILLING'S `:?` IS PROVEN BY THE RENDER RATHER THAN BY A GREP: absent values
  # fail the config, present ones pass — the seam secret's own test, at the
  # render rather than on the file, because a render that fails is a service
  # that refuses to boot.
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

# ===========================================================================
# 8. The suite did not touch the real launch tree
# ===========================================================================
# The down path runs in the shadow and everything else reads, so the credential
# home of a stack that may be RUNNING must come out of this suite exactly as it
# went in. This is the tripwire on that, and it is silent on a checkout that
# has never launched — there is nothing there to preserve, which is the state
# the `down` claim is green in on a fresh clone.
if [ -f "$REAL_ENV_BEFORE" ]; then
  run 'the suite leaves the real launch/.env untouched' green \
    cmp -s "$REAL_ENV_BEFORE" "$REAL_ENV"
fi

printf '\nlaunch_test: %d passed, %d skipped, %d failed\n' "$passes" "$skips" "$failures"
[ "$failures" -eq 0 ]
