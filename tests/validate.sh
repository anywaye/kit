#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/kit-validate.XXXXXX")"
trap 'kit_phase "END OF RUN (no section header after this point)"; kit_total; rm -rf "$TMP"' EXIT

WORKFLOW='ci/ci.reusable.yml'




CONFIG_ONLY='none'

RUN_STATIC=1
RUN_OBSERVABILITY=1
RUN_LINT=1
RUN_LIVE=1
LANGS=()

ONLY_MATCH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --static-only)
      RUN_OBSERVABILITY=0
      RUN_LINT=0
      ;;
    --no-observability) RUN_OBSERVABILITY=0 ;;
    --no-live) RUN_LIVE=0 ;;
    --no-lint) RUN_LINT=0 ;;
    --language=*)
      LANGS+=("${1#*=}")
      ;;
    --only=*)
      ONLY_MATCH="${1#*=}"
      ;;
    -h | --help)
      sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d'
      rm -rf "$TMP"
      trap - EXIT
      exit 0
      ;;
    *)
      echo "validate.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

_PROFILE="${KIT_PROFILE:-}"
_pf_tag="${KIT_PROFILE_TAG:-}"

if [ -n "$_PROFILE" ]; then
  _pf_now() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
else
  _pf_now() { printf '0'; }
fi

kit_profile() {
  [ -n "$_PROFILE" ] || return 0
  local ms=$(( $(_pf_now) - $3 ))
  [ "$ms" -lt 0 ] && ms=0
  printf '%s\t%s\t%d.%03d\t%s\n' "$1" \
    "$(printf '%s' "$2" | tr '\t' ' ')" \
    "$((ms / 1000))" "$((ms % 1000))" "$_pf_tag" >>"$_PROFILE"
}

_pf_last=0
if [ -n "$_PROFILE" ]; then
  _pf_last="$(_pf_now)"
fi
_pf_start="$_pf_last"
_pf_region_base=0
_pf_mark=0
_pf_kind=check

kit_phase() {
  [ -n "$_PROFILE" ] || return 0
  local now prev
  prev="$_pf_last"
  now="$(_pf_now)"
  local ms=$((now - prev))
  [ "$ms" -lt 0 ] && ms=0
  printf 'phase\t%s\t%d.%03d\t%s\n' "$1" "$((ms / 1000))" "$((ms % 1000))" "$_pf_tag" >>"$_PROFILE"
  _pf_last="$now"
}

kit_total() {
  [ -n "$_PROFILE" ] || return 0
  local now ms
  now="$(_pf_now)"
  ms=$((now - _pf_start))
  [ "$ms" -lt 0 ] && ms=0
  printf 'total\tFULL RUN (first line of the script to the exit trap)\t%d.%03d\t%s\n' \
    "$((ms / 1000))" "$((ms % 1000))" "$_pf_tag" >>"$_PROFILE"
}

if [ ! -r "$ROOT/tests/bootstrap.sh" ]; then
  echo "validate.sh: tests/bootstrap.sh is missing — the gate cannot install its own dependencies" >&2
  exit 1
fi
. "$ROOT/tests/bootstrap.sh"
kit_activate_mise
kit_bootstrap_python "$ROOT"
export KIT_PYTHON="$PY"

kit_phase "00 bootstrap: resolve the interpreter and install deps"


yaml_ok() {
  "$PY" - "$1" <<'PY'
import sys

import yaml

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        list(yaml.safe_load_all(fh))
except Exception as exc:
    sys.exit(f"yaml: {exc}")
PY
}

fails=0
skips=0

report() {
  if [ -n "$_PROFILE" ] && [ "$_pf_mark" != 0 ]; then
    kit_profile "$_pf_kind" "$2" "$_pf_mark"
    _pf_mark="$(_pf_now)"
  fi
  printf '%-4s %s\n' "$1" "$2"
  case "$1" in
    FAIL) fails=$((fails + 1)) ;;
    SKIP) skips=$((skips + 1)) ;;
  esac
}

SKIP_EXIT=78

  local label="$1" out status
  shift
  if [ -n "$ONLY_MATCH" ]; then
    case "$label" in
      *"$ONLY_MATCH"*)
        ONLY_RAN=$((ONLY_RAN + 1))
        ;;
      *)
        ONLY_SKIPPED=$((ONLY_SKIPPED + 1))
        return 0
        ;;
    esac
  fi
  _t0=0
  [ -n "$_PROFILE" ] && _t0="$(_pf_now)"
  _pf_mark="$_t0"
  _pf_kind=check
  if out="$("$@" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -eq 0 ]; then
    report PASS "$label"
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | sed 's/^/       /'
    fi
  elif [ "$status" -eq "$SKIP_EXIT" ]; then
    report SKIP "$label"
    [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/       /'
  else
    report FAIL "$label"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

  local label="$1" proof="$2" out ec=0
  shift 2
  _t0=0
  [ -n "$_PROFILE" ] && _t0="$(_pf_now)"
  _pf_mark="$_t0"
  _pf_kind=check
  out="$("$@" 2>&1)" || ec=$?
  if [ "$ec" -eq 0 ]; then
    report PASS "$label"
    printf '%s\n' "$out" | grep -E "$proof" | sed 's/^/       /' || true
  else
    report FAIL "$label"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

section() {
  kit_phase "$1"
  printf '\n-- %s\n' "$1"
}

only_wanted() {
  [ -z "$ONLY_MATCH" ] && return 0
  case "$1" in
    *"$ONLY_MATCH"*)
      ONLY_RAN=$((ONLY_RAN + 1))
      return 0
      ;;
    *)
      ONLY_SKIPPED=$((ONLY_SKIPPED + 1))
      return 1
      ;;
  esac
}

par_n="${KIT_PARALLEL_CHECKS:-0}"
if [ "$par_n" -eq 0 ] 2>/dev/null; then
  par_n="$( (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4) )"
  [ "$par_n" -gt 4 ] && par_n=4
fi
case "$par_n" in
  '' | *[!0-9]*) par_n=4 ;;
esac
par_dir="$TMP/parallel"
mkdir -p "$par_dir"
par_count=0

check_par() {
  local label="$1"
  shift
  if [ -n "$ONLY_MATCH" ]; then
    case "$label" in
      *"$ONLY_MATCH"*) ONLY_RAN=$((ONLY_RAN + 1)) ;;
      *)
        ONLY_SKIPPED=$((ONLY_SKIPPED + 1))
        return 0
        ;;
    esac
  fi
  par_count=$((par_count + 1))
  local slot="$par_dir/$par_count"
  printf '%s\n' "$label" >"$slot.label"
  ( set +e
    _t0=0; [ -n "$_PROFILE" ] && _t0="$(_pf_now)"
    "$@" >"$slot.out" 2>&1; _ec=$?
    kit_profile cpu "$label" "$_t0"
    printf '%s\n' "$_ec" >"$slot.status" ) &
  par_pids="$par_pids $!"
  par_slots="$par_slots $slot"
  par_running=$((par_running + 1))
  if [ "$par_running" -ge "$par_n" ]; then
    par_reap
  fi
}

par_reap() {
  [ -n "$par_pids" ] || return 0
  set -- $par_pids
  wait "$1" 2>/dev/null || true
  shift
  par_pids="$*"
  par_running=$((par_running - 1))
  return 0
}

report_par() {
  local verdict="$1" label="$2"
  if [ -n "$ONLY_MATCH" ]; then
    case "$label" in
      *"$ONLY_MATCH"*) ONLY_RAN=$((ONLY_RAN + 1)) ;;
      *)
        ONLY_SKIPPED=$((ONLY_SKIPPED + 1))
        return 0
        ;;
    esac
  fi
  par_count=$((par_count + 1))
  local slot="$par_dir/$par_count"
  printf '%s\n' "$label" >"$slot.label"
  case "$verdict" in
    PASS) printf '0\n' >"$slot.status" ;;
    SKIP) printf '%s\n' "$SKIP_EXIT" >"$slot.status" ;;
    *) printf '1\n' >"$slot.status" ;;
  esac
  : >"$slot.out"
  _t0=0
  [ -n "$_PROFILE" ] && _t0="$(_pf_now)"
  kit_profile verdict "$label" "$_t0"
}

