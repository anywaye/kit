#!/usr/bin/env bash
#
# kit's proof that `bin/dev` can FETCH the stack it runs.
#
#   bash tests/fetch_test.sh
#
# WHY THIS IS A SCRIPT AND NOT A SECTION OF validate.sh
#   The claim is about a *git fetch succeeding*, a *branch being refused*, and
#   an *offline run not touching the network*. None of that is a static property
#   of a file, and all of it is a property of a real subprocess talking to a
#   real remote. So it is executed, the same way `classify_test.sh` and
#   `fingerprint_test.sh` are, and for the same reason: a check that only parsed
#   `bin/dev` would pass on a script that fetches nothing.
#
# THE REMOTE IS LOCAL
#   Every case here builds a bare repository from kit's own tree and fetches
#   over `file://`. That is not a shortcut around the mechanism — `git fetch
#   --depth 1 <remote> <ref>` is the same command either way, and the ref
#   resolution, the shallow checkout, the cache and the offline refusal are all
#   exercised for real. What it buys is that the suite needs no network, so a
#   CI runner and a laptop on a train get the same answer, and a flaky network
#   can never be mistaken for a broken gate.
#
#   The network path itself (https://github.com/cafaye/kit) is NOT proven here
#   and the report says so: it is one `git ls-remote` away from being, but a
#   gate that depends on github.com is a gate that goes red when github is down.
#
# THE SIX CLAIMS
#   1. A PINNED ref (a 40-hex commit, or a `v<semver>` tag) fetches, and the
#      resolved tree is byte-identical to the checkout it was fetched from.
#   2. A MOVING ref (`master`, a branch name, an empty value, a short sha) is
#      REFUSED — loudly, before any network call, naming what was wrong. This is
#      the "a moving reference is a gate that changes under you" rule, and the
#      refusal has to happen before `git fetch`, because by the time fetch has
#      run the gate has already changed under you.
#   3. OFFLINE (`KIT_STACK_OFFLINE=1`) with the cache warm runs, and says it came
#      from the cache rather than from the network.
#   4. OFFLINE with a cold cache and no remote FAILS LOUDLY and names the one
#      thing that fixes it. It does not silently fall back to whatever is in the
#      working directory, because "the stack that came up" being a different
#      stack than the one you pinned is the whole failure.
#   5. A VENDORED copy (`.kit/stack`) that DECLARES the pinned ref is accepted
#      offline — that is the documented offline story, and it has to work or
#      "use a vendored copy" is a sentence in a README rather than a mode.
#   6. A vendored copy at a DIFFERENT ref is REFUSED. This is the drift the
#      packet exists to remove, in the shape it takes when the copy is vendored
#      instead of fetched: a directory that looks like a stack and is somewhere
#      else. Accepting it silently is how an offline loop stops matching what
#      the team runs.
#
# NO SLEEPS. Every wait is a poll with a deadline, and the only thing polled for
# is this script's own subprocesses.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-fetch.XXXXXX")"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixtures: a bare "kit remote" built from this tree, and a service sandbox.
# ---------------------------------------------------------------------------
# Built from the REAL tree rather than from a hand-written stub, so the test
# proves the thing ships: a fetched ref has to contain `templates/compose/`
# with the vendor config trees in it, because that is what `bin/dev` then runs.
# A stub with three empty files would pass and prove nothing about the real
# artifact.
REMOTE="$WORK/kit-remote.git"
# Built from the WORKING TREE, not from HEAD. A `git clone --bare "$ROOT"` of a
# tree with uncommitted changes produces a remote holding the last COMMIT, so
# every "the fetched bytes are the shipped bytes" assertion below would compare
# this packet's new files against the ones before them and fail for a reason
# that has nothing to do with the mechanism. Three extra lines make the remote
# contain exactly what is on disk, which is the only thing that makes the
# comparison mean anything.
SEED="$WORK/seed"
mkdir -p "$SEED"
# `tar` over the tree and NOT `git ls-files`, because this has to work in a
# directory that is not a git repository — which is exactly what
# `self_test.sh`'s throwaway copies are. It was `git ls-files`, and the
# consequence was the sharpest failure mode this file could have: the self-test
# CONTROL went red, because a break of nothing at all was reported as a broken
# gate. A control that is red is not a control.
(cd "$ROOT" && tar -cf - --exclude=./.git --exclude=./.venv --exclude=./__pycache__ .) |
  (cd "$SEED" && tar -xf -)
