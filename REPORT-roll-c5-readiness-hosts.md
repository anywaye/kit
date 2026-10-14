# REPORT-roll-c5-readiness-hosts: the readiness preflight now reads Ingress hosts

## The defect, from the cold box

The box's readiness event, in the headless JSONL:

```json
{
  "event": "readiness",
  "step": 13,
  "phase": "rs-residual",
  "message": "readiness: 2 condition(s) keep this box from fully serving",
  "tls_pending_hosts": ["app.cafaye.com", "auth.cafaye.com"],
  "oidc_configured": true,
  "log_store": "journald"
}
```

**Two hosts. The box has three.** `kubectl get ingress -A` on the same box:

```
NAMESPACE   NAME       CLASS     HOSTS            ADDRESS          PORTS
gateway     gateway    traefik   api.cafaye.com   169.58.108.209   80, 443
parlor      parlor     traefik   app.cafaye.com   169.58.108.209   80, 443
```

and `kubectl get certificates -A`:

```
gateway   gateway-tls   False   gateway-tls   98m
parlor    parlor-tls    False   parlor-tls    98m
```

`api.cafaye.com` is missing from `tls_pending_hosts` — and it is the host of a
Certificate that has been `False` for 98 minutes. The number the installer
reports is wrong in the direction that matters: it says the box has fewer
problems than it does.

## Why, exactly

`kit_substrate_intended_hosts` built its list from three sources:

1. `KIT_SUBSTRATE_APP_BASE_URL` → `app.cafaye.com`
2. `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER` → `auth.cafaye.com`
3. a `grep -oE 'https?://[^"' <>]+'` over the Application manifests, minus `repoURL:` and `destination:`

**An Ingress host is a bare hostname, not a URL.** `api.cafaye.com` appears in
the tree as `host: api.cafaye.com` (or in the chart's values as a host string)
and the URL grep cannot match it by construction — the pattern requires a
scheme. `app.cafaye.com` is caught only because `KIT_SUBSTRATE_APP_BASE_URL`
happens to name the same host as parlor's Ingress; the coincidence hides the
gap for one of the three.

## The change

`templates/substrate/install.sh`, in the readiness-honesty block:

- **`kit_substrate_intended_host_table [manifest_dir]`** — the derivation,
  now one function emitting `host<TAB>source` rows. Three sources, all read
  rather than listed:
  1. the operator's two URLs (`KIT_SUBSTRATE_APP_BASE_URL`,
     `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER`);
  2. any public https URL in the Applications' `helm.values` (comments
     stripped, fetch coordinates dropped by key) — the old source 2,
     unchanged;
  3. **an Ingress host**: a `host:` key in the manifests and in the charts'
     values, via the new `kit_substrate_ingress_hosts` — parsed as key lines
     (after indentation and an optional YAML list dash), value taken to end
     of line with surrounding quotes dropped, over COMMENT-STRIPPED text.
     `kit_substrate_ingress_host` then normalises the value (a URL-shaped
     value goes through `kit_substrate_url_host`; a bare host keeps its
     name, a `:port` suffix dropped).
- **`kit_substrate_intended_hosts`** is now the table's first column — every
  existing caller and the JSONL field keep the hosts-only contract.
- **Dedup is by host, first source wins**, so a host reachable from two
  sources is reported once, and the reported order is fixed between runs
  (operator URLs, values URLs, ingress hosts, in file order).
- **`kit_substrate_is_checkable_host`** now also drops `127.*` — a chart's
  `host:` value may carry `127.0.0.1` and it resolves on the box by
  construction. The existing rules (in-cluster, localhost, single-label)
  stay untouched.
- **The reports name the source.** The preflight prints every intended host
  and where the derivation got it; each pending host and the final report's
  remedy line carry the source beside them.
- **The count follows the list**: `kit_substrate_readiness_pending_count` is
  unchanged and now counts the longer list — on the live box's shape, 3.

### Where each host in the derivation comes from