par_flush() {
  while [ -n "$par_pids" ]; do
    par_reap
  done
  [ -n "$_PROFILE" ] && _pf_mark=0
  local i=1 label status out
  while [ "$i" -le "$par_count" ]; do
    local slot="$par_dir/$i"
    label="$(cat "$slot.label" 2>/dev/null || printf '')"
    if [ ! -f "$slot.status" ]; then
      report FAIL "$label"
      printf '       the check did not report a status; it was killed rather than finished\n'
      i=$((i + 1))
      continue
    fi
    status="$(cat "$slot.status")"
    out="$(cat "$slot.out" 2>/dev/null || printf '')"
    case "$status" in
      '' | *[!0-9]*)
        report FAIL "$label"
        printf '       the check did not finish writing a status; it was killed rather than finished\n'
        i=$((i + 1))
        continue
        ;;
    esac
    if [ "$status" -eq 0 ]; then
      report PASS "$label"
      [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/       /'
    elif [ "$status" -eq "$SKIP_EXIT" ]; then
      report SKIP "$label"
      [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/       /'
    else
      report FAIL "$label"
      printf '%s\n' "$out" | sed 's/^/       /'
    fi
    i=$((i + 1))
  done
  if [ -n "$_PROFILE" ] && [ "$_pf_region_base" -ne 0 ]; then
    kit_profile par "par region: $par_count check(s) — wall clock; the cpu rows overlap inside it" "$_pf_region_base"
    _pf_last="$(_pf_now)"
  fi
  _pf_region_base=0
  par_count=0
  par_pids=""
  par_slots=""
  par_running=0
}

par_begin() {
  par_pids=""
  par_slots=""
  par_running=0
  par_count=0
  rm -f "$par_dir"/*.label "$par_dir"/*.out "$par_dir"/*.status 2>/dev/null || true
  _pf_region_base="$_pf_last"
}

par_pids=""
par_slots=""
par_running=0

_kit_probe_for() {
  case "$1" in
    go) printf '%s' 'version' ;;
    gofmt) printf '%s' '-h' ;;
    *)      printf '%s' '--version' ;;
  esac
}

_kit_have_cache=""
have() {
  local cmd="$1" cached runner probe
  case "$_kit_have_cache" in
    *"|$cmd="*) cached="${_kit_have_cache#*"|$cmd="}"; cached="${cached%%|*}"
      [ "$cached" = yes ] && return 0 || return 1 ;;
  esac
  runner="$(_timeout_bin 2>/dev/null || printf '')"
  probe="$(_kit_probe_for "$cmd")"
  if command -v "$cmd" >/dev/null 2>&1; then
    if [ -n "$runner" ]; then
      "$runner" 30 "$cmd" "$probe" >/dev/null 2>&1 && cached=yes || cached=no
    else
      "$cmd" "$probe" >/dev/null 2>&1 && cached=yes || cached=no
    fi
  else
    cached=no
  fi
  _kit_have_cache="${_kit_have_cache}|${cmd}=${cached}|"
  [ "$cached" = yes ]
}

conflict_markers_absent() {
  local hits
  hits="$(git -C "$ROOT" grep -I -n -E '^<{7} |^>{7} |^\|{7} ' -- . 2>/dev/null)" || true
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
    printf 'these lines are merge residue, not content; resolve and commit\n'
    return 1
  fi
  return 0
}

ruby_floor() {
  ruby -e 'require ARGV[0]; print KitOtel::RUBY_FLOOR' \
    "$ROOT/templates/otel/ruby/traceparent.rb" 2>/dev/null
}

version_at_least() {
  local have_v="$1" want_v="$2" i a b
  for i in 1 2 3; do
    a="$(printf '%s' "$have_v" | cut -d. -f"$i")"; a="${a:-0}"
    b="$(printf '%s' "$want_v" | cut -d. -f"$i")"; b="${b:-0}"
    case "$a$b" in
      '' | *[!0-9]*) return 1 ;;
    esac
    if [ "$a" -eq "$b" ]; then
      continue
    fi
    if [ "$a" -gt "$b" ]; then
      return 0
    fi
    return 1
  done
  return 0
}

_KF_ENABLED=1
case "${KIT_FINGERPRINT:-on}" in
  0|off|no|false) _KF_ENABLED=0 ;;
esac

_kf_dir() {
  if [ -n "${KIT_CACHE_DIR:-}" ]; then
    printf '%s' "$KIT_CACHE_DIR"
  else
    printf '%s/.kit/cache/gate' "$ROOT"
  fi
}

_kf_id() {
  printf '%s' "${1%% *}"
}

KIT_CACHE_LAST_EXIT=""
KIT_CACHE_LAST_OUT=""

  local label="$1" bound="$2" inputs="$3" outputs="$4"
  shift 4
  [ "$_KF_ENABLED" -eq 1 ] || { bounded_check "$label" "$bound" "$@"; return $?; }

  if [ -n "$ONLY_MATCH" ]; then
    case "$label" in
      *"$ONLY_MATCH"*) ONLY_RAN=$((ONLY_RAN + 1)) ;;
      *)
        ONLY_SKIPPED=$((ONLY_SKIPPED + 1))
        return 0
        ;;
    esac
  fi

  local id cdir man tmpout
  id="$(_kf_id "$label")"
  cdir="$(_kf_dir)"
  man="$cdir/manifests/$(printf '%s' "$id" | tr '/ ' '__').json"
  mkdir -p "$cdir/manifests" 2>/dev/null || true

  if ! "$PY" "$ROOT/tests/fingerprint.py" --root "$ROOT" --cache-dir "$cdir" manifest \
        --check "$id" --inputs "$inputs" --outputs "$outputs" \
        --command "$*" --out "$man" 2>"$cdir/manifest.err"; then
    printf '       note: the fingerprint declaration for %s did not build, so this\n' "$id"
    printf '       tier ran uncached. The declaration is:\n'
    sed 's/^/         /' "$cdir/manifest.err"
    bounded_check "$label" "$bound" "$@"
    return $?
  fi

  if "$PY" "$ROOT/tests/fingerprint.py" --root "$ROOT" --cache-dir "$cdir" \
        lookup --manifest "$man" >"$cdir/replay.txt" 2>"$cdir/lookup.err"; then
    bounded_ran=$((bounded_ran + 1))
    report PASS "$label"
    printf '       (skipped: the fingerprint is unchanged and the declared outputs are\n'
    printf '        still on disk — %s)\n' "$(_kf_id "$label")"
    if [ -s "$cdir/replay.txt" ]; then
      sed 's/^/       /' "$cdir/replay.txt"
    fi
    return 0
  fi

  [ -s "$cdir/lookup.err" ] || true
  bounded_check "$label" "$bound" "$@"
  local ec=$?
  ec="$KIT_CACHE_LAST_EXIT"

  tmpout="$cdir/manifests/$(printf '%s' "$id" | tr '/ ' '__').out"
  printf '%s' "$KIT_CACHE_LAST_OUT" >"$tmpout"
  "$PY" "$ROOT/tests/fingerprint.py" --root "$ROOT" --cache-dir "$cdir" record \
    --manifest "$man" --exit "$ec" --stdout-file "$tmpout" 2>/dev/null || true
  rm -f "$tmpout"
  return 0
}
bounded_ran=0
ONLY_SKIPPED=0
ONLY_RAN=0
bounded_hit=0
_timeout_bin() {
  for candidate in timeout gtimeout; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

bounded_check() {
  local label="$1" bound="$2"
  shift 2
  local runner out ec=0
  if [ -n "$ONLY_MATCH" ]; then
    case "$label" in
      *"$ONLY_MATCH"*)
        ONLY_RAN=$((ONLY_RAN + 1))
        ;;
      *)
        ONLY_SKIPPED=$((ONLY_SKIPPED + 1))
        return 0
        ;;
    esac
  fi
  if runner="$(_timeout_bin)"; then
    bounded_ran=$((bounded_ran + 1))
    _t0=0; [ -n "$_PROFILE" ] && _t0="$(_pf_now)"
    _pf_mark="$_t0"
    _pf_kind=tier
    out="$("$runner" --kill-after=30s "$bound" "$@" 2>&1)" || ec=$?
  else
    _t0=0; [ -n "$_PROFILE" ] && _t0="$(_pf_now)"
    _pf_mark="$_t0"
    _pf_kind=tier
    out="$("$@" 2>&1)" || ec=$?
  fi
  KIT_CACHE_LAST_EXIT="$ec"
  KIT_CACHE_LAST_OUT="$out"
  if [ "$ec" -eq 0 ]; then
    report PASS "$label"
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | sed 's/^/       /'
    fi
  elif [ "$ec" -eq 124 ]; then
    bounded_hit=$((bounded_hit + 1))
    if [ -n "$_PROFILE" ] && [ "$_pf_mark" != 0 ]; then
      kit_profile tier "$label" "$_pf_mark"
      _pf_mark="$(_pf_now)"
    fi
    printf '%-4s %s\n' BOUND "$label"
    printf '       exceeded its %ss bound on this machine. The tier did not finish, so\n' "$bound"
    printf '       the claim it exists to prove is UNEXERCISED — this is not a defect in\n'
    printf '       the tree, and it is not a pass. Re-run on a quieter box; every tier is\n'
    printf '       bounded, so a run that reaches the end has exercised all of them.\n'
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | tail -12 | sed 's/^/       /'
    fi
  else
    report FAIL "$label"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

live_check() {
  local label="$1" bound="$2"
  shift 2
  if [ "$RUN_LIVE" -eq 1 ]; then
    bounded_check "$label" "$bound" "$@"
    return $?
  fi
  if [ -n "$ONLY_MATCH" ]; then
    case "$label" in
      *"$ONLY_MATCH"*) ONLY_RAN=$((ONLY_RAN + 1)) ;;
      *)
        ONLY_SKIPPED=$((ONLY_SKIPPED + 1))
        return 0
        ;;
    esac
  fi
  KIT_CACHE_LAST_EXIT="$SKIP_EXIT"
  KIT_CACHE_LAST_OUT="$label  (not run: --no-live)"
  report SKIP "$label  (NOT RUN — --no-live: the observability live tier was opted out and this claim is UNEXERCISED)"
}

kit_phase "10 static: every artifact parses, and the strictness decisions hold"

if [ "$RUN_STATIC" -eq 1 ]; then
  erb_yaml_ok() {
    local f="$1" rendered
    have ruby || return 78
    if ! rendered="$(KIT_SERVICE=kitprobe KIT_REGISTRY_ORG=kitprobe \
      KIT_REPO=kitprobe KIT_WEB_HOST=198.51.100.7 \
      KIT_APP_DOMAIN=kitprobe.invalid \
      ruby -rerb -e '
        puts ERB.new(File.read(ARGV[0]), trim_mode: "-").result
      ' "$f" 2>&1)"; then
      printf '%s\n' "$rendered" >&2
      return 1
    fi
    printf '%s' "$rendered" | "$PY" -c 'import sys, yaml; yaml.safe_load(sys.stdin.read())'
  }

  docker_rules() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
docker_dir = os.path.join(root, "docker")

problems = []
for name in sorted(os.listdir(docker_dir)):
    if not name.startswith("Dockerfile."):
        continue
    rel = f"docker/{name}"
    body = open(os.path.join(docker_dir, name), encoding="utf-8").read()
    lines = body.splitlines()

    last_from = max(
        (i for i, ln in enumerate(lines) if re.match(r"^\s*FROM\s", ln, re.I)),
        default=None,
    )
    if last_from is None:
        problems.append(f"{rel}: no FROM — nothing to run")
        continue

    final_stage = lines[last_from:]
    users = [
        ln.strip()[len("USER "):].strip()
        for ln in final_stage
        if re.match(r"^\s*USER\s+\S", ln, re.I)
    ]
    if not users:
        problems.append(
            f"{rel}: the final stage sets no USER, so it runs as root — "
            f"a container running as root is a container where a bug is a host "
            f"compromise"
        )
    elif any(u.split(":")[0] in ("root", "0", "0:0") for u in users):
        problems.append(f"{rel}: the final stage's USER is root ({users[-1]})")

    for i, ln in enumerate(lines, 1):
        m = re.match(r"^\s*FROM\s+(\S+)(.*)$", ln, re.I)
        if not m:
            continue
        image, rest = m.group(1), m.group(2)
        tail = re.split(r"[ \t]", rest.strip())[0] if rest.strip() else ""
        if not tail and ":" not in image:
            problems.append(f"{rel}:{i}: FROM {image} has no tag; an untagged base is a moving target")
        if tail in ("latest",) or image.rsplit(":", 1)[-1] == "latest":
            problems.append(f"{rel}:{i}: FROM {image} is :latest")

    for i, ln in enumerate(lines, 1):
        if re.match(r"^\s*ADD\s", ln, re.I):
            problems.append(f"{rel}:{i}: ADD — use COPY, which cannot fetch a URL")

if problems:
    sys.exit("; ".join(problems))
PY
  }

  docker_entrypoint() {
    "$PY" - "$ROOT" <<'PY'
import json
import os
import re
import sys

root = sys.argv[1]
docker_dir = os.path.join(root, "docker")
script = os.path.join(docker_dir, "entrypoint.sh")

problems = []
if not os.path.isfile(script):
    problems.append(
        "docker/entrypoint.sh is missing, and every Dockerfile's ENTRYPOINT "
        "names it — which means all seven images exec a file that is not there"
    )

for name in sorted(os.listdir(docker_dir)):
    if not name.startswith("Dockerfile."):
        continue
    rel = f"docker/{name}"
    body = open(os.path.join(docker_dir, name), encoding="utf-8").read()

    entrypoints = re.findall(r"^\s*ENTRYPOINT\s+(.+)$", body, re.I | re.M)
    if not entrypoints:
        problems.append(f"{rel}: no ENTRYPOINT at all")
        continue
    raw = entrypoints[-1].strip()
    if not raw.startswith("["):
        problems.append(
            f"{rel}: the final ENTRYPOINT is shell form ({raw!r}); kit's exec "
            f"contract is exec-form, because a shell form adds a shell that "
            f"does not forward SIGTERM"
        )
        continue
    try:
        argv = json.loads(raw)
    except ValueError as exc:
        problems.append(f"{rel}: the final ENTRYPOINT is not a JSON array ({exc})")
        continue

    at = next(
        (i for i, a in enumerate(argv) if a.endswith("kit-entrypoint")),
        None,
    )
    if at is None:
        problems.append(
            f"{rel}: the final ENTRYPOINT does not start through "
            f"docker/entrypoint.sh, so this image boots without applying its "
            f"migrations — the cold-start race kit ships the entrypoint to "
            f"delete. Expected the script before the service command."
        )
        continue
    rest = [a for a in argv[at + 1:] if a]
    if not rest:
        problems.append(
            f"{rel}: the final ENTRYPOINT ends at the entrypoint script and "
            f"names no service command, so the container would exec nothing. "
            f"The script refuses to start with no arguments."
        )
        continue
    if rest[0].startswith("-"):
        problems.append(
            f"{rel}: the final ENTRYPOINT puts {rest[0]!r} before the service "
            f"command, so the script would try to exec a flag as a program"
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }

  section 'static: every artifact parses'

  if [ -z "$ONLY_MATCH" ]; then
  par_begin
  for f in "$ROOT"/ci/* "$ROOT"/lint/* "$ROOT"/docker/* \
    "$ROOT"/backends/instabox/*.sh \
    "$ROOT"/templates/bin-prime/* "$ROOT"/templates/compose/* \
    "$ROOT"/templates/kamal/drill.sh \
    "$ROOT"/templates/compose/postgres/initdb/*.sh \
    "$ROOT"/templates/compose/postgres/Dockerfile \
    "$ROOT"/templates/database/contract.json \
    "$ROOT"/templates/database/tenancy/* \
    "$ROOT"/templates/bin/* "$ROOT"/templates/tier/*/* "$ROOT"/tests/*.sh \
    "$ROOT"/tests/*.mjs \
    "$ROOT"/templates/substrate/install.sh \
    "$ROOT"/templates/substrate/local-cycle.sh \
    "$ROOT"/templates/substrate/kit-install.mjs \
    "$ROOT"/templates/substrate/wrangler.jsonc \
    "$ROOT"/templates/substrate/manifests/applications/* \
    "$ROOT"/templates/substrate/manifests/tls/* \
    "$ROOT"/templates/publish/*; do
    [ -f "$f" ] || continue
    path="${f#"$ROOT"/}"
    case "$f" in
      *.sh) check_par "$path  (bash -n)" bash -n "$f" ;;
      *.yml | *.yaml) check_par "$path  (yaml.safe_load_all)" yaml_ok "$f" ;;
      *.json)
        check_par "$path  (json.loads)" "$PY" -c \
          'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$f"
        ;;
      *.jsonc)
        check_par "$path  (jsonc: comments stripped, then json.loads)" "$PY" -c '
import json, sys
src = open(sys.argv[1], encoding="utf-8").read()
out, i, n, in_str = [], 0, len(src), False
while i < n:
    c = src[i]
    if in_str:
        out.append(c)
        if c == "\\" and i + 1 < n:
            out.append(src[i + 1]); i += 2; continue
        if c == "\"":
            in_str = False
        i += 1
        continue
    if c == "\"":
        in_str = True; out.append(c); i += 1; continue
    if c == "/" and src[i + 1:i + 2] == "/":
        while i < n and src[i] != "\n":
            i += 1
        continue
    if c == "/" and src[i + 1:i + 2] == "*":
        i += 2
        while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
            i += 1
        i += 2
        continue
    out.append(c); i += 1
json.loads("".join(out))
' "$f"
        ;;
      "$ROOT"/templates/compose/postgres/Dockerfile) ;;
      *.mjs)
        if have node; then
          check_par "$path  (node --check)" node --check "$f"
        else
          report_par SKIP "$path  (node not installed)"
        fi
        ;;
      "$ROOT"/docker/Dockerfile.*)
        ;;
      "$ROOT"/templates/tier/rust/*.rs)
        if have rustc; then
          check_par "$path  (rustc --test)" bash -c \
            "rustc --test --edition 2021 -o \"$TMP/kit-tier-rust\" '$f' && '$TMP/kit-tier-rust' --list >/dev/null"
        else
          report_par SKIP "$path  (rustc not installed)"
        fi
        ;;
      "$ROOT"/templates/tier/python/*.py)
        if have python3; then
          check_par "$path  (compile)" python3 -c \
            'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$f"
        else
          report_par SKIP "$path  (python3 not installed)"
        fi
        ;;
      "$ROOT"/templates/tier/ruby/*.rb)
        if have ruby; then
          check_par "$path  (ruby -c)" ruby -c "$f"
        else
          report_par SKIP "$path  (ruby not installed)"
        fi
        ;;
      "$ROOT"/templates/tier/elixir/*.ex)
        if have elixir; then
          check_par "$path  (Code.string_to_quoted!)" elixir -e \
            'case Code.string_to_quoted(File.read!(hd(System.argv()))) do
               {:error, e} -> IO.puts("syntax: #{inspect e}"); System.halt(1)
               {:ok, _} -> :ok
             end' "$f"
        else
          report_par SKIP "$path  (elixir not installed)"
        fi
        ;;
      "$ROOT"/templates/database/tenancy/README.md)
        report_par PASS "$path  (markdown; the presence check is its check)"
        ;;
      "$ROOT"/templates/database/tenancy/substrate.sql | \
      "$ROOT"/templates/database/tenancy/isolation.sql | \
      "$ROOT"/templates/database/tenancy/advisor.sql)
        report_par SKIP "$path  (SQL; parsed by tests/tenancy_test.sh against a real Postgres)"
        ;;
      "$ROOT"/templates/database/tenancy/assertions.txt)
        check_par "$path  (every entry is an assertion name)" bash -c \
          "[ \"\$(grep -cE '^[[:space:]]*[^#[:space:]]' '$f')\" -eq \"\$(grep -cE '^[a-z-]+/[a-z0-9-]+$' '$f')\" ]"
        ;;
      "$ROOT"/templates/database/go/tenancy_test.go.snippet)
        if have gofmt; then
          check_par "$path  (gofmt parses)" gofmt -e "$f"
        else
          report_par SKIP "$path  (gofmt not installed)"
        fi
        ;;
      "$ROOT"/templates/database/python/tenancy_test.py.snippet)
        if have python3; then
          check_par "$path  (compile)" python3 -c \
            'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$f"
        else
          report_par SKIP "$path  (python3 not installed)"
        fi
        ;;
      "$ROOT"/templates/database/ruby/tenancy_test.rb.snippet)
        if have ruby; then
          check_par "$path  (ruby -c)" ruby -c "$f"
        else
          report_par SKIP "$path  (ruby not installed)"
        fi
        ;;
      "$ROOT"/templates/database/elixir/tenancy_test.exs.snippet)
        if have elixir; then
          check_par "$path  (Code.string_to_quoted!)" elixir -e \
            'case Code.string_to_quoted(File.read!(hd(System.argv()))) do
               {:error, e} -> IO.puts("syntax: #{inspect e}"); System.halt(1)
               {:ok, _} -> :ok
             end' "$f"
        else
          report_par SKIP "$path  (elixir not installed)"
        fi
        ;;
      "$ROOT"/templates/database/rust/tenancy_test.rs.snippet)
        if have rustc; then
          check_par "$path  (rustc parses)" rustc --edition 2021 --crate-type lib \
            --emit=metadata -o /dev/null "$f"
        else
          report_par SKIP "$path  (rustc not installed)"
        fi
        ;;
      "$ROOT"/templates/database/node/tenancy_test.ts.snippet)
        if have node; then
          check_par "$path  (node --check, as .ts)" bash -c \
            "cp '$f' '$TMP/tenancy_test.ts' && node --experimental-strip-types --check '$TMP/tenancy_test.ts'"
        else
          report_par SKIP "$path  (node not installed)"
        fi
        ;;
      "$ROOT"/templates/kamal/deploy.yml.erb | "$ROOT"/templates/kamal/kamal-backup.yml.erb)
        check_par "$path  (renders, and the rendered YAML parses)" erb_yaml_ok "$f"
        ;;
      "$ROOT"/templates/tier/go/*.go)
        ;;
      "$ROOT"/templates/tier/*/*.ts)
        report_par SKIP "$path  (node --check cannot read TypeScript; needs a type-stripping parser)"
        ;;
      *)
        report_par SKIP "$path  (no parser for this file type)"
        ;;
    esac
  done
  par_flush

  section 'static: handed-out scripts are executable'
  for f in "$ROOT"/templates/bin-prime/* "$ROOT"/templates/bin/* \
    "$ROOT"/templates/kamal/drill.sh \
    "$ROOT"/templates/substrate/install.sh \
    "$ROOT"/docker/entrypoint.sh \
    "$ROOT"/tests/zizmor_gate.sh; do
    [ -f "$f" ] || continue
    path="${f#"$ROOT"/}"
    if [ -x "$f" ]; then
      report PASS "$path  (executable)"
    else
      report FAIL "$path  (not executable)"
    fi
  done
  fi

  if [ -z "$ONLY_MATCH" ] && have shellcheck; then
    section 'static: shellcheck -S warning'
    par_begin
    for f in "$ROOT"/templates/bin-prime/* "$ROOT"/templates/bin/* \
      "$ROOT"/templates/kamal/*.sh "$ROOT"/templates/substrate/*.sh \
      "$ROOT"/docker/*.sh "$ROOT"/backends/instabox/*.sh "$ROOT"/tests/*.sh; do
      [ -f "$f" ] || continue
      path="${f#"$ROOT"/}"
      check_par "$path  (shellcheck -S warning)" shellcheck -S warning -e SC2317 "$f"
    done
    par_flush
  else
    report SKIP 'shellcheck (not installed)'
  fi

  section 'static: no Go generate line pins a module version without a declared shape'
  # A Go `//go:generate` that names `@v` resolves in a throwaway module context,
  # and a gate that fetches it on demand cannot run where the cache is cold. Two
  # legitimate shapes exist and the guard must tell them apart:
  #
  #   1. DECLARED (applications): tools.go with `//go:build tools` declares the
  #      tool, `go mod tidy` records its graph, `go mod download` fills the cache,
  #      and the `//go:generate` line runs as `go run <module>` with no `@v`.
  #   2. WARMED OUT OF BAND (libraries): the service is a library and a `require`
  #      would pollute every consumer's graph (identity/client). The `//go:generate`
  #      line keeps `@v`, and the gate warms the cache out of band: it reads the
  #      module@version from the generate line (never retyped), creates a throwaway
  #      module that requires it, runs `go mod download all`, and discards the temp
  #      dir. GOMODCACHE is shared so `go run @v` hits the cache offline.
  #
  # The fleet-wide check lives in two places:
  #   - ci.reusable.yml's Go job (`no generate version pin` step) — the CI
  #     enforcement every Go service inherits.
  #   - templates/bin-prime/go.sh (`no Go generate line pins...` step) — the local
  #     `bin/prime` enforcement.
  # Both are asserted here; a service that copies an old template or a workflow
  # that loses the step is a fleet regression that must go red. The guard itself
  # is proven on three fixtures: declared (green), warmed out of band (green),
  # neither (red).
  check 'ci.reusable.yml Go job has no-generate-version guard' bash -c '
    set -euo pipefail
    f="$1/ci/ci.reusable.yml"
    if ! grep -q "no generate version pin" "$f"; then
      echo "ci.reusable.yml Go job has no \"no generate version pin\" step" >&2
      exit 1
    fi
    if ! grep -q "go:generate.*@v" "$f"; then
      echo "ci.reusable.yml Go job has no grep for go:generate.*@v" >&2
      exit 1
    fi
    if ! grep -q "GOMODCACHE" "$f"; then
      echo "ci.reusable.yml Go job has no GOMODCACHE warming marker — it cannot discriminate library shape" >&2
      exit 1
    fi
  ' -- "$ROOT"
  check 'templates/bin-prime/go.sh has no-generate-version guard' bash -c '
    set -euo pipefail
    f="$1/templates/bin-prime/go.sh"
    if ! grep -q "no Go generate line pins" "$f"; then
      echo "templates/bin-prime/go.sh has no generate-version guard" >&2
      exit 1
    fi
    if ! grep -q "go:generate.*@v" "$f"; then
      echo "templates/bin-prime/go.sh has no grep for go:generate.*@v" >&2
      exit 1
    fi
    if ! grep -q "GOMODCACHE" "$f"; then
      echo "templates/bin-prime/go.sh has no GOMODCACHE warming marker — it cannot discriminate library shape" >&2
      exit 1
    fi
  ' -- "$ROOT"
  check 'generate-version guard discriminates (declared green, warmed green, neither red)' bash -c '
    set -euo pipefail

    # The guard logic under test: a //go:generate @v is allowed ONLY if the gate
    # warms the cache out of band (GOMODCACHE / go mod download all in bin/prime
    # or ci.yml). Without that it must fail. Extracted here so the test does not
    # just grep for the pattern but exercises the discrimination.
    guard_passes() {
      local dir="$1"
      if grep -rq "^//go:generate.*@v" --include="*.go" "$dir" >/dev/null; then
        if grep -q "GOMODCACHE\|go mod download all" "$dir/bin/prime" 2>/dev/null || grep -q "GOMODCACHE\|go mod download all" "$dir/ci/ci.yml" 2>/dev/null; then
          return 0
        else
          return 1
        fi
      else
        return 0
      fi
    }

    tmp="$(mktemp -d)"
    trap '\''rm -rf "$tmp"'\'' EXIT

    mkdir -p "$tmp/declared"
    printf "//go:build tools\npackage tools\nimport _ \"github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen\"\n" > "$tmp/declared/tools.go"
    printf "//go:generate go run github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen --config oapi-codegen.yaml\n" > "$tmp/declared/gen.go"
    mkdir -p "$tmp/declared/bin"
    printf "# no warming needed\n" > "$tmp/declared/bin/prime"
    if ! guard_passes "$tmp/declared"; then
      echo "generate-version guard failed on declared fixture — false positive (should be green)" >&2
      exit 1
    fi

    mkdir -p "$tmp/warmed/bin" "$tmp/warmed/ci"
    printf "//go:generate go run github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@v2.8.0 --config oapi-codegen.yaml\n" > "$tmp/warmed/gen.go"
    printf "# WARM THE GENERATOR — GOMODCACHE is shared\n# go mod download all\n" > "$tmp/warmed/bin/prime"
    printf "warming: GOMODCACHE\n" > "$tmp/warmed/ci/ci.yml"
    if ! guard_passes "$tmp/warmed"; then
      echo "generate-version guard failed on warmed fixture — false positive (should be green)" >&2
      exit 1
    fi

    mkdir -p "$tmp/neither"
    printf "//go:generate go run github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@v2.8.0 --config oapi-codegen.yaml\n" > "$tmp/neither/gen.go"
    if guard_passes "$tmp/neither"; then
      echo "generate-version guard passed on neither fixture — false negative (should be red)" >&2
      exit 1
    fi

    if ! grep -q "^//go:generate.*@v" "$tmp/warmed/gen.go"; then
      echo "warmed fixture not matched by @v pattern — vacuous" >&2
      exit 1
    fi
    if grep -q "^//go:generate.*@v" "$tmp/declared/gen.go"; then
      echo "declared fixture incorrectly matched @v pattern" >&2
      exit 1
    fi
  '

  section 'static: templates/otel — every artifact is present'
  otel_required() {
    "$PY" - "$ROOT" "$@" <<'PY'
import os
import sys

root, *rest = sys.argv[1:]
missing = [p for p in rest if not os.path.isfile(os.path.join(root, p))]
if missing:
    sys.exit("missing template artifact(s): " + ", ".join(missing))
PY
  }

  while IFS='|' read -r lang a b c d e; do
    [ -n "$lang" ] || continue
    wanted=()
    for f in "$a" "$b" "$c" "$d" "$e"; do
      [ -n "$f" ] && wanted+=("templates/otel/$lang/$f")
    done
    if otel_required "${wanted[@]}"; then
      report PASS "templates/otel/$lang/  (${#wanted[@]} artifacts present)"
    else
      report FAIL "templates/otel/$lang/  (${#wanted[@]} artifacts present)"
    fi
  done <<'OTEL'
go|traceparent.go|traceparent_test.go|otelhttp.go.snippet
ruby|traceparent.rb|test_traceparent.rb|rack_middleware.rb.snippet
elixir|traceparent.ex|test_traceparent.exs|phoenix_telemetry.ex.snippet
rust|traceparent.rs|otel_client.rs.snippet
python|traceparent.py|test_traceparent.py|fastapi.py.snippet
node|traceparent.mjs|traceparent.test.mjs|hono.ts.snippet
OTEL

  section 'static: templates/database/tenancy — every artifact is present'
  if otel_required \
    'templates/database/tenancy/README.md' \
    'templates/database/tenancy/substrate.sql' \
    'templates/database/tenancy/isolation.sql' \
    'templates/database/tenancy/advisor.sql' \
    'templates/database/tenancy/assertions.txt' \
    'templates/database/go/tenancy_test.go.snippet' \
    'templates/database/elixir/tenancy_test.exs.snippet' \
    'templates/database/python/tenancy_test.py.snippet' \
    'templates/database/ruby/tenancy_test.rb.snippet' \
    'templates/database/node/tenancy_test.ts.snippet' \
    'templates/database/rust/tenancy_test.rs.snippet'; then
    report PASS 'templates/database/tenancy/  (5 shared artifacts + 6 per-language drivers)'
  else
    report FAIL 'templates/database/tenancy/  (5 shared artifacts + 6 per-language drivers)'
  fi

  section 'static: templates/kamal — every artifact is present'
  if otel_required \
    'templates/kamal/README.md' \
    'templates/kamal/deploy.yml.erb' \
    'templates/kamal/kamal-backup.yml.erb' \
    'templates/kamal/drill.sh'; then
    report PASS 'templates/kamal/  (4 artifacts present, the set is whole)'
  else
    report FAIL 'templates/kamal/  (4 artifacts present, the set is whole)'
  fi

  section 'static: backends/instabox — the poller, its supervisor, the provisioner and the template are present'
  if otel_required \
    'backends/README.md' \
    'backends/instabox/agent.sh' \
    'backends/instabox/provision.sh' \
    'backends/instabox/supervisor.sh' \
    'backends/instabox/pipeline.template.sh'; then
    report PASS 'backends/instabox/  (5 artifacts present, the set is whole)'
  else
    report FAIL 'backends/instabox/  (5 artifacts present, the set is whole)'
  fi

  provision_usage="$(bash "$ROOT/backends/instabox/provision.sh" 2>&1 || true)"
  if case "$provision_usage" in
    *--postgres*) true ;;
    *) false ;;
  esac &&
    grep -q 'echo "TEST_DATABASE_URL=' "$ROOT/backends/instabox/provision.sh" &&
    grep -q 'CI_GATE_SERIAL:-0' "$ROOT/backends/instabox/agent.sh" &&
    grep -q 'DATABASE_URL' "$ROOT/backends/README.md" &&
    grep -q 'TEST_DATABASE_URL' "$ROOT/backends/README.md"; then
    report PASS 'backends/instabox  (--postgres, the DATABASE_URL/TEST_DATABASE_URL pair, and CI_GATE_SERIAL are present)'
  else
    report FAIL 'backends/instabox  (--postgres, the DATABASE_URL/TEST_DATABASE_URL pair, and CI_GATE_SERIAL are present)'
  fi

  if [ -e "$ROOT/templates/backup" ] || [ -e "$ROOT/templates/bin/backup.sh" ] ||
    [ -e "$ROOT/docker/Dockerfile.backup" ] || [ -e "$ROOT/tests/backup_test.sh" ]; then
    report FAIL 'the superseded custom backup toolchain  (it must be gone — kamal-backup is the standard)'
  else
    report PASS 'the superseded custom backup toolchain  (it must be gone — kamal-backup is the standard)'
  fi

  if have kamal && have kamal-backup && have ruby; then
    if only_wanted 'kamal_test'; then
      if bash "$ROOT/tests/kamal_test.sh" >"$TMP/kamal_test.log" 2>&1; then
        report PASS "$(sed 's/^PASS: //' "$TMP/kamal_test.log" | tail -1)"
      else
        report FAIL 'kamal_test  (the generated config is accepted by the real binaries)'
        sed 's/^/       /' "$TMP/kamal_test.log" | tail -20
      fi
    fi
  else
    report SKIP 'kamal + kamal-backup + ruby not installed  (the generated config was validated by nothing)'
  fi

  if only_wanted 'kamal_agreement_test'; then
    if bash "$ROOT/tests/kamal_agreement_test.sh" >"$TMP/kamal_agreement_test.log" 2>&1; then
      report PASS "$(sed 's/^PASS: //' "$TMP/kamal_agreement_test.log" | tail -1)"
    else
      report FAIL 'kamal_agreement_test  (the template and its README agree)'
      sed 's/^/       /' "$TMP/kamal_agreement_test.log" | tail -20
    fi
  fi

  if only_wanted 'customer_upstream_check'; then
    if bash "$ROOT/tests/customer_upstream_check.sh" >"$TMP/customer_upstream_check.log" 2>&1; then
      report PASS "$(sed 's/^PASS: //' "$TMP/customer_upstream_check.log" | tail -1)"
    else
      report FAIL 'customer_upstream_check  (the customer path is linked and agrees)'
      sed 's/^/       /' "$TMP/customer_upstream_check.log" | tail -20
    fi
  fi

  section 'static: the canary harness parses in Go'
  if [ -z "$ONLY_MATCH" ] && have gofmt; then
    for f in "$ROOT"/templates/secrets/go/*.go "$ROOT"/templates/secrets/go/internal/*/*.go; do
      [ -f "$f" ] || continue
      path="${f#"$ROOT"/}"
    done
  else
    report SKIP 'templates/secrets/go  (gofmt not installed — cannot parse)'
  fi

  section 'static: every otel snippet parses in its own language'
  snippet_dir="$TMP/snippets"
  rm -rf "$snippet_dir"
  mkdir -p "$snippet_dir"

  while IFS='|' read -r lang file ext cmd; do
    [ -n "$lang" ] || continue
    src="$ROOT/templates/otel/$lang/$file"
    [ -f "$src" ] || continue
    copy="$snippet_dir/$lang$ext"
    cp "$src" "$copy"
    if out=$($cmd "$copy" 2>&1); then
      report PASS "otel/$lang/$file  (parses as $ext)"
    else
      report FAIL "otel/$lang/$file  (parses as $ext)"
      printf '%s\n' "$out" | head -8 | sed 's/^/       /'
    fi
  done <<'SNIPPETS'
