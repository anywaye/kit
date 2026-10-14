# REPORT-roll-c5-honest-done: `install.done` no longer claims success on a box that cannot become Ready

## The seam

`templates/substrate/install.sh` — the final report, the Certificate/Application
steps' surroundings, and a new preflight — plus `tests/substrate_test.sh` §25.
Nothing else in the tree moves: no new `KIT_SUBSTRATE_*` variable, no change to
gateway's `/readyz` semantics, no change to identity's `OIDCEnabled`, no change
to the per-step timing events.

## The evidence (live Contabo box, measured)

The substrate install ran to completion and exited 0, while:

```
$ kubectl get applications -n argocd
NAME         SYNC STATUS   HEALTH STATUS
courier      Synced        Healthy
identity     Synced        Healthy
parlor       Synced        Healthy
gateway      Synced        Degraded        <-- never Ready
loki         Unknown       Healthy
alloy        OutOfSync     Healthy
grafana      OutOfSync     Healthy
prometheus   OutOfSync     Healthy
```

```
$ kubectl -n gateway get pods
gateway-6f9c8bfdd-dzr94   0/1   ImagePullBackOff   ...
gateway-7cd45d569-rr8fw   0/1   Running            ...
```

`Readiness probe failed: HTTP probe failed with statuscode: 503` — 1564 times
over four hours. Two independent causes, both invisible in the installer's output:

**1. ACME can never complete, and the install says nothing.**

```
$ kubectl get challenges -n gateway
state=pending reason=Waiting for HTTP-01 challenge propagation: failed to
perform self check GET request 'http://api.cafaye.com/.well-known/acme-challenge/…':
dial tcp: lookup api.cafaye.com on 10.43.0.10:53: no such host
```

`api.cafaye.com` does not resolve — the operator never pointed DNS at the box.
The installer created the Certificates, waited for nothing, and finished.

**2. gateway can never be Ready, and the install says nothing.**

gateway's `/readyz` probes identity's JWKS. Identity serves that route only when
OIDC is configured, and the installer wires OIDC into `identity-secrets` ONLY
when the operator sets `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER`. The box's
`identity-secrets` held `COURIER_TOKEN, DATABASE_URL, MFA_ENCRYPTION_KEY,
NATS_URL, SIGNUP_SIGNING_KEY` — no OIDC keys. So identity answers 404 on the
JWKS path and gateway's readiness fails forever.

Both are operator inputs the installer correctly refuses to guess. **The defect
is not that they are unset. The defect is that a run over them reported the
same successful `install.done` as a run over a fully-ready box.**

## What was added (`templates/substrate/install.sh`, +245 lines, one block)

All new code sits between `# --- honest-done BEGIN` / `# --- honest-done END`
plus four one-line call sites marked `# honest-done`, so the test's
master-shaped fixture derives by deleting exactly that.

- **Host sources, read not listed.** `kit_substrate_intended_hosts` reads the
  intended public hosts out of what the installer is about to write: the hosts
  of `KIT_SUBSTRATE_APP_BASE_URL` and `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER`,
  plus any public `https://` host inside the Applications' `helm.values`.
  Fetch coordinates (`repoURL:`, `destination.server:`), comments, and
  in-cluster names (`*.svc.cluster.local`, `*.svc`, `*.local`, `localhost`,
  single labels) are dropped — each drop is asserted by the intended-hosts
  unit test.
- **Resolution on the box.** `kit_substrate_host_resolves`: `getent hosts` on
  Linux (the box), `dscacheutil` on macOS (a developer DRY_RUN), python3's
  resolver as fallback.
- **Preflight report, before anything is created** (`kit_substrate_readiness_preflight`,
  called on both the live and DRY_RUN paths): one block naming each
  unresolving host with its consequence (ACME HTTP-01 self check fails,
  Certificate sits pending, Ingress keeps serving plaintext on port 80), and
  the OIDC consequence with the one export that turns it on. A report, never
  a refusal.
- **Done-report verdict** (`kit_substrate_readiness_final`): after the timing
  table, a `THIS BOX WILL NOT FULLY SERVE UNTIL` section with each condition
  and its exact remedy; when clean, the same header with
  `(none — every intended host resolves and the OIDC issuer is set)` — the
  header is unconditional so quiet can never read as ready.
- **Headless JSONL**: a new final `readiness` event carrying the named field
  **`tls_pending_hosts`** (array) beside **`oidc_configured`** (bool).
  Existing events are byte-untouched; `install.done` still closes with the
  same total and `steps` array.

## Controls' verdicts (`tests/substrate_test.sh` §25)

`bash tests/substrate_test.sh`: **279 passed, 0 failed, 0 skipped**
(includes the pre-existing 269). New: three green checks (unresolving host
reported with consequence at exit 0; unset issuer names never-Ready + fix;
resolving host + set issuer prints neither warning with the header present),
the headless `readiness`-event check (field present, host present,
`install.done` present, every stdout line parses as JSON), the resolving-host
no-warn control, and the intended-hosts unit — plus four red controls running
the same checks against the master-shaped fixture (block deleted, premise
asserted: verdict absent, parses, DRY_RUN still exits 0), all red as required.
The five new value-printing helpers were added to §14's `VALUE_PRODUCERS`
list in the same commit, with all call sites inside `$(...)`.

## The exact block a manager will see on the live box

Preflight (before anything is created):

```
  readiness preflight: resolving the intended public hosts on this box
    api.cafaye.com: DOES NOT RESOLVE — the ACME HTTP-01 self check will fail, the Certificate will sit pending, and the Ingress will keep serving plaintext on port 80
  OIDC: KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER is unset — identity serves no JWKS route, so gateway's /readyz fails and its Deployment never becomes Ready
    turn it on with: export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='https://<your-issuer>'
```

Done report (after the step-times table):

```
  THIS BOX WILL NOT FULLY SERVE UNTIL:
    - api.cafaye.com resolves (point api.cafaye.com at this box) — until then the ACME HTTP-01 self check fails, the Certificate sits pending, and the Ingress serves plaintext on port 80
    - KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER is set (export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='https://<your-issuer>') — until then identity serves no JWKS route, so gateway's /readyz fails and its Deployment never becomes Ready
```

Headless (`caf box apply` caller reads this, not the text):

```json
{"event":"readiness","step":12,"phase":"courier-mint","message":"readiness: 2 condition(s) keep this box from fully serving","tls_pending_hosts":["api.cafaye.com"],"oidc_configured":false}
```

## Deliberately not done

- No refusal on unresolvable hosts; no guessed hostname/URL/issuer variable.
- No change to `/readyz` or `OIDCEnabled` — both are correct; they are why
  the box is honest about being broken.
- Per-step timing events and the `install.done` shape are untouched.
