#!/usr/bin/env bash
#
# snapshot.sh — build a FROZEN copy of the fleet, so a baseline is a measurement
# and not a rumour.
#
#   bash reports/account-scope-contract-01/snapshot.sh <dest>
#
# WHY THIS EXISTS, and it is the packet's own lesson applied to itself
#
#   Three sessions share this machine and two of them are working IN the fleet.
#   `pantry`'s master moved twice while this packet was being written — once
#   between two measurements of the SAME command, forty minutes apart — so
#   "the current baseline" measured against live working trees is a number that
#   changes while the report is being typed. Every number in
#   REPORT-kit-account-scope-contract-01.md that is presented as a baseline is
#   measured against a copy this script built, and the commit SHAs are printed
#   by the script and quoted in the report. A number whose tree cannot be named
#   is not re-derivable, and `DEBT.md` D18's own standing example is two numbers
#   in that file that no longer re-derive because no method was recorded.
#
#   THE COPY IS A GIT REPOSITORY, and that is not incidental. The runner's rule 1
#   — a repository that stops declaring is red — is derived from `git cat-file -e
#   HEAD:account_scope.yml`, so a copy without history answers "I could not
#   check" for all nine repositories and the runner correctly reports itself
#   blind. That is the runner working; it is also the reason this script commits
#   what it unpacked rather than only unpacking it.
#
#   `git archive` reads a repository and writes nothing in it, so the fleet's own
#   trees are untouched by this. That is the same property `DEBT.md` relies on
#   when it re-derives a historical self-test.
set -euo pipefail

DEST="${1:?usage: snapshot.sh <dest>}"
KIT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FLEET="${KIT_FLEET:-$KIT_ROOT/..}"

rm -rf "$DEST"
mkdir -p "$DEST"

printf 'snapshot of the fleet at %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'source fleet: %s\n\n' "$FLEET"
printf '%-9s %-40s %s\n' repo commit declaration-in-HEAD

for repo in identity courier guard site parlor pantry caf kit core; do
  src="$FLEET/$repo"
  if [ ! -d "$src/.git" ] && [ ! -f "$src/.git" ]; then
    echo "snapshot.sh: $repo is not a git checkout at $src" >&2
    exit 1
  fi
  sha="$(git -C "$src" rev-parse HEAD)"
  mkdir -p "$DEST/$repo"
  git -C "$src" archive "$sha" | tar -x -C "$DEST/$repo"
  # The copy gets its own repository, so `git cat-file -e HEAD:account_scope.yml`
  # answers the way the real tree's does. `-c` inline config, because a global
  # `user.email` is not something this script may assume.
  git -C "$DEST/$repo" init -q
  git -C "$DEST/$repo" add -A
  git -C "$DEST/$repo" \
    -c user.name=snapshot -c user.email=snapshot@localhost \
    commit -q -m "snapshot of $repo at $sha"
  if git -C "$DEST/$repo" cat-file -e HEAD:account_scope.yml 2>/dev/null; then
    declared=yes
  else
    declared=no
  fi
  printf '%-9s %-40s %s\n' "$repo" "$sha" "$declared"
done

printf '\nBuilt %s. Point the runner at it with --repos-dir.\n' "$DEST"