go|otelhttp.go.snippet|.go|gofmt -e -l
ruby|rack_middleware.rb.snippet|.rb|ruby -c
python|fastapi.py.snippet|.py|python3 -m py_compile
SNIPPETS

  if have elixir; then
    ex_copy="$snippet_dir/phoenix_telemetry.ex"
    cp "$ROOT/templates/otel/elixir/phoenix_telemetry.ex.snippet" "$ex_copy"
    ex_out="$(elixir -r "$ROOT/templates/otel/elixir/traceparent.ex" "$ex_copy" 2>&1 || true)"
    if grep -qE '\*\* \((Compile|Syntax)Error\)|^\s*error:' <<<"$ex_out"; then
      report FAIL 'otel/elixir/phoenix_telemetry.ex.snippet  (parses as .ex)'
      printf '%s\n' "$ex_out" | head -8 | sed 's/^/       /'
    else
      report PASS 'otel/elixir/phoenix_telemetry.ex.snippet  (parses as .ex)'
    fi
  else
    report SKIP 'otel/elixir/phoenix_telemetry.ex.snippet  (elixir not installed)'
  fi

  if have rustc; then
    rust_copy="$snippet_dir/otel_client.rs"
    cp "$ROOT/templates/otel/rust/otel_client.rs.snippet" "$rust_copy"
    rust_out="$(rustc --edition 2021 --crate-type lib --emit=metadata \
      -o /dev/null "$rust_copy" 2>&1 || true)"
    rust_codes="$(printf '%s\n' "$rust_out" | grep -oE '^error\[E[0-9]+\]' | sort -u)"
    rust_unexpected="$(printf '%s\n' "$rust_codes" | grep -vE 'E0432|E0433|E0463' || true)"
    if [ -n "$rust_unexpected" ]; then
      report FAIL 'otel/rust/otel_client.rs.snippet  (parses as .rs)'
      printf '%s\n' "$rust_unexpected" | sed 's/^/       /'
    elif [ -z "$rust_codes" ]; then
      report PASS 'otel/rust/otel_client.rs.snippet  (parses; crates resolved)'
    else
      report PASS 'otel/rust/otel_client.rs.snippet  (parses; crates unresolved, as expected)'
    fi
  else
    report SKIP 'otel/rust/otel_client.rs.snippet  (rustc not installed)'
  fi

  if have node; then
    ts_copy="$snippet_dir/hono.ts"
    cp "$ROOT/templates/otel/node/hono.ts.snippet" "$ts_copy"
    ts_out="$(node --experimental-strip-types --check "$ts_copy" 2>&1 |
      grep -vE 'ExperimentalWarning|trace-warnings' || true)"
    if [ -z "$ts_out" ]; then
      report PASS 'otel/node/hono.ts.snippet  (parses as .ts)'
    else
      report FAIL 'otel/node/hono.ts.snippet  (parses as .ts)'
      printf '%s\n' "$ts_out" | head -8 | sed 's/^/       /'
    fi
  else
    report SKIP 'otel/node/hono.ts.snippet  (node not installed)'
  fi

  if have node; then
    node_suite_check() {
      node --test "$ROOT/templates/otel/node/traceparent.test.mjs" 2>&1
    }
    check 'templates/otel/node  (the traceparent suite, executed — inbound trace id asserted, and no SDK-2-removed call in the snippet)' \
      node_suite_check
  else
    report SKIP 'templates/otel/node  (node not installed — the conformance suite ran nothing)'
  fi

  section 'static: every Dockerfile is hadolint clean'
  if kit_bootstrap_binary hadolint \
    "https://github.com/hadolint/hadolint/releases/download/v${KIT_HADOLINT_VERSION}" \
    "$KIT_HADOLINT_SHA256S" "$ROOT"; then
    for f in "$ROOT"/docker/Dockerfile.* "$ROOT"/templates/compose/postgres/Dockerfile; do
      [ -f "$f" ] || continue
      rel="${f#"$ROOT"/}"
      if out=$("$BIN" -c "$ROOT/lint/hadolint.yaml" --no-color "$f" 2>&1); then
        report PASS "$rel  (hadolint)"
      else
        report FAIL "$rel  (hadolint)"
        printf '%s\n' "$out" | sed 's/^/       /'
      fi
    done
  else
    report FAIL 'hadolint (required: could not be installed — see the note above)'
  fi

  section 'static: every Dockerfile runs non-root on a pinned base'
  check 'docker/Dockerfile.*  (non-root final stage, no :latest, no ADD)' docker_rules

  section 'static: every image starts through the migration entrypoint'
  check 'docker/Dockerfile.*  (ENTRYPOINT migrates, then execs the service)' docker_entrypoint

  section 'static: every language ships all four artifacts'
  kit_languages() {
    "$PY" - "$ROOT" "$CONFIG_ONLY" "$WORKFLOW" <<'PY'
import re
import sys

import yaml

skip = sys.argv[2]
with open(sys.argv[3], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
jobs = doc.get("jobs") or {}
script = "\n".join(
    str(s.get("run") or "") for s in ((jobs.get("language") or {}).get("steps") or [])
    if isinstance(s, dict)
)
found = [
    name
    for arm in re.findall(r"^\s*([a-z|]+)\)\s*$", script, re.M)
    for name in arm.split("|")
    if name and name != skip
]
if not found:
    sys.exit(
        "the reusable workflow has no `language` gate job naming any language, "
        "so no language artefact can be checked. Reading zero languages is not "
        "the same as there being none"
    )
for name in found:
    print(name)
PY
  }

  _kit_langs="$(kit_languages)" ||
    report FAIL "every language  (the language list could not be read at all)"
  if [ -n "$_kit_langs" ]; then
    while IFS= read -r lang; do
      [ -n "$lang" ] || continue
      if otel_required "docker/Dockerfile.$lang" "templates/bin-prime/$lang.sh"; then
        report PASS "$lang  (Dockerfile + bin/prime present)"
      else
        report FAIL "$lang  (Dockerfile + bin/prime present)"
      fi
    done <<<"$_kit_langs"
  fi

  section 'static: a run: body does not read a name it only ever prefix-assigned'
  run_body_env_check() {
    "$PY" - "$ROOT" <<'PY'
import glob
import os
import re
import sys

import yaml

root = sys.argv[1]

def logical_lines(block):
    buf, start = [], None
    for i, raw in enumerate(block.splitlines(), 1):
        s = raw.rstrip()
        if start is None:
            start = i
        if s.endswith("\\"):
            buf.append(s[:-1])
            continue
        buf.append(s)
        yield start, " ".join(buf)
        buf, start = [], None
    if start is not None:
        yield start, " ".join(buf)


def strip_comment(line):
    """Drop a `#` comment.

    A workflow here carries long explanatory comments and one of them NAMES the
    bug (`built_at=$KIT_PROVENANCE_BUILT_AT` appears in prose explaining it). A
    check that counted that comment would be a check a comment can satisfy, and a
    check a comment can satisfy is the same defect as one a comment can falsify.
    """
    m = re.search(r"(?<![\"'\w])#", line)
    return line[: m.start()] if m else line


READ = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))")
WORD = re.compile(r"""(?:[^\s'"]+|'[^']*'|"[^"]*")+""")
ASSIGN_HEAD = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=")
DECLARE = re.compile(r"^(?:export|declare|readonly|local|typeset)\b")