| source | example on this tree | how it is read |
| --- | --- | --- |
| `KIT_SUBSTRATE_APP_BASE_URL` | `https://app.cafaye.com` | `kit_substrate_url_host` |
| `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER` | `https://auth.cafaye.com` | `kit_substrate_url_host` |
| an https URL in an Application's `helm.values` | a chart's `PUBLIC_URL` value | `grep -oE 'https?://…'` over comment-stripped manifests, fetch coordinates dropped by key |
| an ingress host in the manifests | `- host: api.cafaye.com` (`spec.rules`) | `kit_substrate_ingress_hosts` |
| a host in the charts' values | `ingress:\n  host: …` in `helm.values` | `kit_substrate_ingress_hosts` |

### The one source this cannot read — stated, not hidden

An Ingress host that exists **only inside a chart's templates**. The gateway
chart renders `api.cafaye.com`, and no manifest, no values override and no
operator input on this tree names it: a box-side derivation reads the tree the
box runs, not the chart's compiled sources. The comment above the derivation
says so, and where a chart's values *do* carry the host (an Application's
`helm.values` override) source 3 reads it. Where the host is template-only,
the fix belongs in the tree — name the host in the Application's values —
never in a list here. This is the same discipline as the charter's "do not add
`api.cafaye.com` as a literal": the derivation reads what the tree ships.

## The controls

In `tests/substrate_test.sh` §27 (continued), with the repo's mock harness
(install.sh sourced with its trailing `main` stripped, fixture Applications
built per check, assertions by `case` and counted lines, every fixture
assuming `$WORK` and swept by the EXIT trap). `*.invalid` never resolves
(RFC 2606); `localhost` and `127.0.0.1` are excluded by rule. No network.

**Greens (all real tree, all PASS):**

| check | verdict |
| --- | --- |
| an Ingress host is intended — the chart-values host, spec.rules, and the URL sources beside them | PASS |
| a host named by an Ingress and a URL is reported once | PASS |
| localhost, in-cluster, 127.0.0.1 and single-label host values stay out | PASS |
| a host named only in a comment is not added | PASS |
| the readiness count equals the pending list, plus the OIDC half | PASS |

**Reds (both PROVEN red):**

| control | verdict |
| --- | --- |
| R1: the master-shaped derivation (the real install.sh with the ingress-host parse and its call site deleted — URL-only) fails the Ingress-host check | PASS |
| R1: the same fixture fails the exclusions check (the bare host is gone while the exclusion rules hold) | PASS |
| R2: a loose mutant (the `host:` reader swapped for a raw-text `grep -h 'host:'` — no comment strip, no key anchoring) fails the no-invented check; its premise asserts it really lists the commented host first | PASS |

Each fixture asserts its own premise before its reds run: R1's derivation
still lists the operator URL and no longer lists the ingress host, and
DRY_RUN over it exits 0 (manifests copied beside it, because a relocated
install.sh finds its manifests through `SCRIPT_DIR`); R2's parses, DRY_RUNs to
0, and its derivation on the ghost fixture lists the commented host.

**The vacuous half, named.** The real-tree half of the first green — every
`host:` key in the *shipped* manifests is in the derivation — passes vacuously
today because the shipped Applications declare no `host:` key. It is the
ratchet for the day one appears; the fixture is the load-bearing proof. A
check that passes against an empty directory is not a check, so the fixture
half is what the property rests on.

## What was measured on the fix itself

- `bash -n` and `shellcheck -S warning` clean on `templates/substrate/install.sh`.
- The derivation on a hand-built fixture tree (manual `bash -c` over the
  sourced script): an ingress host quoted and unquoted, a values URL, an
  operator URL, a dual-named host reported once with the first source named,
  and `localhost` / `127.0.0.1` / `*.svc.cluster.local` / `redis-master` /
  a commented host all absent.
- `bash tests/substrate_test.sh`: **346 passed, 0 failed, 0 skipped**
  (baseline before this packet: 338 passed).

## Not proven here

That the live box now reports 3 — that needs the box. The mechanism is unit-
proved (the list grows, the count follows it), and the derivation reads
`host:` keys wherever the tree ships them; a host that exists only inside a
chart's templates needs the carrier to name it in the tree, which is a
substrate edit, not a derivation one.
