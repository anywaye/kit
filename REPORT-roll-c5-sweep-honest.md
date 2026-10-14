# REPORT-roll-c5-sweep-honest: the orphan sweep keeps a working mail path

## The live-box evidence

The Contabo box carries a COMPLETE, working courier block — seven keys:
`COURIER_BASE_URL` and `COURIER_TOKEN` both present, five link templates
derived from `https://app.cafaye.com` — and identity boots and reports:

```
account recovery can send all four messages through courier: password reset,
address verification, and both halves of an email change
```

The sweep as it stood, run with `KIT_SUBSTRATE_APP_BASE_URL` unset, collected
all seven keys into `orphans` and deleted them, printing:

```
identity's mail path is NOT configured (KIT_SUBSTRATE_APP_BASE_URL unset):
removed orphaned courier key(s): COURIER_BASE_URL COURIER_TOKEN … — leftovers
from an installer that wrote half a pair
```

Two falsehoods in one line: "leftovers from an installer that wrote half a
pair" asserts a provenance the installer never checked (both halves are
present, the pair matches the credential courier presents, identity is sending
mail), and "removed" is the whole story with no mention that the box went from
a working mail path to 503 on every recovery route. Same class as
`roll-c5-honest-done`: the installer reported a box that is not the box it
produced.

## The two shapes, and what happens to each

| | half-pair / stray template | complete pair |
|---|---|---|
| shape | `COURIER_BASE_URL` xor `COURIER_TOKEN`, or a lone template | both present, with or without templates |
| identity boots? | no — `loadCourier` refuses, CrashLoopBackOff | yes |
| verdict | orphan: swept exactly as before | working mail path: NOT swept |
| report | `removed orphaned courier key(s): <keys>` — each removed key named, no kept key named | `identity carries a working mail path … this run has no KIT_SUBSTRATE_APP_BASE_URL to rewrite it with, so the mail path stays, nothing removed, and every recovery route keeps answering — set KIT_SUBSTRATE_APP_BASE_URL to rewrite …` |
| restart | identity restarted | identity NOT restarted |
| empty run | `… no identity courier keys written, nothing removed, so identity boots into its supported no-mail state …` | — |

The classification mirrors `loadCourier`'s `present != 2` rule
(`identity/internal/config/config.go:1121`). Default is keep: silently
regressing a working box is the worse failure, and a step that cannot write
the correct value must not delete the correct value already there. The
half-pair sweep is unweakened (a lone `COURIER_TOKEN` crashloops; the sweep
is the only thing that heals it). `KIT_SUBSTRATE_APP_BASE_URL` is never
guessed. The read-back verification is unchanged: a sweep that does not
converge still fails the step naming the leftovers. The mint's closing line
splits the same way (kept path vs off-by-design); `IDENTITY_MAIL_PATH_KEPT`
is a shell-local flag, not exported, so the env surface is untouched.
`loadCourier` itself is unchanged.

## Controls' verdicts (`bash tests/substrate_test.sh`: 309 passed, 0 failed)

- Green, real tree (§18d): half-pair + stray template swept, block verified
  empty, unrelated keys kept, courier pair written, identity restarted, log
  names `COURIER_TOKEN` and `EMAIL_CHANGE_LINK_TEMPLATE`, log names no kept
  key (`NATS_URL` absent).
- Green, real tree (§18e, new): complete pair with all five templates left in
  place byte-identical (`COURIER_TOKEN` still `live-box-working-token`),
  report says working mail path + names `KIT_SUBSTRATE_APP_BASE_URL` + says
  nothing removed, no `leftovers`/`orphaned courier key` wording, identity
  NOT restarted, courier pair still written and courier restarted.
- Green, real tree (§18c): empty run says `mail path is NOT configured` and
  `nothing removed`.
- Red control 1 (new): classification forced false (`if false` at the
  `SWEEP-HONEST-CLASSIFY` marker, premise asserted) → pair deleted → the
  keep-check fails naming the deletion (`went from sending mail`). Proves the
  check discriminates the pre-fix behavior.
- Red control 2 (new): orphan sentence planted in the keep-branch report
  (keys still kept, classification intact, premise asserted) → the keep-check
  fails on the message assertion. Proves the wording check is not vacuous.
- Read-back failure (pre-existing §18d control): unchanged, still fails the
  step.

## Collateral repair (required for green, not part of the packet)

The OIDC three-key red control read its fixture from `HEAD~1`. The Q1 commit
of this packet shifted the parent from the three-key tree (`aca1756`) onto
the four-key tree (`d7732d5`), turning that control red (`unbound variable`
on `KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL`). The fixture now locates the
commit that wired `OIDC_LOGIN_UI_URL` via pickaxe and reads that commit's
parent — same three-key content, immune to further commits on this branch.
No OIDC behavior changed.