def prefix_assignments(line):
    """The names a logical line sets as a PREFIX assignment, in order.

    Walks the line word by word. A run of `NAME=value` words is one prefix
    assignment SET; the first word after that run is the command they belong to.
    A run with no command after it is a plain assignment — which creates a shell
    variable, so reading it back is correct.

    Written as a walk rather than as "is there a `NAME=` at the start of a line"
    because the shapes that matter are all wider than that one test:
      - `FOO=-mod=mod BAR=off baz cmd` — three, then the command
      - `FOO="$(date -u +%F)" cmd`        — a quoted value with spaces in it
      - `FOO=bar cmd; …`                  — a `case` arm, terminated by `;;`
      - `export FOO=bar cmd`              — NOT a prefix assignment; `export`
                                             makes it a shell variable, so
                                             reading it later is correct and
                                             refusing it would be the check
                                             firing on correct code
    """
    words = []
    for w in WORD.finditer(line):
        end = w.end()
        word = w.group(0)
        words.append((word, end))
    names = []
    i = 0
    while i < len(words):
        word, _ = words[i]
        if DECLARE.match(word):
            nxt = words[i + 1][0] if i + 1 < len(words) else ""
            m = ASSIGN_HEAD.match(nxt)
            if m:
                names.append((m.group(1), False))
                i += 2
                continue
            i += 1
            continue
        m = ASSIGN_HEAD.match(word)
        if m:
            names.append((m.group(1), True))
            i += 1
            continue
        break
    if i >= len(words):
        return []
    tail = words[i][0]
    if set(tail) <= set(";|&"):
        return []
    return [n for n, is_prefix in names if is_prefix]


