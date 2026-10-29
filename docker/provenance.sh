#!/bin/sh
set -eu

PROG='kit-provenance'

FIELDS='source revision built_at source_dirty template_version'

shape_source() {
  case "$1" in
    unknown) return 0 ;;
    */*) ;;
    *) return 1 ;;
  esac
  case "$1" in
  esac
  printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9._-]*[a-z0-9])?/[a-z0-9]([a-z0-9._-]*[a-z0-9])?$'
}

shape_revision() {
  case "$1" in
    unknown) return 0 ;;
  esac
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

shape_built_at() {
  case "$1" in
    unknown) return 0 ;;
  esac
  printf '%s' "$1" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
}

shape_source_dirty() {
  case "$1" in
    unknown | clean | dirty) return 0 ;;
  esac
  return 1
}

shape_template_version() {
  case "$1" in
    unknown) return 0 ;;
  esac
  printf '%s' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'
}

expect_source() { printf 'owner/repo, or "unknown" (lowercase, exactly one "/", no scheme, no host, no port)'; }
expect_revision() { printf '40 lowercase hex characters, or "unknown"'; }
expect_built_at() { printf 'RFC3339 UTC to the second (YYYY-MM-DDTHH:MM:SSZ), or "unknown"'; }
expect_source_dirty() { printf 'one of clean, dirty, unknown — a FLAG, never a file list'; }
expect_template_version() { printf 'vN.N.N, or "unknown"'; }

field_value() {
  case "$1" in
    source) printf '%s' "${KIT_PROVENANCE_SOURCE:-}" ;;
    revision) printf '%s' "${KIT_PROVENANCE_REVISION:-}" ;;
    built_at) printf '%s' "${KIT_PROVENANCE_BUILT_AT:-}" ;;
    source_dirty) printf '%s' "${KIT_PROVENANCE_SOURCE_DIRTY:-}" ;;
    template_version) printf '%s' "${KIT_PROVENANCE_TEMPLATE_VERSION:-}" ;;
  esac
}

fail_field() {
  printf '%s: refusing to stamp %s=%s\n' "$PROG" "$1" "$2" >&2
  printf '%s:   it must be %s\n' "$PROG" "$(expect_$1)" >&2
  printf '%s:   this value was NOT stamped and NOT truncated. A stamp that lies is worse than no stamp.\n' "$PROG" >&2
  exit 2
}

validate() {
  for f in $FIELDS; do
    v="$(field_value "$f")"
    [ -n "$v" ] || v='unknown'
    "shape_$f" "$v" || fail_field "$f" "$v"
  done
}

emit_args() {
  validate
  for f in $FIELDS; do
    v="$(field_value "$f")"
    [ -n "$v" ] || v='unknown'
    printf -- '--build-arg\nKIT_PROVENANCE_%s=%s\n' "$(_build_arg_suffix "$f")" "$v"
  done
}

_build_arg_suffix() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

write_stamp() {
  out="${1:-/app/kit-provenance.json}"
  validate
  src="$(field_value source)"; [ -n "$src" ] || src='unknown'
  rev="$(field_value revision)"; [ -n "$rev" ] || rev='unknown'
  at="$(field_value built_at)"; [ -n "$at" ] || at='unknown'
  dirty="$(field_value source_dirty)"; [ -n "$dirty" ] || dirty='unknown'
  tv="$(field_value template_version)"; [ -n "$tv" ] || tv='unknown'
  printf '{\n  "source": "%s",\n  "revision": "%s",\n  "built_at": "%s",\n  "source_dirty": "%s",\n  "template_version": "%s"\n}\n' \
    "$src" "$rev" "$at" "$dirty" "$tv" >"$out"
  printf '%s: wrote %s\n' "$PROG" "$out" >&2
}

_verify_got() {
  case "$1" in
    source) printf '%s' "${got_src:-}" ;;
    revision) printf '%s' "${got_rev:-}" ;;
    built_at) printf '%s' "${got_at:-}" ;;
    source_dirty) printf '%s' "${got_dirty:-}" ;;
    template_version) printf '%s' "${got_tv:-}" ;;
  esac
}

emit_verify() {
  image="$1"
  expect_rev="${2:-}"
  expect_src="${3:-}"
  command -v docker >/dev/null 2>&1 || {
    printf '%s: docker is not on PATH, so a pulled image cannot be asked what it is\n' "$PROG" >&2
    exit 3
  }

  labels="$(docker image inspect "$image" --format '{{json .Config.Labels}}' 2>/dev/null || true)"
  if [ -z "$labels" ] || [ "$labels" = 'null' ]; then
    printf '%s: %s carries no labels at all — it was built without the stamp.\n' "$PROG" "$image" >&2
    printf '%s:   (kit: docker/Dockerfile.<lang> declares the ARGs and the LABELs; this image predates it, or was built elsewhere.)\n' "$PROG" >&2
    exit 4
  fi

  got_rev="$(printf '%s' "$labels" | sed -n 's/.*"org\.opencontainers\.image\.revision":"\([^"]*\)".*/\1/p')"
  got_src="$(printf '%s' "$labels" | sed -n 's/.*"org\.opencontainers\.image\.source":"\([^"]*\)".*/\1/p')"
  got_at="$(printf '%s' "$labels" | sed -n 's/.*"org\.opencontainers\.image\.created":"\([^"]*\)".*/\1/p')"
  got_dirty="$(printf '%s' "$labels" | sed -n 's/.*"com\.anywaye\.kit\.source\.dirty":"\([^"]*\)".*/\1/p')"
  got_tv="$(printf '%s' "$labels" | sed -n 's/.*"com\.anywaye\.kit\.template\.version":"\([^"]*\)".*/\1/p')"

  printf 'provenance: %s\n' "$image"
  printf '  source:           %s\n' "${got_src:-<absent>}"
  printf '  revision:         %s\n' "${got_rev:-<absent>}"
  printf '  built_at:         %s\n' "${got_at:-<absent>}"
  printf '  source_dirty:     %s\n' "${got_dirty:-<absent>}"
  printf '  template_version: %s\n' "${got_tv:-<absent>}"

  bad_shape=''
  absent_hard=''
  absent_soft=''
  for f in $FIELDS; do
    v="$(_verify_got "$f")"
    if [ -z "$v" ]; then
      case "$f" in
        source | revision) absent_hard="$absent_hard $f" ;;
        *) absent_soft="$absent_soft $f" ;;
      esac
      continue
    fi
    "shape_$f" "$v" || bad_shape="$bad_shape $f"
  done

  if [ -n "$bad_shape" ] || [ -n "$absent_hard" ]; then
    printf '%s: FAIL %s carries labels, and they are not a anywaye provenance stamp.\n' "$PROG" "$image" >&2
    for f in $bad_shape; do
      printf '%s:   %-16s = "%s" — it must be %s\n' "$PROG" "$f" "$(_verify_got "$f")" "$(expect_$f)" >&2
    done
    for f in $absent_hard; do
      printf '%s:   %-16s is absent, and on --verify an absent identity field is a REFUSAL, not a pass.\n' "$PROG" "$f" >&2
    done
    printf '%s:   org.opencontainers.image.* are STANDARD OCI labels that every base image sets,\n' "$PROG" >&2
    printf '%s:   and an image built FROM a stamped one INHERITS them. This stamp names "%s",\n' "$PROG" "${got_src:-nothing at all}" >&2
    printf '%s:   which is not us. A verifier a third party'"'"'s labels can satisfy is not a verifier.\n' "$PROG" >&2
    return 6
  fi

  if [ -n "$absent_soft" ]; then
    printf '%s: note: %s absent — metadata rather than identity, so an old image is not refused for it.\n' "$PROG" "$absent_soft" >&2
  fi

  if [ -z "$got_dirty" ] && [ -z "$got_tv" ]; then
    printf '%s: FAIL %s carries only org.opencontainers.image.*, so those labels came from the BASE\n' "$PROG" "$image" >&2
    printf '%s:   IMAGE it was built FROM and not from a kit Dockerfile: nothing here set\n' "$PROG" >&2
    printf '%s:   com.anywaye.kit.*, and that namespace is the one part of a stamp a third-party\n' "$PROG" >&2
    printf '%s:   base image cannot supply by accident.\n' "$PROG" >&2
    printf '%s:   source reads "%s" — whoever built that base image, it is not us.\n' "$PROG" "${got_src:-<absent>}" >&2
    printf '%s:   Pass --expect-source owner/repo to assert the repository as well.\n' "$PROG" >&2
    return 6
  fi

  if [ -n "$expect_src" ]; then
    if [ -z "$got_src" ] || [ "$got_src" = 'unknown' ]; then
      printf '%s: FAIL %s is stamped "%s" for source and %s was expected — an image that cannot name itself cannot be asserted about.\n' \
        "$PROG" "$image" "${got_src:-<absent>}" "$expect_src" >&2
      return 5
    fi
    if [ "$got_src" != "$expect_src" ]; then
      printf '%s: FAIL %s is built from %s, and %s was expected.\n' "$PROG" "$image" "$got_src" "$expect_src" >&2
      printf '%s:   a stamp that satisfies the grammar is not a stamp that is OURS. %s is a\n' "$PROG" "$got_src" >&2
      printf '%s:   well-formed and entirely foreign, which is the case shape cannot see.\n' "$PROG" >&2
      return 5
    fi
  else
    printf '%s: WARN no --expect-source was given, so OWNERSHIP OF THE REPOSITORY WAS NOT ESTABLISHED.\n' "$PROG" >&2
    printf '%s:      the source reads "%s", and every grammar in this file accepts it. Only\n' "$PROG" "$got_src" >&2
    printf '%s:      --expect-source owner/repo turns "it is shaped like ours" into "it IS ours".\n' "$PROG" >&2
  fi

  [ -n "$expect_rev" ] || return 0

  if [ "${got_rev:-}" = 'unknown' ] || [ -z "${got_rev:-}" ]; then
    printf '%s: FAIL %s is stamped "unknown" and %s was expected — an artifact that cannot name itself cannot be asserted about.\n' \
      "$PROG" "$image" "$expect_rev" >&2
    return 5
  fi
  if [ "${got_rev:-}" != "$expect_rev" ]; then
    printf '%s: FAIL %s is commit %s, and %s was expected.\n' "$PROG" "$image" "${got_rev:-<absent>}" "$expect_rev" >&2
    printf '%s:   the tag is a mutable name. This is the disagreement the stamp exists to make visible.\n' "$PROG" >&2
    return 5
  fi
  printf '%s: ok %s is %s\n' "$PROG" "$image" "$expect_rev"
  return 0
}


cmd="${1:---validate}"
shift 2>/dev/null || true
case "$cmd" in
  --validate) validate ;;
  --args) emit_args ;;
  --write) write_stamp "${1:-/app/kit-provenance.json}" ;;
  --verify)
    shift 0 2>/dev/null || true
    v_image=''
    v_expect=''
    v_expect_src=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --expect-revision)
          [ "$#" -ge 2 ] || { printf '%s: --expect-revision needs a value\n' "$PROG" >&2; exit 64; }
          v_expect="$2"
          shift 2
          ;;
        --expect-revision=*) v_expect="${1#*=}"; shift ;;
        --expect-source)
          [ "$#" -ge 2 ] || { printf '%s: --expect-source needs a value\n' "$PROG" >&2; exit 64; }
          v_expect_src="$2"
          shift 2
          ;;
        --expect-source=*) v_expect_src="${1#*=}"; shift ;;
        -*) printf '%s: unknown flag %s\n' "$PROG" "$1" >&2; exit 64 ;;
        *)
          [ -z "$v_image" ] || { printf '%s: --verify takes one image reference\n' "$PROG" >&2; exit 64; }
          v_image="$1"
          shift
          ;;
      esac
    done
    [ -n "$v_image" ] || { printf '%s: --verify needs an image reference\n' "$PROG" >&2; exit 64; }
    if [ -n "$v_expect_src" ]; then
      _es="$v_expect_src"
      case "$_es" in
        unknown) ;;
        *)
          if ! shape_source "$_es"; then
            printf '%s: refusing to ASSERT source=%s\n' "$PROG" "$_es" >&2
            printf '%s:   --expect-source must be %s\n' "$PROG" "$(expect_source)" >&2
            exit 2
          fi
          ;;
      esac
    fi
    emit_verify "$v_image" "$v_expect" "$v_expect_src"
    ;;
  --fields) printf '%s\n' $FIELDS ;;
  -h | --help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    printf '%s: unknown subcommand %s (want --validate, --args, --write FILE, --verify IMAGE, --fields)\n' "$PROG" "$cmd" >&2
    exit 64
    ;;
esac