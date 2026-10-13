# HANDOFF — roll-c3-substrate-race

**Branch:** `roll/c3-substrate-race` · **Worktree:** `wt/roll-c3-substrate-race`
**Status: the packet's core is DONE and green.** Step 1 and step 8 now prove the
list exists before they wait for its condition, the rule is an executable check
rather than a comment, and there is a test that would have caught the defect.
One adjacent race (step 11) is identified, reasoned about, and deliberately left
— see *not done*.

Nothing was pushed, nothing was merged, no other repo was touched.

---

## 1. What broke, and what was measured

`kubectl wait --for=condition=Ready node --all` **does not wait on an empty
list**. It fails within a second with `error: no matching resources found`.
k3s is started by the line above it; the Node object the kubelet registers
lands a few seconds LATER. On a warm box the node wins the race, which is why
the first bring-up was fine; on a wiped box nothing has registered and the
install dies at step 1, exit 1, under `set -e`.

An independent audit (run against kubectl's own source, not from memory)
confirmed both premises, which were the two that could have made the fix dead
on arrival:

- `get.go` writes the empty-list message to **`o.ErrOut`** and exits **0** — so
  `--no-headers` printing nothing is genuinely "the list is empty", and
  `2>/dev/null` is safe.
- `wait.go` returns `errNoMatchingResources` when `visitCount == 0`, with no
  waiting. The premise of the whole packet holds.

## 2. The fix — a shape, not a sleep

`kit_substrate_await_list <budget> <get args...>` in `templates/substrate/install.sh`:

- polls `kubectl get <args> --no-headers` until the output is **non-empty**;
- bounded by a `date +%s` deadline; on timeout it calls `kit_substrate_refuse`,
  so it exits non-zero, writes the receipt, and names the object that never
  appeared;
- a **command substitution, not a pipe into `grep -q .`** — `grep -q` closes the
  pipe on its first match, the producer dies of SIGPIPE, and `pipefail` promotes
  its 141, so a *long* list would read as an empty one and poll until the
  deadline on a healthy cluster. This is the same bug class `AGENTS.md` names
  about never reading gate output through a pipe;
- prints one line naming what it waits for and the bound, through
  `kit_substrate_out` (stderr in headless), so the two-writer contract holds.

**Budgets are SPLIT, not grown** — the rule that splitting a wait must not buy
the step more patience:

| step | wait | split | was |
|---|---|---|---|
| 1 | node | 90s register + 30s Ready | 120s |
| 8 | CNPG pods | 60s for the operator + 540s Ready | 600s |

Both are `: "${VAR:=default}"` so the suite can shorten them without the numbers
being the contract.

## 3. The eight waits, classified (per line)

Install.sh is 1745 lines; line numbers below are the current (post-fix) ones.

| line | wait | shape | verdict |
|---|---|---|---|
| 708 | `node --all` (step 1) | LIST | **RACY — FIXED.** The kubelet registers after k3s starts; `await_list 90s node` precedes it. |
| 763 | `deployment -n cert-manager --all` | LIST | **safe.** Apply of cert-manager.yaml at 761-762 in the same function; the deployments exist the moment apply returns. |
| 782 | `deployment -n cnpg-system cnpg-controller-manager` | NAMED | **safe.** Apply of the CNPG release at 780-781; named objects fail loudly by name, not as an empty list. |
| 802 | `deployment -n argocd --all` | LIST | **safe.** Namespace created at 798-799, core-install applied at 800-801, same function. |
| 993 | `deployment -n argocd argocd-server` (step 6) | NAMED | **safe, and the closest call.** The apply above it (992) is the Argo *Applications*, not the deployment. It is safe because step 4 waited for argocd-server at 802 earlier in the same run, not because of the line above it. |
| 1156 | `pod -l cnpg.io/cluster=postgres -n data` (step 8) | LIST | **RACY — FIXED.** The Cluster CR is applied synchronously (1140) but the pods are created asynchronously by the CNPG operator, so the selector could match zero pods the instant apply returns. `await_list 60s pod -l ... -n data` precedes it. |
| 1181 | `deployment redis -n data` | NAMED | **safe.** `redis.yaml` applied at 1180. |
| 1584 | `deployment nats -n data` | NAMED | **safe.** `nats.yaml` applied through a pipe at 1582-1583. |

No third racy `kubectl wait` exists. Everything else that touches a possibly
missing resource is in an `if` / `|| true` context and safe: the guards
(337-388), `read_secret_key` (1193-1195), and the NATS phase poll in step 10 —
the `kubectl run` at 1590 creates the pod synchronously, so `set -e` would
already have stopped the run if it had failed.

## 4. The tests

`tests/substrate_test.sh` gained two sections.

**§16 — the defect, executed.** The harness already sources the installer and
runs single steps against a file-backed mock, so step 1 (three lines: start
k3s, prove the node exists, wait for Ready) runs for real. The mock is a faithful
cluster: a GET of an empty list exits 0 and prints nothing, and the WAIT on that
empty list is the error, not a wait. Three cases, each recording every kubectl
invocation in an argv log, because "reached Ready" is an order and not a return
code:

1. **cold box** — empty on the first poll, registered on the second. The step
   must return 0 with the Ready wait *after* the registration.
2. **broken box** — the node never registers. The step must refuse inside its
   bound (shortened to 2s through the same seam), name the empty list, and never
   claim to have waited. The elapsed time is measured, because a wait over its
   own budget would pass a glance at the message.
3. **the control** — the fixture with `kit_substrate_await_list` deleted, i.e.
   the shape the Contabo box actually ran. It must abort with
   `no matching resources found`, and the argv log must show it went straight to
   a Ready wait with **no existence check before it**. That argv is the
   assertion: a control that merely exits non-zero is also satisfied by a step
   that failed for some other reason. The fixture guard fails loudly if the sed
   did not apply, so the control cannot silently become the fixed tree.

**§17 — the rule, as a coupling.** Walks install.sh function by function, in
order (an excuse that comes after the wait is not an excuse), and classes every
wait: a LIST wait is excused only by an apply of what it selects earlier in the
same function, or by a matching `kit_substrate_await_list`. `--all` and an absent
selector are the same query for kubectl, so they compare equal — a rule that
depended on the spelling would be a rule about spelling. All three populations
are asserted (>=2 awaited, >=2 applied, >=4 named), because a check satisfied by
deleting every wait is a check on the empty case. The bound is part of it: the
four numbers must still add to 120s and 600s. Five controls: each await dropped
in turn (each red, naming that resource), a third list wait with no excuse at
all, and a step that grew its registration bound to 300s.

**WATCHED RED ON THE REAL TREE, not only on fixtures.** With the node's await
line deleted from the real `install.sh`, the suite reports **5 failures**,
including §16's "step 1 reaches Ready when the node registers a few seconds
after k3s starts". The tree was restored from the index afterwards.

### Narrow gate — pasted

```
$ bash -n templates/substrate/install.sh                -> OK
$ bash -n tests/substrate_test.sh                        -> OK
$ shellcheck -S warning templates/substrate/install.sh   -> clean
$ shellcheck -S warning tests/substrate_test.sh          -> clean
$ bash tests/substrate_test.sh
      ...
      PASS substrate_test: step 1 reaches Ready when the node registers a few seconds after k3s starts
      PASS substrate_test: control: a single wait on an empty list aborts the install, with no existence check before it
      PASS substrate_test: step 1 refuses within its bound when the node never registers
      PASS substrate_test: every list wait proves the list exists first, and no bound grew
      PASS substrate_test: control: a list wait with no existence check goes red, naming the resource
      PASS substrate_test: control: the CNPG pod wait with no existence check goes red, naming the resource
      PASS substrate_test: control: a new list wait with no existence check goes red
      PASS substrate_test: control: growing the registration bound goes red
-- substrate_test: 159 passed, 0 failed, 0 skipped
PASS: 159 passed, 0 failed, 0 skipped
exit: 0
```

151 passed before this packet -> 159. `tests/validate.sh` was **not** run, per
the brief (it is the manager's merge gate); its one known failure
(`onecluster_test.sh`'s `bin/dev up`) is unrelated to anything touched here.

## 5. What I deliberately did NOT do

- **Step 11's `kubectl -n identity rollout status deployment/identity`** — the
  same *class* of race on a different controller, and I did not fix it. The
  Deployment is created by **Argo**, asynchronously, from the Application step 6
  applies; `rollout status` on a missing named object is a `NotFound` exit 1
  rather than a wait (the `!resourceFound` no-op branch is the empty-*list*
  path, which a named object never takes). Steps 7-10 sit between them, and step
  8 alone lasts 30-90s, so the window is narrow — but it is real. §17 cannot see
  that line, because it reads `kubectl wait` only. Fixing it is one line plus a
  `get deployment` in the harness's `mock_kubectl` (otherwise the mint-loop test
  in 13e would poll for 60s and refuse); that needed its own gate run and the
  budget was gone. **It is named in the CHANGELOG and in the commit message
  rather than left for a reader to infer from silence.**
- **Step 5's silent companion:** the backgrounded `kubectl port-forward` at ~1650
  reads no exit status, so a missing `identity` Service surfaces as
  `error: identity would not mint a signup timestamp` with nothing naming the
  Service. Not a wait, not this packet, noted by the audit.
- **§17's known limit, stated:** the apply excuse is "an apply earlier in the
  same function", not "an apply of the selector's objects". Today that is exact
  for the two waits that use it (cert-manager, Argo CD). A *future* LIST wait
  dropped into `install_applications` would be excused by the apply of the
  Applications. Tightening it needs a manifest-to-objects model this check does
  not have, and a check that pretended to more would fail on correct work.
- No changes to `.github/`, no cluster operations, no box wipe, no
  `tests/validate.sh`.

## 6. Commits

```
8e2b379 install: a wait on an empty list is an error, not a wait — the node and the CNPG pods must EXIST first
c34b36e test(substrate): step 1 runs the cold box, and the pre-fix shape is the control
77d9c0a test(substrate): the wait rule, stated as a coupling rather than a list of remembered lines
e684c02 docs(substrate): the README now says why a step waits twice
db33bf5 docs(substrate): the audit's boundary, stated instead of implied
51dfbd3 install(step 1): the comment said "the wait below" for a wait that is no longer there
```

## 7. Successor's first move

**Step 11's `rollout status`, with its own gate run.** It is one line in
`mint_courier_identity_token`, immediately before the `rollout status` at ~1644:

```bash
kit_substrate_await_list 120 deployment identity -n identity
```

and three things in the same commit, or it is not done:

1. `tests/substrate_test.sh`'s `mock_kubectl` gains a `get deployment` handler
   (existence by name in the file store, like `get secret` already does),
   otherwise §13e's mint-loop test polls for 60s and refuses.
2. §17's wait pattern is widened to also match `rollout status`, and
   `split_args` learns the `deployment/identity` spelling — otherwise the check
   stays blind to the very line you just fixed, which is the exact lesson the
   AGENTS.md keeps repeating.
3. A control for it: a fixture where Argo's sync never happens must go red.
   §16's node fixture is the template to copy.

Do **not** shorten the 120s to make it pass — it is Argo's sync time on a cold
box, and it is the same budget-growing trap §17 already refuses.

Second move, if time: `kubectl port-forward`'s exit status at ~1650 is never
read, so a missing Service is reported as a mint failure ten lines later.
