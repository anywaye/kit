#!/usr/bin/env bash


set -uo pipefail

adapter_language_tool() { printf 'mix'; }

adapter_prepare() {
  local src="$KIT_TENANT_SERVICE" dst="$KIT_TENANT_WORK/service"
  [ -d "$src/deps" ] || {
    printf '  %s has no deps/ directory. The harness does not fetch them: a check that\n' "$src" >&2
    printf '  reached the network would answer differently on a laptop and on CI.\n' >&2
    return 1
  }
  rm -rf "$dst"
  mkdir -p "$dst"
  cp -R "$src/lib" "$src/priv" "$src/config" "$src/test" "$dst/" || return 1
  cp "$src/mix.exs" "$src/mix.lock" "$dst/" || return 1
  [ -f "$src/.formatter.exs" ] && cp "$src/.formatter.exs" "$dst/"
  ln -s "$src/deps" "$dst/deps"

  ( cd "$dst" && MIX_ENV=test "$TIMEOUT_BIN" 900 mix compile ) >"$KIT_TENANT_WORK/compile.log" 2>&1 || {
    printf '  mix compile failed; tail of the log:\n' >&2
    tail -20 "$KIT_TENANT_WORK/compile.log" | sed 's/^/  /' >&2
    return 1
  }
  return 0
}

adapter_migrate() {
  local dst="$KIT_TENANT_WORK/service"
  (
    cd "$dst" &&
      MIX_ENV=test COURIER_TEST_PG_PORT="$KIT_TENANT_PGPORT" \
        "$TIMEOUT_BIN" 300 mix ecto.create &&
      MIX_ENV=test COURIER_TEST_PG_PORT="$KIT_TENANT_PGPORT" \
        "$TIMEOUT_BIN" 300 mix ecto.migrate
  ) >"$KIT_TENANT_WORK/migrate.log" 2>&1 || {
    printf '  the service migrations failed; tail of the log:\n' >&2
    tail -25 "$KIT_TENANT_WORK/migrate.log" | sed 's/^/  /' >&2
    return 1
  }
  return 0
}

adapter_install_probe() {
  local probe="$KIT_TENANT_ADAPTER_DIR/elixir/cross_tenant_probe_test.exs"
  [ -r "$probe" ] || {
    printf '  the negative suite is missing at %s\n' "$probe" >&2
    return 1
  }
  cp "$probe" "$KIT_TENANT_WORK/service/test/courier/kit_tenant_isolation_probe_test.exs" || return 1
  adapter_run '__collect_probe__'
}

adapter_run() {
  local needle="${1:-}" dst="$KIT_TENANT_WORK/service"
  if [ "$needle" = "__collect_probe__" ]; then
    if ! (
      cd "$dst" && MIX_ENV=test COURIER_TEST_PG_PORT="$KIT_TENANT_PGPORT" \
        "$TIMEOUT_BIN" 300 mix test test/courier/kit_tenant_isolation_probe_test.exs
    ) >"$KIT_TENANT_WORK/probe.log" 2>&1; then
      printf '  the negative suite does not run against the unmodified service:\n' >&2
      tail -40 "$KIT_TENANT_WORK/probe.log" | sed 's/^/  /' >&2
      return 1
    fi
    cat "$KIT_TENANT_WORK/probe.log"
    return 0
  fi

  (
    cd "$dst" && MIX_ENV=test COURIER_TEST_PG_PORT="$KIT_TENANT_PGPORT" \
      "$TIMEOUT_BIN" 300 mix test test/courier/kit_tenant_isolation_probe_test.exs
  ) 2>&1
  return $?
}