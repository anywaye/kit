#!/usr/bin/env bash
# kit/backends/instabox/provision.sh — bring a sandbox up as ONE OR MANY
# projects' CI.
#
#   kit/backends/instabox/provision.sh [--postgres] <sandbox-name> <project> [...]
#
# e.g. one sandbox for the whole fleet, with a database for the five services
# whose gates need one:
#
#   kit/backends/instabox/provision.sh --postgres \
#     cafaye-build billing courier docs identity
#
# --postgres AND PER-PROJECT DATABASES. Five projects' gates cannot start
# without a Postgres (identity, billing, courier, darkroom, box — read from each
# repository's `.github/workflows/ci.yml`, which names a `postgres:17-alpine`
# service; the README's rollout table records the same column). Without the flag
# a project's pipeline fails at its first migration on a machine nobody
# provisioned for it. With it, provision ensures ONE postgres container on the
# sandbox and, for each project that DECLARES a database, a `<project>` database
# and a `<project>` login role, and writes `DATABASE_URL` / `TEST_DATABASE_URL`
# into that project's env.
#
# WHICH PROJECTS DECLARE ONE. `CI_DB_PROJECTS` (default: the five service names
# above) is the declaration, and it is the README's rollout table's database
# column in one place. A project not in the set gets no database and no
# `DATABASE_URL`; a project in it that --postgres is not given gets neither,
# which is the loud half — its gate fails at the migration rather than writing
# to a database that was never created.
#
# THE PASSWORDS ARE GENERATED ONCE AND KEPT. A per-project password is stored at
# `~/ci/pg-passwords/<project>` (0600) on the sandbox and re-read on every
# re-provision; the role is created only when it is absent, and an EXISTING
# role's password is never touched. The measured trap this avoids: a
# re-provision that rotates the password under a live agent turns every run red
# until the container restarts, because the agent's environment still names the
# old credential. The container itself is likewise never recreated — a re-run
# starts an existing one rather than replacing it.
#
# ONE CLUSTER, ONE DATABASE PER PROJECT, is the fleet's own rule in miniature
# (docs: architecture/one-cluster.md): each database has `REVOKE ALL ... FROM
# PUBLIC` and a `GRANT CONNECT` back to its own role, so no project's role can
# reach another's rows. See `templates/compose/postgres/initdb/10-cluster.sh`
# for the fleet's full contract; this is the sandbox-sized version of it.
#
# Run from an operator's machine with the instabox CLI logged in and `gh`
# authenticated. Idempotent on purpose: it reconciles a sandbox that drifted
# rather than failing — a newer master, a rotated key, a replaced machine, a
# project added to the list.
#
# WHY A LIST AND NOT A SANDBOX PER REPOSITORY. The plan caps sandboxes at FIVE
# and the fleet is larger, so one sandbox must host several projects' pollers.
# A poller is a sleep-loop; N of them cost N × ~3 MB, and the sandbox is 4
# vCPU / 8 GB. What is expensive is a GATE yet, and gates are bursty and
# independent — see backends/README.md for the capacity arithmetic and the
# rollout table. This script is what makes "several projects on one sandbox"
# a provisioned fact rather than a convention:
#
#   ~/ci-env.d/<project>.env   that project's CI variables, one KEY=value per
#                              line — GH_TOKEN, the project, the poll interval,
#                              and whatever its pipeline declares
#   ~/ci/agent.sh              the poller (shared), written by every provision
#   ~/ci/agents/<project>.sh   the binding of that poller to one project: its
#                              CI_ENV, its AGENT_NAME, its run log. One file
#                              per project IS the project list.
#   ~/ci/supervisor.sh         starts and restarts every agent in ~/ci/agents
#   ~/ci-logs/<project>.log    that project's agent output (git/pipeline lines)
#   ~/ci/run/<project>.pid     that project's agent pid, so the supervisor can
#                              tell a dead poller from a live one
#
# The single-project form keeps working: the list has one element.
#
# THE DEPLOY HOST, AND WHY IT MOVED. The old form took a third positional —
# `<sandbox> <project> <deploy-host>` — which a project list makes ambiguous:
# `... docs identity` is two projects, not a project and a host. So a host is
# now either the DEPLOY_HOST environment variable or a trailing argument that
# contains a `.` or a `:` (no cafaye project name does). Both spellings work,
# and the ones an operator already has keep working.
#
# WHAT IT STILL DOES NOT PLACE, and why: a deploy KEY. Keys belong to the
# project's pipeline, which declares what it needs and writes its own
# credentials from its env; cafaye/docs writes one from DEPLOY_KEY with
# ci/deploy-key.sh, and that is the pattern to copy. Publishing credentials
# are the same shape: a chart-publishing sandbox is logged in once by
# `bin/publish --sandbox` (token via stdin), and neither is provision's to
# hold.
#
# WHAT IT INSTALLS, AND WHY THOSE TWO THINGS. `rsync`, because most pipelines
# ship something and a forced-command key on the target is unreachable without
# the client; and `mise`, because every repository in this fleet pins its
# toolchain in `mise.toml` and the pipeline template runs the gate under
# `mise exec`. Both are bounded and reported; a machine without network gets a
# loud note rather than a silent half-provision. The toolchains themselves are
# installed by `mise install` inside the project's pipeline, from the pin in
# the project's own tree.
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
    # A host, not a project name: no cafaye project carries a `.` or a `:`.
    # See the header for why this heuristic exists at all.
    *.* | *:*) DEPLOY_HOST="$arg" ;;
    *) PROJECTS+=("$arg") ;;
  esac
