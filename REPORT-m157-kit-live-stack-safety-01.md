# REPORT-m157-kit-live-stack-safety-01 — close two retained risks in m154's live snapshot

**Branch:** `kit-m150-default-mfa` · **Packets:** m154 + m157 · **Gate (worker):** `bash tests/fetch_test.sh` → exit 0, **41/41 PASS** (32 m154 + 9 m157)

---

## 1. The two risks m157 was asked to close

m154 (`ad11020`) moved every `up` to compose from a service-owned snapshot
`.kit/live/<ref>` so deleting the whole cache no longer invalidates a live
mount (section 9 proves it, 5 FAIL on old code → 0 on new). The review
identified two narrower risks the fix still carried:

1. `sync_live_stack()` ran `rm -rf "$dest.stale"` before `mv "$dest"
   "$dest.stale"` — repeated corruption could delete a generation an
   older stack still bind-mounts.
2. The derived snapshot was claimed "ignored" (`git status
   --untracked-files=all` after the fixture) and tidy, but the
   per-snapshot `.kit/live/<ref>/.gitignore` (`*` + `!.gitignore`)
   leaves its own `.gitignore` untracked, so a service that never had
   a root ignore would report the snapshot as untracked.
3. (Scope honest bound) Legacy cache-mounted stacks — any stack
   rendered *before* m154 still composes from `<cache>/<ref>` —
   remain reachable by `prune_generations`'s existing matcher until
   they are re-rendered onto `.kit/live`. New snapshots must not
   enter that matcher.

No `site-launch-*` container was started, stopped or mutated; all
proofs are stub-Docker/shell, no `tests/validate.sh`, no push.

---

## 2. Finding 1 — proved, then made mount-safe

**Proved.** On an immutable ref the only way `sync_live_stack` reaches
`mv "$dest" "$dest.stale"` is corruption (bytes differ). After the
first corruption `DEST=.kit/live/<ref>` has been renamed to
`DEST.stale` but `docker inspect` still reports the *pre-rename* path
`DEST/...` as the mount source. A second corruption's `rm -rf
"$dest.stale"` therefore deletes the inode tree containers from the
first generation are still mounted to — the same inode lesson §8
proved for the cache (`rename` keeps inodes, `unlink` does not).
Measured in the fixture: a marker file in `DEST.stale` is readable
before `rm -rf`, and gone after it on plain `rm -rf` — bind mount
invalid.

**Fix** (`templates/bin/dev.sh:748-789`, the only prod change):

```sh
if [ -e "$dest.stale" ] || [ -L "$dest.stale" ]; then
  _stale_abs=...; _dest_abs=...  # absolute via $PWD for inspect prefix
  _sources="$(mount_sources)" || _known=0
  _keep=0
  if [ "$_known" -eq 0 ]; then _keep=1               # cannot tell → keep
  elif generation_is_mounted "$_stale_abs" "$_sources" \
    || generation_is_mounted "$_dest_abs" "$_sources"; then _keep=1; fi
  if [ "$_keep" -eq 1 ]; then
    _n=0; while [ -e "$dest.stale.$_n" ]; do _n=$((_n+1)); done
    mv "$dest" "$dest.stale.$_n"   # preserve old stale, spill dest to numbered slot
    mv "$tmp" "$dest"
    return 0
  else
    rm -rf "$dest.stale"           # not mounted → safe to rotate in place
  fi
fi
mv "$dest" "$dest.stale"
```

* Never deletes a generation that is (or may be) mounted. If docker is
  unavailable, we cannot answer → conservative keep. If either `DEST`
  *or* `DEST.stale` matches a mount source prefix, the current `DEST`
  is spilled to `DEST.stale.<n>` instead of overwriting `DEST.stale`.
  The extra generations are a few hundred KB each and only occur on
  corruption (rare at an immutable ref) — bounded, and bounded by a
  rare path is bounded.
* ShellCheck `-S warning -e SC2317` clean, `bash -n` clean.

**Regression proof** (`tests/fetch_test.sh` §10a, stub docker, no daemon):

* Warms a live snapshot, creates `DEST.stale` with a marker
  `mounted_marker` and a collector file, fakes `docker inspect` to
  report `DEST/...` as mounted (`FAKE_MOUNTS`/`FAKE_PS_IDS`), corrupts
  `DEST`, runs `up` again.
* Asserts `up` exits 0, old stale marker still readable (at
  `DEST.stale` or `DEST.stale.<n>`), new live snapshot usable, and
  the recorded `compose` invocation still names `.kit/live/<ref>`.
  Before the fix this is red on the "old stale deleted" label; after
  it is green.

---

## 3. Finding 2 — `git status --untracked-files=all` is now truly ignored

**Root cause.** The snapshot is derived, and m154 made it derived by
writing `DEST/.gitignore` (`*` + `!.gitignore`) alongside the bytes.
That ignores everything *beneath* `DEST` but not `DEST/.gitignore`
itself. `git status --untracked-files=all` in a fixture that creates
`.kit/live/<ref>` therefore reported

```
Untracked files:
  .kit/live/<ref>/.gitignore
