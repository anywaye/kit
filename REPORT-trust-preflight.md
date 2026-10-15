# REPORT-trust-preflight: the installer verifies the box's TLS trust chain

## The defect, from the dogfood box

The Contabo dogfood box (2026-10-15) could not reach its own control plane:

```
$ cafe boxd
… x509: certificate signed by unknown authority
```

while a Mac client reached `https://box.svc.cafaye.com:8443` fine. The cause was
the box's OS trust store:

```
/etc/ssl/certs/ca-certificates.crt   122 certificates
no ISRG Root X1, no DigiCert Global Root
```

A stale or trimmed trust store. `cafe boxd` is a Go client, and a Go client reads
the SYSTEM store, so every client of the same shape failed on that box. The
remedy that worked was one command:

```
apt-get install --reinstall ca-certificates && update-ca-certificates --fresh
```

The installer had no check for any of it. A box could be seconds into
`curl | sh` and headed for a half-install it could not recover from, and nothing
said so.

## The change

`templates/substrate/install.sh`, a new `trust-preflight` block plus two calls
from `preflight()`:

- **`kit_substrate_tls_verify <url>`** — a bounded connect and certificate
  verification of `<url>`'s origin against the SYSTEM trust store. Uses
  `openssl s_client -verify_return_error -connect host:port -servername host
  </dev/null`, which **fails non-zero on an unverifiable chain**, and reads the
  system store — the store a Go client reads. It writes nothing to the process
  stdout: openssl's output is captured and its error line goes to the refusal
  through `TLS_VERIFY_ERROR`.
- **`kit_substrate_refresh_trust_store`** — the remedy the incident needed:
  `apt-get update && apt-get install -y --reinstall ca-certificates &&
  update-ca-certificates --fresh`, with `dnf`/`update-ca-trust` and `apk` also
  supported. Every call is bounded by the resolved `timeout`/`gtimeout`
  (`KIT_SUBSTRATE_TIMEOUT_BIN`) and `KIT_SUBSTRATE_TRUST_REFRESH_TIMEOUT`.
  Best-effort: the RE-CHECK is the verdict.
- **`kit_substrate_trust_preflight`** — for `KIT_SUBSTRATE_BOX_URL` and
  `KIT_SUBSTRATE_REGISTRY_URL`: verify, on failure report the finding, refresh,
  RE-CHECK, and refuse only what the refresh could not fix — naming the origin
  and openssl's own verification error. In `DRY_RUN` it plans and touches
  nothing.
- `preflight()` calls it in both shapes (host and `KIT_SUBSTRATE_KUBECONFIG`),
  and its `DRY_RUN` early-return calls it too, where it emits one `step.plan`.

### Why `openssl s_client` and not `curl`

The brief is right and the live incident is the proof: curl answered where the
Go client did not. curl carries its own CA fallbacks and verification policy on
some builds, so a `curl … --max-time 15 <url>/healthz` success is not a proof
that the store a Go client reads can verify the chain. `openssl s_client
-verify_return_error` fails on an unverifiable chain and reads the system store,
so the preflight asks the question `cafe boxd` will ask.

### `DRY_RUN`: the deliberate deviation

The brief says the check *may* run in `DRY_RUN` (read-only) but the apt remedy
**must not**. I declined the permission for the check, for a measured reason:

- `tests/substrate_test.sh`'s `lc_cycle` runs the LIVE preflight against a
  supplied cluster, and it does not (could not) control the real
  `box.svc.cafaye.com`. Run for real, the cycle depended on the cafaye hosts and
  the runner's trust store. On this machine it passed (both origins verified in
  ~1s); on an offline runner it would have **refused** and turned a green unit
  cycle red. That is exactly the network dependence this repo's gate forbids.
- A plan that can REFUSE — an unreachable origin is not an origin that verifies
  — is not a plan. `DRY_RUN` output must stay `exit 0` and offline.

So `DRY_RUN` plans the check (`DRY_RUN: verify the TLS chain of …`) and invokes
neither openssl nor the package manager, and `kit_substrate_refresh_trust_store`
is guarded by `dry_run` as a second layer. The remedy half of the brief is met
exactly; the check half is planned rather than performed, for offline
determinism, and that choice is written at the call site.

