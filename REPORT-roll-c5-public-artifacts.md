# REPORT — roll-c5-public-artifacts

**Packet:** step 5 demands a box-bound capability for artifacts that are public.
**Branch:** `roll/c5-public-artifacts` (cut from master at `52c423e`). **Worktree:**
`moon/wt/roll-c5-public-artifacts`.
**Status:** installer + tests + README committed; `bash tests/substrate_test.sh`
green at **365 passed, 0 failed**; full gate verdict pending at time of writing
(see §7). The packet's real proof — `local-cycle.sh` reaching `install.done` —
is **NOT met**, and the reason is a registry fact rather than an installer
defect (§5). Every control the packet names is proven; the red ones went red.

---

## 1. What was measured (anonymous, no credentials, today)

Two calls per artifact — an anonymous token from
`https://ghcr.io/token?scope=repository:<repo>:pull&service=ghcr.io`, then a
manifest HEAD carrying it. A token alone proves nothing (a public repo with a
missing tag issues a token and 404s the manifest), so both halves must answer.
Accept header carries all four OCI/Docker manifest media types: asking for only
`image.manifest` 404s artifacts stored as an `image.index` (measured on
`cafaye/charts/identity:0.1.0` — 404 with one type, 200 with the list).

| artifact | token | manifest | verdict |
|---|---|---|---|
| `cafaye/identity:0.1.0` | issued | 200 | public |
| `cafaye/gateway:0.1.0` | issued | 200 | public |
| `cafaye/courier:0.1.0` | issued | 200 | public |
| `cafaye/parlor:0.1.0` | issued | 200 | public |
| `cafaye/pantry:0.1.0` | issued | 200 | public |
| `cafaye/keyholder:0.1.0` | issued | 200 | public |
| `cafaye/box:0.1.0` | **DENIED** (`UNAUTHORIZED`) | — | **private or unpublished** |
| `cafaye/charts/identity:0.1.0` | issued | 200 | public |
| `cafaye/charts/gateway:0.1.0` | issued | 200 | public |
| `cafaye/charts/courier:0.1.0` | issued | 200 | public |
| `cafaye/charts/parlor:0.1.0` | issued | 200 | public |
| `cafaye/charts/keyholder:0.1.0` | issued | 200 | public |
| `cafaye/charts/pantry:0.1.0` | **DENIED** | — | **private or unpublished** |
| `cafaye/charts/box:0.1.0` | **DENIED** | — | **private or unpublished** |

**11 of 14 public, 3 refused.** The packet's table claims all seven images and
all seven charts are public; that claim is wrong for three artifacts as of this
run. (Corroboration from inside this tree: the CHANGELOG's pantry entry already
records "both token scopes still DENIED at this writing" for pantry's image and
chart — the image has since been made public, the chart has not.) Token-denied
is indistinguishable between private and never-published; both take the
capability path, so the installer does not need to tell them apart.

Probe cost, live: 14 artifacts × 2 calls in **~14 s** typical, every call
bounded by `KIT_SUBSTRATE_REGISTRY_PROBE_TIMEOUT` (default 10 s) plus a 5 s
connect timeout — worst case ~280 s, never a hang. Runs once per install.

## 2. The derivation (no flag)

`registry_derived_artifacts` reads `manifests/applications/*.yaml`: a `repoURL`
of `oci://ghcr.io/<path>` plus its `targetRevision` yields one `<path> <rev>`
row (the chart Argo pulls); a path under `cafaye/charts/<name>` yields a second
row `cafaye/<name> <same rev>` (the image that chart runs). Non-GHCR charts
(alloy, grafana, prometheus over plain-HTTPS Helm repos) need no registry
credential and are excluded: the secret this step writes is a `ghcr.io`
credential, so the question is only ever about `ghcr.io`.

The image half is the fleet's own convention — the publish path names the image
`ghcr.io/cafaye/<chart>` and tags it with the chart's version, verified per
service in its chart's `values.yaml` (identity, gateway, courier, parlor,
pantry, box, keyholder: all `tag: "0.1.0"`). The probe measures rather than
assumes: a chart whose image moves takes the capability path with nobody
editing the installer. No `KIT_SUBSTRATE_ARTIFACTS_PUBLIC` flag was added — a
flag is a claim the operator makes; the probe is a fact the installer
established.