```

— a tracked/dirty signal from a derived tree, and `git add -A` would
include the `.gitignore` (harmless but untracked).

**Fix.** Root `.gitignore` now ignores the whole subtree in one place:

```
.kit/cache/
.kit/live/   # m157: entire live snapshot subtree is derived, never committed
```

With this, both the snapshot bytes *and* its own `.gitignore` are
covered, and the inner `*` remains as defence-in-depth for a service
that copied the old snapshot without the outer line. `git check-ignore
-v` proves it: both the compose file and the inner `.gitignore` are
ignored via `.gitignore:20:.kit/live/`.

**Proof** (§10b, `git init` fixture under `$WORK`, no repo dirt):

* Creates a temp git repo with `.gitignore` lines `.kit/cache/` and
  `.kit/live/`, builds a snapshot as `up` would, `git add`/`commit`
  the tracked README, then asserts

  ```
  git status --untracked-files=all --porcelain` does not contain `kit/live`
  git status --porcelain` does not contain `kit/live`
  ```

  Both PASS only with the outer line; without it the first is FAIL on
  the `.gitignore` line.

* Repo left clean: no `live` directory remains under `ROOT/.kit/live`
  after the check (`rm -rf` in the test's trap).

---

## 4. Finding 3 — prune scope and the honest bounded limitation

**Confirmed scope.** `prune_generations` walks only

```sh
home="$(generation_home)"          # $KIT_STACK_HOME/.retired
for path in "$home/$ref".*; do ... done
```

New snapshots live at `.kit/live/<ref>` — a service-owned path that
never appears in `$KIT_STACK_HOME`. `KIT_STACK_HOME` defaults to
`~/.cache/cafaye/kit`, and `generation_home` is its `.retired`
subdirectory. Therefore a live snapshot cannot be matched by that
glob, and `prune_generations` cannot delete it, regardless of mount
state.

**Regression proof** (§10c):

* Creates 4 retired generations under
  `$KIT_STACK_HOME/.retired/$ref.0`…`.3` and a live snapshot under
  `.kit/live/$ref` for the *same* ref, stubs `docker` to report no
  mounts (so prune would delete when allowed), invokes the real prune
  loop (`KIT_STACK_HOME=$prune_home ... prune_generations $ref`),
  asserts `.kit/live/$ref` still present while the oldest retired
  generation has been reclaimed per `keep=3`.

**Bounded limitation — stated honestly, not hidden.**

* **What is protected after m157:** every stack rendered *after*
  m154+m157 (`up` writes to `.kit/live/<ref>` and `compose()` reads
  from there). Cache replacement, `prune_generations`, or outright
  `rm -rf ~/.cache/cafaye/kit` moves no byte any live mount resolves
  to, even with `KIT_STACK_OFFLINE=1`. Proven §9 (§10c confirms the
  glob).
* **What is not — until re-rendered:** any stack that still composes
  from the cache (rendered before m154) remains on the old path and
  therefore remains reachable by `prune_generations`'s existing
  matcher. The blind prefix spot (`inspect` reports pre-rename path
  while the tree lives under `.retired/<ref>.<n>`) that m154 §2
  documented is still present for those trees. The first `bin/dev up`
  from the m157 tree re-renders the stack onto `.kit/live/<new-ref>`
  (or the same ref, via corruption path) and removes it from that
  matcher. Until that `up` runs, the manager's existing
  `site-launch-*` stack is the bounded example: still mounting from
  `/.../.cache/cafaye/kit/<sha>/...`, still subject to the old
  matcher. No auto-migration was attempted — a running container
  cannot be re-pointed without a recreate, and the manager decides
  when that recreate happens.
* **Size bound:** one live directory per deliberate pin (immutable
  ref), plus at most one `.stale` and numbered `.stale.<n>` on rare
  corruption. Each is a `--depth 1` compose subtree: a few hundred KB
  of YAML. No reaping of old pins — an unchanged service keeps its
  mounts across an upgrade.

---

## 5. What changed on disk

* `templates/bin/dev.sh` — `sync_live_stack` mount-aware stale retention
  (see §2). `generation_is_mounted`/`mount_sources` reused, no new
  helpers.
* `.gitignore` — added `.kit/live/` with comment.
* `tests/fetch_test.sh` — header `SIX`→`NINE` fixed in m154, now
  `NINE`→`TEN`; §10 (9 new PASS) covering §2–§4.
* No change to `prune_generations`, `generation_keep`,
  `generation_home`, `fetch_stack`, `resolve_stack`, `compose()`,
  `generation_is_mounted`, `mount_sources`.

Static: `shellcheck -S warning -e SC2317` clean on both scripts,
`bash -n` clean, `git status --untracked-files=all --porcelain`
empty at `ROOT` after the gate (the live fixture lives under
`$WORK` and is swept by `trap`).

---

## 6. Handoff / required manager gate

* Worker ran only `bash tests/fetch_test.sh` + `shellcheck` + `bash -n`
  per brief — no `tests/validate.sh`, no docker daemon, no network.
* **Required:** full `bash tests/validate.sh` on the merged tree (fetch
  phase, shellcheck sweep, static checks that read `dev.sh` and
  `.gitignore`, and the new §10 controls).
* Follow-up is bounded: `prune_generations`'s blind prefix for *cache*
  generations remains latent for pre-fix stacks only; for post-fix
  stacks it is unreachable by construction (§4). A later packet that
  repairs that matcher would change deletion behaviour and needs its
  own proof.
* Commits on `kit-m150-default-mfa` (this report's tree):
  `f884478` (m157 Q1 — mount-safe stale + root ignore),
  `4cb9999` (m157 Q2 — §10 regression).

---

## 7. Appendix — m154 report addendum

m154's §2 second bullet and §5 first bullet remain true, now with the
m157 qualifier: the blind spot is unreachable for *new* snapshots
because they live outside the matcher (this report §4). The honest
limitation for pre-m154 cache-mounted generations is as stated there
and restated above. m154's "old live snapshots are never reaped" now
reads: one live directory per pin, plus at most one `.stale` (and
numbered `.stale.<n>` only when the previous stale was still mounted).
No merge, no push by worker.