def steps(node, path=()):
    """Yield (yaml_path, run_body) for every step with a `run:`."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "run" and isinstance(v, str):
                yield path, v
            else:
                yield from steps(v, path + (k,))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from steps(v, path + (i,))


problems = []

for wf in sorted(glob.glob(os.path.join(root, "ci/*.yml"))):
    rel = os.path.relpath(wf, root)
    with open(wf, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    if not isinstance(doc, dict):
        continue
    for path, body in steps(doc):
        lines = list(logical_lines(body))
        prefix = {}
        for ln, raw in lines:
            for name in prefix_assignments(strip_comment(raw)):
                prefix.setdefault(name, (ln, raw.strip()))

        for name, (assign_ln, assign_txt) in sorted(prefix.items()):
            bare = []
            for ln, raw in lines:
                if ln <= assign_ln:
                    continue
                line = strip_comment(raw)
                for m in READ.finditer(line):
                    got = m.group(1) or m.group(2)
                    if got != name:
                        continue
                    if re.search(
                        r"(?:^|[\s;&|])" + re.escape(name) + r"=\S*$", line[: m.start()]
                    ):
                        continue
                    bare.append((ln, raw.strip()))
            if not bare:
                continue
            problems.append(
                f"{rel} :: {'/'.join(str(p) for p in path)}: {name} is set as a "
                f"PREFIX assignment on line {assign_ln} "
                f"({assign_txt[:70]}) and read as a shell variable on line "
                f"{bare[0][0]} ({bare[0][1][:70]}). A prefix assignment reaches "
                f"the COMMAND's environment, not the shell, so under `set -u` "
                f"that read is fatal: 'unbound variable', exit 1. Assign it on "
                f"its own line and export it, or keep it as a prefix assignment "
                f"and stop reading it back."
            )

if not problems:
    sys.exit(0)
sys.exit("; ".join(problems))
PY
  }
  check 'every run: body  (no name is prefix-assigned and then read as a variable)' \
    run_body_env_check

  section 'static: every workflow job that runs on a runner is bounded'
  check_workflow_timeouts() {
    bash "$ROOT/tests/workflow_timeouts_check.sh" "$1"
  }
  check 'workflow timeouts  (every runs-on job declares timeout-minutes in 1..360; no uses job carries the illegal key)' \
    check_workflow_timeouts "$ROOT/ci"

  section 'static: compose — the observability chokepoint'

  compose_check() {
    "$PY" - "$ROOT" <<'PY'
import re
import sys

import yaml

root = sys.argv[1]
path = f"{root}/templates/compose/docker-compose.yml"
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)

problems = []
services = doc.get("services") or {}
if not services:
    problems.append("no services")

for required in ("postgres", "nats", "nats-stream-init", "redis", "otel-collector", "tempo", "loki", "grafana", "clickstack"):
    if required not in services:
        problems.append(f"missing service: {required}")

for name, svc in services.items():
    image = svc.get("image")
    if not image:
        problems.append(f"{name}: no image")
        continue
    tag = image.rsplit(":", 1)[-1] if ":" in image.rsplit("/", 1)[-1] else ""
    if tag in ("", "latest"):
        problems.append(f"{name}: image is unpinned ({image})")
    if "healthcheck" not in svc:
        problems.append(f"{name}: no healthcheck, so `up --wait` cannot gate on it")

published = []
for name, svc in services.items():
    for entry in (svc or {}).get("ports") or []:
        if isinstance(entry, dict):
            host = str(entry.get("published", ""))
            target = str(entry.get("target", ""))
        else:
            host, _, target = str(entry).partition(":")
        if not host or not target:
            continue
        if "${" not in host:
            published.append(f"{name}: published host port {host} is not a ${{KIT_*}} substitution")

if published:
    problems.extend(published)

INFRASTRUCTURE = (
    "postgres",
    "nats",
    "nats-stream-init",
    "redis",
    "otel-collector",
    "tempo",
    "loki",
    "grafana",
    "clickstack",
)
for name in services:
    if name not in INFRASTRUCTURE:
        problems.append(f"unexpected service: {name}")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/compose/docker-compose.yml  (pinned, healthy, parameterized)' compose_check

  port_range_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import sys

import yaml

root = sys.argv[1]
LOW, HIGH = 15000, 15999
BLOCK = f"{LOW}-{HIGH}"

with open(f"{root}/templates/compose/docker-compose.yml", encoding="utf-8") as fh:
    services = (yaml.safe_load(fh).get("services") or {})

problems = []
seen = {}
for name, svc in services.items():
    for entry in (svc or {}).get("ports") or []:
        if isinstance(entry, dict):
            host = str(entry.get("published", ""))
        else:
            host = str(entry).partition(":")[0]
        if "${" in host:
            host = host.split(":-", 1)[1].rstrip("}") if ":-" in host else host
        if not host.isdigit():
            continue
        port = int(host)
        if not (LOW <= port <= HIGH):
            problems.append(
                f"{name}: published host port {port} is outside the {BLOCK} block "
                f"kit claims. 5432 and 6379 are the two most likely things on a "
                f"developer machine already, and a dev stack that loses to them "
                f"is a dev stack nobody runs."
            )
        if port in seen:
            problems.append(f"{name}: host port {port} is already published by {seen[port]}")
        seen[port] = name

example = open(f"{root}/templates/compose/.env.example", encoding="utf-8").read()
if BLOCK not in example:
    problems.append(
        f"templates/compose/.env.example does not state the {BLOCK} block this "
        f"check enforces: a port range nobody can read is a range nobody respects"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check "docker-compose.yml  (host ports all in the 15000-15999 block, no reuse)" port_range_check

  readiness_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

import yaml

root = sys.argv[1]
with open(f"{root}/templates/compose/docker-compose.yml", encoding="utf-8") as fh:
    services = (yaml.safe_load(fh).get("services") or {})

problems = []
for name, svc in services.items():
    if name == "otel-collector":
        continue
    depends = svc.get("depends_on") or []
    if isinstance(depends, dict):
        depends = list(depends)
    for dep in depends:
        if "otel" in str(dep):
            problems.append(
                f"{name}: depends_on {dep!r}. Telemetry must never be in anyone's "
                f"readiness path: a service that waits for the collector serves "
                f"no traffic while the collector is down, which is strictly worse "
                f"than serving traffic with no traces."
            )
    probe = svc.get("healthcheck") or {}
    test = " ".join(str(probe.get("test", [])))
    for target in ("otel-collector", "4317", "4318", "13133"):
        if target in test:
            problems.append(
                f"{name}: its healthcheck probes {target}. core's probes schema "
                f"wants /healthz to consult NOTHING and /readyz to check real "
                f"dependencies — the collector is not one."
            )

dev = open(f"{root}/templates/bin/dev.sh", encoding="utf-8").read()
up_body = dev.split("\nup() {", 1)[-1].split("\n}\n", 1)[0]
for needle, why in (
    ("healthz", "bin/dev must not probe a telemetry endpoint"),
    ("4317", "bin/dev must not wait on an OTLP port"),
    ("4318", "bin/dev must not wait on an OTLP port"),
):
    if needle in up_body:
        problems.append(f"{why} (found {needle!r} in bin/dev's up path)")

agents = open(f"{root}/templates/AGENTS.md", encoding="utf-8").read()
if "OTEL" not in agents and "telemetry" not in agents:
    problems.append(
        "templates/AGENTS.md says nothing about telemetry and readiness, so the "
        "rule never reaches the service repo where a probe would be written"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'compose + bin/dev  (telemetry is never in a readiness path)' readiness_check

  section 'static: the event bus — the stream the fleet publishes to'
  check 'tests/nats_stream_test.sh  (nats-stream-init exists, is pinned, waits for a healthy nats, covers the fleet publishers, and is idempotent by construction — each with a control that goes red)' \
    bash "$ROOT/tests/nats_stream_test.sh"

  database_contract_check() {
    "$PY" - "$ROOT" <<'PY'
import json
import os
import re
import sys

root = sys.argv[1]
contract_path = os.path.join(root, "templates/database/contract.json")
if not os.path.isfile(contract_path):
    sys.exit(
        "templates/database/contract.json does not exist. The connection "
        "requirements then have no single source, and the next language restates "
        "them in its own snippet and disagrees with the other five."
    )
contract = json.load(open(contract_path, encoding="utf-8"))

def strip_comments(src, lang):
    """`src` with its COMMENTS removed, per language.

    Exists because a required setting can be named in prose and not set in code,
    and a substring test cannot tell the two apart. Measured: the go snippet's
    header comment reads "1. application_name — THE ONE THAT IS NOT OPTIONAL",
    so deleting the one line that sets it left the contract satisfied and
    self-test breakage 72 green.

    The rules, and the reasoning behind each:

      * go / elixir / node / rust  — `//` to end of line. Elixir is the awkward
        DATA, so this strips YAML comments; it is not ERB, because the file holds
        `<%= ENV.fetch(…) %>` as a plain scalar.
      * sql                        — `--` to end of line. Added for the tenancy
        substrate, whose comments quote nearly every required string while
        explaining why it exists; a check that read that file as text would report
        the whole contract satisfied on a substrate with none of it.

    String literals are NOT tracked, and that is the conservative choice in the
    right direction: a comment marker inside a string is left in place, so the
    code that follows it is still scanned and a real setting is still found. The
    failure this could cause is a false NEGATIVE — a setting missed because a
    the six snippets' settings is on its own line above such a marker, so it
    survives. The opposite error, eating code that carries a setting, would make
    this check red on a correct tree.
    """
    out = []
    for line in src.splitlines():
        marker = None
        if lang in ("go", "node", "rust"):
            marker = "//"
        elif lang == "sql":
            marker = "--"
        elif lang in ("python", "ruby"):
            marker = "#"
        elif lang == "elixir":
            i = line.find("#")
            if i != -1 and not (i + 1 < len(line) and line[i + 1] == "{"):
                marker = "#"
        if marker is None:
            out.append(line)
            continue
        i = line.find(marker)
        if i == -1:
            out.append(line)
        else:
            out.append(line[:i].rstrip())
    return "\n".join(out)

required = contract.get("requiredSettings") or []
pool = contract.get("boundedPool") or {}
pool_tokens = pool.get("tokens") or []
forbidden = (contract.get("pooler") or {}).get("forbidden") or []
languages = contract.get("languages") or []

problems = []
if not required:
    problems.append("contract.json declares no requiredSettings")
if not pool_tokens:
    problems.append("contract.json declares no boundedPool.tokens")
if not forbidden:
    problems.append(
        "contract.json declares no forbidden pooler settings. An empty forbidden "
        "list would make the half of this check that matters a no-op."
    )
if not languages:
    problems.append("contract.json declares no languages")
if problems:
    sys.exit("; ".join(problems))

for entry in languages:
    lang = entry.get("lang", "?")
    rel = entry.get("snippet", "")
    path = os.path.join(root, rel)
    if not rel or not os.path.isfile(path):
        problems.append(f"{lang}: {rel} does not exist")
        continue
    body = open(path, encoding="utf-8").read()
    code = strip_comments(body, entry.get("lang", ""))

    for setting in required:
        key = setting.get("key", "?")
        if key not in code:
            problems.append(
                f"database/{lang}: does not set {key}. {setting.get('why', '')} "
                f"The contract is templates/database/contract.json and this file "
                f"is the generated output; a setting that is required there and "
                f"absent here is the service running unbounded on a shared "
                f"cluster."
            )

    if not any(t in code for t in pool_tokens):
        problems.append(
            f"database/{lang}: no bounded pool setting. Expected one of "
            f"{pool_tokens}. {pool.get('why', '')}"
        )

    for bad in forbidden:
        if bad in code:
            problems.append(
                f"database/{lang}: contains {bad!r}, which is a pooler "
                f"workaround. kit runs NO pooler — see "
                f"templates/database/README.md for the argument, and "
                f"DECISIONS.md for the measurements. Each of these trades real "
                f"performance for compatibility with a component that is not in "
                f"the path, and a service carrying one looks correct and is "
                f"slower, so this is the only way it gets noticed."
            )

    if not any(re.search(rf"""["']?\b{n}\b["']?""", body)
               for n in ("courier", "billing", "identity", "darkroom")):
        problems.append(
            f"database/{lang}: names no service, so application_name has nothing "
            f"to attribute a query to. Every snippet ships a placeholder service "
            f"name and the service changes it; none of them may ship without one."
        )

if problems:
    sys.exit("\n       ".join([""] + problems))
print(f"       contract: {len(languages)} language(s) x ({len(required)} required "
      f"+ {len(pool_tokens)} pool tokens + {len(forbidden)} forbidden) — all satisfied")
PY
  }
  check 'templates/database/*  (the contract, in the generated output, per language)' \
    database_contract_check

  tenancy_contract_check() {
    "$PY" - "$ROOT" <<'PY'
import json
import os
import re
import sys

root = sys.argv[1]
contract_path = os.path.join(root, "templates", "database", "contract.json")
if not os.path.isfile(contract_path):
    sys.exit("templates/database/contract.json is missing, so the account boundary has "
             "no requirements and the next edit states them in a README")
contract = json.load(open(contract_path, encoding="utf-8"))
tenancy = contract.get("tenancy") or {}
if not tenancy:
    sys.exit(
        "templates/database/contract.json declares no `tenancy` block. The account "
        "boundary then has no machine-readable requirements, and the check that used "
        "to assert them has nothing to read — which is how a check ends up green "
        "having checked nothing."
    )

def strip_sql_comments(src):
    """`src` with its `--` comments removed, per LINE.

    Deliberately conservative in the same direction the connection check's
    stripper is: a marker it cannot recognise is left alone, so a false NEGATIVE
    (a required string left in a comment, check satisfied anyway) is the known
    failure mode rather than a false POSITIVE that would take a correct tree red.

    String literals are not tracked, and that is safe here for a measured reason
    rather than a hopeful one: every required token in the substrate lives on its
    own line, and the substrate's only `--` inside a string is the `'anywaye:tier=db
    ...'`-shaped hint text, which no required token overlaps.
    """
    out = []
    for line in src.splitlines():
        i = line.find("--")
        if i == -1:
            out.append(line)
        else:
            out.append(line[:i].rstrip())
    return "\n".join(out)

def read(rel):
    path = os.path.join(root, rel)
    if not rel or not os.path.isfile(path):
        return None, f"{rel} does not exist"
    return open(path, encoding="utf-8").read(), ""

problems = []

sub = tenancy.get("substrate") or {}
sub_rel = sub.get("file", "")
sub_raw, err = read(sub_rel)
if err:
    problems.append(f"tenancy/substrate: {err}")
else:
    sub_code = strip_sql_comments(sub_raw)
    for entry in sub.get("required") or []:
        token = entry.get("token", "?")
        if token not in sub_code:
            problems.append(
                f"tenancy/substrate: does not contain {token!r}. {entry.get('why', '')} "
                f"The requirements are templates/database/contract.json and this file is "
                f"the thing they are about; a requirement absent here is an account "
                f"boundary that does not exist."
            )
    if not sub.get("required"):
        problems.append(
            "contract.json's tenancy.substrate declares no `required`. An empty list "
            "would make the half of this check that matters a no-op that passes."
        )
    for bad in sub.get("forbidden") or []:
        if bad.lower() in sub_code.lower():
            problems.append(
                f"tenancy/substrate: contains {bad!r}, which makes a policy decorative. "
                f"{'; '.join(sub.get('forbiddenWhy') or []) or 'See substrate.sql.'}"
            )
    if not sub.get("forbidden"):
        problems.append(
            "contract.json's tenancy.substrate declares no `forbidden` list. The four "
            "shapes that make an RLS policy read correctly and enforce nothing are the "
            "ones nobody notices."
        )

iso = tenancy.get("isolation") or {}
iso_rel = iso.get("file", "")
iso_raw, err = read(iso_rel)
if err:
    problems.append(f"tenancy/isolation: {err}")
else:
    for token in iso.get("required") or []:
        if token not in iso_raw:
            why = iso.get("requiredWhy") or []
            problems.append(
                f"tenancy/isolation: does not contain {token!r}. "
                f"{why[iso.get('required').index(token)] if token in (iso.get('required') or []) else ''}"
            )
    if not iso.get("required"):
        problems.append("contract.json's tenancy.isolation declares no `required` list")

man = tenancy.get("assertions") or {}
man_rel = man.get("file", "")
man_raw, err = read(man_rel)
listed = []
if err:
    problems.append(f"tenancy/assertions: {err}")
else:
    listed = [l.strip() for l in man_raw.splitlines()]
    listed = [l for l in listed if l and not l.startswith("#")]
    if not listed:
        problems.append(
            f"{man_rel} lists no assertions. Every one of the six drivers compares the "
            f"proof's results against this file, so an empty one makes them all "
            f"satisfied by a proof that returned nothing."
        )
    if len(listed) != len(set(listed)):
        dupes = sorted({n for n in listed if listed.count(n) > 1})
        problems.append(f"{man_rel} lists {len(duped)} name(s) twice: {', '.join(dupes)}")

if iso_raw and listed:
    for name in listed:
        suffix = name.split("/", 1)[1] if "/" in name else name
        if ("'" + name + "'") not in iso_raw and ("'/" + suffix + "'") not in iso_raw:
            problems.append(
                f"tenancy/assertions: lists {name!r}, which isolation.sql never "
                f"constructs. Every one of the six drivers compares the proof's "
                f"results against this list, so a name here that the proof does not "
                f"make is a driver asserting completeness about an assertion that "
                f"does not exist — and the driver will be red for it, which is the "
                f"right answer to the wrong question."
            )
    spine = iso.get("spine") or []
    if not spine:
        problems.append(
            "contract.json's tenancy.isolation declares no `spine`. The spine is the "
            "shape the packet names — three denials and an allowance — and a check "
            "that cannot say which assertions are the shape cannot say the shape is "
            "still there."
        )
    for name in spine:
        if name not in listed:
            problems.append(
                f"tenancy/isolation: the spine requires {name!r}, which "
                f"{man_rel} does not list. The spine is asserted in the contract and "
                f"carried by the manifest, and the two must agree or one of them is "
                f"decorative."
            )
    for name in ("owner/no-identity-reads-no-rows",
                 "owner/another-tenants-rows-read-as-none",
                 "owner/own-rows-are-visible",
                 "owner/own-identity-reads-only-its-own-rows"):
        if name not in listed:
            problems.append(
                f"tenancy/assertions: the OWNER half is missing {name!r}. The login "
                f"half passes on a substrate with no FORCE ROW LEVEL SECURITY at all, "
                f"so an assertion set without the owner half cannot detect the one "
                f"defect this whole directory exists for."
            )

adv_raw, err = read("templates/database/tenancy/advisor.sql")
adv_rules = set()
if err:
    problems.append(f"tenancy/advisor: {err}")
else:
    adv_code = strip_sql_comments(adv_raw)
    adv_rules = set(re.findall(r"select\s+'([a-z0-9_]+)'::text\s+as\s+name", adv_code))
    if not adv_rules:
        problems.append(
            "tenancy/advisor: no rule names found in advisor.sql. The pattern reads "
            "`select '<name>'::text as name`, which is the shape every union arm uses. "
            "If the arms were rewritten this check would find nothing and pass — which "
            "is the state it is meant to make impossible, so it says so rather than "
            "reporting a clean file."
        )

ten_raw, err = read("tests/tenancy_test.sh")
if err:
    problems.append(f"tenancy/tenancy_test.sh: {err}")
else:
    trip_pairs = re.findall(
        r"^ *'([a-z0-9_]+):([a-z0-9_]+)'", ten_raw, re.M
    )
    tripped = {r for r, _ in trip_pairs}
    if not tripped:
        problems.append(
            "tests/tenancy_test.sh: no `<rule>:<fixture>` trip pairs found. The pattern "
            "reads the quoted pairs the assertion-7 loop iterates. Without them this "
            "half of the check has nothing to compare and reports agreement between "
            "two empty sets."
        )
    for rule in sorted(adv_rules - tripped):
        problems.append(
            f"tenancy/advisor: rule {rule!r} has NO fixture that trips it in "
            f"tests/tenancy_test.sh. A detective that has never fired is a detective "
            f"nobody can trust, and one that cannot fire is indistinguishable from a "
            f"detective that does not work."
        )
    for rule in sorted(tripped - adv_rules):
        problems.append(
            f"tests/tenancy_test.sh: asserts a rule {rule!r} that advisor.sql does not "
            f"define. Either the rule was renamed or removed and the fixture was not, "
            f"and the suite would then be proving a rule that no longer exists."
        )

drivers = tenancy.get("drivers") or {}
DRIVER_FILES = {
    "go": "templates/database/go/tenancy_test.go.snippet",
    "elixir": "templates/database/elixir/tenancy_test.exs.snippet",
    "python": "templates/database/python/tenancy_test.py.snippet",
    "ruby": "templates/database/ruby/tenancy_test.rb.snippet",
    "node": "templates/database/node/tenancy_test.ts.snippet",
    "rust": "templates/database/rust/tenancy_test.rs.snippet",
}
READ_FORMS = {
    "go": [r"os\.ReadFile\("],
    "elixir": [r"File\.read!\("],
    "python": [r"\.read_text\(", r"open\("],
    "ruby": [r"File\.readlines\(", r"File\.read\("],
    "node": [r"readFile\("],
    "rust": [r"read_to_string\("],
}
for lang, rel in DRIVER_FILES.items():
    body, err = read(rel)
    if err:
        problems.append(f"tenancy/driver {lang}: {err}")
        continue
    code = [l for l in body.splitlines() if not l.lstrip().startswith(("//", "#", "--"))]

    if not drivers.get("mustCarry"):
        problems.append(
            "contract.json's tenancy.drivers declares no `mustCarry`. Every list this "
            "check iterates needs an empty-list guard, because an empty list makes the "
            "loop over it a no-op that PASSES — which is how a check ends up green "
            "having read nothing at all."
        )
    for token in drivers.get("mustCarry") or []:
        if token not in "\n".join(code):
            problems.append(
                f"tenancy/driver {lang}: {token!r} is not in the code. Every driver runs "
                f"isolation.sql and reads the result table it creates; a driver that "
                f"never asks for it is not running this proof."
            )

    if not drivers.get("mustRead"):
        problems.append(
            "contract.json's tenancy.drivers declares no `mustRead`. Without it the "
            "half of this check that distinguishes a driver which READS the assertion "
            "set from one which merely names it in a comment does not exist."
        )
    for token in drivers.get("mustRead") or []:
        forms = READ_FORMS[lang]
        hit = [l.strip() for l in code
               if token in l and any(re.search(f, l) for f in forms)]
        if not hit:
            problems.append(
                f"tenancy/driver {lang}: does not READ {token!r} — no mention of it on a "
                f"line that also opens a file ({', '.join(forms)}). A driver that names "
                f"the assertion set without reading it asserts completeness about "
                f"nothing, and the failure is silent: the driver still runs and still "
                f"passes."
            )
if problems:
    sys.exit("\n       ".join([""] + problems))
print(
    f"       tenancy: substrate {len(sub.get('required') or [])} required + "
    f"{len(sub.get('forbidden') or [])} forbidden, isolation {len(iso.get('required') or [])} "
    f"required, spine {len(iso.get('spine') or [])}, manifest {len(listed)} assertions, "
    f"{len(DRIVER_FILES)} driver(s) all reading both files"
)
PY
  }
  check 'templates/database/tenancy/*  (the account boundary, in the templates that enforce it)' \
    tenancy_contract_check


  postgres_tag_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
