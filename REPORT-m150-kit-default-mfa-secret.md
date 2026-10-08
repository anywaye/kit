# REPORT-m150-kit-default-mfa-secret.md

Packet m150 — make first-box Identity MFA usable by default. Worktree
`kit-worker-m150-default-mfa`, branch `kit-m150-default-mfa`, based on
current `master` (`e248eeb`). No prior partial work existed in the tree
(clean `git status` at dispatch).

## What the packet is for

The launch substrate treated `MFA_ENCRYPTION_KEY` as optional: `install.sh`
created it only when the operator supplied
`KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY`, and Identity mounts
`GET /v1/mfa` plus the enrollment routes only when that key is present
(verified: `identity/internal/config/config.go` — `loadMFA` decodes with
`base64.RawURLEncoding`, `MFAEncryptionKey()` returns
`ErrNoMFAEncryptionKey` when empty, `HasMFA()` is `len == 32`). A fresh
substrate install with the documented minimum inputs therefore booted an
identity that could neither display the truthful `Off` state nor enroll a
factor, while parlor's Settings screen and launch scope assume MFA exists.

## What changed (3 commits)

1. `5694ee7` (Q1) — red-first tests + one portability fix.
   `tests/substrate_test.sh` gains section 13: the installer is sourced
   with its trailing `main` call removed and `install_service_secrets`
   runs against a file-backed mocked `kubectl` (emulates exactly the
   verbs the step uses: `create namespace`, `create secret generic` with
   `--from-literal`, `get secret` existence + `jsonpath={.data.KEY}`
   reads). Local only — no k3s, no network. `check_secret_record`'s
   conditional set drops `MFA_ENCRYPTION_KEY`. The one-line installer fix
   in the same commit (`"${courier_extra_args[@]}"` →
   `${courier_extra_args[@]+"${courier_extra_args[@]}"}`) is what makes
   the secrets step executable at all under this machine's bash 3.2, where
   an empty array under `set -u` is fatal (zero behavior change on
   bash 4.4+ / the Linux customer box).
2. `3244552` (Q2) — the feature. `install.sh`: `identity-secrets` always
   carries `MFA_ENCRYPTION_KEY` — generated (`head -c 32 /dev/urandom |
   base64 | tr '+/' '-_' | tr -d '=\n'`, `SIGNUP_SIGNING_KEY`'s spelling)
   on first creation, or the validated override when set.
   `validate_mfa_override` enforces charset → 43 chars → decodes-to-32
   on the live path only; refusals name the variable, never the value.
   Stored key wins on reruns; pre-existing secrets are never patched.
   SECRET RECORD, header/provenance comments updated; OIDC/OAuth stay
   optional. `templates/substrate/README.md`: secret table, override
   semantics, legacy operator path, proven-list entry.
3. Q3 (this report + CHANGELOG entry).

## Evidence (exact commands, this worktree)

Q1 red-first state (installer unmodified except the portability line):

```
$ bash tests/substrate_test.sh 2>&1 | grep -E "FAIL|passed.*failed"
      FAIL substrate_test: the recorded secret name-and-key list matches install.sh
      FAIL substrate_test: default: first creation stores an MFA_ENCRYPTION_KEY
      ... (10 red total, all MFA-feature assertions)
-- substrate_test: 46 passed, 10 failed, 0 skipped
```

All 46 pre-existing checks stayed green while the 10 new feature
assertions failed — the test measures the feature, not the harness.
(Harness bugs found and fixed before committing Q1: `unset` after
sourcing re-introduced `set -u` fatals — fixed with export-empty; the
empty-array expansion above.)

Q2 green state:

```
$ bash -n templates/substrate/install.sh && echo parses ok
parses ok
$ shellcheck -S warning -e SC2317 templates/substrate/install.sh && echo clean
clean
$ bash tests/substrate_test.sh 2>&1 | tail -1
PASS: 56 passed, 0 failed, 0 skipped
```

What the 10 new assertions prove (each read from the mock store, output
checked with shell `case`, never a pipe): default key stored with
`^[A-Za-z0-9_-]{43}$` decoding to exactly 32 bytes (python
`urlsafe_b64decode`); valid override stored verbatim; invalid override
refused naming the variable with no secret written and the rejected value
absent from output; rerun keeps the stored key under a competing override;
two fresh installs generate distinct keys; legacy secret without the key
kept byte-identical (no patch, own values preserved); generated and
override values absent from all installer output. The existing
no-operator-value-echoed sweep already covered the MFA variable and stays
green — the new refusal lines name it without `$`.

## Legacy-secret caveat (deliberate, documented)

A re-run never touches an existing `identity-secrets`, so installs that
predate this packet keep running with MFA unwired. This is the safe
direction: an imported database could hold TOTP ciphertext sealed under a
key no longer present, and writing a fresh key in would fork it. The
operator path for an install that never carried the key (hence never
sealed anything under it) is in `templates/substrate/README.md`: back up
the secret, generate with the installer's spelling, `kubectl patch` the
key in, restart identity's pods. If the database may hold ciphertext under
a *different* key, recover that key — a second key decrypts nothing.

## Boundaries kept

- Narrow tests only: `bash tests/substrate_test.sh` (plus `bash -n` and
  `shellcheck`). No Docker substrate install, no full `tests/validate.sh`
  in this worker — the manager gates the merged tree.
- No change to any `site-launch-*` stack; no merge, no push (manager owns).
- Local/mocked only: no k3s executed, no real box touched.
- No new dependency, no parallel installer path; the mock harness lives
  entirely inside `substrate_test.sh` and is swept by its EXIT trap.

## Successor's first move

If this report exists without the Q2 commit above it, the handoff is: the
Q1 test commit stands alone and fails 10 assertions — implement
`validate_mfa_override` + unconditional `MFA_ENCRYPTION_KEY` in
`install_service_secrets` per the test's expectations and the README
wording already committed. Nothing was weakened: every red assertion is a
feature claim, every green one a guard that must stay green.
