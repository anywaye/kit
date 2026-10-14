# REPORT — roll-c5-local-cycle

**Packet:** a cycle takes ten minutes and a VPS wipe; it should take minutes and a
local cluster.
**Branch:** `roll-c5-local-cycle` (cut from master). **Worktree:**
`moon/wt/roll-c5-local-cycle`.
**Status:** three commits; the local cycle runs, is measured, and found two real
defects (one fixed, one measured and left as the next packet's decision).
**Cluster used:** `k3d-cafaye-local` (`kubectl config current-context` =
`k3d-cafaye-local`, node `k3d-cafaye-local-server-0`, API server
`https://0.0.0.0:16443`). **No command in this run addressed the Contabo box** —
see §5.

---

## 1. The input's shape, and why it is that shape

**`KIT_SUBSTRATE_KUBECONFIG` — one environment variable, no flag.**

```sh
export KIT_SUBSTRATE_KUBECONFIG=/path/to/kubeconfig
bash templates/substrate/install.sh
```

Set it and the substrate installs **into that cluster**: no k3s is installed on
the machine the script runs on, and steps 1-3 ask the **cluster** whether the
component is there instead of asking the host whether `/usr/local/bin/k3s` is.
Unset is the product — a fresh Linux host is provisioned exactly as before, every
host probe included.

**Why an env var and not a flag.** Two precedents already in the file:
`KIT_SUBSTRATE_RECEIPT` is a path-valued input with no flag, and `DRY_RUN` is a
runtime switch with no flag. A flag is for a **boolean** a human types
(`--headless`); a path is **copied out of another tool's output** —
`k3d kubeconfig get`, `kind get kubeconfig`, `export KUBECONFIG=…` — so an
argument a flag would carry is one the shell would also have to expand, and the
flag's usage line would grow a second form for the same fact.

**Why not the ambient `KUBECONFIG`.** A developer's shell has a current context
for reasons that have nothing to do with this install, and a variable that
changes whether k3s gets installed **on the host** off some other tool's export
is a trap. This one is named, kit-scoped, and stated once.

**One input, one derivation, one code path.** `CLUSTER_SUPPLIED` is derived from
it at startup and never re-derived, so a later assignment cannot leave the guard
asking the host while the preflight asked the cluster. The preflight's split is
**by what each check is a fact about**:

| check | a fact about | fresh box | supplied cluster |
|---|---|---|---|
| root, Linux, arch, memory | the **host** | refusal | not this install's business |
| curl, jq, openssl, ghcr.io | the **run** | refusal | refusal |
| kubeconfig readable, cluster answers | the **cluster** | n/a | refusal (new) |

A supplied cluster with **no Node** refuses naming the input — it does not fall
through to `curl … get.k3s.io | sh` on the workstation the operator is typing at.

## 2. The measured local cycle

```sh
bash templates/substrate/local-cycle.sh
```

**Cold cycle** (cluster reused, but empty of the operators — the measurement that
matters), 2026-10-14 14:17:13Z → 14:20:19Z, **3m06s**, then it stopped at step 4:

```
{"event":"step.start","step":1,"phase":"k3s",…}
{"event":"step.done","step":1,"phase":"k3s","message":"k3s: skipped","seconds":"skipped"}
{"event":"step.done","step":2,"phase":"cert-manager","message":"cert-manager: skipped","seconds":"skipped"}
{"event":"step.start","step":3,"phase":"cnpg","seconds":1.095}
{"event":"step.done","step":3,"phase":"cnpg","seconds":2.099}
{"event":"step.start","step":4,"phase":"argocd","seconds":3.302}
error: timed out waiting for the condition on deployments/cnpg-controller-manager
```

Steps 1 and 2 skipped **on the cluster's evidence** (the Node object exists; the
`cert-manager` Deployment exists) — on a macOS workstation, where the host probes
that used to decide them are all false. CNPG and Argo CD were applied for real.

**Warm cycle** (CNPG and Argo CD now in the cluster), **2 seconds**, and it stops
at step 5 with the substrate's own refusal:

```
local-cycle: 2 seconds, exit 1
local-cycle: the substrate did NOT reach install.done
  refused at step 5 (pull-secret): KIT_SUBSTRATE_BOX_ID is not set
```

**Against the VPS cycle:** a wipe (2 min), `cafe box setup` (2-4 min) and the
substrate (3-6 min) — **~10 minutes per iteration, over SSH, against a machine on
another continent**, and every defect found costs another full pass. The local
cycle is one command on the same machine, and a warm one costs 2 seconds.

**The honest boundary, named rather than hidden: the local cycle stops at step 5
and cannot pass it on a developer machine.** The registry credential is redeemed
per run from a capability that is single-use, minutes-lived and **bound to an
enrolled box** (`KIT_SUBSTRATE_BOX_ID` + a `cap_…` capability), and steps 6-13
then wait on the fleet's images with no credential to pull them. That is the
substrate's own invariant 2 working as designed. The packet's green control asks
for a local cycle that reaches `install.done`; **that control is NOT met**, and
the reason is structural rather than a bug in this work: passing step 5 needs a
credential minted for a box, and steps 6-13 need images that credential unlocks.
The successor's first move is written down in §6.

