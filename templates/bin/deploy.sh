#!/usr/bin/env bash
set -euo pipefail

TOOL_NAME="$(basename "$0")"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES_DIR="$(cd "$SELF_DIR/.." && pwd)"
DEFAULT_REDACTOR="$TEMPLATES_DIR/deploy/redact.py"

SERVICE=""
COMPOSE_FILE=""
PROJECT=""
IMAGE=""
LEDGER_DIR="${KIT_DEPLOY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/kit-deploy}"
SECRETS_FD=""
PURGE=0
BUILD=0
SERVICE_ORDER="${KIT_SERVICE_ORDER:-db app}"
READY_TIMEOUT="${KIT_READY_TIMEOUT:-120}"
SECRET_BYTE_LIMIT=32768
MIN_SECRET_LEN=8

SECRET_NAMES=()
SECRET_VALUES=()

fail() { printf '%s: %s\n' "$TOOL_NAME" "$1" >&2; exit "${2:-1}"; }
note() { printf '%s: %s\n' "$TOOL_NAME" "$1" | scrub; }

usage() {
  sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
}

REDACT_CMD=()
KIT_PY=""

setup_redaction() {
  local py
  py="${KIT_PYTHON:-}"
  if [ -z "$py" ]; then
    if command -v python3 >/dev/null 2>&1; then
      py=python3
    else
      fail "python3 is required for log redaction; refusing to print an unredacted deploy log" 78
    fi
  fi
  KIT_PY="$py"
  [ -r "$REDACTOR" ] || fail "redactor not found at $REDACTOR" 78
  REDACT_CMD=("$py" "$REDACTOR" --secrets-fd 3)
}

scrub() {
  if [ "${#SECRET_VALUES[@]}" -eq 0 ]; then
    cat
  else
    "${REDACT_CMD[@]}" 3< <(printf '%s\n' "${SECRET_VALUES[@]}")
  fi
}

say() { printf '%s\n' "$1" | scrub; }

run_scrubbed() {
  local rc=0
  "$@" 2>&1 | scrub || rc="${PIPESTATUS[0]}"
  return "$rc"
}

container_label() {
  docker inspect -f "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || echo ""
}

read_secrets() {
  local fd line name value total=0
  if [ -n "$SECRETS_FD" ]; then
    fd="$SECRETS_FD"
  else
    fail "no secret source. Pass --secrets-fd N (an inherited descriptor) — never a file path" 64
  fi

  while IFS= read -r line <&"$fd"; do
    [ -n "$line" ] || continue
    case "$line" in
    esac
    name="${line%%=*}"
    value="${line#*=}"
    [ "$name" != "$line" ] || fail "secret line has no '=': refusing to guess" 64
    case "$name" in
      [A-Z_][A-Z0-9_]*) ;;
      *) fail "secret name '$name' is not a valid environment variable name" 64 ;;
    esac
    if [ "${#value}" -lt "$MIN_SECRET_LEN" ]; then
      fail "secret '$name' is shorter than $MIN_SECRET_LEN characters; refusing to inject a credential too short to be one" 64
    fi
    SECRET_NAMES+=("$name")
    SECRET_VALUES+=("$value")
  done

  if [ "${#SECRET_VALUES[@]}" -eq 0 ]; then
    fail "the secret descriptor produced no secrets; refusing to deploy without credentials" 64
  fi

  if [ "$total" -gt "$SECRET_BYTE_LIMIT" ]; then
    fail "secrets total $total bytes, over the $SECRET_BYTE_LIMIT byte redaction limit" 64
  fi


  note "read ${#SECRET_VALUES[@]} secret(s): $(printf '%s ' "${SECRET_NAMES[@]}")"
}

check_every_secret_is_claimed() {
  local claimed_all name rendered errfile
  errfile="$(mktemp "${TMPDIR:-/tmp}/kit-deploy-cfg.XXXXXX")"
  if ! rendered="$(compose config --format json 2>"$errfile")"; then
    head -5 "$errfile" | scrub >&2 || true
    rm -f "$errfile"
    fail "could not render '$COMPOSE_FILE' to read the kit.deploy/secrets labels" 65
  fi
  rm -f "$errfile"
  claimed_all="$(
    printf '%s' "$rendered" | "$KIT_PY" -c '
import json
import sys

config = json.load(sys.stdin)
order = sys.argv[1].split()
claimed = []
for name in order:
    body = (config.get("services") or {}).get(name) or {}
    labels = body.get("labels") or {}
    if isinstance(labels, list):
        labels = dict(p.split("=", 1) for p in labels if "=" in p)
    value = labels.get("kit.deploy/secrets")
    if value:
        claimed.extend(value.split())
print(" ".join(claimed))
' "$SERVICE_ORDER" 2>/dev/null
  )"

  for name in "${SECRET_NAMES[@]}"; do
    case " $claimed_all " in
      *" $name "*) ;;
      *) fail "secret '$name' is not claimed by any service in '$SERVICE_ORDER'. Fix the kit.deploy/secrets label, or drop the secret" 64 ;;
    esac
  done
  note "every supplied secret is claimed by a service"
}

