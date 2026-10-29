#!/usr/bin/env bash
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() { printf 'usage: provision.sh [--postgres] <sandbox-name> <project> [<project> ...]\n' >&2; exit 2; }

POSTGRES=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --postgres) POSTGRES=1 ;;
    -h | --help) usage ;;
    *) ARGS+=("$arg") ;;
  esac
done
NAME="${ARGS[0]:-}"
[ -n "$NAME" ] || usage

DEPLOY_HOST="${DEPLOY_HOST:-}"
PROJECTS=()
for arg in "${ARGS[@]:1}"; do
  case "$arg" in
    *.* | *:*) DEPLOY_HOST="$arg" ;;
    *) PROJECTS+=("$arg") ;;
  esac
done
[ "${#PROJECTS[@]}" -gt 0 ] || usage

CI_DB_PROJECTS="${CI_DB_PROJECTS:-identity billing courier darkroom box}"

needs_db() {
  local p
  for p in $CI_DB_PROJECTS; do
    [ "$p" = "$1" ] && return 0
  done
  return 1
}

log() { printf '\n== %s\n' "$1"; }
ssh_() { instabox ssh "$NAME" -- "$@"; }

log "sandbox $NAME for ${#PROJECTS[@]} project(s): ${PROJECTS[*]}"
instabox get "$NAME" >/dev/null 2>&1 || instabox create --name "$NAME" --template universal >/dev/null
instabox start "$NAME" >/dev/null 2>&1 || true

if [ -z "${GH_TOKEN:-}" ]; then
  GH_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [ -z "$GH_TOKEN" ]; then
  echo "provision: no GH_TOKEN and \`gh auth token\` answered nothing — the agents cannot clone private repositories" >&2
  exit 1
fi

log "the toolchain the sandbox lacks"
timeout 180 instabox ssh "$NAME" -- "sudo apt-get update -qq && sudo apt-get install -y -qq rsync >/dev/null 2>&1; rsync --version | head -1" \
  || echo "provision: WARN rsync install did not finish — deploys that rsync will fail"
if ! ssh_ "command -v mise >/dev/null 2>&1"; then
  echo "provision: installing mise (the fleet pins every toolchain in mise.toml)"
  timeout 180 instabox ssh "$NAME" -- "curl -fsSL https://mise.run | sh" \
    || echo "provision: WARN mise install did not finish — pipelines will fall back to the sandbox's own toolchain"
fi

if printf '%s\n' "${PROJECTS[@]}" | grep -qx pantry || [ "${CI_INSTALL_POSTGRES_BIN:-0}" = "1" ]; then
  if ! ssh_ "command -v pg_ctl >/dev/null 2>&1"; then
    echo "provision: installing PostgreSQL server binaries for pantry's RLS suite"
    timeout 240 instabox ssh "$NAME" -- "sudo apt-get install -y -qq postgresql postgresql-client >/dev/null 2>&1" \
      || echo "provision: WARN postgresql install did not finish — pantry's RLS suite will skip"
  fi
fi