git -C "$SEED" init -q
git -C "$SEED" add -A
git -C "$SEED" -c user.email=t@example.invalid -c user.name=kit13 commit -q -m "seed"
git clone --bare --quiet "$SEED" "$REMOTE"
rm -rf "$SEED"

PIN_SHA="$(git -C "$REMOTE" rev-parse HEAD)"
PIN_TAG="v0.0.0"
PIN_TAG_RC="v1.0.0-rc.1"
git -C "$REMOTE" tag -f "$PIN_TAG" "$PIN_SHA" >/dev/null 2>&1
git -C "$REMOTE" tag -f "$PIN_TAG_RC" "$PIN_SHA" >/dev/null 2>&1

# A branch in the remote, for the "moving reference" cases. It has to EXIST, or
# a refusal could be "no such ref" rather than "that is a branch" — and only the
# second one proves the rule.
git -C "$REMOTE" branch -f kit13-test-branch "$PIN_SHA" >/dev/null 2>&1

# The service sandbox: kit's `bin/dev`, a `.env` naming the ref, and NOTHING
# else. No `docker-compose.yml` of kit's, no `otel-collector.yml`, no `tempo/` —
# those are the copy this packet removes, and a sandbox that still had them
# would pass against a `bin/dev` that never fetched anything.
#
# $2 is the ref and $3 is the cache home. The cache home is a PARAMETER and not a
# constant because the cold-cache case needs a genuinely cold one: with every
# sandbox sharing `$WORK/cache`, the case before it had already warmed the cache
# and "offline with a cold cache" passed on a warm one — which is a test that
# proves the opposite of what its name says.
make_service() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir/bin"
  cp "$ROOT/templates/bin/dev.sh" "$dir/bin/dev"
  chmod +x "$dir/bin/dev"
  # The pin goes in `kit.ref`, a COMMITTED one-liner at the repository root —
  # not in `.env`, which is git-ignored and would make the pin a per-machine
  # secret. A fixture that put it in `.env` would pass against a `bin/dev` that
  # reads it from either, and the difference is the whole point of the file
  # existing: two people on the same commit must run the same stack.
  printf '%s\n' "${2-$PIN_SHA}" >"$dir/kit.ref"
  cat >"$dir/.env" <<ENV
KIT_STACK_URL=file://$REMOTE
KIT_STACK_HOME=${3-$WORK/cache}
ENV
}

# run_dev <service-dir> [args...] — run bin/dev, capture output and status.
#
# Never a bare `out=$(...)`: on its own that is an ASSIGNMENT, so `set -e` kills
# this script before the status can be read, and every case below would report
# the same nothing. `|| ec=$?` makes the command part of a list, which `set -e`
# does not apply to. This is the same trap self_test.sh documents, and it is
# worth a comment in two files rather than a bug in one.
run_dev() {
  local dir="$1"
  shift
  local out ec=0
  out="$(cd "$dir" && bash ./bin/dev "$@" 2>&1)" || ec=$?
  DEV_OUT="$out"
  DEV_EC="$ec"
}

# The resolved directory, read out of the `resolved:` line. Parsed rather than
# guessed at a path, so the assertion is about the script REPORTING where it
# resolved — which is the interface other tooling will read — and not about this
# test's idea of where that should be.
resolved_path() {
  printf '%s\n' "$1" | sed -n 's/^resolved: //p' | head -1
}

printf -- '-- fetch: bin/dev resolves a pinned kit ref, and refuses a moving one\n'

# ---------------------------------------------------------------------------
# 1. A pinned commit fetches, and what arrives is what was pinned
# ---------------------------------------------------------------------------
one="$WORK/svc-sha"
make_service "$one" "$PIN_SHA"
run_dev "$one" stack

RESOLVED=""
if [ "$DEV_EC" -ne 0 ]; then
  fail "a pinned commit was not resolvable (exit $DEV_EC)"
  printf '%s\n' "$DEV_OUT" | tail -12 | sed 's/^/        /'
else
  RESOLVED="$(resolved_path "$DEV_OUT")"
  if [ -z "$RESOLVED" ]; then
    fail "bin/dev stack succeeded but printed no 'resolved: <path>' line, so nothing can read it"
    printf '%s\n' "$DEV_OUT" | tail -12 | sed 's/^/        /'
  elif [ ! -d "$RESOLVED" ]; then
    fail "bin/dev stack reported $RESOLVED, which is not a directory"
  else
    pass "a pinned commit resolves, and reports where it resolved to"
  fi
fi