compose() {
  docker compose --project-name "$PROJECT" --file "$COMPOSE_FILE" "$@"
}

service_container() {
  compose ps --quiet "$1" 2>/dev/null | head -1
}

require_docker() {
  docker info >/dev/null 2>&1 || fail "the docker daemon is not reachable" 69
  docker compose version >/dev/null 2>&1 || fail "docker compose v2 is required" 69
}

ledger_path() { printf '%s/%s.ledger' "$LEDGER_DIR" "$SERVICE"; }

ledger_append() {
  local tag="$1" digest="$2" status="$3"
  mkdir -p "$LEDGER_DIR"
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$digest" "$status" \
    >>"$(ledger_path)"
}

ledger_last_ok() {
  local skip="${1:-0}" line idx
  local -a hits=()
  [ -r "$(ledger_path)" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      *"	ok") hits+=("$line") ;;
    esac
  done <"$(ledger_path)"
  [ "$skip" -lt "${#hits[@]}" ] || return 1
  printf '%s\n' "${hits[$idx]}"
}


wait_healthy() {
  local cid="$1" deadline="$2" waited=0 status
  while :; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo gone)"
    case "$status" in
      healthy) return 0 ;;
      unhealthy) return 1 ;;
      gone)
        ;;
    esac
    if [ "$waited" -ge "$deadline" ]; then
      return 2
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

tar_stream() {
  "$KIT_PY" -c '
import io
import sys
import tarfile

name = sys.argv[1]
data = sys.stdin.buffer.read()
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w") as archive:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o444
    archive.addfile(info, io.BytesIO(data))
sys.stdout.buffer.write(buf.getvalue())
' "$1"
}

container_has_shell() {
  docker exec -u 0 "$1" sh -c 'exit 0' >/dev/null 2>&1
}

inject_secrets() {
  local cid="$1"
  shift
  local i j name value
  local -a claimed=()

  for name in "$@"; do
    i=-1
    for j in "${!SECRET_NAMES[@]}"; do
      if [ "${SECRET_NAMES[$j]}" = "$name" ]; then
        i="$j"
        break
      fi
    done
    if [ "$i" -lt 0 ]; then
      fail "service claims secret '$name', which was not supplied" 64
    fi
    claimed+=("$name")
    value="${SECRET_VALUES[$i]}"
    if container_has_shell "$cid"; then
      printf '%s' "$value" |
        docker exec -u 0 -i "$cid" sh -c "umask 077; cat > /run/secrets/$name; chmod 0444 /run/secrets/$name" \
          2>/dev/null ||
        fail "could not deliver secret '$name' to $cid" 70
    else
      printf '%s' "$value" | tar_stream "$name" |
        docker cp - "$cid:/run/secrets/" ||
        fail "could not deliver secret '$name' to $cid" 70
    fi
    unset value
  done

  if container_has_shell "$cid"; then
    docker exec -u 0 "$cid" sh -c 'touch /run/secrets/.loaded' >/dev/null
  else
    printf 'loaded' | tar_stream '.loaded' | docker cp - "$cid:/run/secrets/" >/dev/null
  fi
  note "delivered ${#claimed[@]} secret(s) to $cid: ${claimed[*]}"
}

start_with_secrets() {
  local svc="$1" deadline="$2" cid rc=0 claimed
  note "starting service: $svc"
  rc=0
  compose up -d "$svc" >/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    say "service '$svc' did not start (rc=$rc)"
    return 1
  fi
  cid="$(service_container "$svc")"
  if [ -z "$cid" ]; then
    say "could not resolve the container for service '$svc'"
    return 1
  fi

  claimed="$(container_label "$cid" 'kit.deploy/secrets')"
  if [ -n "$claimed" ]; then
    inject_secrets "$cid" $claimed || return 1
  fi

  note "waiting for '$svc' to pass its health gate (timeout ${deadline}s)"
  rc=0
  wait_healthy "$cid" "$deadline" || rc=$?
  case "$rc" in
    0) note "service '$svc' is healthy" ;;
    1)
      say "service '$svc' reported UNHEALTHY within ${deadline}s"
      return 1
      ;;
    2)
      say "service '$svc' never reported healthy within ${deadline}s"
      return 1
      ;;
  esac
  return 0
}

