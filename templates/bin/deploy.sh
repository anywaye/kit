#!/usr/bin/env bash
#
# deploy — the one deployment the other eight copy.
#
#   deploy up       --service courier --file <compose file>   [--secrets-fd 3]
#   deploy verify   --service courier
#   deploy rollback --service courier
#   deploy status   --service courier
#   deploy down     --service courier [--purge]
#
# WHAT THIS IS, PRECISELY, SO A READER IS NOT MISLED. It runs the full shape of
# a production deployment — immutable artifact, ordered start, real health
# gates, restart policy, credential injection, automatic rollback on a failed
# health gate — against a Docker daemon. The TARGET is whatever daemon you
# point it at. Pointed at this machine's local daemon it is a
# production-shaped deployment that runs LOCALLY. It is not a remote deploy
# and does not become one by being called from a laptop. See
# templates/deploy/README.md, "What this is not".
#
# THE FOUR THINGS THAT ARE ACTUALLY HARD, AND WHERE THEY ARE
#
#   1. CREDENTIALS.  The platform's rule is no plaintext at rest, never in a
#      config file, never logged, and a deploy is the most likely place in the
#      system to break it, because deploy tooling prints its own configuration.
#      Handled by: never accepting a secret as an argument or from a file, and
#      `run_scrubbed` wrapping everything this tool prints. See --secrets-fd.
#
#   2. HEALTH GATES THAT CAN GO RED.  A gate that only ever says yes is
#      decoration. `up` does not report success until the container's own
#      healthcheck reports `healthy`, and if it never does, the deploy rolls
#      itself back and says so. `verify` reports the current verdict and its
#      exit code reflects it.
#
#   3. ROLLBACK.  Not a paragraph about how one might roll back. The previous
#      artifact is recorded before the new one is started, and `rollback`
#      redeploys it and waits for its health gate. Tested, not described.
#
#   4. NOT TOUCHING STATE THAT IS NOT OURS.  Every container, network and
#      volume this tool creates is named by the compose project, which
#      defaults to `kit-deploy-<service>`. It never runs `docker system prune`,
#      never runs `docker volume prune`, and never references a container it
#      did not create by that name. A machine with other people's Docker in it
#      is the normal case, not an edge case.
#
# NO SLEEPS ANYWHERE.  Every wait is a poll on a real signal -- a container
# health status, an HTTP status code -- against a deadline. `sleep` appears
# only as the interval BETWEEN polls, which is how often the tool is allowed to
# ask, not how long it guesses something takes.
#
set -euo pipefail

TOOL_NAME="$(basename "$0")"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# templates/bin/ -> templates/ ; the deploy distribution shape is a sibling.
TEMPLATES_DIR="$(cd "$SELF_DIR/.." && pwd)"
DEFAULT_REDACTOR="$TEMPLATES_DIR/deploy/redact.py"

# ---------------------------------------------------------------------------
# Configuration. Every one of these has a default that is safe on a machine
# shared with other people; nothing here reaches for global state.
# ---------------------------------------------------------------------------
SERVICE=""
COMPOSE_FILE=""
PROJECT=""
IMAGE=""
LEDGER_DIR="${KIT_DEPLOY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/kit-deploy}"
SECRETS_FD=""
PURGE=0
BUILD=0
# Dependency order. Every service listed is started, given the secrets it
# claims, and held at its own health gate before the next one starts. The
# default is the shape almost every service in this fleet has: one database,
# then the application. Override it for a service with more moving parts.
SERVICE_ORDER="${KIT_SERVICE_ORDER:-db app}"
READY_TIMEOUT="${KIT_READY_TIMEOUT:-120}"
SECRET_BYTE_LIMIT=32768
# The fixture values in the deploy test are obviously fake; a real deploy
# supplies real ones. This is the floor below which a "secret" is refused,
# because a one-character credential is a misconfiguration that would
# otherwise be masked everywhere and protect nothing.
MIN_SECRET_LEN=8