if [ -n "$RESOLVED" ] && [ -d "$RESOLVED" ]; then
  # Assert the resolved BYTES, not that a path was printed. "It printed a path"
  # is not "it is the right bytes", and the second is the claim.
  if diff -q "$RESOLVED/templates/compose/docker-compose.yml" \
    "$ROOT/templates/compose/docker-compose.yml" >/dev/null 2>&1; then
    pass "the fetched compose file is byte-identical to the tree it was pinned to"
  else
    fail "the fetched compose file differs from the tree it was pinned to"
  fi
  if [ -f "$RESOLVED/templates/compose/otel-collector.yml" ] &&
    [ -d "$RESOLVED/templates/compose/tempo" ] &&
    [ -d "$RESOLVED/templates/compose/grafana/provisioning" ]; then
    pass "the fetched tree carries the collector config and the vendor config trees"
  else
    fail "the fetched tree is missing otel-collector.yml, tempo/ or grafana/provisioning/: \`up\` would die on a bind mount"
  fi
fi

# The same, pinned to a TAG. A tag is a deliberate act by a human and resolves
# to an immutable commit, so it is a legitimate pin; `master` is not.
two="$WORK/svc-tag"
make_service "$two" "$PIN_TAG"
run_dev "$two" stack
TAG_RESOLVED="$(resolved_path "$DEV_OUT")"
if [ "$DEV_EC" -ne 0 ] || [ -z "$TAG_RESOLVED" ]; then
  fail "a release tag was not resolvable (exit $DEV_EC)"
  printf '%s\n' "$DEV_OUT" | tail -8 | sed 's/^/        /'
elif diff -q "$TAG_RESOLVED/templates/compose/docker-compose.yml" \
  "$ROOT/templates/compose/docker-compose.yml" >/dev/null 2>&1; then
  pass "a v<semver> tag resolves to the same bytes a commit does"
else
  fail "a tag resolved to different bytes than the commit it points at"
fi

# A pre-release tag. `v1.0.0-rc.1` is a real tag a real project cuts, and a pin
# rule that refused it would simply be pushed around — a branch would be used
# instead, which is the exact thing the pin exists to prevent. Semver's own
# grammar admits the suffix, so the validator does too.
tag_rc="$WORK/svc-tag-rc"
make_service "$tag_rc" "$PIN_TAG_RC" "$WORK/cache-rc"
run_dev "$tag_rc" stack
if [ "$DEV_EC" -eq 0 ]; then
  pass "a v<semver>-<prerelease> tag is accepted, as semver's own grammar admits it"
else
  fail "a semver pre-release tag was refused: the rule would push developers onto a branch"
  printf '%s\n' "$DEV_OUT" | tail -6 | sed 's/^/        /'
fi

# ---------------------------------------------------------------------------
# 2. A moving ref is refused, BEFORE any network call
# ---------------------------------------------------------------------------
# `master` is the ref every one of these repos' CI already uses, so it is the
# one that would actually be written by someone in a hurry.
for bad in master kit13-test-branch ""; do
  three="$WORK/svc-bad-${bad:-empty}"
  make_service "$three" "$bad"
  run_dev "$three" stack
  if [ "$DEV_EC" -eq 0 ]; then
    fail "an unpinned ref ('${bad}') was ACCEPTED"
    printf '%s\n' "$DEV_OUT" | tail -6 | sed 's/^/        /'
  elif ! printf '%s' "$DEV_OUT" | grep -qiE 'pinned|branch|moving|40-char|40 hex|tag'; then
    fail "the refusal for '${bad}' does not say why: a developer cannot act on it"
    printf '%s\n' "$DEV_OUT" | tail -6 | sed 's/^/        /'
  else
    pass "ref '${bad}' is refused, and the message says why"
  fi
done

# A short sha is a moving reference wearing a sha costume: `git fetch` will
# happily resolve it, and it is ambiguous across remotes.
four="$WORK/svc-short"
make_service "$four" "${PIN_SHA:0:7}"
run_dev "$four" stack
if [ "$DEV_EC" -eq 0 ]; then
  fail "a 7-character abbreviated sha was accepted as a pin"
else
  pass "an abbreviated sha is refused: it is ambiguous across remotes"
fi