The other half of the fix: `lc_cycle` now puts a fake `openssl` on `PATH` that
verifies. The trust check calls the openssl **binary** (through the resolved
`timeout` binary, so a shell-function mock cannot intercept it), so the fake has
to be a PATH fixture — the idiom `tests/fetch_test.sh` uses for docker. The
cycle is offline and deterministic again, and it is still a test of the cluster
evidence, not of the cafaye hosts.

## The tests

`tests/substrate_test.sh` §30. One fakebin (`openssl`, `apt-get`,
`update-ca-certificates`, plus `kubectl` and `curl` for the preflight-wiring
cases), **seven greens** against the real `install.sh` (sourced, `main` stripped)
and **five red controls**, each mutating exactly one thing.

The greens:

1. a verifiable box is reported verified for BOTH origins, **openssl IS invoked**
   with the origin in `-connect` and `-servername`, the package manager is NOT;
2. a failing chain fixed by a refresh is **re-checked** — twice per failing
   origin, read off the openssl log — and reported fixed, with the remedy
   ATTEMPTED: the fake `update-ca-certificates` rebuilds the fake store, so
   "refreshed" is a real state the re-check observes rather than a scripted
   reply;
3. a chain that stays broken **refuses**, naming the origin and openssl's own
   verification error, after the remedy was attempted, and the second origin is
   never reached;
4. an origin that never answers a **handshake** refuses as REACHABILITY and the
   remedy is NOT run — openssl prints no `Verify return code:` line for a
   refused port, so the store was never consulted;
5. a remedy that itself **fails** is named in the refusal, so the operator is
   never told to run a command that has just been refused;
6. the installer's OWN `preflight()` reaches the trust check, and **stops** at
   it: with a fake `curl`, the ghcr.io probe is visible in the record after a
   pass and absent after a refusal;
7. `DRY_RUN` plans the check and calls neither openssl nor the package manager.

The red controls, one mutation each:

| mutation | what must go red |
| --- | --- |
| `trust-preflight BEGIN/END` block stripped | check 1 — no verification at all |
| `DRY_RUN` guard's four-line `if … fi` deleted | check 7 — a plan that runs openssl and apt-get |
| `kit_substrate_refresh_trust_store` emptied | check 2 — a refreshable box now refuses |
| reachability guard changed to `= "yes"` | check 4 — an unreachable origin run through the remedy |
| BOTH `preflight()` call sites removed | check 6 — a tree where nothing runs the check |

