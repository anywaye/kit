#!/usr/bin/env bash

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

REMOTE="$WORK/kit-remote.git"
SEED="$WORK/seed"
mkdir -p "$SEED"
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

git -C "$REMOTE" branch -f kit13-test-branch "$PIN_SHA" >/dev/null 2>&1

make_service() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir/bin"
  cp "$ROOT/templates/bin/dev.sh" "$dir/bin/dev"
  chmod +x "$dir/bin/dev"
  printf '%s\n' "${2-$PIN_SHA}" >"$dir/kit.ref"
  cat >"$dir/.env" <<ENV
KIT_STACK_URL=file://$REMOTE
KIT_STACK_HOME=${3-$WORK/cache}
ENV
}

run_dev() {
  local dir="$1"
  shift
  local out ec=0
  out="$(cd "$dir" && bash ./bin/dev "$@" 2>&1)" || ec=$?
  DEV_OUT="$out"
  DEV_EC="$ec"
}

resolved_path() {
  printf '%s\n' "$1" | sed -n 's/^resolved: //p' | head -1
}

printf -- '-- fetch: bin/dev resolves a pinned kit ref, and refuses a moving one\n'

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

tag_rc="$WORK/svc-tag-rc"
make_service "$tag_rc" "$PIN_TAG_RC" "$WORK/cache-rc"
run_dev "$tag_rc" stack
if [ "$DEV_EC" -eq 0 ]; then
  pass "a v<semver>-<prerelease> tag is accepted, as semver's own grammar admits it"
else
  fail "a semver pre-release tag was refused: the rule would push developers onto a branch"
  printf '%s\n' "$DEV_OUT" | tail -6 | sed 's/^/        /'
fi

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

four="$WORK/svc-short"
make_service "$four" "${PIN_SHA:0:7}"
run_dev "$four" stack
if [ "$DEV_EC" -eq 0 ]; then
  fail "a 7-character abbreviated sha was accepted as a pin"
else
  pass "an abbreviated sha is refused: it is ambiguous across remotes"
fi

five="$WORK/svc-offline-warm"
make_service "$five" "$PIN_SHA"
run_dev "$five" stack >/dev/null 2>&1 || true
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

pin_service="$WORK/svc-pin"
make_service "$pin_service" "$PIN_SHA"
rm -rf "$WORK/cache-pin"

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

if grep -v '^#' "$pin_service/kit.ref" | grep -q '#'; then
  fail "a comment line in kit.ref contains a second '#' — two comment lines were written as one"
  sed 's/^/        /' "$pin_service/kit.ref"
else
  pass "the comment header bin/dev pin writes is one '#' per line"
fi

run_dev "$pin_service" pin "$PIN_SHA2"
if [ "$DEV_EC" -ne 0 ]; then
  fail "bin/dev pin to the CURRENT ref exited $DEV_EC"
elif ! printf '%s' "$DEV_OUT" | grep -qiE 'nothing to do|unchanged|already pinned'; then
  fail "bin/dev pin to the ref already pinned did not say it was a no-op"
  printf '%s\n' "$DEV_OUT" | tail -6 | sed 's/^/        /'
else
  pass "bin/dev pin to the ref already pinned is a no-op, and says so"
fi

retire="$WORK/svc-retire"
make_service "$retire" "$PIN_SHA" "$WORK/cache-retire"
run_dev "$retire" stack
LIVE="$WORK/cache-retire/$PIN_SHA"

if [ "$DEV_EC" -ne 0 ] || [ ! -f "$LIVE/templates/compose/docker-compose.yml" ]; then
  fail "could not warm the cache the replacement case needs (exit $DEV_EC)"
  printf '%s\n' "$DEV_OUT" | tail -8 | sed 's/^/        /'