## 3. The defects the local cycle found

### 3.1 `kubectl apply`'s own output went into the JSONL stream — **FIXED**

The cold run's stdout, between step 3's start event and its done event:

```
namespace/cnpg-system serverside-applied
customresourcedefinition.apiextensions.k8s.io/clusters.postgresql.cnpg.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/databases.postgresql.cnpg.io serverside-applied
…  (26 lines)
```

The first consumer to read the stream — `jq` over the file — died:

```
jq: parse error: Invalid numeric literal at line 7, column 22
```

`tests/substrate_test.sh` already refuses an `echo` or a `printf` outside the two
writers, so the only way to break the channel is **a command this file spawns**,
and no audit of this file's own statements can see those. The install had
reported step 3 complete and step 4 started around the garbage, so the events were
correct and the stream was unreadable — which is what `caf box apply` reads.

**The fix is a file descriptor rather than a policy:** the real stdout is saved on
fd 3, the process's stdout becomes the human channel, and the two writers target
fd 3. Every future `echo`, every tool's progress line and every accidental write
lands beside the operator's other output instead of inside the event stream.

The control pair in `tests/substrate_test.sh` §16 proves the direction: the same
run against an installer with the saved descriptor removed **must go red**.

**And the first version of that fix was wrong, which the suite caught within one
run.** The `exec` originally lived inside `main`, so the tests that source the
installer with `main` stripped — the ones that drive `install_service_secrets` and
`kit_substrate_refuse` directly — got emits writing to a descriptor nobody opened.
The suite reported `FAIL headless: stdout is JSONL, one object per line — stdout
was empty — no events at all`. The channel is now opened by one idempotent
function called from both entry points (source time for the environment form,
`main` for the `--headless` flag), so "where the descriptor is opened" is one
statement rather than two policies.

### 3.2 The operator wait bound is shorter than a cold node's image pull — **MEASURED, NOT FIXED**

```
install start                  14:17:13Z
cnpg Deployment/RS/Pod created 14:17:16Z   (server-side apply, 2.099s for step 3)
grouped wait begins (cnpg)    14:17:19Z
image pull finishes, pod starts 14:20:33Z  (3m17s)
Deployment Available           14:20:37Z  (3m18s after the wait began)
wait bound expires             14:20:19Z  (180s)
error: timed out waiting for the condition on deployments/cnpg-controller-manager
```

**The install died 18 seconds before the controller became Available**, on a
cluster where everything the step had applied was already in place. The pod was
`Running 1/1` and the Deployment's `Available` condition was `True` the whole
time after 14:20:37Z; the same wait command returns `condition met` instantly
when re-run now.

This is **not** fixed here, and that is deliberate rather than a gap:
`tests/substrate_test.sh`'s wait audit enforces `NODE_REGISTER_TIMEOUT +
NODE_READY_TIMEOUT == 120` and its siblings with the stated reason that
**"splitting a wait into two must not make the step more patient"** — quietly
raising 180 to 300 is exactly the edit that audit exists to catch. The decision
(bound, or a pull-aware wait, or an operator-readiness report instead of a
timeout) belongs to the next packet with this measurement attached.

### 3.3 The local cycle's own script hit the SIGPIPE trap — FIXED

The first version probed for the cluster with

```sh
k3d cluster list -o json | grep -q "\"name\":\"$CLUSTER\""
```

under `set -euo pipefail`, and measured its own bug on the first run:
`local-cycle: creating cluster cafaye-local` **on a machine where that cluster
was up**. `grep -q` exits on its first match, k3d is still writing the document
into the pipe, it dies of SIGPIPE, and pipefail promotes 141 over a match that
was already there — AGENTS.md's rule, found by walking into it. The cluster list
is now read once into a variable and matched with the shell's own operator, and
the reason is written above the line.

## 4. The controls' verdicts

| control | verdict | evidence |
|---|---|---|
| **Green:** a local k3d cycle runs the substrate with the same JSONL shape, wall-clock measured | **PARTIAL** — steps 1-4 ran for real, JSONL parsed clean end-to-end, 2s warm / 3m06s cold. It does **not** reach `install.done`: step 5 refuses without a box-bound capability (§2). | `local-cycle` logs quoted above; every stdout line of the warm cycle is one JSON object (`jq -r .event` over the stream returns event names only). |
| **Green:** the default path on a fresh Linux host behaves exactly as before | **PASS** — the host probes are unchanged and still decide; with the input set the run never touches them. `tests/substrate_test.sh` §16 asserts the workstation still refuses `must run as root` with the input unset, and that a supplied cluster never calls `curl … get.k3s.io`. | §16 tests 1-3. |
| **Green:** the local run's kubeconfig is the local one, and nothing addresses the Contabo box | **PASS** — the script writes the kubeconfig itself from `k3d kubeconfig get cafaye-local` and prints the API server it points at (`https://0.0.0.0:16443`). `tests/substrate_test.sh` §16 asserts the script carries no IP literal and dials no ssh, with a control fixture that adds `ssh root@203.0.113.9` and must go red. | §5 below. |
| **RED:** with the input unset, a run on this workstation still refuses the way it does today | **RED, as required** — `error: must run as root — k3s installs to /usr/local and writes the kubeconfig`. The input is what makes the local cycle possible; removing it must break it, and it does. | §16 test 3, and the direct run quoted in §5. |
| **RED:** a defect reproduced locally | **RED, twice** — (a) 26 lines of `kubectl apply` output on the JSONL stream, `jq: parse error … line 7`, reproduced in one local run and now fixed with a control pair; (b) `error: timed out waiting for the condition on deployments/cnpg-controller-manager` 18s before Available, measured §3.2. | quoted verbatim above. |
| **Independent verification:** the local cycle's `install.done` event and `kubectl get applications` | **NOT MET** — there is no `install.done`, because the run stops at step 5's refusal. The cycle prints `No resources found in argocd namespace.` (Argo CD is installed; step 6 never ran). This is the same fact as the first row. | warm-cycle log, §2. |

