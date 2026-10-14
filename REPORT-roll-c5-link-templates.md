# REPORT-roll-c5-link-templates: the installer's link templates land readers on the right screen

## The live-box warning (the packet's premise)

```
identity: RECOVERY_LINK_TEMPLATE is the link for every purpose with no variable of its own,
and it is currently the link for: email_change, verify_email. If that template is the
password reset screen then an address confirmation or an email-change confirmation lands
the reader on a screen that answers 404 for the token it carries.
Set EMAIL_CHANGE_LINK_TEMPLATE and EMAIL_VERIFICATION_LINK_TEMPLATE to say where each kind
of link goes.
```

Cause: step 12 derived `EMAIL_CHANGE`, `EMAIL_VERIFICATION` and `RECOVERY` as three
identical strings (`${base}/verify-email/confirm?token={token}`). Identity's
`LinkPurposesUsingTheDefault` (`identity/internal/config/config.go:741`) compares
VALUES, so any purpose resolving to the default is reported even when its own variable
is set. Two of the three served no distinct screen, and the warning fired on a
configured box.

## What parlor actually serves (read, not inferred)

Parlor's repository (`../caf-rename-parlor`), both route trees and the generated table:

- `src/app`: `login register forgot-password reset-password verify-email
  verify-email/confirm invitations/[token] accounts settings admin healthz readyz`
- `src/routes` + `routeTree.gen.ts`: the same set (`reset-password.tsx`,
  `verify-email/confirm` via `verify-email/confirm.tsx`, `invitations/$token.tsx`)
- No email-change route in either tree, no `email-change`/`email_change` reference
  anywhere in `src/` or `e2e/`.
- Stronger than absence: parlor's upstream proxy table (`src/lib/upstream.ts`)
  lists `/v1/email-changes` and its two children as **deliberately absent** — no
  screen, no client call (`src/lib/identity.ts` performs none of them), proxy
  refuses. Parlor cannot redeem an email-change token at all.
- Identity's own compose spelling (`/email-change/confirm`) is a screen the front
  door never mounted; the installer must not invent it. A path parlor does not
  serve is a browser 404.

## The five derived templates, with reasons

| variable | value | reason |
|---|---|---|
| `PASSWORD_RESET_LINK_TEMPLATE` | `{base}/reset-password?token={token}` | the screen that spends a password-reset token (`POST /v1/password-resets/confirm` answers 404 for any other purpose's token) |
| `EMAIL_VERIFICATION_LINK_TEMPLATE` | `{base}/verify-email/confirm?token={token}` | the screen that spends an address-confirmation token |
| `EMAIL_CHANGE_LINK_TEMPLATE` | `{base}/verify-email/confirm?token={token}` | **documented substitution**: parlor has no email-change screen. An email-change token spent there answers identity's single `ErrTokenNotFound` and the screen renders its generic "this link cannot be used" sentence — a wrong-flow dead end on a served page, materially better than a 404. Same spelling as `launch/docker-compose.launch.yml`. |
| `RECOVERY_LINK_TEMPLATE` | **not written; a stale value is deleted** (`data`-null in the same patch) | it is the fallback for purposes with no variable of their own, and every purpose identity delivers has one — the end-state identity's own wiring test blesses (`cmd/identity/link_template_wiring_test.go`: "all three per-purpose variables set, the legacy one deleted"). A future purpose identity adds then refuses at boot naming its variable instead of silently inheriting a screen that cannot redeem it. |
| `INVITATION_LINK_TEMPLATE` | `{base}/invitations/{token}` | unchanged: parlor's accept route, a path segment |

Two purposes sharing `/verify-email/confirm` does not fire the warning: the rule
compares each purpose against the *default*, not against each other, and with no
default written there is nothing to equal (`DefaultLinkTemplate == ""` → nil).

Note: the `data`-null (not `stringData`-null) is load-bearing — a null under
`stringData` merges into a field the stored object does not carry and deletes
nothing. The mock (`rollout_kubectl`) and the box agree on this contract.

## Controls' verdicts (`bash tests/substrate_test.sh`: 325 passed, 0 failed)

- Green, real tree: the set-branch run writes the pair plus the four exact
  templates, the seeded legacy default is gone, reset ≠ verify, change == verify
  on the cited shared screen, invitation on `/invitations/{token}`.
- Green, real tree: identity's warning cannot fire — mirrored rule (no purpose
  resolves to a default; templates proved non-empty first, so vacuity cannot pass).
  Mirror, not the real rule: kit grades this tree; identity's
  `resolveLinkTemplates`/`LinkPurposesUsingTheDefault` is cited, not executed.
- Green, real tree: `INVITATION_LINK_TEMPLATE` still `${base}/invitations/{token}`.
- RED, proven red: the master derivation (three identical strings) fails naming
  `RECOVERY_LINK_TEMPLATE`. (Found in construction: the first fixture kept the new
  `data`-null, which wiped its own re-added default — the fixture now drops the
  deletion too, with the premise asserted.)
- RED, proven red: `EMAIL_CHANGE_LINK_TEMPLATE` at `/email-change/confirm`
  (unserved) fails naming the variable.
- Pre-existing controls kept green: pair-with-no-template, half-pair, unset-branch
  no-mail path, orphan sweep, and the 18e keep path — which now requires the six
  new-shape keys and asserts a legacy default on a kept box is preserved byte for
  byte (keep means keep).

Two fixture-mechanics repairs, both honest: the status line no longer contains the
`LINK_TEMPLATE` substring (the no-template control builds its fixture with
`sed /LINK_TEMPLATE/d`, which had emptied the `if` body — a syntax error, not a
finding), and the mint harness plants a legacy default on every run so the green
run proves the deletion rather than assuming a fresh store.

## Out of scope, noticed

`launch/docker-compose.launch.yml` carries the same three-identical-string shape
with the same warning attached. This packet's scope is the installer + its test;
the launch stack is flagged here, not changed here.