compose_path = os.path.join(root, "templates/compose/docker-compose.yml")
example_path = os.path.join(root, "templates/compose/.env.example")

problems = []
compose = open(compose_path, encoding="utf-8").read()
example = open(example_path, encoding="utf-8").read()

m = re.search(r"^\s*POSTGRES_TAG:\s*\$\{KIT_POSTGRES_TAG:-([^}]+)\}\s*$",
              compose, re.M)
if not m:
    problems.append(
        "docker-compose.yml does not pass POSTGRES_TAG as "
        "${KIT_POSTGRES_TAG:-<default>}; without a default the stack cannot "
        "start on a clone with no .env, and this check cannot compare anything"
    )
    compose_default = None
else:
    compose_default = m.group(1)

m2 = re.search(r"^KIT_POSTGRES_TAG=(.*)$", example, re.M)
if not m2:
    problems.append(
        ".env.example does not set KIT_POSTGRES_TAG. That is the state this check "
        "exists for: an unset variable means the compose default silently wins, "
        "which is the half of the disagreement nobody can see."
    )
    example_value = None
else:
    example_value = m2.group(1).strip()
    if not example_value:
        problems.append(
            "KIT_POSTGRES_TAG= with no value. bin/dev copies .env.example to .env, "
            "so an empty value here OVERRIDES the compose default with nothing — "
            "and `postgres:` is an image reference with no tag."
        )

if compose_default and example_value and compose_default != example_value:
    problems.append(
        f"the Postgres tag disagrees. docker-compose.yml defaults to "
        f"{compose_default!r} and templates/compose/.env.example sets "
        f"{example_value!r}. .env.example WINS, because bin/dev copies it to .env "
        f"on first run — so the stack a developer actually gets is "
        f"{example_value!r} while every document in this repository says "
        f"{compose_default!r}. Change both, or neither."
    )

for value, where in ((example_value, ".env.example"),
                     (compose_default, "docker-compose.yml")):
    if value and "alpine" in value:
        problems.append(
            f"{where} pins the Postgres tag as {value!r} (an alpine variant). "
            "pgvector comes from pglayers as a glibc-linked layer and does not "
            "load on musl — measured, in templates/compose/postgres/Dockerfile: "
            "`Error loading shared library ld-linux-*.so` and `CREATE EXTENSION "
            "vector` reporting the extension is not available. Use the Debian "
            "variant."
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'postgres tag  (.env.example and compose agree, and it is not alpine)' postgres_tag_check

  cluster_topology_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
compose_path = os.path.join(root, "templates/compose/docker-compose.yml")
init_path = os.path.join(root, "templates/compose/postgres/initdb/10-cluster.sh")
dockerfile_path = os.path.join(root, "templates/compose/postgres/Dockerfile")

problems = []
compose = open(compose_path, encoding="utf-8").read()

if not os.path.isfile(init_path):
    sys.exit(
        "templates/compose/postgres/initdb/10-cluster.sh does not exist, so the "
        "cluster provisions exactly one database — POSTGRES_DB, the admin one — "
        "and every service's migrations run against a database that was never "
        "created."
    )
init = open(init_path, encoding="utf-8").read()
read_vars = set(re.findall(r"\$\{(KIT_POSTGRES_[A-Z0-9_]+)[:\-]", init))

svc = re.search(r"^  postgres:\n(.*?)(?=^  [a-z]|\Z)", compose, re.M | re.S)
if not svc:
    sys.exit("docker-compose.yml has no postgres service")
block = svc.group(1)

block_live = "\n".join(
    ln for ln in block.splitlines() if not ln.strip().startswith("#")
)
provided = set(re.findall(r"KIT_POSTGRES_[A-Z0-9_]+", block_live))
for name in sorted(read_vars - provided):
    problems.append(
        f"the init script reads ${{{name}}} but docker-compose.yml does not pass "
        f"{name} into the container, so it resolves empty and the cluster "
        f"provisions whatever the script's default is rather than what the "
        f"operator configured. This is the collector rule applied "
        f"where the failure is SILENT: postgres still starts, and the missing "
        f"thing is the databases."
    )

if "/docker-entrypoint-initdb.d" not in block_live:
    problems.append(
        "the postgres service does not mount anything at "
        "/docker-entrypoint-initdb.d, so initdb/10-cluster.sh never runs. The "
        "cluster comes up healthy with a single database and no per-service "
        "roles, and nothing reports it."
    )

if "build:" not in block:
    problems.append(
        "the postgres service has no build: stanza. The image is the official "
        "postgres image plus the pglayers layer, which has to be composed — a "
        "pull would be either a third-party postgres replacement or a cluster "
        "with no pgvector."
    )
else:
    if "dockerfile:" not in block:
        problems.append(
            "the postgres build: stanza names no dockerfile:, so which file is "
            "built is a convention rather than a statement"
        )
    if not os.path.isfile(dockerfile_path):
        problems.append("templates/compose/postgres/Dockerfile does not exist")
    else:
        df = open(dockerfile_path, encoding="utf-8").read()
        for arg in ("POSTGRES_TAG", "PGVECTOR_TAG"):
            if not re.search(rf"^ARG {arg}=", df, re.M):
                problems.append(
                    f"the cluster Dockerfile declares no ARG {arg}, so the tag "
                    f"compose passes as a build arg is ignored and the image "
                    f"silently uses whatever the ARG default is"
                )
        for tag in re.findall(r"^\s*FROM\s+(\S+)", df, re.M):
            if tag.endswith(":latest") or ":" not in tag.rsplit("/", 1)[-1]:
                problems.append(f"the cluster Dockerfile has an unpinned FROM: {tag}")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'the cluster  (one database + role per service, wired end to end)' cluster_topology_check

  connection_budget_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
example = open(
    os.path.join(root, "templates/compose/.env.example"), encoding="utf-8"
).read()
compose = open(
    os.path.join(root, "templates/compose/docker-compose.yml"), encoding="utf-8"
).read()
init = open(
    os.path.join(root, "templates/compose/postgres/initdb/10-cluster.sh"),
    encoding="utf-8",
).read()

problems = []

compose_live = "\n".join(
    ln for ln in compose.splitlines() if not ln.strip().startswith("#")
)

def env_value(name):
    m = re.search(rf"^{name}=(.*)$", example, re.M)
    return int(m.group(1)) if m and m.group(1).strip().isdigit() else None

def compose_fallback(name):
    m = re.search(rf"\$\{{{name}:-(\d+)\}}", compose_live)
    return int(m.group(1)) if m else None

def script_default(name):
    m = re.search(rf'^\s*{name}="\$\{{{name}:-(\d+)\}}"', init, re.M)
    return int(m.group(1)) if m else None

def effective_int(name):
    for source in (env_value(name), compose_fallback(name), script_default(name)):
        if source is not None:
            return source
    return None

max_conn = effective_int("KIT_POSTGRES_MAX_CONNECTIONS")
role_limit = effective_int("KIT_POSTGRES_ROLE_CONNECTIONS")

for name, value in (
    ("KIT_POSTGRES_MAX_CONNECTIONS", max_conn),
    ("KIT_POSTGRES_ROLE_CONNECTIONS", role_limit),
):
    if value is None:
        problems.append(
            f"nothing sets {name} to an integer - not .env.example, not "
            f"docker-compose.yml's :-fallback, not initdb/10-cluster.sh's - so the "
            f"connection budget cannot be checked and a service that raises one of "
            f"them has no idea whether the cluster can absorb it"
        )
if problems:
    sys.exit("; ".join(problems))

FLEET_SERVICES = 9

declared = None
for source in (example, compose_live):
    m = re.search(r"^KIT_POSTGRES_DATABASES=(.*)$", source, re.M) or re.search(
        r"KIT_POSTGRES_DATABASES:\s*\$\{KIT_POSTGRES_DATABASES:-([^}]*)\}", source
    )
    if m and m.group(1).strip():
        declared = m.group(1)
        break

if declared is None:
    tenants = FLEET_SERVICES
    basis = f"no tenant is declared by default, so the fleet this template is for ({tenants} services) is used"
else:
    dbs = [d.strip() for d in declared.split(",") if d.strip()]
    service_dbs = [d for d in dbs if not d.startswith("KIT_")]
    tenants = len(service_dbs)
    basis = f"{tenants} database(s) declared"

for name, effective, from_script in (
    ("KIT_POSTGRES_ROLE_CONNECTIONS", role_limit, script_default("KIT_POSTGRES_ROLE_CONNECTIONS")),
):
    if from_script is not None and from_script != effective:
        problems.append(
            f"{name}: the effective default is {effective} and initdb/10-cluster.sh's "
            f"fallback says {from_script}. The script only reaches its fallback "
            f"when compose does not pass the variable, so the two disagreeing is "
            f"a shape that works on a developer's machine and not in CI."
        )

RESERVED = 8
needed = tenants * role_limit + RESERVED
if max_conn < needed:
    problems.append(
        f"KIT_POSTGRES_MAX_CONNECTIONS is {max_conn} but the topology needs "
        f"{tenants} databases x {role_limit} connections "
        f"(KIT_POSTGRES_ROLE_CONNECTIONS) + {RESERVED} for Postgres's own "
        f"reserves = {needed} ({basis}). With no pooler in the path, the "
        f"connection budget IS the isolation story's other half: a service that "
        f"cannot get a connection cannot reach another service's data, so an "
        f"undersized budget shows up as a total outage rather than as a refused "
        f"query."
    )

if problems:
    sys.exit("; ".join(problems))
print(
    f"       budget: {max_conn} >= {tenants} db x {role_limit} + "
    f"{RESERVED} reserved = {needed}  ({basis})"
)
PY
  }
  check 'the connection budget  (max_connections covers the declared topology)' connection_budget_check

  section 'static: every database snippet parses in its own language'
  db_snippet_dir="$TMP/db-snippets"
  rm -rf "$db_snippet_dir"
  mkdir -p "$db_snippet_dir"

  while IFS='|' read -r file ext cmd; do
    [ -n "$file" ] || continue
    src="$ROOT/templates/database/${file}"
    [ -f "$src" ] || continue
    lang="${file%%/*}"
    copy="$db_snippet_dir/$lang.$ext"
    cp "$src" "$copy"
    tool="${cmd%% *}"
    if command -v "$tool" >/dev/null 2>&1; then
      if out=$($cmd "$copy" 2>&1); then
        report PASS "database/${file}  (parses as $ext)"
      else
        report FAIL "database/${file}  (parses as $ext)"
        printf '%s\n' "$out" | head -8 | sed 's/^/       /'
      fi
    else
      report SKIP "database/${file}  (parses as $ext — $tool not installed)"
    fi
  done <<'DBSNIPPETS'