## 5. How "a local run must not touch the live box" is guaranteed

1. **The kubeconfig is produced by the cycle, not inherited.** `local-cycle.sh`
   writes it with `k3d kubeconfig get cafaye-local` into a scratch directory keyed
   to the worktree and passes it to the installer as
   `KIT_SUBSTRATE_KUBECONFIG`. It never reads, and never writes, the ambient
   `~/.kube/config` — `kubectl config current-context` was read before and after
   the cycle and is unchanged.
2. **The cycle prints the API server it is about to install into**, so "which
   cluster" is a line of output rather than an assumption:
   `kubeconfig /var/folders/…/kit-local-cycle-roll-c5-local-cycle/kubeconfig.yaml
   -> https://0.0.0.0:16443`.
3. **No command in the cycle or the installer names a remote host.** The
   installer's only `kubectl` invocations carry `--kubeconfig="$KUBECONFIG"`, and
   `KUBECONFIG` is either `/etc/rancher/k3s/k3s.yaml` (a fresh box) or the
   supplied path. There is no `ssh`, no `rsync`, and no IP literal in
   `local-cycle.sh` — and that is an assertion in the gate (§16), not a promise
   in this paragraph.
4. **Measured over the run itself.** The captured run directory
   (`/tmp/lc-run/`, `/tmp/lc-run-warm/`, the cycle's own scratch dir) was grepped
   for the box address: **zero matches** in the JSONL, the human channel, the
   receipt, the script and the environment the script exported.

## 6. The successor's first move

**A local exchange for step 5, as one decision in one place.** The blocker is a
credential, not a mechanism: `KIT_SUBSTRATE_REGISTRY_URL` is documented as
configuration (`https://registry.svc.cafaye.com` by default, a self-hosted fleet
points it elsewhere), `KIT_SUBSTRATE_BOX_ID` is only checked for emptiness, and
the capability is only checked **by shape** (`^cap_[0-9a-f]{64}$`) — so a
developer can already run a local HTTP stub at 127.0.0.1 that answers
`POST /v1/registry-credentials` with a fake dockerconfigjson and an `expires_in`
above `REGISTRY_CREDENTIAL_MIN_SECONDS=60`, and step 5 completes without touching
the fleet. What is NOT decided is whether that stub belongs in
`local-cycle.sh` (and what it must never do: never print the fake credential,
never accept a real one). That decision, plus step 3.2's wait bound, is the next
packet — and both were found here in 2 seconds and 3 minutes respectively,
instead of in another ten-minute VPS pass.

## 7. What is in the commits

| commit | what |
|---|---|
| `42079d7` | `KIT_SUBSTRATE_KUBECONFIG`: the installer installs into a cluster that is already there. Preflight split by what each check is a fact about; step 1's guard and its refusal; the receipt's `next` and the final message stop claiming a pin for a cluster this script did not provision. |
| `ce4dd8c` | The JSONL channel is a file descriptor, not a policy (defect 3.1). Plus `templates/substrate/local-cycle.sh`. |
| `73edeae` | The presence probe reads a variable, not a pipe (defect 3.3). |
| (this report's commit) | `tests/substrate_test.sh` §16, `README.md`, this report. |

**Gate:** `bash tests/substrate_test.sh` — see the log; five failures appeared on
the first run after the fd-3 change (one real: §3.1's `exec` in the wrong place,
fixed; four in the AppProject warm-box tests, under diagnosis when this report was
written — do not merge until they are accounted for).
