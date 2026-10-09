# REPORT — kit W2-P4: the installer's secret-input surface is zero

Packet: cut the substrate installer's secret-input surface to zero
(`moon/AGENTS-FIRST.md`, W2-P4, depends on W1-P3).
Branch: `agents-first/w2p4`. Commits: `dd75ae4`, `2a704fe`, `28f28f5`,
`6406727`, plus one comment commit on `kit-install.mjs`.
Gate: `bash tests/validate.sh`, run alone, in the background, log at
`/tmp/gate-kit-w2p4.log` (exit code in `/tmp/gate-kit-w2p4.exit`).

## What the packet was for

Invariant 3 is "secrets are born where they are used". The installer already
obeyed it for everything it *writes* — the eight Postgres role passwords, the
Redis password, `SIGNUP_SIGNING_KEY`, `MFA_ENCRYPTION_KEY`, `SECRET_KEY_BASE`,
`COURIER_SECRET_BOX_KEY`, `COURIER_ERROR_RELAY_TOKEN` — and broke it on its
*input* side with two long-lived values handed TO it:

| retired input | why it broke the invariant | what replaced it |
|---|---|---|
| `KIT_SUBSTRATE_PULL_SECRET` (a GHCR dockerconfigjson) | a registry credential with no expiry, in a shell history and in whatever transcript recorded the operator's terminal | `KIT_SUBSTRATE_BOX_ID` + `KIT_SUBSTRATE_REGISTRY_CAPABILITY`, redeemed ONCE per run for a short-lived dockerconfigjson |
| `KIT_SUBSTRATE_IDENTITY_OIDC_SIGNING_KEY` / `_ID` | identity's private RSA key — the customer's own key — transmitted and possibly printed | generated on the box: `openssl genrsa 2048`, key id derived from the key |
| `KIT_SUBSTRATE_COURIER_IDENTITY_TOKEN` | minted by hand in one terminal and pasted into a second run | step 11 mints it on the box and patches both halves in one run |

The third row is in the packet's goal (c) and was not in the "Done means"
list; it is the same defect by the same invariant — a credential crossing a
boundary when the box could hold it — and the two halves it crosses between
are required to be identical, which a hand-off cannot be trusted to get right.

## What was built

**1. The pull secret is redeemed, not supplied** (`redeem_registry_credential`
+ `install_pull_secret`).

- The capability is validated by SHAPE (`cap_` + 64 hex, the minted spelling
  of W1-P3) **before any network call**, so a pasted dockerconfigjson from an
  older runbook is refused on the box instead of sent somewhere as an opaque
  bearer.
- One `POST` names the purpose and the box
  (`{"purpose":"registry.pull","box_id":…}`), so a capability minted for
  another purpose or another box is refused by the registry whether or not
  this script checked — the same posture as `Capability.redeem!`.
- The response body IS the base64 dockerconfigjson and is shape-checked
  exactly as the old operator value was (decodes, carries `auths`), so the
  only change is where the value comes from.
- The value is a shell variable, and the Secret is rendered and applied
  through a pipe. It reaches no disk, no argv and no stdout.

**2. Identity's OIDC signing key is born on the box**
(`resolve_oidc_signing_key`, `oidc_key_id_for`).

- `openssl genrsa 2048` — identity's own `MinKeyBits`; a shorter key is a
  boot-time refusal there, so it is a refusal here by not being produced.
- The key id is DERIVED FROM THE KEY (16 hex of the key's SHA-256, prefixed
  `box-`) rather than invented: it is a public thumbprint, so it is stable for
  as long as the key is, and a verifier that cached the old `kid` keeps
  matching. No clock, no counter, nothing to get out of step on a re-run.
- Read back once-only with the key, like every other generated value: a
  re-run never rotates a live system's key.
- The surface stays **all-or-nothing**, because identity's config refuses a
  lone key (`present != 3 → ErrInvalidOIDC`): the operator may set
  `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER` (configuration, not a secret) and the
  key is born beside it; with no issuer the surface stays absent rather than
  half-wired. `KIT_SUBSTRATE_IDENTITY_COURIER_TOKEN` was REMOVED as an input,
  because step 11 now writes identity's half of that pair itself — which also
  closes the silent-mismatch hole.

**3. The courier loop is box-internal** (`mint_courier_identity_token`, step 11).

The loop's shape is not invented: `launch/bin/launch` already performs the
same four calls against identity's own API, and its comment records why
(the signup timestamp must age 2s before it verifies, because this mint is a
client of the same route; the account belongs to the mail path and nothing
else; the scope is the floor of the vocabulary because the mint refuses an
empty list). The installer now does the same four calls against the
cluster-local Service over a port-forward, writes ONE value into both secrets,
and restarts both deployments. The guard is the VALUE: a re-run that finds the
credential already minted has nothing to mint, so the resume path is not a
step flag that can lie.

## Two real defects found while building the proofs

Both were found by reading the write rather than by a failing test, and both
are now asserted.

**`--from-file=<(...)` never worked where it looked like it did.** Step 5's
old pull-secret write handed kubectl a `/dev/fd/N` path that exists only for
the lifetime of one command. Reproduced in isolation on this machine: the
file descriptor is not there by the time anything reads it. The rendered
Secret is now applied through a pipe, which also removes the value from any
argv. This was a pre-existing defect in step 5, not one this packet
introduced, and the packet fixed it because it had to touch the same line.

**A whole-Secret apply is a REPLACE — and my own first draft used one.**
Writing `COURIER_TOKEN` through
`kubectl create secret … --dry-run=client -o yaml | kubectl apply -f -`
would have deleted `DATABASE_URL`, `SIGNUP_SIGNING_KEY`,
`MFA_ENCRYPTION_KEY` and the OIDC keys from `identity-secrets` in the same
breath, with the symptom an identity that boots no further after its next
restart. Replaced with a merge patch built by `jq` and read from
`--patch-file=-`. `mock_kubectl` gained a `patch` verb that MERGES the way
kubectl does, so the assertion "identity-secrets still holds the keys step 9
wrote" is real — a mock that treated a patch as a replace would have made the
destructive and the correct write indistinguishable.