go/database.go.snippet|.go|gofmt -e -l
python/database.py.snippet|.py|python3 -m py_compile
ruby/database.yml.snippet|.yml|yaml_ok
DBSNIPPETS

  if have elixir; then
    cp "$ROOT/templates/database/elixir/repo.exs.snippet" "$db_snippet_dir/elixir.exs"
    out="$(elixir "$db_snippet_dir/elixir.exs" 2>&1 || true)"
    if printf '%s\n' "$out" | grep -qE '\*\* \((Compile|Syntax)Error\)|^\s*error:'; then
      report FAIL 'database/elixir/repo.exs.snippet  (loads as .exs)'
      printf '%s\n' "$out" | head -8 | sed 's/^/       /'
    else
      report PASS 'database/elixir/repo.exs.snippet  (loads; stdlib only, as intended)'
    fi
  else
    report SKIP 'database/elixir/repo.exs.snippet  (elixir not installed)'
  fi

  if have rustc; then
    cp "$ROOT/templates/database/rust/database.rs.snippet" "$db_snippet_dir/rust.rs"
    out="$(rustc --edition 2021 --crate-type lib --emit=metadata \
      -o /dev/null "$db_snippet_dir/rust.rs" 2>&1 || true)"
    codes="$(printf '%s\n' "$out" | grep -oE '^error\[E[0-9]+\]' | sort -u)"
    unexpected="$(printf '%s\n' "$codes" | grep -vE 'E0432|E0433|E0463' || true)"
    if [ -n "$unexpected" ]; then
      report FAIL 'database/rust/database.rs.snippet  (parses as .rs)'
      printf '%s\n' "$unexpected" | sed 's/^/       /'
    elif [ -z "$codes" ]; then
      report PASS 'database/rust/database.rs.snippet  (parses; crates resolved)'
    else
      report PASS 'database/rust/database.rs.snippet  (parses; crates unresolved, as expected)'
    fi
  else
    report SKIP 'database/rust/database.rs.snippet  (rustc not installed)'
  fi

  if have node; then
    cp "$ROOT/templates/database/node/database.ts.snippet" "$db_snippet_dir/node.ts"
    out="$(node --experimental-strip-types --check "$db_snippet_dir/node.ts" 2>&1)" \
      && node_status=0 || node_status=$?
    if [ "$node_status" -eq 0 ]; then
      report PASS 'database/node/database.ts.snippet  (parses as .ts)'
    else
      report FAIL 'database/node/database.ts.snippet  (parses as .ts)'
      printf '%s\n' "$out" | head -8 | sed 's/^/       /'
    fi
  else
    report SKIP 'database/node/database.ts.snippet  (node not installed)'
  fi

  section 'static: the canary harness — contract, adapter, and every artifact'

  canary_literal_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import sys

root = sys.argv[1]

prefix = "anywaye_canary_"
body = "notarealsecret"
canary = prefix + (body * 3)[:32]

hits = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in (".git", ".venv", "__pycache__")]
    for name in filenames:
        full = os.path.join(dirpath, name)
        rel = os.path.relpath(full, root)
        try:
            with open(full, encoding="utf-8") as fh:
                body_text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
        if canary in body_text:
            hits.append(rel)

if hits:
    sys.exit(
        f"the assembled canary appears as a literal in {hits}. Build it, do not "
        f"write it: a committed credential-shaped string is a finding every "
        f"scanner in the world will make, and allowlisting it teaches the next "
        f"reader that allowlisting a credential is normal. The Go suite asserts "
        f"the same property for templates/secrets/go; this catches it anywhere "
        f"else in the tree"
    )
PY
  }
  check 'the canary  (never committed as a literal, anywhere)' canary_literal_check

  canary_safety_check() {
    "$PY" - "$ROOT" <<'PY'
import sys

prefix = "anywaye_canary_"
canary = prefix + ("notarealsecret" * 3)[:32]

if not canary.startswith(prefix):
    sys.exit("the canary does not carry its prefix")
if len(canary) != len(prefix) + 32:
    sys.exit(f"the canary is {len(canary)} bytes; the contract says prefix + 32")
if "notarealsecret" not in canary:
    sys.exit(
        "the canary has no human-readable 'this is fake' component. A value that "
        "merely LOOKS random is one a reader mistakes for a real credential"
    )

body_expected = ("notarealsecret" * 3)[:32]
if canary[len(prefix):] != body_expected:
    sys.exit(
        "the canary body is not the repeated word the contract specifies, so it "
        "is no longer unmistakably fake. A high-entropy canary is "
        "indistinguishable from a real credential to any detector that scores "
        "entropy, which is most of them"
    )
print("the canary is prefixed, low-entropy, and self-describing")
PY
  }
  check 'the canary  (unmistakably fake: prefixed, low-entropy, self-describing)' \
    canary_safety_check

  canary_output_check() {
    local out ec=0
    if ! have go; then
      echo "go is not installed, so there is no output to sweep" >&2
      return 1
    fi
    out="$(cd "$ROOT/templates/secrets/go" &&
      GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local go test -v -count=1 ./... 2>&1)" || ec=$?

    local needle
    needle="$("$PY" -c '
prefix = "anywaye_canary_"
print(prefix + ("notarealsecret" * 3)[:32])
')"
    if [ -n "$needle" ] && printf '%s\n' "$out" | grep -qF -- "$needle"; then
      echo "the canary suite printed the value it planted. The harness must never print the" >&2
      echo "thing it is sweeping for: a report of a leak that carries the leak is a leak." >&2
      echo "The offending lines, with the value redacted:" >&2
      printf '%s\n' "$out" | grep -F -- "$needle" |
        sed "s|$needle|anywaye_canary_REDACTED|g" | sed 's/^/  /' >&2
      return 1
    fi

    if [ "$ec" -ne 0 ]; then
      printf '%s\n' "$out" | tail -20 | sed 's/^/       /' >&2
      return 1
    fi
    return 0
  }
  check 'the canary suite  (never prints the value it planted)' canary_output_check

  check_chart_publish() {
    bash "$ROOT/tests/chart_publish_check.sh" "$1" "$2"
  }

  check_publish_seam() {
    bash "$ROOT/tests/publish_seam_check.sh" "$1" "$2" "$3" "$4"
  }

  check_publish_toolchain() {
    bash "$ROOT/tests/publish_toolchain_check.sh" "$1"
  }

  check_obs_chart_sources() {
    local apps_dir="$1"
    local checker="$TMP/obs-chart-sources-check.py"
    cat >"$checker" <<'PY'
import glob
import os
import sys

import yaml

apps_dir = sys.argv[1]

PRIVATE_OCI = "oci://ghcr.io/anywaye/charts"
GRAFANA_REPO = "https://grafana.github.io/helm-charts"
PROM_REPO = "https://prometheus-community.github.io/helm-charts"

SERVICE_APPS = {"identity", "gateway", "courier", "parlor", "billing"}
SERVICE_VERSIONS = {
    "identity": "0.1.0",
    "gateway": "0.1.0",
    "courier": "0.1.0",
    "parlor": "0.1.0",
    "billing": "0.1.2",
}
EXPECTED = {
    "alloy": (GRAFANA_REPO, "alloy", "1.13.0"),
    "grafana": (GRAFANA_REPO, "grafana", "10.5.15"),
    "prometheus": (PROM_REPO, "prometheus", "29.36.0"),
}

problems = []
apps = sorted(glob.glob(apps_dir + "/*.yaml")) + sorted(glob.glob(apps_dir + "/*.yml"))
if not apps:
    problems.append(f"no Application manifests found in {apps_dir}")
resolved = 0
for app in apps:
    stem = os.path.splitext(os.path.basename(app))[0]
    try:
        with open(app, encoding="utf-8") as fh:
            adoc = yaml.safe_load(fh)
    except Exception as exc:
        problems.append(f"{app} does not parse: {exc}")
        continue
    if not isinstance(adoc, dict):
        problems.append(f"{app} is not a mapping")
        continue
    name = ((adoc.get("metadata") or {}).get("name"))
    if name != stem:
        problems.append(
            f"{app}: metadata.name is {name!r}, not the filename stem "
            f"{stem!r} — the rule classifies by name and cannot place this file"
        )
        continue
    source = ((adoc.get("spec") or {}).get("source") or {})
    triple = (source.get("repoURL"), source.get("chart"), str(source.get("targetRevision")))
    if name in SERVICE_VERSIONS:
        want = (f"{PRIVATE_OCI}/{name}", name, SERVICE_VERSIONS[name])
        if triple != want:
            problems.append(
                f"{app}: service chart resolves to {triple!r}, not {want!r} — "
                f"the private-OCI ruling still governs the service charts"
            )
            continue
    elif name in EXPECTED:
        want = EXPECTED[name]
        if triple != want:
            problems.append(
                f"{app}: observability chart resolves to {triple!r}, not "
                f"{want!r} — a chart that resolves to neither a fleet "
                f"publication nor its pinned upstream is a broken install"
            )
            continue
    else:
        problems.append(
            f"{app}: {name!r} is neither a service chart nor a pinned "
            f"observability chart — an unclassified Application fails closed"
        )
        continue
    resolved += 1

if problems:
    for problem in problems:
        print(f"obs chart sources: {problem}")
    sys.exit(1)
print(f"sources: {resolved} Application(s) resolve to a published chart")
PY

    local out ec=0
    out="$("$PY" "$checker" "$apps_dir" 2>&1)" || ec=$?
    if [ "$ec" -ne 0 ]; then
      printf '%s\n' "$out" | sed 's/^/       /'
      return 1
    fi


    local registry_fixture="$TMP/obs-chart-sources-registry"
    rm -rf "$registry_fixture"
    mkdir -p "$registry_fixture"
    cp "$apps_dir"/*.yaml "$registry_fixture"/
    sed 's|repoURL: https://grafana.github.io/helm-charts|repoURL: oci://ghcr.io/anywaye/charts|' \
      "$registry_fixture/alloy.yaml" >"$registry_fixture/alloy.yaml.reverted"
    mv "$registry_fixture/alloy.yaml.reverted" "$registry_fixture/alloy.yaml"
    if "$PY" "$checker" "$registry_fixture" >/dev/null 2>&1; then
      printf '       control (a) the registry control did not go red — the repoURL comparison is not measuring what it claims\n'
      return 1
    fi

    local chart_fixture="$TMP/obs-chart-sources-chart"
    rm -rf "$chart_fixture"
    mkdir -p "$chart_fixture"
    cp "$apps_dir"/*.yaml "$chart_fixture"/
    sed 's/chart: grafana$/chart: grafana-drifted/' \
      "$chart_fixture/grafana.yaml" >"$chart_fixture/grafana.yaml.drifted"
    mv "$chart_fixture/grafana.yaml.drifted" "$chart_fixture/grafana.yaml"
    if "$PY" "$checker" "$chart_fixture" >/dev/null 2>&1; then
      printf '       control (b) the chart-name control did not go red — the chart comparison is not measuring what it claims\n'
      return 1
    fi

    printf '%s\n' "$out" | sed 's/^/       /'
    return 0
  }

  check_install_host() {
    local worker="$ROOT/templates/substrate/kit-install.mjs"
    local config="$ROOT/templates/substrate/wrangler.jsonc"
    local script="$ROOT/templates/substrate/install.sh"
    local driver="$ROOT/tests/install-host-driver.mjs"

    if [ ! -f "$worker" ]; then
      printf '       the Worker does not exist: %s\n' "$worker"
      printf '       nothing serves install.sh at anywaye.com/box/install — the front door is open\n'
      return 1
    fi

    if ! have node; then
      return "$SKIP_EXIT"
    fi

    local checker="$TMP/install-host-config-check.py"
    cat >"$checker" <<'PY'
import json
import sys

src = open(sys.argv[1], encoding="utf-8").read()
out, i, n, in_str = [], 0, len(src), False
while i < n:
    c = src[i]
    if in_str:
        out.append(c)
        if c == "\\" and i + 1 < n:
            out.append(src[i + 1]); i += 2; continue
        if c == '"':
            in_str = False
        i += 1
        continue
    if c == '"':
        in_str = True; out.append(c); i += 1; continue
    if c == "/" and src[i + 1:i + 2] == "/":
        while i < n and src[i] != "\n":
            i += 1
        continue
    if c == "/" and src[i + 1:i + 2] == "*":
        i += 2
        while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
            i += 1
        i += 2
        continue
    out.append(c); i += 1

try:
    doc = json.loads("".join(out))
except Exception as exc:
    sys.exit(f"wrangler.jsonc does not parse: {exc}")
if not isinstance(doc, dict):
    sys.exit("wrangler.jsonc is not an object")

problems = []
if doc.get("name") != "kit-install":
    problems.append(f"name is {doc.get('name')!r}, not 'kit-install'")
compat = doc.get("compatibility_date")
if not isinstance(compat, str) or not compat:
    problems.append(f"compatibility_date is {compat!r}, not a pinned date")
if doc.get("main") != "kit-install.mjs":
    problems.append(f"main is {doc.get('main')!r}, not 'kit-install.mjs'")
obs = doc.get("observability")
if not isinstance(obs, dict) or obs.get("enabled") is not True:
    problems.append("observability.enabled is not true")
if "routes" in doc:
    problems.append(
        "a `routes` block is present — the fleet does not carry one (measured:"
        " site's has none); the anywaye.com/box/install route binding is an"
        " operator action, not a file"
    )
rules = doc.get("rules")
if not isinstance(rules, list):
    problems.append(
        "no `rules` array — nothing bundles install.sh into the Worker, so"
        " the served bytes would be a hand-copied second file"
    )
else:
    text_rules = [r for r in rules if isinstance(r, dict) and r.get("type") == "Text"]
    if not text_rules:
        problems.append(
            "no Text-module rule — the served bytes would be a hand-copied"
            " second file"
        )
    else:
        globs = []
        for r in text_rules:
            globs.extend(r.get("globs") or [])
        if not any(
            "install.sh" in g or g == "*.sh" or g.endswith("/*.sh")
            for g in globs
        ):
            problems.append(
                f"Text rule globs {globs} do not cover install.sh — the"
                " served bytes would be a hand-copied second file"
            )

if problems:
    for p in problems:
        print(f"install host: {p}")
    sys.exit(1)
print(
    "wrangler.jsonc: name, pinned compatibility_date, observability, main,"
    " Text rule bundling install.sh — and no routes"
)
PY

    local out ec=0
    out="$("$PY" "$checker" "$config" 2>&1)" || ec=$?
    if [ "$ec" -ne 0 ]; then
      printf '%s\n' "$out" | sed 's/^/       /'
      return 1
    fi

    out="$(node "$driver" "$worker" "$script" 2>&1)" || ec=$?
    if [ "$ec" -eq "$SKIP_EXIT" ]; then
      printf '%s\n' "$out" | sed 's/^/       /'
      return "$SKIP_EXIT"
    fi
    if [ "$ec" -ne 0 ]; then
      printf '%s\n' "$out" | sed 's/^/       /'
      return 1
    fi
    printf '%s\n' "$out" | sed 's/^/       /'


    local short_fixture="$TMP/install-host-short"
    rm -rf "$short_fixture"
    mkdir -p "$short_fixture"
    cp "$worker" "$short_fixture/kit-install.mjs"
    head -c $(( $(wc -c <"$script") - 1 )) "$script" >"$short_fixture/install.sh"
    if node "$driver" "$short_fixture/kit-install.mjs" "$script" >/dev/null 2>&1; then
      printf '       control (a) the one-byte-shorter control did not go red — the byte comparison is not measuring what it claims\n'
      return 1
    fi

    local ct_fixture="$TMP/install-host-content-type"
    rm -rf "$ct_fixture"
    mkdir -p "$ct_fixture"
    sed 's/text\/x-shellscript/text\/plain/' "$worker" >"$ct_fixture/kit-install.mjs"
    cp "$script" "$ct_fixture/install.sh"
    if node "$driver" "$ct_fixture/kit-install.mjs" "$script" >/dev/null 2>&1; then
      printf '       control (b) the content-type control did not go red — the content-type assertion is not measuring what it claims\n'
      return 1
    fi

    return 0
  }

  check_install_host_bundle() {
    if ! have node; then
      return "$SKIP_EXIT"
    fi
    local wrangler_js
    wrangler_js="$(command -v wrangler 2>/dev/null || true)"
    if [ -z "$wrangler_js" ]; then
      wrangler_js="$(find "${XDG_CACHE_HOME:-$HOME/.npm}/_npx" -maxdepth 5 \
        -path '*/node_modules/wrangler/bin/wrangler.js' 2>/dev/null | head -n1 || true)"
    fi
    if [ -z "$wrangler_js" ]; then
      printf '       SKIP: wrangler is not installed — the bundle proof needs it; the offline proof in the check above still ran\n'
      return "$SKIP_EXIT"
    fi

    local bundle_dir="$TMP/install-host-bundle"
    rm -rf "$bundle_dir"
    mkdir -p "$bundle_dir"
    cp "$ROOT/templates/substrate/kit-install.mjs" "$bundle_dir/"
    cp "$ROOT/templates/substrate/wrangler.jsonc" "$bundle_dir/"
    cp "$ROOT/templates/substrate/install.sh" "$bundle_dir/"

    if ! (cd "$bundle_dir" && node "$wrangler_js" deploy --dry-run --outdir "$bundle_dir/out" >/dev/null 2>&1); then
      printf '       wrangler could not build the Worker — the Text-module rule is not bundling install.sh\n'
      return 1
    fi
    local bundle
    bundle="$(ls "$bundle_dir"/out/*.js "$bundle_dir"/out/*.mjs 2>/dev/null | head -n1 || true)"
    if [ -z "$bundle" ]; then
      printf '       the wrangler build produced no bundle\n'
      return 1
    fi

    local out ec=0
    out="$(node "$ROOT/tests/install-host-driver.mjs" "$bundle" "$ROOT/templates/substrate/install.sh" 2>&1)" || ec=$?
    if [ "$ec" -ne 0 ]; then
      printf '%s\n' "$out" | sed 's/^/       /'
      return 1
    fi
    printf '%s\n' "$out" | tail -1 | sed 's/^/       /'

    sed 's|\*\*\/\*\.sh|**/*.txt|' \
      "$bundle_dir/wrangler.jsonc" >"$bundle_dir/wrangler.jsonc.broken"
    mv "$bundle_dir/wrangler.jsonc.broken" "$bundle_dir/wrangler.jsonc"
    if (cd "$bundle_dir" && node "$wrangler_js" deploy --dry-run --outdir "$bundle_dir/out2" >/dev/null 2>&1); then
      printf '       control: the broken-glob control did not go red — the bundle proof is not measuring what it claims\n'
      return 1
    fi
    return 0
  }

  section 'static: templates/substrate — the install is real, and its pins are exact'
  check 'tests/substrate_test.sh  (install.sh parses, DRY_RUN runs, pins are exact, manifests parse, every CRD field is declared by the pinned operator CRD, no :latest, no inline secret, NATS broker + stream + local/substrate drift, remote-URL applies server-side with force-conflicts and local applies client-side)' \
    bash "$ROOT/tests/substrate_test.sh"

  section 'static: the publish tool — Actions-free image+chart publish'
  check 'publish tool  (bin/publish dry-run prints every command; no auth refused with login commands; malformed digest refused; sandbox dry-run idempotent)' \
    bash "$ROOT/tests/publish_test.sh"

  section 'static: launch/ — the developer harness is shaped right, without running it'
  check 'tests/launch_test.sh  (layout validation, pin behavior, command construction, teardown safety, compose/schema invariants with red controls, installer split)' \
    bash "$ROOT/tests/launch_test.sh"

  section 'static: the chart publish path — the publish/consume seam, both ends in kit'
  check 'chart publish  (workflow_call, push defaults false, registry + chart == every service Application repoURL, name/version not inputs, pull_request refused)' \
    check_chart_publish "$ROOT/ci/chart.reusable.yml" \
      "$ROOT/templates/substrate/manifests/applications"

  section 'static: the publish path — the references resolve, and the tag the chart pins is the tag the publish produces'
  check 'publish seam  (local uses root-relative and resolving; caller/callee inputs agree both ways; appVersion derived into the image tag; sha-<40> kept; image digest derived from the image job, written before helm package, refused when malformed; sibling charts agree with their Applications)' \
    check_publish_seam "$ROOT/ci" \
      "$ROOT/templates/substrate/manifests/applications" \
      "$ROOT/.." \
      "$ROOT/templates/publish/publish.yml"

  check 'publish toolchain  (no helm flag the pinned v4 lacks; the pin is verified against one value; the provenance stamper is fetched from the reusable workflow'"'"'s own commit, guarded by name)' \
    check_publish_toolchain "$ROOT/ci"

  section 'static: the observability chart sources — every Application resolves to a chart somebody publishes'
  check 'obs chart sources  (service charts stay on the private OCI registry at their own path (0.1.0, 0.1.2 for billing); alloy/grafana/prometheus carry their pinned upstream repoURL, chart and targetRevision; anything else fails closed)' \
    check_obs_chart_sources \
      "$ROOT/templates/substrate/manifests/applications"

  section 'static: the install host — the Worker serves the exact bytes of install.sh'
  check 'install host  (anywaye.com/box/install serves install.sh byte-exact as text/x-shellscript; traversal and every other path 404; /healthz is 200; wrangler config pinned, Text rule, no routes)' \
    check_install_host

  section 'static: the install host bundle — wrangler builds it, and the build serves the exact bytes (optional)'
  check 'install host bundle  (wrangler dry-run builds the Worker; the bundle serves install.sh byte-exact; a broken Text-rule glob fails the build)' \
    check_install_host_bundle