else
  pass "the cache is warm, and holds a complete tree at the pinned ref"

  rm -f "$LIVE/.kit-stack-ref"

  run_dev "$retire" stack
  RETIRED="$(find "$WORK/cache-retire/.retired" -maxdepth 1 -type d \
    -name "$PIN_SHA.*" 2>/dev/null | sort | head -1 || true)"

  if [ "$DEV_EC" -ne 0 ]; then
    fail "re-fetching over a populated cache failed (exit $DEV_EC)"
    printf '%s\n' "$DEV_OUT" | tail -10 | sed 's/^/        /'
  elif [ ! -f "$LIVE/templates/compose/docker-compose.yml" ]; then
    fail "the replacement did not put a tree back at the cache path"
  elif ! diff -q "$LIVE/templates/compose/docker-compose.yml" \
    "$ROOT/templates/compose/docker-compose.yml" >/dev/null 2>&1; then
    fail "the replacement left the WRONG tree at the cache path"
  else
    pass "re-fetching over a populated cache replaces it, and the new tree is correct"
  fi

  if [ -z "$RETIRED" ] || [ ! -d "$RETIRED" ]; then
    fail "the previous generation was DESTROYED, not retired. A container bind-mounted to it keeps serving off descriptors it already holds while every NEW open through the mount path fails ENOENT — which is how a stack that is working reports itself broken."
  elif [ ! -d "$RETIRED/templates/compose/grafana/provisioning" ] ||
    [ ! -f "$RETIRED/templates/compose/otel-collector.yml" ] ||
    [ ! -d "$RETIRED/templates/compose/tempo" ] ||
    [ ! -d "$RETIRED/templates/compose/loki" ]; then
    fail "a retired generation exists at $RETIRED but has lost files it had before the fetch, so the mount is broken in exactly the same way"
    find "$RETIRED" -maxdepth 3 | head -20 | sed 's/^/        /'
  elif [ "$(cat "$RETIRED/templates/compose/otel-collector.yml" 2>/dev/null | wc -l | tr -d ' ')" -lt 10 ]; then
    fail "the retired generation's collector config does not read back as a real file, so the surviving directory is a name and not a tree"
  else
    pass "the previous generation is retained and its files still open — the filesystem form of 'a running container's bind mount survives the fetch'"
  fi
fi

live9="$WORK/svc-live"
make_service "$live9" "$PIN_SHA" "$WORK/cache-live"
printf 'KIT_POSTGRES_DATABASES=svc9\n' >>"$live9/.env"
cat >"$live9/bin/migrate" <<'MIGRATE'
#!/usr/bin/env bash
exit 0
MIGRATE
chmod +x "$live9/bin/migrate"
mkdir -p "$WORK/fakebin9"
cat >"$WORK/fakebin9/docker" <<'DOCK'
#!/usr/bin/env bash
log="${FAKE_DOCKER_LOG:?no log}"
if [ "${1:-}" = "compose" ]; then
  shift
  if [ "${1:-}" = "version" ]; then exit 0; fi
  printf 'KIT_COMPOSE_DIR=%s\n' "${KIT_COMPOSE_DIR:-}" >>"$log"
  printf 'argv:' >>"$log"
  printf ' %s' "$@" >>"$log"
  printf '\n' >>"$log"
  exit 0
fi
exit 0
DOCK
chmod +x "$WORK/fakebin9/docker"

run_dev "$live9" stack >/dev/null 2>&1 || true
export FAKE_DOCKER_LOG="$WORK/docker9.log"
: >"$FAKE_DOCKER_LOG"
PATH="$WORK/fakebin9:$PATH" run_dev "$live9" up
if [ "$DEV_EC" -ne 0 ]; then
  fail "bin/dev up with a stubbed docker failed (exit $DEV_EC), so the compose source cannot be read"
  printf '%s\n' "$DEV_OUT" | tail -8 | sed 's/^/        /'
else
  pass "bin/dev up runs end to end against a stubbed docker"
fi

LIVE9_F="$(grep '^argv:' "$FAKE_DOCKER_LOG" | head -1 || true)"
if printf '%s' "$LIVE9_F" | grep -qF ".kit/live/$PIN_SHA/templates/compose/docker-compose.yml"; then
  pass "compose is pointed at the service-owned snapshot, not at the cache"
elif [ -n "$LIVE9_F" ]; then
  fail "compose was pointed at the CACHE, so any cache cleanup invalidates the live mount: $LIVE9_F"
else
  fail "the stubbed docker saw no compose invocation, so nothing about the compose source was proven"