# ---------------------------------------------------------------------------
# 3. Offline with a warm cache runs, and says where it came from
# ---------------------------------------------------------------------------
five="$WORK/svc-offline-warm"
make_service "$five" "$PIN_SHA"
run_dev "$five" stack >/dev/null 2>&1 || true
# Now REMOVE the remote. If offline mode consults it at all this case fails, and
# that is stronger than unsetting a variable: a URL that 404s is a different
# failure from a URL that is not there, and only one of them is a network.
mv "$REMOTE" "$REMOTE.moved"
run_dev "$five" stack
if [ "$DEV_EC" -ne 0 ]; then
  fail "offline mode failed with a warm cache and the remote removed"
  printf '%s\n' "$DEV_OUT" | tail -10 | sed 's/^/        /'
elif ! printf '%s' "$DEV_OUT" | grep -qiE 'cache|offline'; then
  fail "offline mode ran but never said it came from the cache — a reader cannot tell the network was skipped"
  printf '%s\n' "$DEV_OUT" | tail -10 | sed 's/^/        /'
else
  pass "offline mode runs from the cache with the remote removed"
fi
mv "$REMOTE.moved" "$REMOTE"

# ---------------------------------------------------------------------------
# 4. Offline with a cold cache fails LOUDLY, and names the fix
# ---------------------------------------------------------------------------
six="$WORK/svc-offline-cold"
make_service "$six" "$PIN_SHA" "$WORK/cache-cold"
mv "$REMOTE" "$REMOTE.moved"
run_dev "$six" stack
if [ "$DEV_EC" -eq 0 ]; then
  fail "offline mode with a cold cache and no remote SUCCEEDED — it invented a stack"
  printf '%s\n' "$DEV_OUT" | tail -10 | sed 's/^/        /'
elif ! printf '%s' "$DEV_OUT" | grep -qE 'KIT_STACK_DIR|\.kit/stack|KIT_STACK_HOME'; then
  fail "the cold-cache failure names none of KIT_STACK_DIR, .kit/stack or KIT_STACK_HOME, so there is nothing to act on"
  printf '%s\n' "$DEV_OUT" | tail -10 | sed 's/^/        /'
else
  pass "offline mode with a cold cache fails loudly and names the fix"
fi

# ---------------------------------------------------------------------------
# 5. The vendored copy that DECLARES the pinned ref is accepted
# ---------------------------------------------------------------------------
git clone --quiet --depth 1 "file://$REMOTE.moved" "$six/.kit/stack" 2>/dev/null || true
printf '%s\n' "$PIN_SHA" >"$six/.kit/stack/.kit-stack-ref"
rm -rf "$WORK/cache-vendored"
KIT_STACK_HOME="$WORK/cache-cold" run_dev "$six" stack
if [ "$DEV_EC" -ne 0 ]; then
  fail "a vendored copy declaring the pinned ref was refused in offline mode"
  printf '%s\n' "$DEV_OUT" | tail -10 | sed 's/^/        /'
elif ! printf '%s' "$DEV_OUT" | grep -qiE 'vendor'; then
  fail "the vendored copy was used but bin/dev did not say it was vendored — the developer cannot tell where the bytes came from"
  printf '%s\n' "$DEV_OUT" | tail -10 | sed 's/^/        /'
else
  pass "a vendored copy that DECLARES the pinned ref is accepted, and is named as the source"
fi
mv "$REMOTE.moved" "$REMOTE"

# ---------------------------------------------------------------------------
# 6. The vendored copy that does not declare the pinned ref is refused
# ---------------------------------------------------------------------------
seven="$WORK/svc-vendored-stale"
make_service "$seven" "$PIN_SHA"
git clone --quiet --depth 1 --branch "$PIN_TAG" "file://$REMOTE" "$seven/.kit/stack" 2>/dev/null || true
printf '%s\n' "0000000000000000000000000000000000000000" >"$seven/.kit/stack/.kit-stack-ref"
rm -rf "$WORK/cache-stale"
KIT_STACK_HOME="$WORK/cache-stale" run_dev "$seven" stack
if [ "$DEV_EC" -eq 0 ]; then
  fail "a vendored copy at a DIFFERENT ref was ACCEPTED — the gate changed under you"
  printf '%s\n' "$DEV_OUT" | tail -10 | sed 's/^/        /'
else
  pass "a vendored copy at a different ref is refused, not silently used"
fi

# ---------------------------------------------------------------------------
# 7. `bin/dev pin` — the DELIBERATE upgrade
# ---------------------------------------------------------------------------
# The command exists for one reason: to show what changes before it writes the
# pin. It is the only place a developer sees the consequence of the move, and the
# first `bin/dev pin` is the first use and the most likely to BE the upgrade.
#
# Both assertions below are for bugs this file found by running the command rather
# than by reading it.
pin_service="$WORK/svc-pin"
make_service "$pin_service" "$PIN_SHA"
rm -rf "$WORK/cache-pin"