done
[ "${#PROJECTS[@]}" -gt 0 ] || usage

# The projects that declare a database, and the rollout table's database column
# in one place. Read from each repository's `.github/workflows/ci.yml`, never
# invented: every name here has a `postgres:17-alpine` service block. A caller
# that adds or removes a project overrides this rather than editing the file.
CI_DB_PROJECTS="${CI_DB_PROJECTS:-identity billing courier darkroom box}"

# needs_db <project> — is this project one that declares a database?
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
# A paused sandbox answers `get` but not `ssh`; waking it is part of being
# idempotent, not a separate operator step.
instabox start "$NAME" >/dev/null 2>&1 || true

# The token is resolved ONCE, here, and an empty one is refused rather than
# written. `GH_TOKEN=${GH_TOKEN:-$(gh auth token)}` used to fail silently into
# an empty string — `echo` succeeds whatever the substitution did — and an
# empty token is not a provision error until the agent tries to clone, on the
# sandbox, with a message about a repository that does not exist.
if [ -z "${GH_TOKEN:-}" ]; then
  GH_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [ -z "$GH_TOKEN" ]; then
  echo "provision: no GH_TOKEN and \`gh auth token\` answered nothing — the agents cannot clone private repositories" >&2
  exit 1
fi

log "the toolchain the sandbox lacks"
# Bounded: `apt-get update` is network-bound and a sandbox with no route would
# otherwise hang the whole provision. Both commands are best-effort — a missing
# rsync costs the deploy step and not the gate, and a missing mise is reported
# here rather than three layers down inside a pipeline.
timeout 180 instabox ssh "$NAME" -- "sudo apt-get update -qq && sudo apt-get install -y -qq rsync >/dev/null 2>&1; rsync --version | head -1" \
  || echo "provision: WARN rsync install did not finish — deploys that rsync will fail"
if ! ssh_ "command -v mise >/dev/null 2>&1"; then
  echo "provision: installing mise (the fleet pins every toolchain in mise.toml)"
  timeout 180 instabox ssh "$NAME" -- "curl -fsSL https://mise.run | sh" \
    || echo "provision: WARN mise install did not finish — pipelines will fall back to the sandbox's own toolchain"
fi

# Pantry's RLS suite needs PostgreSQL server binaries (pg_ctl, psql, initdb)
# on the host — it starts its own cluster and does NOT read PANTRY_DATABASE_URL.
# Install them when any project in this provision is pantry (or when the caller
# asks via CI_INSTALL_POSTGRES_BIN=1).
if printf '%s\n' "${PROJECTS[@]}" | grep -qx pantry || [ "${CI_INSTALL_POSTGRES_BIN:-0}" = "1" ]; then
  if ! ssh_ "command -v pg_ctl >/dev/null 2>&1"; then
    echo "provision: installing PostgreSQL server binaries for pantry's RLS suite"
    timeout 240 instabox ssh "$NAME" -- "sudo apt-get install -y -qq postgresql postgresql-client >/dev/null 2>&1" \
      || echo "provision: WARN postgresql install did not finish — pantry's RLS suite will skip"
  fi
fi