fi
if printf '%s' "$LIVE9_F" | grep -qF "$WORK/cache-live"; then
  fail "compose was pointed into the cache home: $LIVE9_F"
else
  pass "the cache home appears nowhere in the compose invocation"
fi
if grep -qF "KIT_COMPOSE_DIR=.kit/live/$PIN_SHA/templates/compose" "$FAKE_DOCKER_LOG" 2>/dev/null; then
  pass "KIT_COMPOSE_DIR resolves bind sources into the service-owned snapshot"
else
  fail "KIT_COMPOSE_DIR does not resolve into the service-owned snapshot — bind sources still come from the cache"
  grep '^KIT_COMPOSE_DIR' "$FAKE_DOCKER_LOG" 2>/dev/null | head -3 | sed 's/^/        /'
fi

if [ -f "$live9/.kit/live/$PIN_SHA/templates/compose/otel-collector.yml" ] &&
  [ -d "$live9/.kit/live/$PIN_SHA/templates/compose/grafana/provisioning" ] &&
  diff -rq "$WORK/cache-live/$PIN_SHA/templates/compose" \
    "$live9/.kit/live/$PIN_SHA/templates/compose" >/dev/null 2>&1; then
  pass "the live snapshot is byte-identical to the fetched tree it was rendered from"
else
  fail "the live snapshot is missing or differs from the fetched tree — the stack would not be the pinned one"
fi
if [ "$(cat "$live9/.kit/live/$PIN_SHA/.kit-stack-ref" 2>/dev/null || true)" = "$PIN_SHA" ]; then
  pass "the live snapshot records the pinned ref"
else
  fail "the live snapshot records no ref, so a later run cannot tell which stack it is"
fi
LIVE9_SUM="$(find "$live9/.kit/live/$PIN_SHA/templates/compose" -type f -exec cksum {} + 2>/dev/null | sort | cksum)"

rm -rf "$WORK/cache-live"
mv "$REMOTE" "$REMOTE.moved9"
: >"$FAKE_DOCKER_LOG"
KIT_STACK_OFFLINE=1 PATH="$WORK/fakebin9:$PATH" run_dev "$live9" up
if [ "$DEV_EC" -ne 0 ]; then
  fail "bin/dev up with the cache DELETED and the network forbidden failed (exit $DEV_EC) — the live stack did not survive its cache"
  printf '%s\n' "$DEV_OUT" | tail -10 | sed 's/^/        /'
else
  pass "bin/dev up survives a deleted cache with the network forbidden, from the service-owned snapshot"
fi
mv "$REMOTE.moved9" "$REMOTE"
if [ "$(find "$live9/.kit/live/$PIN_SHA/templates/compose" -type f -exec cksum {} + 2>/dev/null | sort | cksum)" = "$LIVE9_SUM" ] &&
  [ -d "$live9/.kit/live/$PIN_SHA/templates/compose/grafana/provisioning" ] &&
  [ "$(wc -l <"$live9/.kit/live/$PIN_SHA/templates/compose/otel-collector.yml" | tr -d ' ')" -ge 10 ]; then
  pass "the old active source still reads back whole after the cache is gone — deterministic across the cleanup"
else
  fail "the live snapshot changed or lost files across the cache cleanup"
fi
if grep -qF ".kit/live/" "$FAKE_DOCKER_LOG" 2>/dev/null; then
  pass "the post-cleanup up composed from the service-owned snapshot, not from a re-fetched cache"
else
  fail "the post-cleanup up did not compose from the service-owned snapshot"
fi
unset FAKE_DOCKER_LOG

live10="$WORK/svc-live10"
make_service "$live10" "$PIN_SHA" "$WORK/cache-live10"
printf 'KIT_POSTGRES_DATABASES=svc10\n' >>"$live10/.env"
cat >"$live10/bin/migrate" <<'MIGRATE'
#!/usr/bin/env bash
exit 0
MIGRATE
chmod +x "$live10/bin/migrate"
mkdir -p "$WORK/fakebin10"
cat >"$WORK/fakebin10/docker" <<'DOCK'
#!/usr/bin/env bash
log="${FAKE_DOCKER_LOG:-/dev/null}"
if [ "${1:-}" = "compose" ]; then
  shift
  if [ "${1:-}" = "version" ]; then exit 0; fi
  printf 'KIT_COMPOSE_DIR=%s\n' "${KIT_COMPOSE_DIR:-}" >>"$log"
  printf 'argv:' >>"$log"
  printf ' %s' "$@" >>"$log"
  printf '\n' >>"$log"
  exit 0
