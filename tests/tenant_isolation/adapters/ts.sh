#!/usr/bin/env bash
#
# adapters/ts.sh — the THIRD implemented adapter of the cross-tenant harness:
# TypeScript, against `parlor`.
#
# SKELETON. Two of the five functions are still `return 1` with a TODO. It is
# committed deliberately and early: two packets on this repository were lost to
# workers that did the work and committed nothing, and a skeleton that is wired
# but incomplete is worth more than a finished file that was never committed.
#
# This file is the whole of kit's knowledge of TypeScript and of parlor. The
# harness beside it knows about databases, containers and assertions; it does not
# know what `vitest` is, what a drizzle query is, or what an account's tables are
# called. Five functions make up the contract and `adapters/README.md` states it
# in full.
#
# SC2209 is disabled for this whole file, for the reason `go.sh` gives: the
# directive has to sit BEFORE the first command to be file-wide, and
# `TIMEOUT_BIN` is assigned in the harness by `command -v`, so shellcheck cannot
# see from here that it holds a path rather than a string built by a command
# substitution. The adapter inherits the harness's binary rather than
# re-resolving it, because two resolvers is one more place to be wrong.
# shellcheck disable=SC2209

set -uo pipefail

adapter_language_tool() { printf 'node'; }

# Where the probe is copied to INSIDE the service copy, and the name it lands
# under. A directory of its own rather than beside parlor's own sources, because
# the probe calls the query layer from several places and a test file inside a
# module under mutation would mean a mutation's recompile also has to satisfy the
# probe.
PROBE_DIR="kit-probe"
PROBE_SRC_NAME="cross_tenant_probe_test.ts"

# ts_probe — the one environment every vitest run in this adapter gets.
ts_probe() {
  printf 'postgres://postgres:postgres@127.0.0.1:%s/postgres?sslmode=disable' \
    "$KIT_TENANT_PGPORT"
}

# harness_project_name — the container the harness started, derived from the work
# directory it left behind.
#
# `cross_tenant_harness.sh` names its container `kit-tenant-iso-$SESSION` and its
# work directory `kit-tenant-iso.$SESSION`. Nothing outside that file knows the
# session except the recipe that exported it, and the adapter contract names five
# readable variables and the session is not one of them — so the name is read out
# of the one variable the contract does grant. The transformation is CHECKED
# rather than assumed.
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
  [ -f "$src/package.json" ] || {
    printf '  %s has no package.json, so it is not the service this adapter was\n' "$src" >&2
    printf '  written for. Point KIT_SERVICE_REPO at parlor.\n' >&2
    return 1
  }
  rm -rf "$dst"
  mkdir -p "$dst" || return 1
  ( cd "$src" && tar -cf - --exclude='./.git' --exclude='./node_modules' . ) \
    | ( cd "$dst" && tar -xf - ) || return 1
  [ -f "$dst/package.json" ] || {
    printf '  the copy of %s arrived without a package.json.\n' "$src" >&2
    return 1
  }
  return 0
}

adapter_migrate() {
  # TODO: apply parlor's own migrations with parlor's own tool.
  return 1
}

adapter_install_probe() {
  # TODO: copy the negative suite in and prove it was COLLECTED.
  return 1
}

adapter_run() {
  # TODO: run the suite under vitest, print its output, exit with its status.
  return 1
}