## The SECRET RECORD tripwire, and how it was extended

The tripwire is unchanged in shape: `RECORD secret: KEY…` lines in
`install.sh`, and a check that every recorded key is created below it and
written by a spelling the file uses, in both directions. It caught this
packet's own change — switching step 11 to a patch removed the
`--from-literal=COURIER_IDENTITY_TOKEN=` spelling the check required, so the
gate went red on a correct installer. The check now counts a key as written
by either spelling (`--from-literal=KEY=` or the merge-patch body
`{"stringData":{"KEY":$t}}`), **with a control of its own** that removes the
patch and must go red. Without that control the widened check would have been
proven only on the `--from-literal` path — the path that never changed — which
is the same "a green control two different checks could satisfy" trap
`AGENTS.md` names.

Section 13 of `tests/substrate_test.sh` (new, ~230 lines) asserts:

- the five retired variable names do not appear in the installer's **code**,
  with comments stripped by the same strip the record check uses — a comment
  naming a retired value is the record of the change, and a comment cannot
  read a variable. Each name also has a control that plants it back into a
  fixture and must be found;
- the capability shape (accepted, and three refusals: a dockerconfigjson,
  a short value, an empty one);
- the redemption: the Secret that reaches the cluster is a
  `kubernetes.io/dockerconfigjson` in all six namespaces carrying the redeemed
  value, and neither the capability nor the credential appears in the output;
- the OIDC key: a 2048-bit RSA PEM, a `box-`-plus-16-hex id, distinct on a
  second box, never regenerated on a re-run, and absent from the output;
- the mint loop: one value in both halves, both restarts as no-ops against the
  mock, and the value absent from the output;
- the patch does not drop the three keys step 9 wrote;
- every no-print claim has a control that plants the value in a log and must
  go red, in the idiom the existing MFA cases established.

`substrate_test.sh`: **91 passed, 0 failed, 0 skipped** (was 73 before this
packet).

## The honest gap

**The redemption endpoint's exact wire format does not exist yet.** It lands
with conductor's box-enrolment work (W2-P6 `caf box enroll`, W2-P7 `caf boxd`,
and W4-P2's `artifact.fetch` capability). The consumer here is built against
the documented shape of W1-P3's capability — opaque bearer, single-use,
minutes TTL, box-bound, digest-only at rest (`app/models/capability.rb`,
`TTL_MINUTES = 15`, `cap_#{SecureRandom.hex(32)}`) — and the brief's
instruction was to build the consumer against that shape and say so, which
this is. Three things make the seam narrow rather than a guess:

- the request names the purpose and the box, so the server can refuse a
  capability minted for either without trusting this script;
- `$KIT_SUBSTRATE_REGISTRY_URL` is configuration with a documented default,
  so a fleet pointing at its own registry needs no code change here;
- the response shape is the one the old operator value already had to pass, so
  a different envelope is a one-line change in `redeem_registry_credential`.

**What is NOT proven by anything here:** that a real capability mints, that a
real registry redeems one, and that a real box can reach either. Those need a
box and a conductor, and the substrate README has said the same about every
step since W7-4.

**A physical limit, named rather than hidden:** the pull secret holds a
credential with minutes of life, so an image pulled an hour later — a pod that
restarts, a new node — needs a fresh one. The installer re-redeems on every
run and `apply` replaces the Secret, which is the right mechanism but still a
re-run. The owner of the scheduled refresh is `caf boxd` (W2-P7), and until it
exists the box's pull stops being shorter-lived than the operator's habit of
running the installer. That is a note for the successor, not a claim this
packet can make.

## What the successor should read first

1. `redeem_registry_credential` in `templates/substrate/install.sh` — the seam
   the wire format lands in.
2. Section 13 of `tests/substrate_test.sh` — the proofs, in the order the
   claims are made.
3. `REPORT-kit-w74-substrate.md` — the previous substrate packet's report,
   left unedited. It still describes the retired
   `KIT_SUBSTRATE_PULL_SECRET` input, because it is a record of what was true
   when it was written. Nothing asserts it against the tree; if a future check
   ever compares a report to the tree, this is the place it will trip.

## Verification

- `bash tests/substrate_test.sh` — 91 passed, 0 failed, 0 skipped (was 73
  before this packet).
- `shellcheck -S warning templates/substrate/install.sh tests/substrate_test.sh`
  — clean. The gate's first run with this packet went red on exactly this
  (`FAIL tests/substrate_test.sh (shellcheck -S warning)`) while the substrate
  tier itself passed 87/87; fixed in `28f28f5`.
- `node --check templates/substrate/kit-install.mjs` — clean.
- **`bash tests/validate.sh` — GREEN, run alone, in the background, on the
  finished tree** (`2cfc90d`): exit code `0`, `PASS: every check passed.`,
  579 PASS rows, no FAIL, `substrate_test: 91 passed, 0 failed, 0 skipped`,
  the install host still serving `install.sh` byte-exact, `9 check(s) skipped —
  reported above, never hidden`, `5 tier(s) ran under a time bound; none was
  reached`. Log: `/tmp/gate-kit-w2p4.log`, exit code in
  `/tmp/gate-kit-w2p4.exit`.
  Two earlier runs are on record as well: the baseline before this packet
  (exit 0), and the first run with it (exit 1, on the shellcheck warning above)
  — so this packet has been seen green *and* seen red, and the red was fixed
  rather than skipped.
