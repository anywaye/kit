# REPORT-kit-cachemount-01 — a cache eviction that broke every running container

**Branch:** `worker/w6-cachemount` · **Packet:** W6 · **Gate:** `bash tests/validate.sh --static-only` → exit 0

---

## 1. The defect

`fetch_stack` (`templates/bin/dev.sh`) caches kit per git ref under
`${XDG_CACHE_HOME:-$HOME/.cache}/cafaye/kit/<ref>` and ended with:

```sh
rm -rf "$dest"
mv "$tmp" "$dest"
```

`$dest` is not a directory kit owns. `docker compose` bind-mounts **files** out of
it into running containers, and on macOS a bind mount resolves its source **when
the container is created**. So `rm -rf "$dest"` leaves every container serving off
descriptors it already holds, while every **new** open through the mount path
fails `no such file or directory`.

Reported symptom, seven containers up for three hours:

```
cafaye-otel-collector-1   Up 3 hours (unhealthy)
  ExitCode: 1: Error: failed to get config: cannot retrieve the configuration:
  unable to read the file file:/etc/otel/otel-collector.yml:
  open /etc/otel/otel-collector.yml: no such file or directory
```

The collector never stopped serving. Its **healthcheck** failed, because
`validate` re-reads the config through the mount on every probe — and the healthcheck
is right to report a broken file read, because the read *is* broken. What made it
expensive rather than cosmetic is that `bin/dev up` then failed with `stack did
not become healthy`, so **the recovery path reported the fault the cache caused**,
and the run lost its readiness budget to a checkpoint that took 271s to write.

### 1a. The measurement that decided the fix

The prompt asks for a measurement of the subtlety, because it decides whether
"move it aside and clean up later" is a fix or a delay. I ran it against a real
container that re-opens its mount path once a second — the exact shape of the
collector healthcheck, and the reason the healthcheck is what notices.

```
=== A. baseline ===
OK
OK
OK
=== B. rename the mounted tree aside: mv tree tree.retired ===
OK
OK
OK
=== C. delete the RENAMED copy: rm -rf tree.retired ===
ENOENT
ENOENT
ENOENT
=== D. total ENOENT count across the run ===
3
```

Three ENOENTs, and not one before step C. **A rename does not break a bind mount;
deleting the renamed copy breaks it exactly as the original delete did, because it
is the same inode.** So the retention cannot be "clean it up on the next run" —
the later cleanup has to **ask** whether anything is mounted from the tree it is
about to delete. Cleanup ran by label; 0 containers left behind.

---

## 2. The fix

### 2a. `fetch_stack` — retire, never delete

Both moves are renames within one filesystem, so **the property the old comment was
buying is kept**: a second `bin/dev` in another terminal never sees a half-populated
directory, and there is now *no instant* at which the cache path is neither the old
tree nor the new one.

- Retired generations live in `<cache home>/.retired/<ref>.<serial>`. A
  subdirectory, so `ls ~/.cache/cafaye/kit` still reads as "one directory per ref"
  and nothing else has to learn a second naming scheme. **The serial is never
  reused**, so pruning one generation can never make a later fetch land on it and
  inherit a directory something is mounted from.
- `prune_generations` reclaims, oldest-first, beyond
  `KIT_STACK_KEEP_GENERATIONS` (default 3) — and **retains any generation the
  daemon reports a mount source under**, asking through `docker inspect` over every
  container's `.Mounts`.
- **It retains on every answer it cannot get**: no `docker` on `PATH`, `docker info`
  failing, `docker inspect` failing. A machine that cannot answer also has no
  containers mounted from these paths, so retaining is right rather than merely
  cautious.
- **The cold path starts no docker process at all** — there is nothing to prune on a
  fresh cache, and `fetch_test.sh` runs with no daemon and gets the same answer.

Why `docker inspect` over every container rather than `--filter volume=` per
generation: compose mounts **individual files**, and on this machine (docker 29.4.0)
`--filter volume=<the file>` matches while `--filter volume=<the directory holding
it>` matches **nothing**. A filter built from the generation directory would have
reported every generation as unreferenced and deleted the one a container was
mounted to.

### 2b. The healthcheck comment told a stronger lie than the code

`templates/compose/docker-compose.yml` said the check was "the `health_check`
extension's real endpoint, not `components`", because `up --wait` should wait for
the pipelines to be wired. The command was `otelcol-contrib validate`, which proves
the file **parses from disk**. Weaker claim, stronger words, one line apart.

I measured whether the stronger probe is reachable rather than assuming:

```
=== every file in otel/opentelemetry-collector-contrib:0.115.1 ===
.dockerenv  /proc/mounts  dev/  etc/hostname  etc/hosts
/etc/otelcol-contrib/config.yaml  /etc/resolv.conf
/etc/ssl/certs/ca-certificates.crt  otelcol-contrib  proc/  sys/

Available Commands:
  completion   components   help   validate
```

