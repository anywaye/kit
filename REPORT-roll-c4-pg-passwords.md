# roll-c4-pg-passwords — CNPG never set the app roles' passwords, because the Secret's `username` key was the secret's name

Branch `roll/c4-pg-passwords`, worktree `wt/roll-c4-pg-passwords`, repo
`cafaye/kit`, cut from current master.

**Commits on the branch:**

- `0fde6c4` `fix(substrate): the role secret's username key is the ROLE name, not the secret's`
- `fa65c7d` `fix(substrate): reconcile the role secrets ABOVE step 8's cluster guard`
- `95c84b9` `test(substrate): the role-secret wiring is asserted from both ends, with five red controls`

**Prior work:** the worktree was clean (`git status` empty, no diff) — the
previous attempt died before writing anything. There was nothing to keep or
discard.

## The defect, measured on the live box

Read-only `ssh contabo` + `sudo -n kubectl`, `data` namespace. The secrets DO
carry a plaintext password (`password`, 48 hex characters); **no plaintext value
is quoted anywhere here** — only key names, lengths and SHA-256 prefixes.

**All eight role secrets exist** — it is not a missing `-app` secret:

```
postgres-role-courier        Opaque   2
postgres-role-courier-app    Opaque   2
postgres-role-gateway        Opaque   2
postgres-role-gateway-app    Opaque   2
postgres-role-identity       Opaque   2
postgres-role-identity-app   Opaque   2
postgres-role-parlor         Opaque   2
postgres-role-parlor-app     Opaque   2
```

**The `username` key of each `-app` secret is the SECRET's spelling, not the
ROLE's:**

```
postgres-role-identity       username=identity
postgres-role-identity-app   username=identity-app     <-- role is identity_app
postgres-role-gateway        username=gateway
postgres-role-gateway-app    username=gateway-app
postgres-role-courier        username=courier
postgres-role-courier-app    username=courier-app
postgres-role-parlor         username=parlor
postgres-role-parlor-app     username=parlor-app
```

The `password` values are distinct per role and all 48 hex characters
(SHA-256 prefixes, values never printed):

```
identity         len=48 sha256=1d184c7045832c64
identity-app     len=48 sha256=65e31a09e7dbd6fd
gateway          len=48 sha256=07837e247e1d5790
gateway-app      len=48 sha256=be4017c4ebfc6d0a
courier          len=48 sha256=df6f71bf9a1ccb5e
courier-app      len=48 sha256=3fa979ebcb821d7c
parlor           len=48 sha256=24467a18481f63a7
parlor-app       len=48 sha256=88a8ef7507d3ede2
```

**CNPG names those secrets in `spec.managed.roles`, one per role:**

```
identity     login=true secret=postgres-role-identity
identity_app login=true secret=postgres-role-identity-app
gateway      login=true secret=postgres-role-gateway
gateway_app  login=true secret=postgres-role-gateway-app
courier      login=true secret=postgres-role-courier
courier_app  login=true secret=postgres-role-courier-app
parlor       login=true secret=postgres-role-parlor
parlor_app   login=true secret=postgres-role-parlor-app
```

**And CNPG says, in its own status, that it refused to set the password for
every `_app` role:**

```
managedRolesStatus:
  byStatus:
    reconciled:            [identity, gateway, courier, parlor]
    pending-reconciliation: [identity_app, gateway_app, courier_app, parlor_app]
  cannotReconcile:
    courier_app:  - the username in secret "postgres-role-courier-app" does not match role "courier_app"
    gateway_app:  - the username in secret "postgres-role-gateway-app" does not match role "gateway_app"
    identity_app: - the username in secret "postgres-role-identity-app" does not match role "identity_app"
    parlor_app:   - the username in secret "postgres-role-parlor-app" does not match role "parlor_app"
  managedRoleSecretVersion:
    postgres-role-identity-app: "1427"   (and one per secret)
```

**The consequence in `pg_authid` — the owner roles got a SCRAM verifier, the
app roles got nothing:**

