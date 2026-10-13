# roll-c5-gateway-key — the secret key the chart mounts and the installer never wrote

**Status:** fixed and proved; narrow gate green. Branch `roll/c5-gateway-key`,
commits `172f440` (fix) and `510985f` (check). Not pushed, not merged.

**The defect, measured live:** gateway's pod never started. `README.md` in the
chart says the assertion key is mounted; the installer wrote only `REDIS_URL`.

```
Warning  FailedMount  5m50s (x82 over 152m)  kubelet
MountVolume.SetUp failed for volume "assertion-key" :
references non-existent secret key: ASSERTION_SIGNING_KEY
```

---

## 1. The consumed-vs-written inventory (measured)

Every secret **name + key** the four service charts' pods consume, read
read-only out of the service repos, and which `install.sh` step writes it.

| Service | Chart path | Reference | Secret | Key | Writer | Live state |
|---|---|---|---|---|---|---|
| gateway | `gateway/charts/gateway/templates/deployment.yaml` | `env` → `secretKeyRef` | `gateway-secrets` | `REDIS_URL` | step 9 | present |
| gateway | same | `volumes.secret` → `items` | `gateway-secrets` | **`ASSERTION_SIGNING_KEY`** | **nothing — the defect** | **missing** |
| identity | `identity/chart/templates/deployment.yaml` | `envFrom.secretRef` | `identity-secrets` | *every key in the secret* | step 9 (4 keys), step 11 (`COURIER_TOKEN`) | 4 keys, Running |
| courier | `courier/chart/templates/deployment.yaml` | `envFrom.secretRef` | `courier-secrets` | *every key in the secret* | step 9 (10 keys), step 11 (`COURIER_IDENTITY_TOKEN`) | **10 keys — token missing, CrashLoop** |
| parlor | `parlor/chart/templates/deployment.yaml` | `envFrom.secretRef` | `parlor-secrets` | *every key in the secret* | step 9 (`DATABASE_URL`) | 1 key, Running |
| identity | same | `imagePullSecrets` | `identity-ghcr` | — (whole secret) | **nothing — installer writes `ghcr-pull-secret`** | benign live (image pulled) |
| courier | same | `imagePullSecrets` | `courier-ghcr` | — | same mismatch | benign live |
| parlor | same | `imagePullSecrets` | `parlor-ghcr` | — | same mismatch | benign live |
| gateway | `ingress.yaml` | `ingress.tls.secretName` | `gateway-tls` | — | cert-manager, not a pod mount | `gateway-tls-smxwn` |

Notes on the two `envFrom` rows: a generated chart injects the **whole secret**
with `envFrom: secretRef`, so the chart names no key and the key list is the
service's own env list. `install.sh`'s SECRET RECORD is that list, and it was
already complete for identity and parlor. `courier-secrets` is live **10 of
11** because step 11 (the mint) never finished on this box.

### The keys nothing writes

1. **`gateway-secrets`/`ASSERTION_SIGNING_KEY`** — the packet's subject. A
   `volumes.secret` **item** is a *hard* reference: a missing key is
   `FailedMount`, i.e. `ContainerCreating` forever, not a missing environment
   variable. This is the one key the check now catches from the chart side.
2. **`courier-secrets`/`COURIER_IDENTITY_TOKEN`** — the known cross-service
   credential, minted on the box at step 11. It is in the RECORD and written
   by step 11's merge patch; the live box simply never reached step 11
   (`environment variable COURIER_IDENTITY_TOKEN is missing` in courier's
   boot log). Not a step-9 gap — an ordering/resume one.

### Drawn but deliberately OUT of the key charter

The three `imagePullSecrets` names (`<svc>-ghcr`) do **not** match what
`install.sh` writes (`ghcr-pull-secret`, step 5, in every namespace). It has
not bitten (the images pulled; the kubelet ignores a missing pull secret when
the pull needs no auth), and it is a whole-secret *name*, not a secret *key*.
**Reported, not fixed** — and it is a chart-side edit, not a kit one: each
chart's `values.yaml` `imagePullSecrets:` should read `ghcr-pull-secret`, or
`install.sh` should also write `<svc>-ghcr`. I did not touch a service repo.