fi


_lint_label='tests/lint_test.sh  (every linter runs, and its control disagrees)'
_lint_bg=0
_lint_pid=""
_lint_out="$TMP/lint_test.bg.out"
_lint_t0=0
if [ "$RUN_LINT" -eq 1 ]; then
  _lint_wanted=0
  if [ -z "$ONLY_MATCH" ]; then
    ONLY_RAN=$((ONLY_RAN + 1))
    _lint_wanted=1
  else
    case "$_lint_label" in
      *"$ONLY_MATCH"*)
        ONLY_RAN=$((ONLY_RAN + 1))
        _lint_wanted=1
        ;;
      *)
        ONLY_SKIPPED=$((ONLY_SKIPPED + 1))
        ;;
    esac
  fi
  if [ "$_lint_wanted" -eq 1 ]; then
    [ -n "$_PROFILE" ] && _lint_t0="$(_pf_now)"
    bash "$ROOT/tests/lint_test.sh" >"$_lint_out" 2>&1 &
    _lint_pid="$!"
    _lint_bg=1
  fi
fi

kit_phase "30 observability: the claims worth nothing unexercised"
if [ "$RUN_OBSERVABILITY" -eq 1 ]; then
  section 'observability: the redaction boundary, against a real collector'

  if ! have docker; then
    report SKIP 'observability proofs (docker not installed)'
  elif ! docker info >/dev/null 2>&1; then
    report SKIP 'observability proofs (docker daemon not reachable)'
  else
    live_check 'tests/no_telemetry_in_readiness.sh  (collector killed, service still serves)' \
      900 bash "$ROOT/tests/no_telemetry_in_readiness.sh"

    bounded_check 'tests/isolation_test.sh  (service A cannot reach service B'"'"'s database)' \
      1800 bash "$ROOT/tests/isolation_test.sh"
    bounded_check 'tests/tenancy_test.sh  (no identity, another tenant and its own tenant — as the login role AND as the owner; and the same proof with FORCE removed goes red)' \
      1800 bash "$ROOT/tests/tenancy_test.sh"
    bounded_check 'tests/onecluster_test.sh  (two services, ONE postgres container, each with its own database and roles; both answer as their own role, neither reaches the other'"'"'s)' \
      1800 bash "$ROOT/tests/onecluster_test.sh"
    bounded_check 'tests/grant_surface_test.sh  (a fresh cluster'"'"'s roles, settings, memberships, CONNECT and public ACLs match tests/grant_surface.out byte for byte, and both mutation controls go red by name)' \
      1800 bash "$ROOT/tests/grant_surface_test.sh"
    bounded_check 'tests/provisioning_complete_test.sh  (every database in KIT_POSTGRES_DATABASES has BOTH roles — <db>_app exists, LOGIN, NOSUPERUSER, NOBYPASSRLS, membership app -> owner and never back — with a DROPPED role, a REVERSED membership, BYPASSRLS and NOLOGIN each going red by name)' \
      1800 bash "$ROOT/tests/provisioning_complete_test.sh"
  fi
fi

kit_phase "40 classifier + fingerprint + fetch + tenancy, executed"
check 'tests/classify_test.sh  (19 cases, incl. the fail-closed property)' \
  bash "$ROOT/tests/classify_test.sh"

check 'tests/fingerprint_test.sh  (the skip is proven able to be WRONG: outputs deleted, one byte changed, a corrupt record, a foreign version)' \
  bash "$ROOT/tests/fingerprint_test.sh"

check 'tests/route_test.sh  (19 cases: every routing class fails closed; the router never launches the gate)' \
  bash "$ROOT/tests/route_test.sh"

check 'tests/have_timeout_test.sh  (the toolchain probes cannot re-enter the gate: _timeout_bin never calls have)' \
  bash "$ROOT/tests/have_timeout_test.sh"

check 'tests/substrate_copy_test.sh  (66 assertions: missing/edited/comment-only/split/goose-Down both ways/unreadable/standalone byte+named/comment-only-named/extra-named/template-dir-not-graded/dump-excluded/not-adopted/schema-only-not-adoption/bad-path/fleet)' \
  bash "$ROOT/tests/substrate_copy_test.sh"

check 'tests/onecluster_ports_race_test.sh  (two concurrent selections with the same seed never share a block)' \
  bash "$ROOT/tests/onecluster_ports_race_test.sh"

section 'provenance: the stamp a pulled image carries, and what it refuses to carry'
check 'tests/provenance_test.sh  (11 leak shapes refused; both sinks agree; --verify refuses a foreign or ill-shaped stamp; 4/5/6 stay distinct)' \
  bash "$ROOT/tests/provenance_test.sh"

section 'fetch: the pinned kit ref resolves, and a moving one is refused'
kit_cached_check 'tests/fetch_test.sh  (a pin fetches, a branch is refused, offline is real)' \
  120 \
  'tests/fetch_test.sh,templates/bin/dev.sh,VERSION' \
  '' \
  bash "$ROOT/tests/fetch_test.sh"

section 'tenancy: how one shared cluster is split into per-service databases'
check 'tests/multi_tenant_split_test.sh  (a second tenant is split, not fused; identifiers hold in every locale)' \
  bash "$ROOT/tests/multi_tenant_split_test.sh"

if have docker && docker info >/dev/null 2>&1; then
  check 'tests/failfast_test.sh  (a missing required variable is refused in seconds, by name, with nothing started)' \
    bash "$ROOT/tests/failfast_test.sh"
else
  report SKIP 'tests/failfast_test.sh  (NOT RUN — no docker daemon: "no container was created" and the control are UNEXERCISED)'
fi

kit_phase "50 lint: the four linters, run against fixtures that must fail them"
section 'lint: kit configs, executed against fixtures that must fail them'
if [ "$RUN_LINT" -eq 0 ]; then
  report SKIP 'lint_test.sh  (--no-lint)'
elif [ "$_lint_bg" -eq 1 ]; then
  if wait "$_lint_pid"; then
    _lint_ec=0
  else
    _lint_ec=$?
  fi
  _lint_text="$(cat "$_lint_out" 2>/dev/null || true)"
  if [ -n "$_PROFILE" ] && [ "$_lint_t0" != 0 ]; then
    kit_profile check "$_lint_label" "$_lint_t0"
  fi
  _pf_mark=0
  _pf_kind=check
  if [ "$_lint_ec" -eq 0 ]; then
    report PASS "$_lint_label"
    [ -z "$_lint_text" ] || printf '%s\n' "$_lint_text" | sed 's/^/       /'
  elif [ "$_lint_ec" -eq "$SKIP_EXIT" ]; then
    report SKIP "$_lint_label"
    [ -z "$_lint_text" ] || printf '%s\n' "$_lint_text" | sed 's/^/       /'
  else
    report FAIL "$_lint_label"
    printf '%s\n' "$_lint_text" | sed 's/^/       /'
  fi
else
  :
fi

kit_phase "60 summary"
printf '\n'
if [ -n "$ONLY_MATCH" ] && [ "$ONLY_RAN" -eq 0 ]; then
  echo "FAIL: --only='$ONLY_MATCH' selected NO check out of the suite."
  echo "       A filter that matches nothing runs nothing and proves nothing;"
  echo "       agreeing with a filter that matches nothing is not a passing gate."
  echo "       $ONLY_SKIPPED check(s) were excluded. The filter is a typo, or the"
  echo "       check it names does not exist -- and both are worth failing on."
  exit 1
fi
if [ -n "$ONLY_MATCH" ]; then
  echo "note: FILTERED run -- $ONLY_RAN check(s) ran, $ONLY_SKIPPED excluded by --only='$ONLY_MATCH'."
  echo "       This is NOT a claim about the $ONLY_SKIPPED excluded check(s). Run without --only for that."
fi
if [ "$RUN_LIVE" -eq 0 ]; then
  echo "note: --no-live: the observability live tier (canary, collector-killed, fetched stack)"
  echo "       did NOT run. Those claims are UNEXERCISED by this run."
fi
if [ "$fails" -ne 0 ]; then
  echo "FAIL: $fails check(s) failed."
  [ "$skips" -eq 0 ] || echo "note: $skips check(s) skipped (reported above)."
  [ "$bounded_hit" -eq 0 ] || echo "note: $bounded_hit tier(s) hit their time bound — the proof was unexercised, not passed (reported above)."
  exit 1
fi
echo "PASS: every check passed."
[ "$skips" -eq 0 ] || echo "note: $skips check(s) skipped — reported above, never hidden."
[ "$bounded_hit" -eq 0 ] || echo "note: $bounded_hit tier(s) hit their time bound — reported above, never hidden."
if [ "$bounded_ran" -gt 0 ]; then
  echo "note: $bounded_ran tier(s) ran under a time bound; none was reached."
fi
