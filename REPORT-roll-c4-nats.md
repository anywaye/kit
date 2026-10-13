# roll-c4-nats — the NATS deployment gave Kubernetes a flag where it expected a binary

Branch `roll/c4-nats`, worktree `wt/roll-c4-nats`, repo `cafaye/kit`.

**Commits on the branch:**

- `419e99f` `fix(substrate-nats): the flag list is args:, not command: — Kubernetes replaces the entrypoint, it does not append to it` (from the previous attempt; kept — see "the partial work" below)
- `615228c` `test(substrate): a flag-shaped command: cannot ship silently, with the -js red control` (this attempt)

## The defect, measured

Step 10 applied the broker and then timed out:

```
error: timed out waiting for the condition on deployments/nats
```

The pod was `CrashLoopBackOff`, and its termination message named the defect
exactly:

```
StartError: failed to create containerd task: … runc create failed:
unable to start container process: error during container init:
exec: "-js": executable file not found in $PATH
```

`templates/substrate/manifests/data/nats.yaml` carried the local stack's flag
list under `command:`:

```yaml
          command:
            - "-js"
            - "-sd"
            - "/data"
            - "-m"
            - "8222"
```

## The field-semantics note (the whole packet in one table)

Compose and Kubernetes spell two different fields `command:`, and one spelling
means two different things:

| | the field that supplies the **binary** | the field that supplies **arguments** |
|---|---|---|
| Compose | `entrypoint:` (replaces ENTRYPOINT) | `command:` (**appends** to ENTRYPOINT) |
| Kubernetes | `command:` (**replaces** ENTRYPOINT) | `args:` (appends to `command:`) |

So the compose service runs `nats-server -js …` through the image's own
entrypoint, while the identical list under Kubernetes' `command:` **replaces**
that entrypoint and asks the kernel to exec a binary literally named `-js`. The
comment in the manifest said "The local service's command, flag for flag" — a
sentence that was true of the compose file and false of this one, which is
exactly how it shipped.

## The fix, at the code site

The flags move to `args:`, beside a `command:` naming the binary:

```yaml
          command:
            - "nats-server"
          args:
            - "-js"
            - "-sd"
            - "/data"
            - "-m"
            - "8222"
```

`command:` is written out rather than left off to inherit the entrypoint: the
manifest then states what it runs without the reader knowing the image, and it
does not depend on the entrypoint script's first-argument heuristic still being
there. Leaving it off would work today — the image's entrypoint script prepends
`nats-server` when the first argument is a flag — and that is the more literal
port of the compose contract; naming the binary is the Redis manifest's
precedent, which names `sh` for the same reason. Both semantics and that trade
are written at the Deployment (`nats.yaml:91-137`) and in the file header
(`nats.yaml:17-28`), and the "flag for flag" sentence is gone.

## The audit — every `command:` / `args:` under `templates/substrate/manifests/**`

There are **four** `command:` sites in the tree and **one** `args:` site. Each is
checked against the image it runs; the Argo `Application`s carry none (verified
by a recursive key walk, not by eye).

| # | file | site | image | value (first element) | image entrypoint (measured) | verdict |
|---|------|------|-------|-----------------------|------------------------------|---------|
| 1 | `data/nats.yaml:130` | Deployment container `command` | `nats:2.10.24-alpine` | `["nats-server"]` | `ENTRYPOINT ["docker-entrypoint.sh"]`, `CMD ["nats-server","--config","/etc/nats/nats-server.conf"]` | **OK** — `nats-server` is at `/usr/local/bin/nats-server` |
| 2 | `data/nats.yaml:132` | Deployment container `args` | same | `["-js","-sd","/data","-m","8222"]` | — | **OK** — flags belong in `args`; this is the fix |
| 3 | `data/redis.yaml:69` | Deployment container `command` | `redis:7.4.1-alpine` | `["sh","-c","exec redis-server --appendonly yes --requirepass \"$REDIS_PASSWORD\""]` | `ENTRYPOINT ["docker-entrypoint.sh"]`, `CMD ["redis-server"]` | **OK** — `/bin/sh` exists; the shell form expands the secret and `exec`s `redis-server` itself |
| 4 | `data/redis.yaml:87` | `livenessProbe.exec.command` | redis image | `["sh","-c","redis-cli -a \"$REDIS_PASSWORD\" ping \| grep -q PONG"]` | — | **OK** — `/bin/sh` |
| 5 | `data/redis.yaml:95` | `readinessProbe.exec.command` | redis image | `["sh","-c",…]` | — | **OK** — `/bin/sh` |
| — | `applications/*.yaml` (8 docs) | none | Helm charts | no `command:`/`args:` keys at all | — | **n/a** — and if one appeared it would be a Helm value, not a Kubernetes field |