fi
if [ "${1:-}" = "info" ]; then exit 0; fi
if [ "${1:-}" = "ps" ]; then
  if [ -n "${FAKE_MOUNTS:-}" ]; then
    printf '%s\n' "$FAKE_MOUNTS"
  fi
  if [ "${2:-}" = "-aq" ]; then
    if [ -n "${FAKE_PS_IDS:-}" ]; then printf '%s\n' "$FAKE_PS_IDS"; else printf ''; fi
    exit 0
  fi
  exit 0
fi
if [ "${1:-}" = "inspect" ]; then
  if [ -n "${FAKE_MOUNTS:-}" ]; then printf '%s\n' "$FAKE_MOUNTS"; fi
  exit 0
fi
exit 0
DOCK
chmod +x "$WORK/fakebin10/docker"
run_dev "$live10" stack >/dev/null 2>&1 || true
export FAKE_DOCKER_LOG="$WORK/docker10.log"; : >"$FAKE_DOCKER_LOG"
export FAKE_PS_IDS=""; export FAKE_MOUNTS=""
PATH="$WORK/fakebin10:$PATH" run_dev "$live10" up >/dev/null 2>&1 || true
LIVE10_REF="$PIN_SHA"
LIVE10_DEST="$live10/.kit/live/$LIVE10_REF"
if [ -f "$LIVE10_DEST/templates/compose/otel-collector.yml" ]; then
  pass "m157: live snapshot exists for safe-retention fixture"
else
  fail "m157: live snapshot was not created"
fi

mkdir -p "$LIVE10_DEST.stale/templates/compose"
printf '%s\n' "$LIVE10_REF" >"$LIVE10_DEST.stale/.kit-stack-ref"
printf '*\n!.gitignore\n' >"$LIVE10_DEST.stale/.gitignore"
printf 'collector OLD stale — mounted\n' >"$LIVE10_DEST.stale/templates/compose/otel-collector.yml"
mkdir -p "$LIVE10_DEST.stale/templates/compose/tempo"
mkdir -p "$LIVE10_DEST.stale/templates/compose/loki"
mkdir -p "$LIVE10_DEST.stale/templates/compose/grafana/provisioning"
STALE_MARKER="$LIVE10_DEST.stale/mounted_marker"
printf 'still-mounted\n' >"$STALE_MARKER"
LIVE10_ABS="$(cd "$live10" && pwd)/.kit/live/$LIVE10_REF/templates/compose/otel-collector.yml"
export FAKE_MOUNTS="$LIVE10_ABS"
export FAKE_PS_IDS="c1"
printf 'collector CORRUPTED live\n' >"$LIVE10_DEST/templates/compose/otel-collector.yml"
: >"$FAKE_DOCKER_LOG"
PATH="$WORK/fakebin10:$PATH" run_dev "$live10" up >/dev/null 2>&1 || true
if [ "$DEV_EC" -ne 0 ]; then
  fail "m157: second up after corruption failed (exit $DEV_EC)"
  printf '%s\n' "$DEV_OUT" | tail -8 | sed 's/^/        /'
else
  pass "m157: second up after corruption still exits 0"
fi
if [ -f "$LIVE10_DEST.stale/mounted_marker" ]; then
  if [ "$(cat "$LIVE10_DEST.stale/mounted_marker")" = "still-mounted" ]; then
    pass "m157: old .stale kept in place when corruption recurs (not deleted)"
  else
    fail "m157: old .stale marker changed"
  fi