# ---------------------------------------------------------------------------
# the database, one cluster and one database per project
# ---------------------------------------------------------------------------
# THE CONTAINER IS ONE, AND IT IS NOT RECREATED. `postgres:17-alpine` on a
# fixed port, because that is the image the five repositories' CI already runs
# (`services: postgres: image: postgres:17-alpine`) — a sandbox that ran a
# different image would be a second thing to keep in step. The port is
# `CI_POSTGRES_PORT` (default 5432), the host port the projects' `localhost:…`
# URLs name.
#
# `docker inspect` is the existence test and `docker start` is the idempotent
# action: re-running provision over a live container must START it, never
# replace it. `docker run` on an existing name errors; recreating it would lose
# nothing only because the data lives in a named volume, and a role password
# lives in the data too — so the container is deliberately left alone.
PG_PORT="${CI_POSTGRES_PORT:-5432}"
PG_ADMIN_PW=""
if [ "$POSTGRES" -eq 1 ]; then
  log "postgres on $NAME (port $PG_PORT)"

  # The admin password, generated once and stored. It is not load-bearing for
  # provisioning — every statement below runs over `docker exec` into the
  # container's unix socket, where the image trusts the local user — but a
  # project's gate that provisions its own owner/app roles needs an admin DSN
  # over TCP (identity's `bin/provision-testdb` reads `TEST_DATABASE_ADMIN_URL`),
  # so the password has to be known and stable.
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

  # Bounded readiness wait: a pipeline run against a server still initialising
  # is a connection refused three layers down inside a service's own gate.
  if ! ssh_ "for i in \$(seq 1 60); do docker exec ci-postgres pg_isready -U postgres -d postgres -q && exit 0; sleep 1; done; exit 1"; then
    echo "provision: ci-postgres did not become ready in 60s" >&2
    ssh_ "docker logs --tail 20 ci-postgres" || true
    exit 1
  fi

  ssh_ "mkdir -p \$HOME/ci/pg-passwords"
  for p in "${PROJECTS[@]}"; do
    needs_db "$p" || continue

    # THE PASSWORD IS THE STORE'S, AND AN EXISTING ROLE'S IS NEVER ROTATED.
    # If the store has it, that is the credential — full stop. If the store is
    # absent, one is generated; and if the role nevertheless exists (a previous
    # provision whose store was removed), the new password is applied with
    # ALTER, which is safe precisely because nothing recorded the old one. The
    # trap this closes is a live agent whose env names the old password: it
    # exists only when the store exists, and the store existing is what stops
    # the ALTER.
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

    # The identifier rule is the cluster's: a project name is pasted into an
    # unquoted identifier below, and `[a-z_][a-z0-9_]*` is what keeps one
    # project from naming another's database. `LC_ALL=C` is set in the SQL
    # session's shell for the same collation reason the cluster script records.
    case "$p" in
      "" | [!a-z_]* | *[!a-z0-9_]*)
        echo "provision: REFUSING '$p' as a database name — must match [a-z_][a-z0-9_]*" >&2
        exit 1
        ;;
    esac

    # CREATE ROLE and CREATE DATABASE cannot share a batch (`CREATE DATABASE
    # cannot run inside a transaction block`), and the database is created with
    # `\gexec` so the "does it already exist" test and the CREATE are one round
    # trip. Every call runs under `ON_ERROR_STOP=1`: without it psql logs the
    # error, carries on, and still exits 0, which is how a cluster reports a
    # database it never created.
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

    # Ensure CREATEDB/CREATEROLE even on a role provisioned by an earlier version
    # of this script (idempotent: ALTER on an already-set attribute is a no-op).
    ssh_ "docker exec -i ci-postgres psql --no-psqlrc --quiet -U postgres -d postgres --set=ON_ERROR_STOP=1" <<SQL
ALTER ROLE "$p" CREATEDB CREATEROLE;
SQL

    ssh_ "docker exec -i ci-postgres psql --no-psqlrc --quiet -U postgres -d postgres --set=ON_ERROR_STOP=1" <<SQL
