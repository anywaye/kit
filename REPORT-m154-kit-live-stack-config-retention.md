# REPORT-m154-kit-live-stack-config-retention — a cache cleanup that broke a live Compose bind mount

**Branch:** `kit-m150-default-mfa` · **Packet:** m154 · **Gate (worker):** `bash tests/fetch_test.sh` → exit 0, 32/32 PASS

---

## 1. The symptom (untouched, as ordered)

The protected local stack `site-launch-otel-collector-1` is unhealthy. Its bind
mount source —
`/Users/kaka/.cache/cafaye/kit/e248eebf67c90a098da5c1b204260c8d21c900e7/templates/compose/otel-collector.yml`
→ `/etc/otel/otel-collector.yml` — no longer exists on the host, and the
healthcheck repeats `open /etc/otel/otel-collector.yml: no such file or
directory`. No container or volume was started, stopped, recreated or
otherwise mutated in this packet; the stack was only ever observed via the
read-only state described in the brief. **Nothing in this packet recovers that
container** — the fix below protects every stack rendered after it, and the
manager decides on the manual refresh of the protected one.

## 2. The proved path (not the suggested one)

The brief suggested "an update/retention/cleanup lifecycle removed a host file".
The in-tree mechanism that makes that removal fatal is proved, and it is NOT the
one section 8 fixed:

- Section 8 (cachemount-01) proved a same-ref **replacement** retires the old
  tree instead of deleting it, and measured that a rename does not break a bind
  mount — only deleting the renamed copy does.
- What it did **not** change: every `-f` and every bind source still points
  into `<cache>/<ref>`. `compose()` built
  `-f "$STACK_DIR/templates/compose/docker-compose.yml"` and exported
  `KIT_COMPOSE_DIR="$STACK_DIR/templates/compose"`, with `STACK_DIR` always a
  cache directory for the fetched path.
- So **any** removal of the cache directory — retention sweep, cleaner, hand —
  invalidates the live mount while the containers are still up. Retiring
  protects against `fetch_stack`; it protects against nothing else. The red
  control for this packet shows the old invocation verbatim:
  `-f …/cache-live/<sha>/templates/compose/docker-compose.yml`.

A second, latent hole was found and deliberately LEFT in place (see §5): after a
same-ref re-fetch, `docker inspect` keeps reporting the PRE-rename source path
while the tree lives under `.retired/<ref>.<serial>`, so `prune_generations`'s
prefix test cannot see the mount and reaps the live tree once generations exceed
`KIT_STACK_KEEP_GENERATIONS`. The snapshot below makes that unreachable for new
stacks rather than repairing the matcher.

## 3. The fix (`templates/bin/dev.sh` only)

`up` snapshots the resolved compose subtree into **`.kit/live/<ref>`** — owned
by the service — and `compose()` runs from the snapshot whenever it is usable
for the pinned ref:

- **Content-addressed:** ref recorded in `.kit-stack-ref`; byte-compared
  (`diff -rq`) before any write; a snapshot at another ref (or a corrupt one)
  is never composed from. The common case — every `up` after the first on a
  fixed pin — touches nothing, because the snapshot directory is itself
  bind-mounted into running containers.
- **Bounded:** one directory per deliberate pin, written once per ref, never
  rewritten for a fixed ref (a ref is immutable). A snapshot that differs at an
  immutable ref is corruption and is kept aside as ONE `.stale` generation,
  never deleted. Older pins' snapshots are never reaped here — an unchanged
  service keeps its mounts across an upgrade.
- **Deterministic:** a re-sync from the same ref is byte-identical (asserted in
  the test by checksum across the cleanup).
- **Derived, not committed:** the sync writes `.kit/live/<ref>/.gitignore`
  (`*` + `!.gitignore`) alongside the bytes, editing no file the service owns.
- `resolve_stack` accepts the snapshot as a resolution source (explicit dir →
  cache → **live** → vendored → fetch), so with the cache deleted outright and
  the network forbidden, `up` still resolves to the bytes the machine already
  runs. `down`/`status`/`logs` resolve the same tree the running stack was
  rendered from, because the preference lives in `compose()`, not in a global
  set by `up`.
- No watcher, no daemon, no new command. Cache/retirement semantics
  (`fetch_stack`, `prune_generations`, `generation_keep`) are byte-untouched.

## 4. The test, and the mutation

`tests/fetch_test.sh` gains **section 9** (header now reads NINE claims; it
already listed eight under a stale "SIX" — fixed as found). A stub `docker`
records the `-f`/env the real `compose()` computed and a stub `bin/migrate`
lets the real `up` run to its end — no daemon, same answer everywhere:

1. `up` exits 0 end to end; compose's `-f` names
   `.kit/live/<sha>/templates/compose/docker-compose.yml`, and the cache home
   appears **nowhere** in the invocation (the anti-assertion — a match alone is
   satisfied by a line that also names the cache).
2. `KIT_COMPOSE_DIR` resolves into the snapshot; the snapshot is byte-identical
   (`diff -rq`) to the fetched tree and records the pin.
3. The whole cache is deleted AND the remote removed with `KIT_STACK_OFFLINE=1`:
   `up` still exits 0 from the snapshot, the tree checksums identical, the
   collector config reads back whole, and the post-cleanup invocation again
   names the snapshot.

Results: **32/32 PASS** (`bash tests/fetch_test.sh`, exit 0),
`shellcheck -S warning -e SC2317` clean on both changed scripts,
`bash -n` clean, and the gate's readiness-parse of `up()` replicated by hand
(no `healthz`/`4317`/`4318` in the `up` body).

**Mutation (file-swap, restored afterwards):** pre-fix `dev.sh` under the new
test → 21 PASS (sections 1–8 intact, nothing weakened) and 5 FAIL, every one on
a section-9 label naming the cache-vs-snapshot finding. The test proves the fix
and nothing else.

Two test-authoring defects found by running rather than reading, fixed in the
packet: `xargs cat` over an empty `find` blocks on stdin (replaced with
`find -exec cksum`), and the recorded compose paths are service-relative
(assertions match the relative snapshot path plus the cache-home absence).

## 5. Deliberately not done

- **`prune_generations`'s prefix matcher was not repaired** (§2, second hole).
  For stacks rendered after this fix nothing live is ever in the cache, so the
  blind spot is unreachable; repairing the matcher changes deletion behaviour
  with its own blast radius and belongs to its own packet with its own proof.
- **Old live snapshots are never reaped.** One tiny YAML tree per historical
  pin; reaping the old pin breaks unchanged services that kept their mounts.
- **The protected `site-launch-*` stack was not refreshed.** Its containers
  still mount the cache. The first `bin/dev up` from this tree re-renders them
  onto `.kit/live/<new-pin>`; until the manager orders that, the old mounts
  stand as they were found.
- `templates/substrate/*`, `tests/substrate_test.sh`, the m150 report, and all
  other services: untouched. No merge, no push.

## 6. Handoff / required manager gate

- Worker ran ONLY `bash tests/fetch_test.sh` + syntax/shellcheck (per brief: no
  `tests/validate.sh`, no docker, no network in the worker).
- **Required:** full `bash tests/validate.sh` on the manager gate (fetch phase,
  shellcheck sweep, and the static checks that read `dev.sh`).
- Suggested follow-up packet: the `prune_generations` prefix blind spot (§2),
  now unreachable for new stacks but still live for pre-fix ones until they
  are re-rendered.
- Commits on `kit-m150-default-mfa`: `6c98ad3` (m154 Q1, red test),
  `ad11020` (m154 Q2, fix, green) + changelog/report commit.