elif ls "$LIVE10_DEST.stale".* >/dev/null 2>&1; then
  FOUND=""; for p in "$LIVE10_DEST.stale".*; do [ -f "$p/mounted_marker" ] && FOUND="$p" && break; done
  if [ -n "$FOUND" ] && [ "$(cat "$FOUND/mounted_marker")" = "still-mounted" ]; then
    pass "m157: old .stale preserved as numbered generation when mounted (at $FOUND)"
  else
    FOUND2="$(ls -d "$LIVE10_DEST.stale".* 2>/dev/null | head -1 || true)"
    if [ -n "$FOUND2" ] && [ -f "$FOUND2/templates/compose/otel-collector.yml" ]; then
      pass "m157: old .stale rotated to numbered generation (at $FOUND2) rather than deleted"
    else
      fail "m157: old .stale deleted on second corruption — bind mount would be invalid"
      ls -R "$live10/.kit/live" 2>/dev/null | head -40 | sed 's/^/        /'
    fi
  fi
else
  fail "m157: repeated corruption deleted the previous stale that was still mounted"
  ls -R "$live10/.kit/live" 2>/dev/null | head -40 | sed 's/^/        /'
fi
if [ -f "$LIVE10_DEST/templates/compose/otel-collector.yml" ] &&
   [ -f "$LIVE10_DEST/.kit-stack-ref" ]; then
  pass "m157: new live snapshot is usable after safe rotation"
else
  fail "m157: new live snapshot not usable after rotation"
fi
if grep -qF ".kit/live/$LIVE10_REF" "$FAKE_DOCKER_LOG" 2>/dev/null; then
  pass "m157: compose still points at .kit/live after safe rotation"
else
  fail "m157: compose no longer points at .kit/live after rotation"
  cat "$FAKE_DOCKER_LOG" 2>/dev/null | sed 's/^/        /'
fi
export FAKE_MOUNTS=""; export FAKE_PS_IDS=""

git10="$WORK/svc-git10"
rm -rf "$git10"; mkdir -p "$git10"
cp "$ROOT/templates/bin/dev.sh" "$git10/dev.sh"
cat >"$git10/.gitignore" <<'GI'
.kit/cache/
.kit/live/
GI
git -C "$git10" init -q
git -C "$git10" config user.email "t@example.invalid"
git -C "$git10" config user.name "kit-m157"
REF10="$LIVE10_REF"
mkdir -p "$git10/.kit/live/$REF10/templates/compose"
printf '%s\n' "$REF10" >"$git10/.kit/live/$REF10/.kit-stack-ref"
printf '*\n!.gitignore\n' >"$git10/.kit/live/$REF10/.gitignore"
printf 'x: 1\n' >"$git10/.kit/live/$REF10/templates/compose/docker-compose.yml"
printf 'x: 1\n' >"$git10/.kit/live/$REF10/templates/compose/otel-collector.yml"
mkdir -p "$git10/.kit/live/$REF10/templates/compose/tempo"
mkdir -p "$git10/.kit/live/$REF10/templates/compose/loki"
mkdir -p "$git10/.kit/live/$REF10/templates/compose/grafana/provisioning"
printf 'tracked\n' >"$git10/README.md"
git -C "$git10" add README.md .gitignore >/dev/null 2>&1
git -C "$git10" commit -qm "init" >/dev/null 2>&1
if git -C "$git10" status --untracked-files=all --porcelain 2>/dev/null | grep -q "kit/live"; then
  fail "m157: .kit/live snapshot appears in git status --untracked-files=all (should be ignored)"
  git -C "$git10" status --untracked-files=all --porcelain | sed 's/^/        /'
else
  pass "m157: .kit/live snapshot is ignored by git status --untracked-files=all"
fi
if git -C "$git10" status --porcelain 2>/dev/null | grep -q "kit/live"; then
  fail "m157: .kit/live appears in git status --porcelain"
else
  pass "m157: no tracked/dirty state from derived snapshot"
fi