### Evidence

Read-only, on this machine, against the images the manifests pin:

```
$ docker image inspect nats:2.10.24-alpine --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}'
["docker-entrypoint.sh"] ["nats-server","--config","/etc/nats/nats-server.conf"]
$ docker run --rm --entrypoint sh nats:2.10.24-alpine -c 'command -v nats-server; command -v sh'
/usr/local/bin/nats-server
/bin/sh

$ docker image inspect redis:7.4.1-alpine --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}'
["docker-entrypoint.sh"] ["redis-server"]
$ docker run --rm --entrypoint sh redis:7.4.1-alpine -c 'command -v redis-server; command -v sh'
/usr/local/bin/redis-server
/bin/sh
```

The compose contract this file reproduces is
`templates/compose/docker-compose.yml:396-406` — `image: nats:${KIT_NATS_TAG:-2.10.24-alpine}`,
`command: [-js, -sd, /data, -m, 8222]` — which runs through the entrypoint and is
correct there.

### Why `redis.yaml` starts fine, in one sentence

Its `command:`'s **first element is `sh`**, a real binary on the image's PATH;
the shell it starts then `exec`s `redis-server` with the flags, so replacing the
entrypoint is harmless — the flags are *arguments to the shell*, not the name of
the binary. The nats manifest's first element was `-js`: a flag where the kernel
expects a program. Same field, opposite outcome, and the difference is entirely
the first element.

**Live-box evidence was not available from this worktree.** `kubectl config
get-contexts` lists only `k3d-cafaye-local`; there is no `contabo` context here,
so the read-only `kubectl get pod … -o jsonpath=…` the brief allowed could not be
run. The entrypoint/`command -v` measurements above are the evidence instead, and
they are the same facts the pod would have shown.

## The new check and its red control

`tests/substrate_test.sh` **§12b** (committed as `615228c`). It parses every
non-Argo document under `templates/substrate/manifests/` and refuses any
`command:` whose **first element begins with `-`** — a value that cannot name a
binary on any image, because the entrypoint it would have been appended to has
been replaced.

It keys on the **first element**, not on "a flag appears somewhere": a
`command:` that names the binary and carries the flags after it is the fix, and
the check must not refuse it along with the bug. It reads a scalar `command:`
string too (the API server would reject that shape at apply, but the gate sees
the tree first).

**Covered:** every non-Argo `command:` list under `manifests/`, at any depth —
a container's `command:` and a probe's or lifecycle handler's `exec.command:`
alike, because both are argv.

**Not covered, said plainly:**

- **Argo `Application`s** — a `command:` inside their values is a Helm value
  whose meaning belongs to the chart, and the charts are out of this packet's
  scope. They are counted and reported as skipped (8 docs today), never passed
  over in silence.
- **Whether a non-flag `command:` names a binary the image actually carries.**
  `command: [nats-server]` and `command: [sh, -c, …]` are both accepted on
  shape; proving the binary exists needs a runtime, which this suite is offline
  of. That is what the audit table above is for.

