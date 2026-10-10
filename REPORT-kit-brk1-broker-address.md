# REPORT — kit-brk1: the substrate's services get the broker's address

## What the packet was for

`identity` on the substrate had its outbox publisher dark. The broker was
installed (step 10: one Deployment + Service + PVC in `data`, plus stream
`cafaye` defined idempotently), identity's loop was fully wired and tested,
and the only `NATS_URL` the installer ever set was on the one-shot
`nats-stream-init` pod — a `kubectl run` pod that exits, not a service's
environment. `cmd/identity/main.go` builds `outbox.NewNATSPublisher` only
when `NATS_URL` is set, so the local compose stack published and a real box
did not. One commit, `0cdce5b` (branch `broker/kit-brk1`), closes it.

## The address, and how it was verified

**`nats://nats.data.svc.cluster.local:4222`** — the same address the
stream-init pod uses, and the right one for cross-namespace resolution.

- **Kubernetes' own rule, measured from its docs** (fetched live from
  `<https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/`,
  "Namespaces of Services"): "DNS queries that don't specify a namespace are
  limited to the Pod's namespace… A query for `data` returns no results,
  because it uses the Pod's test namespace. A query for `data.prod` returns
  the intended result", and "a Pod in the test namespace can successfully
  resolve either `data.prod` or `data.prod.svc.cluster.local`." A/AAAA
  records have the form `my-svc.my-namespace.svc.cluster-domain.example`.
  So the fully qualified form resolves from identity's namespace; the
  unqualified `nats` (the compose spelling) does **not** — it would be
  limited to `data`, where identity does not run.
- **The in-tree precedent is the same FQDN, already load-bearing**:
  `gateway-secrets` carries `REDIS_URL="redis://:$redis_pw@redis.data.svc.cluster.local:6379"`
  (gateway's namespace reaching data's), and every service's `DATABASE_URL`
  is `postgres-rw.data.svc.cluster.local:5432`. Those cannot fail to resolve
  or the service cannot serve a query at all. No `NetworkPolicy` exists
  anywhere in the substrate tree, so nothing restricts the path.
- **The gate derives the expected value from the broker's own Service**
  (`manifests/data/nats.yaml`: `metadata.name: nats`,
  `metadata.namespace: data`, client port 4222) rather than restating it, so
  the check measures the address against the object that must answer it.

The compose spelling is the control fixture: `control: the unqualified
compose spelling goes red`.

## Ordering

Unchanged and unguarded, and deliberately so. `install_redis_and_secrets`
(step 9, which calls `install_service_secrets`) runs **before** `install_nats`
(step 10) in `main`. That ordering would matter only if the secret's value
were read back from anything the broker step creates — the way
`gateway-secrets` reads `redis-password` (step 9's own first half) or
`DATABASE_URL` reads the step-8 role secrets. `NATS_URL` is a **constant**:
one assignment near the pins, read by both writers, no read-back, no guard,
no dependency on the broker existing at secret-creation time. So the secret
is created whether or not step 10 has run, which is what the packet asked
for ("if the broker is absent on a first run, the secret must still be
created"). README's step-9 entry now says so in one line.

A second consequence worth naming: on a re-run the step-level guard
(`kit_substrate_guard secrets`) fires before any per-secret path when all
four secrets exist, so a re-run is a no-op for the key; when only some
secrets exist (a half-finished first run) the step runs and the per-secret
refusal protects `identity-secrets`. Both paths were asserted (see below).

## Idempotency

**Never patched, written on first creation, exactly like every other key in
that secret.** The address is fixed by the broker's own Service name, so
there is nothing to read back and nothing to migrate; a broker that moves is
a rotate-by-replacement (back up, patch `stringData`, restart the pods), not
a silent patch of a live secret. A pre-existing `identity-secrets` (an
install from before this change) is therefore left without the key by a
re-run — same trade the MFA packet made, and README documents the same
rotate path for it (no ciphertext to fork here, since the value is a
constant).

## The SECRET RECORD reading

**Recorded, as a non-secret key.** `NATS_URL` is configuration — the broker's
address is not sensitive (the broker carries no credentials on this
substrate, and the stream it reaches holds no customer data) — but the
RECORD's job is the two-way tripwire over what the charts' `envFrom` reads,
and a key the record cannot see drift on is a key it will not catch being
deleted. So it is added to `RECORD identity-secrets:` (not to the test's
`conditional` set, which would have been the weakening move) and a new
provenance bullet, **NEITHER — configuration that rides a secret-shaped
slot**, records why it belongs to no other bucket. The tripwire itself is
untouched: 4 RECORD lines, the `check_secret_record` logic unchanged, both
directions still proven by the existing red controls.

## What the gate gained

`tests/substrate_test.sh` went from 115 to 123 passing checks:

- **A parse check, `check_nats_service_url`** (in section 12): exactly one
  `NATS_URL="…"` assignment, equal to the FQDN derived from the broker's
  Service; identity's secret carries `--from-literal=NATS_URL="$NATS_URL"`;
  the stream-init pod reads the same constant (so the two writers cannot
  drift). Three controls, each going red for the reason its name gives — the
  compose spelling, the missing literal, and a second spelling of the address
  in the stream-init pod. The failure strings were read back by hand to
  confirm each control fires on its own assertion.
- **An executed half** (placed after the MFA section, because the
  file-backed mock kubectl and sourced installer it needs are defined there):
  `install_service_secrets` is run against the mock and the stored secret is
  read back — the green claim is about the secret kubectl would create, not
  about the script's text. A second run asserts the stored value is
  byte-identical and the log names the guard/refusal. Its control runs an
  installer carrying the compose spelling through the same harness and shows
  the store records it verbatim and differently from the broker address — so
  the green assertion is about the installer, not about the mock.

## Evidence

- `bash tests/substrate_test.sh`: **123 passed, 0 failed, 0 skipped**.
- `bash tests/validate.sh` (full gate, backgrounded, exit code captured):
  **exit 0**, 414 PASS, 0 FAIL, 9 reported skips (rustc/wrangler not
  installed — all named in the log), 5 tiers ran under a time bound and none
  was reached. Logs: `/tmp/gate-kit-brk1.log`, `/tmp/gate-kit-brk1-final.log`.
- `shellcheck -S warning` and `-S error` clean on both touched shell files;
  `bash -n` clean; yamllint untouched (no YAML changed).

## Not touched, by design

The stream definition and its subjects, the Application manifests (thin
ArgoCD Applications — the env belongs in the secret the charts consume), the
broker manifest, and the other four services. courier, muse, billing and
darkroom take the same key when their publishers land: one line in their
secret's args array, one line in their RECORD, and the README/CHANGELOG. The
shared constant means none of them can spell the address differently from the
stream-init pod.

## What I learned (for the next worker)

The one fixture that failed first was a `grep -v` of the
`--from-literal=NATS_URL=…` line: it removed the array's **closing paren**
too, so the control script did not parse and the "control" failed for a
reason unrelated to the assertion. A control fixture that mutates a line must
leave the file it mutates still loadable; where it cannot, mutate the value
rather than the line (that is why the executed control substitutes
`nats://nats:4222` instead of deleting the literal). The parse-level control
is unaffected because it never executes the fixture.

The worktree was clean on arrival — the previous attempt left no partial work
to keep or discard.