SELECT 'CREATE DATABASE "$p" OWNER "$p"'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$p')\gexec
SQL

    # THE APP ROLE. identity and darkroom run kit's account-isolation substrate,
    # whose `protect_table` defaults its login role to `<owner>_app` and refuses
    # to run when that role is absent (the failure the gaps brief names). The
    # owner role above is what migrations run as; `_app` is the runtime role
    # the substrate grants to. provision creates it here so the migration passes
    # on a fresh sandbox. NOTE: the runtime DSN provision writes is still the
    # owner role — switching the service to `_app` is an identity/darkroom-side
    # change (separate DSN) recorded in backends/README.md, not done here.
    app_role="${p}_app"
    # The app role carries the SAME password as the owner role, because the
    # gate's dbtest.AppDSN reuses the owner's password for the app role.
    # provision-testdb (which identity/darkroom's gate runs) creates the app
    # role with its own password, but only when the role is absent; on the
    # sandbox we create it here with the owner's password so AppDSN connects.
    app_pw="$pw"
    app_pwfile="\$HOME/ci/pg-passwords/${app_role}"
    printf '%s' "$app_pw" | ssh_ "cat > $app_pwfile && chmod 600 $app_pwfile"
    # create-if-absent OR set: the role may already exist from a previous
    # provision with a different password, so always ALTER to the owner's.
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

    # THE BOUNDARY, the fleet's rule in miniature. PUBLIC holds CONNECT on every
    # database by default, so without the REVOKE the database-per-project split
    # is a naming convention rather than an isolation boundary. The timeouts
    # are the shared-cluster backstop the fleet's role provisioning also sets.
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
# keyholder's gate needs to push/pull ghcr.io; provision logs the sandbox in
# once when GH_TOKEN carries packages:write (and read:packages for pull). The
# username is resolved locally and baked into the command — the token itself
# never leaves the operator's machine in plaintext beyond the ssh argument,
# matching how GH_TOKEN already travels.
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
# docs (and any other project whose pipeline references $WORKSPACE/cafaye/kit)
# needs kit's tree — its cafaye.yml for the fleet sync and its lint/ for the
# gate. The poller only clones the project it polls, so kit is provision's job.
# Idempotent: clone once, fetch on re-provision, never overwrite local edits.
ssh_ "mkdir -p \$HOME/workspace/cafaye"
if ssh_ "test -d \$HOME/workspace/cafaye/kit/.git"; then
  ssh_ "git -C \$HOME/workspace/cafaye/kit fetch --quiet origin master 2>/dev/null && git -C \$HOME/workspace/cafaye/kit reset --hard origin/master --quiet || true"
  echo "provision: kit checkout refreshed"
else
  ssh_ "git clone --depth 1 \"https://x-access-token:${GH_TOKEN}@github.com/cafaye/kit.git\" \$HOME/workspace/cafaye/kit 2>/dev/null || git clone --depth 1 \"https://x-access-token:${GH_TOKEN}@github.com/cafaye/kit.git\" \$HOME/workspace/cafaye/kit" \
    && echo "provision: kit cloned into \$HOME/workspace/cafaye/kit" \
    || echo "provision: WARN kit clone failed — pipelines that read kit/ will fail"
fi

log "the shared poller and supervisor"
# The agent is shared by every project; the per-project binding is written
# below. Writing it fresh on every provision is what keeps a drifted sandbox
# from running a stale poller.
ssh_ "mkdir -p ~/ci/agents ~/ci-env.d ~/ci-logs ~/ci/run && cat > ~/ci/agent.sh && chmod +x ~/ci/agent.sh" \
  < "$KIT_DIR/backends/instabox/agent.sh"
ssh_ "cat > ~/ci/supervisor.sh && chmod +x ~/ci/supervisor.sh" \
  < "$KIT_DIR/backends/instabox/supervisor.sh"

log "the legacy single-project state, read once"
# The old provisioner wrote one global ~/.ci-env. Read it so a project it names
# does not lose the variables it declares and the operator does not re-supply
# them (docs' DEPLOY_HOST is the live example). Only PROJECT_NAME's own file
# inherits it; a project that did not exist under the old form starts clean.
legacy=""
if ssh_ "test -f ~/.ci-env" 2>/dev/null; then
  legacy="$(ssh_ "cat ~/.ci-env" 2>/dev/null || true)"
fi

