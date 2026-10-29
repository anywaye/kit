#!/usr/bin/env bash

set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

cd "$(dirname "$SELF")/.."

STACK_TIMEOUT="${KIT_DEV_TIMEOUT:-180}"

KIT_DEV_PROFILES="${KIT_DEV_PROFILES-}"


stack_url() { stack_setting KIT_STACK_URL "https://github.com/anywaye/kit.git"; }

stack_home() { stack_setting KIT_STACK_HOME "${XDG_CACHE_HOME:-$HOME/.cache}/anywaye/kit"; }

vendor_dir() { stack_setting KIT_VENDOR_DIR ".kit/stack"; }

REF_FILE="kit.ref"

STACK_DIR=""

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
info() { printf '   %s\n' "$1"; }
die() {
  printf '\n\033[1;31mbin/dev: %s\033[0m\n' "$1" >&2
  exit "${2:-1}"
}

usage() { sed -n '2,/^$/p' "$SELF" | sed '$d'; }


stack_ref() {
  local from_env
  from_env="$(eval "printf '%s' \"\${KIT_STACK_REF:-}\"")"
  if [ -n "$from_env" ]; then
    printf '%s' "$from_env"
    return 0
  fi
  [ -f "$REF_FILE" ] || return 0
  sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$REF_FILE" 2>/dev/null |
    grep -v '^#' | grep -v '^$' | head -1 || true
  return 0
}