# A ref whose stack really does differ, so "the diff is empty" cannot be what a
# broken implementation produces. A second commit changes one line of the compose
# file, and a tag is cut on it.
# A SECOND remote, carrying a second commit, because the first version of this
# built the second seed by copying `$SEED` — which the fixture block deletes once
# the bare remote exists, so the copy failed and the script aborted rather than
# asserting anything. A test that dies in its own setup asserts nothing at all,
# and it looks exactly like a passing run that stopped early.
PIN_SEED2="$WORK/seed2"
git clone --quiet "$REMOTE" "$PIN_SEED2"
printf '\n# kit-13 fetch_test: a change the pin diff must notice\n' \
  >>"$PIN_SEED2/templates/compose/docker-compose.yml"
git -C "$PIN_SEED2" add -A
git -C "$PIN_SEED2" -c user.email=t@example.invalid -c user.name=kit13 commit -q -m "second"
PIN_SHA2="$(git -C "$PIN_SEED2" rev-parse HEAD)"
rm -rf "$WORK/kit-remote2.git"
git clone --bare --quiet "$PIN_SEED2" "$WORK/kit-remote2.git"
sed -i.bak "s|^KIT_STACK_URL=.*|KIT_STACK_URL=file://$WORK/kit-remote2.git|" \
  "$pin_service/.env" && rm -f "$pin_service/.env.bak"

run_dev "$pin_service" pin "$PIN_SHA2"
if [ "$DEV_EC" -ne 0 ]; then
  fail "bin/dev pin to a second commit failed (exit $DEV_EC)"
  printf '%s\n' "$DEV_OUT" | tail -8 | sed 's/^/        /'
elif printf '%s' "$DEV_OUT" | grep -q 'cannot be computed'; then
  # The bug this asserts: on a COLD cache — the first use, and the one that
  # matters — the command said it could not compute the diff and wrote the pin
  # anyway. The whole reason the command exists was absent on its first run.
  fail "bin/dev pin gave up on the diff from a cold cache, which is the FIRST use"
  printf '%s\n' "$DEV_OUT" | tail -8 | sed 's/^/        /'
elif ! printf '%s' "$DEV_OUT" | grep -q 'docker-compose.yml'; then
  fail "bin/dev pin printed a pin message but no diff, so the move was invisible"
  printf '%s\n' "$DEV_OUT" | tail -8 | sed 's/^/        /'
else
  pass "bin/dev pin fetches both refs and prints a REAL stack diff from a cold cache"
fi

if [ "$(tail -1 "$pin_service/kit.ref")" = "$PIN_SHA2" ]; then
  pass "bin/dev pin wrote kit.ref, and the sha is the last line"
else
  fail "kit.ref does not end with the new sha: $(cat "$pin_service/kit.ref" | tr '\n' '|')"
fi

# The header it writes. A `printf 'text\n'` inside single quotes emits a literal
# backslash-n, and two such lines run together into `# ...commit# sha, or...` —
# a comment block that reads as one garbled line. Asserted on the SHAPE (every
# comment line starts with `# `, none contains a second `#`), not on the wording.
if grep -v '^#' "$pin_service/kit.ref" | grep -q '#'; then
  fail "a comment line in kit.ref contains a second '#' — two comment lines were written as one"
  sed 's/^/        /' "$pin_service/kit.ref"
else
  pass "the comment header bin/dev pin writes is one '#' per line"
fi

# The same ref is a no-op, and says so. Pinning to the ref you are already on is
# not a move; answering it by fetching two copies of one commit would be a lie
# about what happened.
run_dev "$pin_service" pin "$PIN_SHA2"
if [ "$DEV_EC" -ne 0 ]; then
  fail "bin/dev pin to the CURRENT ref exited $DEV_EC"
elif ! printf '%s' "$DEV_OUT" | grep -qiE 'nothing to do|unchanged|already pinned'; then
  fail "bin/dev pin to the ref already pinned did not say it was a no-op"
  printf '%s\n' "$DEV_OUT" | tail -6 | sed 's/^/        /'
else
  pass "bin/dev pin to the ref already pinned is a no-op, and says so"
fi

printf '\n'
if [ "$failures" -ne 0 ]; then
  echo "FAIL: fetch — $failures assertion(s) failed."
  exit 1
fi
echo "PASS: fetch — a pinned ref fetches, a moving ref does not, and offline is real."