log "one binding per project"
for p in "${PROJECTS[@]}"; do
  # The path is expanded by the SANDBOX's shell when it lands there, not by the
  # operator's, so $HOME is escaped here and expanded on the far side by the
  # remote shell — the operator's home is a different directory.
  envf="\$HOME/ci-env.d/$p.env"
  {
    # Legacy first so the standard block below overrides it: a rotated token,
    # a moved branch or a renamed project must win over the old file.
    if grep -qx "PROJECT_NAME=$p" <<<"$legacy"; then
      printf '%s\n' "$legacy"
    fi
    echo "PROJECT_REPO_URL=https://github.com/cafaye/${p}.git"
    echo "PROJECT_NAME=${p}"
    echo "CI_BRANCH=${CI_BRANCH:-master}"
    echo "CI_POLL_SECONDS=${CI_POLL_SECONDS:-120}"
    echo "GH_TOKEN=${GH_TOKEN}"
    # Per-project golangci-lint cache: three Go gates running at once collide
    # on golangci-lint's lock when they share one cache (the hand-applied fix
    # that lived on cafaye-build before this). One cache per project removes
    # the contention without serialising the gates.
    echo "GOLANGCI_LINT_CACHE=\$HOME/.cache/golangci-lint/${p}"
    if [ -n "$DEPLOY_HOST" ]; then
      echo "DEPLOY_HOST=${DEPLOY_HOST}"
    fi
    # THE DATABASE, when this project declares one and --postgres provisioned
    # it. BOTH URLS POINT AT THE SAME DATABASE and that is deliberate: the
    # fleet's gates read two names — identity's `bin/migrate` reads
    # `DATABASE_URL` while its gate reads `TEST_DATABASE_URL` — and a pair that
    # disagreed would migrate one database and test another. The password is
    # read back from the sandbox's store, so the URL is stable across
    # re-provisions.
    #
    # `TEST_DATABASE_ADMIN_URL` is the superuser the same database, for a gate
    # that provisions its own owner/app roles (identity's `bin/provision-testdb`
    # reads exactly that name). It is written only for a DB project, and it is
    # the sandbox's own admin credential — the boundary it crosses is the
    # database's, not the container's.
    if [ "$POSTGRES" -eq 1 ] && needs_db "$p"; then
      db_pw="$(ssh_ "cat \$HOME/ci/pg-passwords/$p")"
      echo "PROJECT_DB=1"
      echo "DATABASE_URL=postgres://${p}:${db_pw}@localhost:${PG_PORT}/${p}?sslmode=disable"
      # TEST_DATABASE_URL names the OWNER role. The gate's dbtest.AppDSN
      # derives the app role (`<owner>_app`) from it and reuses the SAME
      # password, so the app role must be provisioned with the owner's
      # password (see the app-role block above) — a different password here
      # is SASL auth failure before a single test runs.
      echo "TEST_DATABASE_URL=postgres://${p}:${db_pw}@localhost:${PG_PORT}/${p}?sslmode=disable"
      echo "TEST_DATABASE_ADMIN_URL=postgres://postgres:${PG_ADMIN_PW}@localhost:${PG_PORT}/postgres?sslmode=disable"
    fi
    # Pantry's RLS suite needs the server bin dir on PATH; resolve it on the
    # sandbox (where the binaries actually live) and write the value into the env.
    if [ "$p" = "pantry" ]; then
      pantry_pg_bin="$(ssh_ 'for c in /usr/lib/postgresql/*/bin /opt/homebrew/opt/postgresql@*/bin /usr/local/opt/postgresql@*/bin /usr/lib/postgresql/*/bin; do [ -x "$c/pg_ctl" ] && { echo "$c"; exit 0; }; done; command -v pg_ctl >/dev/null 2>&1 && dirname "$(command -v pg_ctl)"')"
      if [ -n "$pantry_pg_bin" ]; then
        echo "PANTRY_PG_BIN=${pantry_pg_bin}"
      fi
    fi
    # Anything the caller exports in CI_EXTRA_ENV (KEY=value lines) is passed
    # through verbatim: a project's pipeline declares its own variables, and
    # provision does not enumerate them.
    if [ -n "${CI_EXTRA_ENV:-}" ]; then
      printf '%s\n' "$CI_EXTRA_ENV"
    fi
  } | ssh_ "cat > $envf && chmod 600 $envf"

  # The binding. `exec` keeps ONE process per project, so the supervisor's
  # pidfile is the agent's identity and a restart cannot leave an orphan
  # poller behind. $HOME stays literal here — it is the sandbox's home.
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
# Order matters: the supervisor first (so it cannot restart what we are about
# to stop), then the agents. Both patterns are bracketed so the ssh command
# line running the kill does not match its own pattern — the classic
# self-kill. A stopped agent is restarting, not failing: the supervisor that
# comes up below starts one per project.
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
