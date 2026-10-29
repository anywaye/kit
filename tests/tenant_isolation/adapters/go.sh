#!/usr/bin/env bash

set -uo pipefail

adapter_language_tool() { printf 'go'; }

PROBE_PKG_DIR="internal/kitprobe"
PROBE_SRC_NAME="cross_tenant_probe_test.go"

go_probe() {
  printf 'postgres://postgres:postgres@127.0.0.1:%s/postgres?sslmode=disable' \
    "$KIT_TENANT_PGPORT"
}

harness_project_name() {
  local base="${KIT_TENANT_WORK##*/}"
  case "$base" in
    kit-tenant-iso.*)
      [ -n "${base#kit-tenant-iso.}" ] || return 1
      printf 'kit-tenant-iso-%s' "${base#kit-tenant-iso.}"
      ;;
    *)
      return 1
      ;;
  esac
}

adapter_prepare() {
  local src="$KIT_TENANT_SERVICE" dst="$KIT_TENANT_WORK/service"
  [ -f "$src/go.mod" ] || {
    printf '  %s has no go.mod, so it is not the Go service this adapter was written\n' "$src" >&2
    printf '  for. Point KIT_SERVICE_REPO at identity.\n' >&2
    return 1
  }
  rm -rf "$dst"
  mkdir -p "$dst" || return 1
  ( cd "$src" && tar -cf - --exclude='./.git' . ) | ( cd "$dst" && tar -xf - ) || return 1
  [ -f "$dst/go.mod" ] || {
    printf '  the copy of %s arrived without a go.mod.\n' "$src" >&2
    return 1
  }

  ( cd "$dst" && "$TIMEOUT_BIN" 600 go build ./... ) >"$KIT_TENANT_WORK/build.log" 2>&1 || {
    printf '  go build failed; tail of the log:\n' >&2
    tail -20 "$KIT_TENANT_WORK/build.log" | sed 's/^/  /' >&2
    return 1
  }
  return 0
}

adapter_migrate() {
  local dst="$KIT_TENANT_WORK/service"

  local project
  project="$(harness_project_name)" || {
    printf '  cannot derive the harness container name from KIT_TENANT_WORK=%s.\n' \
      "$KIT_TENANT_WORK" >&2
    return 1
  }

  if ! "$TIMEOUT_BIN" 60 docker exec "$project" psql -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -q \
    -c "do \$\$ begin
            if not exists (select 1 from pg_roles
                             where rolname = current_user || '_app' and rolcanlogin) then
              execute format('create role %I login', current_user || '_app');
            end if;
          end \$\$;" >"$KIT_TENANT_WORK/role.log" 2>&1; then
    printf '  the login role anywaye.protect_table needs could not be provisioned:\n' >&2
    sed 's/^/  /' "$KIT_TENANT_WORK/role.log" >&2
    return 1
  fi

  (
    cd "$dst" &&
      "$TIMEOUT_BIN" 300 goose -dir migrations postgres "$(go_probe)" up
  ) >"$KIT_TENANT_WORK/migrate.log" 2>&1 || {
    printf '  identity'"'"'s own migrations failed; tail of the log:\n' >&2
    tail -25 "$KIT_TENANT_WORK/migrate.log" | sed 's/^/  /' >&2
    return 1
  }
  return 0
}

adapter_install_probe() {
  local probe="$KIT_TENANT_ADAPTER_DIR/go/$PROBE_SRC_NAME"
  local dst="$KIT_TENANT_WORK/service/$PROBE_PKG_DIR"
  [ -r "$probe" ] || {
    printf '  the negative suite is missing at %s\n' "$probe" >&2
    return 1
  }
  mkdir -p "$dst" || return 1
  cp "$probe" "$dst/$PROBE_SRC_NAME" || return 1
  adapter_run '__collect_probe__'
}

adapter_run() {
  local needle="${1:-}" dst="$KIT_TENANT_WORK/service"

  if [ "$needle" = "__collect_probe__" ]; then
    local listed
    if ! listed="$( cd "$dst" && TEST_DATABASE_URL="$(go_probe)" \
        "$TIMEOUT_BIN" 300 go test -list '.' "./$PROBE_PKG_DIR/" 2>&1 )"; then
      printf '  go test -list could not enumerate the probe. It does not compile, or\n' >&2
      printf '  the package is not where it was copied. Full output:\n' >&2
      printf '%s\n' "$listed" | tail -25 | sed 's/^/  /' >&2
      return 1
    fi
    local n
    n="$(printf '%s\n' "$listed" | grep -c -E '^Test' || true)"
    if [ "${n:-0}" -lt 1 ]; then
      printf '  the negative suite was NOT COLLECTED. `go test -list` returned:\n' >&2
      printf '%s\n' "$listed" | sed 's/^/  /' >&2
      printf '  A probe that was never collected reports 0 failures and every breakage\n' >&2
      printf '  looks green. Refusing to continue.\n' >&2
      return 1
    fi
    printf '%s\n' "$listed"
    printf 'collected %s test(s) in %s\n' "$n" "$PROBE_PKG_DIR"
    return 0
  fi

  local filter='.'
  [ "$needle" != "__all__" ] && filter="$needle"
  [ -n "$needle" ] || filter='.'

  local out code
  out="$(
    cd "$dst" && TEST_DATABASE_URL="$(go_probe)" \
      "$TIMEOUT_BIN" 600 go test -count=1 -v -run "$filter" "./$PROBE_PKG_DIR/" 2>&1
  )"
  code=$?
  printf '%s\n' "$out"

  local ran
  ran="$(printf '%s\n' "$out" | grep -c -E '^=== RUN' || true)"
  if [ "${ran:-0}" -lt 1 ]; then
    printf 'adapter_run: THE RUN MEASURED NOTHING. `go test -run %s` started 0 tests and\n' \
      "$filter" >&2
    printf '  still exited %s, which is the vacuous green this harness exists to\n' "$code" >&2
    printf '  remove. Refusing to report it as a pass.\n' >&2
    return 1
  fi
  printf 'ran %s test(s)\n' "$ran" >&2
  return "$code"
}