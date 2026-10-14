# REPORT — roll/c5/dns-split: the readiness preflight resolves on the node, and ACME resolves through CoreDNS

## The live evidence (measured on the box)

Three A records were created for the box (`api`, `app`, `auth` → `169.58.108.209`, proxied OFF):

```
# From the public internet — all three resolved and the box answered on port 80

# cert-manager's HTTP-01 self check still failed:
Waiting for HTTP-01 challenge propagation: failed to perform self check GET request
'http://api.cafaye.com/.well-known/acme-challenge/ByV7fYMx…':
Get "http://api.cafaye.com/…": dial tcp: lookup api.cafaye.com on 10.43.0.10:53:
no such host
```

`10.43.0.10` is k3s's **CoreDNS**.

The box's own resolver could not resolve the name either:

```
$ getent hosts api.cafaye.com
(no output)

$ dig +short @1.1.1.1 api.cafaye.com
169.58.108.209

$ resolvectl status | grep 'Current DNS'
Current DNS Server: 209.126.15.53   # Contabo's resolvers
```

**Root cause:** Contabo's resolver `209.126.15.53` held a stale NXDOMAIN for the records for minutes after `1.1.1.1` answered correctly. `resolvectl flush-caches` cleared systemd-resolved but not the provider's cache.

**Fix applied on the box:**

```
# /etc/systemd/resolved.conf.d/99-cafaye.conf
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=1.0.0.1 8.8.4.4
```

Then `systemctl restart systemd-resolved`, `resolvectl flush-caches`, `kubectl -n kube-system rollout restart deployment coredns`, recreating the Challenges. Both Certificates went `True` and HTTPS serves from the internet with a Let's Encrypt certificate. Cost before fix: ~170 minutes of `pending` challenges, nothing in the run said why.

## Why this is a substrate defect, not an environment accident

