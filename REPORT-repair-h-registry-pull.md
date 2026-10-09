# REPORT — repair-h: the installer pointed at the door that exists

Packet: REPAIR-H — the seam audit's §5a–5c, one design across conductor
and kit. Branch: `agents-first/repair-h`. Commits: `f9bdec6` (this
repo), `198f409` (conductor).

## The three findings, and what each became

**5a — the endpoint does not exist.** The installer posted to
`POST ${KIT_SUBSTRATE_REGISTRY_URL}/v1/boxes/{id}/registry-credentials`;
no service in the fleet serves `/v1/boxes/*` — there is no registry
service at all (the audit grepped the whole fleet: one file, the
installer itself).

**5b — the purpose is outside conductor's vocabulary.** The request sent
`purpose: "registry.pull"`; conductor's `Capability::PURPOSES` was
`["box.enroll","artifact.fetch"]` and the mint refused it with 422.

**5c — the response contract disagrees.** The installer decoded the body
AS a base64 dockerconfigjson; conductor's redeem answers JSON, so even a
re-pointed URL failed the base64 check.

## Design decision 1 — where the door lives

**The installer now redeems at conductor's
`POST /v1/capabilities/redeem`** — the one redeem door the fleet built
(W1-P3, W4-P2, W4-P3 all redeem through it). The URL variable was renamed
with the door: `KIT_SUBSTRATE_REGISTRY_URL` →
`KIT_SUBSTRATE_CONDUCTOR_URL` (default `https://conductor.cafaye.com`,
configuration not a secret; a self-hosted fleet points it at its own
conductor). The name matches the service that answers — the audit's §6
already flags env-name drift as a fleet problem, and a variable named
for a registry that does not exist would be one more.

The request body still names the purpose and the box
(`{"token":…, "purpose":"registry.pull", "box_id":…}`) — the same
purpose/box naming the request always carried, now answered by a route
that enforces them server-side (conductor's `Capability.redeem!` checks
both before the single-use spend; a mismatch is a 403
`capability_wrong_purpose` / `capability_wrong_box` and does not
consume the token).

## Design decision 2 — the response is parsed as the route renders it

**The receipt, not a base64.** Conductor answers
`{capability:{purpose,box_id,account_id,expires_at}}`; the installer
parses exactly that (jq — already a hard requirement, step 11 reads
identity's mint response with it), and checks every field:

- `capability.purpose` must be `registry.pull` — a receipt for another
  purpose is refused, naming the purpose;
- `capability.box_id` must be THIS box — a receipt for another box is
  refused, naming the box;
- `capability.account_id` must be present;
- `capability.expires_at` must be a live instant (conductor's iso8601
  UTC shape, compared as a string — identical-format UTC timestamps
  order lexicographically as they order chronologically).

A body that is not the receipt JSON at all is refused. `curl -f` turns
every conductor refusal (401/403/409/410 — expired, already redeemed,
wrong purpose, wrong box) into a non-zero exit, and that is a refusal
whose fix is "re-run `caf box enroll`", never "try another value".

## Design decision 3 — what the exchange becomes, and the honest gap

**The write is refused, and the refusal names the gap.** Conductor's
receipt is proof the box-bound, purpose-bound capability was accepted —
and it is all a client can honestly consume today. The second half of
the exchange, the registry service that would trade a redeemed
capability for a short-lived dockerconfigjson, **does not exist in the
fleet yet**: conductor holds no registry credential (boundary 6, and
this packet's avoid-list), and no registry service is in any plan. So
`install_pull_secret` redeems, verifies the receipt, and then refuses:

> the registry-side exchange does not exist yet — conductor redeemed the
> capability for box … (purpose registry.pull), but no service in the
> fleet trades a redeemed capability for a dockerconfigjson (seam audit
> §5a-5c)

A placeholder pull secret was rejected for this installer's own preflight
reason — it installs, schedules pods, and fails at image-pull time in a
voice nobody can attribute ("a half-installed substrate is worse than no
substrate, because it looks like it works"). The capability's SHAPE check
(the pasted-dockerconfigjson refusal) and the secret-free stdout
tripwire are untouched; the tripwire's controls are repointed at the
redemption round trip (`response`).

## What is proven, and how

`tests/substrate_test.sh` section 13c, against a mock curl that records
what the installer sends and answers with a planted receipt (a LABEL,
not a credential, like every fake in that file):

- the redemption POSTs to `/v1/capabilities/redeem` with the capability
  as bearer and a body naming purpose and box (the recorded call is
  asserted, not the mock's say-so);
- a good receipt → the step refuses the WRITE, exit 1, and the refusal
  names the registry-side exchange as the remaining gap;
- the receipt's checks each bite, one case per refusal: wrong-purpose
  receipt, wrong-box receipt, non-JSON body, past `expires_at`, dead
  conductor (curl fails) — each must exit non-zero naming THAT failure;
- neither the capability nor the receipt's fields appear in the step's
  output (the tripwire on the live path).

**115 passed, 0 failed, 0 skipped** (was 91 before the packet). The old
13c's assertion — that the redeemed dockerconfigjson lands in a
`kubernetes.io/dockerconfigjson` Secret in all six namespaces — is
gone, because the write it proved no longer exists by design; the new
13c proves the contract that replaces it. `shellcheck -S warning` clean.

## What is NOT proven

That a real conductor answers the redemption — the mock answers
conductor's exact shape, field for field, and conductor's request specs
prove that shape is what the route renders. That a real capability
mints — the minter has no caller in any repo (audit §5c). That a real
registry trades the receipt for a pull credential — **the registry-side
exchange is the remaining gap**, and it is the successor's packet: a
registry service that accepts a redeemed `registry.pull` capability and
answers a short-lived dockerconfigjson, at which point the write this
step refuses becomes the thing it does.
