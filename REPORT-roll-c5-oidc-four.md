# REPORT roll-c5-oidc-four — the installer's own documented OIDC input produces a crashlooping identity

## 1. The seam

**Where:** `templates/substrate/install.sh` step 9's OIDC block (~line 2309-2315),
the header's variable list (~line 86), and `tests/substrate_test.sh`.

**The claim vs the implementation:**

- The **header** (`install.sh:86-91` on master) promised:

  ```
  KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER optional: the URL identity publishes as
                               its OIDC issuer. NOT a secret — and when it
                               is set the signing key and its id are
                               GENERATED ON THE BOX beside it, because
                               identity's OIDC surface is all-or-nothing
                               (issuer + key + id, or none of them).
  ```

  "All-or-nothing (issuer + key + id, or none of them)" is missing a member.

- The **writer** (`install.sh:2309-2315` on master) wrote three `--from-literal`:

  ```bash
  if [ -n "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ]; then
    resolve_oidc_signing_key
    identity_args+=(--from-literal=OIDC_ISSUER=... --from-literal=OIDC_SIGNING_KEY=... --from-literal=OIDC_SIGNING_KEY_ID=...)
  fi
  ```

- The **loader** (`identity/internal/config/config.go:loadOIDC` line 1560+) requires **four** when OIDC is on:

  ```go
  issuer := lookupValue(lookup, "OIDC_ISSUER")
  key    := lookupValue(lookup, "OIDC_SIGNING_KEY")
  keyID  := lookupValue(lookup, "OIDC_SIGNING_KEY_ID")
  loginUI:= lookupValue(lookup, oidc.LoginUIEnvVar) // "OIDC_LOGIN_UI_URL"
  // present counts issuer/key/keyID only:
  case present != 3: return "OIDC_ISSUER, OIDC_SIGNING_KEY and OIDC_SIGNING_KEY_ID must all be set, or none of them"
  // then, with the three present, login UI is REQUIRED:
  if err := oidc.ValidateLoginUIURL(loginUI); err != nil {
      return "OIDC_LOGIN_UI_URL: <reason>"
  }
  ```

  An operator follows the installer's own documented contract, sets the one variable it names, and gets a Deployment that can never start.

## 2. The evidence, measured

**Live-box reproduction (Contabo box):**

- Operator sets exactly the installer's documented input:

  ```sh
  export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='https://auth.example.com'
  bash templates/substrate/install.sh
  ```

- Identity goes `CrashLoopBackOff` within one rollout:

  ```
  ERROR identity exited with an error error="loading configuration: invalid OIDC configuration: OIDC_LOGIN_UI_URL: no OIDC login UI configured"
  ```

  This is `identity/internal/oidc/loginui.go:ValidateLoginUIURL` refusing `""` → `ErrNoLoginUI`, surfaced through `config.go:1595`.

- The header that promised otherwise:

  ```
  KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER optional ... identity's OIDC surface is all-or-nothing
                               (issuer + key + id, or none of them).
  ```

**Gateway readiness consequence:**

Gateway's `/readyz` probes identity's JWKS (`internal/httpapi/runtime.go:keySetProbe`), and identity serves that route only when OIDC is configured (`identity/internal/config/config.go:OIDCEnabled` — "a process with an unset OIDC_ISSUER serves its /v1 surface and its probes and nothing else, and the routes are absent").

Before OIDC was wired, gateway sat at `Readiness probe failed: ... statuscode: 503` for four hours — 1564 probe failures — while the installer reported a clean `install.done`.

**Measured on the mock:**

```
MOCK_ROOT="$WORK/oidc-three-control" # master (three-key) installer
export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER="https://identity.example.com"
install_service_secrets # exit 0, writes OIDC_ISSUER + key + id, no OIDC_LOGIN_UI_URL
# The same input against the fixed installer:
# exit 1, refused naming KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL, no secret written
```

## 3. The fix

### 3.1 New variable

**`KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL`** — the URL a browser is sent to in order to authenticate — the login UI (parlor on this substrate). Optional, no default, never guessed.