validate_ref() {
  local ref="$1"
  case "$ref" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  esac
  if [ "${#ref}" -eq 40 ]; then
    case "$ref" in
      *[!0-9a-f]*)
        die "$REF_FILE holds '$ref': 40 characters but not a commit sha (lowercase hex)."
        ;;
    esac
    return 0
  fi
  case "$ref" in
    v[0-9]*.[0-9]*.[0-9]*)
      local version="${ref#v}"
      local numeric="${version%%+*}"
      numeric="${numeric%%-*}"
      local major minor patch
      case "$numeric" in
        *.*.*)
          major="${numeric%%.*}"
          minor="${numeric#*.}"
          minor="${minor%%.*}"
          patch="${minor#*.}"
          patch="${patch%%.*}"
          ;;
        *)
          die "$REF_FILE holds '$ref', which is not a v<MAJOR>.<MINOR>.<PATCH> tag."
          ;;
      esac
      for part in "$major" "$minor" "$patch"; do
        case "$part" in
          '' | *[!0-9]*)
            die "$REF_FILE holds '$ref', which is not a v<MAJOR>.<MINOR>.<PATCH> tag with numeric parts."
            ;;
        esac
      done
      local suffix="${version#"$numeric"}"
      case "$suffix" in
        *[!0-9A-Za-z.+-]*)
          die "$REF_FILE holds '$ref', which is not a v<MAJOR>.<MINOR>.<PATCH> tag; a pre-release or
   build suffix may contain only letters, digits, dots and hyphens."
          ;;
      esac
      return 0
      ;;
  esac
  if [ -z "$ref" ]; then
    die "no kit ref, and $REF_FILE does not name one.
   The pin is the ref of kit this repository runs, and it is committed here so that
   'one command, always current' means the same thing on every machine and in CI.
   Write one line into $REF_FILE:
     git -C /path/to/a/kit/checkout rev-parse HEAD > $REF_FILE
   Accepted: a 40-character commit sha (lowercase hex), or a v<MAJOR>.<MINOR>.<PATCH> tag.
   Refused: a branch — 'master' is a MOVING reference, and the stack you get on Tuesday
   would not be the stack you reviewed on Monday.
   To move deliberately once there is one:  bin/dev pin <ref>"
  fi
  die "$REF_FILE holds '$ref', which is not a pin.
   Accepted: a 40-character commit sha (lowercase hex), or a v<MAJOR>.<MINOR>.<PATCH> tag.
   Refused: branch names — 'master', 'main', anything without a ref suffix — because a
   branch is a MOVING reference. \`bin/dev\` would fetch whatever it points at today, and
   the stack you get on Tuesday would not be the stack you reviewed on Monday.
   To move deliberately:  bin/dev pin <ref>"
}


read_stack_ref() {
  [ -f "$1/.kit-stack-ref" ] || return 1
  head -1 "$1/.kit-stack-ref" 2>/dev/null | tr -d ' \t\r\n'
}

stack_is_usable() {
  local dir="$1" ref="$2" have
  [ -d "$dir" ] || return 1
  have="$(read_stack_ref "$dir")" || return 1
  [ "$have" = "$ref" ] || return 1
  [ -f "$dir/templates/compose/docker-compose.yml" ] &&
    [ -f "$dir/templates/compose/otel-collector.yml" ] &&
    [ -d "$dir/templates/compose/tempo" ] &&
    [ -d "$dir/templates/compose/loki" ] &&
    [ -d "$dir/templates/compose/grafana/provisioning" ] &&
    [ -f "$dir/templates/kamal/deploy.yml.erb" ] &&
    [ -f "$dir/templates/kamal/kamal-backup.yml.erb" ] &&
    [ -f "$dir/templates/kamal/drill.sh" ]
}


generation_home() { printf '%s/.retired\n' "$(stack_home)"; }

generation_keep() {
  local n
  n="$(stack_setting KIT_STACK_KEEP_GENERATIONS 3)"
  case "$n" in
    '' | *[!0-9]* | 0) printf '3' ;;
    *) printf '%s' "$n" ;;
  esac
}

next_generation() {
  local ref="$1" home n=0
  home="$(generation_home)"
  mkdir -p "$home"
  while [ -e "$home/$ref.$n" ] || [ -L "$home/$ref.$n" ]; do
    n=$((n + 1))
    [ "$n" -lt 10000 ] || return 1
  done
  printf '%s/%s.%s' "$home" "$ref" "$n"
}

mount_sources() {
  local ids
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1 || return 1
  ids="$(docker ps -aq 2>/dev/null)" || return 1
  [ -n "$ids" ] || return 0
  docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' $ids 2>/dev/null
}

generation_is_mounted() {
  local gen="$1" src
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    case "$src" in
      "$gen"/*) return 0 ;;
    esac
  done <<<"$2"
  return 1
}

prune_generations() {
  local ref="$1" keep
  keep="$(generation_keep)"
  local home
  home="$(generation_home)"
  [ -d "$home" ] || return 0

  local lines="" path serial drop=0 n=0
  for path in "$home/$ref".*; do
    [ -d "$path" ] || continue
    serial="${path##*.}"
    lines="$lines$serial	$path
"
    n=$((n + 1))
  done
  [ "$n" -gt "$keep" ] || return 0
  drop=$((n - keep))

  local sources="" known=1
  sources="$(mount_sources)" || known=0
  if [ "$known" -ne 1 ]; then
    info "keeping $n retired generation(s): docker could not be asked what is mounted"
    return 0
  fi

  local i=0
  while IFS=$'\t' read -r serial path; do
    [ -n "${serial:-}" ] || continue
    if [ "$i" -lt "$drop" ]; then
      if generation_is_mounted "$path" "$sources"; then
        info "keeping retired generation $path: a container is mounted from it"
      else
        rm -rf "$path"
      fi
    fi
    i=$((i + 1))
  done < <(printf '%s' "$lines" | sort -n)
  return 0
}


live_dir_for() { printf '.kit/live/%s' "$1"; }

live_is_usable() {
  local dir="$1" ref="$2" have
  [ -d "$dir" ] || return 1
  have="$(read_stack_ref "$dir")" || return 1
  [ "$have" = "$ref" ] || return 1
  [ -f "$dir/templates/compose/docker-compose.yml" ] &&
    [ -f "$dir/templates/compose/otel-collector.yml" ] &&
    [ -d "$dir/templates/compose/tempo" ] &&
    [ -d "$dir/templates/compose/loki" ] &&
    [ -d "$dir/templates/compose/grafana/provisioning" ]
}

sync_live_stack() {
  local ref="$1" src="$2" dest tmp
  dest="$(live_dir_for "$ref")"
  if live_is_usable "$dest" "$ref" &&
    diff -rq "$src/templates/compose" "$dest/templates/compose" >/dev/null 2>&1; then
    info "live stack: $dest (unchanged — the snapshot already is this ref)"
    return 0
  fi
  tmp="$dest.tmp.$$"
  rm -rf "$tmp"
  mkdir -p "$tmp/templates/compose"
  cp -a "$src/templates/compose/." "$tmp/templates/compose/"
  printf '%s\n' "$ref" >"$tmp/.kit-stack-ref"
  {
    printf '%s\n' '*' '!.gitignore'
  } >"$tmp/.gitignore"
  if ! live_is_usable "$tmp" "$ref"; then
    rm -rf "$tmp"
    die "could not stage the live stack snapshot for kit@$ref from $src.
    The snapshot was left untouched; nothing was started."
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if [ -e "$dest.stale" ] || [ -L "$dest.stale" ]; then
      _stale_abs=""; case "$dest.stale" in /*) _stale_abs="$dest.stale" ;; *) _stale_abs="$PWD/$dest.stale" ;; esac
      _dest_abs=""; case "$dest" in /*) _dest_abs="$dest" ;; *) _dest_abs="$PWD/$dest" ;; esac
      _sources=""; _known=1; _sources="$(mount_sources 2>/dev/null)" || _known=0
      _keep=0
      if [ "$_known" -eq 0 ]; then
        _keep=1
      elif generation_is_mounted "$_stale_abs" "$_sources" || generation_is_mounted "$_dest_abs" "$_sources"; then
        _keep=1
      fi
      if [ "$_keep" -eq 1 ]; then
        _n=0; while [ -e "$dest.stale.$_n" ] || [ -L "$dest.stale.$_n" ]; do _n=$((_n + 1)); [ "$_n" -lt 10000 ] || break; done
        mv "$dest" "$dest.stale.$_n"
        info "previous live snapshot kept at $dest.stale.$_n (previous .stale still mounted or docker unavailable — not deleted)"
        mv "$tmp" "$dest"
        info "live stack: $dest (snapshotted from kit@$ref)"
        unset _stale_abs _dest_abs _sources _known _keep _n
        return 0
      else
        rm -rf "$dest.stale"
      fi
      unset _stale_abs _dest_abs _sources _known _keep
    fi
    mv "$dest" "$dest.stale"
    info "previous live snapshot kept at $dest.stale (it differed at an immutable ref — one side was rewritten)"
  fi
  mv "$tmp" "$dest"
  info "live stack: $dest (snapshotted from kit@$ref)"
}

fetch_stack() {
  command -v git >/dev/null 2>&1 ||
    die "git is not installed, and this script needs it to fetch kit from $(stack_url)."

  local ref="$1" dest="$2" tmp
  tmp="$dest.tmp.$$"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  git -C "$tmp" init -q
  git -C "$tmp" remote add origin "$(stack_url)"
  if ! git -C "$tmp" fetch --quiet --depth 1 origin "$ref" 2>"$tmp/.fetch-error"; then
    local why
    why="$(tail -3 "$tmp/.fetch-error" | tr '\n' ' ')"
    rm -rf "$tmp"
    die "could not fetch kit@$ref from $(stack_url).
   $why
   Check the ref exists:  git ls-remote $(stack_url) '$ref'
   To use a ref you already have on disk, point KIT_STACK_DIR at a kit checkout,
   or vendor one:  git clone --depth 1 $(stack_url) $(vendor_dir)
                        git -C $(vendor_dir) checkout $ref
                        git -C $(vendor_dir) rev-parse HEAD > $(vendor_dir)/.kit-stack-ref"
  fi
  git -C "$tmp" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
  printf '%s\n' "$ref" >"$tmp/.kit-stack-ref"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    local retired
    retired="$(next_generation "$ref")" ||
      die "could not find a free generation name under $(generation_home)"
    mv "$dest" "$retired"
    info "previous generation kept at $retired"
  fi
  mv "$tmp" "$dest"
  prune_generations "$ref"
}

resolve_stack() {
  local ref
  ref="$(stack_ref)"
  validate_ref "$ref"

  local named
  named="$(stack_setting KIT_STACK_DIR "")"
  if [ -n "$named" ]; then
    [ -d "$named" ] ||
      die "KIT_STACK_DIR='$named' is not a directory."
    [ -f "$named/templates/compose/docker-compose.yml" ] ||
      die "KIT_STACK_DIR='$named' has no templates/compose/docker-compose.yml.
   It must be the ROOT of a kit checkout, not its templates/ directory."
    STACK_DIR="$named"
    info "stack: $STACK_DIR (KIT_STACK_DIR — named explicitly, ref not checked)"
    return 0
  fi

  local cached
  cached="$(stack_home)/$ref"
  if stack_is_usable "$cached" "$ref"; then
    STACK_DIR="$cached"
    info "stack: $STACK_DIR (cache)"
    return 0
  fi

  local live
  live="$(live_dir_for "$ref")"
  if live_is_usable "$live" "$ref"; then
    STACK_DIR="$live"
    info "stack: $STACK_DIR (live snapshot — the tree this service rendered)"
    return 0
  fi

  local vendor
  vendor="$(vendor_dir)"
  if [ -e "$vendor" ]; then
    local vendored_ref=""
    vendored_ref="$(read_stack_ref "$vendor" || true)"
    if [ -z "$vendored_ref" ]; then
      die "$vendor exists but records no ref, so there is no way to know what it is.
   A directory that contains a compose file is not a kit checkout at a known version,
   and using one is how an offline loop stops matching what the team runs. Either
   remove it, or record what it is:
     git -C $vendor rev-parse HEAD > $vendor/.kit-stack-ref"
    fi
    if [ "$vendored_ref" != "$ref" ]; then
      die "$vendor is vendored at $vendored_ref, and $REF_FILE pins $ref.
   Using it anyway would run a stack you did not pin. Move the pin deliberately —
   bin/dev pin $vendored_ref — or update the vendored copy to $ref."
    fi
    if ! stack_is_usable "$vendor" "$ref"; then
      die "$vendor records $ref but is missing files the stack mounts
   (templates/compose/{docker-compose,otel-collector}.yml, tempo/, loki/,
   grafana/provisioning/, kamal/{deploy.yml.erb,kamal-backup.yml.erb,drill.sh}).
   Re-vendor it rather than starting a stack that will die four containers later
   on a bind mount."
    fi
    STACK_DIR="$vendor"
    info "stack: $STACK_DIR (vendored, and it declares the pinned ref)"
    return 0
  fi

  if [ "$(stack_setting KIT_STACK_OFFLINE 0)" = "1" ]; then
    die "offline (KIT_STACK_OFFLINE=1) and kit@$ref is not available locally.
   Tried, in order:
     KIT_STACK_DIR          not set
     $cached
                          not present, or not at this ref
     $live      not present (no previous up rendered this ref here)
     $vendor        not present
   Fix it with any one of:
     git clone --depth 1 $(stack_url) $vendor
     git -C $vendor checkout $ref
     git -C $vendor rev-parse HEAD > $vendor/.kit-stack-ref
  fi
  info "fetching kit@$ref from $(stack_url) (first run only)"
  fetch_stack "$ref" "$cached"
  STACK_DIR="$cached"
  info "stack: $STACK_DIR (fetched)"
}

env_value() {
  local name="$1"
  local file="${2:-.env}"
  local line value
  [ -f "$file" ] || return 0
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$name=" "$file" | tail -1 || true)"
  [ -n "$line" ] || return 0
  value="${line#*=}"
  value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")"
  printf '%s' "$value"
}

stack_setting() {
  local name="$1" fallback="${2:-}" value
  value="$(eval "printf '%s' \"\${$name:-}\"")"
  [ -n "$value" ] && {
    printf '%s' "$value"
    return 0
  }
  value="$(env_value "$name")"
  [ -n "$value" ] || value="$fallback"
  printf '%s' "$value"
}


compose() {
  local root="$STACK_DIR" live_ref live_root
  live_ref="$(stack_ref)"
  if [ -n "$live_ref" ]; then
    live_root="$(live_dir_for "$live_ref")"
    if live_is_usable "$live_root" "$live_ref"; then
      root="$live_root"
    fi
  fi
  local -a base=()
  base=(--project-directory . -f "$root/templates/compose/docker-compose.yml")
  [ -f docker-compose.yml ] && base+=(-f ./docker-compose.yml)
  export KIT_COMPOSE_DIR="$root/templates/compose"

  if [ -n "$KIT_DEV_PROFILES" ]; then
    if docker compose version >/dev/null 2>&1; then
      docker compose "${base[@]}" --profile "$KIT_DEV_PROFILES" "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
      docker-compose "${base[@]}" --profile "$KIT_DEV_PROFILES" "$@"
    else
      die "neither 'docker compose' (v2) nor 'docker-compose' is installed" 127
    fi
  else
    if docker compose version >/dev/null 2>&1; then
      docker compose "${base[@]}" "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
      docker-compose "${base[@]}" "$@"
    else
      die "neither 'docker compose' (v2) nor 'docker-compose' is installed" 127
    fi
  fi
}

required_compose_vars() {
  local file
  for file in "$@"; do
    [ -f "$file" ] || continue
    grep -o '\${[A-Za-z_][A-Za-z0-9_]*}' "$file" 2>/dev/null |
      sed -e 's/^\${//' -e 's/}$//'
  done | sort -u
}

preflight_required() {
  local -a files missing=()
  files=("$STACK_DIR/templates/compose/docker-compose.yml")
  [ -f docker-compose.yml ] && files+=(./docker-compose.yml)

  local var value
  while IFS= read -r var; do
    [ -n "$var" ] || continue
    value="$(stack_setting "$var" "")"
    [ -n "$value" ] || missing+=("$var")
  done <<EOF
$(required_compose_vars "${files[@]}")
EOF

  [ "${#missing[@]}" -eq 0 ] && return 0

  local count="${#missing[@]}"
  printf '\n\033[1;31mbin/dev: %s required by the compose file %s not set:\033[0m\n' \
    "$count" "$( [ "$count" -eq 1 ] && printf 'is' || printf 'are' )" >&2
  local m
  for m in "${missing[@]}"; do
    printf '  %s\n' "$m" >&2
  done
  printf '\n' >&2
  printf 'Docker Compose substitutes an empty string for a bare ${VAR} rather than\n' >&2
  printf 'refusing it, so nothing here has started yet and nothing will. The stack\n' >&2
  printf 'would come up with that value empty and fail later, minutes in.\n\n' >&2
  printf 'Set it in .env, which is the only file a developer edits:\n\n' >&2
  printf '  %s=<value>\n' "${missing[0]}" >&2
  [ "$count" -gt 1 ] && printf '  …and one line for each of the names above.\n\n' >&2
  case " ${missing[*]} " in
    *' KIT_POSTGRES_DATABASES '*)
      printf '\nFor KIT_POSTGRES_DATABASES, that value is the COMMA-separated list of\n' >&2
      printf 'the services sharing this one Postgres cluster. Each name becomes a\n' >&2
      printf 'database and an owner role of its own, and the database is the boundary\n' >&2
      printf 'between them (templates/compose/docker-compose.yml, "THE DECLARATION"):\n\n' >&2
      printf '  KIT_POSTGRES_DATABASES=alpha,beta\n\n' >&2
      printf 'One service needs its own name alone; a developer working across two\n' >&2
      printf 'services on one laptop lists both, and they get one container and two\n' >&2
      printf 'databases. Add a name later without wiping the volume: bin/dev db grant <name>\n\n' >&2
      ;;
  esac
  exit 1
}


ensure_env() {
  [ -f .env ] && return 0

  if [ -f "$STACK_DIR/templates/compose/.env.example" ]; then
    cp "$STACK_DIR/templates/compose/.env.example" .env
    info "created .env from the pinned kit ref's .env.example — edit it if a port collides"
    return 0
  fi
  die "the pinned kit ref ($STACK_DIR) has no templates/compose/.env.example.
   That is a defect in kit, not in this service: bin/dev has no template to
   create .env from. Check out the ref and see:
     git -C '$STACK_DIR' ls templates/compose/.env.example"
}

warn_stale_env_example() {
  [ -f .env.example ] || return 0
  step "a .env.example here is no longer read"
  info "bin/dev takes every KIT_* default from the pinned kit ref, and composes fall"
  info "back to those defaults for anything your .env does not set. So this file is"
  info "now dead weight that will read as authoritative and will not be."
  info "  git rm .env.example"
  info "Keep .env itself: it is where your overrides live. Your kit pin is $REF_FILE."
}


up() {
  step "resolving kit"
  resolve_stack
  sync_live_stack "$(stack_ref)" "$STACK_DIR"
  ensure_env
  warn_stale_env_example

  preflight_required

  step "starting the stack from kit@$(stack_ref) (deadline: ${STACK_TIMEOUT}s)"
  local started elapsed
  started=$(date +%s)

  if ! KIT_TIMEOUT="$STACK_TIMEOUT" compose up -d --wait --wait-timeout "$STACK_TIMEOUT"; then
    printf '\n' >&2
    printf 'bin/dev: the stack did not become healthy in %ss.\n' "$STACK_TIMEOUT" >&2
    printf 'What is unhealthy:\n' >&2
    compose ps >&2 2>&1 | sed 's/^/  /' >&2
    printf '\nIts logs:\n' >&2
    compose logs --tail 40 >&2 2>&1 | sed 's/^/  /' >&2
    printf '\nRaise the deadline with KIT_DEV_TIMEOUT=300 bin/dev, or run bin/dev logs.\n' >&2
    die "stack did not become healthy — nothing further was run, so nothing is half-migrated" 1
  fi

  step "migrating"
  migrate

  step "seeding the local admin"
  seed

  print_urls

  elapsed=$(( $(date +%s) - started ))
  step "up in ${elapsed}s"
  if [ -n "$KIT_DEV_PROFILES" ]; then
    info "observability backends are ON (compose profile: $KIT_DEV_PROFILES)"
    info "for the cheap stack instead:  bin/dev up   (no profiles, no backends)"
  else
    info "the cheap stack: postgres/nats/redis + the collector, no observability"
    info "backends. Telemetry is STILL ON — the collector is not behind the"
    info "profile, and it still drops high-cardinality dimensions at ingest."
    info "For traces/logs/metrics to read back:  KIT_DEV_PROFILES=observability bin/dev up"
    info "For the single-pane ClickStack view instead:  KIT_DEV_PROFILES=clickstack bin/dev up"
  fi
}

migrate() {
  if [ -x bin/migrate ]; then
    bin/migrate
  elif [ -x bin/rails ] && [ -f config/application.rb ]; then
    bin/rails db:prepare
  elif [ -x bin/ecto.setup ]; then
    mix ecto.create
    mix ecto.migrate
  elif [ -f Cargo.toml ] && [ -x bin/prime ]; then
    bin/prime --fast
    info "no bin/migrate: ran bin/prime --fast — apply migrations in your own task if you have one"
  else
    die "no migration command found (looked for bin/migrate, bin/rails, bin/ecto.setup). Add bin/migrate and re-run."
  fi
}

seed() {
  if [ -x bin/seed ]; then
    bin/seed
  elif [ -x bin/rails ] && [ -f config/application.rb ]; then
    bin/rails db:seed
  else
    info "no bin/seed: skipping the admin seed"
  fi
}

db_grant() {
  local svc="${1:-}"
  if [ -z "$svc" ]; then
    die "usage: bin/dev db grant <service-name>"
  fi
  case "$svc" in
    [!a-z_]* | *[!a-z0-9_]*)
      die "'$svc' is not a bare identifier. It must match [a-z_][a-z0-9_]*, and it has to be the SAME name as your database, your owner role and your application_name."
      ;;
  esac

  [ -f .env ] && { set -a && . ./.env && set +a; }
  local port="${KIT_POSTGRES_PORT:-15500}"
  local user="${KIT_POSTGRES_USER:-anywaye}"
  local pass="${KIT_POSTGRES_PASSWORD:-anywaye}"
  local admin_db="${KIT_POSTGRES_DB:-anywaye_platform}"

  cat <<SQL
bin/dev db grant $svc — add one service to a cluster that is already running.

  docker-entrypoint-initdb.d only runs on a FRESH volume, so naming this service
  in KIT_POSTGRES_DATABASES and running \`bin/dev up\` will not create anything.
  (And \`bin/dev down -v && bin/dev up\` DOES work, by deleting your data.)

Paste this into the cluster. It is the same provisioning the init script performs,
in the same order, and every statement in it is load-bearing:


  CREATE ROLE "$svc" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
    PASSWORD '$pass';
  CREATE DATABASE "$svc" OWNER "$svc";

  -- the LOGIN role, which owns nothing. A login role that owns its tables can
  -- ALTER TABLE ... DISABLE ROW LEVEL SECURITY and DROP POLICY, so the account
  -- boundary in templates/database/tenancy/ needs this second role to be real.
  -- It exists whether or not this service has adopted those templates, which is
  -- why it is here and not in a migration.
  CREATE ROLE "${svc}_app" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
    PASSWORD '$pass';
  GRANT "${svc}_app" TO "$svc";

  -- the boundary. Without this line EVERY role in the cluster can CONNECT to
  -- $svc, and isolation becomes "nobody happened to grant you SELECT".
  REVOKE ALL ON DATABASE "$svc" FROM PUBLIC;
  GRANT CONNECT, TEMPORARY ON DATABASE "$svc" TO "$svc";
  GRANT CONNECT, TEMPORARY ON DATABASE "$svc" TO "${svc}_app";

  -- blast radius, so this service cannot take the connections the other eight need
  ALTER ROLE "$svc" CONNECTION LIMIT ${KIT_POSTGRES_ROLE_CONNECTIONS:-10};
  ALTER ROLE "$svc" SET statement_timeout = '${KIT_POSTGRES_STATEMENT_TIMEOUT_MS:-15000}';
  ALTER ROLE "$svc" SET idle_in_transaction_session_timeout = '${KIT_POSTGRES_IDLE_IN_TRANSACTION_TIMEOUT_MS:-30000}';
  ALTER ROLE "${svc}_app" SET statement_timeout = '${KIT_POSTGRES_STATEMENT_TIMEOUT_MS:-15000}';
  ALTER ROLE "${svc}_app" SET idle_in_transaction_session_timeout = '${KIT_POSTGRES_IDLE_IN_TRANSACTION_TIMEOUT_MS:-30000}';

Then, in that database:

  psql -h localhost -p $port -U $user -d $svc
  REVOKE CREATE ON SCHEMA public FROM PUBLIC;   -- PG15+; already the default, stated so it is true
SQL

  if [ -n "${KIT_POSTGRES_EXTENSIONS:-}" ]; then
    cat <<SQL

  And in EACH database above, as the admin role — a service role cannot:
  CREATE EXTENSION IF NOT EXISTS ${KIT_POSTGRES_EXTENSIONS%%,*} [ , … per name in KIT_POSTGRES_EXTENSIONS ];
SQL
  fi

  cat <<SQL

  Then add the name to KIT_POSTGRES_DATABASES in your .env, so a FRESH volume
  provisions it without any of this. The statements above are for the volume you
  already have.
SQL
}

print_urls() {
  set -a && . ./.env && set +a

  local pg_port="${KIT_POSTGRES_PORT:-15500}"
  local nats_port="${KIT_NATS_CLIENT_PORT:-15600}"
  local redis_port="${KIT_REDIS_PORT:-15800}"
  local pg_user="${KIT_POSTGRES_USER:-anywaye}"
  local pg_pass="${KIT_POSTGRES_PASSWORD:-anywaye}"
  local pg_db="${KIT_POSTGRES_DB:-anywaye_platform}"

  step "ready"
  cat <<URLS
   postgres     postgresql://$pg_user:$pg_pass@localhost:$pg_port/$pg_db
   nats         nats://localhost:$nats_port
   redis        redis://localhost:$redis_port

   otel (otlp)  http://otel-collector:${KIT_OTEL_HTTP_PORT:-4318}   (compose network only)

   service      ${KIT_DEV_SERVICE_URL:-http://localhost:3000}
URLS

  if [ -n "$KIT_DEV_PROFILES" ]; then
    if [ "$KIT_DEV_PROFILES" = "clickstack" ]; then
      cat <<URLS

   hyperdx      http://localhost:${KIT_CLICKSTACK_PORT:-15910}        (traces, logs, metrics, errors — one pane)
URLS
    else
      cat <<URLS

   grafana      http://localhost:${KIT_GRAFANA_PORT:-15000}        (traces, logs, errors)
   tempo        http://localhost:${KIT_TEMPO_PORT:-15900}
   loki         http://localhost:${KIT_LOKI_PORT:-15901}
URLS
    fi
  else
    cat <<URLS

   (no observability backends: this run started the cheap stack. For grafana,
   tempo and loki:  KIT_DEV_PROFILES=observability bin/dev up.  For the
   single-pane ClickStack view:  KIT_DEV_PROFILES=clickstack bin/dev up)
URLS
  fi

  cat <<URLS

   Nothing leaves this machine unless you point it somewhere. To use your own
   backend instead of the ones above, set <SERVICE>_OTEL_ENDPOINT in your own
   .env — that is the only contract, and the shipped collector is just its
   default value. Unset the variable and the exporter is a genuine no-op: no
   queue, no retry loop, no warning per request, no dial at boot.
URLS
}

status() {
  step "stack status"
  resolve_stack
  compose ps
}

logs() {
  resolve_stack
  if [ "${1:-}" = "" ]; then
    compose logs -f
  else
    compose logs -f "$1"
  fi
}

down() {
  step "stopping the stack (volumes kept)"
  resolve_stack
  local -a pf=()
  while IFS= read -r p; do
    [ -n "$p" ] && pf+=(--profile "$p")
  done < <(compose config --profiles 2>/dev/null || true)
  compose "${pf[@]+"${pf[@]}"}" down
}

nuke() {
  step "stopping the stack and DELETING its volumes"
  resolve_stack
  info "postgres, nats and redis data in this stack are gone after this."
  local -a pf=()
  while IFS= read -r p; do
    [ -n "$p" ] && pf+=(--profile "$p")
  done < <(compose config --profiles 2>/dev/null || true)
  compose "${pf[@]+"${pf[@]}"}" down --volumes --remove-orphans
}


stack_cmd() {
  step "resolving kit"
  resolve_stack
  printf 'resolved: %s\n' "$STACK_DIR"
  printf 'ref: %s\n' "$(stack_ref)"
  printf 'compose files:\n'
  printf '  %s (kit, pinned)\n' "$STACK_DIR/templates/compose/docker-compose.yml"
  [ -f docker-compose.yml ] &&
    printf '  %s (this service — an override, not a fork)\n' "$PWD/docker-compose.yml"
  if [ -f docker-compose.yml ]; then
    step "merged by docker compose"
    compose config 2>&1 | sed 's/^/  /' || true
  else
    info "this service adds no compose file; the pinned stack is the whole thing"
  fi
}


live_cmd() {
  step "resolving kit"
  resolve_stack
  sync_live_stack "$(stack_ref)" "$STACK_DIR"
  local dest
  dest="$(live_dir_for "$(stack_ref)")"
  printf 'resolved: %s\n' "$dest"
  printf 'ref: %s\n' "$(stack_ref)"
}

pin_cmd() {
  local new="${1:-}"
  [ -n "$new" ] || die "bin/dev pin needs a ref:  bin/dev pin v0.4.0   |   bin/dev pin <40-char sha>"
  validate_ref "$new"

  local old
  old="$(stack_ref)"

  if [ "$old" = "$new" ]; then
    step "already pinned to $new"
    info "nothing to do. The stack is unchanged."
    return 0
  fi

  local new_dir old_dir="" old_cache
  new_dir="$(stack_home)/$new"
  old_cache="$(stack_home)/$old"
  if stack_is_usable "$old_cache" "$old"; then
    old_dir="$old_cache"
  elif [ -n "$(stack_setting KIT_STACK_DIR "")" ] && [ -d "$(stack_setting KIT_STACK_DIR "")" ]; then
    old_dir="$(stack_setting KIT_STACK_DIR "")"
  fi

  local offline
  offline="$(stack_setting KIT_STACK_OFFLINE 0)"
  step "what changes between $old and $new"
  if [ -z "$old_dir" ] && [ "$offline" != "1" ]; then
    info "fetching the current ref so the diff is real rather than a claim"
    fetch_stack "$old" "$old_cache" || true
    stack_is_usable "$old_cache" "$old" && old_dir="$old_cache"
  fi
  if [ ! -d "$new_dir" ] && [ "$offline" != "1" ]; then
    fetch_stack "$new" "$new_dir" || true
  fi

  if [ -z "$old_dir" ] || [ ! -d "$new_dir" ]; then
    info "the stack diff could NOT be computed: one of the two refs is not on this"
    info "machine. The pin is still written — refusing to record a move you have"
    info "already decided on is not this command's job — but read what you are"
    info "pinning before you commit it:"
    info "  git -C <a kit checkout> diff --stat $old $new -- templates/compose"
  else
    local changed
    changed="$(diff -rq "$old_dir/templates/compose" "$new_dir/templates/compose" 2>/dev/null || true)"
    if [ -z "$changed" ]; then
      info "the compose stack is IDENTICAL between the two refs."
    else
      info "changed under templates/compose:"
      printf '%s\n' "$changed" | sed 's/^/    /'
    fi
  fi

  step "writing the pin"
  local tmp
  tmp="$REF_FILE.new.$$"
  {
    printf '%s\n' '# The kit ref this repository runs. One line: a 40-character commit'
    printf '%s\n' '# sha, or a v<semver> tag. NEVER a branch.'
    printf '%s\n' '# Move it with:  bin/dev pin <ref>   (it prints the stack diff first)'
    printf '%s\n' "$new"
  } >"$tmp"
  mv "$tmp" "$REF_FILE"
  info "$REF_FILE now pins kit@$new"
  info "Commit it. The stack a repository runs is a reviewed statement, not a"
  info "value that happens to be on this laptop."
  info "Nothing has been started. Run \`bin/dev\` to bring the stack up on the new ref."
}


main() {
  case "${1:-up}" in
    up)
      up
      ;;
    stack) stack_cmd ;;
    live) live_cmd ;;
    pin)
      shift
      pin_cmd "${1:-}"
      ;;
    down) down ;;
    nuke) nuke ;;
    status) status ;;
    logs)
      shift
      logs "${1:-}"
      ;;
    migrate) migrate ;;
    seed) seed ;;
    db)
      shift
      case "${1:-}" in
        grant)
          shift
          db_grant "${1:-}"
          ;;
        *) die "usage: bin/dev db grant <service-name>" ;;
      esac
      ;;
    -h | --help | help) usage ;;
    *)
      printf 'bin/dev: unknown command: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
