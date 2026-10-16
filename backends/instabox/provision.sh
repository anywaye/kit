#!/usr/bin/env bash
# kit/backends/instabox/provision.sh — bring a sandbox up as ONE OR MANY
# projects' CI.
#
#   kit/backends/instabox/provision.sh <sandbox-name> <project> [<project> ...]
#
# e.g. one sandbox for the whole fleet:
#
#   kit/backends/instabox/provision.sh cafaye-build billing courier docs identity
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

usage() { printf 'usage: provision.sh <sandbox-name> <project> [<project> ...]\n' >&2; exit 2; }

NAME="${1:-}"
[ -n "$NAME" ] || usage
shift

DEPLOY_HOST="${DEPLOY_HOST:-}"
PROJECTS=()
for arg in "$@"; do
  case "$arg" in
    # A host, not a project name: no cafaye project carries a `.` or a `:`.
    # See the header for why this heuristic exists at all.
    *.* | *:*) DEPLOY_HOST="$arg" ;;
    *) PROJECTS+=("$arg") ;;
  esac
done
[ "${#PROJECTS[@]}" -gt 0 ] || usage

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
    if [ -n "$DEPLOY_HOST" ]; then
      echo "DEPLOY_HOST=${DEPLOY_HOST}"
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