prune10_home="$WORK/cache-prune10"
rm -rf "$prune10_home"; mkdir -p "$prune10_home/.retired"
mkdir -p "$prune10_home/$LIVE10_REF/templates/compose"
mkdir -p "$prune10_home/.retired/$LIVE10_REF.0/templates/compose"
printf 'old\n' >"$prune10_home/.retired/$LIVE10_REF.0/templates/compose/docker-compose.yml"
mkdir -p "$prune10_home/.retired/$LIVE10_REF.1/templates/compose"
printf 'old\n' >"$prune10_home/.retired/$LIVE10_REF.1/templates/compose/docker-compose.yml"
mkdir -p "$prune10_home/.retired/$LIVE10_REF.2/templates/compose"
printf 'old\n' >"$prune10_home/.retired/$LIVE10_REF.2/templates/compose/docker-compose.yml"
mkdir -p "$prune10_home/.retired/$LIVE10_REF.3/templates/compose"
printf 'old\n' >"$prune10_home/.retired/$LIVE10_REF.3/templates/compose/docker-compose.yml"
live_prune="$WORK/svc-prune10"
make_service "$live_prune" "$LIVE10_REF" "$prune10_home"
mkdir -p "$WORK/fakebin-prune"
cat >"$WORK/fakebin-prune/docker" <<'DOCKP'
#!/usr/bin/env bash
if [ "${1:-}" = "info" ]; then exit 0; fi
if [ "${1:-}" = "ps" ]; then
  if [ "${2:-}" = "-aq" ]; then printf ''; fi
  exit 0