```
rolname     | rolpassword     | length
courier     | SCRAM-SHA-25…   | 133
courier_app |                 |
gateway     | SCRAM-SHA-25…   | 133
gateway_app |                 |
identity    | SCRAM-SHA-25…   | 133
identity_app|                 |
parlor      | SCRAM-SHA-25…   | 133
parlor_app  |                 |
```

`rolpassword` is NULL for `identity_app` (and its three siblings), so the pod's
SCRAM exchange against a role with no verifier fails:

```
readiness probe failed dep=postgres error="failed to connect to
`user=identity_app database=identity`: … failed SASL auth: FATAL: password
authentication failed for user \"identity_app\" (SQLSTATE 28P01)"
```

The Deployment reads `DATABASE_URL` through `envFrom: secretRef` on
`identity-secrets` (identity/courier/parlor), and gateway carries the one
`REDIS_URL` `secretKeyRef` to `gateway-secrets`. None of them has a
`secretKeyRef` to a role secret: the role password reaches the pod **inside the
`DATABASE_URL`** that step 9 builds from `postgres-role-<svc>-app`'s `password`
key.

## The mechanism

CNPG's managed-role reconciler sets a role's password from the Secret named in
`passwordSecret` **only when that Secret's `username` key equals the role's
name**. When it does not, the operator does not fail the step, does not surface
an event, and does not refuse the apply — it records the refusal in
`status.managedRolesStatus.cannotReconcile` and moves on, leaving
`rolpassword` NULL. Step 8 named each secret for the service
(`postgres-role-identity-app`, a hyphen) and wrote that same hyphenated spelling
into `username`; the role is `identity_app` (an underscore). The owner roles
happened to reconcile because their secret name and role name are both `<svc>`
— which is why only the app roles were broken, and why the failure looked like
a password mismatch rather than a naming one.

### The hypotheses in the brief, checked and ruled out

- **A missing `-app` secret for one role:** no — all eight exist.
- **CNPG pointed at a different key than the deploy reads:** no — the Cluster
  names `postgres-role-<svc>-app` and `database_url_for` reads
  `postgres-role-<svc>-app`/`password`. Same secret, same key.
- **A `password` vs `password-app` suffix mismatch:** no — the role secret's key
  is `password`, and only step 9 reads it; the Deployments never name a role
  secret's key directly.
- **The operator pin or `password_encryption`:** no — the owner roles reconciled
  to a SCRAM verifier under the same operator and the same scheme.
- **Step 9 rewriting one side after CNPG read the other:** no — `<svc>-secrets`
  is never patched after creation, and it embeds the very value CNPG reads. (The
  *re-run* ordering trap is real but separate; see below.)

## The fix

**`templates/substrate/install.sh`, step 8.** The password-secret loop is the
named function `create_postgres_role_secrets`, and the `username` key it writes
is `$role` (`identity` / `identity_app`), computed independently of
`$secret_name`, whose `-app` suffix belongs to the secret only. The function
carries the live evidence (`cannotReconcile` text, the NULL, the FATAL) at the
code site.

**The re-run, and which side wins.** A re-run keeps every stored password
(regenerating one under a running pod is a login that breaks between two runs)
and merge-patches only the `username` key. CNPG watches the Secret — its status
carries a `managedRoleSecretVersion` per secret — and re-reconciles, so **the
secret wins**: the role's password is *derived* from it. The deploy side does
not move: `identity-secrets`' `DATABASE_URL` already carries the same password
value, so nothing there needs rewriting.

**The ordering trap, fixed separately in `fa65c7d`.** Step 8 returns early when
the `cluster` guard finds the CNPG Cluster already exists — which is exactly the
state of a box installed with the broken spelling. A reconcile placed below the
guard would never run on the only box that needs it. The order is now: DRY_RUN
plan (returns before any write) → idempotent `create namespace data` → the
reconcile → **then** the guard. The guard keeps its contract (do not
re-provision a Cluster that exists); the reconcile is not part of the
re-provision, and on a healthy re-run it is a no-op merge patch.