---

## 2. The fixes

**`templates/substrate/install.sh`** (commit `172f440`):

- `resolve_gateway_assertion_key` generates the key on the box —
  `openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048`, a **PKCS#8**
  PEM, because gateway reads it with `x509.ParsePKCS8PrivateKey`
  (`gateway/internal/httpapi/assertion.go:511`). `openssl genrsa` (PKCS#1)
  would be refused at startup. It is read back on a re-run, never rotated.
- The gateway-secrets create path writes `REDIS_URL` **and**
  `ASSERTION_SIGNING_KEY`.
- The SECRET RECORD now reads
  `RECORD gateway-secrets: REDIS_URL ASSERTION_SIGNING_KEY`, so the existing
  two-way record tripwire sees it.
- **The repair runs above the guard.** On the live box all four service secrets
  exist, so `kit_substrate_guard secrets` skips `install_service_secrets`
  whole. `reconcile_gateway_assertion_key` is called **before** the guard and
  merge-patches only the missing key — the same shape as
  `create_postgres_role_secrets`'s repair above the `cluster` guard. Unlike
  `MFA_ENCRYPTION_KEY`, an absent *signing* key has no ciphertext to fork, so
  generating one heals the box.

**`templates/substrate/README.md`** and **`CHANGELOG.md`**: the
`gateway-secrets` row, the mount's provenance, and the re-run repair.

### The cross-service credential (ordering, made explicit)

`COURIER_IDENTITY_TOKEN` is written by **step 11** (`mint_courier_identity_token`),
never by step 9. `main` already runs step 9 (`install_redis_and_secrets`)
before step 11, so step 9's `courier-secrets` exists when step 11 patches it;
step 11's guard is the **value**, so a re-run with the token absent mints it.
No reordering was needed — the ordering was already correct and is stated at
both call sites. The re-run below exercises it.

---

## 3. The check and its controls

`check_chart_secret_keys` (section **11b** of `tests/substrate_test.sh`,
commit `510985f`) reads the four service charts **beside kit, one level up and
never further** (the AGENTS rule) and requires every secret **name** and
**key** they reference to be in `install.sh`'s own inventory:

- `envFrom.secretRef` → the secret must be created by `install.sh`;
- `env.valueFrom.secretKeyRef` → the secret and the key;
- `volumes.secret` + `items` → the secret and every item key (the shape that
  produced the 152-minute `ContainerCreating`);
- a Helm expression that cannot be resolved in a secret position is a
  **failure**, never a silent skip.

A missing sibling checkout is a **named note**, so a fresh clone stays green.
The check's ability to see a missing writer is therefore proved by a
**throwaway fixture fleet**, not by a neighbour:

| check | fixture | expected |
|---|---|---|
| real run | the sibling charts beside kit | **green** |
| control | fixture chart mounts `gateway-secrets/A_KEY_NOTHING_WRITES` | **red** |
| control (green) | same fixture, mounts `ASSERTION_SIGNING_KEY` | **green** |
| control | fixture reads `gateway-secrets-TYPO` (a secret nothing creates) | **red** |

Two further assertions are wired into existing checks so the new secret is
covered on the live headless path: `ASSERTION_SIGNING_KEY` is in the closed
`SECRET_VARS` list, and the headless live run asserts it never reaches stdout.

The green control is what makes the red one meaningful: the same fixture with
the written key must stay green, or the redone's redness could be about a
broken fixture rather than about the key.

---

## 4. Live evidence (read-only) and what a re-run should show

`ssh contabo` → `sudo k3s kubectl` (no mutation):

```
$ kubectl -n gateway get secret gateway-secrets -o json | keys
"REDIS_URL":                       # DATA 1, AGE 177m — ASSERTION_SIGNING_KEY absent
$ kubectl -n gateway get pods
gateway-6f9c8bfdd-dzr94   0/1   ContainerCreating   0   166m
$ kubectl -n gateway get events --field-selector reason=FailedMount
Warning  FailedMount  pod/gateway-6f9c8bfdd-dzr94
MountVolume.SetUp failed for volume "assertion-key" :
references non-existent secret key: ASSERTION_SIGNING_KEY
$ kubectl -n courier logs deploy/courier --tail=30
** (RuntimeError) environment variable COURIER_IDENTITY_TOKEN is missing.
```

| namespace | secrets | pod |
|---|---|---|
| gateway | `gateway-secrets` (1 key), `ghcr-pull-secret`, `gateway-tls-smxwn` | `ContainerCreating` 166m |
| identity | `identity-secrets` (4 keys), `ghcr-pull-secret` | `Running` |
| courier | `courier-secrets` (10 keys), `ghcr-pull-secret` | `Error`, 35 restarts |
| parlor | `parlor-secrets` (1 key), `ghcr-pull-secret`, `parlor-tls-lqs7x` | `Running` |

**What a re-run of `install.sh` should show** (the manager's next step):

1. Step 9's first half sees the Redis Deployment and skips; step 9's second
   half runs `reconcile_gateway_assertion_key` **above** the guard, finds
   `gateway-secrets` without the key, generates a PKCS#8 RSA-2048 PEM, and
   merge-patches it in (REDIS_URL survives). Then the `secrets` guard skips the
   rest.
2. `kubectl -n gateway rollout status deploy/gateway` — the kubelet's next
   secret-volume sync resolves `assertion-key`, the pod leaves
   `ContainerCreating`, and gateway boots (its ConfigMap already points
   `ASSERTION_SIGNING_KEY_FILE` at `/etc/gateway/assertion/signing.pem`). No
   manual restart should be needed; a rollout restart is harmless if the mount
   is still stale.
3. Step 11 finds `COURIER_IDENTITY_TOKEN` absent, mints it from identity's own
   API, patches **both** `identity-secrets/COURIER_TOKEN` and
   `courier-secrets/COURIER_IDENTITY_TOKEN` with the same value, and restarts
   both Deployments — courier leaves its `Error` loop.

**Still out of band, and named as such:** the public half of the generated
assertion key must reach pantry (or whatever verifies gateway's assertions as
its verifier key). That hand-off is not a step in this installer and is not
created here.

---

## 5. Suite counts

`bash tests/substrate_test.sh` (narrow gate):

```
-- substrate_test: 209 passed, 0 failed, 0 skipped
PASS: 209 passed, 0 failed, 0 skipped
exit: 0
```

Four `run` checks are new (1 real + 3 controls); `bash -n` on `install.sh` and
`substrate_test.sh` is clean; `shellcheck -S warning` is clean on both.

---

## 6. What I deliberately did NOT do

- **Did not touch a service repo.** The `imagePullSecrets` name drift
  (`<svc>-ghcr` vs `ghcr-pull-secret`) is reported with the exact chart edit and
  left alone; the packet chart scope is secret **keys**.
- **Did not invent a value for a signing key.** The key is generated on the box
  and read back; the check never contains key material.
- **Did not rotate anything.** A stored assertion key is read back, never
  regenerated; the repair only adds a key that was absent.
- **Did not change the cross-service ordering.** Step 9 → step 11 was already
  correct; the live courier failure was a resume gap (step 11 never ran), not a
  misordering, and the re-run fixes it.
- **Did not weaken `check_secret_record`.** The new check is additive; the
  existing record tripwire and all its controls are untouched and green.
- **Did not run the full `tests/validate.sh` gate to completion in this
  attempt** — the narrow gate the packet names is `substrate_test.sh`, which is
  green. A `--no-observability` gate run was started; its result is in the
  handoff.