The entire rootfs is the binary, the CA bundle, and empty `/proc` `/sys` `/dev`.
**No shell, no `curl`, no `wget`, no `nc`.** A compose `test:` in `CMD` form execs
one binary, so the only candidate is `/otelcol-contrib`, and none of its four
subcommands opens a socket; `CMD-SHELL` would need the shell that is not there. The
endpoint is bound (`KIT_OTEL_HEALTH_ENDPOINT:-0.0.0.0:13133`) and **genuinely not
reachable this way.**

So the check stays and the comment now says **what it proves** (the config is
readable through its bind mount and parses — both load-bearing, and the mount is
the thing that breaks) and **what it does not** (that the pipelines are wired). Not
deleted: a container that is up and misreporting is worse than one that reports
nothing, and this one caught a real class of failure — it is the probe that surfaced
the defect in §1. **Compose behaviour is otherwise unchanged**, so no compose proof
against real containers was owed here; the measurement above is against the shipped
image.

---

## 3. The test, and the mutation

`tests/fetch_test.sh` gains **section 8** (the eighth of eight; the header's list
was updated to match). **20 assertions, 19 PASS / 1 FAIL under the mutation.**

The fixture puts the cache in the only state that reaches `fetch_stack` with
something already there — `resolve_stack` returns early on a usable cache, so a
fetch over a populated directory happens only when it fails `stack_is_usable`.
Deleting `.kit-stack-ref` is the smallest edit that produces that state and leaves
the rest of the tree exactly as a running container has it open.

Both halves are asserted, because each alone is satisfied by the wrong thing:
"a retired generation survived" alone by a `fetch_stack` that never replaces
anything, and "the new tree is correct" alone by the delete this section catches.

**Asserting the FILESYSTEM rather than docker is deliberate, not a shortcut.** A bind
mount resolves at container creation, so a container that is already up is unaffected
by whatever happens afterwards — what breaks is the *next* open, and that reduces to
whether the inodes are still linked. Renamed: they are. Unlinked: they are not. So
"the retired tree's files still open" is the filesystem statement of the container
claim, and a machine with no daemon gets the same answer.

The assertion reads the retired generation by `find`, not by a name the test chose:
a bind mount does not care what a generation is **called**.

### Mutation

`fetch_stack`'s tail restored to `rm -rf "$dest"; mv "$tmp" "$dest"` — nothing else,
one property:

```
PASS  the cache is warm, and holds a complete tree at the pinned ref
PASS  re-fetching over a populated cache replaces it, and the new tree is correct
FAIL  the previous generation was DESTROYED, not retired. A container bind-mounted
      to it keeps serving off descriptors it already holds while every NEW open
      through the mount path fails ENOENT — which is how a stack that is working
      reports itself broken.

FAIL: fetch — 1 assertion(s) failed.
```

Red on the label, and only on the label. Restored afterwards; `git diff` shows the
fix in place.

**Note for whoever writes the next proof of this:** the self-test layer is retired, so
the mutation above is the only thing standing between the new assertion and a green
suite that cannot see the defect — which is why section 8 asserts the *finding*
(what happened to the files) rather than the exit status. An assertion on exit
status is satisfied by a script that dies before it asserts anything.

---

## 4. Gate

```
bash tests/validate.sh --static-only   →  exit 0
```

`shellcheck -S warning -e SC2317` clean on both changed scripts (they are inside the
linter's glob). No check was weakened, and no threshold or pin moved to get there.

---

## 5. Deliberately not done

- **The collector's `health_check` endpoint is not published to the host**, and I did
  not publish it. It would let a human verify readiness from outside, and the
  collector currently publishes nothing — but adding a published port changes the
  port surface that `tests/validate.sh` checks and is a larger decision than this
  packet. Recorded here as the obvious follow-up if the image ever gains a client.
- **`stack_is_usable` was not tightened** to notice a cache directory more damaged
  than "missing its ref marker". The trigger is rare precisely *because* the check is
  narrow, and widening it changes which caches get re-fetched — a behavioural change
  with its own blast radius, not a fix for this defect.
- **No `bin/dev prune` command.** `prune_generations` runs where the space is created
  and is bounded there; a command would be a second place to get the retention rule
  wrong.
- **`templates/AGENTS.md` (the service skeleton) was not touched.** It documents the
  service's own repo, and this is kit's cache.
- **The two suites the packet listed as in-scope were added to `AGENTS.md`** in both
  places (layout tree, gate list), reading the surrounding structure rather than
  appending — the gate list is a flat run of bullets with per-phase nesting, so
  `onecluster_test.sh` went under `observability` beside its two docker siblings and
  `failfast_test.sh` got its own bullet, since it is a wall-clock measurement rather
  than a phase.

## 6. What a reader should take away

A directory that is **bind-mounted into something running** is not the program's to
delete, and "rename then clean up later" moves the breakage rather than removing it —
the later cleanup has to ask the daemon what is mounted, and it has to retain on
every answer it cannot get. And a comment that names a stronger check than the code
runs is a defect in this repository by its own stated rule, whether or not the check
it describes is achievable: the honest move is to measure whether it is, then say
what the code actually proves.