The fake openssl answers **three** shapes — unreachable (no verify verdict),
unverifiable (`Verify return code: 20 (unable to get local issuer certificate)`,
the live box's own failure) and verified (exit 0). A fake with one shape would
let the installer collapse two different findings into one.

Every fixture asserts its own premise before it is used: the DRY_RUN fixture
asserts the guard is a four-line span whose middle is `step.plan` and `return 0`;
the call-site fixture asserts the needle appears exactly twice (the DRY_RUN branch
and the live branch) and that `preflight()` no longer calls the helper while its
definition survives.

```sh
$ bash tests/substrate_test.sh
-- substrate_test: 416 passed, 0 failed, 0 skipped
PASS: 416 passed, 0 failed, 0 skipped

$ bash tests/validate.sh --static-only
PASS: every check passed.
note: 9 check(s) skipped — reported above, never hidden.
note: 1 tier(s) ran under a time bound; none was reached.
```

`shellcheck -S warning` clean on both edited files, and `bash -n` on both.

## Commits (branch `feat/trust-preflight`)

- `substrate: preflight the box's TLS trust chain against the system store`
- `substrate_test: prove the trust preflight, with a fake openssl/apt on PATH`
- `substrate_test: keep the local cycle offline — fake openssl on PATH`
- `changelog`/`README` entry for the above.

## What is NOT proven here

- The check against a **real** stale store. The greens use a fake openssl; the
  live path was exercised only against the real (healthy) cafaye hosts, where it
  verified in ~1s each. The refusal path is proven against the fake, not against
  a box with a trimmed `/etc/ssl/certs`.
- The `dnf`/`apk` remedy branches: they exist and are bounded, but only the
  `apt-get`/`update-ca-certificates` branch is exercised by the fakebin.
- `openssl`'s own connect bound when `timeout`/`gtimeout` is absent: the check
  then falls back to openssl's `-timeout` and the kernel's TCP connect timeout,
  which is looser than the bound the box usually gets.

## Successor's first move

If a box with a genuine trimmed store is available: run the live installer
against it and watch the preflight print `TLS chain NOT verifiable: … verify
error:num=20:unable to get local issuer certificate`, refresh, then either
report `trust store refreshed: …` or refuse. That would replace the third
"not proven" line above with a measurement.

## Concurrency — this run, resolved

**A second worker (`opencode-go/step-5-preview-free`) was dispatched into THIS
worktree for THIS packet while the first run was in flight.** Both halves were
written in the same working tree by two agents, which is how two reports came to
describe one packet. The manager consolidated: `f856198` is the second worker's
half — the refinement above and its proof — on top of this run's commits.

```
f856198 substrate: finish the second worker's trust-preflight refinement and its proof
4549b58 report: note the second worker dispatched into this worktree
142bd6a docs: report the trust preflight, and name it in the substrate README
81055c1 substrate_test: keep the local cycle offline — fake openssl on PATH
4b85906 substrate_test: prove the trust preflight, with a fake openssl/apt on PATH
94141d7 substrate: preflight the box's TLS trust chain against the system store
```

**What the second half changed, and why.** The first half was right about the
incident and wrong about one thing it could not have measured: it ran the
trust-store refresh for ANY non-zero `openssl` exit, so an origin that was
unreachable — a refused port, a name that does not resolve — was reported as
`the OS trust store is stale or trimmed`, a false statement about a network
problem, with the refresh budget burned on a remedy that could not land. openssl
distinguishes the two itself: it prints `Verify return code:` only when a session
was established and a chain was checked. Measured on this host:

```
$ openssl s_client -verify_return_error -connect github.com:443 -servername github.com </dev/null
Verify return code: 0 (ok)                              # exit 0
$ openssl s_client -verify_return_error -connect 127.0.0.1:1 -servername x </dev/null
connect:errno=61                                        # exit 1, no verify verdict
$ openssl s_client -verify_return_error -connect no-such-host.invalid:443 -servername x </dev/null
nodename nor servname provided, or not known             # exit 1, no verify verdict
$ openssl s_client -verify_return_error -connect github.com:443 ... -CAfile /tmp/self.pem
Verify return code: 20 (unable to get local issuer certificate)   # exit 1, verdict printed
```

So `kit_substrate_tls_verify` now sets `TLS_VERIFY_REACHED` from that line, and
four things follow:

- an unreachable origin refuses **as reachability**, without running the remedy,
  and its message never claims the store is stale;
- `kit_substrate_refresh_trust_store` records what each bounded command did in
  `TRUST_REFRESH_NOTE`, so a refusal never recommends a command that has just
  failed — and says nothing at all when the refresh ran clean;
- a plaintext `http://` origin is reported as carrying no chain to verify, rather
  than refused with openssl's `wrong version number`;
- the error extraction prefers the `Verify return code:` line, then
  `verify error:`, then anything carrying a reason, so the refusal shows openssl's
  own words instead of the `CONNECTED(…)` line.

**What is still not proven here** — the same three as above, plus:

- the unreachable-path branch is proven against the fake's connect-failure shape,
  not against a box behind an egress firewall;
- the `dnf`/`apk` remedy branches are bounded and named in the refusal, but only
  the `apt-get` branch is exercised by the fakebin.

## Successor's first move

If a box with a genuine trimmed store is available: run the live installer
against it and watch the preflight print `TLS chain NOT verifiable: … unable to
get local issuer certificate`, refresh, then either report `trust store
refreshed: …` or refuse. That would replace the first "not proven" line above
with a measurement.

The second such box needs no new test — the three-shape fake already covers the
verdict openssl gives, and the only untested shape left is a dnf/apk box.