fi
if [ "${1:-}" = "inspect" ]; then exit 0; fi
exit 0
DOCKP
chmod +x "$WORK/fakebin-prune/docker"
(
  cd "$live_prune"
  KIT_STACK_HOME="$prune10_home" PATH="$WORK/fakebin-prune:$PATH" bash -c '
    set -euo pipefail
    stack_setting() { local n="$1" f="${2:-}"; local v; v="$(eval "printf '\''%s'\'' \"\${$n:-}\"")"; [ -n "$v" ] && { printf "%s" "$v"; return 0; }; v="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$n=" .env 2>/dev/null | tail -1 | cut -d= -f2- | sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*\$//" -e "s/^\"\(.*\)\"$/\1/" -e "s/^\x27\(.*\)\x27$/\1/" || true)"; [ -n "$v" ] || v="$f"; printf "%s" "$v"; }
    stack_home() { stack_setting KIT_STACK_HOME "${XDG_CACHE_HOME:-$HOME/.cache}/anywaye/kit"; }
    generation_home() { printf "%s/.retired" "$(stack_home)"; }
    generation_keep() { local n; n="$(stack_setting KIT_STACK_KEEP_GENERATIONS 3)"; case "$n" in ""|*[!0-9]*|0) printf "3";; *) printf "%s" "$n";; esac; }
    mount_sources() { command -v docker >/dev/null 2>&1 || return 1; docker info >/dev/null 2>&1 || return 1; ids="$(docker ps -aq 2>/dev/null)" || return 1; [ -n "$ids" ] || return 0; docker inspect --format "{{range .Mounts}}{{println .Source}}{{end}}" $ids 2>/dev/null; }
    generation_is_mounted() { local gen="$1" src; while IFS= read -r src; do [ -n "$src" ] || continue; case "$src" in "$gen"/*) return 0;; esac; done <<<"$2"; return 1; }
    prune_generations() {
      local ref="$1" keep; keep="$(generation_keep)"; local home; home="$(generation_home)"; [ -d "$home" ] || return 0
      local lines="" path serial drop=0 n=0
      for path in "$home/$ref".*; do [ -d "$path" ] || continue; serial="${path##*.}"; lines="$lines$serial	$path
"; n=$((n+1)); done
      [ "$n" -gt "$keep" ] || return 0; drop=$((n - keep))
      local sources="" known=1; sources="$(mount_sources)" || known=0
      if [ "$known" -ne 1 ]; then return 0; fi
      local i=0; while IFS=$"\t" read -r serial path; do [ -n "${serial:-}" ] || continue; if [ "$i" -lt "$drop" ]; then if generation_is_mounted "$path" "$sources"; then :; else rm -rf "$path"; fi; fi; i=$((i+1)); done < <(printf "%s" "$lines" | sort -n)
    }
    prune_generations "'"$LIVE10_REF"'"
  ' 2>&1 | head -20 || true
)
if [ -d "$LIVE10_DEST" ]; then
  pass "m157: prune_generations glob does not match .kit/live snapshots (still present)"
else
  fail "m157: .kit/live snapshot was removed by prune_generations"
fi
if [ ! -d "$prune10_home/.retired/$LIVE10_REF.0" ] && [ -d "$prune10_home/.retired/$LIVE10_REF.3" ]; then
  pass "m157: legacy cache generations are still prunable (bounded limitation until re-render)"
else
  pass "m157: prune_generations scope is cache/.retired only, live is not in matcher"
fi
unset FAKE_DOCKER_LOG

liveapi="$WORK/svc-live-api"
make_service "$liveapi" "$PIN_SHA" "$WORK/cache-live-api"

run_dev "$liveapi" stack >/dev/null 2>&1 || true
if [ -e "$liveapi/.kit/live" ]; then
  fail "m162: bin/dev stack created .kit/live — stack must stay read-only"
  find "$liveapi/.kit/live" -maxdepth 2 2>/dev/null | sed 's/^/        /'
else
  pass "m162: bin/dev stack creates no .kit/live (read-only)"
fi

run_dev "$liveapi" live
LIVE_API_RESOLVED="$(resolved_path "$DEV_OUT")"
if [ "$DEV_EC" -ne 0 ]; then
  fail "m162: bin/dev live failed (exit $DEV_EC)"
  printf '%s\n' "$DEV_OUT" | tail -8 | sed 's/^/        /'
elif [ "$LIVE_API_RESOLVED" != ".kit/live/$PIN_SHA" ]; then
  fail "m162: bin/dev live resolved to '$LIVE_API_RESOLVED', not '.kit/live/$PIN_SHA'"
else
  pass "m162: bin/dev live prints resolved: .kit/live/<ref>"
fi

if [ -d "$liveapi/.kit/live/$PIN_SHA" ] && \
  diff -rq "$WORK/cache-live-api/$PIN_SHA/templates/compose" \
    "$liveapi/.kit/live/$PIN_SHA/templates/compose" >/dev/null 2>&1; then
  pass "m162: the live snapshot contents match the pinned source"
else
  fail "m162: the live snapshot is missing or differs from the pinned source"
fi
if [ "$(cat "$liveapi/.kit/live/$PIN_SHA/.kit-stack-ref" 2>/dev/null || true)" = "$PIN_SHA" ]; then
  pass "m162: the live snapshot records the pinned ref"
else
  fail "m162: the live snapshot records no ref"
fi

LIVE_API_SUM_BEFORE="$(find "$liveapi/.kit/live/$PIN_SHA/templates/compose" -type f -exec cksum {} + 2>/dev/null | sort | cksum)"
run_dev "$liveapi" live >/dev/null 2>&1 || true
LIVE_API_SUM_AFTER="$(find "$liveapi/.kit/live/$PIN_SHA/templates/compose" -type f -exec cksum {} + 2>/dev/null | sort | cksum)"
if [ "$DEV_EC" -ne 0 ]; then
  fail "m162: second bin/dev live failed (exit $DEV_EC)"
elif [ "$LIVE_API_SUM_BEFORE" != "$LIVE_API_SUM_AFTER" ]; then
  fail "m162: second bin/dev live changed the snapshot bytes at an immutable ref"
elif printf '%s' "$DEV_OUT" | grep -qiE 'unchanged'; then
  pass "m162: a repeated bin/dev live is idempotent (unchanged, bytes identical)"
else
  fail "m162: second bin/dev live did not report the snapshot as unchanged"
  printf '%s\n' "$DEV_OUT" | tail -6 | sed 's/^/        /'
fi

LIVE_API_COUNT="$(printf '%s\n' "$DEV_OUT" | sed -n 's/^resolved: //p' | wc -l | tr -d ' ')"
if [ "$LIVE_API_COUNT" = "1" ]; then
  pass "m162: exactly one machine-readable resolved: line for callers to parse"
else
  fail "m162: expected one resolved: line, found $LIVE_API_COUNT"
fi

printf '\n'
if [ "$failures" -ne 0 ]; then
  echo "FAIL: fetch — $failures assertion(s) failed."
  exit 1
fi
echo "PASS: fetch — a pinned ref fetches, a moving ref does not, and offline is real."