## The test and the red controls

`tests/substrate_test.sh` §12c, six checks. The green check **executes** step 8's
function against the file-backed kubectl and compares the result to the Cluster
manifest per role: the `passwordSecret` exists and carries a password, its
`username` equals the role name (the assertion the live defect violated), and
`database_url_for` — step 9's own naming function — builds each DSN from the
`<svc>_app` secret's password, names `<svc>_app`, and names the right database.

Five controls, each proved red:

| control | what it drifts | why it must go red |
|---|---|---|
| A | step 8 hyphenates the app `username` | the live defect reintroduced |
| B | one role name in the manifest (`identity_app` → `identity-app`) | username no longer matches the role |
| C | `database_url_for` reads the owner secret | a DSN that logs in as the wrong role with the wrong password |
| D | the reconcile moved **below** the `cluster` guard | a re-run never repairs (this packet's ordering fix) |
| — | the fixture's own premise | the transform refuses a file it could not edit |

The re-run case (green + control D) is **executed**: `install_postgres_cluster`
is driven with the mock answering the guard "the Cluster exists" and every app
secret seeded with the broken spelling; the check asserts the usernames were
repaired and the passwords were **not** regenerated. The mock gains a
`get cluster.postgresql.cnpg.io` branch for it.

### A note on the brief's suggested test shape

The brief proposed asserting "the manifests' `secretKeyRef`s name the same
secret+key per service". There is no such `secretKeyRef` in this tree to assert:
the four `manifests/applications/*.yaml` are Argo CD `Application` objects
pointing at charts in `ghcr.io/cafaye/charts`, and the Deployments are rendered
from those charts, not from a file here. The real, in-tree seam is the one the
defect crossed — the role Secret's `username` key against the CNPG role name the
Cluster declares — plus the `DATABASE_URL` naming in step 9. That is what the
check asserts.

## The narrow gate

```
bash -n templates/substrate/install.sh          # OK
bash -n tests/substrate_test.sh                 # OK
shellcheck -S warning templates/substrate/install.sh   # clean
bash tests/substrate_test.sh                    # exit 0
-- substrate_test: 200 passed, 0 failed, 0 skipped
```

The six new checks:

```
PASS the role secrets and the Cluster agree: username is the role name, DATABASE_URL reads the app secret
PASS control: a hyphenated app username (the live defect) goes red
PASS control: one role name drifting from its secret goes red
PASS control: a DATABASE_URL built from the owner secret goes red
PASS a re-run repairs the app-role usernames even though the cluster guard skips the apply
PASS control: a reconcile behind the cluster guard never repairs a re-run
```

## What I deliberately did NOT do

- **Did not run `validate.sh`** (the brief says not to) and did not change the
  box: every `kubectl` call was read-only, over `ssh contabo`.
- **Did not run a live re-run.** The box still has NULL passwords for the four
  app roles until the installer is re-run. **Predicted outcome of a re-run:**
  step 8 patches the four `-app` secrets' `username` to the role name; CNPG
  re-reconciles and sets each role's password from the unchanged secret value;
  `<svc>-secrets`' `DATABASE_URL` already carries that value, so the pods
  authenticate and the readiness probe passes. This is a prediction from the
  mechanism, not a measurement.
- **Did not change the CNPG operator pin** (`v1.30.1`) or the chart env shape —
  neither side moved.
- **Did not add a retry, a sleep, or a `password_encryption` workaround.**
- **Did not touch `.github/workflows/`** or any other repo, and spawned no other
  agent.
- **Did not bump `VERSION`/add a `MIGRATIONS.md`** — the change is under
  `## Unreleased`, no released version moved.

## The successor's first move, if anything is left

Nothing is outstanding for this packet. If a live re-run is authorised, run
`caf box apply --phase 8` on the box and then re-read
`kubectl get cluster postgres -n data -o yaml` — `cannotReconcile` should be
empty, `byStatus.reconciled` should name all eight roles, and
`identity_app`'s `pg_authid.rolpassword` should be non-NULL.