PG_PORT="${CI_POSTGRES_PORT:-5432}"
PG_ADMIN_PW=""
if [ "$POSTGRES" -eq 1 ]; then
  log "postgres on $NAME (port $PG_PORT)"

  if ssh_ "test -s \$HOME/ci/pg-admin-password"; then
    PG_ADMIN_PW="$(ssh_ "cat \$HOME/ci/pg-admin-password")"
  else
    PG_ADMIN_PW="$(ssh_ 'openssl rand -hex 24 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n"')"
    [ -n "$PG_ADMIN_PW" ] || { echo "provision: could not generate an admin password on $NAME (no openssl, no usable /dev/urandom)" >&2; exit 1; }
    printf '%s' "$PG_ADMIN_PW" | ssh_ "mkdir -p \$HOME/ci && cat > \$HOME/ci/pg-admin-password && chmod 600 \$HOME/ci/pg-admin-password"
  fi

  if ssh_ "docker inspect ci-postgres >/dev/null 2>&1"; then
    ssh_ "docker start ci-postgres >/dev/null 2>&1 || true"
    echo "provision: ci-postgres exists — started; its data and role passwords are kept"
  else
    ssh_ "docker run -d --name ci-postgres --restart unless-stopped \
      -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD='$PG_ADMIN_PW' -e POSTGRES_DB=postgres \
      -p ${PG_PORT}:5432 -v ci-postgres-data:/var/lib/postgresql/data \
      postgres:17-alpine >/dev/null" \
      || { echo "provision: docker run failed — is the docker daemon running on $NAME?" >&2; exit 1; }
    echo "provision: ci-postgres created (postgres:17-alpine, host port $PG_PORT)"
  fi

  if ! ssh_ "for i in \$(seq 1 60); do docker exec ci-postgres pg_isready -U postgres -d postgres -q && exit 0; sleep 1; done; exit 1"; then
    echo "provision: ci-postgres did not become ready in 60s" >&2
    ssh_ "docker logs --tail 20 ci-postgres" || true
    exit 1
  fi

  ssh_ "mkdir -p \$HOME/ci/pg-passwords"
  for p in "${PROJECTS[@]}"; do
    needs_db "$p" || continue

    pwfile="\$HOME/ci/pg-passwords/$p"
    if ssh_ "test -s $pwfile"; then
      pw="$(ssh_ "cat $pwfile")"
      role_action="create-if-absent"
    else
      pw="$(ssh_ 'openssl rand -hex 24 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n"')"
      [ -n "$pw" ] || { echo "provision: could not generate a password for $p on $NAME" >&2; exit 1; }
      printf '%s' "$pw" | ssh_ "cat > $pwfile && chmod 600 $pwfile"
      role_action="create-or-set"
    fi

    case "$p" in
      "" | [!a-z_]* | *[!a-z0-9_]*)
        echo "provision: REFUSING '$p' as a database name — must match [a-z_][a-z0-9_]*" >&2
        exit 1
        ;;
    esac

    ssh_ "docker exec -i ci-postgres psql --no-psqlrc --quiet -U postgres -d postgres --set=ON_ERROR_STOP=1" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$p') THEN
    CREATE ROLE "$p" LOGIN NOSUPERUSER CREATEDB CREATEROLE NOREPLICATION PASSWORD '$pw';
  ELSIF '$role_action' = 'create-or-set' THEN
    ALTER ROLE "$p" LOGIN PASSWORD '$pw';
    ALTER ROLE "$p" CREATEDB CREATEROLE;
  END IF;
END
\$\$;
SQL

    ssh_ "docker exec -i ci-postgres psql --no-psqlrc --quiet -U postgres -d postgres --set=ON_ERROR_STOP=1" <<SQL
ALTER ROLE "$p" CREATEDB CREATEROLE;
SQL

    ssh_ "docker exec -i ci-postgres psql --no-psqlrc --quiet -U postgres -d postgres --set=ON_ERROR_STOP=1" <<SQL
SELECT 'CREATE DATABASE "$p" OWNER "$p"'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$p')\gexec
SQL

    app_role="${p}_app"
    app_pw="$pw"
    app_pwfile="\$HOME/ci/pg-passwords/${app_role}"
    printf '%s' "$app_pw" | ssh_ "cat > $app_pwfile && chmod 600 $app_pwfile"
    app_action="create-or-set"
    ssh_ "docker exec -i ci-postgres psql --no-psqlrc --quiet -U postgres -d postgres --set=ON_ERROR_STOP=1" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$app_role') THEN
    CREATE ROLE "$app_role" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD '$app_pw';
  ELSIF '$app_action' = 'create-or-set' THEN
    ALTER ROLE "$app_role" LOGIN PASSWORD '$app_pw';
  END IF;
END
\$\$;
SQL
    ssh_ "docker exec -i ci-postgres psql --no-psqlrc --quiet -U postgres -d postgres --set=ON_ERROR_STOP=1" <<SQL