Off the real tree the derivation yields exactly 14 rows (7 charts + 7 images),
pinned by a test.

## 3. The anonymous path's shape: empty `auths`, not no secret

The step writes the Secret on both halves — same name (`ghcr-pull-secret`),
same type (`kubernetes.io/dockerconfigjson`), same seven namespaces, same pipe
(`--from-file` through stdin, decoded once). The anonymous half's content is
`{"auths":{}}`.

Why not skip the Secret: three charts (box, keyholder, pantry) name
`imagePullSecrets: ghcr-pull-secret` in their Application values, so the object
must EXIST wherever a pod references it. A missing Secret is a kubelet-level
failure whose voice varies by version; an empty-auths Secret is inert
everywhere — GHCR falls back to anonymous for public pulls (the C3-measured
property), and Argo plus the kubelet see one contract on both paths. The test
proves the content both ways: the anonymous Secret decodes once to empty
`auths`, and a Secret carrying a credential where the anonymous half should be
would fail that read.

## 4. The capability path is unchanged, except it names names

Same box-id refusal, same shape check (`registry_capability_shape_ok`
untouched), same exchange call, same secret shape — with one appended line on
each of the two pre-network refusals:

```
…what the registry capability is bound to — this install pulls private artifact(s) needing a credential: cafaye/charts/box:0.1.0 cafaye/box:0.1.0 cafaye/charts/pantry:0.1.0
```

With an empty private list (including every existing suite caller, which drives
`exchange_registry_credential` directly) the suffix is empty and both refusals
read byte-identically to before. The box id is likewise only demanded on the
private half — an anonymous fetch asks for no identifier.

The readiness report names the path in both modes: the human report prints
`registry: every artifact is public; no registry credential was needed` (or the
capability line), and the headless `readiness` event carries a new
`"registry_path":"anonymous|capability"` field beside the untouched
`tls_pending_hosts`/`oidc_configured`/`log_store`.

## 5. The local cycle: what ran, where it stopped, and what unblocks it

```sh
env -u KIT_SUBSTRATE_BOX_ID -u KIT_SUBSTRATE_REGISTRY_CAPABILITY \
  KIT_SUBSTRATE_DATABASES="identity,gateway,courier,parlor,pantry,box" \
  KIT_SUBSTRATE_SMTP_HOST="smtp.fixtures.invalid" \
  KIT_SUBSTRATE_SMTP_USERNAME="fixture-label" \
  KIT_SUBSTRATE_SMTP_PASSWORD="fixture-label-not-a-credential" \
  KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET="whsec_fixture-label" \
  bash templates/substrate/local-cycle.sh
```

Result on cluster `cafaye-local` (reused, operators present): **15 seconds,
exit 1, stopped at step 5** — `install.done` NOT reached. Steps 1–3 skipped on
cluster evidence, step 4 applied (0.244 s), step 5 probed all 14 artifacts,
found the 3 private ones, and refused:

```json
{"event":"refusal","step":5,"phase":"pull-secret","input_needed":"KIT_SUBSTRATE_BOX_ID","human":"export KIT_SUBSTRATE_BOX_ID='<the enrolled uuid of this box>' and re-run — the box's own identity, and what the registry capability is bound to","message":"KIT_SUBSTRATE_BOX_ID is not set\n  export KIT_SUBSTRATE_BOX_ID='<the enrolled uuid of this box>'\n  # the box's own identity, and what the registry capability is bound to — this install pulls private artifact(s) needing a credential: cafaye/charts/box:0.1.0 cafaye/box:0.1.0 cafaye/charts/pantry:0.1.0"}
```

**The unblock is a registry fact, not an installer edit:** make
`cafaye/box` (image), `cafaye/charts/box`, and `cafaye/charts/pantry`
publicly visible (or publish them, if they were never pushed), and the same
command takes the anonymous half. No capability, no exchange, no code change.
The packet's "green, real tree: with every artifact public" control has a
false premise today; the installer honors the true one.

