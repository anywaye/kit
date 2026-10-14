# REPORT-roll-c5-identity-courier-converge — step 12 converges identity's orphaned courier block

## The seam

`mint_courier_identity_token` in `templates/substrate/install.sh` (step 12, the
courier-mint). With `KIT_SUBSTRATE_APP_BASE_URL` unset it took the else branch,
printed "no identity courier keys written", and wrote nothing.

## The evidence

- The live box runs `identity-7f5d4655d5-…` in CrashLoopBackOff (58 restarts):
  `invalid courier configuration: COURIER_BASE_URL and COURIER_TOKEN must both
  be set, or neither of them`.
- `kubectl -n identity get secret identity-secrets` carries `COURIER_TOKEN` and
  no `COURIER_BASE_URL` — `present == 1`, which `loadCourier` refuses.
- The half-pair came from an earlier installer (recorded in
  `reports/REPORT-roll-c4-e2e.md` and `reports/REPORT-roll-c5-e2e.md`); master
  already writes both halves in one patch, but the fix is write-forward: a
  re-run with the base URL unset writes nothing, so the orphan survives every
  re-run. Same shape as the AppProject defect (`roll-c5-appproject-reapply`,
  b453cc5): the repair must run outside the happy-path guard so a warm box
  picks it up.

## What changed (`templates/substrate/install.sh`)

- New `converge_identity_courier_block`: reads the seven block keys
  (`IDENTITY_COURIER_KEYS`: the pair plus the five link templates), deletes
  whichever are present in **one** `--type=merge` patch, prints which keys were
  removed and why, restarts `deployment/identity`, re-reads the secret and
  **fails the step naming leftovers** if the block is not empty.
- Called **above the mint guard** (a warm box that already minted still heals)
  and again in the unset branch after the mint (so the branch itself converges
  and re-verifies). The set branch is untouched: pair + five templates in one
  patch. Courier's own `COURIER_IDENTITY_URL` + `COURIER_IDENTITY_TOKEN` pair is
  still written unconditionally. `identity/` is untouched.
- The nulls go under **`data`, not `stringData`**, on purpose: `stringData` is
  write-only and never persisted, so a null there merges into a field the
  stored object does not carry and deletes nothing; a null under `data`
  removes the entry before decode. Both test mocks model this (data-null
  deletes, stringData-null is a no-op) and the shared patch-convention check
  pins it, so a revert to `stringData` goes red.
- The §24 `RECORD identity-secrets:` list is unchanged (no key added or
  removed), and the record tripwire still holds.

## Controls (`tests/substrate_test.sh`, §18d + patch-convention)

- Green, real tree: unset path with a pre-seeded orphaned `COURIER_TOKEN` and a
  stray template removes both, verifies the seven-key block empty, keeps
  `DATABASE_URL` / `SIGNUP_SIGNING_KEY` / `MFA_ENCRYPTION_KEY` / `NATS_URL` /
  the OIDC triple, still writes courier's pair, reports the removed keys, and
  restarts identity.
- Green, real tree: set path still lands pair + five templates together
  (existing §18c test, unchanged).
- RED control: the real tree with `IDENTITY_COURIER_KEYS` emptied (functionally
  master's write-forward: the sweep scans nothing, removes nothing) fails the
  orphan check naming `COURIER_TOKEN`. Premise-asserted.
- Verdict: `tests/substrate_test.sh` — **271 passed, 0 failed, 0 skipped**.

## Manager fallback: converge the live box by hand

One command on the box (add `sudo` / `KUBECONFIG=/etc/rancher/k3s/k3s.yaml` as
the box requires). It nulls the seven keys under `data` — **not** `stringData`,
which would be a silent no-op — then restarts identity:

```sh
kubectl -n identity patch secret identity-secrets --type=merge -p '{"data":{"COURIER_BASE_URL":null,"COURIER_TOKEN":null,"PASSWORD_RESET_LINK_TEMPLATE":null,"EMAIL_VERIFICATION_LINK_TEMPLATE":null,"EMAIL_CHANGE_LINK_TEMPLATE":null,"RECOVERY_LINK_TEMPLATE":null,"INVITATION_LINK_TEMPLATE":null}}' && kubectl -n identity rollout restart deployment/identity
```

Verify: `kubectl -n identity get secret identity-secrets -o jsonpath='{.data}'`
must show none of the seven keys, and `kubectl -n identity rollout status
deployment/identity` must go Ready (identity boots into its supported no-mail
state; recovery routes answer 503 until `KIT_SUBSTRATE_APP_BASE_URL` is set
and the installer re-run writes the full block).