REVOKE ALL ON DATABASE "$p" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE "$p" TO "$app_role";
SQL

    ssh_ "docker exec -i ci-postgres psql --no-psqlrc --quiet -U postgres -d postgres --set=ON_ERROR_STOP=1" <<SQL
REVOKE ALL ON DATABASE "$p" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE "$p" TO "$p";
ALTER ROLE "$p" CONNECTION LIMIT ${CI_PG_ROLE_CONNECTIONS:-50};
ALTER ROLE "$p" SET statement_timeout = '${CI_PG_STATEMENT_TIMEOUT_MS:-15000}';
ALTER ROLE "$p" SET idle_in_transaction_session_timeout = '${CI_PG_IDLE_IN_TRANSACTION_TIMEOUT_MS:-30000}';
SQL
    echo "provision: $p -> database $p, role $p, DATABASE_URL/TEST_DATABASE_URL"
  done
fi

log "registry login, when the token can write packages"
GH_USER="${GH_USER:-$(gh api user -q .login 2>/dev/null || true)}"
if [ -n "$GH_USER" ]; then
  if ssh_ "printf '%s' '$GH_TOKEN' | docker login ghcr.io -u '$GH_USER' --password-stdin >/dev/null 2>&1"; then
    echo "provision: ghcr.io logged in as $GH_USER"
  else
    echo "provision: WARN ghcr.io login failed — keyholder's gate will fail to push/pull images"
  fi
else
  echo "provision: WARN could not resolve a GitHub user (set GH_USER) — skipping ghcr.io login"
fi

log "the kit checkout the pipelines read"
ssh_ "mkdir -p \$HOME/workspace/anywaye"
if ssh_ "test -d \$HOME/workspace/anywaye/kit/.git"; then
  ssh_ "git -C \$HOME/workspace/anywaye/kit fetch --quiet origin master 2>/dev/null && git -C \$HOME/workspace/anywaye/kit reset --hard origin/master --quiet || true"
  echo "provision: kit checkout refreshed"
else
  ssh_ "git clone --depth 1 \"https://x-access-token:${GH_TOKEN}@github.com/anywaye/kit.git\" \$HOME/workspace/anywaye/kit 2>/dev/null || git clone --depth 1 \"https://x-access-token:${GH_TOKEN}@github.com/anywaye/kit.git\" \$HOME/workspace/anywaye/kit" \
    && echo "provision: kit cloned into \$HOME/workspace/anywaye/kit" \
    || echo "provision: WARN kit clone failed — pipelines that read kit/ will fail"
fi

log "the shared poller and supervisor"
ssh_ "mkdir -p ~/ci/agents ~/ci-env.d ~/ci-logs ~/ci/run && cat > ~/ci/agent.sh && chmod +x ~/ci/agent.sh" \
  < "$KIT_DIR/backends/instabox/agent.sh"
ssh_ "cat > ~/ci/supervisor.sh && chmod +x ~/ci/supervisor.sh" \
  < "$KIT_DIR/backends/instabox/supervisor.sh"

log "the legacy single-project state, read once"
legacy=""
if ssh_ "test -f ~/.ci-env" 2>/dev/null; then
  legacy="$(ssh_ "cat ~/.ci-env" 2>/dev/null || true)"
fi