Two further findings for the successor, both met on this run but worth naming:
- `local-cycle.sh`'s `KIT_SUBSTRATE_DATABASES` default
  (`identity,gateway,courier,parlor`) no longer equals the Cluster manifest's
  set (now six with pantry and box) — step 8 refuses the mismatch, so the
  default must be passed over (as above) until the file's default is updated.
  Untouched per the packet's "do not touch the local-cycle entry".
- Step 9's live path requires the four courier SMTP/signing values; labelled
  fixtures (`.invalid` host, never routed) carry the run past it. Steps 6–13
  past step 5 are otherwise unblocked on public artifacts (migrate images for
  identity/courier/pantry are all public; nothing waits on box).

## 6. The controls and their verdicts

| control (packet) | verdict |
|---|---|
| Green: all public + no capability/box-id → anonymous path | **PASS** (suite §13e, mock GHCR answering all-public; installer succeeds, empty-auths Secret in every namespace, exchange route never spoken, anonymous line printed) |
| Green: one private artifact → capability path, refusal names it | **PASS** (suite §13e; live local-cycle run above names all three) |
| Green: capability path unchanged (same refusals/exchange/secret) | **PASS** (all pre-existing §13c assertions green unmodified, plus a new private+valid-capability exchange test) |
| RED: master step fails "public needs no capability" | **PASS / quoted** — master `exchange_registry_credential` with no box id, before seeing any artifact: `error: KIT_SUBSTRATE_BOX_ID is not set / export KIT_SUBSTRATE_BOX_ID='<the enrolled uuid of this box>' / # the box's own identity, and what the registry capability is bound to`; with a box id and no capability: `error: KIT_SUBSTRATE_REGISTRY_CAPABILITY is not a minted capability / export KIT_SUBSTRATE_REGISTRY_CAPABILITY='<cap_… from caf box enroll>' / # a dockerconfigjson belongs in the OLD runbook: it is exchanged, not pasted`. Pinned in-suite (`control: the exchange alone still demands a capability…`). |
| RED: probe-answered-but-unfetchable must not pass silently | **PASS** (suite §13e: token answers, manifest 404s on `cafaye/charts/identity:0.0.0-no-such-tag` → private path, refusal names it; plus an empty-manifest-dir fail-closed refusal) |
| Independent verification: `local-cycle.sh` reaches `install.done` | **NOT MET** — 15 s, exit 1, refusal at step 5 quoted in §5. Blocked by the three non-public packages, which no installer edit can publish. |

One check was narrowed, deliberately, and the commit message says so: the
"pasted dockerconfigjson is refused before any network call" control now
asserts the pasted value appears in no call and the exchange route is never
spoken. The probe's anonymous halves run before the shape check, so zero
traffic is no longer the shape of that refusal — but the secret still travels
nowhere, which is the property the control exists to protect.

## 7. Gate status

- `bash tests/substrate_test.sh`: **365 passed, 0 failed, 0 skipped** (354
  pre-existing + 11 new), including the §14 two-writers static check with
  `registry_derived_artifacts` added to its `VALUE_PRODUCERS` in the same
  commit, `shellcheck -S warning` clean, DRY_RUN thirteen steps in order.
- `bash tests/validate.sh`: **green, exit 0** ("every check passed", 9
  loud skips, no bound reached). One failure on the first run, pre-existing
  and unrelated: `obs chart sources` classified box/keyholder/pantry as
  unclassified Applications because its `SERVICE_APPS` still named only the
  four older services — the manifests and the check were both byte-identical
  to pre-packet HEAD. Fixed by adding the three (a strengthening: three more
  Applications pinned to the private-OCI triple, fail-closed preserved), in
  its own commit with the reason.

## 8. Worktrees used

One: `moon/wt/roll-c5-public-artifacts` (this packet). No second repository
was touched — the sibling `moon/cafaye/*` service checkouts were read
(chart `values.yaml` image tags) but never modified.
