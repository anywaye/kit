# HANDOFF — roll-c5-crossns

**Branch:** `roll-c5-crossns` (worktree `moon/wt/roll-c5-crossns`).
**Status:** the packet is **accomplished**; the branch is ready to merge.
**Tip:** `04296c9` (fix) + this report/handoff commit.

## What the packet was for

Every service on a box dialled a peer by a **bare name** (`identity`, `redis`,
`postgres-rw`, `pantry`) while the substrate puts each service in its **own
namespace** — so the address resolved only inside a namespace of that name and
no cross-service call worked. gateway's `/readyz` answered
`{"deps":{"identity":"unavailable","redis":"unavailable"}}`; parlor had no
`IDENTITY_URL` at all.

## What is done

- The substrate now sets the box's addresses in the file it owns —
  `spec.source.helm.values` of the two Applications whose charts ship a compose
  default: **gateway** (`IDENTITY_URL`, `IDENTITY_JWKS_URL`) and **parlor**
  (`IDENTITY_URL`, which nothing set before).
- The installer's own addresses (`COURIER_BASE_URL`, `COURIER_IDENTITY_URL`,
  `REDIS_URL`, the DSNs, `NATS_URL`) were already fully qualified — verified,
  unchanged.
- `tests/substrate_test.sh` **§24** asserts every cross-service address the
  Applications set, and every `.svc.cluster.local` name `install.sh` writes,
  names a Service the manifests ship in the namespace they ship it in; five red
  controls, each checked to fail for the right reason.
- Gate: `bash tests/substrate_test.sh` → **253 passed, 0 failed, 0 skipped**;
  `bash -n` and `shellcheck -S warning` clean.

## What is deliberately left

1. **gateway's `ROUTE_TABLE` (pantry) and parlor's `BILLING_URL`.** Neither
   pantry nor billing is a Service the substrate ships, so §24 (correctly)
   refuses an address to them. The **values commit** that deploys those
   services writes the address. `ROUTE_TABLE` also carries a **port bug** worth
   fixing there: `http://pantry:8080` but pantry's Service is `port: 80`
   (`targetPort: http` → 8080).
2. **The issuer pair.** `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER` has **no default**
   (unset ⇒ identity serves no OIDC surface); gateway's chart default is
   `https://auth.cafaye.com`. A box must set the **same public origin** on both
   sides or `iss` never matches — see REPORT §3. `IDENTITY_ISSUER` is left an
   operator/values-commit fact; the reachable box already shows a mismatch
   (`http://auth.cafaye.test` vs `https://auth.cafaye.test`).

## The successor's first move (if the packet is reopened)

The only open design question is **wiring `IDENTITY_ISSUER` from the installer**,
so the mint and verify halves cannot drift: substitute
`IDENTITY_ISSUER_PLACEHOLDER` in `manifests/applications/gateway.yaml` from
`KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER` at apply time — the exact pattern
`install_cluster_issuers` uses for `ACME_EMAIL_PLACEHOLDER`. That is a
templated-apply change to `install_applications`, plus a §24 assertion that the
two halves are one value. Do **not** hard-code a customer's domain into the
manifest.

## A trap for the next check you add

`install.sh` defines globals named `DATA_DIR`, `MANIFEST_DIR`,
`ARGOCD_MANIFEST_DIR`, `SCRIPT_DIR`. Some test sections `. "$installer"` a
**fixture install in the test shell**, so `$DATA_DIR` is silently rebound to
`$WORK/manifests/data` for every check that runs later. §24's first draft used
`$DATA_DIR` and its controls "passed" only because the directory did not exist —
a red for the wrong reason. §24 now names the path literally. Renaming the
installer's globals (or sourcing it in a subshell everywhere) is the real fix,
for its own packet.

## What proved the work

`bash tests/substrate_test.sh` (253/0/0), `bash -n` on both scripts,
`shellcheck -S warning` clean, `yamllint` on the two Applications (pre-existing
`missing document start` warning only — every sibling manifest has it). The
reachable `k3d-cafaye-local` cluster is **not** a substrate install, so nothing
was "verified live"; the box commands a successor should run are in REPORT §7.