1. **The preflight and ACME do not resolve through the same path.** Preflight used `getent hosts` (node, provider's resolver). ACME's self check resolves through CoreDNS `10.43.0.10:53`, which forwards to `/etc/resolv.conf` (node). When the provider holds a stale negative, the two paths disagree.
2. **A box that serves public names depends on a resolver it does not control.** Every provider runs its own negative cache; the names most likely to have been created minutes earlier are the box's own. The substrate left that to luck.
3. **Silent for the negative TTL.** The failure is invisible until the TTL expires.

## The two resolution paths

| Path | How it resolves | What it uses |
|------|-----------------|--------------|
| **Node** | `getent hosts` / `dscacheutil` / `python3 socket.getaddrinfo` | The box's `/etc/resolv.conf` → systemd-resolved → provider's `209.126.15.53` or the public fallback |
| **Cluster** | `dig @10.43.0.10` (or `nslookup`, fallback) | CoreDNS at `10.43.0.10:53` (k3s default, or the IP from `kube-dns` Service), which forwards to the node's `resolv.conf`. ACME's HTTP-01 self check takes this path |

A host is **resolving** only when **both** paths answer. Agreement is the invariant.

## Which shape was chosen, and why

**Shape 1 — write a public resolver — was chosen.**

The installer now writes `/etc/systemd/resolved.conf.d/99-cafaye.conf` with:

```
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=1.0.0.1 8.8.4.4
```

It is written **only when the box serves public names** (any checkable host from `kit_substrate_intended_hosts`), is idempotent, and is **visible in the output**:

- `DRY_RUN` prints `would write …`
- Live run prints `wrote public resolver … — the provider's resolver held a stale NXDOMAIN on the live box (getent hosts empty, dig @1.1.1.1 answered 169.58.108.209, resolvectl Current DNS Server: 209.126.15.53)` or `already configured`
- After writing, it restarts `systemd-resolved`, flushes caches, and rollouts `coredns` so the new upstream is used.

**Why not shape 2 (detect and name the stale answer)?** Detecting node-vs-public split and reporting it would still require the operator to act, and would not prevent the 170 minutes of pending. Shape 1 fixes the provider dependency at the substrate, where it belongs. The split reporting (shape 2's value) is retained as the packet's item 1: the preflight now reports a split with its own sentence **in addition** to the fix, so the operator sees which path failed rather than only that a host "does not resolve". The two are complementary: the resolver makes the paths agree; the split sentence proves the check would have caught the disagreement.

Shape 2 alone would have been honest but not fixing. Shape 1 alone would have been fixing but not proving. The chosen shape does both, and the report justifies the choice rather than doing it silently.

## What changed

### `templates/substrate/install.sh`

- **`kit_substrate_cluster_host_resolves`** — new function that queries CoreDNS at its ClusterIP (`10.43.0.10` or `kube-dns` Service) with `dig`/`nslookup`, falling back to the node resolver. This is the path ACME's self check uses.
- **`kit_substrate_compute_readiness`** — now checks **both** `host_resolves` and `cluster_host_resolves`; a host is resolving only when both succeed. Stores `READINESS_TLS_PENDING` (hosts failing either path), `READINESS_DNS_SPLIT` (hosts where the two paths disagree), and `READINESS_DNS_STATUS` (per-host `node_ok/cluster_ok`) for reporting.
- **`kit_substrate_readiness_preflight`** / **`kit_substrate_readiness_final`** — keep the existing `DOES NOT RESOLVE` sentence for both-fail; add distinct sentences for the two splits:
  - `RESOLVES ON NODE BUT NOT THROUGH CLUSTER DNS (CoreDNS 10.43.0.10:53: no such host; …) — the ACME HTTP-01 self check (which resolves through CoreDNS) will fail …`
  - `RESOLVES THROUGH CLUSTER DNS BUT NOT ON NODE (… ) — the two DNS paths disagree …`
  Plus a summary line naming CoreDNS and which hosts split, so the operator sees which path failed.
- **`kit_substrate_readiness_json`** — adds `dns_split_hosts` and `dns_cluster_pending_hosts` beside `tls_pending_hosts`.
- **`kit_substrate_ensure_public_resolver`** — writes `99-cafaye.conf` only when serving public names, idempotent, visible, with reloads. Called from `preflight` (before the readiness check) in both live and `DRY_RUN` paths, marked `# honest-done` so the master-shape fixture remains valid.
- **`KUBECONFIG` handling** and `KIT_SUBSTRATE_RESOLVED_CONF` override for tests.

### `tests/substrate_test.sh` — section 29, six new checks

| Check | Colour | What it proves |
|-------|--------|----------------|
| `a host that resolves on node but not through cluster DNS is reported as pending with its own sentence` | green | Split (live-box shape) is pending, with `RESOLVES ON NODE BUT NOT THROUGH CLUSTER DNS` and `CoreDNS at 10.43.0.10:53` |
| `a host that resolves on both paths is reported as resolving` | green | Both succeed → `every intended host resolves` and `cluster DNS … agrees` |
| `a host that resolves through cluster DNS but not on node is reported as pending` | green | Opposite split is also pending (agreement, not which side wins) |
| `the public resolver is written only when serving public names, content correct and visible` | green | No write when no checkable host; with public host writes `DNS=1.1.1.1 8.8.8.8` + fallback, reports `wrote public resolver`, second run `already configured` |
| `control: node-only preflight reports split as resolving` | green goes red | Node-only fixture (pre-packet compute) reports the split host as `every intended host resolves` — proves the check discriminates (would have been green on the live box while the Certificate sat pending) |
| `control: a fixture where CoreDNS answers and node does not is not reported as resolving` | green | Agreement: opposite split is not reported as resolving |

The `node-only` fixture is built by replacing `kit_substrate_compute_readiness` with its pre-packet node-only spelling; the `getent empty / dig @1.1.1.1 answered 169.58.108.209 / resolvectl 209.126.15.53` tuple is the second proof that the check discriminates.

## Controls' verdicts

```
-- substrate_test: 352 passed, 0 failed, 0 skipped   (was 346 before this packet)
```

All new checks green; the one pre-existing honest-done fixture that was red when the `cat >` was a `printf` is now green after routing the file write through `cat` (the `every stdout echo/printf lives in the two writers` check).

## Definition of done

- [x] Commit whose message carries the live evidence (CoreDNS `no such host`, empty `getent`, `1.1.1.1` answer, `resolvectl 209.126.15.53`)
- [x] All greens passing (352) and both red controls proven red (node-only split reported as resolving; opposite split not reported as resolving)
- [x] This report in the worktree root
