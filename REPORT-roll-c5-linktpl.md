# roll-c5-linktpl — identity's mail path is all-or-nothing, and the installer now decides it

**Branch:** `roll/c5-linktpl`, cut from master. Commits:

```
c9db367 fix(substrate): identity's link templates ride the courier pair, or the mail path is deliberately off
fce2273 fix(substrate): build the identity patch into a variable, and assert the mail-path report
<docs>  docs(report): roll-c5-linktpl — the matrix, the decision, the controls
```

The predecessor (`roll-c5-mint-pair`, merged) fixed the *half pair* — a token
with no base URL — and its report named the next refusal behind it: identity's
courier configuration additionally requires a **link template** plus
`INVITATION_LINK_TEMPLATE`. The substrate set neither, so a box's identity would
refuse to boot on the check *after* the pair landed. This packet closes that.

## 1. The matrix — identity's courier config, read out of `cafaye/identity`

All quotes are from `internal/config/config.go` and its own test table
`internal/config/courier_test.go` (READ-ONLY; no service repo was touched).

**The loader is `loadCourier` (`config.go:1097-1144`).** It reads
`COURIER_BASE_URL`, `COURIER_TOKEN`, and five link variables, and counts the
first two:

| # | state | result |
|---|---|---|
| 1 | `COURIER_BASE_URL` and `COURIER_TOKEN` both **absent**, and **no** link variable set | `nil` — a supported deployment with **no mail path**. It mounts `recovery.Unavailable{}`; every route that needs a message answers `503`. Comment: *"Absent is supported. Everything unset is a process with no mail path, which is a legitimate deployment."* |
| 2 | pair absent, but **any** link variable set | `ErrInvalidCourier`, naming that variable — *"…is set but COURIER_BASE_URL and COURIER_TOKEN are not, so the link has nowhere to go"* (`config.go:1112-1116`) |
| 3 | exactly **one** of the pair set | `ErrInvalidCourier` — *"COURIER_BASE_URL and COURIER_TOKEN must both be set, or neither of them: a base URL with no credential sends every message as an anonymous caller and courier answers 401"* (`config.go:1120-1123`) |
| 4 | **both** set | `validateMailBaseURL`, then `resolveLinkTemplates`, then `resolveInvitationLinkTemplate` — all must pass or `ErrInvalidCourier` |

For state 4 the sub-rules are:

- **`validateMailBaseURL` (`config.go:1460-1479`)** — absolute `http`/`https`,
  a host, and **no query or fragment**.
- **`resolveLinkTemplates` (`config.go:1396-1444`)** — at least **one** of the
  four recovery variables must be set, else *"a deployment that can send mail
  needs at least one link template"*; each of the three purposes
  (`PASSWORD_RESET_LINK_TEMPLATE`, `EMAIL_VERIFICATION_LINK_TEMPLATE`,
  `EMAIL_CHANGE_LINK_TEMPLATE`) must have **its own variable or the
  `RECOVERY_LINK_TEMPLATE` default**; each template must contain `{token}`, be
  absolute `http`/`https` with a host, and carry no fragment or userinfo
  (`validateLinkTemplate`, `config.go:1494-1526`).
- **`resolveInvitationLinkTemplate` (`config.go:1312-1326`)** —
  `INVITATION_LINK_TEMPLATE` is **required whenever the block is wired**: *"is
  not set, and a deployment that can send mail needs it"*. It has no default and
  falls back to nothing.

The exact refusal conditions, by variable name:

```
COURIER_BASE_URL, COURIER_TOKEN   — must both be set or neither (state 3)
RECOVERY_LINK_TEMPLATE            — the fallback; validated even when unused
PASSWORD_RESET_LINK_TEMPLATE      — per purpose, or the fallback covers it
EMAIL_VERIFICATION_LINK_TEMPLATE  — per purpose, or the fallback covers it
EMAIL_CHANGE_LINK_TEMPLATE        — per purpose, or the fallback covers it
INVITATION_LINK_TEMPLATE          — REQUIRED whenever the block is wired
{token}                           — required in every recovery template
```

`courier_test.go`'s own rows are the matrix, and the packet's case is among
them (`courier_test.go:62`):

```
name: "a base URL and a token with no link template"
env:  {"COURIER_BASE_URL": …, "COURIER_TOKEN": …}
wantErr: ErrInvalidCourier
```

beside `"all four set is the working configuration"` (boots, enabled),
`"all three absent is a deployment with no mail path, and is supported"` (`nil`),
`"a link template with no base URL"`, `"a base URL and a token with the recovery
templates but no invitation template"`, and `"an invitation template with no base
URL"` — all `ErrInvalidCourier`.

**The two facts the matrix settles:** the shape the substrate shipped (pair, no
template) is state 4 and refuses; and **"neither" is a legal, supported state**
(state 1). That is what makes a truthful second branch possible.

## 2. The decision

**`KIT_SUBSTRATE_APP_BASE_URL` is an OPTIONAL operator input, and identity's mail
path follows it exactly.**

- **Set** → the five link templates are derived from the one public origin and
  written **in the same merge patch** as `COURIER_BASE_URL` + `COURIER_TOKEN`.
  The mail path is *true*.
- **Unset** → the mint writes **no identity courier key at all**. Identity boots
  into its own supported `present == 0` no-mail state (state 1); every recovery
  route answers `503` rather than a rollout that never goes Ready. Courier still
  gets its required pair, because `COURIER_IDENTITY_TOKEN` is demanded by
  courier's runtime regardless (`courier/config/runtime.exs:227-229`).

