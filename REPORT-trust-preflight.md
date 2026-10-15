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
`update-ca-certificates`), four greens against the real `install.sh` (sourced,
`main` stripped), one red control:

1. a verifiable box is reported verified, **openssl IS invoked**, the package
   manager is NOT;
2. a failing chain fixed by a refresh is re-checked and reported fixed, with the
   remedy attempted — the fake `update-ca-certificates` rebuilds the fake store
   and the re-check observes it, so "refreshed" is state rather than a scripted
   reply;
3. a chain that stays broken **refuses**, naming the origin and openssl's own
   verification error, after the remedy was attempted;
4. `DRY_RUN` plans and calls neither openssl nor the package manager;
5. **RED**: strip the `trust-preflight BEGIN/END` block and there is no
   verification at all, so check 1 goes red. The fixture asserts its own premise
   (block absent, copy parses) first.

```sh
$ bash tests/substrate_test.sh
-- substrate_test: 408 passed, 0 failed, 0 skipped
PASS: 408 passed, 0 failed, 0 skipped

$ bash tests/validate.sh --static-only
PASS: every check passed.
note: 9 check(s) skipped — reported above, never hidden.
```

403 → 408 checks. `shellcheck -S warning` clean on both edited files.

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

## Concurrency — read this before merging

**A second worker (`opencode-go/step-5-preview-free`, pid 65408) was dispatched
into THIS worktree for THIS packet while this run was in progress.** It was
actively editing `templates/substrate/install.sh` in the working tree (mtime
moved at 16:09 and again at 16:12, after this run's commits). The committed
history on `feat/trust-preflight` therefore contains **this run's** four
commits only:

```
142bd6a docs: report the trust preflight, and name it in the substrate README
81055c1 substrate_test: keep the local cycle offline — fake openssl on PATH
4b85906 substrate_test: prove the trust preflight, with a fake openssl/apt on PATH
94141d7 substrate: preflight the box's TLS trust chain against the system store
```

The uncommitted diff in `templates/substrate/install.sh` is **the other
worker's**, and it is an improvement on this implementation — it distinguishes
"the store refused the chain" (fixable by a refresh) from "the origin never
answered" (reachability, not the store), records what the refresh actually did,
and skips verification for a plaintext `http://` origin. **This run deliberately
did not commit it**: another agent was mid-write, and committing a torn file
under a message its author did not write is worse than leaving it for its
author. The manager should let that worker commit its own change (or, if it is
gone, commit the diff itself after a `bash tests/substrate_test.sh` on the
final file) — not discard it.

The two workers' versions agree on the substance of the packet, so either tip
satisfies it; do not merge a state where the uncommitted diff is silently
dropped.