- Belongs to the customer's front end (parlor), exactly as `KIT_SUBSTRATE_APP_BASE_URL` does.
- When the issuer is set this MUST be set too, and vice versa; a lone issuer is a CrashLoopBackOff.
- Identity validates it as an `http(s)` URL with a host, no query, no fragment and no userinfo — the same rule as `oidc.ValidateLoginUIURL` (`identity/internal/oidc/loginui.go:ValidateLoginUIURL`).

### 3.2 Header wording (the contract)

Before:

```
KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER optional: the URL identity publishes as
                               its OIDC issuer. NOT a secret — and when it
                               is set the signing key and its id are
                               GENERATED ON THE BOX beside it, because
                               identity's OIDC surface is all-or-nothing
                               (issuer + key + id, or none of them).
```

After:

```
KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER optional: the URL identity publishes as
                               its OIDC issuer. NOT a secret — and when it
                               is set the signing key, its id and the login
                               UI URL are GENERATED (key/id) or SET (login
                               UI) ON THE BOX beside it, because identity's
                               OIDC surface is all-or-nothing (issuer +
                               key + id + login UI, or none of them).
KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL optional: the URL a browser is sent
                               to in order to authenticate — the login UI
                               (parlor on this substrate). When the issuer
                               is set this MUST be set too, and vice versa;
                               a lone issuer is a CrashLoopBackOff
                               (`OIDC_LOGIN_UI_URL: no OIDC login UI
                               configured`). Identity validates it as an
                               http(s) URL with a host, no query, no
                               fragment and no userinfo — the same rule as
                               `oidc.ValidateLoginUIURL`. NOT a secret, and
                               never guessed: a guessed URL sends a browser
                               somewhere the operator never chose, the same
                               rule `KIT_SUBSTRATE_APP_BASE_URL` states.
```

### 3.3 Writer

`install.sh:resolve_oidc_signing_key` unchanged — generated once, read back, `box-<16hex>` thumbprint.

`install_service_secrets`:

- **Reconcile above the guard** (`reconcile_oidc_identity_secrets`): a box installed before this packet holds all four service secrets, so the guard would skip. When the operator now supplies both issuer and login UI, patch missing OIDC surface into pre-existing `identity-secrets` via `jq` + `--patch-file=/dev/stdin`, reusing stored signing key (`resolve_oidc_signing_key` reads back). Read-back verification: re-read four keys and compare.

- **All-or-nothing refusal** (`validate_oidc_all_or_nothing`): before any secret is written (LIVE path, after `dry_run` early return, before `create namespace`), if issuer without login UI → `kit_substrate_refuse KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL`; if login UI without issuer → `kit_substrate_refuse KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER`. Both name the missing variable and the export that fixes it.

- **Shape** (`validate_oidc_login_ui_url`): mirrors `ValidateLoginUIURL` — scheme http/https, host non-empty, no `?` query, no `#` fragment, no `@` userinfo before `/`.

- **Create path**: when `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER` set, add four literals:

  ```
  --from-literal=OIDC_ISSUER="$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER"
  --from-literal=OIDC_SIGNING_KEY="$oidc_key"
  --from-literal=OIDC_SIGNING_KEY_ID="$oidc_key_id"
  --from-literal=OIDC_LOGIN_UI_URL="$KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL"
  ```

  After `kubectl create`, read-back verification on a cold box (same as warm).

### 3.4 Record tripwire

`RECORD identity-secrets: ...` unchanged — OIDC keys remain **conditional** (all-or-nothing surface), so they stay unrecorded beside the issuer that gates them. Added `OIDC_LOGIN_UI_URL` to the `conditional` set in `tests/substrate_test.sh:check_secret_record`, so a `--from-literal=OIDC_LOGIN_UI_URL` is not flagged as unrecorded.

`sourced_vars` in `tests/substrate_test.sh` now includes `KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL`.

### 3.5 Persisted-key rule

`resolve_oidc_signing_key` still governs `OIDC_SIGNING_KEY`/`OIDC_SIGNING_KEY_ID`: stored key read back, never rotated. A pre-existing `identity-secrets` that already holds the surface is not patched; one that holds three without login UI is patched (the crashloop shape), reusing the stored key.

## 4. Controls

### 4.1 Green, real tree

