#!/usr/bin/env bash
#
# route.sh — the path router: changed paths in, one ROUTE= line out.
#
#   tests/route.sh [--event NAME] [--] [path ...]
#
# WHAT IT IS. A pure-bash classifier over the changed-path list. It answers
# one question — which CI tier proves this change — and it answers with a
# single line on stdout:
#
#   ROUTE=docs | tier | publish | full
#
# THE CLASSES, and what each one owes:
#   docs     prose only. CI runs `git diff --check` and nothing else, and
#            reports "docs-only; platform checks not run". No venv, no gate.
#   tier     every changed path is under templates/tier/. CI runs the tier
#            focused proof (family syntax + the gate's exact tier checks) and
#            plainly discloses every check it did not run.
#   publish  every changed path is under templates/publish/. Same shape as
#            tier, for the publish family.
#   full     everything else: platform/runtime artifacts, workflows, tests,
#            mixed families, unknown paths, empty/uncomputable lists, and any
#            non-PR event (push, schedule, workflow_dispatch). CI runs
#            `bash tests/validate.sh` with no flags — the full release proof,
#            unchanged.
#
# FAILS CLOSED. A path this script does not recognise is full. An empty list
# is full (nothing to prove a fast tier with). A mix of two fast families is
# full (no family proof covers the other). An event that is not a pull
# request is full regardless of paths: merge-queue, scheduled and manual
# runs are the release proof and are never narrowed.
#
# WHAT IT IS NOT. It never reads the tree, never installs anything, never
# calls tests/validate.sh — tests/route_test.sh asserts the last one by
# grepping this file. A router that launched the gate would be the recursion
# this packet exists to avoid: the gate proving the router proving the gate.
#
# Deterministic: argv in, ROUTE out. No git, no network, no timestamps.

set -euo pipefail

EVENT="pull_request"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --event)
      EVENT="${2:?route.sh: --event needs a value}"
      shift 2
      ;;
    --event=*)
      EVENT="${1#--event=}"
      shift
      ;;
    --)
      shift
      break
      ;;
    --*)
      echo "route.sh: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

# Non-PR events are the release proof and are never narrowed. This branch is
# why schedule and workflow_dispatch do not need a path list at all.
case "$EVENT" in
  pull_request) ;;
  *)
    echo "ROUTE=full"
    exit 0
    ;;
esac

# Empty/uncomputable: no paths, no fast tier. Fails closed by construction.
if [ "$#" -eq 0 ]; then
  echo "ROUTE=full"
  exit 0
fi

is_tier=1
is_publish=1
is_docs=1

for p in "$@"; do
  case "$p" in
    templates/tier/*) ;;
    *) is_tier=0 ;;
  esac
  case "$p" in
    templates/publish/*) ;;
    *) is_publish=0 ;;
  esac
  case "$p" in
    *.md | *.markdown | *.txt | LICENSE* | NOTICE* | AUTHORS*) ;;
    *) is_docs=0 ;;
  esac
done

# One family only: a mix is full, because no family proof covers the other.
if [ "$is_tier" -eq 1 ]; then
  echo "ROUTE=tier"
elif [ "$is_publish" -eq 1 ]; then
  echo "ROUTE=publish"
elif [ "$is_docs" -eq 1 ]; then
  echo "ROUTE=docs"
else
  echo "ROUTE=full"
fi
exit 0