**No allowlist**, deliberately. The brief allowed an exception for "a site whose
entrypoint is documented as such"; there is no such site, because replacing the
entrypoint is what makes a flag-named binary unrunnable on every image. An
allowlist entry that permits nothing is a ratchet.

**The controls, each asserting its own premise before it runs:**

| control | fixture | expected |
|---------|---------|----------|
| the `-js` shape that shipped | flag list restored under `command:`, `args:` gone | **red** |
| binary-first fold | `args:` removed, flags folded under `command: [nats-server, …]` | **green** |
| scalar flag | `command: "-js"` as one string, premise asserts the fixture still parses | **red** |

**And the check cannot be satisfied by examining nothing.** It prints how many
`command:` sites it read, and the harness reads that count back out of the real
tree's own output (`4 command site(s) read, … 8 argoproj.io document(s)
skipped`) — a check that walks an empty tree and reports "0 flag-shaped" is
green and worthless.

The check is also why `check_nats_manifest` (the §12 broker check) now reads the
**union** of `command` and `args`: that union is the argv the runtime execs, and
reading only one field passed a manifest whose flags sat in the wrong field. A
stale cross-reference in that comment (`§12c`, which does not exist) is corrected
to `§12b` in the same commit.

### The check seen red on the real tree, not only on a fixture

A fixture proves the check's shape; it does not prove the gate would have caught
**this** tree. So the shipped defect was restored into the real
`templates/substrate/manifests/data/nats.yaml` (the flag list back under
`command:`, `args:` gone), and the whole suite run: **179 passed, 5 failed, exit
1** — the §12b check itself, the "read the real tree's own command sites"
assertion, and the three fixture premises (which derive from the real manifest and
therefore cannot be built from a broken one). The manifest was then restored
byte-identically from `git checkout` and the suite re-run green. The §12 broker
check stayed green throughout, correctly: the flags were still *present* in the
argv — it was their **field** that was wrong, which is the class only §12b sees.

## Suite counts

```
$ bash tests/substrate_test.sh
-- substrate_test: 184 passed, 0 failed, 0 skipped
PASS: 184 passed, 0 failed, 0 skipped

$ bash -n templates/substrate/install.sh
(clean)

$ shellcheck -S warning tests/substrate_test.sh templates/substrate/install.sh
(clean)
```

The count is 184 because this attempt added one assertion (the scalar red
control) to the 183 the previous attempt left.

## The partial work from the previous attempt

`git status` at dispatch showed the manifest fix and the `check_nats_manifest`
union-read **committed** (`419e99f`), and the new §12b check **uncommitted** in
`tests/substrate_test.sh`. I judged it correct and kept it, with three changes:

1. Corrected the stale `§12c` cross-reference to `§12b` (in `419e99f`'s comment).
2. Broadened the checker to read a **scalar** `command:` string as well as a
   list, matching the brief's "a `command:` value looks like a flag" literally,
   and added the scalar red control that proves the new branch can go red.
3. Fixed the scalar fixture's premise to use `safe_load_all` (the file is
   multi-document; `safe_load` raised `ComposerError` on a *correct* fixture).

Nothing from the previous attempt was discarded as wrong.

## What I deliberately did NOT do

- **Did not touch `.github/workflows/` or any other repository.**
- **Did not run `validate.sh`** — the brief's narrow gate is
  `tests/substrate_test.sh` plus `bash -n` and `shellcheck`, and it was run.
- **Did not make any cluster write.** No `kubectl` mutation; the only cluster
  command attempted was the read-only context listing, and no `contabo` context
  exists here.
- **Did not add an allowlist** to the new check (see above).
- **Did not extend the check to the Argo `Application`s** — chart-owned Helm
  values, out of scope, and they carry no `command:`/`args:` keys today anyway.
- **Did not prove a non-flag `command:` names a binary the image carries** —
  that needs a runtime; it is named as not covered rather than implied.
- **Did not edit the compose file** — its `command:` is correct for Compose.
- **Did not merge or push.** The manager does that.
