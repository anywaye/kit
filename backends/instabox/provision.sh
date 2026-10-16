#!/usr/bin/env bash
# kit/backends/instabox/provision.sh — bring a sandbox up as a project's CI.
#
#   kit/backends/instabox/provision.sh <sandbox-name> <project-name> [deploy-host]
#
# Run from an operator's machine with the instabox CLI logged in and `gh`
# authenticated. Idempotent on purpose: it reconciles a sandbox that drifted
# rather than failing — a newer master, a rotated key, a replaced machine.
#
# What the sandbox gets:
#   rsync           most pipelines ship something; without the client the
#                   forced-command key on the target is unreachable
#   $HOME/.ci-env   the project's CI variables, one KEY=value per line —
#                   GH_TOKEN, the project, the poll interval, and whatever
#                   the project's pipeline declares (DEPLOY_HOST et al)
#   the workspace   $HOME/workspace/cafaye, the shape the fleet's gates
#                   expect (the same layout moon/cafaye uses)
#   the agent       kit/backends/instabox/agent.sh, polling that project's
#                   master and running its ci/pipeline.sh on every move
#
# A key is NOT placed by default: deploy keys belong to the project's
# pipeline (which declares what it needs), and the pipeline writes its own
# credentials from $HOME/.ci-env. A project that ships files over SSH puts
# its key in the sandbox itself — the docs pipeline writes one from
# DEPLOY_KEY, and that is the pattern to copy.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAME="${1:?usage: provision.sh <sandbox-name> <project-name> [deploy-host]}"
PROJECT="${2:?usage: provision.sh <sandbox-name> <project-name> [deploy-host]}"
DEPLOY_HOST="${3:-}"

log() { printf '\n== %s\n' "$1"; }

log "sandbox $NAME for cafaye/$PROJECT"
instabox get "$NAME" >/dev/null 2>&1 || instabox create --name "$NAME" --template universal >/dev/null

log "the toolchain the sandbox lacks"
instabox ssh "$NAME" -- "sudo apt-get update -qq && sudo apt-get install -y -qq rsync >/dev/null 2>&1; rsync --version | head -1"

log "the CI environment"
{
  echo "PROJECT_REPO_URL=https://github.com/cafaye/${PROJECT}.git"
  echo "PROJECT_NAME=${PROJECT}"
  echo "CI_BRANCH=${CI_BRANCH:-master}"
  echo "CI_POLL_SECONDS=${CI_POLL_SECONDS:-120}"
  echo "GH_TOKEN=${GH_TOKEN:-$(gh auth token)}"
  [ -n "$DEPLOY_HOST" ] && echo "DEPLOY_HOST=${DEPLOY_HOST}"
  # Anything the caller exports in CI_EXTRA_ENV (JSON-ish lines) is passed
  # through verbatim: a project's pipeline declares its own variables, and
  # provision does not enumerate them.
  if [ -n "${CI_EXTRA_ENV:-}" ]; then
    printf '%s\n' "$CI_EXTRA_ENV"
  fi
} | instabox ssh "$NAME" -- "cat > ~/.ci-env && chmod 600 ~/.ci-env"

log "the agent"
instabox ssh "$NAME" -- "mkdir -p ~/ci && cat > ~/ci/agent.sh" < "$KIT_DIR/backends/instabox/agent.sh"
instabox ssh "$NAME" -- "chmod +x ~/ci/agent.sh"

log "start (or confirm) the poller"
if instabox ssh "$NAME" -- "pgrep -f agent.sh >/dev/null"; then
  echo "provision: the agent is already running; restarting it to pick up the new environment"
  instabox ssh "$NAME" -- "pkill -f agent.sh; sleep 1; nohup bash ~/ci/agent.sh > ~/ci-agent.log 2>&1 & disown" 
else
  instabox ssh "$NAME" -- "nohup bash ~/ci/agent.sh > ~/ci-agent.log 2>&1 & disown"
fi
sleep 2
instabox ssh "$NAME" -- "pgrep -f agent.sh >/dev/null && echo 'provision: the agent is running' || { echo 'provision: THE AGENT IS NOT RUNNING'; tail ~/ci-agent.log; exit 1; }"

log "provision: done — $PROJECT builds itself on every push to \$CI_BRANCH"
