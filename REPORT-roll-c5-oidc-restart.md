# REPORT roll-c5-oidc-restart — the OIDC patch wrote the keys, verified them, and never restarted identity

## 1. The defect, measured

**Where:** `templates/substrate/install.sh` — the OIDC patch block in the secrets step
(`reconcile_oidc_identity_secrets`), which ended with the round-trip check.

A warm box re-run with `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER` and
`KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL` set. The secret gained all four keys —
the patch path works, and the read-back verified them:

```
$ kubectl -n identity get secret identity-secrets -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}' | grep -i oidc
OIDC_ISSUER
OIDC_LOGIN_UI_URL
OIDC_SIGNING_KEY
OIDC_SIGNING_KEY_ID
```

And identity serves no JWKS route, because the pod never saw them:

```
identity_jwks=404                     (from a pod in the gateway namespace)
identity-secrets created: 2026-10-14T20:58:43Z
identity pod startTime:   2026-10-14T20:58:15Z     (28 SECONDS BEFORE THE SECRET)
```

The pod's environment comes from `envFrom: secretRef identity-secrets`, read **at pod start**.
The keys were patched into a secret whose pod was already running, and **nothing restarted
it** — so `OIDCEnabled()` is false in that process, the routes are absent rather than
present-and-500, and gateway's `/readyz` answers 503 forever:

```
Warning Unhealthy  kubelet  spec.containers{gateway}: Readiness probe failed: HTTP probe
                            failed with statuscode: 503        (x61 over 10m)
```

The installer's own report printed "identity serves no JWKS route, so gateway's /readyz
fails and its Deployment never becomes Ready" when the issuer is unset. The operator set
the issuer, the keys landed, and the box still cannot serve: the report and the reality
disagree, which is the defect.

## 2. What the patch now does after writing

`reconcile_oidc_identity_secrets` is unchanged up to and including the round-trip check
(four-variable rule and read-back intact). After it, on the patch path only:

1. **Restart.** `kubectl -n identity rollout restart deployment/identity` — the same call
   step 12's mint patch makes — gated on the Deployment existing. No Deployment (fresh
   box, Argo has not synced yet) means no restart: the secret is already converged and
   the next sync boots with it. The step log names which happened.
2. **Bounded wait.** `rollout status deployment/identity --timeout=${IDENTITY_ROLLOUT_TIMEOUT}s`
   (default 180, the file's existing identity bound). A stuck rollout is fatal (`exit 1`
   naming the Deployment), never forgiven — an explicit `if`, not a bare command, because
   callers below run with errexit disabled and a bare failure would march on. A wait that
   forgives a stuck rollout reports success over a box still serving no route, which is
   worse than no wait.
3. **Route probe.** New `verify_oidc_jwks_route`: port-forward to `svc/identity` on the box
   and `GET /.well-known/jwks.json` over the loopback — the same mechanism step 12's mint
   uses, with the same self-removing RETURN trap. 2xx sets `OIDC_ROUTE_VERIFIED=1`; a
   connect failure names the forward rather than identity; any non-2xx (including the live
   404) is fatal naming the code. The JWKS body is discarded (`-o /dev/null`): nothing
   secret-shaped reaches the log.

## 3. How the no-op case is preserved

- **Converged re-run:** the guard above the patch (`stored_issuer`/`stored_login` both
  non-empty) returns early — no patch, no restart, no probe. Proven by
  `check_oidc_patch_noop`: converge a store, re-run, exit 0 with no `rollout restart`
  in argv.
- **Creation path:** the secret does not exist yet, so reconcile returns before writing
  anything; the keys are created with the secret and there is no running pod to restart.
  Proven by `check_oidc_create_no_restart`: fresh store, all four keys land, no restart
  in argv.
- **Unset issuer:** reconcile returns on the first line, untouched.

## 4. What the readiness report now says

The unset-issuer wording is unchanged (it is right). The set-issuer final verdict
distinguishes three states, so the report never promises a route the run did not watch:

- verified this run: "this run patched identity-secrets, restarted deployment/identity
  and watched its JWKS route answer 2xx";
- patched but Deployment absent: "no rollout was watched and the JWKS route is
  unverified — the next sync boots with the patched secret";
- otherwise: "this run did not verify identity's JWKS route (the secret already carried
  the OIDC surface, or was freshly created with it)".

Two new globals carry the states: `OIDC_ROUTE_VERIFIED` (partial work already present)
and `OIDC_SECRET_PATCHED`, both set only by the patch path. The JSONL `readiness` event
is untouched.

## 5. The controls and their verdicts

Substrate suite (`tests/substrate_test.sh`), real tree: **395 passed, 0 failed, 0 skipped**
(exit 0). The packet's checks:

- Green: `warm: the OIDC patch restarts identity, watches the rollout bounded, and verifies
  the JWKS route` — patch lands the fourth key reusing the stored signing key, argv carries
  `rollout restart deployment/identity` and `rollout status deployment/identity --timeout=5s`
  (bound plumbed through `IDENTITY_ROLLOUT_TIMEOUT`, not a literal), the log carries
  `JWKS route answers 2`.
- Green: `warm: a converged OIDC box restarts nothing on a re-run` — the guard's early
  return is preserved; re-run exits 0 with no restart in argv.
- Green: `warm: the OIDC creation path writes the keys and restarts nothing` — fresh box
  writes all four keys, no restart attempted.
- Green: `warm: the OIDC patch without a Deployment converges the secret and skips the
  restart` — secret converges, exit 0, log names `restart skipped` and `unverified by
  this run`.
- Green (report): verified / patched-but-unwatched / unverified final lines each asserted
  on the real `kit_substrate_readiness_final`.
- RED: `control: the master-shaped patch leaves the pod stale, failing the check` — the
  real tree with reconcile's restart/wait/probe block deleted (premise asserted: probe
  call gone, round-trip check standing) fails the restart check with `was not restarted`.
  Without the fix, the check is red; with it, green.
- RED: `warm: a stuck OIDC rollout refuses rather than reporting success` — `rollout
  status` refusing yields exit non-zero, the `did not roll out after the OIDC patch`
  error, restart proven attempted, and no verified-route claim.
- RED: `warm: a 404 JWKS after the OIDC restart refuses rather than reporting success` —
  the live `identity_jwks=404` shape exits non-zero naming `answers 404`.
- Existing suite untouched and green: all OIDC four-key tests, the mint rollout tests,
  and the §27 honest-report tests (`check_clean` still finds neither warning with a set
  issuer, unset wording byte-identical).

Structural gate that caught a real mistake during this packet: the wait-lists audit
(`every list wait proves the list exists first`) went red on the first version of this
fix — `rollout status` with only a `get` before it. Fixed by adding
`kit_substrate_await_list … deployment identity -n identity` between restart and status,
the same two-waits shape step 12 uses; the audit is green again, and no bound grew
(no new timeout variable).

Full gate (`tests/validate.sh`): **PASS: every check passed** (exit 0, 908 PASS lines,
8 skips reported, none in the lint phase).

## 6. What was not done

- No independent live-box re-run here: no cluster was available to this worker. The
  "warm box re-run shows 2xx" verification is for the manager/packet owner on a real
  box; the mock suite proves the installer asks (restart + bounded status + JWKS GET)
  and refuses on every red shape.
- The preflight (pre-run) OIDC line is unchanged: it prints before the secrets step runs
  and cannot know the outcome; the final (post-run) verdict carries the verified state.