Why optional rather than required: the box's public name is **the operator's
fact**, and a default (or a required value invented here) is exactly the trade
the brief forbids — a localhost link mails a reader to a screen that is not
theirs, which is *worse* than no mail path. Why not *only* refuse: identity's own
config says "neither" is supported, and a fresh box that cannot know its public
URL should still **boot**, which is the packet's done-criterion.

The derived values are the launch stack's own spellings
(`launch/docker-compose.launch.yml:326-375`), each on a path **parlor actually
serves** (`launch/README` / the launch file's argument):

| variable | value derived from `${base}` |
|---|---|
| `PASSWORD_RESET_LINK_TEMPLATE` | `${base}/reset-password?token={token}` |
| `EMAIL_VERIFICATION_LINK_TEMPLATE` | `${base}/verify-email/confirm?token={token}` |
| `EMAIL_CHANGE_LINK_TEMPLATE` | `${base}/verify-email/confirm?token={token}` |
| `RECOVERY_LINK_TEMPLATE` | `${base}/verify-email/confirm?token={token}` |
| `INVITATION_LINK_TEMPLATE` | `${base}/invitations/{token}` |

`EMAIL_CHANGE` has no screen of its own on parlor, so it points at
`verify-email/confirm` — the served address-confirmation screen and the closest
honest target, exactly as the launch file already argues.

**Why one patch.** A base URL and a token with no template is a refusal at boot
(state 4), so the pair and the templates are one fact with seven names and move
in one `stringData` merge patch. No path can write the pair without the
templates, and none can write a template without the pair.

**Why the templates are `--arg` values, not literals.** `tests/substrate_test.sh`
reads every written key out of each `"stringData":{…}` block with a regex that
stops at the first `}`. A literal `{token}` placeholder inside the jq *source*
would truncate that block after the first template, hiding four keys from the
record tripwire. Keeping the placeholders in shell values keeps all seven visible
to the check. (This is written at the code site too.)

**A malformed origin is refused by shape, naming the variable**, in
`validate_app_base_url`, before the port-forward and the four API calls — so a
typo costs a sentence, not a minted account and a rollout that never goes Ready.
Unset is not a refusal.

## 3. The test and the control — `tests/substrate_test.sh`

Section **18c**, in the established style:

| assertion | green | red control |
|---|---|---|
| step 11 writes identity's pair **AND** its five link templates when `KIT_SUBSTRATE_APP_BASE_URL` is set | `$mint_fixed` (real mint, real mocks) | the shipped shape: `sed '/LINK_TEMPLATE/d'` leaves the pair and drops the templates |
| step 11 writes **NO** identity courier key when the base URL is unset | `MINT_APP_BASE_URL=__UNSET__` | — (the control is the configured case, which must differ) |
| the installer's own output **says** which mail path the box has | both branches above assert their report line | — |

`check_mint_mail_path` is **identity's all-or-nothing rule in executable form**:
it runs step 12 for real and then reads `identity-secrets`, deciding
`present == 0` (no-mail, green), a half pair (red), or pair-without-templates
(red). The **red control** is the exact shape this packet exists for, and the
test asserts the refusal **names the variable** (`INVITATION_LINK_TEMPLATE`) —
matched with a shell `case`, never a pipe. The fixture is asserted to really be
that shape (templates gone, pair present) before the control is allowed to count;
a mutation that broke nothing would prove nothing. The unset branch is proven
green **and** asserted to still write courier's required pair.

The `KIT_SUBSTRATE_APP_BASE_URL` value is a **test fixture** (`https://app.example.com`),
never a shipped default. `mint_step` emits it by default so the pre-existing pair
tests keep exercising the configured path, and `MINT_APP_BASE_URL=__UNSET__`
selects the no-mail branch.

## 4. Suite counts

```
bash tests/substrate_test.sh
-- substrate_test: 241 passed, 0 failed, 0 skipped
PASS: 241 passed, 0 failed, 0 skipped
```

All three new assertions and the red control appear in the log and pass:

```
PASS substrate_test: step 11 writes identity's courier pair AND its five link templates when KIT_SUBSTRATE_APP_BASE_URL is set
PASS substrate_test: control: a pair written with no link template goes red, naming the variable
PASS substrate_test: step 11 writes NO identity courier key when KIT_SUBSTRATE_APP_BASE_URL is unset
```

`bash -n` clean on `install.sh` and `substrate_test.sh`; `shellcheck -S warning`
clean on both.

**The narrow gate the brief names was run; the full `tests/validate.sh` was
not.** Its substrate-touching static checks are shellcheck and the executable
bit on `install.sh` (both clean above); its docker and lint tiers are the
manager's/CI's run, and this packet's scope is the narrow gate.

## 5. What I deliberately did NOT do

- **No guessed URL, no localhost default.** The value is optional with no
  default; the only place a URL appears is the operator's export line and the
  test fixture.
- **No chart edits.** `KIT_SUBSTRATE_APP_BASE_URL`'s templates ride the same
  secret the charts already mount with `envFrom`, exactly as the pair did.
- **No service-repo edits, no `.github/workflows/`, no merge, no push.** All
  identity reads were READ-ONLY.
- **No second writer of the base URL.** It is one input, one derivation, one
  patch.
- **No change to the mint's four API calls, its guard, or its bounds.**
- **Not addressed here** (other packets own them): the signup probe's
  port-forward race (`roll-c5-migrations`), gateway's `ASSERTION_SIGNING_KEY`
  (`roll-c5-gateway-key`, whose chart-inventory check is on that branch), and
  parlor's schema family.