# BARE VALUES AND NOTHING ELSE. `redact.py` reads fd 3 as a list of literal
# values to scrub, so this array must never hold `NAME=value` — a pair makes the
# redactor match the whole `NAME=value` string and leave the value itself in the
# clear. The NAMES live in SECRET_NAMES beside it and are only ever printed.
#
# Populated by read_secrets. Never printed, never exported to a child.
SECRET_NAMES=()
SECRET_VALUES=()

fail() { printf '%s: %s\n' "$TOOL_NAME" "$1" >&2; exit "${2:-1}"; }
# note: an operator-facing progress line, AND it is scrubbed like everything
# else. It was not, originally, on the reasoning that progress lines are
# written by this file and therefore safe — which is exactly the reasoning
# that makes a leak feel safe right up until a secret is interpolated into a
# message. `note` and `say` are the same function with different prefixes, and
# the prefix is the only reason they were ever two.
note() { printf '%s: %s\n' "$TOOL_NAME" "$1" | scrub; }

usage() {
  sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Redaction. Nothing this tool prints bypasses this, which is the whole point:
# a deploy log is the single most likely artefact in the platform to carry a
# credential out of it.
# ---------------------------------------------------------------------------
REDACT_CMD=()
KIT_PY=""

setup_redaction() {
  local py
  py="${KIT_PYTHON:-}"
  if [ -z "$py" ]; then
    if command -v python3 >/dev/null 2>&1; then
      py=python3
    else
      # Failing closed. A redactor that cannot start is not a redactor, and
      # the safe answer to "I cannot scrub this output" is to refuse to
      # produce it.
      fail "python3 is required for log redaction; refusing to print an unredacted deploy log" 78
    fi
  fi
  KIT_PY="$py"
  [ -r "$REDACTOR" ] || fail "redactor not found at $REDACTOR" 78
  REDACT_CMD=("$py" "$REDACTOR" --secrets-fd 3)
}

# scrub: filter stdin through the redactor. The secret values reach the redactor
# on fd 3 and on nothing else — not argv, not the environment, not a file.
#
# WHY A FRESH DESCRIPTOR EVERY TIME, which is not a style preference. An earlier
# version opened ONE pipe on fd 3 at startup and every `scrub` inherited that
# same descriptor:
#
#     exec 3< <(printf '%s\n' "${SECRET_PAIRS[@]}")
#
# The problem is that fd 3 is a PIPE and not a seekable file, so it is a STREAM
# with one read. The first `scrub` consumed it to EOF and closed it. Every
# `scrub` after that — and `scrub` sits behind every single thing this tool
# prints, including `note` — inherited a descriptor already at EOF, so the
# redactor received an EMPTY value list and fell back to shape matching alone.
#
# The consequence was quiet and severe: the exact-value layer, the one that
# actually knows this deploy's secrets, applied to the FIRST line of output and
# never again. From the second line onward a leaked secret was only caught if it
# happened to match a credential SHAPE. An opaque value — a randomly generated
# password, a base64 signing key — matches no shape, and would have been printed
# in the clear.
#
# It also got worse as the tool grew. Every additional `note`/`say`/`run_scrubbed`
# call was another opportunity to consume the pipe early, so the window in which
# the real redaction was active shrank as the tool got chattier.
#
# Re-opening the pipe per call restores the invariant: every line this tool
# prints is filtered against every secret it holds. The cost is one extra
# subshell per call, which is nothing next to what a deploy does anyway.
scrub() {
  if [ "${#SECRET_VALUES[@]}" -eq 0 ]; then
    cat
  else
    # BARE VALUES, and the second bug this function ever had. The stream used to
    # be built from `SECRET_PAIRS`, which holds `NAME=value`. The redactor
    # treats each fd-3 line as the literal value to scrub, so it was matching the
    # text `SECRET_KEY_BASE=hunter2` and cheerfully printing `hunter2` on every
    # line — running, exiting 0, and masking nothing.
    #
    # Nothing about that is visible from outside. The redactor is not supposed
    # to be defensive about its input format because it cannot: a caller handing
    # it the wrong shape is a caller bug, and the only place that can be caught
    # is the tool that makes the call. Section 1b of `tests/deploy_test.sh`
    # drives THIS function, which is the reason it is written against the tool
    # rather than against the redactor — the redaction unit test used its own
    # helper, passed the right shape, and went green over the whole thing.
    "${REDACT_CMD[@]}" 3< <(printf '%s\n' "${SECRET_VALUES[@]}")
  fi
}

say() { printf '%s\n' "$1" | scrub; }

# run_scrubbed: run a command with all of its output redacted. Used for every
# command whose output could contain a credential — `docker inspect`,
# `docker compose config`, `docker compose logs` above all, because all three
# print things they should not.
#
# The command's own exit status is preserved rather than the redactor's: a
# pipeline that returns the status of `scrub` reports whether the FILTER worked
# and says nothing about whether the DEPLOY did, which is the one status a
# caller acts on.
run_scrubbed() {
  local rc=0
  "$@" 2>&1 | scrub || rc="${PIPESTATUS[0]}"
  return "$rc"
}

# container_label <container> <key>
# Per-service configuration is read from container LABELS rather than by
# re-parsing the rendered compose file. `docker compose config` normalises and
# reorders what it prints, so anything read out of it with sed is a guess about
# a format that exists to be machine-consumed; a label is a value the container
# itself carries, and reading it back cannot drift from what was deployed.
container_label() {
  docker inspect -f "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# Secrets. Read from a file descriptor, never from argv and never from a path.
# ---------------------------------------------------------------------------
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
      \#*) continue ;;
    esac
    # FIRST `=` splits, so a value may contain `=` (base64 padding, query
    # strings, passwords). The name is validated, never the value.
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
    total=$((total + ${#value}))
    SECRET_NAMES+=("$name")
    SECRET_VALUES+=("$value")
  done

  if [ "${#SECRET_VALUES[@]}" -eq 0 ]; then
    fail "the secret descriptor produced no secrets; refusing to deploy without credentials" 64
  fi

  # The redaction stream is an OS pipe and its buffer is finite (64 KiB on
  # Linux). Writing more than this would block the writer at startup, before
  # anything is reading. Refusing with an explanation beats a deploy that
  # hangs with no output.
  if [ "$total" -gt "$SECRET_BYTE_LIMIT" ]; then
    fail "secrets total $total bytes, over the $SECRET_BYTE_LIMIT byte redaction limit" 64
  fi

  # NO long-lived redaction stream is opened here, and that used to be the
  # design. `scrub` now opens its own fresh pipe per call, because a pipe opened
  # once is a stream with a single read: the first scrub drained it and every
  # later one got an empty value list, which meant every line after the first
  # was filtered by SHAPE alone and an opaque secret would have printed in the
  # clear. The values already live in SECRET_VALUES in this shell's memory, so
  # nothing is lost by re-deriving the pipe — and nothing is written to disk.
  # `<<<` would put every secret in /tmp on shells that implement herestrings
  # with a file, which is the failure this whole design exists to prevent, so the
  # pipe is built with process substitution instead.

  # Never printed. Only the NAMES are ever shown, and only in aggregate.
  note "read ${#SECRET_VALUES[@]} secret(s): $(printf '%s ' "${SECRET_NAMES[@]}")"
}

# Every secret handed to this deploy must be claimed by some service. A secret
# that no service claims is almost always a typo in a `kit.deploy/secrets`
# label or a name the service no longer reads, and the failure mode it causes
# is the worst kind: the deploy reports itself green, and the service fails on
# its first real request with a credential that was sitting right there.
#
# This runs BEFORE anything is created. That is why it reads the rendered
# compose config as JSON rather than the labels off a running container:
# `docker compose config --format json` is the machine-readable projection, and
# reading it is how a check can fire before the first container exists. (The
# default YAML projection exists to be read by people and is explicitly not a
# stable interface — the same reasoning that put migrations on a label.)
#
# python3 is not an extra dependency here: setup_redaction has already failed
# closed without it.
check_every_secret_is_claimed() {
  local claimed_all name rendered errfile
  errfile="$(mktemp "${TMPDIR:-/tmp}/kit-deploy-cfg.XXXXXX")"
  # stdout and stderr are captured SEPARATELY, and that is not tidiness. The
  # JSON is read from stdout, so anything on stderr — a compose warning, and
  # under `set -x` the shell's own trace line — has to be kept out of it. The
  # failure mode of merging them is a JSON parse error whose message says
  # nothing about the deploy, which is exactly the kind of thing that gets
  # "fixed" by deleting the check.
  if ! rendered="$(compose config --format json 2>"$errfile")"; then
    # Most often a missing required variable — the file's own
    # `${KIT_DEPLOY_IMAGE:?...}` guard refusing to render. Report that rather
    # than handing empty input to a JSON parser, which is how this ends up
    # printing a Python traceback into a deploy log.
    head -5 "$errfile" | scrub >&2 || true
    rm -f "$errfile"
    fail "could not render '$COMPOSE_FILE' to read the kit.deploy/secrets labels" 65
  fi
  rm -f "$errfile"
  # One line, space-separated. The matcher below is `*" NAME "*`, which needs
  # a space on BOTH sides of the name — and a newline is not a space. Emitting
  # one name per line meant the first label matched and every subsequent one
  # silently did not, so a correctly-configured service was reported as having
  # unclaimed secrets. This is the shape of bug that only appears the moment
  # two services are involved, which is the moment it matters.
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

# ---------------------------------------------------------------------------
# Compose plumbing. Every object this tool creates belongs to PROJECT and
# nothing else.
# ---------------------------------------------------------------------------
compose() {
  docker compose --project-name "$PROJECT" --file "$COMPOSE_FILE" "$@"
}

# service_container <service> — resolve a container by compose service name
# rather than by naming convention, so a service that renames its container
# in the file keeps working.
service_container() {
  compose ps --quiet "$1" 2>/dev/null | head -1
}

require_docker() {
  docker info >/dev/null 2>&1 || fail "the docker daemon is not reachable" 69
  docker compose version >/dev/null 2>&1 || fail "docker compose v2 is required" 69
}

ledger_path() { printf '%s/%s.ledger' "$LEDGER_DIR" "$SERVICE"; }

# The ledger records image tags and digests. It holds NO SECRETS and no
# configuration: it is the answer to "what was running before this deploy",
# which is the only question rollback needs answered.
ledger_append() {
  local tag="$1" digest="$2" status="$3"
  mkdir -p "$LEDGER_DIR"
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$digest" "$status" \
    >>"$(ledger_path)"
}

# The Nth most recent successful deploy, counting back from the newest.
# `ledger_last_ok 0` is what is running now; `1` is the rollback target.
#
# COUNTING FROM THE END, and that is the whole point of the function. The
# ledger is append-ordered, so the newest entry is the LAST line, and the first
# version of this walked the file forwards and compared a running index against
# `$skip`. That returns the OLDEST successful deploy for `0` and the second
# oldest for `1` — so `rollback`, which asks for `1`, cheerfully redeployed the
# artifact that was already running, reported success, and changed nothing.
#
# The symptom was the most dangerous kind: a rollback that reports it worked.
# `tests/deploy_test.sh` caught it by asserting on the container's image
# REFERENCE rather than its digest, because the two tags under test share an
# image and therefore share a digest — a digest assertion would have passed
# against a rollback that did nothing at all.
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
  idx=$(( ${#hits[@]} - 1 - skip ))
  printf '%s\n' "${hits[$idx]}"
}

# ---------------------------------------------------------------------------
# Waiting. A poll against a deadline, never a sleep and a hope.
# ---------------------------------------------------------------------------

# wait_healthy <container> <deadline-seconds>
# Returns 0 on healthy, 1 on unhealthy, 2 on timeout. The three are distinct
# because "the deploy failed" and "we gave up deciding" are different findings
# and a caller that collapses them will eventually report a timeout as a
# failure caused by something it never looked at.
wait_healthy() {
  local cid="$1" deadline="$2" waited=0 status
  while :; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo gone)"
    case "$status" in
      healthy) return 0 ;;
      unhealthy) return 1 ;;
      gone)
        # The container is not there. A restart policy means it may be on its
        # way back; keep polling rather than declaring failure on a race.
        ;;
    esac
    if [ "$waited" -ge "$deadline" ]; then
      return 2
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

# tar_stream <member-name> — read stdin, write a one-member tar to stdout.
#
# Built in memory on purpose. The obvious implementation writes the secret to
# a temp file, tars it, and deletes it, and that temp file is a plaintext
# credential on a block device for the duration of the deploy — which is
# exactly the thing the platform's rule forbids and exactly the thing an
# operator reading this file would assume was fine. The value is on this
# process's stdin and in its memory, and nowhere else.
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

# container_has_shell <container>
#
# Half this fleet ships a distroless runtime image: `docker/Dockerfile.go` and
# `docker/Dockerfile.rust` are both `gcr.io/distroless/static`, which contains
# no shell, no coreutils and no curl. A secret gate that is a shell script
# cannot be mounted into those images at all, so the transport is chosen by
# asking the container rather than by asking the operator.
#
# This is the single most important polyglot difference in this whole packet
# and it is why templates/deploy/README.md has a table instead of a template.
container_has_shell() {
  docker exec -u 0 "$1" sh -c 'exit 0' >/dev/null 2>&1
}

# inject_secrets <container> <name>...
#
# Only the named secrets, and only into this container. Every service in the
# stack declares what it claims on a `kit.deploy/secrets` label, so the
# database's password goes to the database and the application's signing key
# does not travel with it. A deploy that handed every secret to every
# container would be a deploy whose blast radius is the whole stack.
#
# Two transports, one meaning:
#
#   exec  the container has a shell. The value is written by `cat` on the
#         container's own stdin, so it is never on this host's argv, never in
#         a file, and never in the container's config.
#   cp    the container has no shell (distroless). `docker cp` moves a tar over
#         the Docker API rather than by exec'ing anything, so it needs no
#         shell in the container. The same value, the same tmpfs, the same
#         never-on-disk property.
#
# The `.loaded` barrier is part of the delivery in both cases. In the exec
# path it is a `touch`; in the cp path it is an extra tar member, so a
# distroless service gets the identical guarantee — the application cannot
# observe a partially-populated directory as a valid state.
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
      # `-u 0` is not optional. Without it `docker exec` runs as the IMAGE's
      # user, and half this fleet runs unprivileged — courier's release image
      # declares `USER nobody` — so the write would be refused by a tmpfs the
      # runtime made root-owned. The application still runs as its declared
      # user; only the delivery is privileged.
      #
      # umask 077 then chmod 0444 — created owner-only, then made readable,
      # because the application runs unprivileged and its uid cannot be
      # resolved portably across nine language runtimes. The tmpfs is
      # per-container, never written to a block device, and destroyed with the
      # container, so the mode is a bounded trade rather than a shortcut. The
      # production answer, with a real secret provider, is a file owned by the
      # service account; see templates/deploy/README.md.
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
    # The barrier, for a container with no shell to touch anything.
    printf 'loaded' | tar_stream '.loaded' | docker cp - "$cid:/run/secrets/" >/dev/null
  fi
  note "delivered ${#claimed[@]} secret(s) to $cid: ${claimed[*]}"
}

# start_with_secrets <service> <deadline>
#
# Start one service, hand it exactly the secrets it claims, and wait for the
# health gate it declares. The database goes through this path too, which is
# the part that is easy to get wrong: a postgres whose POSTGRES_PASSWORD sits
# in `environment:` is a password that `docker inspect` prints, so the
# reference deployment runs the official postgres image under the same gate as
# the application and feeds it POSTGRES_PASSWORD_FILE.
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
  # shellcheck disable=SC2086  # `claimed` is a deliberately word-split list of names.
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

# redeliver_secrets <service>
#
# Re-send the credentials a service claims, to whatever container currently
# bears that service name. Used after the whole set has been started, because
# `compose up` on one service can recreate another — see the comment at its
# call site.
#
# It resolves the container fresh rather than reusing a captured id, because
# the whole point is that the id may have changed. A service that claims
# nothing is skipped, which is what makes this safe to run over a stack whose
# services are not all credentialed.
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
  # shellcheck disable=SC2086  # a deliberately word-split list of names.
  inject_secrets "$cid" $claimed || return 1
  return 0
}

# run_with_secrets <container> <command> [args...]
#
# Run a command inside a deployed container WITH ITS CREDENTIALS.
#
# This exists because of a fact that is easy to get wrong and expensive to
# debug: **`docker exec` does not inherit PID 1's environment.** It builds the
# new process's environment from the CONTAINER's configuration, which is
# exactly the place the credentials deliberately are not. The application
# starts fine — it is PID 1, and the entrypoint exported into its own
# environment — and then every exec'd process, migrations above all, dies with
# "environment variable X is missing" while the service is healthy and
# answering requests. That is exactly the failure this packet ran into, and it
# is why this function is here rather than a bare `docker exec`.
#
# The values are read from the container's OWN /run/secrets — the same RAM the
# application reads — so the tmpfs remains the single source of truth and no
# value ever crosses back to this host.
#
# A container with no shell (distroless) cannot do this, because there is
# nothing to run the loop with. There the honest answer is that the operation
# has to be a subcommand of the service binary, which is a per-service fact
# and is written up in templates/deploy/README.md rather than guessed at here.
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

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

# The core of `up`, split out because `rollback` runs exactly the same code
# against a different image, and a rollback that is a second implementation is
# a rollback that has never been tested.
do_deploy() {
  local tag="$1" cid rc=0

  # Every compose call made while deploying THIS artifact must name THIS
  # artifact. `main` exports a placeholder so that `down` and `status` can
  # render the file at all, and without this line that placeholder wins for
  # rollback — which passes no `--image` — and compose tries to pull a
  # repository literally named `kit-deploy-no-artifact-required-for-this-command`.
  # The bug is only reachable through `rollback`, which is the worst possible
  # time for a deploy tool to be unable to name its own artifact.
  export KIT_DEPLOY_IMAGE="$tag"

  if [ "$BUILD" -eq 1 ]; then
    note "building $tag"
    run_scrubbed docker build --tag "$tag" "$SERVICE_BUILD_CONTEXT" || fail "image build failed" 70
  fi

  # 1. Name the artifact we are leaving, BEFORE starting anything. A ledger
  #    written only after the new deploy succeeds cannot tell you what to roll
  #    back to when the new deploy succeeds and then misbehaves.
  #
  #    Index 0, and the asymmetry with `do_rollback_impl`'s two indices is the
  #    whole point: this deploy has NOT appended yet, so the newest `ok` entry
  #    is the artifact that is serving right now. That is what `cmd_up` goes
  #    back to if this deploy cannot go green.
  local previous_tag=""
  if previous_tag="$(ledger_last_ok 0 | cut -f2)"; then
    note "the artifact running now, and the rollback target if this deploy fails: $previous_tag"
  else
    note "no previous deployment on record; this is the first one, and a failure has nothing to roll back to"
  fi

  # 2. Each service in order. `SERVICE_ORDER` is the dependency order; every
  #    service is started, given its own secrets, and held at its own health
  #    gate before the next one starts. A database that is "running" but not
  #    yet accepting connections is the most common cause of a first-boot
  #    migration failure, and this ordering is what makes that a wait instead
  #    of a race.
  local svc
  for svc in $SERVICE_ORDER; do
    start_with_secrets "$svc" "$READY_TIMEOUT" || {
      say "service '$svc' did not reach green; the deploy is not going out"
      return 1
    }
  done

  # RE-DELIVER TO EVERYTHING, once the whole set exists.
  #
  # A later `compose up` can RECREATE an earlier service as a side effect —
  # observed, not theorised: after a daemon restart, `compose up -d app`
  # printed `db-1 Recreate / db-1 Recreated` because `postgres:17-alpine` had
  # been re-pulled and its digest no longer matched the one the container was
  # created from. A recreated container comes back with an EMPTY /run/secrets,
  # so it blocks at the credential gate, its healthcheck fails, and
  # `depends_on: service_healthy` takes the application down with it.
  #
  # This is the restart problem one layer down: a tmpfs credential store is
  # only correct for as long as the container holding it. Injecting at each
  # service's own start and then trusting that nothing later touches it is a
  # deploy that is correct until an image is re-pulled — which on a machine with
  # a shared image cache is a Tuesday.
  #
  # Re-delivering is idempotent and cheap — the same values, over the same
  # pipe — and it closes the window where a service is alive but has no
  # credentials.
  for svc in $SERVICE_ORDER; do
    redeliver_secrets "$svc" || return 1
  done

  cid="$(service_container app)"
  if [ -z "$cid" ]; then
    say "could not resolve the app container"
    return 1
  fi

  # 3. Schema migrations, from INSIDE the running image, as the release's own
  #    task. For courier that is `bin/migrate`; for Rails it is `db:migrate`;
  #    for Django it is `manage.py migrate`. It is a label rather than a rule
  #    because nine languages genuinely disagree here — one of the places this
  #    packet refuses to pretend a single template fits all nine.
  local migrate_cmd
  migrate_cmd="$(container_label "$cid" 'kit.deploy/migrate')"
  if [ -n "$migrate_cmd" ]; then
    note "running migrations: $migrate_cmd"
    rc=0
    # run_with_secrets, not docker exec: a migration is an exec'd process and
    # an exec'd process does not inherit the entrypoint's environment.
    # shellcheck disable=SC2086  # $migrate_cmd is the label's own command line.
    run_scrubbed run_with_secrets "$cid" sh -c "$migrate_cmd" || rc=$?
    if [ "$rc" -ne 0 ]; then
      say "migrations failed (rc=$rc); rolling back"
      return 2
    fi
  fi

  # 4. The gate, one more time, after migrations. The pre-migration gate only
  #    proves the service can start; this one proves it is still healthy with
  #    the new schema applied, which is a different question and the one a
  #    deploy actually has to answer.
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

# Everything both mutating commands need before they touch anything, in this
# order: resolve the redactor, read the credentials, prove every credential is
# claimed, then find the daemon.
#
# `rollback` needs this too, and its omission is the bug this packet shipped
# into its own test suite first time round: rollback re-runs the deploy path,
# the deploy path delivers secrets, and a rollback with an empty secret list
# fails at the first service with "service claims secret 'POSTGRES_PASSWORD',
# which was not supplied". A rollback that cannot restart the stack it is
# rolling back is not a rollback, and it fails exactly when it is most needed —
# during an incident, with the previous artifact sitting right there.
prepare_deploy() {
  setup_redaction
  # Input validation BEFORE the daemon, in this order, and the order is the
  # point: a deploy that is going to be refused should be refused before it
  # touches infrastructure, and it should be refused for the same reason
  # whether or not a Docker daemon happens to be running. `compose config`
  # renders the file without contacting the daemon, so the claim check works
  # on a machine with no Docker at all — which is what makes it a static check
  # rather than a thing that only runs where the thing it checks is.
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
  # A deploy that cannot reach green must not leave the previous version
  # quietly replaced by a broken one. Rolling back here is the difference
  # between a deploy and an outage with extra steps.
  local rb=0
  if ledger_last_ok 0 >/dev/null 2>&1; then
    note "rolling back to the previous artifact (the one running before this deploy)"
    do_rollback_impl 0 || rb=1
  else
    # Said out loud rather than skipped over. A first-ever deploy that fails
    # leaves a broken stack with nothing to go back to, and an operator who is
    # not told that will find out from their users.
    say "no previous deployment on record, so there is nothing to roll back to"
    say "the stack is on $tag and it is NOT healthy — this needs a human"
  fi
  if [ "$rb" -ne 0 ]; then
    say "ROLLBACK ALSO FAILED — this needs a human"
  fi
  return "$rc"
}

# do_rollback_impl <ledger-index>
#
# 0 = the artifact that was running a moment ago, 1 = the one before that.
#
# The two callers need different indices, and getting this wrong is invisible
# until a deploy fails at 03:00. A deploy that FAILS never appends to the
# ledger, so immediately after a failure the newest `ok` entry IS the artifact
# that was serving before the failure — index 0. A `rollback` a human asked
# for, on the other hand, runs while a perfectly good artifact is current, so
# it must reach past it — index 1.
#
# Using 1 for both is wrong in a way the tests found: after a human rollback,
# the ledger holds [A, B, A] — the rollback appends A as the new head — and a
# later failed deploy then took index 1 and restored **B**, the artifact that
# had already been rolled back away from. The stack was left on a version
# nobody had asked for and nobody had rolled back to.
do_rollback_impl() {
  local idx="${1:-1}" line tag
  line="$(ledger_last_ok "$idx")" || {
    say "no deployment on record ${idx} back; there is nothing to roll back to"
    return 1
  }
  tag="$(printf '%s' "$line" | cut -f2)"
  note "rolling back to $tag"
  # The same deploy path, the same health gate, a different artifact. If this
  # did not go through the same code the deploy did, it would not be tested by
  # the fact that the deploy works.
  do_deploy "$tag"
}

cmd_rollback() {
  local start end
  # prepare_deploy, not just require_docker: see its comment. Rollback is a
  # deploy of a different artifact and needs the credentials that go with it.
  prepare_deploy
  start=$(date +%s)
  # Index 1, explicitly: a human asked to go back from a GOOD artifact, so the
  # one behind the head is the target. See do_rollback_impl.
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

  # A deadline of 0 is "ask once", not "wait forever": the point of `verify`
  # is to report the state RIGHT NOW, not to paper over a red by waiting for
  # it to become green.
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

  # The probe the deploy gate does NOT make, reported so an operator can see
  # it: whether the container has been restarting. A service that is "healthy"
  # because it crash-loops into health once a minute is not healthy.
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
  # Scoped to this project by construction. `docker compose down` on a named
  # project removes that project's containers, networks and — with --volumes —
  # that project's volumes, and nothing else. It is not a prune, and there is
  # no code path in this tool that runs one.
  if [ "$PURGE" -eq 1 ]; then
    run_scrubbed compose down --volumes --remove-orphans
    note "removed project $PROJECT and its volumes"
  else
    run_scrubbed compose down --remove-orphans
    note "removed project $PROJECT; volumes kept (--purge to remove them)"
  fi
  rm -f "$(ledger_path)"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SERVICE_BUILD_CONTEXT="."

main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift || true

  while [ $# -gt 0 ]; do
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

  # The deploy file guards its image with `${KIT_DEPLOY_IMAGE:?...}` on
  # purpose — a deploy that reaches that line with no artifact is a deploy
  # that was going to run `latest` by accident. The guard has a cost, though:
  # it makes the file un-renderable for `down` and `status` unless the variable
  # happens to be set in the operator's environment, which means you cannot
  # tear down a stack whose image name you have forgotten. Exporting a
  # placeholder here makes every command renderable; `up` overrides it with
  # the real artifact immediately before it runs.
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