redeliver_secrets() {
  local svc="$1" cid claimed
  cid="$(service_container "$svc")"
  if [ -z "$cid" ]; then
    say "service '$svc' has no container to re-deliver credentials to"
    return 1
  fi
  claimed="$(container_label "$cid" 'kit.deploy/secrets')"
  if [ -z "$claimed" ]; then
    return 0
  fi
  inject_secrets "$cid" $claimed || return 1
  return 0
}

run_with_secrets() {
  local cid="$1"
  shift
  if container_has_shell "$cid"; then
    docker exec "$cid" sh -c '
      set -a
      for f in /run/secrets/*; do
        [ -f "$f" ] || continue
        n=$(basename "$f")
        [ "$n" = ".loaded" ] && continue
        export "$n=$(cat "$f")"
      done
      set +a
      exec "$@"
    ' sh "$@"
  else
    docker exec "$cid" "$@"
  fi
}


do_deploy() {
  local tag="$1" cid rc=0

  export KIT_DEPLOY_IMAGE="$tag"

  if [ "$BUILD" -eq 1 ]; then
    note "building $tag"
    run_scrubbed docker build --tag "$tag" "$SERVICE_BUILD_CONTEXT" || fail "image build failed" 70
  fi

  local previous_tag=""
  if previous_tag="$(ledger_last_ok 0 | cut -f2)"; then
    note "the artifact running now, and the rollback target if this deploy fails: $previous_tag"
  else
    note "no previous deployment on record; this is the first one, and a failure has nothing to roll back to"
  fi

  local svc
  for svc in $SERVICE_ORDER; do
    start_with_secrets "$svc" "$READY_TIMEOUT" || {
      say "service '$svc' did not reach green; the deploy is not going out"
      return 1
    }
  done

  for svc in $SERVICE_ORDER; do
    redeliver_secrets "$svc" || return 1
  done

  cid="$(service_container app)"
  if [ -z "$cid" ]; then
    say "could not resolve the app container"
    return 1
  fi

  local migrate_cmd
  migrate_cmd="$(container_label "$cid" 'kit.deploy/migrate')"
  if [ -n "$migrate_cmd" ]; then
    note "running migrations: $migrate_cmd"
    rc=0
    run_scrubbed run_with_secrets "$cid" sh -c "$migrate_cmd" || rc=$?
    if [ "$rc" -ne 0 ]; then
      say "migrations failed (rc=$rc); rolling back"
      return 2
    fi
  fi

  note "re-checking the health gate after migrations (timeout ${READY_TIMEOUT}s)"
  rc=0
  wait_healthy "$cid" "$READY_TIMEOUT" || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      1) say "the health gate reported UNHEALTHY after migrations" ;;
      2) say "the health gate never reported healthy after migrations" ;;
    esac
    return 3
  fi

  local digest
  digest="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null || echo unknown)"
  ledger_append "$tag" "$digest" ok
  note "deployed $tag and its health gate is green"
  return 0
}

prepare_deploy() {
  setup_redaction
  read_secrets
  check_every_secret_is_claimed
  require_docker
}

cmd_up() {
  local tag="${IMAGE:-anywaye-deploy/$SERVICE:latest}"
  local rc=0
  prepare_deploy

  do_deploy "$tag" || rc=$?
  if [ "$rc" -eq 0 ]; then
    note "UP: $SERVICE is deployed and healthy"
    return 0
  fi

  say "UP FAILED (rc=$rc)"
  local rb=0
  if ledger_last_ok 0 >/dev/null 2>&1; then
    note "rolling back to the previous artifact (the one running before this deploy)"
    do_rollback_impl 0 || rb=1
  else
    say "no previous deployment on record, so there is nothing to roll back to"
    say "the stack is on $tag and it is NOT healthy — this needs a human"
  fi
  if [ "$rb" -ne 0 ]; then
    say "ROLLBACK ALSO FAILED — this needs a human"
  fi
  return "$rc"
}

do_rollback_impl() {
  local idx="${1:-1}" line tag
  line="$(ledger_last_ok "$idx")" || {
    say "no deployment on record ${idx} back; there is nothing to roll back to"
    return 1
  }
  tag="$(printf '%s' "$line" | cut -f2)"
  note "rolling back to $tag"
  do_deploy "$tag"
}

cmd_rollback() {
  local start end
  prepare_deploy
  start=$(date +%s)
  if do_rollback_impl 1; then
    end=$(date +%s)
    note "ROLLBACK: healthy on the previous artifact after $((end - start))s"
    return 0
  fi
  say "ROLLBACK: failed"
  return 1
}

cmd_verify() {
  require_docker
  setup_redaction
  local cid url rc=0
  cid="$(service_container app)"
  [ -n "$cid" ] || fail "no app container for project $PROJECT" 69

  url="$(container_label "$cid" 'kit.deploy/probe-url')"
  [ -n "$url" ] || url="http://127.0.0.1/"

  local hrc=0
  wait_healthy "$cid" 0 || hrc=$?
  if [ "$hrc" -eq 0 ]; then
    say "PASS  container healthcheck: healthy"
  else
    say "FAIL  container healthcheck: not healthy (the service defines what this means)"
    rc=1
  fi

  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo 000)"
  if [ "$code" = "200" ]; then
    say "PASS  $url -> 200"
  else
    say "FAIL  $url -> $code"
    rc=1
  fi

  local restarts policy
  restarts="$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null || echo '?')"
  policy="$(container_label "$cid" 'kit.deploy/restart-policy')"
  say "NOTE  restart policy: ${policy:-unset}, restarts so far: $restarts"
  if [ "$restarts" != "0" ] && [ "$restarts" != "?" ]; then
    say "NOTE  this container has restarted $restarts time(s) since it was created"
  fi

  return "$rc"
}

cmd_status() {
  require_docker
  setup_redaction
  run_scrubbed docker compose --project-name "$PROJECT" --file "$COMPOSE_FILE" ps
  note "ledger ($SERVICE):"
  if [ -r "$(ledger_path)" ]; then
    run_scrubbed cat "$(ledger_path)"
  else
    say "  (no deployments recorded)"
  fi
}

cmd_down() {
  require_docker
  setup_redaction
  if [ "$PURGE" -eq 1 ]; then
    run_scrubbed compose down --volumes --remove-orphans
    note "removed project $PROJECT and its volumes"
  else
    run_scrubbed compose down --remove-orphans
    note "removed project $PROJECT; volumes kept (--purge to remove them)"
  fi
  rm -f "$(ledger_path)"
}

SERVICE_BUILD_CONTEXT="."

main() {
  local cmd="${1:-}"

    case "$1" in
      --service)
        SERVICE="${2:-}"
        shift 2
        ;;
      --file)
        COMPOSE_FILE="${2:-}"
        shift 2
        ;;
      --project)
        PROJECT="${2:-}"
        shift 2
        ;;
      --image)
        IMAGE="${2:-}"
        shift 2
        ;;
      --context)
        SERVICE_BUILD_CONTEXT="${2:-}"
        shift 2
        ;;
      --ledger-dir)
        LEDGER_DIR="${2:-}"
        shift 2
        ;;
      --redactor)
        REDACTOR="${2:-}"
        shift 2
        ;;
      --secrets-fd)
        SECRETS_FD="${2:-}"
        shift 2
        ;;
      --ready-timeout)
        READY_TIMEOUT="${2:-}"
        shift 2
        ;;
      --service-order)
        SERVICE_ORDER="${2:-}"
        shift 2
        ;;
      --build)
        BUILD=1
        shift
        ;;
      --purge)
        PURGE=1
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done

  REDACTOR="${REDACTOR:-$DEFAULT_REDACTOR}"

  case "$cmd" in
    up | verify | rollback | status | down) ;;
    "" | -h | --help)
      usage
      return 0
      ;;
    *)
      fail "unknown command: $cmd"
      ;;
  esac

  [ -n "$SERVICE" ] || fail "--service is required"
  [ -n "$COMPOSE_FILE" ] || fail "--file is required"
  [ -r "$COMPOSE_FILE" ] || fail "compose file not found: $COMPOSE_FILE"
  PROJECT="${PROJECT:-kit-deploy-$SERVICE}"

  export SERVICE_NAME="$SERVICE"
  export KIT_DEPLOY_IMAGE="${IMAGE:-kit-deploy-no-artifact-required-for-this-command}"

  case "$cmd" in
    up) cmd_up ;;
    verify) cmd_verify ;;
    rollback) cmd_rollback ;;
    status) cmd_status ;;
    down) cmd_down ;;
  esac
}

main "$@"