log "one binding per project"
for p in "${PROJECTS[@]}"; do
  envf="\$HOME/ci-env.d/$p.env"
  {
    if grep -qx "PROJECT_NAME=$p" <<<"$legacy"; then
      printf '%s\n' "$legacy"
    fi
    echo "PROJECT_REPO_URL=https://github.com/anywaye/${p}.git"
    echo "PROJECT_NAME=${p}"
    echo "CI_BRANCH=${CI_BRANCH:-master}"
    echo "CI_POLL_SECONDS=${CI_POLL_SECONDS:-120}"
    echo "GH_TOKEN=${GH_TOKEN}"
    echo "GOLANGCI_LINT_CACHE=\$HOME/.cache/golangci-lint/${p}"
    if [ -n "$DEPLOY_HOST" ]; then
      echo "DEPLOY_HOST=${DEPLOY_HOST}"
    fi
    if [ "$POSTGRES" -eq 1 ] && needs_db "$p"; then
      db_pw="$(ssh_ "cat \$HOME/ci/pg-passwords/$p")"
      echo "PROJECT_DB=1"
      echo "DATABASE_URL=postgres://${p}:${db_pw}@localhost:${PG_PORT}/${p}?sslmode=disable"
      echo "TEST_DATABASE_URL=postgres://${p}:${db_pw}@localhost:${PG_PORT}/${p}?sslmode=disable"
      echo "TEST_DATABASE_ADMIN_URL=postgres://postgres:${PG_ADMIN_PW}@localhost:${PG_PORT}/postgres?sslmode=disable"
    fi
    if [ "$p" = "pantry" ]; then
      pantry_pg_bin="$(ssh_ 'for c in /usr/lib/postgresql/*/bin /opt/homebrew/opt/postgresql@*/bin /usr/local/opt/postgresql@*/bin /usr/lib/postgresql/*/bin; do [ -x "$c/pg_ctl" ] && { echo "$c"; exit 0; }; done; command -v pg_ctl >/dev/null 2>&1 && dirname "$(command -v pg_ctl)"')"
      if [ -n "$pantry_pg_bin" ]; then
        echo "PANTRY_PG_BIN=${pantry_pg_bin}"
      fi
    fi
    if [ -n "${CI_EXTRA_ENV:-}" ]; then
      printf '%s\n' "$CI_EXTRA_ENV"
    fi
  } | ssh_ "cat > $envf && chmod 600 $envf"

  {
    printf '#!/usr/bin/env bash\n'
    printf '# generated by kit/backends/instabox/provision.sh — do not edit on the sandbox.\n'
    printf '# The <project> binding of the shared poller: which env, which name, which log.\n'
    printf 'export CI_ENV="$HOME/ci-env.d/%s.env"\n' "$p"
    printf 'export AGENT_NAME="%s"\n' "$p"
    printf 'export AGENT_RUN_LOG="$HOME/ci-logs/%s-last-run.log"\n' "$p"
    printf '# mise installs itself into ~/.local/bin and its toolchains into shims;\n'
    printf '# a non-login ssh shell has neither on PATH, so the binding supplies them.\n'
    printf 'export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"\n'
    printf 'exec bash "$HOME/ci/agent.sh"\n'
  } | ssh_ "cat > ~/ci/agents/$p.sh && chmod +x ~/ci/agents/$p.sh"
  echo "provision: $p -> ~/ci-env.d/$p.env, ~/ci/agents/$p.sh"
done

log "stop any poller this change replaces"
ssh_ "pkill -f '[c]i/supervisor.sh' 2>/dev/null || true; pkill -f '[c]i/agent.sh' 2>/dev/null || true; sleep 1; true"

log "start the supervisor"
ssh_ "nohup bash ~/ci/supervisor.sh --loop > ~/ci-supervisor.log 2>&1 & disown"
sleep 4

log "verify"
ssh_ "pgrep -f '[c]i/supervisor.sh' >/dev/null && echo 'provision: the supervisor is running' || { echo 'provision: THE SUPERVISOR IS NOT RUNNING'; tail -n 20 ~/ci-supervisor.log; exit 1; }"
want="${#PROJECTS[@]}"
got="$(ssh_ "pgrep -fc '[c]i/agent.sh' || true")"
if [ "$got" = "$want" ]; then
  echo "provision: $got of $want project agents are running: ${PROJECTS[*]}"
else
  echo "provision: expected $want project agents, found $got — see ~/ci-logs/<project>.log" >&2
  ssh_ "for f in ~/ci-logs/*.log; do echo \"--- \$f\"; tail -n 10 \"\$f\"; done" || true
  exit 1
fi

log "provision: done — ${PROJECTS[*]} build themselves on every push to ${CI_BRANCH:-master}"