- **Four keys wired:** `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER=https://identity.example.com` + `KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL=https://app.example.com/sign-in/oidc` → `identity-secrets` carries `OIDC_ISSUER`, `OIDC_SIGNING_KEY` (2048-bit RSA PEM), `OIDC_SIGNING_KEY_ID` (`box-` + 16 hex), `OIDC_LOGIN_UI_URL`. Round-trip verified.

  `PASS oidc four: issuer and login UI both set wires all four keys`
  `PASS oidc four: the four keys round-trip on a warm box (read-back agrees)`

- **All-or-nothing refused before secret:** issuer alone → `FAIL` naming `KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL`, no secret; login UI alone → `FAIL` naming `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER`, no secret.

  `PASS oidc four: issuer alone is refused, naming the missing login UI`
  `PASS oidc four: login UI alone is refused, naming the missing issuer`

- **Shape refused:** `not-a-url` → `FAIL` naming `KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL`, no secret; also `?query`, `#frag`, `user@`, `https:///`.

  `PASS oidc four: a non-http(s) login UI is refused, naming the variable`
  `PASS oidc four: bad login UI 'https://app.example.com/sign-in?x=1' is refused` etc.

- **Warm-box reconcile:** legacy `identity-secrets` with `OIDC_ISSUER` + key + id but no `OIDC_LOGIN_UI_URL` (crashloop shape) patched on re-run, reusing stored key.

  `PASS warm: a legacy secret without login UI is patched, reusing the stored signing key`

### 4.2 Red controls (must go red)

- **Three-key installer passes issuer-alone:** `git show HEAD:templates/substrate/install.sh` (master, three keys, no refusal) with `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER` alone → `exit 0`, writes `OIDC_ISSUER` + key + id, no login UI. Proves the new refusal discriminates.

  `PASS control: the three-key installer passes issuer-alone without complaint (the refusal discriminates)`

- **Four-key installer refuses issuer-alone:** same input against fixed installer → `exit 1`, names `KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL`.

  `PASS control: the four-key installer refuses issuer-alone (the new code discriminates)` (via `oidc_refused_case`)

- **Bad login UI red:** not an `http(s)` origin → `FAIL`.

- **Existing §24 record tripwire still holds**, and `sourced_vars` covers the new variable (`sourced_vars names only variables install.sh reads`).

### 4.3 Updated OIDC harness

Existing `13d` harness now sets both issuer and login UI:

```
export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER="https://identity.example.com"
export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL="https://app.example.com/sign-in/oidc"
```

and asserts both ride along.

## 5. Exact env block a manager exports on a live box to wire OIDC fully

```sh
export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='https://auth.example.com'
export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL='https://app.example.com/sign-in/oidc'
# The signing key and its id are GENERATED ON THE BOX beside them — no export.
# Both must be set, or neither; a lone issuer is a preflight refusal naming
# the missing KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL.
bash templates/substrate/install.sh
# Verify:
kubectl -n identity get secret identity-secrets -o json | jq -r '.data | keys'
# → DATABASE_URL, MFA_ENCRYPTION_KEY, NATS_URL, OIDC_ISSUER, OIDC_SIGNING_KEY,
#   OIDC_SIGNING_KEY_ID, OIDC_LOGIN_UI_URL, SIGNUP_SIGNING_KEY (+ OTEL, courier)
kubectl -n identity get secret identity-secrets -o jsonpath='{.data.OIDC_ISSUER}' | base64 -d
kubectl -n identity get secret identity-secrets -o jsonpath='{.data.OIDC_LOGIN_UI_URL}' | base64 -d
```

On a warm box that already has `identity-secrets` without the login UI, re-running with both exports patches `OIDC_LOGIN_UI_URL` (and `OIDC_ISSUER` if drifted) into the existing secret, reusing the stored signing key, and verifies the read-back.

## 6. Verification

```
bash tests/substrate_test.sh
-- substrate_test: 294 passed, 0 failed, 0 skipped
PASS: 294 passed, 0 failed, 0 skipped
```

All greens passing and the red controls proven red.

## 7. Live-box reproduction in commit message

Carried verbatim in the commit message (the exact error and the header line that promised otherwise).
