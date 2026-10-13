# roll-c5-mint-pair — the mint wrote half a pair, and the done path exited 1

**Branch:** `roll/c5-mint-pair`, cut from master. Commits:

```
fix(substrate): the mint writes each credential pair whole, and the done path exits 0
docs(changelog): the half-pair defect, the global RETURN trap, and what proves each
docs(report): roll-c5-mint-pair — the pair's four keys, the trap's mechanism, the controls
```

**Source of the live evidence:** `reports/REPORT-roll-c4-e2e.md:126-136` (the
manager's end-to-end run), which quotes both the `install.done` event and the
two failures in the same step.

## Defect A — the token was written without its base URL

Step 11 minted one API key and patched the two tokens, and the restarted
identity exited 1 on its own fail-closed loader:

```
loading configuration: invalid courier configuration:
COURIER_BASE_URL and COURIER_TOKEN must both be set, or neither of them: a base URL
with no credential sends every message as an anonymous caller and courier answers 401
```

The loader is `identity/internal/config/config.go`, `loadCourier` (lines
1097-1124): it counts the two values and refuses `present != 2`. identity's
chart mounts `identity-secrets` with `envFrom` and puts only `PORT` in its
`env:`, so the **only** door for `COURIER_BASE_URL` is the same secret the token
rides — which is why the fix writes both into one patch rather than editing a
chart the substrate does not own.

Courier's side has the same shape: `COURIER_IDENTITY_TOKEN` is required
(`courier/config/runtime.exs:227-229`), and `COURIER_IDENTITY_URL` defaults to
`http://identity:8080` (`runtime.exs:188-190`) — the compose-network spelling,
which does not resolve from the `courier` namespace to a Service in `identity`.

### The pair's exact names and targets, and where each was read

| target secret | key | value | read from |
|---|---|---|---|
| `identity-secrets` | `COURIER_BASE_URL` | `http://courier.courier.svc.cluster.local:4000` | courier's Service: `courier/chart/templates/service.yaml` (`name: courier`), port `courier/chart/values.yaml` `service.port: 4000`; namespace from kit's own `manifests/applications/courier.yaml` (`destination.namespace: courier`) |
| `identity-secrets` | `COURIER_TOKEN` | the value identity minted | the mint's response (unchanged) |
| `courier-secrets` | `COURIER_IDENTITY_URL` | `http://identity.identity.svc.cluster.local:8080` | identity's Service: `identity/chart/templates/service.yaml` (`name: identity`), port `identity/chart/values.yaml` `service.port: 8080`; namespace from `manifests/applications/identity.yaml` (`identity`) |
| `courier-secrets` | `COURIER_IDENTITY_TOKEN` | the same minted value | the mint's response (unchanged) |

The env-var names are from the services' loaders, not guessed:
`COURIER_BASE_URL`/`COURIER_TOKEN` from `identity/internal/config/config.go`
and the identity chart `values.yaml` comment; `COURIER_IDENTITY_URL` from
`courier/config/runtime.exs` and `COURIER_IDENTITY_TOKEN` from
`courier/chart/values.yaml`. The two URLs live as constants in `install.sh`
(`COURIER_URL`, `IDENTITY_URL`) beside `NATS_URL`, with the chart provenance
written at the code site — one fact, one line.

Both keys of a pair go in ONE `jq`-built `stringData` object, because two
values that must move together are one fact with two names: no path can write a
token without its URL.

## Defect B — `install.done`, then exit 1

```
{"event":"install.done","step":11,…}
/var/lib/substrate/install.sh: line …: forward_pid: unbound variable
```

**The mechanism, read out of the file.** `mint_courier_identity_token` starts
the port-forward in the background and installs
`trap 'kill "$forward_pid" …' RETURN`. A bash `RETURN` trap is **global**: bash
runs it after **every** function return, not only the return of the function
that set it. So it fired once at the mint's own return (correct — the `local`
is still in scope there) and then fired **again** when the caller returned —
`main`, at the very end of the install — where `forward_pid` has left scope and
`set -u` turns the reference into a fatal `forward_pid: unbound variable`. The
trap command's failure is the process's exit status, so an install that had
completed all eleven steps exited 1.

Measured minimal reproduction of the mechanism (the fix, then the pre-fix
shape, each with the mint called from a caller as `main` does):

```
$ bash /tmp/trap_prefix.sh     # trap 'kill "$forward_pid" …' RETURN
mint body
wrapper after
/tmp/trap_prefix.sh: line 7: forward_pid: unbound variable
prefix exit=1
$ bash /tmp/trap_fixed.sh      # trap 'kill "$forward_pid" … ; trap - RETURN' RETURN
mint body
wrapper after
END
fixed exit=0
```

**The fix:** the trap body ends with `trap - RETURN`, so it runs **at most
once** — on the return where the variable is still in scope — and can no longer
fire at the caller's return. The reason is written at the code site, naming the
global-trap rule and the two returns.

## Controls — each claim, and what goes red

`tests/substrate_test.sh`:

| assertion | green | red control |
|---|---|---|
| the recorded secret list matches `install.sh` | real tree | (a) `--from-literal=COURIER_SMTP_PASSWORD=` removed; (b) `"COURIER_IDENTITY_TOKEN":$t` removed from its patch; (c) `"COURIER_BASE_URL":$url,` removed from its patch; (d) an unrecorded `--from-literal` added |
| step 11 writes **both halves of each pair** | real mint against the mock | the same mint with `"COURIER_BASE_URL":$url,` stripped — token written, base URL not, the exact shape that shipped |
| the done path **exits 0** with the mint called **from a caller**, as `main` calls it | real mint wrapped in a function | the same fixture with the trap's `; trap - RETURN` stripped — the pre-fix shape — which exits 1 |
| the mint writes one value into both secrets (pre-existing) | real mint | the `-` patch spelling aborts the mint |

`check_mint_writes_pair` asserts all four keys against the values read from the
two charts (above). `check_mint_exit_zero` runs the mint wrapped in a function,
which is the only shape that triggers the caller-return trap; a top-level call
(the default `mint_step`) could never prove the exit code. The control fixture
is asserted to really be the pre-fix shape (self-removal gone, trap present)
before the control is allowed to count — a mutation that broke nothing would
prove nothing.

The sibling packet's chart-inventory check (`check_chart_secret_keys`, branch
`roll/c5-gateway-key`) is **not on this branch**, so the pair is asserted
explicitly, as the brief allows.

## Suite counts

```
bash tests/substrate_test.sh
-- substrate_test: 215 passed, 0 failed, 0 skipped
PASS: 215 passed, 0 failed, 0 skipped
```

All four new assertions and their three new red controls appear in the log and
pass. `bash -n` clean on `install.sh` and `substrate_test.sh`; `shellcheck -S
warning` clean on both.

## THE BLOCKER THIS PACKET'S GOAL ALSO NEEDS — identity still needs link templates

The packet's goal is three claims; two are proved here (the pair, exit 0). The
third — **"a restarted identity boots"** — needs one more thing, and it is
recorded rather than guessed.

Wiring the courier block makes `loadCourier` continue past the pair check into
`resolveLinkTemplates` and `resolveInvitationLinkTemplate`, which **require**
at least one link template plus `INVITATION_LINK_TEMPLATE` whenever the block
is wired. identity's own config test says it in the name:

```
internal/config/courier_test.go:62
    name: "a base URL and a token with no link template",
    env:  {"COURIER_BASE_URL": …, "COURIER_TOKEN": …},
    wantErr: ErrInvalidCourier,
```

The substrate sets no `*_LINK_TEMPLATE` at all — identity's chart `env:` has
only `PORT`, and the substrate's `identity-secrets` is built from
`DATABASE_URL`/`SIGNUP_SIGNING_KEY`/`MFA_ENCRYPTION_KEY`/`NATS_URL` — so after
this pair fix a restarted identity refuses on the **next** check. That is not a
regression this packet introduces; it is the second half of the same
incompleteness, and it was invisible until the first half was fixed.

The launch stack sets all four (`launch/docker-compose.launch.yml:326-375`:
`PASSWORD_RESET_LINK_TEMPLATE`, `EMAIL_VERIFICATION_LINK_TEMPLATE`,
`EMAIL_CHANGE_LINK_TEMPLATE`, `RECOVERY_LINK_TEMPLATE`,
`INVITATION_LINK_TEMPLATE`), built from `${APP_BASE_URL}`. The substrate has no
`APP_BASE_URL` equivalent, and its public host is a gateway-ingress value the
installer never sees, so the right values are a **deployment decision**, not a
chart read. I did not invent them.

**The successor's first move:** decide whether the substrate's identity is
meant to have a mail path. If yes, add `KIT_SUBSTRATE_APP_BASE_URL` (the same
pattern as the required SMTP settings) and write the four/five link templates
into `identity-secrets` in the same patch as the pair — the values are
one-fact-one-render with `launch/docker-compose.launch.yml`. If no, do not
write `COURIER_TOKEN` into `identity-secrets` at all, and say so: an identity
with half a courier block is worse than one with no mail path. Either way, the
record tripwire and the pair test here already cover the keys that exist today.

## What I deliberately did NOT do

- **No chart edits.** The substrate does not own the two service charts (they
  are OCI, built and published elsewhere), so `COURIER_BASE_URL` and
  `COURIER_IDENTITY_URL` ride the secrets the charts already mount with
  `envFrom`. Moving them to a chart `env:` block is a chart packet.
- **No link-template values invented.** See the blocker section above — the
  public app URL is a deployment decision and the installer has no input for
  it. Inventing one would trade "identity refuses to boot loudly" for "identity
  boots and mails links that 404", which is strictly worse.
- **No second writer.** The URLs are constants in `install.sh` beside
  `NATS_URL`; the README and the code site both name the chart the value came
  from, rather than restating it in the charts.
- **No `2>/dev/null` suppression of the trap error.** The exit code is the
  contract; the lifetime is what was fixed.
- **No touching of service repos, `.github/workflows/`, or other branches.**
- **No change to the mint's four API calls, its guard, or its bounds.**
- Not addressed here (other packets own them, per
  `REPORT-roll-c4-e2e.md`): the signup probe's own port-forward race
  (`roll-c5-migrations`), gateway's missing `ASSERTION_SIGNING_KEY`
  (`roll-c5-gateway-key`), and parlor's schema family.
