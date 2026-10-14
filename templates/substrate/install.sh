#!/usr/bin/env bash
#
# kit's customer substrate — one command, one box.
#
#   curl https://cafaye.com/box/install | sh
#
# or, from a kit checkout:
#
#   KIT_SUBSTRATE_BOX_ID=<uuid> \
#   KIT_SUBSTRATE_REGISTRY_CAPABILITY=<token> \
#   KIT_SUBSTRATE_ACME_EMAIL=<value> bash templates/substrate/install.sh
#
# WHAT THIS INSTALLS, IN ORDER
#   1. k3s            single node, sqlite datastore — no etcd on one box
#   2. cert-manager
#   3. CloudNativePG
#   4. Argo CD core   no Dex, no SSO, no Redis HA
#   5. the GHCR image pull secret, redeemed from the box's own short-lived
#      capability — no long-lived registry credential is ever handed over
#   6. the first Applications, so Argo starts syncing
#   7. the Let's Encrypt ClusterIssuers — staging + prod, from a value the OPERATOR supplies
#   8. the Postgres Cluster — one CNPG Cluster, one database and two roles per
#      service, reproducing templates/compose/postgres/initdb/10-cluster.sh
#   9. Redis (single instance) and the services' secrets — identity-secrets,
#      gateway-secrets, courier-secrets, parlor-secrets, one per namespace,
#      each exactly the keys its chart reads (see the SECRET RECORD on
#      install_service_secrets)
#   10. the services' database schemas — one migrate Job per schema-owning
#      service (identity, courier), in that service's own running image and as
#      its OWNER role, waited to completion; gateway and parlor own no schema
#      and are named-and-skipped. Without this the fleet boots against an empty
#      database: identity's outbox loop retries forever on a missing
#      `outbox_events`, which is the failure this step ends.
#   11. NATS with JetStream (single instance) and the fleet's stream — one
#      Deployment + Service + PVC in `data`, plus the one-shot stream init
#      defining stream `cafaye`, mirroring templates/compose's nats-stream-init
#      (same subjects, retention, storage, replicas — the gate refuses drift).
#   12. courier's identity credential, MINTED ON THE BOX from identity's own
#      API and patched in place — the install → boot → mint → patch → restart
#      loop nothing outside this box takes part in.
#
# NO LONG-LIVED SECRET IS AN INPUT TO THIS SCRIPT.
#   Two values used to be: a GHCR dockerconfigjson and identity's OIDC signing
#   key. Both violated invariant 3 ("secrets are born where they are used") on
#   the INPUT side, and both are gone — the first because a box-bound,
#   single-use, minutes-lived capability, exchanged at the registry service's
#   POST /v1/registry-credentials, buys exactly one short-lived pull-only
#   dockerconfigjson and nothing else (the exchange spends the capability at
#   box's own redeem door, so the enforcement stays where it already lives),
#   the second because an OIDC signing key is the customer's own key and a
#   private RSA key that has been in someone's shell history is not their own
#   any more. What the operator now hands over is configuration and a
#   capability whose value expires in minutes:
#
# THE OPERATOR-SUPPLIED VALUES (none of them a long-lived secret):
#   KIT_SUBSTRATE_BOX_ID           required, no default: the enrolled identity
#                                  of THIS box (a UUID). Not a secret — it is
#                                  the box's name — and it is what the
#                                  capability is BOUND TO, so a capability
#                                  minted for another box is refused rather
#                                  than silently used.
#   KIT_SUBSTRATE_REGISTRY_CAPABILITY required, no default: the single-use,
#                                  minutes-lived, box-bound capability the
#                                  box's enrolled identity presents to exchange
#                                  ONE short-lived registry credential. It is
#                                  never written to disk and never echoed.
#   KIT_SUBSTRATE_BOX_URL    default https://box.svc.cafaye.com — where a
#                                  capability is redeemed (the box control
#                                  plane's POST /v1/capabilities/redeem).
#                                  Configuration, not a secret; a self-hosted
#                                  fleet points it at its own control plane.
#   KIT_SUBSTRATE_REGISTRY_URL default https://registry.svc.cafaye.com — where
#                                  a capability is EXCHANGED for a
#                                  dockerconfigjson (the registry service's
#                                  POST /v1/registry-credentials). A different
#                                  service from the box that spends the
#                                  capability: box holds no registry
#                                  credential, so the exchange lives where the
#                                  registry material lives.
#   KIT_SUBSTRATE_ACME_EMAIL       required, no default (see step 7).
#   KIT_SUBSTRATE_DATABASES        required, no default. The comma-separated
#                                  service names; must equal the service set the
#                                  Cluster manifest provisions
#                                  (identity,gateway,courier,parlor). Refused
#                                  empty, naming the fix.
#   KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER optional: the URL identity publishes as
#                                  its OIDC issuer. NOT a secret — and when it
#                                  is set the signing key, its id and the login
#                                  UI URL are GENERATED (key/id) or SET (login
#                                  UI) ON THE BOX beside it, because identity's
#                                  OIDC surface is all-or-nothing (issuer +
#                                  key + id + login UI, or none of them).
#   KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL optional: the URL a browser is sent
#                                  to in order to authenticate — the login UI
#                                  (parlor on this substrate). When the issuer
#                                  is set this MUST be set too, and vice versa;
#                                  a lone issuer is a CrashLoopBackOff
#                                  (`OIDC_LOGIN_UI_URL: no OIDC login UI
#                                  configured`). Identity validates it as an
#                                  http(s) URL with a host, no query, no
#                                  fragment and no userinfo — the same rule as
#                                  `oidc.ValidateLoginUIURL`. NOT a secret, and
#                                  never guessed: a guessed URL sends a browser
#                                  somewhere the operator never chose, the same
#                                  rule `KIT_SUBSTRATE_APP_BASE_URL` states.
#   KIT_SUBSTRATE_SMTP_ADAPTER     courier's mail adapter: smtp or postmark.
#   KIT_SUBSTRATE_SMTP_HOST        the SMTP relay host (when the adapter is smtp).
#   KIT_SUBSTRATE_SMTP_PORT        default 587, the submission port.
#   KIT_SUBSTRATE_SMTP_USERNAME / KIT_SUBSTRATE_SMTP_PASSWORD — SMTP auth.
#   KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET — the provider's signing secret
#                                  for courier's inbound webhooks (externally
#                                  sourced: generated by the PROVIDER).
#   KIT_SUBSTRATE_COURIER_ERROR_RELAY_TOKEN — the shared secret for courier's
#                                  error relay (externally sourced: the other
#                                  end holds it too, so generating one here
#                                  would fork it).
#   KIT_SUBSTRATE_MAIL_FROM / KIT_SUBSTRATE_MAIL_FROM_NAME — optional courier
#                                  passthroughs (courier falls back to its
#                                  compiled default without them).
#   KIT_SUBSTRATE_APP_BASE_URL     optional: the public origin a browser reaches
#                                  (e.g. https://app.example.com). Step 12
#                                  derives identity's four link templates from
#                                  it and deletes the legacy shared default
#                                  in the SAME patch as the
#                                  courier pair, because identity's courier block
#                                  is all-or-nothing: a base URL and a token with
#                                  no link template is `ErrInvalidCourier`
#                                  (`identity/internal/config/config.go`
#                                  `loadCourier` → `resolveLinkTemplates`), and
#                                  a link template with no base URL is refused
#                                  the same way. UNSET is a DELIBERATE, supported
#                                  no-mail path: step 12 writes no identity
#                                  courier keys at all, identity boots into its
#                                  own "no mail path" state, and every recovery
#                                  route answers 503. There is no default and the
#                                  value is never guessed — a localhost link
#                                  mails a reader to a screen that is not theirs.
#   KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY / _OAUTH_ENCRYPTION_KEY /
#                                  _COURIER_TOKEN — optional identity surfaces;
#                                  each lands in identity-secrets only when
#                                  set, except COURIER_TOKEN, which step 12
#                                  writes with the value it minted itself (see
#                                  below). MFA_ENCRYPTION_KEY is NOT optional:
#                                  it is generated on first creation (or taken
#                                  from the override when the operator sets it),
#                                  because identity mounts its MFA surface only
#                                  when the key is present.
# Every value above is validated by shape and never echoed, the way the
# capability already works. The values this script GENERATES — every key in
# the SECRET RECORD's generated half, the OIDC signing key, and the courier
# credential step 12 mints — are born here, stored here, and never printed.
#
# The decisions are in DEPLOYMENT.md. This file is the executable half of it:
# Argo core (not HA), Traefik (k3s's default) for ingress, traces deferred —
# Tempo slots in later as one more Application. There is no second deploy path.
#
# HOW TO CHOOSE A PIN
#   Every version below is exact. A floating tag in an install script is the
#   defect this whole fleet exists to avoid. Each pin was verified against the
#   GitHub releases API on 2026-10-07 and is re-checked by
#   `tests/substrate_test.sh`, which refuses a `latest` or floating pin.
#
# IDEMPOTENT — THE GUARD
#   `kit_substrate_guard` is the named guard. Each step asks it whether the
#   component is already present and skips it rather than re-installing. A
#   second run is a no-op, not a corruption. The guard is per-component, so a
#   half-finished first run resumes where it stopped instead of restarting.
#
# FAILS LOUDLY AND EARLY
#   No root, no curl, an unsupported arch, a non-Linux kernel, a box too small
#   for the Grafana stack, or an unreachable registry: each says what is wrong
#   and stops before anything is half-installed. The preflight runs before
#   step 1 and there is no `if` around any of its exits.
#
# DRY_RUN=1
#   Prints every step it would take and executes nothing. This is what makes
#   the script testable on a machine that is not a customer box — and a
#   developer machine is not one.
#
# --headless (or HEADLESS=1)
#   The mode an agent drives. `caf box apply --phase N` runs this script with
#   the flag and reads stdout as a STREAM OF JSONL EVENTS, one object per
#   line, and nothing else: `{"event":"step.start","step":1,"phase":"k3s",
#   "message":"k3s v1.37.1+k3s1 — single node, sqlite datastore","seconds":0.052}`.
#   Every human line that interactive mode prints goes to STDERR instead, so
#   stdout is progress-only and a parser never has to guess.
#   EVERY RUN REPORTS ITS OWN SPEED. `seconds` on step.start is the step's
#   OFFSET since the install began; on step.done it is the step's DURATION,
#   measured on the step's own boundary (a skipped step reports the string
#   "skipped", never `0`). The final `install.done` carries the total and a
#   `steps` array of {step, phase, seconds}, so "how long did this take, and
#   which step was the cost" is one line rather than a stopwatch.
#   The install-receipt file (KIT_SUBSTRATE_RECEIPT, default
#   /var/lib/kit/substrate-receipt.json) is rewritten at every state change and
#   names the phase, the next step, the input needed and where the human goes.
#   A refusal writes a `refusal` event AND a receipt with `status: refused` and
#   the input it needs, which is the whole point: the agent's only touchpoint
#   with a person is the receipt's `human` field.
#   Two writers exist and the test enforces the split: kit_substrate_emit
#   writes stdout (JSONL, headless only) and kit_substrate_out writes the
#   human text (stderr, headless only). Nothing else writes to the process
#   stdout — see tests/substrate_test.sh, which parses every echo and printf
#   in this file and fails on one that reaches stdout from anywhere else.
#
# SECRETS
#   NO LONG-LIVED SECRET ENTERS THIS SCRIPT. The registry credential is
#   REDEEMED, per run, from a capability that is single-use, minutes-lived and
#   bound to this box: it buys one short-lived dockerconfigjson, which is held
#   in a shell variable and reaches the cluster through a pipe. It is never
#   echoed, in any mode, and never written to disk. The OIDC signing key and
#   the courier credential are GENERATED OR MINTED ON THIS BOX. The same holds
#   for every operator value above and every generated value steps 8, 9 and 11
#   create: a secret VALUE never reaches an `echo`, in DRY_RUN or live.
#   Refusals name the VARIABLE (`export KIT_SUBSTRATE_SMTP_HOST=…`), never its
#   value.

set -euo pipefail

# --- pins ------------------------------------------------------------------
# Exact, always. Verified against the GitHub releases API on 2026-10-07.
K3S_VERSION="v1.37.1+k3s1"
CERT_MANAGER_VERSION="v1.21.2"
CNPG_VERSION="v1.30.1"
ARGOCD_VERSION="v3.5.4"
# NATS pins. The defaults match the local stack's (compose renders
# `nats:${KIT_NATS_TAG:-2.10.24-alpine}` and
# `natsio/nats-box:${KIT_NATS_BOX_TAG:-0.20.0}`) — one fact, two renders, and
# the gate's drift check refuses a divergence. The broker manifest carries
# NATS_IMAGE_PLACEHOLDER where the tag goes, substituted at apply time, so the
# pin lives here and nowhere else.
NATS_VERSION="2.10.24-alpine"
NATS_BOX_VERSION="0.20.0"
# THE BROKER'S ADDRESS, AND IT IS ONE FACT. Both writers read this line: step
# 10's one-shot stream-init pod (it dials the broker to create the stream) and
# identity-secrets (it is what tells identity's outbox loop where to publish).
# A second spelling is exactly how the init pod and the services drift apart,
# so neither of them writes the address out.
#
# FULLY QUALIFIED, AND DELIBERATELY SO. `nats` alone is the compose stack's
# spelling and it resolves only inside the `data` namespace — identity runs in
# `identity`, so a `nats://nats:4222` here produces a pod that starts and a
# loop that silently connects to nothing, which is the failure this key ends.
# Kubernetes' own rule, measured from its docs: a query naming no namespace is
# limited to the caller's, and `svc.<namespace>.svc.cluster.local` crosses it.
NATS_URL="nats://nats.data.svc.cluster.local:4222"

# TWO SERVICE URLs, and each is the OTHER service's in-cluster Service. They
# are constants here for the same reason NATS_URL is — one fact, one line —
# and they are here rather than in a secret record because they are not
# secrets: they are the address of a Service, derived from two charts.
#
#   COURIER_URL   — identity's `COURIER_BASE_URL`. Read from the courier chart
#                   (`courier/chart/values.yaml`: `service.port: 4000`, the
#                   Elixir container port) and the Service template
#                   (`courier/chart/templates/service.yaml`: `name: courier`),
#                   deployed into namespace `courier` by
#                   `templates/substrate/manifests/applications/courier.yaml`.
#   IDENTITY_URL  — courier's `COURIER_IDENTITY_URL`, the base of identity's
#                   introspection endpoint (`POST /v1/introspections`). Read
#                   from the identity chart (`identity/chart/values.yaml`:
#                   `service.port: 8080`) and its Service template
#                   (`name: identity`), namespace `identity`.
#
# WHY THEY ARE WRITTEN AT ALL. identity refuses to boot with half a courier
# block (`internal/config/config.go` `loadCourier`: "COURIER_BASE_URL and
# COURIER_TOKEN must both be set, or neither of them"), and courier's
# `COURIER_IDENTITY_URL` DEFAULTS to `http://identity:8080`
# (`config/runtime.exs`), which cannot resolve across the `courier`/`identity`
# namespace boundary — it is the compose-network spelling. So both URLs are
# written by step 11, beside the token of the same block: two environment
# values that must move together are one fact with two names.
COURIER_URL="http://courier.courier.svc.cluster.local:4000"
IDENTITY_URL="http://identity.identity.svc.cluster.local:8080"
# IDENTITY_COURIER_KEYS — the seven keys of identity's courier block: the pair
# plus the four link templates the installer writes (three per-purpose links
# plus the invitation link) AND the legacy shared default it deletes. ONE list
# for the set-branch patch and the unset-branch sweep-and-verify, so the two
# can never disagree about the block's extent. The set-branch patch below still
# spells every key literally (the record tripwire reads the written keys out
# of the stringData block, and the deleted default out of nothing — it is a
# `data`-null, which is why the RECORD names only what an install creates);
# this list is what the sweep scans, deletes and re-verifies.
IDENTITY_COURIER_KEYS=(COURIER_BASE_URL COURIER_TOKEN PASSWORD_RESET_LINK_TEMPLATE EMAIL_VERIFICATION_LINK_TEMPLATE EMAIL_CHANGE_LINK_TEMPLATE RECOVERY_LINK_TEMPLATE INVITATION_LINK_TEMPLATE)

# --- the services' telemetry on a box: DELIBERATELY OFF ---------------------
# THE BOX DEPLOYS NO OTLP ENDPOINT, SO THE SERVICES MUST NOT TRY TO REACH ONE.
#
# Measured, not assumed. The observability set is alloy + grafana +
# prometheus (`manifests/applications/`), and alloy is pinned at chart 1.13.0
# with NO values: the chart's default config is `config/example.alloy` — a
# `logging` block and `discovery.kubernetes` components, and no
# `otelcol.receiver.otlp` — and its default Service exposes only
# `http-metrics` on 12345 (`alloy.extraPorts` is empty). So alloy does not
# accept OTLP as shipped, and the substrate ships no Tempo at all: DEPLOYMENT.md
# ("Traces | deferred") is the fleet's decision, and there is nowhere for a span
# to land. `kubectl get svc -n observability` on the live box returns nothing.
#
# The services' COMPILED default is `http://otel-collector:4318` (identity,
# courier, parlor) / `:4317` (gateway) — the COMPOSE stack's name, which
# resolves only inside the compose network. On a box it resolves to nothing, and
# the OTel SDK retries forever, so identity logs this every ten seconds:
#
#   level=INFO msg="traces export: Post \"http://otel-collector:4318/v1/traces\":
#     dial tcp: lookup otel-collector on 10.43.0.10:53: no such host"
#
# The fix is the SDK's OWN kill switch, not a log-level change and not a
# re-point at a name that does not resolve: core's `otel-endpoint.schema.json`
# pins the no-op to `OTEL_SDK_DISABLED` and requires it to be free (no buffer,
# no retry, no warning per export, no dial on boot). With it set, the service
# logs one line at startup and nothing per export. When Tempo becomes an
# Application this is what comes OUT: the endpoint variable goes IN, one fact in
# one place.
#
# ONE SPELLING, ONE LINE, AND THE ONE EXCEPTION NAMED. The generated charts
# inject env with `envFrom: secretRef`, so a key written into a service secret
# below IS an environment variable; the array is referenced, never retyped.
# gateway's chart is hand-written and reads its CLEAR env from a ConfigMap
# rather than its secret, so its Application carries the same key/value in
# `spec.source.helm.values` — the one service whose chart shape differs, and the
# reason is written at the site that differs.
SERVICE_OTEL_DISABLED=(--from-literal=OTEL_SDK_DISABLED=true)

# --- operator-supplied values ----------------------------------------------
# --- the box's own identity and capability ------------------------------------
# KIT_SUBSTRATE_BOX_ID is the enrolled identity of THIS box — a UUID the
# capability below is BOUND TO, so a capability minted for another box is
# refused by the registry rather than used here. It is the box's name, not a
# secret, and it is what makes the redeemed credential single-purpose: a
# credential issued to box A is worthless on box B, which is invariant 2
# ("possession alone is useless") buying invariant 1 back.
: "${KIT_SUBSTRATE_BOX_ID:=}"

# KIT_SUBSTRATE_REGISTRY_CAPABILITY is the capability the box presents. It is
# the one value the operator hands over that is credential-shaped, and it is
# deliberately the only one left: single-use (a redemption consumes it),
# minutes-lived (15, by the mint's own TTL), and bound to the box above. It
# buys exactly ONE short-lived registry credential and nothing else — not a
# deploy, not a shell, not another box's artifacts. Validated by shape (the
# minted spelling `cap_` plus 64 hex) and never echoed.
: "${KIT_SUBSTRATE_REGISTRY_CAPABILITY:=}"

# KIT_SUBSTRATE_BOX_URL is where a capability is REDEEMED. Configuration,
# not a secret: a cafaye-operated fleet is the default and a self-hosted one
# points it at the control plane it runs. No default of `localhost` — a
# silently local URL is how a box redeems against itself. The door is the box
# control plane's POST /v1/capabilities/redeem, the one the fleet built; the
# registry-side exchange (the dockerconfigjson) is a different service,
# landed separately.
: "${KIT_SUBSTRATE_BOX_URL:=https://box.svc.cafaye.com}"

# KIT_SUBSTRATE_ACME_EMAIL is the ACME account contact address. Read from the
# environment like the pull secret and validated by shape, but it is not a
# secret — it is the address Let's Encrypt sends expiry notices to. A literal
# in the manifests would be wrong, not merely insecure: it would put cafaye's
# address, or a made-up one, on a customer's ACME account. The manifests carry
# the placeholder ACME_EMAIL_PLACEHOLDER; this script substitutes it in a pipe
# at apply time and never prints the value.
: "${KIT_SUBSTRATE_ACME_EMAIL:=}"

# KIT_SUBSTRATE_DATABASES names the services, comma-separated — one
# role-and-database per name, reproducing
# templates/compose/postgres/initdb/10-cluster.sh. NO DEFAULT, and empty is
# refused with the fix named (the way 10-cluster.sh:120 refuses): a service
# with no entry has no database, and a plan with no names is a plan for
# nothing. It must name the same services
# manifests/data/postgres-cluster.yaml provisions — step 8 checks the
# agreement and refuses a list the manifest does not cover.
: "${KIT_SUBSTRATE_DATABASES:=}"

# KIT_SUBSTRATE_POSTGRES_EXTENSIONS is the extension list, comma-separated,
# mirroring the local contract (compose writes ${KIT_POSTGRES_EXTENSIONS:-vector}).
# Validated as identifiers; creation per database is a named gap (see step 8).
: "${KIT_SUBSTRATE_POSTGRES_EXTENSIONS:=vector}"

# Courier's externally-sourced settings. The relay host, username and password
# come from the operator's mail relay; the adapter and port have honest
# defaults (smtp / 587) and are validated non-empty / numeric. The two companion
# secrets are NOT generatable and NOT inputs either:
# COURIER_INBOUND_RESEND_SECRET is copied from the provider's dashboard
# (Resend: the webhook endpoint's Signing Secret, whsec_…) — the provider is
# the only party that can hold it, so it is the one long-lived secret this
# install takes from outside the box.
# COURIER_IDENTITY_TOKEN is no longer an input at all: it was minted by
# identity itself after it booted, so the operator had to carry a freshly
# minted API key between two terminals and paste it into a second run. Step 11
# performs that mint ON THIS BOX — the same API, the same four calls, the same
# patch-and-restart — and nothing crosses a boundary to make it happen.
# MAIL_FROM/MAIL_FROM_NAME are optional passthroughs — courier falls back to
# its compiled default without them.
: "${KIT_SUBSTRATE_SMTP_ADAPTER:=smtp}"
: "${KIT_SUBSTRATE_SMTP_PORT:=587}"
: "${KIT_SUBSTRATE_SMTP_HOST:=}"
: "${KIT_SUBSTRATE_SMTP_USERNAME:=}"
: "${KIT_SUBSTRATE_SMTP_PASSWORD:=}"
: "${KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET:=}"
: "${KIT_SUBSTRATE_MAIL_FROM:=}"
: "${KIT_SUBSTRATE_MAIL_FROM_NAME:=}"

# Courier's mail path. The relay host, username and password are the
# operator's account with their provider and have no defaults — a default
# relay is a relay that mails nobody while reporting success (see runtime.exs
# on adapter `none`), and a default credential is a credential in version
# control. The adapter and port default to smtp/587 (validated: adapter
# non-empty, port numeric); with the postmark adapter the SMTP_* values ride
# along unused — one shape, no conditional refusals to misread.
# (The error-relay token is generated on the box — a random self-contained
# value, like the other generated keys — so it is declared nowhere here.)

# Optional identity surfaces. Unset means the surface stays unwired (no OIDC
# provider, no OAuth, no courier calls from identity) — each lands in
# identity-secrets only when set. MFA is the exception: MFA_ENCRYPTION_KEY is
# GENERATED on first creation (or taken from the override below), because
# identity mounts GET /v1/mfa and the enrollment routes only when the key is
# present — an install without it boots an identity that can neither show the
# truthful `Off` state nor enroll a factor.
#
# The OIDC signing key is NOT on the list above, and that is the whole point of
# this packet: it used to be an operator input, which made identity's private
# RSA key a value in somebody's shell history and somebody else's transcript.
# It is the customer's own key, so it is BORN ON THIS BOX — generated on first
# creation, read back once-only thereafter, and printed never. It is written
# beside an issuer the operator may set, because identity's OIDC surface is
# all-or-nothing (issuer + key + key id + login UI, or none of the four): a
# lone key is a boot-time refusal, not a half-configured provider.
: "${KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER:=}"
: "${KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL:=}"
: "${KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY:=}"
: "${KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY:=}"

# KIT_SUBSTRATE_APP_BASE_URL is the public origin a browser reaches — where
# identity's mail links point. It is the ONE input that makes identity's mail
# path true: identity refuses to boot with a courier pair and no link template
# (`internal/config/config.go`, loadCourier → resolveLinkTemplates; identity's
# own test names the case "a base URL and a token with no link template" →
# ErrInvalidCourier), and it refuses the reverse too ("a link template and a
# token with no base URL"). NO DEFAULT: a localhost or guessed default is a link
# that reaches a screen the reader cannot open, which is worse than no mail path
# at all. UNSET is a DELIBERATE, supported state — step 12 then writes no
# identity courier keys, so identity boots into its own supported "no mail path"
# state (its loader's `present == 0` branch: "all three absent is a deployment
# with no mail path, and is supported") and every recovery route answers 503
# rather than a rollout that never goes Ready. Set it to the box's public origin
# (scheme + host, optionally a path — no query and no fragment) to give the box a
# true mail path; identity appends each link's own path to it.
: "${KIT_SUBSTRATE_APP_BASE_URL:=}"

DRY_RUN="${DRY_RUN:-0}"

# HEADLESS=1 (or the --headless flag) turns stdout into a JSONL event stream —
# one object per line, machine-parseable — and writes an install receipt naming
# the phase, the next step, the input needed and where the human goes. This is
# the mode `caf box apply --phase N` drives: the agent reads the JSONL and the
# receipt, and the only human touchpoint is the receipt's `human` field. The
# interactive mode is unchanged — the same calls print the same plain text.
HEADLESS="${HEADLESS:-0}"

# Where the install receipt is written. Overridable so a test (or a box with a
# different layout) can point it at a writable path; the default is the box's
# own state directory. The receipt is rewritten at every state change, so a
# crashed install leaves one naming where it stopped.
RECEIPT_PATH="${KIT_SUBSTRATE_RECEIPT:-/var/lib/kit/substrate-receipt.json}"

# Where this script lives, so the manifests are found from a checkout and from
# a served copy alike.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$SCRIPT_DIR/manifests/applications"
TLS_DIR="$SCRIPT_DIR/manifests/tls"
DATA_DIR="$SCRIPT_DIR/manifests/data"
ARGOCD_MANIFEST_DIR="$SCRIPT_DIR/manifests/argocd"

# --- timing -----------------------------------------------------------------
# EVERY RUN REPORTS ITS OWN SPEED. Before this, the JSONL carried no timestamps
# at all, so "how long did this take, and which step was the cost" could only be
# reconstructed from the cluster's object-creation times — archaeology that says
# nothing about a cold box or a bad change. The clock below is monotonic and the
# measurement is taken on each step's OWN boundary, so the numbers are the
# step's, not the run's.
#
# kit_substrate_now — a MONOTONIC millisecond clock. On the box this reads
# /proc/uptime (seconds since boot), which does not follow the NTP step or the
# operator's clock edit that a wall-clock reading would; `date +%s` is the
# packet's accepted floor and would be wrong exactly on the box that had just
# had its clock set. Off Linux there is no /proc, so the highest-resolution wall
# clock the machine has is used instead (bash 5's EPOCHREALTIME, then perl's
# Time::HiRes, then `date +%s`); those fallbacks are for a developer machine
# running DRY_RUN, where the absolute value is meaningless anyway. Only
# DIFFERENCES are ever taken, so the base (boot time vs epoch) does not matter.
kit_substrate_now() {
  if [ -r /proc/uptime ]; then
    awk '{printf "%.0f\n", $1 * 1000}' /proc/uptime
    return 0
  fi
  if [ -n "${EPOCHREALTIME:-}" ]; then
    printf '%s' "$EPOCHREALTIME" | awk -F. '{printf "%d%03d\n", $1, substr($2 "000", 1, 3)}'
    return 0
  fi
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'
    return 0
  fi
  printf '%s000\n' "$(date +%s)"
}

# kit_substrate_seconds <milliseconds> — the decimal-seconds spelling the JSONL
# and the table carry. Milliseconds is the resolution a step is actually read
# at, and "0.004" is a duration where "0" is a shrug; the field is still named
# `seconds` because that is what it is a number of.
kit_substrate_seconds() {
  printf '%d.%03d' "$(( $1 / 1000 ))" "$(( $1 % 1000 ))"
}

# kit_substrate_elapsed — whole milliseconds since the install began, for the
# `seconds` a step.start carries (the step's OFFSET, so a reader can see a step
# start serializing) as opposed to the DURATION a step.done carries.
kit_substrate_elapsed() {
  kit_substrate_seconds "$(( $(kit_substrate_now) - INSTALL_START_MS ))"
}

# --- the guard --------------------------------------------------------------
# kit_substrate_present <component> — is this component already installed?
# Returns 0 if present, 1 if absent. The body is unchanged from the guard this
# replaces; the timing wrapper below is what makes a step's clock start AFTER
# the guard's check, so a step's time is the step's work and not the guard's
# kubectl probe — and a skipped step is marked, not timed.
kit_substrate_present() {
  local component="$1"
  case "$component" in
    k3s)
      [ -x /usr/local/bin/k3s ] && systemctl is-active --quiet k3s 2>/dev/null
      ;;
    cert-manager)
      kubectl --kubeconfig="$KUBECONFIG" get deployment -n cert-manager cert-manager >/dev/null 2>&1
      ;;
    cloudnative-pg)
      kubectl --kubeconfig="$KUBECONFIG" get deployment -n cnpg-system cnpg-controller-manager >/dev/null 2>&1
      ;;
    argocd)
      # A Deployment core-install ships, so a re-run finds it and skips. This
      # probed argocd-server, which core-install does not ship, so the guard
      # never matched and step 4 re-applied the largest manifest on every run.
      kubectl --kubeconfig="$KUBECONFIG" get deployment -n argocd argocd-repo-server >/dev/null 2>&1
      ;;
    clusterissuer)
      # Cluster-scoped, so no -n: the guard asks for the production issuer by
      # name and the staging one is assumed to have come up beside it.
      kubectl --kubeconfig="$KUBECONFIG" get clusterissuer letsencrypt-prod >/dev/null 2>&1
      ;;
    cluster)
      # The CNPG Cluster object exists. The bootstrap SQL ran once at
      # creation; a re-run must not re-provision, only resume. Qualified by
      # API group: a bare `get cluster` is ambiguous the day another CRD
      # defines the same kind.
      kubectl --kubeconfig="$KUBECONFIG" get cluster.postgresql.cnpg.io postgres -n data >/dev/null 2>&1
      ;;
    redis)
      kubectl --kubeconfig="$KUBECONFIG" get deployment redis -n data >/dev/null 2>&1
      ;;
    nats)
      # The broker only. The stream init below it runs on every install —
      # `info || add` makes that a no-op when the stream exists — so a re-run
      # heals a missing stream without touching a healthy broker.
      kubectl --kubeconfig="$KUBECONFIG" get deployment nats -n data >/dev/null 2>&1
      ;;
    secrets)
      # All four service secrets exist. One missing re-runs the whole step,
      # which reads every existing value back rather than regenerating —
      # so a half-finished first run resumes without rotating live keys.
      for s in identity/identity-secrets gateway/gateway-secrets courier/courier-secrets parlor/parlor-secrets; do
        kubectl --kubeconfig="$KUBECONFIG" get secret "${s#*/}" -n "${s%/*}" >/dev/null 2>&1 || return 1
      done
      ;;
    *)
      return 1
      ;;
  esac
}

# kit_substrate_guard <component> — the step-facing wrapper around the probe
# above. Returns 0 if present (skip), 1 if absent (install), and stamps the
# timing state on the way:
#   * present  → STEP_SKIPPED=1, so the step reports `skipped` and NOT a `0.000`
#                that would read as "this step is free".
#   * absent   → STEP_START_MS=now, the step's OWN boundary, after the probe.
# In DRY_RUN the probe is skipped and every step is stamped as if it would run,
# so a plan is timed end to end rather than reported as thirteen skips.
kit_substrate_guard() {
  local component="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    STEP_START_MS="$(kit_substrate_now)"
    return 1
  fi
  if kit_substrate_present "$component"; then
    STEP_SKIPPED=1
    return 0
  fi
  STEP_START_MS="$(kit_substrate_now)"
  return 1
}

# kit_substrate_pending <component> — record that a component was applied this
# run and its rollout still has to be waited on. Called by steps 2-4 after their
# apply; drained by step 4's grouped wait. A component already present never
# reaches here, because its step returned at the guard.
kit_substrate_pending() {
  PENDING_WAITS="${PENDING_WAITS} $1"
}

# --- helpers ----------------------------------------------------------------
KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

STEP=0
TOTAL=13
# The phase the install is in — set by main before each step, read by the
# emit path and the receipt. It names the STEP, not the sub-step, so the
# receipt's phase is always one of the thirteen (or preflight/complete).
CURRENT_PHASE="install"

# --- timing state -----------------------------------------------------------
# INSTALL_START_MS — stamped once, in main, before preflight, so the total
#   covers the whole run rather than the steps alone.
# STEP_PHASE — the phase the step IN FLIGHT belongs to. Captured at log_step
#   because main sets CURRENT_PHASE to the NEXT step's phase before calling it,
#   so by the time the previous step is finalised CURRENT_PHASE has moved on.
# STEP_START_MS — stamped by the guard when it decides the component is absent;
#   empty until then.
# STEP_SKIPPED — set by the guard when the component is already present.
# STEP_LEDGER — one `step<TAB>phase<TAB>seconds` line per completed step, in
#   order. The final event's `steps` array and the human table both read it, so
#   there is one accounting and not two.
INSTALL_START_MS=""
STEP_PHASE="install"
STEP_START_MS=""
STEP_SKIPPED=0
STEP_LEDGER=""

# PENDING_WAITS — the operator components APPLIED this run whose rollout has not
# been waited on yet. The three operator manifests (cert-manager, CNPG, Argo CD)
# are independent, so they are applied back to back in steps 2-4 and waited on
# TOGETHER at the end of step 4; the controllers then roll out concurrently
# instead of one behind the other. A component whose guard found it present is
# never added, so a warm re-run waits on nothing and step 4 stays a true skip.
PENDING_WAITS=""

# --- the headless emit path ---------------------------------------------------
# TWO writers, and the split between them is the whole property.
#
#   kit_substrate_emit — PROGRESS. In headless mode it is the ONLY thing that
#     reaches stdout, and every line it writes is one JSONL object. In
#     interactive mode the same call prints exactly what the installer has
#     always printed, byte for byte.
#   kit_substrate_out — HUMAN TEXT. stdout in interactive mode; STDERR in
#     headless mode, so the operator (and `caf box logs`) still reads it while
#     stdout stays a machine-parseable stream.
#
# Nothing else in this file writes to the process stdout. `printf … | kubectl`
# is a pipe, not a stdout write; `echo … >&2` is a refusal and already goes to
# stderr. tests/substrate_test.sh parses every echo and printf in this file and
# FAILS on one that reaches stdout from anywhere but those two functions, so
# the claim "headless stdout is progress-only" is enforced rather than
# promised. The message is pre-formatted by the caller and carries no secret —
# a refusal names a VARIABLE, never its value, the same rule as every refusal.

# json_str <string> — the string as a JSON string literal. Every JSONL value
# goes through this, so a quote, a backslash or a newline in a message cannot
# break the line's shape. jq is already a hard requirement (preflight).
json_str() {
  printf '%s' "$1" | jq -Rs '.'
}

# kit_substrate_out <message> — the human channel. Interactive mode prints it
# on stdout, exactly as the `echo` it replaced did; headless mode sends it to
# stderr, because stdout is the agent's channel and it has one shape.
#
# The caller formats the message, so `kit_substrate_out "secret $secret_name
# created …"` names a NAME and never a value — the rule every other line in
# this file already follows. Nothing routed here is ever a credential, a token
# or key material, and the test proves it by reading every call site.
kit_substrate_out() {
  if [ "$HEADLESS" -eq 1 ]; then
    printf '%s\n' "$*" >&2
  else
    printf '%s\n' "$*"
  fi
}

# kit_substrate_emit <event> <message> [<extra-json>] — emit one progress event.
# <extra-json> is a RAW JSON fragment of additional fields (leading comma
# included), e.g. `,"seconds":1.250` or `,"seconds":"skipped"`. It is appended
# verbatim, so the caller is responsible for it being valid JSON — which is why
# the only two callers that pass it build it from a number this file formatted
# itself or from a fixed keyword.
kit_substrate_emit() {
  local event="$1" message="$2" extra="${3:-}"
  if [ "$HEADLESS" -eq 1 ]; then
    printf '{"event":"%s","step":%s,"phase":%s,"message":%s%s}\n' \
      "$event" "$STEP" "$(json_str "$CURRENT_PHASE")" "$(json_str "$message")" "$extra"
  else
    case "$event" in
      step.start) echo "[${STEP}/${TOTAL}] $message" ;;
      step.skip)  echo "      already installed, skipping" ;;
      step.plan)  echo "      DRY_RUN: $message" ;;
      # step.done is a MACHINE event. Interactive mode already saw the step's
      # start line and its own output; the run's speeds are the final table, so
      # printing a line per step here would be noise, not a table.
      step.done)  ;;
      *)          echo "$message" ;;
    esac
  fi
}

# kit_substrate_skip — the guard said the component is already present.
# Used by the steps that skip as a whole; the per-secret and per-stream lines
# go through kit_substrate_out because they carry a name.
kit_substrate_skip() {
  kit_substrate_emit step.skip "already installed, skipping"
}

# kit_substrate_step_finalize — close the step in flight, if any, and append it
# to the ledger. Called by the NEXT log_step (and once by main after the last
# step), so a step that returns early — a skip, a dry-run plan — is still
# closed without thirteen end-of-step calls that a later edit could forget.
#
# Three shapes, and the first is the one the packet names: a SKIPPED step did
# no work, so it reports the string "skipped" and never `0.000`, which would
# read as "this step is free" — the misleading number the timing exists to
# avoid. A measured step reports the window [guard decision, now]. The third,
# "unknown", is unreachable in a completed run (a step that never reached its
# guard would have to have skipped it) and exists so a future step that forgets
# the guard reports a word rather than a silent zero.
kit_substrate_step_finalize() {
  [ "$STEP" -gt 0 ] || return 0
  local secs
  if [ "$STEP_SKIPPED" -eq 1 ]; then
    secs="skipped"
  elif [ -n "$STEP_START_MS" ]; then
    secs="$(kit_substrate_seconds "$(( $(kit_substrate_now) - STEP_START_MS ))")"
  else
    secs="unknown"
  fi
  STEP_LEDGER="${STEP_LEDGER}${STEP}	${STEP_PHASE}	${secs}
"
  # The step.done event names the step's OWN phase. main has already set
  # CURRENT_PHASE to the NEXT step's phase by the time the next log_step
  # finalises this one, so it is restored around the emit.
  local saved_phase="$CURRENT_PHASE"
  CURRENT_PHASE="$STEP_PHASE"
  if [ "$secs" = "skipped" ] || [ "$secs" = "unknown" ]; then
    kit_substrate_emit step.done "$STEP_PHASE: $secs" ",\"seconds\":$(json_str "$secs")"
  else
    kit_substrate_emit step.done "$STEP_PHASE: ${secs}s" ",\"seconds\":${secs}"
  fi
  CURRENT_PHASE="$saved_phase"
  STEP_SKIPPED=0
  STEP_START_MS=""
}

# kit_substrate_steps_json — the ledger as a JSON array, for the final event.
# `seconds` is a number for a measured step and the string "skipped"/"unknown"
# otherwise, exactly as in the step.done events, so a consumer reads one shape.
kit_substrate_steps_json() {
  printf '%s' "$STEP_LEDGER" | jq -R -s -c '
    split("\n")
    | map(select(length > 0) | split("\t"))
    | map({step: (.[0] | tonumber),
           phase: .[1],
           seconds: (if .[2] == "skipped" or .[2] == "unknown"
                     then .[2] else (.[2] | tonumber) end)})'
}

# kit_substrate_print_table — the human face of the same ledger: one line per
# step, a name and a duration, then the total. A compact table, not prose,
# because the question it answers is "which step was the cost".
kit_substrate_print_table() {
  local total="$1" line n phase secs
  kit_substrate_out "  step  phase                seconds"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n="${line%%	*}"
    phase="${line#*	}"
    secs="${phase#*	}"
    phase="${phase%%	*}"
    kit_substrate_out "$(printf '  %-5s %-20s %s' "$n" "$phase" "$secs")"
  done <<EOF
$STEP_LEDGER
EOF
  kit_substrate_out "  total                      ${total}"
}

log_step() {
  # Finalise the PREVIOUS step first: its window closed when this step's
  # log_step began. This is the whole reason the boundary is here and not at
  # the end of each of the thirteen steps — there is one place to get right.
  kit_substrate_step_finalize
  STEP=$((STEP + 1))
  STEP_PHASE="$CURRENT_PHASE"
  # The step's window opens HERE, by default. A step that has a guard re-stamps
  # it after the guard's probe (so the probe is not charged to the step), and a
  # step with no guard — six of the thirteen have none, because their work is
  # idempotent without a presence check — keeps this stamp. Either way every
  # step is measured; none reports `unknown` for want of a guard.
  STEP_START_MS="$(kit_substrate_now)"
  # The receipt follows the install: at each step start it names the phase and
  # the next step, so a crash mid-step leaves a receipt pointing at that step.
  R_PHASE="$CURRENT_PHASE"
  R_NEXT="$*"
  R_INPUT=""
  R_HUMAN=""
  R_STATUS="running"
  R_MESSAGE=""
  kit_substrate_write_receipt
  # `seconds` on step.start is the step's OFFSET since the install began (so a
  # reader can see a step start serializing); on step.done it is the step's
  # DURATION. Two numbers, one key, and this comment is where that is stated.
  kit_substrate_emit step.start "$*" ",\"seconds\":$(kit_substrate_elapsed)"
}

# dry_run <description> — print what would happen and return 0 (skip the real
# work) when DRY_RUN=1, or return 1 (do the real work) when it is not.
dry_run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    kit_substrate_emit step.plan "$*"
    return 0
  fi
  return 1
}

# --- waits that can face an empty list ---------------------------------------
# `kubectl wait --for=<condition> <resource> --all` DOES NOT WAIT on an empty
# list. It fails immediately with `error: no matching resources found` — a
# non-zero exit inside a second, and under `set -e` that is the end of the
# install.
#
# MEASURED, not theorised: k3s is STARTED by the line above step 1's wait, and
# the Node object the kubelet registers lands a few seconds LATER. On a warm
# box the registration has already happened, so the wait finds the object and
# wins; on a WIPED box nothing has registered, the list is empty, and the wait
# loses — a fresh Contabo box died at step 1 with exactly that error, exit 1,
# before any step after it ran. A wait that survives one box state and dies on
# the other is a race, and this is the shape it takes.
#
# A wait that runs immediately after a synchronous `kubectl apply` of the SAME
# object does not need this, and is NOT given it: the object exists the moment
# apply returns, because apply is a round trip that created it. The ones that
# need it are the objects a CONTROLLER creates asynchronously — the Node
# object behind the kubelet, the Cluster's pods behind the CNPG operator.
#
# SO THE SHAPE IS TWO WAITS AND ONE BOUND: prove the list is not empty first
# (bounded, below), then wait for the condition with the part of the step's
# budget that is left. The two bounds add up to the total the step always had,
# because a slow registration must not become a slow install. A genuinely
# broken cluster still fails — exactly as it did before — and now says which
# object never appeared instead of reporting a condition that was never
# measured.
kit_substrate_await_list() {
  local budget="$1"; shift
  kit_substrate_out "      waiting up to ${budget}s for: kubectl get $*"
  local deadline list
  deadline=$(( $(date +%s) + budget ))
  while :; do
    # A command substitution, NOT a pipe into `grep -q .`: `grep -q` closes the
    # pipe on its first match, the producer dies of SIGPIPE, and `pipefail`
    # promotes its 141 to the pipeline's status — so a LONG list would read as
    # an empty one and poll until the deadline on a healthy cluster. `--no-headers`
    # prints exactly one line per object and nothing at all for an empty list,
    # and a GET on an empty list exits 0, so "non-empty output" IS "the list is
    # not empty", and a failing GET is no answer yet rather than a verdict.
    list="$(kubectl --kubeconfig="$KUBECONFIG" get "$@" --no-headers 2>/dev/null || true)"
    if [ -n "$list" ]; then
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      kit_substrate_refuse "" \
        "timed out after ${budget}s waiting for: kubectl get $* (the list is empty)" \
        "the object does not exist yet, so there is nothing to wait for — check the controller that owns it (the kubelet for a Node, the CNPG operator for the Cluster's pods, the API server itself), then re-run: every step that already completed is skipped by its guard"
    fi
    sleep 2
  done
}

# kit_substrate_await_port <port> <budget> — wait until a LOCAL TCP port accepts
# a connection. The companion of kit_substrate_await_list, for the one thing a
# `kubectl port-forward` needs and a `kubectl get` does not: the listener is
# established ASYNCHRONOUSLY by the port-forward process (it must reach the API
# server, find the pod and dial it), so a curl issued the line after the
# background `&` races it and dies with `curl: (7) Failed to connect … port
# <n>`. That is a CONNECT failure, not an HTTP status — the schema-missing 500
# is a different error (curl exit 22 under `-f`) — and conflating the two is how
# a racy forward reads as "identity would not mint a signup timestamp".
#
# The shape is existence-then-use, the same shape the list and rollout waits
# take: prove the endpoint is UP (bounded), then use it with what is left. Uses
# bash's /dev/tcp so it needs no `nc`, which a customer box is not promised.
kit_substrate_await_port() {
  local port="$1" budget="$2" deadline
  deadline=$(( $(date +%s) + budget ))
  while :; do
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      return 1
    fi
    sleep 1
  done
}

# --- the install receipt ------------------------------------------------------
# The receipt is the resumable-install contract and the agent's map of the
# install: it names the phase, the next step, the input needed and where the
# human goes. `caf box apply --phase N` (W2-P6) reads it to know what to do
# next; W5-P4's resumable install is its consumer.
R_PHASE="install"
R_NEXT=""
R_INPUT=""
R_HUMAN=""
R_STATUS="running"
R_MESSAGE=""

kit_substrate_write_receipt() {
  local dir
  dir="$(dirname "$RECEIPT_PATH")"
  # Best-effort on a machine that is not a box: a dev machine running DRY_RUN
  # has no /var/lib/kit, and there the receipt is a nicety, not a contract. On
  # a box the installer runs as root and the directory is made. A failure here
  # never stops the install — the receipt is a report, not a gate.
  if ! mkdir -p "$dir" 2>/dev/null; then
    return 0
  fi
  jq -n \
    --arg phase "$R_PHASE" \
    --arg status "$R_STATUS" \
    --argjson step "$STEP" \
    --argjson total_steps "$TOTAL" \
    --arg next "$R_NEXT" \
    --arg input_needed "$R_INPUT" \
    --arg human "$R_HUMAN" \
    --arg message "$R_MESSAGE" \
    --arg receipt "$RECEIPT_PATH" \
    --argjson headless "$HEADLESS" \
    --argjson dry_run "$DRY_RUN" \
    --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      phase: $phase,
      status: $status,
      step: $step,
      total_steps: $total_steps,
      next: (if $next == "" then null else $next end),
      input_needed: (if $input_needed == "" then null else $input_needed end),
      human: (if $human == "" then null else $human end),
      message: (if $message == "" then null else $message end),
      receipt: $receipt,
      headless: $headless,
      dry_run: $dry_run,
      updated_at: $updated_at
    }' >"$RECEIPT_PATH" 2>/dev/null || true
}

# kit_substrate_refuse <input_needed> <human> <message> — the ONE refusal path.
# The message and the fix both go to stderr for the human, in the same
# `error:` + indented-hint shape every refusal in this file has always used
# (a refusal names a VARIABLE, never its value). In headless mode a refusal
# event goes to stdout and the receipt is rewritten with the input needed and
# where the human goes, so the agent driving the install knows what to
# collect and what to tell the operator.
#
# THE HINT IS NOT OPTIONAL, and dropping it was a real regression: the first
# version of this helper printed only `error: <message>` and the operator lost
# the `export KIT_SUBSTRATE_…` line that tells them how to unblock. The
# interactive contract is the message AND the fix, on two lines.
kit_substrate_refuse() {
  local input="$1" human="$2" message="$3"
  printf 'error: %s\n' "$message" >&2
  [ -n "$human" ] && printf '  %s\n' "$human" >&2
  if [ "$HEADLESS" -eq 1 ]; then
    printf '{"event":"refusal","step":%s,"phase":%s,"input_needed":%s,"human":%s,"message":%s}\n' \
      "$STEP" "$(json_str "$CURRENT_PHASE")" "$(json_str "$input")" "$(json_str "$human")" "$(json_str "$message")"
  fi
  R_PHASE="$CURRENT_PHASE"
  R_INPUT="$input"
  R_HUMAN="$human"
  R_STATUS="refused"
  R_MESSAGE="$message"
  kit_substrate_write_receipt
  exit 1
}

# --- readiness honesty -------------------------------------------------------
# THE BOX THAT CANNOT SERVE MUST SAY SO. Measured on the live Contabo box
# (2026-10): the install ran to completion and exited 0 while
# `kubectl get applications -n argocd` showed gateway `Degraded` and
# `kubectl -n gateway get pods` showed `Readiness probe failed: HTTP probe
# failed with statuscode: 503` 1564 times over four hours. Two independent
# causes, both invisible in the installer's output:
#
#   1. ACME could never complete: `kubectl get challenges -n gateway` showed
#      `Waiting for HTTP-01 challenge propagation: failed to perform self
#      check ... dial tcp: lookup api.cafaye.com on 10.43.0.10:53: no such
#      host`. The operator never pointed DNS at the box; the installer
#      created the Certificates, waited for nothing, and finished.
#   2. gateway could never be Ready: its /readyz probes identity's JWKS, and
#      identity serves that route only when OIDC is configured. The box's
#      identity-secrets held no OIDC keys (the installer writes them only
#      when KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER is set), so identity answered
#      404 and gateway's readiness failed forever.
#
# Both are operator inputs the installer correctly refuses to guess (a
# localhost default "mails every reader to a screen that is not theirs"), so
# neither is a refusal here. THE DEFECT WAS SILENCE: a run over them reported
# the same successful install.done as a run over a fully-ready box. What
# follows is a REPORT — in preflight (before anything is created) and in the
# final report beside the step times — plus the same verdict as a `readiness`
# JSONL event for the headless caller. A box with no public DNS is a
# legitimate target behind a firewall; the operator must be told which state
# they chose. No KIT_SUBSTRATE_* variable here guesses a hostname, a URL or
# an issuer: every host below is read out of what the installer is about to
# write (the operator's two URLs, plus any public host in the Applications'
# helm.values), never out of a second hard-coded list.
# --- honest-done BEGIN
READINESS_TLS_PENDING=""

# kit_substrate_url_host <url> — the hostname inside a URL. Scheme, path,
# query, fragment and port are stripped; what is left is what DNS must
# resolve. Prints empty for an empty input.
kit_substrate_url_host() {
  local rest="${1:-}"
  case "$rest" in
    *://*) rest="${rest#*://}" ;;
  esac
  rest="${rest%%/*}"
  rest="${rest%%:*}"
  printf '%s' "$rest"
}

# kit_substrate_is_checkable_host <host> — is this a name public DNS must
# resolve? In-cluster names (anything under .svc, .local, bare localhost or a
# single label) are answered by the cluster or the box itself, so resolving
# them here would prove nothing about ACME.
kit_substrate_is_checkable_host() {
  case "$1" in
    "") return 1 ;;
    localhost | *.svc.cluster.local | *.svc | *.local) return 1 ;;
  esac
  case "$1" in
    *.*) return 0 ;;
    *) return 1 ;;
  esac
}

# kit_substrate_host_resolves <host> — does this box resolve the name?
# getent on Linux (the box); dscacheutil on macOS (a developer DRY_RUN);
# python3's resolver as the last fallback. A missing resolver is "cannot
# tell", reported as unresolving with the reason in the report — never a
# refusal, and never silence.
kit_substrate_host_resolves() {
  local host="$1"
  [ -n "$host" ] || return 1
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$host" >/dev/null 2>&1
    return $?
  fi
  if command -v dscacheutil >/dev/null 2>&1; then
    dscacheutil -q host -a name "$host" 2>/dev/null | grep -q 'ip_address:'
    return $?
  fi
  python3 -c 'import socket,sys; socket.getaddrinfo(sys.argv[1], None)' "$host" >/dev/null 2>&1
  return $?
}

# kit_substrate_intended_hosts [manifest_dir] — every public hostname the
# install is about to serve, one per line, deduplicated. Two sources, both
# read rather than listed: the operator's two URLs (APP_BASE_URL becomes
# identity's link templates, OIDC_ISSUER becomes identity's issuer — both
# written by this installer), and any public https host in the Applications'
# helm.values. Comments are stripped before the scan so a URL mentioned in
# prose (e.g. a chart default deliberately NOT set) is not reported as
# intended. In-cluster names are dropped by kit_substrate_is_checkable_host.
kit_substrate_intended_hosts() {
  local dir="${1:-$MANIFEST_DIR}" hosts="" url h found
  for url in "$KIT_SUBSTRATE_APP_BASE_URL" "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER"; do
    [ -n "$url" ] || continue
    h="$(kit_substrate_url_host "$url")"
    if kit_substrate_is_checkable_host "$h"; then
      hosts="${hosts}${h}
"
    fi
  done
  if [ -d "$dir" ]; then
    # The Application's FETCH coordinates are not served names: repoURL is
    # where Argo pulls the chart from and destination.server is the API
    # server Argo talks to, so neither gets a Certificate and neither is
    # resolved here. What is left after dropping those two keys (and the
    # comments) is the helm.values the installer applies — the served
    # surface, which today is in-cluster http only.
    found="$(sed 's/#.*//' "$dir"/*.yaml 2>/dev/null | grep -vE 'repoURL:|destination:|server: https://' | grep -oE 'https?://[^"'"'"' <>]+' 2>/dev/null || true)"
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      h="$(kit_substrate_url_host "$url")"
      if kit_substrate_is_checkable_host "$h"; then
        hosts="${hosts}${h}
"
      fi
    done <<EOF
$found
EOF
  fi
  printf '%s' "$hosts" | awk 'NF && !seen[$0]++'
}

# kit_substrate_compute_readiness — resolve every intended host now and store
# the ones that do not. Run once, in preflight (before anything is created);
# the final report and the JSONL event read READINESS_TLS_PENDING back. The
# OIDC half needs no probe: unset issuer means no JWKS route by construction.
kit_substrate_compute_readiness() {
  READINESS_TLS_PENDING=""
  local h all pending=""
  all="$(kit_substrate_intended_hosts)"
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    if ! kit_substrate_host_resolves "$h"; then
      pending="${pending}${h}
"
    fi
  done <<EOF
$all
EOF
  READINESS_TLS_PENDING="$pending"
}

# kit_substrate_readiness_pending_count — conditions keeping the box from
# fully serving: one per unresolving host, plus one when the OIDC issuer is
# unset. A number, for the human summary and the JSONL message.
kit_substrate_readiness_pending_count() {
  local n=0 h
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    n=$((n + 1))
  done <<EOF
$READINESS_TLS_PENDING
EOF
  if [ -z "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ]; then
    n=$((n + 1))
  fi
  printf '%s' "$n"
}

# kit_substrate_readiness_preflight — the preflight half of the report: which
# intended hosts do not resolve and what that means, and the OIDC consequence
# with the one export that turns it on. A report, not a refusal.
kit_substrate_readiness_preflight() {
  kit_substrate_compute_readiness
  local h all
  all="$(kit_substrate_intended_hosts)"
  kit_substrate_out "  readiness preflight: resolving the intended public hosts on this box"
  if [ -z "$all" ]; then
    kit_substrate_out "    no checkable public host to resolve (unset or local/in-cluster URLs need no public DNS)"
  elif [ -z "$READINESS_TLS_PENDING" ]; then
    kit_substrate_out "    every intended host resolves"
  else
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      kit_substrate_out "    ${h}: DOES NOT RESOLVE — the ACME HTTP-01 self check will fail, the Certificate will sit pending, and the Ingress will keep serving plaintext on port 80"
    done <<EOF
$READINESS_TLS_PENDING
EOF
  fi
  if [ -z "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ]; then
    kit_substrate_out "  OIDC: KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER is unset — identity serves no JWKS route, so gateway's /readyz fails and its Deployment never becomes Ready"
    kit_substrate_out "    turn it on with: export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='https://<your-issuer>'"
  else
    kit_substrate_out "  OIDC: issuer is set — identity serves its JWKS route"
  fi
  local store
  store="$(kit_substrate_log_store)"
  if [ "$store" = "journald" ]; then
    kit_substrate_out "  logs: centralized Loki not installed — logs in journald / kubectl logs; Alloy runs but ships nowhere centrally"
  else
    kit_substrate_out "  logs: centralized Loki installed — query via Grafana Explore / Loki API"
  fi
}

# kit_substrate_log_store — where logs land on this substrate. Loki's
# upstream chart 7.3.0 in SimpleScalable mode requires object storage
# (loki.storage.bucketNames.chunks and a backend endpoint/bucket/keys); this
# single-box substrate provisions no object store, so the Application is not
# installed and logs remain in journald / kubectl logs. Alloy still runs but
# ships nowhere centrally. If a future substrate provisions an object store,
# this function and the Application return together — the report is the proof.
kit_substrate_log_store() {
  if [ -f "$MANIFEST_DIR/loki.yaml" ]; then
    printf 'loki'
  else
    printf 'journald'
  fi
}

# kit_substrate_readiness_final — the done-report half: the shape of the box,
# not just the step times. Each unready condition with its exact remedy; the
# header is unconditional so a run with nothing pending still names the
# verdict rather than going quiet (quiet is the defect this ends).
kit_substrate_readiness_final() {
  local h
  kit_substrate_out "  THIS BOX WILL NOT FULLY SERVE UNTIL:"
  if [ -n "$READINESS_TLS_PENDING" ]; then
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      kit_substrate_out "    - ${h} resolves (point ${h} at this box) — until then the ACME HTTP-01 self check fails, the Certificate sits pending, and the Ingress serves plaintext on port 80"
    done <<EOF
$READINESS_TLS_PENDING
EOF
  fi
  if [ -z "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ]; then
    kit_substrate_out "    - KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER is set (export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='https://<your-issuer>') — until then identity serves no JWKS route, so gateway's /readyz fails and its Deployment never becomes Ready"
  fi
  if [ -z "$READINESS_TLS_PENDING" ] && [ -n "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ]; then
    kit_substrate_out "    (none — every intended host resolves and the OIDC issuer is set)"
  fi
  # Log store is not a readiness condition but a shape statement: what the
  # installer DID NOT install, and where to find the logs it does not centralize.
  # The loki Application's render failure (ComparisonError at
  # loki/storage.bucketNames.chunks) is the evidence; the absence is the fix.
  local store
  store="$(kit_substrate_log_store)"
  if [ "$store" = "journald" ]; then
    kit_substrate_out "  logs: centralized Loki not installed — logs remain in journald / kubectl logs (kubectl -n <ns> logs <pod>); Alloy runs but ships nowhere centrally"
    kit_substrate_out "    reason: loki chart 7.3.0 SimpleScalable requires loki.storage.bucketNames.chunks and an object-storage backend (endpoint/bucket/access_key/secret_key); this substrate provisions no object store"
  else
    kit_substrate_out "  logs: centralized Loki installed — query via Grafana Explore / Loki API"
  fi
}

# kit_substrate_readiness_summary — the one-line verdict the JSONL event and
# the human report share.
kit_substrate_readiness_summary() {
  local n
  n="$(kit_substrate_readiness_pending_count)"
  if [ "$n" -eq 0 ]; then
    printf 'readiness: no known unready condition'
  else
    printf 'readiness: %s condition(s) keep this box from fully serving' "$n"
  fi
}

# kit_substrate_readiness_json — the machine half of the same verdict: the
# field is `tls_pending_hosts` (every intended host that does not resolve)
# beside `oidc_configured` and `log_store`. Leading comma included, for
# kit_substrate_emit's <extra-json> slot; the existing events are untouched.
kit_substrate_readiness_json() {
  local hosts_json oidc="false" store
  hosts_json="$(printf '%s' "$READINESS_TLS_PENDING" | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  if [ -n "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ]; then
    oidc="true"
  fi
  store="$(kit_substrate_log_store)"
  printf ',"tls_pending_hosts":%s,"oidc_configured":%s,"log_store":"%s"' "$hosts_json" "$oidc" "$store"
}
# --- honest-done END

# --- preflight --------------------------------------------------------------
# Every check here is a refusal, not a warning: a half-installed substrate is
# worse than no substrate, because it looks like it works.
preflight() {
  if [ "$DRY_RUN" -eq 1 ]; then
    kit_substrate_emit progress "DRY_RUN: would check root, curl, openssl, jq, Linux, arch, memory, registry reachability"
    kit_substrate_readiness_preflight # honest-done
    return 0
  fi

  if [ "$(id -u)" -ne 0 ]; then
    kit_substrate_refuse "" "run as root — k3s installs to /usr/local and writes the kubeconfig" "must run as root — k3s installs to /usr/local and writes the kubeconfig"
  fi

  if ! command -v curl >/dev/null 2>&1; then
    kit_substrate_refuse "" "install curl — every component is fetched over HTTPS" "curl is required — every component is fetched over HTTPS"
  fi

  # openssl generates identity's OIDC signing key ON THIS BOX (it is the
  # customer's own key and never travels), and jq reads step 12's mint
  # response. Both are refusals, not warnings: the first would otherwise be
  # discovered by an operator with a copy-paste runbook to fall back on, which
  # is exactly the invariant-3 violation this install exists to remove.
  if ! command -v openssl >/dev/null 2>&1; then
    kit_substrate_refuse "" "install openssl — identity's OIDC signing key is generated on this box rather than supplied" "openssl is required — identity's OIDC signing key is generated on this box rather than supplied"
  fi

  if ! command -v jq >/dev/null 2>&1; then
    kit_substrate_refuse "" "install jq — step 12 reads the minted credential out of identity's response" "jq is required — step 12 reads the minted credential out of identity's response"
  fi

  if [ "$(uname -s)" != "Linux" ]; then
    kit_substrate_refuse "" "this script installs k3s, which needs Linux" "this script installs k3s, which needs Linux (found $(uname -s))"
  fi

  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64 | aarch64) ;;
    *)
      kit_substrate_refuse "" "k3s supports x86_64 and aarch64" "unsupported architecture '$arch' — k3s supports x86_64 and aarch64"
      ;;
  esac

  # Memory. DEPLOYMENT.md sizes the box: 8GB comfortable, 4GB no longer
  # qualifies once the Grafana stack lands. Measured from /proc/meminfo.
  local mem_kb
  mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [ "$mem_kb" -lt 4194304 ]; then
    kit_substrate_refuse "" "DEPLOYMENT.md sizes the box: 8GB comfortable, 4GB no longer qualifies once the Grafana stack lands" "${mem_kb} kB RAM — 4GB no longer qualifies once the Grafana stack lands (DEPLOYMENT.md)"
  fi
  if [ "$mem_kb" -lt 8388608 ]; then
    echo "warning: ${mem_kb} kB RAM — 8GB is comfortable for the full stack" >&2
  fi

  # The registry is where the pull secret and every chart come from. An
  # unreachable ghcr.io is a refusal, not a retry: the install cannot complete.
  if ! curl -s --max-time 10 -o /dev/null https://ghcr.io/v2/; then
    kit_substrate_refuse "" "check network access to ghcr.io — the pull secret and charts come from there" "ghcr.io is unreachable — the pull secret and charts come from there"
  fi
  # The readiness verdict is a REPORT, not a refusal: a box with no public DNS
  # is a legitimate target behind a firewall, and an unset OIDC issuer is a
  # supported reduced surface. Both run here — before anything is created — so
  # the operator learns which state they chose while there is still nothing to
  # undo. DRY_RUN reports it too, through the early return above.
  kit_substrate_readiness_preflight # honest-done
}

# --- step 1: k3s ------------------------------------------------------------
# THE TWO BOUNDS ARE THIS STEP'S OWN 120s, SPLIT HONESTLY: 90s for the Node
# object to register, 30s for it to become Ready. Both are overridable so the
# suite can shorten them — the rule is the split, not the numbers.
: "${NODE_REGISTER_TIMEOUT:=90}"
: "${NODE_READY_TIMEOUT:=30}"
install_k3s() {
  log_step "k3s ${K3S_VERSION} — single node, sqlite datastore"
  if kit_substrate_guard k3s; then
    kit_substrate_out "      already installed, skipping"
    return 0
  fi
  if dry_run "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${K3S_VERSION} sh -"; then
    return 0
  fi
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -
  # TWO WAITS, because the Node object is created ASYNCHRONOUSLY: the line
  # above starts k3s, and the kubelet registers the Node a few seconds after
  # that. This step used to be a single `wait --for=condition=Ready node
  # --all`, which on an EMPTY list is not a wait at all — it is `error: no
  # matching resources found`, exit 1, and the install is dead at step 1. On a
  # box that had already registered a node the race was invisible; on a wiped
  # one it was the whole install. So the node must EXIST first, and only then
  # be waited on for Ready. See the helper above for the measurement.
  kit_substrate_await_list "$NODE_REGISTER_TIMEOUT" node
  kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Ready node --all --timeout="$((NODE_READY_TIMEOUT))s"
}

# --- step 2: cert-manager ----------------------------------------------------
# THE TWO MODES ARE NOT A STYLE CHOICE, and the installer does not mix them
# per-object by accident. A manifest fetched from a REMOTE URL (steps 2-4) is
# applied `--server-side=true --force-conflicts`; a manifest shipped in THIS
# repository (steps 6-10) stays on client-side apply. Both halves are stated
# once here and again at their first use, because the reason each way is the
# thing that stops a later edit from "tidying" them into one shape.
#
# REMOTE, server-side: client-side apply's last-applied-configuration
# annotation overflows Kubernetes's 262144-byte cap on metadata.annotations for
# cert-manager's, CNPG's and Argo CD's CRDs — measured on the box, named in
# install_cert_manager below. `--force-conflicts` rides along so a re-run on a
# box that has already had a hand-repaired client-side apply takes the fields
# back instead of refusing with "field managed by another client".
#
# LOCAL, client-side: these files are small, they are re-applied on every run as
# the installer's own convergence mechanism, and server-side apply would take
# away a re-run's ability to reclaim a field it previously owned. The remote
# manifests are third-party inputs whose ownership the installer must not
# contest; the local ones are kit's own, and reclaiming them is the point.
install_cert_manager() {
  log_step "cert-manager ${CERT_MANAGER_VERSION}"
  if kit_substrate_guard cert-manager; then
    kit_substrate_out "      already installed, skipping"
    return 0
  fi
  # A REMOTE MANIFEST IS APPLIED SERVER-SIDE, and that is measured rather than
  # preferred. Client-side apply writes the whole object into the
  # `kubectl.kubernetes.io/last-applied-configuration` annotation, and
  # cert-manager's, CNPG's and Argo CD's manifests are large enough that the
  # annotation overflows the 262144-byte ceiling Kubernetes puts on
  # `metadata.annotations` — the API server refuses the object, not the apply:
  #   `CustomResourceDefinition "clusters.postgresql.cnpg.io" is invalid:
  #     metadata.annotations: Too long: may not be more than 262144 bytes`
  # measured live on the Contabo box (169.58.108.209), on
  # `clusters.postgresql.cnpg.io` and `applicationsets.argoproj.io`. Server-side
  # apply keeps that bookkeeping on the API server instead, where the object's
  # field manager does the work and no annotation grows.
  #
  # `--force-conflicts` is not optional either, and it is the same decision seen
  # from the re-run side. Once a box has had ANY client-side apply of these
  # objects — a hand-repaired `kubectl apply -f` to get past the failure above,
  # or an earlier version of this installer — the field managers disagree, and a
  # plain server-side apply refuses with `field is managed by another client`.
  # The flags are therefore a pair: the mode that survives the annotation
  # ceiling is only usable if it also takes the fields back, and mixing modes
  # per step is exactly the state that leaves a half-applied substrate behind.
  if dry_run "kubectl apply --server-side=true --force-conflicts -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"; then
    return 0
  fi
  kubectl --kubeconfig="$KUBECONFIG" apply --server-side=true --force-conflicts -f \
    "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  # THE WAIT IS NOT HERE. The three operator manifests — this one, CNPG's and
  # Argo CD's — are INDEPENDENT: separate namespaces, separate CRDs, separate
  # controllers, and applies that do not reference one another. Applied one
  # step at a time and waited one step at a time, CNPG's apply sits behind
  # cert-manager's rollout and Argo CD's behind CNPG's, and the three steps add
  # up. Applied back to back (steps 2-4) and waited on together at the end of
  # step 4, the three controllers roll out CONCURRENTLY and the waits mostly
  # return at once. So the wait moves; the apply does not. See install_argocd.
  kit_substrate_pending cert-manager
}

# --- step 3: CloudNativePG --------------------------------------------------
install_cnpg() {
  log_step "CloudNativePG ${CNPG_VERSION}"
  if kit_substrate_guard cloudnative-pg; then
    kit_substrate_out "      already installed, skipping"
    return 0
  fi
  # Same mode as cert-manager above, for the same measured reason: the CNPG
  # release manifest ships CRDs whose last-applied-configuration annotation
  # exceeds Kubernetes's 262144-byte ceiling, and this is the one that failed
  # first on the box.
  if dry_run "kubectl apply --server-side=true --force-conflicts -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_VERSION}/releases/cnpg-${CNPG_VERSION#v}.yaml"; then
    return 0
  fi
  kubectl --kubeconfig="$KUBECONFIG" apply --server-side=true --force-conflicts -f \
    "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_VERSION}/releases/cnpg-${CNPG_VERSION#v}.yaml"
  # The wait moved to step 4's grouped wait, for the reason written at step 2:
  # the three operator applies are independent and their rollouts overlap when
  # the applies are not serialized behind each other's waits.
  kit_substrate_pending cnpg
}

# --- step 4: Argo CD core ---------------------------------------------------
install_argocd() {
  log_step "Argo CD core ${ARGOCD_VERSION}"
  # The guard no longer RETURNS on a hit: step 4 also drains the grouped waits
  # for the operators steps 2 and 3 applied, so a present Argo CD skips only its
  # own apply — not the waits for its neighbours, and not the AppProject below,
  # which is deliberately outside the guard (see the decision at the bottom of
  # this step).
  local argocd_present=0
  if kit_substrate_guard argocd; then
    kit_substrate_out "      already installed, skipping"
    argocd_present=1
  fi
  # The third and largest remote manifest, and the second of the two CRDs that
  # overflowed the annotation ceiling on the box. Same flags, same reason; a
  # mode chosen per step is how a substrate ends up half-applied.
  #
  # The plan line is core-install ONLY. It used to end "and apply
  # …/appproject.yaml", which described an apply that the guard below could
  # suppress — a promise the plan made and the run did not keep.
  if [ "$argocd_present" -eq 0 ]; then
    if ! dry_run "kubectl apply -n argocd --server-side=true --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/core-install.yaml (the Argo CD core manifest)"; then
      kubectl --kubeconfig="$KUBECONFIG" create namespace argocd --dry-run=client -o yaml |
        kubectl --kubeconfig="$KUBECONFIG" apply -f -
      kubectl --kubeconfig="$KUBECONFIG" apply -n argocd --server-side=true --force-conflicts -f \
        "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/core-install.yaml"
      kit_substrate_pending argocd
    fi
  fi

  # THE GROUPED WAIT — THE MEASURED SPEED DECISION, AND WHY IT IS SAFE. The
  # three operator manifests are independent: cert-manager's, CNPG's and Argo
  # CD's objects live in three namespaces behind three sets of CRDs, and none
  # of the three applies reads an object another one creates. So applying all
  # three before waiting on any of them cannot race an empty list — every
  # `--all` list and every named Deployment here was created by an apply that
  # has ALREADY returned (a `kubectl apply` is a round trip: the objects exist
  # when it exits), which is exactly the condition the empty-list rule in
  # kit_substrate_await_list exists to protect. What changes is only WHEN the
  # rollouts start: serialized behind each other's waits, the three steps added
  # up; overlapped, the controllers come up at once and this drain mostly
  # returns immediately. A component whose guard found it present is not in
  # PENDING_WAITS, so a warm re-run waits on nothing.
  local pending waited=0
  for pending in $PENDING_WAITS; do
    case "$pending" in
      cert-manager)
        kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment -n cert-manager --all --timeout=180s
        waited=1
        ;;
      cnpg)
        kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment -n cnpg-system cnpg-controller-manager --timeout=180s
        waited=1
        ;;
      argocd)
        kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment -n argocd --all --timeout=300s
        waited=1
        ;;
    esac
  done
  PENDING_WAITS=""
  # A step that waited on an operator another step applied DID real work, so it
  # is timed rather than reported as a skip — the guard's "present" verdict was
  # about Argo CD's own apply, not about this wait.
  if [ "$waited" -eq 1 ]; then
    STEP_SKIPPED=0
  fi

  # THE APPPROJECT, AND WHY IT IS NOT UNDER THE GUARD ABOVE.
  #
  # MEASURED, ON A WARM BOX. The live Contabo box carried the pre-glob project:
  #   kubectl -n argocd get appproject default -o jsonpath='{.spec.sourceRepos}'
  #   ["https://grafana.github.io/helm-charts",
  #    "https://prometheus-community.github.io/helm-charts",
  #    "oci://ghcr.io/cafaye/charts"]
  # while this repository had already written
  #   oci://ghcr.io/cafaye/charts/*
  # for the per-chart OCI paths the Applications name. The apply that would
  # have fixed it sat inside `if [ "$argocd_present" -eq 0 ]`, and the guard at
  # the top of this step answered PRESENT — `kubectl get deployment -n argocd
  # argocd-repo-server` succeeds on any box that ever got past step 4 — so the
  # step printed "already installed, skipping" and the fixed file was never
  # applied. Every Application read
  #   Unknown: repo oci://ghcr.io/cafaye/charts/gateway is not permitted in
  #   project 'default'
  # on a box where nothing else was wrong, and the only way to land the fix was
  # to delete Argo CD and re-run. A packet that passes on the next clean box
  # and cannot reach a warm one is not a fix.
  #
  # THE DECISION: A GUARD THAT COVERS AN OPERATOR INSTALL AND A PROJECT FILE
  # CONFLATES TWO LIFETIMES, and this one did. `kit_substrate_guard argocd`
  # answers "is the OPERATOR installed" — a question about four Deployments this
  # repository did not write and has no reason to rewrite. The AppProject is the
  # other kind of thing: a file THIS repository owns, shipped in
  # manifests/argocd/, edited whenever the Applications' chart paths move, and
  # least-privilege by deliberate decision. The operator's stability was
  # suppressing the policy file's currency, which is why the second spelling of
  # the fix was rejected rather than chosen: a guard keyed on the AppProject's
  # own EXISTENCE answers "present" on the exact box holding the WRONG project
  # — green on the measured defect — and a guard keyed on the file's bytes is a
  # diff against something already applied. A 112-line project file is too
  # small to guard; what it needs is to be re-applied.
  #
  # AND RE-APPLYING IS ALREADY THIS INSTALLER'S OWN CONVERGENCE MECHANISM. Step
  # 6 carries no guard either: it applies the seven Applications on every run,
  # because `kubectl apply` of an unchanged object is one no-op API round trip
  # and the convergence is worth more than the round trip. The AppProject is
  # smaller than any one of those and the argument holds with more force. So
  # the apply moves out of the operator's `if`, below the wait, and the
  # OPERATOR stays guarded: a warm box now re-applies one small local file and
  # still skips the three remote manifests — which is what "already installed,
  # skipping" should have meant all along.
  #
  # WHY HERE AND NOT AT STEP 6, and why it survived the move. The AppProject CRD
  # ships inside core-install.yaml, so on a cold box this apply needs the apply
  # above to have returned and the grouped wait to have held before it can be
  # parsed. On a warm box PENDING_WAITS is empty, the wait drains at once, and
  # the CRD is there because the guard found the operator. And it must stay
  # BEFORE step 6: Argo's application-controller reconciles an Application
  # only when its project exists, so applying the project in the same
  # `kubectl apply` as the Applications relies on apply ordering and on the
  # controller re-queuing an Unknown Application after the project appears.
  #
  # LOCAL manifest, CLIENT-SIDE apply (the note above step 2 holds). Applied
  # by name, so the file is deliberate; the directory is checked so a stray
  # file beside it is surfaced rather than skipped (see install_applications).
  if dry_run "kubectl apply -f ${ARGOCD_MANIFEST_DIR}/appproject.yaml (the default AppProject the Applications name)"; then
    return 0
  fi
  kit_substrate_check_manifest_dir "$ARGOCD_MANIFEST_DIR"
  kubectl --kubeconfig="$KUBECONFIG" apply -f "$ARGOCD_MANIFEST_DIR/appproject.yaml"
  # This is WORK, so the step is timed rather than reported as a skip. A warm
  # box finds the operator present — the step's headline — and still spends an
  # API round trip here claiming the project; reporting `skipped` over it is the
  # same misleading number the timing ledger refuses for a step that ran.
  STEP_SKIPPED=0
}

# --- step 5: the image pull secret ------------------------------------------
# The credential is EXCHANGED, never handed over. The box presents its own
# single-use, minutes-lived, box-bound capability to the fleet's registry
# exchange — `registry`, the service that trades a redeemed registry.pull
# capability for a short-lived dockerconfigjson — and the exchange spends the
# capability at box's own redeem route itself, naming the purpose and the box
# it is spent FOR. So the single-use, purpose-bound, box-bound enforcement
# stays where it already lives (`Capability.redeem!`), and the registry
# credential's source material lives in exactly one process whose only job is
# holding it. Box holds no registry credential (box/BOUNDARIES.md:6, :8),
# which is why the exchange is a service and not a route on box.
#
# THREE THINGS ARE NEVER DONE, and the suite asserts all three:
#   1. the capability is never printed;
#   2. the dockerconfigjson is never printed, and NEVER ENTERS ARGV — it goes
#      from curl's response into a shell variable and out through
#      `/dev/stdin`, exactly the way the capability itself was piped. A value
#      in argv is a value in `ps`, in a crash report and in a shell history.
#   3. the credential is never written to disk — no temp file, no kubeconfig
#      side file, nothing.
#
# What used to happen here is the previous packet's work, not a regression: the
# installer redeemed at box, got a receipt, and REFUSED the write, because
# nothing in the fleet traded a receipt for a dockerconfigjson (seam audit
# §5a-5c). That gap is now closed by the registry service; the receipt the
# exchange's caller used to parse is now the exchange's own private business.

# KIT_SUBSTRATE_REGISTRY_URL is where the EXCHANGE lives. Configuration, not a
# secret: it names the service that mints credentials, which is a different
# service from the box that spends the capability. No default of `localhost` —
# a silently local URL is how a box exchanges with itself.
: "${KIT_SUBSTRATE_REGISTRY_URL:=https://registry.svc.cafaye.com}"

# The namespaces that pull the fleet's own images. Five, and the list is
# asserted by the suite: a namespace added here without a pull secret is a
# CrashLoopBackOff in a voice nobody can attribute.
REGISTRY_PULL_NAMESPACES=(argocd identity gateway courier parlor observability)
REGISTRY_PULL_SECRET_NAME="ghcr-pull-secret"

# The floor the exchange reports for the credential's remaining life. It is
# measured HERE rather than trusted, because a credential with nothing left
# is a Secret that expires while pods are scheduling — the failure the
# preflight exists to prevent, arriving at image-pull time.
REGISTRY_CREDENTIAL_MIN_SECONDS=60

registry_capability_shape_ok() {
  [[ "${1:-}" =~ ^cap_[0-9a-f]{64}$ ]]
}

# exchange_registry_credential — trades the capability for ONE short-lived
# dockerconfigjson, and leaves it in REGISTRY_DOCKERCONFIGJSON (base64, the
# form a Secret's .dockerconfigjson takes) plus its lifetime. Refuses — never
# returns — on any failure, so no caller can accidentally continue without a
# credential.
#
# ONE curl call, because the capability is single-use: a second call is not a
# retry, it is a spent token. The status code is read off a trailing `-w`
# line rather than with `-f`, because a refusal we cannot see is a refusal we
# cannot name the fix for.
exchange_registry_credential() {
  if [ -z "$KIT_SUBSTRATE_BOX_ID" ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_BOX_ID" "export KIT_SUBSTRATE_BOX_ID='<the enrolled uuid of this box>' and re-run — the box's own identity, and what the registry capability is bound to" "KIT_SUBSTRATE_BOX_ID is not set
  export KIT_SUBSTRATE_BOX_ID='<the enrolled uuid of this box>'
  # the box's own identity, and what the registry capability is bound to"
  fi
  if ! registry_capability_shape_ok "$KIT_SUBSTRATE_REGISTRY_CAPABILITY"; then
    kit_substrate_refuse "KIT_SUBSTRATE_REGISTRY_CAPABILITY" "re-run 'caf box enroll' and pass the capability it prints — a dockerconfigjson belongs in the OLD runbook: it is exchanged, not pasted" "KIT_SUBSTRATE_REGISTRY_CAPABILITY is not a minted capability
  export KIT_SUBSTRATE_REGISTRY_CAPABILITY='<cap_… from caf box enroll>'
  # a dockerconfigjson belongs in the OLD runbook: it is exchanged, not pasted"
  fi
  local raw http_status body encoded expires seconds
  # `curl -sS -w` appends the status on its own line after the body, so both
  # arrive in one call and the credential is never re-requested.
  raw="$(curl -sS -X POST \
    -H "Authorization: Bearer ${KIT_SUBSTRATE_REGISTRY_CAPABILITY}" \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg box_id "$KIT_SUBSTRATE_BOX_ID" '{box_id: $box_id}')" \
    -w '\n%{http_code}' \
    "${KIT_SUBSTRATE_REGISTRY_URL}/v1/registry-credentials" 2>/dev/null)" || raw=""
  if [ -z "$raw" ]; then
    kit_substrate_refuse "" "check that the registry exchange is reachable at ${KIT_SUBSTRATE_REGISTRY_URL} and re-run 'caf box enroll' (the capability lives minutes)" "the registry exchange did not answer — the capability was not spent
  check ${KIT_SUBSTRATE_REGISTRY_URL} is reachable, and re-run 'caf box enroll' for a fresh capability"
  fi
  http_status="$(printf '%s' "$raw" | tail -n 1)"
  body="$(printf '%s' "$raw" | sed '$d')"
  # A refusal arrives with box's own code, passed through by the exchange:
  # capability_expired (410), capability_redeemed (409), capability_wrong_box
  # or _purpose (403). Each is a statement about the capability, and the next
  # step is always a fresh one from 'caf box enroll' — never another value.
  case "$http_status" in
    2*) ;;
    *)
      local refusal_code refusal_message upstream_status
      refusal_code="$(printf '%s' "$body" | jq -r '.error.code // empty' 2>/dev/null || true)"
      refusal_message="$(printf '%s' "$body" | jq -r '.error.message // empty' 2>/dev/null || true)"
      upstream_status="${refusal_code:-unspecified}"
      kit_substrate_refuse "KIT_SUBSTRATE_REGISTRY_CAPABILITY" "re-run 'caf box enroll' and pass the capability it prints (it lives minutes) — the exchange refused it with ${upstream_status}" "the registry exchange refused this box's capability (${upstream_status})
  ${refusal_message:-no reason given}
  re-run 'caf box enroll' and pass the capability it prints (it lives minutes)"
      ;;
  esac
  encoded="$(printf '%s' "$body" | jq -r '.dockerconfigjson // empty' 2>/dev/null || true)"
  expires="$(printf '%s' "$body" | jq -r '.expires_at // empty' 2>/dev/null || true)"
  seconds="$(printf '%s' "$body" | jq -r '.seconds_remaining // empty' 2>/dev/null || true)"
  # The product is the base64 dockerconfigjson (seam audit §5c: the old
  # consumer decoded the body AS the credential, which is why a re-pointed URL
  # failed the base64 check even where a route existed). It is read out of the
  # JSON now, and checked for shape: it decodes to a JSON `auths` entry for
  # the fleet's registry, or something is wrong in a way this installer can
  # name rather than discover at image-pull time.
  if [ -z "$encoded" ]; then
    kit_substrate_refuse "" "" "the registry exchange answered ${http_status} but carried no dockerconfigjson"
  fi
  if [ -z "$expires" ]; then
    kit_substrate_refuse "" "" "the registry exchange carried no expires_at for the credential it minted"
  fi
  if ! printf '%s' "$encoded" | base64 -d 2>/dev/null | jq -e '.auths["ghcr.io"].username' >/dev/null 2>&1; then
    kit_substrate_refuse "" "" "the dockerconfigjson the registry exchange returned is not a ghcr.io credential — refused rather than written"
  fi
  # The lifetime is measured, not asserted by the exchange's own word: a
  # credential with less than a minute left is a Secret that expires while
  # pods are being scheduled.
  if ! [[ "$seconds" =~ ^[0-9]+$ ]] || [ "$seconds" -lt "$REGISTRY_CREDENTIAL_MIN_SECONDS" ]; then
    kit_substrate_refuse "" "re-run this installer — the exchange mints a fresh credential with a full hour of life" "the minted credential has ${seconds:-no} seconds of life left (less than ${REGISTRY_CREDENTIAL_MIN_SECONDS})
  a credential that expires mid-pull fails at image-pull time"
  fi
  if [ -n "$expires" ] && [[ ! "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
    kit_substrate_refuse "" "" "the minted credential's expires_at '${expires}' is not an instant this installer can read"
  fi
  # And an instant that is already behind us is a credential that died before
  # it arrived. Compared as a string, because identical-format UTC timestamps
  # order lexicographically the way they order chronologically.
  if [ -n "$expires" ] && [ "${#expires}" -eq 20 ] && [[ "$expires" < "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]]; then
    kit_substrate_refuse "" "re-run this installer — the exchange mints a fresh credential" "the minted credential's expires_at '${expires}' is already past"
  fi
  REGISTRY_DOCKERCONFIGJSON="$encoded"
}

# apply_pull_secret — writes the credential as a docker-registry Secret in each
# namespace that pulls the fleet's images, making the namespace first.
#
# WHY IT MAKES THE NAMESPACE: the argument is at the code site, because it is
# the ordering decision this step owns. In one line — the secret has to exist
# before the first pod that pulls with it is scheduled, and on a wiped box five
# of those six namespaces do not exist until step 6's Applications create them.
#
# THE VALUE NEVER ENTERS ARGV. It travels from curl's response into a shell
# variable, then into the Secret through `/dev/stdin` in a pipe: `kubectl
# create ... --from-file=.dockerconfigjson=/dev/stdin --dry-run=client -o yaml
# | kubectl apply -f -`. A value in argv is visible to every process on the
# box in `ps`, to a crash reporter, and to a shell history; a value in a pipe
# is visible to neither. The Secret is then applied, so a re-run is an
# idempotent replace rather than a create that fails on the second run.
#
# THE PIPE DECODES FIRST, because the exchange returns the credential BASE64
# (its contract: the field's value is the base64 of the JSON) while
# --from-file base64-encodes the file's bytes into data[.dockerconfigjson] —
# so the DECODED bytes are what belongs in the file. Writing the encoded value
# through stores base64(base64(json)): the API server decodes once and the
# kubelet JSON-parses base64 text. Measured on the box:
#   `data[.dockerconfigjson]: Invalid value: "…": invalid character 'e'
#   looking for beginning of value`
# where 'e' is the first character of `eyJhdXRocyI6…`, the base64 of `{"auths":`.
apply_pull_secret() {
  local ns
  for ns in "${REGISTRY_PULL_NAMESPACES[@]}"; do
    # THE NAMESPACE IS MADE HERE, BEFORE THE SECRET, AND THAT IS THE WHOLE FIX.
    #
    # Measured live on a box that had been wiped, and only a wiped box could
    # have shown it: this step wrote the secret into argocd (step 4 created
    # that namespace) and then stopped with
    #   Error from server (NotFound): error when creating "STDIN":
    #   namespaces "identity" not found
    # because the other five did not exist yet — the Argo CD Applications at
    # step 6 create them, with `CreateNamespace=true`. `set -e` ended the
    # install at its second namespace, leaving a box with one namespace of the
    # six the fleet pulls with and a run that reported nothing usable.
    #
    # WHY THE SECRET IS STILL WRITTEN EARLY, AT STEP 5. It has to be. The first
    # pod that pulls a fleet image is Argo CD's own — the Application
    # controller pulls whatever the Applications sync — and everything after
    # that schedules inside a window this installer does not control. A pull
    # secret applied after the pods that need it is a CrashLoopBackOff nobody
    # can attribute to an ordering choice made three steps earlier. So the
    # credential is bought and written as early as it can be, and the missing
    # namespaces are MADE rather than waited for.
    #
    # WHY HERE AND NOT MOVED INTO STEP 6. Step 6 asks Argo to create those
    # namespaces, and Argo creates them when it syncs — a moment chosen by the
    # sync, not by a line in this file. Moving the secret there would put it
    # back inside the race it exists to prevent, and it would still be wrong
    # for argocd: nothing at step 6 creates the namespace Argo CD itself runs
    # in, because Argo CD was installed into an existing one.
    #
    # WHY IDEMPOTENT. `create --dry-run=client -o yaml | apply -f -` is this
    # repository's own idiom and it is the one the Secret itself uses two
    # screens below: a namespace that already exists is answered `unchanged`,
    # so a re-run is a no-op rather than an `AlreadyExists`. And a namespace
    # this step makes is the same instruction Argo's `CreateNamespace=true`
    # will later issue — the same object asked for twice, idempotently, which
    # is why making it here is safe rather than a conflict. The operator who
    # created these namespaces by hand on the affected box worked around
    # exactly this, and a fixed installer must produce that same state itself.
    if ! kubectl --kubeconfig="$KUBECONFIG" create namespace "$ns" --dry-run=client -o yaml |
      kubectl --kubeconfig="$KUBECONFIG" apply -f - >/dev/null; then
      # Refused, never skipped. A retry-until-it-appears loop would be waiting
      # for something nothing in this install creates; an `|| true` on the
      # apply would leave the namespace absent and the run green. Both turn a
      # hole the operator can see into one they discover at image-pull time,
      # in a voice that names neither this line nor the namespace.
      REGISTRY_DOCKERCONFIGJSON=""
      kit_substrate_refuse "" "check that the k3s cluster is reachable from this box and that no admission policy refuses namespace creation, then re-run — the pull secret cannot be written into a namespace that does not exist" "the namespace ${ns} could not be created, so the image pull secret cannot be written into it — every pod scheduled into ${ns} would fail to pull"
    fi
    if kubectl --kubeconfig="$KUBECONFIG" get secret "$REGISTRY_PULL_SECRET_NAME" -n "$ns" >/dev/null 2>&1; then
      kit_substrate_out "      secret ${REGISTRY_PULL_SECRET_NAME} exists in ${ns} — replacing it (the credential is minutes-lived by design; a fresh exchange buys a fresh one)"
    else
      kit_substrate_out "      secret ${REGISTRY_PULL_SECRET_NAME} to be created in ${ns}"
    fi
    # Never printed, never in argv, never on disk — and decoded, per above.
    printf '%s' "$REGISTRY_DOCKERCONFIGJSON" | base64 -d |
      kubectl --kubeconfig="$KUBECONFIG" create secret docker-registry "$REGISTRY_PULL_SECRET_NAME" -n "$ns"       --from-file=.dockerconfigjson=/dev/stdin --dry-run=client -o yaml |
      kubectl --kubeconfig="$KUBECONFIG" apply -f - >/dev/null
  done
  # The variable holding the credential is dropped the moment it is written.
  # Nothing after this point needs it, so nothing after this point can leak it.
  REGISTRY_DOCKERCONFIGJSON=""
}

install_pull_secret() {
  log_step "the GHCR image pull secret, exchanged for box ${KIT_SUBSTRATE_BOX_ID:-<unset>}"
  if dry_run "exchange the registry capability at ${KIT_SUBSTRATE_REGISTRY_URL}/v1/registry-credentials, ensure each of ${REGISTRY_PULL_NAMESPACES[*]} exists, and apply ${REGISTRY_PULL_SECRET_NAME} in it"; then
    return 0
  fi
  exchange_registry_credential
  apply_pull_secret
  kit_substrate_out "      pull secret applied in ${#REGISTRY_PULL_NAMESPACES[@]} namespaces (short-lived by design — a re-run exchanges a fresh capability for a fresh credential)"
}

# --- reading a manifest DIRECTORY deliberately -------------------------------
# WHAT `kubectl apply -f <dir>` ACTUALLY READS, AND THE TRANSPORT THAT BROKE ONE.
#
# `kubectl apply -f <dir>` does not read "the manifests"; it reads every regular
# file the directory holds, DOTFILES INCLUDED. A macOS workstation that shipped
# this tree with the idiom an operator will reach for —
#
#   tar czf - . | ssh box 'tar xzf -'
#
# — leaves AppleDouble sidecars beside every real file: `._install.sh`,
# `._manifests/`, and `._identity.yaml` beside each Application. BSD tar emits
# them for the resource fork / Finder metadata. The apply then handed the
# sidecar to the API server and the install DIED on the FIRST of them, measured
# live on the box:
#
#   error parsing /var/lib/cafaye/substrate/manifests/applications/._identity.yaml:
#   error converting YAML to JSON: yaml: control characters are not allowed
#
# `COPYFILE_DISABLE=1 tar --no-xattrs` reduces the sidecars but does not remove
# the class — a Windows copy, an editor's `foo.yaml~` backup, or a `.DS_Store`
# left in the directory is the same defect from another transport. So the
# installer does not apply a directory and hope: it RESOLVES THE LIST, applies
# exactly the manifests, IGNORES AppleDouble debris (and says so), and REFUSES —
# naming the file — anything else it finds, because a stray file in a manifest
# directory is either a mistake to fix or a convention to record, and silent
# skipping is the one outcome the next author cannot see.
#
# THE FILTER IS THE GLOB, NOT AN ENUMERATED ALLOWLIST. `"$dir"/*.yaml` is the
# intended set and it is read from the directory, so a manifest added or renamed
# is picked up with no second list to keep in step — a hand-written list that
# drifts from the directory is its own bug. Bash's `*` does not match a leading
# dot, which is what already keeps `._identity.yaml` out; the check below makes
# that exclusion EXPLICIT rather than incidental, and the "unexpected entries"
# half turns everything that is neither an intended `*.yaml` manifest nor
# AppleDouble debris into a loud refusal rather than a quiet skip.
KIT_MANIFEST_FILES=()

# kit_substrate_check_manifest_dir <dir> — refuse, naming it, if <dir> holds
# anything that is neither an intended `*.yaml` manifest nor AppleDouble debris.
# AppleDouble sidecars are named once, through kit_substrate_out, so the skip is
# visible rather than silent.
kit_substrate_check_manifest_dir() {
  local dir="$1" entry base
  local -a unexpected=() sidecars=()
  # Three patterns reach every entry: plain names, a leading single dot, and a
  # leading double dot. An unmatched glob stays literal, so `[ -e ]` is the
  # guard rather than a `nullglob` that would change the shell's state.
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$entry" ] || continue
    base="${entry##*/}"
    case "$base" in
      ._*)
        # AppleDouble — a transport artifact, expected wherever a macOS tar or
        # a Windows copy has been. Ignored, and named so the skip is visible.
        sidecars+=("$base")
        continue
        ;;
    esac
    if [ -f "$entry" ]; then
      case "$base" in
        *.yaml) continue ;;
      esac
    fi
    unexpected+=("$base")
  done
  if [ "${#sidecars[@]}" -gt 0 ]; then
    kit_substrate_out "      ignoring AppleDouble sidecar(s) in ${dir}: ${sidecars[*]} (macOS tar/cp debris, not manifests)"
  fi
  if [ "${#unexpected[@]}" -gt 0 ]; then
    kit_substrate_refuse "" \
      "remove it from ${dir}, or record the convention — a manifest directory holds only its *.yaml manifests" \
      "${dir} holds unexpected entries: ${unexpected[*]}"
  fi
}

# kit_substrate_manifest_files <dir> — set KIT_MANIFEST_FILES to the intended
# manifest paths under <dir>, in glob order, AppleDouble excluded, and refuse
# (never return) if the directory holds anything unexpected or no manifest at
# all. The caller reads KIT_MANIFEST_FILES rather than re-globbing, so the list
# and the check can never disagree.
kit_substrate_manifest_files() {
  local dir="$1" f
  KIT_MANIFEST_FILES=()
  kit_substrate_check_manifest_dir "$dir"
  for f in "$dir"/*.yaml; do
    [ -f "$f" ] || continue
    KIT_MANIFEST_FILES+=("$f")
  done
  if [ "${#KIT_MANIFEST_FILES[@]}" -eq 0 ]; then
    kit_substrate_refuse "" "restore ${dir}'s manifests" "${dir} holds no *.yaml manifests — refusing to apply nothing"
  fi
}

# --- step 6: the first Applications ----------------------------------------
# LOCAL manifests, so CLIENT-SIDE apply — see the note above step 2. These are
# kit's own files: small enough that the last-applied-configuration annotation
# is nowhere near Kubernetes's cap, re-applied on every run as this installer's
# convergence mechanism, and owned outright by the installer — so a re-run must
# keep its ability to reclaim the fields it set.
install_applications() {
  log_step "the first Applications (identity, gateway, courier, parlor, observability)"
  if dry_run "kubectl apply -f ${MANIFEST_DIR}"; then
    return 0
  fi
  # Resolve the directory deliberately — see the note above this function for
  # the AppleDouble failure `kubectl apply -f <dir>` used to cause.
  kit_substrate_manifest_files "$MANIFEST_DIR"
  local -a apply_args=()
  local f
  for f in "${KIT_MANIFEST_FILES[@]}"; do apply_args+=(-f "$f"); done
  kubectl --kubeconfig="$KUBECONFIG" apply "${apply_args[@]}"
  # No wait here, and the reason is a property of the install variant rather
  # than of forgetfulness. The wait that used to close this step named
  # argocd-server, which core-install does not ship — the core variant has no
  # API server, no UI and no dex — so it answered NotFound on every run and
  # killed the install at step 6. It is deleted rather than repointed, because
  # every object it could be repointed at is either already waited on or
  # unwatchable. Step 4's `wait --for=condition=Available deployment -n argocd
  # --all` holds until every Deployment core-install ships is Available, and
  # the only one of those these Applications depend on is argocd-repo-server,
  # which pulls their charts. The reconciler — argocd-application-controller,
  # a StatefulSet — publishes no status conditions, so
  # `kubectl wait --for=condition=Available` has nothing to watch and would
  # time out and fail the same way. It is level-triggered: Applications
  # applied before it is up are reconciled when it comes up, and the real
  # "Argo reconciled" signal is step 12's rollout watch on deployment/identity.
}

# --- step 7: the Let's Encrypt ClusterIssuers --------------------------------
# Two issuers — staging and production — identical but for the ACME directory
# URL. The email comes from the environment, is validated by shape, and is
# substituted into the manifests in a pipe: never written to disk, never
# printed. The email is not a secret, but the step prints what it did, not
# the value it did it with.
install_cluster_issuers() {
  log_step "the Let's Encrypt ClusterIssuers (staging + prod, from KIT_SUBSTRATE_ACME_EMAIL)"
  if kit_substrate_guard clusterissuer; then
    kit_substrate_out "      already installed, skipping"
    return 0
  fi
  if dry_run "substitute the ACME email and apply ${TLS_DIR} (letsencrypt-staging, letsencrypt-prod)"; then
    return 0
  fi
  if [ -z "$KIT_SUBSTRATE_ACME_EMAIL" ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_ACME_EMAIL" \
      "export KIT_SUBSTRATE_ACME_EMAIL='<your-address@example.com>' on the box and re-run" \
      "KIT_SUBSTRATE_ACME_EMAIL is not set"
  fi
  # Shape check without echoing the value: exactly one `@`, with something on
  # either side, and not one of the domains Let's Encrypt documents as
  # placeholders. A refused registration reads as a network error from the
  # customer's side; catch it here where the message can say what is wrong.
  # The count is the whole test: `%%@*` splits at the LAST `@`, so a second
  # `@` in the local part is invisible to the split and must be counted.
  local ats local_part domain_part
  ats="${KIT_SUBSTRATE_ACME_EMAIL//[^@]/}"
  local_part="${KIT_SUBSTRATE_ACME_EMAIL%%@*}"
  domain_part="${KIT_SUBSTRATE_ACME_EMAIL##*@}"
  if [ "${#ats}" -ne 1 ] || [ -z "$local_part" ] || [ -z "$domain_part" ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_ACME_EMAIL" \
      "export KIT_SUBSTRATE_ACME_EMAIL='<your-address@example.com>' on the box and re-run" \
      "KIT_SUBSTRATE_ACME_EMAIL must be an email address — exactly one '@', with something on either side"
  fi
  case "$domain_part" in
    example.com | example.org | example.net)
      kit_substrate_refuse "KIT_SUBSTRATE_ACME_EMAIL" \
        "export KIT_SUBSTRATE_ACME_EMAIL='<your-address@example.com>' on the box and re-run" \
        "KIT_SUBSTRATE_ACME_EMAIL is a $domain_part address — it must be real; Let's Encrypt sends expiry notices to it"
      ;;
  esac
  # The placeholder is substituted in a pipe, never with `sed -i`: the value
  # reaches the API server and is never written to disk, so no copy of the
  # operator's address is left in a file on this box.
  #
  # CLIENT-SIDE apply, deliberately: a LOCAL manifest (see the note above step
  # 2) — two small ClusterIssuers, re-applied on every run, and owned by this
  # installer.
  #
  # THE FILE LIST IS RESOLVED, NOT A BARE GLOB. `"$TLS_DIR"/*.yaml` happens to
  # exclude AppleDouble already (bash's `*` skips a leading dot), but the
  # exclusion is left to be incidental here for one directory and explicit in
  # the helper for another — so this site names the same deliberate list the
  # applications step does, and a stray file in `manifests/tls/` is refused
  # rather than quietly not applied. See the note above install_applications.
  kit_substrate_manifest_files "$TLS_DIR"
  sed "s/ACME_EMAIL_PLACEHOLDER/$KIT_SUBSTRATE_ACME_EMAIL/" "${KIT_MANIFEST_FILES[@]}" |
    kubectl --kubeconfig="$KUBECONFIG" apply -f -
  kit_substrate_out "      applied letsencrypt-staging and letsencrypt-prod"
}

# --- the per-role password secrets step 8 makes -------------------------------
# One secret per ROLE, not per service: a service's owner role and its app role
# carry different passwords, and the Cluster names each role's own secret in
# `passwordSecret`. Each secret holds `username` and `password`.
#
# THE `username` KEY IS THE ROLE'S NAME, NOT THE SECRET'S, AND THAT DISTINCTION
# IS THE WHOLE POINT OF THIS FUNCTION. CNPG's managed-role reconciler refuses to
# set a role's password when the `username` in its passwordSecret does not match
# the role's name. It does not fail the step, surface an event on the Cluster,
# or refuse the apply — it records the refusal in the Cluster's
# `status.managedRolesStatus.cannotReconcile` and moves on, leaving
# `pg_authid.rolpassword` NULL for that role. Measured on the live box:
#
#   cannotReconcile:
#     identity_app:
#     - the username in secret "postgres-role-identity-app" does not match
#       role "identity_app"
#
# while `pg_authid` held a SCRAM verifier for `identity` and NULL for
# `identity_app`, and every pod connecting as `identity_app` got
# `FATAL: password authentication failed for user "identity_app" (SQLSTATE 28P01)`.
#
# The secret is named for the SERVICE (`postgres-role-identity-app`, hyphen),
# but the ROLE is `identity_app` (underscore) — so writing the secret's suffix
# into `username` silently disabled the reconcile for all four app roles while
# the owner roles (whose secret name and role name are both `<svc>`) reconciled
# fine. So the value written here is `$role`, computed independently of
# `$secret_name` rather than derived from the `-app` suffix that names the
# secret. `tests/substrate_test.sh` asserts the two agree with the Cluster
# manifest, per role, and that a drift on either side goes red.
#
# A RE-RUN KEEPS THE PASSWORD AND REPAIRS THE USERNAME. Regenerating the
# password under a running pod is a login that breaks between two runs, so the
# stored value is read back, never remade. But the `username` key on a box
# installed by the buggy spelling is wrong, and a repair the operator has to
# remember by hand is a repair that does not happen — so an existing secret is
# merge-patched with the correct `username`. CNPG watches the Secret and
# re-reconciles, which is what heals an already-installed box: this side wins,
# because the role's password is DERIVED from the secret, and the password it
# derives is the very value `identity-secrets`' DATABASE_URL already carries.
# The call site in `install_postgres_cluster` sits ABOVE that step's `cluster`
# guard precisely so this runs on a re-run: the guard skips the re-provision,
# and the reconcile is not part of the re-provision.
create_postgres_role_secrets() {
  local svc role secret_name pw
  for svc in identity gateway courier parlor; do
    for role in "$svc" "${svc}_app"; do
      # The secret name wears the service's spelling (`-app`); the username
      # key must wear the ROLE's (`_app`). The mapping is explicit so the two
      # cannot drift together by accident again.
      case "$role" in
        *_app) secret_name="postgres-role-$svc-app" ;;
        *) secret_name="postgres-role-$svc" ;;
      esac
      if kubectl --kubeconfig="$KUBECONFIG" get secret "$secret_name" -n data >/dev/null 2>&1; then
        # Keep the password (never regenerated, never printed); correct the
        # username if an older run wrote the secret's spelling instead of the
        # role's. A merge patch of the same value is a no-op, so this is safe
        # to run on every pass. The patch is read from `/dev/stdin`, the file
        # the heredoc arrives on: kubectl has no `-` convention for
        # `--patch-file`, and `--patch-file=-` opens a file literally named `-`
        # ("error: unable to read patch file: open -: no such file or
        # directory"), which is the live defect this uses /dev/stdin to avoid.
        kubectl --kubeconfig="$KUBECONFIG" -n data patch secret "$secret_name" \
          --type=merge --patch-file=/dev/stdin >/dev/null <<JSON
{"stringData":{"username":"$role"}}
JSON
        kit_substrate_out "      secret $secret_name exists, keeping its password (never regenerated, never printed)"
      else
        pw="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        kubectl --kubeconfig="$KUBECONFIG" create secret generic "$secret_name" -n data \
          --from-literal=username="$role" --from-literal=password="$pw" >/dev/null
        kit_substrate_out "      secret $secret_name created (generated once — a re-run reads it back)"
      fi
    done
  done
}

# --- step 8: the Postgres Cluster -------------------------------------------
# The two bounds below are this step's own 600s, split the way step 1's are:
# 60s for the CNPG operator to create a pod the selector can see, then Ready
# inside what is left. Overridable so the suite can shorten the first half.
: "${CNPG_POD_TIMEOUT:=60}"
: "${CNPG_POD_READY_TIMEOUT:=540}"
# One CNPG Cluster in the `data` namespace, reproducing the local contract
# (templates/compose/postgres/initdb/10-cluster.sh) through CNPG's bootstrap
# plus managed roles — see manifests/data/postgres-cluster.yaml's header for
# which half holds what and why.
#
# THE REFUSAL RUNS BEFORE THE DRY_RUN EARLY-RETURN, and the inversion is
# deliberate: steps 5 and 7 print their plan unvalidated in DRY_RUN, but this
# step's whole contract is that an empty KIT_SUBSTRATE_DATABASES is refused
# with the fix named — and the gate asserts that refusal happens in DRY_RUN.
# A dry run that printed a plan for an empty database list would be a plan
# for a cluster with no databases in it.
install_postgres_cluster() {
  log_step "the Postgres Cluster (from KIT_SUBSTRATE_DATABASES, in the data namespace)"
  if [ -z "$KIT_SUBSTRATE_DATABASES" ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_DATABASES" \
      "export KIT_SUBSTRATE_DATABASES='identity,gateway,courier,parlor' on the box and re-run" \
      "KIT_SUBSTRATE_DATABASES is not set"
  fi
  # The manifest is the contract and the variable is the operator confirming
  # it: every name must be a service the manifest provisions, and every
  # provisioned service must be named. A typo here ("identty") would otherwise
  # boot a cluster missing a service while every DATABASE_URL pointed at it.
  local want have
  want="$(grep -oE 'CREATE DATABASE "[a-z_]+"' "$DATA_DIR/postgres-cluster.yaml" | sed -E 's/.*"(.*)"/\1/' | sort -u | tr '\n' ',' )"
  have="$(printf '%s' "$KIT_SUBSTRATE_DATABASES" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | sort -u | tr '\n' ',')"
  if [ -z "$have" ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_DATABASES" \
      "export KIT_SUBSTRATE_DATABASES='identity,gateway,courier,parlor' on the box and re-run" \
      "KIT_SUBSTRATE_DATABASES names no services (empty after trimming)"
  fi
  if [ "$want" != "$have" ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_DATABASES" \
      "export KIT_SUBSTRATE_DATABASES='identity,gateway,courier,parlor' on the box and re-run — it must equal the service set manifests/data/postgres-cluster.yaml provisions" \
      "KIT_SUBSTRATE_DATABASES does not match the Cluster manifest (it provisions: ${want%,})"
  fi
  # The extension list is declared (default: vector, mirroring compose) and
  # validated here, even though no CNPG hook can create it per database (see
  # the manifest header): an invalid name must fail here with its own message,
  # not surface later as a database error. Same identifier rule as
  # 10-cluster.sh's require_identifier; LC_ALL=C scoped to the grep, because
  # bracket ranges are collation-dependent (10-cluster.sh:78-110).
  local ext ext_list
  IFS=',' read -r -a ext_list <<<"$KIT_SUBSTRATE_POSTGRES_EXTENSIONS"
  for ext in "${ext_list[@]}"; do
    if ! printf '%s' "$ext" | LC_ALL=C grep -q '^[a-z_][a-z0-9_]*$'; then
      kit_substrate_refuse "KIT_SUBSTRATE_POSTGRES_EXTENSIONS" \
        "export KIT_SUBSTRATE_POSTGRES_EXTENSIONS='vector' on the box and re-run" \
        "'$ext' in KIT_SUBSTRATE_POSTGRES_EXTENSIONS is not a bare identifier ([a-z_][a-z0-9_]*)"
    fi
  done
  if dry_run "create namespace data, create 8 postgres-role-* password secrets (generated once), apply ${DATA_DIR}/postgres-cluster.yaml"; then
    return 0
  fi
  # The namespace first, because the role secrets below live in it. Idempotent
  # (`create --dry-run=client | apply`): the same write on a fresh box, a no-op
  # on a re-run.
  kubectl --kubeconfig="$KUBECONFIG" create namespace data --dry-run=client -o yaml |
    kubectl --kubeconfig="$KUBECONFIG" apply -f -
  # THE ROLE SECRETS ARE RECONCILED ON EVERY RUN, INCLUDING A RE-RUN THAT
  # SKIPS THE APPLY BELOW — which is why this call sits ABOVE the `cluster`
  # guard and not below it. The guard's contract is "the Cluster exists, do not
  # re-provision"; but a box installed with the broken `username` spelling is a
  # box whose Cluster exists, so a repair behind the guard is a repair that
  # never runs on the only box that needs it. `create_postgres_role_secrets`
  # keeps every stored password and only corrects the `username` key, so
  # running it on a healthy re-run is a no-op merge patch.
  create_postgres_role_secrets
  if kit_substrate_guard cluster; then
    kit_substrate_out "      already installed, skipping"
    return 0
  fi
  # LOCAL manifest, CLIENT-SIDE apply (the note above step 2 holds): small,
  # re-applied on every run, and owned by this installer — which is exactly why
  # the mode takes the re-run's ability to reclaim a field away on the remote
  # manifests and leaves it intact here.
  #
  # The file below is applied BY NAME, so its list is deliberate by
  # construction; the check is over the DIRECTORY, so a stray file shipped
  # beside it (AppleDouble ignored, anything else refused by name) is surfaced
  # rather than silently ignored. See the note above install_applications.
  kit_substrate_check_manifest_dir "$DATA_DIR"
  kubectl --kubeconfig="$KUBECONFIG" apply -f "$DATA_DIR/postgres-cluster.yaml"
  # The pods, not the Cluster phase: pod Ready means the instance passed its
  # readiness probe, which is the observable property the services need. A
  # phase-string wait encodes a CNPG status vocabulary this script does not
  # own; a label-selected pod wait encodes the contract.
  #
  # TWO WAITS, AND THIS ONE WAS ALWAYS RACY. The Cluster CR is applied
  # SYNCHRONOUSLY above, but its pods are created ASYNCHRONOUSLY by the CNPG
  # operator, which has to notice the CR, reconcile it and schedule the
  # instance — so the selector below can match ZERO pods the instant the apply
  # returns, and `kubectl wait -l cnpg.io/cluster=postgres` on an empty list is
  # the same error step 1 hit, on an object owned by a different controller.
  # It is not the object this step applied, so existence is proved first here
  # too: 60s for the operator to make a pod, then Ready inside the 600s this
  # step always had.
  kit_substrate_await_list "$CNPG_POD_TIMEOUT" pod -l cnpg.io/cluster=postgres -n data
  kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Ready pod -l cnpg.io/cluster=postgres -n data --timeout="$((CNPG_POD_READY_TIMEOUT))s"
}

# --- step 9: Redis and the services' secrets ----------------------------------
# One step, two guarded halves. Redis (one Deployment + Service + PVC in
# `data`: an accessory, not a product — no sentinel, no cluster) must exist
# before the secrets half runs, because `gateway-secrets`' REDIS_URL is built
# from the `redis-password` secret — and the secrets half has its own guard,
# so a half-finished step 9 resumes the secrets without touching Redis.
install_redis_and_secrets() {
  log_step "Redis (single instance) and the services' secrets (identity, gateway, courier, parlor)"
  if kit_substrate_guard redis; then
    kit_substrate_out "      already installed, skipping"
  elif dry_run "create secret redis-password (generated once) and apply ${DATA_DIR}/redis.yaml"; then
    :
  else
    if ! kubectl --kubeconfig="$KUBECONFIG" get secret redis-password -n data >/dev/null 2>&1; then
      kubectl --kubeconfig="$KUBECONFIG" create secret generic redis-password -n data \
        --from-literal=password="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')" >/dev/null
      kit_substrate_out "      secret redis-password created (generated once — a re-run reads it back)"
    else
      kit_substrate_out "      secret redis-password exists, keeping its password (never regenerated, never printed)"
    fi
    # LOCAL manifest, CLIENT-SIDE apply (the note above step 2 holds). Applied
    # by name, so the file is deliberate; the directory is checked so a stray
    # file beside it is surfaced rather than skipped (see install_applications).
    kit_substrate_check_manifest_dir "$DATA_DIR"
    kubectl --kubeconfig="$KUBECONFIG" apply -f "$DATA_DIR/redis.yaml"
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment redis -n data --timeout=180s
  fi
  install_service_secrets
}

# --- helpers for the secrets half of step 9 ------------------------------------
# read_secret_key <namespace> <secret> <key> — the stored value, or empty.
# Never prints; the caller decides what to do with an absence. A missing
# SECRET is empty (first run); a present secret with a missing KEY is also
# empty (an older run wrote fewer keys) — both mean "generate or refuse",
# never "crash on jsonpath".
read_secret_key() {
  kubectl --kubeconfig="$KUBECONFIG" get secret "$2" -n "$1" -o jsonpath="{.data.$3}" 2>/dev/null |
    base64 -d 2>/dev/null || true
}

# database_url_for <service> — the service's runtime DSN. The role is the
# LOGIN the application uses (`<svc>_app`, which owns nothing), and the
# password is read back from the role secret step 8 made; a missing role
# secret is a refusal naming step 8, not an empty password in a URL.
# postgres-rw is CNPG's read-write service for the Cluster named `postgres`.
# The scheme is per service, exactly as each service's own compose file
# writes it: identity uses postgres://…?sslmode=disable, courier uses
# ecto:// (its runtime.exs names that spelling in the missing-variable
# error), parlor is provisioned-but-unread so it takes the postgres form.
database_url_for() {
  local pw
  pw="$(read_secret_key data "postgres-role-$1-app" password)"
  if [ -z "$pw" ]; then
    # Not a refusal about an operator input — the step that makes the role
    # secret has not run — so `input_needed` names the step rather than a
    # variable, and `human` says which one to run.
    kit_substrate_refuse "run step 8 (the Postgres Cluster) first" \
      "re-run 'caf box apply --phase 8' on the box, then this step" \
      "secret postgres-role-$1-app is missing in namespace data"
  fi
  if [ "$1" = "courier" ]; then
    printf 'ecto://%s_app:%s@postgres-rw.data.svc.cluster.local:5432/%s' "$1" "$pw" "$1"
  else
    printf 'postgres://%s_app:%s@postgres-rw.data.svc.cluster.local:5432/%s?sslmode=disable' "$1" "$pw" "$1"
  fi
}

# owner_database_url_for <service> — the OWNER DSN, for MIGRATIONS ONLY.
#
# WHY A MIGRATION IS NOT THE APP'S CONNECTION. `database_url_for` above names
# `<svc>_app`, the LOGIN the service runs as, which owns nothing and — measured
# against the Cluster manifest — holds no DDL privilege. A migration is DDL: the
# first `CREATE TABLE` would fail `permission denied for schema public`, from a
# step whose job is to create the schema. So the migrate Job connects as the
# OWNER (`postgres-role-<svc>`, the role step 8 provisions and the migration
# tool records its version table under), and the service keeps connecting as
# `<svc>_app`. The roles are the SAME database; only the credential differs, and
# picking the credential is exactly what this function is for. courier's
# `Courier.Release.migrate` says the same thing in its moduledoc.
#
# The scheme is per service, the same distinction `database_url_for` states.
owner_database_url_for() {
  local pw
  pw="$(read_secret_key data "postgres-role-$1" password)"
  if [ -z "$pw" ]; then
    kit_substrate_refuse "run step 8 (the Postgres Cluster) first" \
      "re-run 'caf box apply --phase 8' on the box, then this step" \
      "secret postgres-role-$1 is missing in namespace data"
  fi
  if [ "$1" = "courier" ]; then
    printf 'ecto://%s:%s@postgres-rw.data.svc.cluster.local:5432/%s' "$1" "$pw" "$1"
  else
    printf 'postgres://%s:%s@postgres-rw.data.svc.cluster.local:5432/%s?sslmode=disable' "$1" "$pw" "$1"
  fi
}

# --- identity's OIDC signing key, born on this box ---------------------------
# ONE key, generated here, read back once-only, never printed.
#
# It used to be an operator input (KIT_SUBSTRATE_IDENTITY_OIDC_SIGNING_KEY /
# _ID), which made identity's private RSA key a value in a shell history and a
# transcript. It is the CUSTOMER's key: it signs the tokens their users hold,
# and a key that has been through somebody else's terminal is not theirs. So it
# is generated on the box, stored in identity-secrets, and — exactly like
# SIGNUP_SIGNING_KEY and MFA_ENCRYPTION_KEY — never regenerated on a re-run,
# because gateway caches JWKS entries by `kid` and a service that signs with a
# new key every boot is a service nobody can verify.
#
# The id is DERIVED FROM THE KEY rather than invented: it is a public
# thumbprint (16 hex of the key's SHA-256), so it is stable for as long as the
# key is, and a cached verifier's `kid` keeps matching. It also means no clock,
# no counter, and nothing to get out of step on a re-run.
#
# RSA at 2048 is the floor: identity refuses a shorter key at boot
# (MinKeyBits), and a published JWKS is a durable commitment.
oidc_key_id_for() {
  printf 'box-%s' "$(printf '%s' "$1" | openssl dgst -sha256 -hex | sed 's/^.*= *//' | cut -c1-16)"
}

# resolve_oidc_signing_key — sets OIDC_SIGNING_KEY / OIDC_SIGNING_KEY_ID.
# Called on the LIVE path, and only when the surface is wired (the issuer is
# set): identity's OIDC config is all-or-nothing — an issuer without a key is a
# boot refusal, and a key without an issuer is the same refusal, so a half
# answer is not an answer.
resolve_oidc_signing_key() {
  local stored
  stored="$(read_secret_key identity identity-secrets OIDC_SIGNING_KEY)"
  if [ -n "$stored" ]; then
    OIDC_SIGNING_KEY="$stored"
    stored="$(read_secret_key identity identity-secrets OIDC_SIGNING_KEY_ID)"
    # A stored key with no stored id (a legacy secret, or a key id an operator
    # removed) gets the id the key itself implies, not a fresh one.
    if [ -n "$stored" ]; then
      OIDC_SIGNING_KEY_ID="$stored"
    else
      OIDC_SIGNING_KEY_ID="$(oidc_key_id_for "$OIDC_SIGNING_KEY")"
    fi
    return 0
  fi
  OIDC_SIGNING_KEY="$(openssl genrsa 2048 2>/dev/null)" || {
    echo "error: openssl could not generate identity's OIDC signing key on this box" >&2
    exit 1
  }
  OIDC_SIGNING_KEY_ID="$(oidc_key_id_for "$OIDC_SIGNING_KEY")"
}

# --- gateway's assertion signing key, born on this box ----------------------
# The chart MOUNTS this key as a file: `volumes.secret.secretName` is
# gateway-secrets and `items` pins `ASSERTION_SIGNING_KEY` to `signing.pem`,
# the path `ASSERTION_SIGNING_KEY_FILE` names. A required volume item is a hard
# reference — a secret that lacks the key leaves the pod in ContainerCreating
# forever (`FailedMount … references non-existent secret key`), a failure
# nobody attributes to a missing generator.
#
# It is GENERATED ON THE BOX and never an input, like identity's OIDC key: it is
# the customer's assertion key, the private half of what its verifier holds. It
# is a PKCS#8 RSA-2048 PEM because that is what gateway parses —
# `x509.ParsePKCS8PrivateKey` (internal/httpapi/assertion.go) — so
# `openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048` is the spelling
# and `openssl genrsa` (PKCS#1) would be refused at startup. The public half
# goes to the verifier out of band.
#
# resolve_gateway_assertion_key sets ASSERTION_SIGNING_KEY to the stored value
# or a freshly generated one. Never prints.
resolve_gateway_assertion_key() {
  ASSERTION_SIGNING_KEY="$(read_secret_key gateway gateway-secrets ASSERTION_SIGNING_KEY)"
  if [ -n "$ASSERTION_SIGNING_KEY" ]; then
    return 0
  fi
  ASSERTION_SIGNING_KEY="$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)" || {
    echo "error: openssl could not generate gateway's assertion signing key on this box" >&2
    exit 1
  }
}

# reconcile_gateway_assertion_key — add ASSERTION_SIGNING_KEY to a
# gateway-secrets that predates it.
#
# WHY IT RUNS ABOVE THE `secrets` GUARD: on the box this repair exists for, all
# four service secrets are present, so the guard skips install_service_secrets
# whole — and the gateway-secrets that is present is exactly the one missing the
# key the chart mounts. A repair behind the guard never runs on the only box
# that needs it. Unlike MFA_ENCRYPTION_KEY, an absent assertion key has no
# ciphertext to fork (gateway never booted, because the mount never resolved),
# so generating one heals the box; a stored key is read back, never rotated.
reconcile_gateway_assertion_key() {
  local stored
  stored="$(read_secret_key gateway gateway-secrets ASSERTION_SIGNING_KEY)"
  if [ -n "$stored" ]; then
    return 0
  fi
  # No secret yet means the create path below writes the key; only a PRESENT
  # secret without the key is this repair's business.
  if ! kubectl --kubeconfig="$KUBECONFIG" get secret gateway-secrets -n gateway >/dev/null 2>&1; then
    return 0
  fi
  resolve_gateway_assertion_key
  # A merge patch, built by jq so a PEM's newlines survive: a whole-Secret apply
  # would drop REDIS_URL. `read_secret_key` would return the same bytes on a
  # later run, so the patch is idempotent. Read from `/dev/stdin`, not `-`:
  # kubectl has no `-` convention for `--patch-file` (it opens a file named
  # `-`), and every other patch in this file uses the same door.
  printf '%s' "$(jq -nc --arg k "$ASSERTION_SIGNING_KEY" '{"stringData":{"ASSERTION_SIGNING_KEY":$k}}')" |
    kubectl --kubeconfig="$KUBECONFIG" -n gateway patch secret gateway-secrets --type=merge --patch-file=/dev/stdin >/dev/null
  kit_substrate_out "      secret gateway-secrets existed without ASSERTION_SIGNING_KEY — patched it in (gateway's pod mounts this key; without it the mount never resolves)"
}

# validate_oidc_login_ui_url — the login UI URL, when set, must be what
# identity's oidc.ValidateLoginUIURL accepts: an http(s) URL with a host,
# no query, no fragment and no userinfo. A refused value names the VARIABLE,
# never the value. Unset means no OIDC surface. Called on the LIVE path only,
# beside the other externally-sourced validations — a dry run is a plan and
# does not need the URL to print it.
validate_oidc_login_ui_url() {
  if [ -z "$KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" ]; then
    return 0
  fi
  local url="$KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL"
  local why=""
  case "$url" in
    http://* | https://*) ;;
    *)
      why="its scheme is not http or https"
      ;;
  esac
  if [ -z "$why" ]; then
    local hostpart="${url#*://}"
    case "$hostpart" in
      "" | "/"* | "?"* | "#"* | "@"*)
        why="it has no host, so there is nowhere to send a browser"
        ;;
    esac
  fi
  if [ -z "$why" ]; then
    case "$url" in
      *\?*)
        why="it carries a query"
        ;;
    esac
  fi
  if [ -z "$why" ]; then
    case "$url" in
      *\#*)
        why="it carries a fragment, which is not sent to a server"
        ;;
    esac
  fi
  if [ -z "$why" ]; then
    local without_scheme="${url#*://}"
    local host_and_rest="${without_scheme%%/*}"
    host_and_rest="${host_and_rest%%\?*}"
    host_and_rest="${host_and_rest%%\#*}"
    case "$host_and_rest" in
      *@*)
        why="it has a userinfo section, so the host in it is not the host it resolves to"
        ;;
    esac
  fi
  if [ -n "$why" ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" \
      "export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL='https://app.example.com/sign-in/oidc' — an http(s) URL with a host, no query, no fragment and no userinfo — and re-run" \
      "KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL $why"
  fi
}

# validate_oidc_all_or_nothing — the OIDC surface is four keys or none.
# identity's loader counts issuer/key/id and then requires the login UI; a
# lone issuer or a lone login UI is a boot refusal discovered three steps
# later. The installer refuses before writing anything, naming the missing
# variable. Called on the LIVE path only.
validate_oidc_all_or_nothing() {
  local has_issuer has_login
  has_issuer=0; [ -n "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ] && has_issuer=1
  has_login=0; [ -n "$KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" ] && has_login=1
  if [ "$has_issuer" -eq 1 ] && [ "$has_login" -eq 0 ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" \
      "export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL='https://app.example.com/sign-in/oidc' — the page that asks a person for their password — and re-run" \
      "KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER is set but KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL is not — the OIDC surface is all-or-nothing (issuer + signing key + id + login UI, or none of them)"
  fi
  if [ "$has_issuer" -eq 0 ] && [ "$has_login" -eq 1 ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" \
      "export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='https://auth.example.com' — the URL identity publishes as its issuer — and re-run, or leave both unset for no OIDC surface" \
      "KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL is set but KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER is not — the OIDC surface is all-or-nothing (issuer + signing key + id + login UI, or none of them)"
  fi
  if [ "$has_login" -eq 1 ]; then
    validate_oidc_login_ui_url
  fi
}

# reconcile_oidc_identity_secrets — patch a pre-existing identity-secrets that
# predates the login UI surface (or the whole OIDC surface) with the four keys
# the operator's input now supplies. Runs ABOVE the `secrets` guard, on
# purpose: a box installed before this packet holds all four service secrets, so
# the guard would skip the step whole and leave identity CrashLoopBackOff on a
# secret missing OIDC_LOGIN_UI_URL. A stored signing key is read back, never
# rotated — the same once-only rule as SIGNUP_SIGNING_KEY — so a re-run keeps
# the key its verifiers cached.
reconcile_oidc_identity_secrets() {
  if [ -z "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ] || [ -z "$KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" ]; then
    return 0
  fi
  if ! kubectl --kubeconfig="$KUBECONFIG" get secret identity-secrets -n identity >/dev/null 2>&1; then
    return 0
  fi
  local stored_issuer stored_login
  stored_issuer="$(read_secret_key identity identity-secrets OIDC_ISSUER)"
  stored_login="$(read_secret_key identity identity-secrets OIDC_LOGIN_UI_URL)"
  if [ -n "$stored_issuer" ] && [ -n "$stored_login" ]; then
    return 0
  fi
  resolve_oidc_signing_key
  local oidc_key="$OIDC_SIGNING_KEY" oidc_key_id="$OIDC_SIGNING_KEY_ID"
  printf '%s' "$(jq -nc --arg issuer "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" --arg key "$oidc_key" --arg kid "$oidc_key_id" --arg login "$KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" '{"stringData":{"OIDC_ISSUER":$issuer,"OIDC_SIGNING_KEY":$key,"OIDC_SIGNING_KEY_ID":$kid,"OIDC_LOGIN_UI_URL":$login}}')" |
    kubectl --kubeconfig="$KUBECONFIG" -n identity patch secret identity-secrets --type=merge --patch-file=/dev/stdin >/dev/null
  kit_substrate_out "      secret identity-secrets existed without OIDC surface — patched in OIDC_ISSUER, OIDC_SIGNING_KEY, OIDC_SIGNING_KEY_ID, OIDC_LOGIN_UI_URL (signing key reused if stored)"
  # Read-back: a secret written but not readable is the defect the whole record
  # tripwire exists to catch, so verify the four keys round-trip.
  local got_issuer got_login got_key got_kid
  got_issuer="$(read_secret_key identity identity-secrets OIDC_ISSUER)"
  got_login="$(read_secret_key identity identity-secrets OIDC_LOGIN_UI_URL)"
  got_key="$(read_secret_key identity identity-secrets OIDC_SIGNING_KEY)"
  got_kid="$(read_secret_key identity identity-secrets OIDC_SIGNING_KEY_ID)"
  if [ "$got_issuer" != "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ] || [ "$got_login" != "$KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" ] || [ -z "$got_key" ] || [ -z "$got_kid" ]; then
    echo "error: identity-secrets patch did not round-trip — OIDC keys not readable" >&2
    exit 1
  fi
}

# validate_mfa_override — the operator-supplied MFA key, when set, must be
# exactly what identity's config parser accepts: base64url without padding
# decoding to 32 bytes (43 characters from A-Z a-z 0-9 - _). A refused value
# names the VARIABLE, never its value. Unset (empty) means "generate on the
# box". Called on the LIVE path only, beside the other externally-sourced
# validations — a dry run is a plan and does not need the key to print it.
validate_mfa_override() {
  if [ -z "$KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY" ]; then
    return 0
  fi
  local key="$KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY"
  local why=""
  case "$key" in
    *[!A-Za-z0-9_-]*)
      why="it carries characters outside base64url (A-Z a-z 0-9 - _), or padding"
      ;;
  esac
  if [ -z "$why" ] && [ "${#key}" -ne 43 ]; then
    why="it is ${#key} characters, want 43 (32 bytes as base64url, no padding)"
  fi
  if [ -z "$why" ]; then
    local n=""
    if n="$(printf '%s=' "$key" | tr -- '-_' '+/' | base64 -d 2>/dev/null | wc -c | tr -d ' \n')"; then
      [ "$n" = "32" ] || why="it decodes to ${n:-0} bytes, want exactly 32"
    else
      why="it does not base64-decode"
    fi
  fi
  if [ -n "$why" ]; then
    kit_substrate_refuse "KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY" \
      "export KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY='<43 base64url characters>' on the box and re-run, or leave it unset so the install generates one on first creation and keeps it" \
      "KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY is not a 32-byte base64url-no-padding key — $why"
  fi
}

# --- the secrets half of step 9 ------------------------------------------------
# One secret per service namespace, each exactly the keys its chart reads —
# because the generated charts use `envFrom: secretRef`, every key becomes
# an environment variable, so the key list IS the service's env list.
#
# SECRET RECORD (the drift tripwire — tests/substrate_test.sh parses these:
# every name here must be created below, and every key must appear as a
# --from-literal below; a fixture with one removed must fail):
#   RECORD identity-secrets: DATABASE_URL SIGNUP_SIGNING_KEY MFA_ENCRYPTION_KEY NATS_URL COURIER_BASE_URL COURIER_TOKEN PASSWORD_RESET_LINK_TEMPLATE EMAIL_VERIFICATION_LINK_TEMPLATE EMAIL_CHANGE_LINK_TEMPLATE INVITATION_LINK_TEMPLATE OTEL_SDK_DISABLED
#   RECORD gateway-secrets: REDIS_URL ASSERTION_SIGNING_KEY
#   RECORD courier-secrets: DATABASE_URL SECRET_KEY_BASE COURIER_IDENTITY_TOKEN COURIER_IDENTITY_URL COURIER_SECRET_BOX_KEY COURIER_MAIL_ADAPTER COURIER_SMTP_HOST COURIER_SMTP_PORT COURIER_SMTP_USERNAME COURIER_SMTP_PASSWORD COURIER_INBOUND_RESEND_SECRET COURIER_ERROR_RELAY_TOKEN OTEL_SDK_DISABLED
#   RECORD parlor-secrets: DATABASE_URL OTEL_SDK_DISABLED
#
# OTEL_SDK_DISABLED is the telemetry kill switch (see the constant's comment at
# the top of the file): the box deploys no OTLP endpoint, so every service is
# told to turn its SDK off rather than retry forever against the compose stack's
# `otel-collector`. It is in these three records because the generated charts
# `envFrom` their secret — the key IS the env var. gateway's secret does NOT
# carry it: its hand-written chart reads clear env from a ConfigMap, so the same
# key/value rides its Application's `spec.source.helm.values` instead.
#
# THE SPLIT IS BY PROVENANCE:
#   generated on the box, never printed, generated ONCE and read back —
#     SIGNUP_SIGNING_KEY and MFA_ENCRYPTION_KEY (base64url, exactly 32 bytes:
#     identity decodes both with base64.RawURLEncoding and refuses any other
#     length at boot; MFA falls back to the validated
#     KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY override when the operator
#     sets one),
#     SECRET_KEY_BASE, COURIER_SECRET_BOX_KEY, COURIER_ERROR_RELAY_TOKEN
#     (a self-contained shared value, generated like the raise text
#     suggests), the Redis password (redis half above), each Postgres role's
#     password (step 8), and gateway's ASSERTION_SIGNING_KEY (a PKCS#8 RSA-2048
#     PEM the chart MOUNTS as a file — generated here, never supplied, read
#     back on a re-run; see resolve_gateway_assertion_key).
#   minted on the box in step 12, never printed, never an input —
#     COURIER_IDENTITY_TOKEN. It is an API key identity itself mints, so the
#     old two-terminal loop (install → boot → mint by hand → paste into a
#     second run) is gone: the same four calls run on this box and the value
#     is patched into both secrets that have to hold it. `COURIER_TOKEN` in
#     identity-secrets is the SAME value, which courier requires and which no
#     hand-off can be trusted to get right.
#   minted on the box in step 12, never printed, never an input —
#     COURIER_IDENTITY_TOKEN, and the BASE URL of each side's peer written
#     with it (identity's COURIER_BASE_URL and courier's COURIER_IDENTITY_URL).
#     The token is an API key identity itself mints, so the old two-terminal
#     loop (install → boot → mint by hand → paste into a second run) is gone:
#     the same four calls run on this box and the value is patched into both
#     secrets that have to hold it. `COURIER_TOKEN` in identity-secrets is the
#     SAME value, which courier requires and which no hand-off can be trusted
#     to get right. Each secret gets its WHOLE pair in ONE patch: a token
#     without its base URL is a half-block, and identity's own loader refuses
#     to boot on one (`loadCourier`), which is the live defect this pair
#     closes.
#     THE PAIR ON IDENTITY'S SIDE IS WRITTEN ONLY WITH ITS LINK TEMPLATES, and
#     all seven keys are gated on KIT_SUBSTRATE_APP_BASE_URL. identity refuses
#     to boot with a base URL and a token but no link template
#     (`internal/config/config.go` loadCourier → resolveLinkTemplates; the case
#     is named "a base URL and a token with no link template" → ErrInvalidCourier).
#     So when the operator sets the box's public origin, step 12 writes the pair
#     AND the four templates in one patch and deletes the legacy shared default
#     in the same patch; when it is unset, step 12 writes NO
#     identity courier key at all — the no-mail state identity supports
#     (`present == 0`) — and courier's own pair is still written, because
#     COURIER_IDENTITY_TOKEN is required by courier's runtime regardless.
#   from the environment, shape-validated, never echoed — courier's SMTP
#     settings and the provider's signing secret KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET
#     (see the header for the variable names). This is now the ONE long-lived
#     secret an operator hands over, because the provider is the only party
#     that can hold it.
#   NEITHER — configuration that rides a secret-shaped slot. NATS_URL is
#     the broker's address: not sensitive, and not operator-supplied either,
#     so it belongs to no provenance above. It is in the RECORD as a
#     non-secret key because the record's job is the two-way tripwire over
#     what the charts' `envFrom` actually reads, and a key the check cannot
#     see drift on is a key it will not catch being deleted.
# `gateway-tls` is NOT created here: cert-manager fills it from the
# ClusterIssuer. `DATABASE_URL` agrees with the Cluster by construction — the
# host is CNPG's read-write service, the database and role are the service's
# own, and the password is read back from step 8's secret.
install_service_secrets() {
  # THE ASSERTION-KEY REPAIR RUNS ABOVE THE GUARD, on purpose: a box installed
  # before ASSERTION_SIGNING_KEY existed holds all four secrets, so the guard
  # would skip the step whole and leave gateway's pod stuck on the mount this
  # function is here to resolve. The plan form takes the dry-run path so a plan
  # neither generates a key nor patches a secret.
  if dry_run "ensure gateway-secrets carries ASSERTION_SIGNING_KEY (gateway's chart mounts it; generated on the box, read back on a re-run)"; then
    :
  else
    reconcile_gateway_assertion_key
  fi
  # The OIDC repair runs above the guard for the same reason: a box installed
  # before OIDC_LOGIN_UI_URL existed holds all four secrets (so the guard would
  # skip) and carries OIDC_ISSUER + key + id without the login UI — the shape
  # identity refuses with `OIDC_LOGIN_UI_URL: no OIDC login UI configured` and
  # CrashLoopBackOff. That box is the packet's own reproduction.
  if dry_run "ensure identity-secrets carries OIDC_LOGIN_UI_URL when the OIDC surface is wired (the fourth member of the all-or-nothing surface)"; then
    :
  else
    reconcile_oidc_identity_secrets
  fi
  if kit_substrate_guard secrets; then
    kit_substrate_out "      already installed, skipping"
    return 0
  fi
  if dry_run "create identity-secrets, gateway-secrets, courier-secrets, parlor-secrets (generated values once-only, sourced values validated on the live path)"; then
    return 0
  fi
  # Externally sourced values are validated on the LIVE path only — a dry run
  # is a plan, and a plan does not need credentials to print. A live run
  # with an incomplete relay refuses here, naming every missing variable,
  # before any secret is written.
  if [ -z "$KIT_SUBSTRATE_SMTP_HOST" ] ||
     [ -z "$KIT_SUBSTRATE_SMTP_USERNAME" ] || [ -z "$KIT_SUBSTRATE_SMTP_PASSWORD" ] ||
     [ -z "$KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET" ]; then
    kit_substrate_refuse \
      "KIT_SUBSTRATE_SMTP_HOST, KIT_SUBSTRATE_SMTP_USERNAME, KIT_SUBSTRATE_SMTP_PASSWORD, KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET" \
      "export the four above on the box and re-run — the signing secret comes from the PROVIDER's dashboard (Resend: the webhook endpoint's Signing Secret)" \
      "courier's externally-sourced settings are incomplete — all of these are required"
  fi
  case "$KIT_SUBSTRATE_SMTP_ADAPTER" in
    smtp | postmark) ;;
    *)
      kit_substrate_refuse "KIT_SUBSTRATE_SMTP_ADAPTER" \
        "export KIT_SUBSTRATE_SMTP_ADAPTER='smtp' (or 'postmark') on the box and re-run" \
        "KIT_SUBSTRATE_SMTP_ADAPTER must be smtp or postmark"
      ;;
  esac
  case "$KIT_SUBSTRATE_SMTP_PORT" in
    '' | *[!0-9]*)
      kit_substrate_refuse "KIT_SUBSTRATE_SMTP_PORT" \
        "export KIT_SUBSTRATE_SMTP_PORT='587' on the box and re-run" \
        "KIT_SUBSTRATE_SMTP_PORT must be numeric"
      ;;
  esac

  # Externally sourced OIDC surface is validated before any secret is written.
  # A lone issuer or a lone login UI is a boot-time refusal discovered three
  # steps later; the installer refuses by name before writing anything.
  validate_oidc_all_or_nothing

  local ns
  for ns in identity gateway courier parlor; do
    kubectl --kubeconfig="$KUBECONFIG" create namespace "$ns" --dry-run=client -o yaml |
      kubectl --kubeconfig="$KUBECONFIG" apply -f - >/dev/null
  done

  # identity-secrets. Always: DATABASE_URL (agrees with the Cluster),
  # SIGNUP_SIGNING_KEY (generated once) and MFA_ENCRYPTION_KEY (generated
  # once, or the validated operator override). When the operator set an issuer
  # and a login UI: OIDC_ISSUER plus a signing key and key id GENERATED ON
  # THIS BOX — the customer's own key, which is why it is not an input — plus
  # OIDC_LOGIN_UI_URL, the browser target for authentication (parlor on this
  # substrate). Step 11 adds COURIER_TOKEN with the value it minted, so
  # identity holds exactly the key courier presents rather than one the
  # operator matched up by hand.
  # A pre-existing identity-secrets is NEVER patched — not with a generated
  # key and not with an override — except for the OIDC surface above the
  # guard, which patches a legacy secret missing the login UI. The MFA stored
  # key is a persistent encryption key: an imported database could hold
  # ciphertext sealed under a key no longer present, so guessing a fresh one
  # in would fork it. A legacy secret without the MFA key keeps running
  # unwired; the operator path to MFA on such an install is in README.md, not
  # guessed here.
  # The generation is SIGNUP_SIGNING_KEY's own spelling (32 random bytes as
  # base64url, no padding): identity decodes MFA_ENCRYPTION_KEY with
  # base64.RawURLEncoding and refuses any other length at boot.
  #
  # NATS_URL is CONFIGURATION, not a secret. The broker's address is not
  # sensitive — the broker carries no credentials on this substrate
  # (manifests/data/nats.yaml's header) and the stream it reaches holds no
  # customer data — and it is here because the generated charts inject env
  # with `envFrom: secretRef`, so this secret IS identity's environment.
  # It is the key that turns identity's outbox loop on at all: identity
  # builds its NATS publisher only when NATS_URL is set, so without it the
  # local compose stack publishes and a real box does not. The address is
  # the one constant above — fully qualified, because identity's namespace
  # is not the broker's. Written on first creation and never patched, like
  # every other key here: the address is fixed by the broker's own Service
  # name, and a broker that moves is a rotate-by-replacement (README), not
  # a silent patch of a running secret.
  validate_mfa_override
  local signup_key mfa_key identity_args oidc_key="" oidc_key_id=""
  signup_key="$(read_secret_key identity identity-secrets SIGNUP_SIGNING_KEY)"
  if [ -z "$signup_key" ]; then
    signup_key="$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')"
  fi
  if [ -n "$KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY" ]; then
    mfa_key="$KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY"
  else
    mfa_key="$(read_secret_key identity identity-secrets MFA_ENCRYPTION_KEY)"
    if [ -z "$mfa_key" ]; then
      mfa_key="$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')"
    fi
  fi
  identity_args=(--from-literal=DATABASE_URL="$(database_url_for identity)"
    --from-literal=SIGNUP_SIGNING_KEY="$signup_key"
    --from-literal=MFA_ENCRYPTION_KEY="$mfa_key"
    --from-literal=NATS_URL="$NATS_URL")
  # The OIDC surface, when wired, carries four keys or none: identity refuses
  # to boot on a lone key and on a missing login UI. The signing key is
  # generated here and never printed; the issuer and login UI are configuration
  # and are echoed as configuration.
  if [ -n "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ]; then
    resolve_oidc_signing_key
    oidc_key="$OIDC_SIGNING_KEY"
    oidc_key_id="$OIDC_SIGNING_KEY_ID"
    identity_args+=(--from-literal=OIDC_ISSUER="$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER"
      --from-literal=OIDC_SIGNING_KEY="$oidc_key"
      --from-literal=OIDC_SIGNING_KEY_ID="$oidc_key_id"
      --from-literal=OIDC_LOGIN_UI_URL="$KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL")
  fi
  [ -n "$KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY" ] &&
    identity_args+=(--from-literal=OAUTH_ENCRYPTION_KEY="$KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY")
  if kubectl --kubeconfig="$KUBECONFIG" get secret identity-secrets -n identity >/dev/null 2>&1; then
    kit_substrate_out "      secret identity-secrets exists — refusing to overwrite (rotate by replacing the secret and restarting the pods)"
  else
    kubectl --kubeconfig="$KUBECONFIG" create secret generic identity-secrets -n identity \
      "${identity_args[@]}" "${SERVICE_OTEL_DISABLED[@]}" >/dev/null
    kit_substrate_out "      secret identity-secrets created (generated values once-only; rotate by replacing the secret)"
    # Read-back on a cold box: a secret written but not readable is the defect
    # the whole record tripwire exists to catch.
    if [ -n "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ]; then
      local verify_issuer verify_login verify_key verify_kid
      verify_issuer="$(read_secret_key identity identity-secrets OIDC_ISSUER)"
      verify_login="$(read_secret_key identity identity-secrets OIDC_LOGIN_UI_URL)"
      verify_key="$(read_secret_key identity identity-secrets OIDC_SIGNING_KEY)"
      verify_kid="$(read_secret_key identity identity-secrets OIDC_SIGNING_KEY_ID)"
      if [ "$verify_issuer" != "$KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" ] || [ "$verify_login" != "$KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" ] || [ -z "$verify_key" ] || [ -z "$verify_kid" ]; then
        echo "error: identity-secrets does not carry the OIDC surface after creation — OIDC keys not readable or mismatched" >&2
        exit 1
      fi
    fi
  fi

  # gateway-secrets. Two keys, and both are REQUIRED references the chart names:
  #
  #   * REDIS_URL — the `secretKeyRef` the chart names
  #     (`secrets.redisUrlSecretName` / `redisUrlSecretKey`). The password is
  #     read back from step 9's secret; the host is this file's Redis Service.
  #     No IDENTITY_URL here: that is clear env in the chart's ConfigMap, not a
  #     secret.
  #   * ASSERTION_SIGNING_KEY — the `volumes.secret` ITEM the chart mounts as
  #     `/etc/gateway/assertion/signing.pem`, the path
  #     `ASSERTION_SIGNING_KEY_FILE` names. A missing item is the whole defect
  #     this key exists to end: the pod waits in ContainerCreating on a mount
  #     that never resolves. Generated on this box (see
  #     resolve_gateway_assertion_key) and read back on a re-run.
  local redis_pw
  redis_pw="$(read_secret_key data redis-password password)"
  if [ -z "$redis_pw" ]; then
    echo "error: secret redis-password is missing in namespace data — run step 9 first" >&2
    exit 1
  fi
  # Read-or-generate. On the create path the repair above found no secret, so
  # this is where a first install's key is minted.
  resolve_gateway_assertion_key
  if kubectl --kubeconfig="$KUBECONFIG" get secret gateway-secrets -n gateway >/dev/null 2>&1; then
    kit_substrate_out "      secret gateway-secrets exists — refusing to overwrite (rotate by replacing the secret and restarting the pods)"
  else
    kubectl --kubeconfig="$KUBECONFIG" create secret generic gateway-secrets -n gateway \
      --from-literal=REDIS_URL="redis://:$redis_pw@redis.data.svc.cluster.local:6379" \
      --from-literal=ASSERTION_SIGNING_KEY="$ASSERTION_SIGNING_KEY" >/dev/null
    kit_substrate_out "      secret gateway-secrets created (REDIS_URL and a generated ASSERTION_SIGNING_KEY — the chart's two required references)"
  fi

  # courier-secrets. The keys chart/values.yaml documents that this install
  # can supply, plus the mail-adapter settings runtime.exs refuses to boot
  # without: adapter settings are configuration, but the chart's only env
  # injection is this secret, so they ride along rather than missing the pod.
  # Generated here: SECRET_KEY_BASE (64 bytes — Phoenix refuses shorter),
  # COURIER_SECRET_BOX_KEY (32 bytes base64, the spelling the comment in
  # runtime.exs suggests), COURIER_ERROR_RELAY_TOKEN (32 bytes hex, likewise).
  # From the environment: the relay settings and the provider's signing secret.
  # COURIER_IDENTITY_TOKEN is NOT set here and is NOT an input: step 12 mints
  # it from identity's own API, on this box, and patches this secret with the
  # value — the loop that used to run across two terminals runs inside one run.
  # A missing key is a `System.get_env(…) || raise` at boot — the cheapest
  # possible failure, and it happens before the first customer request.
  local secret_base secret_box relay_token
  local -a courier_extra_args=()
  secret_base="$(read_secret_key courier courier-secrets SECRET_KEY_BASE)"
  [ -n "$secret_base" ] || secret_base="$(head -c 64 /dev/urandom | base64 | tr -d '\n')"
  secret_box="$(read_secret_key courier courier-secrets COURIER_SECRET_BOX_KEY)"
  [ -n "$secret_box" ] || secret_box="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
  relay_token="$(read_secret_key courier courier-secrets COURIER_ERROR_RELAY_TOKEN)"
  [ -n "$relay_token" ] || relay_token="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  if kubectl --kubeconfig="$KUBECONFIG" get secret courier-secrets -n courier >/dev/null 2>&1; then
    kit_substrate_out "      secret courier-secrets exists — refusing to overwrite (rotate by replacing the secret and restarting the pods)"
  else
    kubectl --kubeconfig="$KUBECONFIG" create secret generic courier-secrets -n courier \
      --from-literal=DATABASE_URL="$(database_url_for courier)" \
      --from-literal=SECRET_KEY_BASE="$secret_base" \
      --from-literal=COURIER_SECRET_BOX_KEY="$secret_box" \
      --from-literal=COURIER_MAIL_ADAPTER="$KIT_SUBSTRATE_SMTP_ADAPTER" \
      --from-literal=COURIER_SMTP_HOST="$KIT_SUBSTRATE_SMTP_HOST" \
      --from-literal=COURIER_SMTP_PORT="$KIT_SUBSTRATE_SMTP_PORT" \
      --from-literal=COURIER_SMTP_USERNAME="$KIT_SUBSTRATE_SMTP_USERNAME" \
      --from-literal=COURIER_SMTP_PASSWORD="$KIT_SUBSTRATE_SMTP_PASSWORD" \
      --from-literal=COURIER_INBOUND_RESEND_SECRET="$KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET" \
      --from-literal=COURIER_ERROR_RELAY_TOKEN="$relay_token" \
      "${SERVICE_OTEL_DISABLED[@]}" \
      ${courier_extra_args[@]+"${courier_extra_args[@]}"} >/dev/null
    kit_substrate_out "      secret courier-secrets created (COURIER_IDENTITY_TOKEN follows in step 12 — minted on this box)"
  fi
  # Optional mail-from passthrough: courier falls back to its compiled
  # default without these, so they ride the same conditional pattern as the
  # OIDC keys above — set at creation, and a later addition means replacing
  # the secret (the step refuses to overwrite, by design).
  [ -n "$KIT_SUBSTRATE_MAIL_FROM" ] &&
    courier_extra_args+=(--from-literal=MAIL_FROM="$KIT_SUBSTRATE_MAIL_FROM")
  [ -n "$KIT_SUBSTRATE_MAIL_FROM_NAME" ] &&
    courier_extra_args+=(--from-literal=MAIL_FROM_NAME="$KIT_SUBSTRATE_MAIL_FROM_NAME")

  # parlor-secrets. Parlor's chart reads this secret with envFrom but
  # documents no required keys (its runtime reads IDENTITY_URL, BILLING_URL
  # and OTEL_* — clear configuration, not secrets). The secret must still
  # EXIST or the pod never starts, so it carries the one value that agrees
  # with the Cluster by construction: parlor's own DATABASE_URL.
  if kubectl --kubeconfig="$KUBECONFIG" get secret parlor-secrets -n parlor >/dev/null 2>&1; then
    kit_substrate_out "      secret parlor-secrets exists — refusing to overwrite (rotate by replacing the secret and restarting the pods)"
  else
    kubectl --kubeconfig="$KUBECONFIG" create secret generic parlor-secrets -n parlor \
      --from-literal=DATABASE_URL="$(database_url_for parlor)" \
      "${SERVICE_OTEL_DISABLED[@]}" >/dev/null
    kit_substrate_out "      secret parlor-secrets created (DATABASE_URL only — see the comment above)"
  fi
}

# --- step 10: the services' database schemas ---------------------------------
# NOTHING ELSE IN THIS FILE RUNS A SERVICE'S MIGRATIONS, AND THAT WAS THE
# DEFECT. The Postgres Cluster (step 8) creates an empty database per service;
# the Applications (step 6) boot the services against it; the fleet's charts
# assume a migrated database because in CI the migrate step is explicit. So a
# box that "finished" the substrate booted identity against a schema with no
# `outbox_events`, and identity's own logs said so forever:
#
#   level=ERROR msg="outbox publisher pass failed; retrying"
#     error="outbox: claiming a batch: ERROR: relation \"outbox_events\" does not
#     exist (SQLSTATE 42P01)"
#
# The installer's own integration probe (step 12) then caught it from outside —
# `identity would not mint a signup timestamp`, a 500 on the missing table.
#
# THE MECHANISM, AND WHY THIS ONE. Two shapes were credible: an Argo CD
# PreSync hook Job in each service chart, or a step here that runs each
# service's migrate entrypoint. The PreSync hook is the stronger ordering (it
# runs BEFORE the workload, so no replica ever boots against an old schema), but
# it lives in the service charts — repositories this one does not own — and it
# would need the migrate entrypoint in the image anyway. So the step is here,
# and the two facts that make it correct are both read from the running world
# rather than restated:
#
#   - THE IMAGE IS THE RUNNING DEPLOYMENT'S IMAGE, read back from the
#     Deployment Argo synced. A migration must come from the SAME build as the
#     service it migrates for; a second pin here would be a second thing to
#     keep in step, and the one that drifts is the one nobody reads.
#   - THE DSN IS THE OWNER ROLE (see owner_database_url_for): a migration is
#     DDL and the application's `<svc>_app` role owns nothing.
#
# WHAT IT IS NOT. Not `kubectl exec … migrate || true`, and not a sleep, and not
# "the service migrates at boot" — that last one is checked rather than assumed:
# a service whose image cannot run a migration (identity ships a static binary
# in a distroless image with no shell, no psql and no migration files; courier
# ships its release's `/app/bin/migrate`) is a FINDING, and the step fails
# loudly naming the service and refusing to leave a pod "Ready" over an empty
# schema. A failed migration is a failed step: the pod's phase is watched to
# completion, its logs are printed on failure, and the install stops.
#
# A SERVICE WITH NO SCHEMA IS A FINDING, NOT AN ASSUMPTION. gateway's
# `bin/migrate` is an explicit no-op — no driver, no pool, no `DATABASE_URL`,
# no migrations — and parlor's chart documents no database and its runtime reads
# none (it is a front end; the `parlor` database and roles exist only because
# the Cluster provisions one per named service). Both are named in the plan and
# skipped, so the day either grows a schema this step is the file to extend and
# the omission is visible rather than silent.
#
# IDEMPOTENT, TWICE OVER. The migrate tools keep a version table
# (`goose_db_version`, `schema_migrations`) so applying an already-applied
# migration is a no-op — but a re-run should not even launch the pods. A marker
# Secret in `data` records, per service, the IMAGE whose schema was applied; the
# guard skips the whole step when every marker still matches the running
# Deployment, and a new image re-enters the step and lets the tool apply what is
# pending.
KIT_SUBSTRATE_MIGRATE_MARKER="${KIT_SUBSTRATE_MIGRATE_MARKER:-substrate-migrations}"

# migration_service_has_schema <service> — does this service own a schema?
# A closed list, and the list IS the inventory: adding a service here without a
# matching `migration_command_for` is a red plan, not a silently skipped step.
migration_service_has_schema() {
  case "$1" in
    identity | courier) return 0 ;;
    *) return 1 ;;
  esac
}

# migration_command_for <service> — the entrypoint, run in the service's image.
# Overridable so a service that moves its migrator does not need a kit release;
# the override is per service so one service's path cannot misdirect another's.
migration_command_for() {
  case "$1" in
    # identity's repo entrypoint: `bin/migrate`, a psql loop over
    # `migrations/*.sql` (its Down section is cut out by bin/migration-up-section).
    # It is in the repository, NOT in the image today — see the step header and
    # the report; the exact service-repo edit that puts it there is named there.
    identity) printf '%s' "${KIT_SUBSTRATE_MIGRATE_CMD_identity:-/app/bin/migrate}" ;;
    # courier's release overlays a `bin/migrate` -> `courier eval
    # Courier.Release.migrate`, which runs as Courier.OwnerRepo.
    courier) printf '%s' "${KIT_SUBSTRATE_MIGRATE_CMD_courier:-/app/bin/migrate}" ;;
    *) return 1 ;;
  esac
}

# migration_env_args_for <service> — the `--env=NAME=DSN` arguments for the Job,
# one array element each. courier's release eval loads runtime.exs, which raises
# without DATABASE_URL AND configures Courier.OwnerRepo only from
# COURIER_OWNER_DATABASE_URL, so it needs both; identity's `bin/migrate` reads
# DATABASE_URL and only DATABASE_URL.
migration_env_args_for() {
  case "$1" in
    identity)
      printf '%s\n' "--env=DATABASE_URL=$(owner_database_url_for identity)"
      ;;
    courier)
      printf '%s\n' "--env=COURIER_OWNER_DATABASE_URL=$(owner_database_url_for courier)"
      printf '%s\n' "--env=DATABASE_URL=$(database_url_for courier)"
      ;;
    *) return 1 ;;
  esac
}

# migration_guard_applied — has every schema-owning service's marker been
# written for the image it is running? True means the step is a no-op.
migration_guard_applied() {
  if [ "$DRY_RUN" -eq 1 ]; then
    return 1
  fi
  local svc image marked
  for svc in identity courier; do
    migration_service_has_schema "$svc" || continue
    image="$(kubectl --kubeconfig="$KUBECONFIG" get deployment "$svc" -n "$svc" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    [ -n "$image" ] || return 1
    marked="$(read_secret_key data "$KIT_SUBSTRATE_MIGRATE_MARKER" "$svc")"
    [ "$marked" = "$image" ] || return 1
  done
  return 0
}

install_migrations() {
  log_step "the database schemas of the services that own one (identity, courier)"
  if migration_guard_applied; then
    kit_substrate_out "      every schema already applied at the running image, skipping (a new image re-enters this step)"
    return 0
  fi
  if dry_run "run one migrate Job per schema-owning service, in that service's own running image, connected as its OWNER role (identity/identity, courier/courier), and wait for completion; gateway and parlor own no schema and are skipped"; then
    return 0
  fi

  local svc image cmd phase tries
  local -a env_args=() marker_args=() failed=()
  for svc in identity courier; do
    migration_service_has_schema "$svc" || continue
    # The image the Running Deployment runs — the same build as the service.
    image="$(kubectl --kubeconfig="$KUBECONFIG" get deployment "$svc" -n "$svc" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    if [ -z "$image" ]; then
      echo "error: deployment/${svc} does not exist yet — Argo has not synced it, so the image to migrate with is unknown; re-run step ${STEP}" >&2
      exit 1
    fi
    cmd="$(migration_command_for "$svc")"
    env_args=()
    while IFS= read -r arg; do
      env_args+=("$arg")
    done < <(migration_env_args_for "$svc")

    kit_substrate_out "      migrating ${svc} as its OWNER role, in ${image}"
    # The same one-shot discipline step 11's stream init uses: delete a leftover
    # from a previous run, run the pod with Never semantics, watch its phase.
    kubectl --kubeconfig="$KUBECONFIG" delete pod "kit-migrate-${svc}" -n "$svc" --ignore-not-found >/dev/null 2>&1 || true
    if ! kubectl --kubeconfig="$KUBECONFIG" run "kit-migrate-${svc}" -n "$svc" \
      --restart=Never \
      --image="$image" \
      "${env_args[@]}" \
      --command -- $cmd; then
      # The image could not even start the command — a distroless service with
      # no migrate entrypoint. That is the finding the step exists to surface,
      # not a transient. Fall through to the phase read, which reports it.
      :
    fi
    phase=""
    tries=36
    while [ "$tries" -gt 0 ]; do
      phase="$(kubectl --kubeconfig="$KUBECONFIG" get pod "kit-migrate-${svc}" -n "$svc" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      case "$phase" in
        Succeeded)
          kubectl --kubeconfig="$KUBECONFIG" delete pod "kit-migrate-${svc}" -n "$svc" >/dev/null 2>&1 || true
          kit_substrate_out "      ${svc}'s schema is applied"
          break
          ;;
        Failed)
          break
          ;;
      esac
      tries=$((tries - 1))
      sleep 5
    done
    if [ "$phase" != "Succeeded" ]; then
      echo "error: the migration for ${svc} did not succeed (last pod phase: '${phase:-Unknown}')" >&2
      echo "error:   service: ${svc}" >&2
      echo "error:   dsn:     $(owner_database_url_for "$svc" | sed 's#://[^:]*:[^@]*@#://OWNER:<redacted>@#') (role ${svc}, the OWNER)" >&2
      echo "error:   image:   ${image}" >&2
      echo "error: the pod is left in namespace ${svc} for diagnosis; its logs follow:" >&2
      kubectl --kubeconfig="$KUBECONFIG" logs "pod/kit-migrate-${svc}" -n "$svc" >&2 2>&1 || true
      failed+=("$svc")
      continue
    fi
    marker_args+=("--from-literal=${svc}=${image}")
  done

  if [ "${#failed[@]}" -gt 0 ]; then
    echo "error: the substrate will not report a finished install while a service's schema is empty: ${failed[*]}" >&2
    echo "error: fix the migrate entrypoint for the service(s) named above, then re-run — every completed step is skipped by its guard" >&2
    exit 1
  fi

  # The marker that makes a re-run a no-op. Delete-then-create rather than
  # apply: the value is per-image and a leftover key for a service that no
  # longer has a schema would be a lie the guard then reads.
  kubectl --kubeconfig="$KUBECONFIG" delete secret "$KIT_SUBSTRATE_MIGRATE_MARKER" -n data --ignore-not-found >/dev/null 2>&1 || true
  kubectl --kubeconfig="$KUBECONFIG" create secret generic "$KIT_SUBSTRATE_MIGRATE_MARKER" -n data \
    "${marker_args[@]}" >/dev/null
  kit_substrate_out "      schemas applied for: identity, courier (marker secret ${KIT_SUBSTRATE_MIGRATE_MARKER} in data)"
}

# --- step 11: NATS with JetStream and the fleet's stream -----------------------
# One Deployment + Service + PVC in `data` (manifests/data/nats.yaml: an
# accessory like Redis — no clustering, no credentials, no client TLS on one
# box), plus the stream the fleet publishes to, defined idempotently.
#
# THE IMAGE IS SUBSTITUTED, NOT LITERAL. nats.yaml carries
# NATS_IMAGE_PLACEHOLDER where the tag goes; the apply below replaces it with
# the pinned image in a pipe (the TLS step's shape for the ACME email), so the
# pin lives in exactly one place and never reaches disk unsubstituted.
#
# THE STREAM INIT MIRRORS nats-stream-init. The local one-shot runs
# check-then-create (`nats stream info cafaye` exits 1 when the stream is
# absent, so the `add` runs only then — a plain `add` is NOT idempotent), with
# the same subjects, storage, retention, max-age, discard and replicas. Here
# the same command runs in an ephemeral pod (`kubectl run` with the nats-box
# image, NATS_URL read from the one constant above — the same address
# identity's secret carries): the guard above
# skips the BROKER on a re-run, but the stream init runs every time, and
# `info || add` makes that a no-op when the stream exists.
#
# A FAILED INIT FAILS THE INSTALL LOUDLY. The pod runs with Never semantics,
# it is waited on to the Succeeded phase, and a Failed phase prints the pod's
# logs and exits non-zero — never hidden behind a restart policy (which is why
# the pod is deleted only on success; a failed pod is left for diagnosis and
# removed at the start of the next run by the delete below).
#
# The broker's apply is a LOCAL manifest through a pipe, so CLIENT-SIDE — the
# note above step 2 holds.
install_nats() {
  log_step "NATS with JetStream ${NATS_VERSION} and stream cafaye (in the data namespace)"
  if kit_substrate_guard nats; then
    kit_substrate_out "      already installed, skipping the broker (the stream init still runs)"
  elif dry_run "substitute NATS_IMAGE_PLACEHOLDER with nats:${NATS_VERSION} and apply ${DATA_DIR}/nats.yaml, then wait for deployment nats"; then
    :
  else
    kubectl --kubeconfig="$KUBECONFIG" create namespace data --dry-run=client -o yaml |
      kubectl --kubeconfig="$KUBECONFIG" apply -f -
    # Applied BY NAME, so the file is deliberate; the directory is checked so a
    # stray file beside it is surfaced rather than skipped (see
    # install_applications).
    kit_substrate_check_manifest_dir "$DATA_DIR"
    sed "s/NATS_IMAGE_PLACEHOLDER/nats:${NATS_VERSION}/" "$DATA_DIR/nats.yaml" |
      kubectl --kubeconfig="$KUBECONFIG" apply -f -
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment nats -n data --timeout=180s
  fi
  if dry_run "run one-shot pod nats-stream-init (image natsio/nats-box:${NATS_BOX_VERSION}) ensuring stream cafaye"; then
    return 0
  fi
  kubectl --kubeconfig="$KUBECONFIG" delete pod nats-stream-init -n data --ignore-not-found >/dev/null
  kubectl --kubeconfig="$KUBECONFIG" run nats-stream-init -n data \
    --restart=Never \
    --image="natsio/nats-box:${NATS_BOX_VERSION}" \
    --env="NATS_URL=$NATS_URL" \
    --command -- sh -c 'nats stream info cafaye >/dev/null 2>&1 || nats stream add cafaye --subjects "identity.>,billing.>,courier.>,muse.>,darkroom.>" --storage file --retention limits --max-age 7d --discard old --replicas 1 --defaults'
  local phase="" tries=24
  while [ "$tries" -gt 0 ]; do
    phase="$(kubectl --kubeconfig="$KUBECONFIG" get pod nats-stream-init -n data -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in
      Succeeded)
        kubectl --kubeconfig="$KUBECONFIG" delete pod nats-stream-init -n data >/dev/null
        kit_substrate_out "      stream cafaye exists (created or already present)"
        return 0
        ;;
      Failed)
        echo "error: the NATS stream init failed — the pod is left in namespace data for diagnosis:" >&2
        kubectl --kubeconfig="$KUBECONFIG" logs pod/nats-stream-init -n data >&2 || true
        exit 1
        ;;
    esac
    tries=$((tries - 1))
    sleep 5
  done
  echo "error: timed out waiting for pod nats-stream-init (last phase: '${phase:-unknown}') — the pod is left for diagnosis" >&2
  exit 1
}

# --- step 12: courier's identity credential, minted on this box -------------
# The two bounds below are this step's own 360s, split the way steps 1 and 8
# are: 180s for Argo to create the Deployment, then rollout inside what is
# left. Overridable so the suite can shorten the first half.
#
# WHY 180 AND NOT 120. Argo CD's application-controller reconciles on a watch
# event when an Application is created, but its resync / hard refresh interval
# defaults to 180s (3 minutes, `timeout.reconciliation` / `status.processors`
# in the controller's args — the same 3m the live box's controller was
# observed at), and a cold box after steps 7-10 is exactly the place where
# the watch event is most likely to be missed or delayed: the API server was
# busy creating the CNPG Cluster's pods, the controller was waiting on
# repo-server to be Available, and step 12 arrived before the next resync.
# The previous bound was 120+180=300s; measured live, Argo had not created
# deployment/identity 120s after the Applications were applied even ignoring
# the missing AppProject — the Unknown Applications never started syncing, so
# the wait timed out on an empty list. 180s covers one full resync period
# plus the image-pull / rollout that follows, and keeps the total at 360s
# rather than growing it arbitrarily. A bound that is shorter than the
# controller's own refresh is a bound that fails on a healthy cluster, which
# is the silent skip section 17 exists to refuse.
: "${IDENTITY_DEPLOY_TIMEOUT:=180}"
: "${IDENTITY_ROLLOUT_TIMEOUT:=180}"
# install → boot → MINT → patch → restart, in ONE run on ONE box.
#
# This loop used to cross a boundary: identity booted, the operator minted an
# API key by hand (POST /v1/accounts/{id}/api-keys), pasted it into a second
# run of this script, and a mismatch between identity's COURIER_TOKEN and
# courier's COURIER_IDENTITY_TOKEN surfaced as a 403 that reads like a network
# fault. None of that is a property the box cannot hold itself, so the mint
# runs here — the same four calls the local launch harness makes, against
# identity's own in-cluster endpoint over a port-forward, on the box.
#
# WHAT NEVER LEAVES: the minted value is a shell variable, written into two
# secrets, and printed nowhere — not in DRY_RUN, not on a refusal, not on
# success. The token is written as ONE value in ONE step, and each secret's
# base URL is written in the same patch as its token — the only shape that
# cannot drift.
# validate_app_base_url — refuse a malformed KIT_SUBSTRATE_APP_BASE_URL, naming
# the variable, BEFORE identity's link templates are derived from it. identity
# validates the same shape at boot (`validateMailBaseURL` and the link-template
# checks: absolute http/https, a host, no query or fragment; placeholders and a
# per-template path are the template's own), but a boot-time refusal costs a
# rollout that never goes Ready while this one costs a sentence. An UNSET value
# is NOT a refusal: it is the documented no-mail path, and this returns 0.
validate_app_base_url() {
  [ -n "$KIT_SUBSTRATE_APP_BASE_URL" ] || return 0
  case "$KIT_SUBSTRATE_APP_BASE_URL" in
    http://* | https://*) ;;
    *)
      kit_substrate_refuse "KIT_SUBSTRATE_APP_BASE_URL" \
        "export KIT_SUBSTRATE_APP_BASE_URL='https://app.example.com' — the public origin a browser reaches (scheme and host, no query and no fragment) — and re-run" \
        "KIT_SUBSTRATE_APP_BASE_URL must be an absolute http(s) URL"
      ;;
  esac
  case "${KIT_SUBSTRATE_APP_BASE_URL#*://}" in
    "" | *\?* | *#*)
      kit_substrate_refuse "KIT_SUBSTRATE_APP_BASE_URL" \
        "export KIT_SUBSTRATE_APP_BASE_URL='https://app.example.com' — scheme, host and nothing with a query or a fragment (identity appends each link's own path) — and re-run" \
        "KIT_SUBSTRATE_APP_BASE_URL must be an origin: a host, and no query or fragment"
      ;;
  esac
}

# converge_identity_courier_block — converge identity's courier keys when the box
# declares no public origin. TWO shapes reach this branch and they are not the
# same thing, so the function CLASSIFIES before it deletes — mirroring
# identity's own `loadCourier` rule (`present != 2` refuses):
#
# * HALF-PAIR or STRAY TEMPLATE — COURIER_BASE_URL xor COURIER_TOKEN present,
#   or a lone template key. This is the state the sweep was written for: an
#   older installer wrote COURIER_TOKEN without COURIER_BASE_URL (or templates
#   pointing at a base this box no longer declares), identity's loader refuses
#   exactly that half-pair, so the orphan crashloops identity and a re-run
#   that only writes the happy path never clears it. These keys are orphans:
#   deleted in one merge patch, reported key by key, identity restarted, and
#   the block re-read to prove it converged.
# * COMPLETE PAIR — COURIER_BASE_URL AND COURIER_TOKEN both present, with or
#   without templates. This is NOT an orphan: it is a WORKING mail path the
#   operator configured (a run where KIT_SUBSTRATE_APP_BASE_URL was set, or a
#   hand patch), identity boots on it and every recovery route answers. A step
#   that cannot write the correct value must not delete the correct value that
#   is already there, so the pair STAYS: nothing is deleted, nothing is
#   restarted, and the report says plainly that the box keeps a working mail
#   path and names KIT_SUBSTRATE_APP_BASE_URL as the variable that would
#   rewrite it. Deleting it here and calling it "leftovers" turned a working
#   box into 503s on every recovery route with no line in the run saying so.
#
# The intended state with KIT_SUBSTRATE_APP_BASE_URL unset is NO courier keys
# at all (`present == 0`, the supported no-mail state) — and a box that
# carries none says so, naming that nothing was removed. But "intended" is
# not "present": the sweep heals what is broken and leaves what works.
#
# The nulls go under `data` and NOT under `stringData` on purpose: stringData
# is write-only and is never persisted, so a null there merges into a field
# the stored object does not carry and deletes nothing, while a null under
# `data` removes the entry at the JSON level before the object is decoded.
#
# Called ABOVE the mint guard as well as in the unset branch below it: a warm
# box that already minted (guard: COURIER_IDENTITY_TOKEN present) still carries
# the orphan, and the guard's early return would otherwise skip the sweep — the
# same shape as the AppProject reapply fix. Courier's own pair is NOT swept:
# COURIER_IDENTITY_TOKEN is required by courier's runtime regardless.
converge_identity_courier_block() {
  local k v orphans=""
  IDENTITY_MAIL_PATH_KEPT=""
  local base_present="" token_present=""
  for k in ${IDENTITY_COURIER_KEYS[@]+"${IDENTITY_COURIER_KEYS[@]}"}; do
    v="$(read_secret_key identity identity-secrets "$k")"
    if [ -n "$v" ]; then
      orphans="${orphans:+$orphans }$k"
      case "$k" in
        COURIER_BASE_URL) base_present=1 ;;
        COURIER_TOKEN) token_present=1 ;;
      esac
    fi
  done
  if [ -n "$base_present" ] && [ -n "$token_present" ]; then # SWEEP-HONEST-CLASSIFY
    kit_substrate_out "      identity carries a working mail path (COURIER_BASE_URL and COURIER_TOKEN are both present): this run has no KIT_SUBSTRATE_APP_BASE_URL to rewrite it with, so the mail path stays, nothing removed, and every recovery route keeps answering — set KIT_SUBSTRATE_APP_BASE_URL to rewrite the pair and its link templates on a later run"
    IDENTITY_MAIL_PATH_KEPT=1
    return 0
  fi
  if [ -z "$orphans" ]; then
    kit_substrate_out "      identity's mail path is NOT configured (KIT_SUBSTRATE_APP_BASE_URL unset): no identity courier keys written, nothing removed, so identity boots into its supported no-mail state and every recovery route answers 503"
    return 0
  fi
  local orphan_patch
  orphan_patch="$(printf '%s' "$orphans" | tr ' ' '\n' | jq -Rn '[inputs | select(length > 0)] | map({(.): null}) | add | {data: .}')"
  printf '%s' "$orphan_patch" |
    kubectl --kubeconfig="$KUBECONFIG" -n identity patch secret identity-secrets \
    --type=merge --patch-file=/dev/stdin
  kit_substrate_out "      identity's mail path is NOT configured (KIT_SUBSTRATE_APP_BASE_URL unset): removed orphaned courier key(s):$orphans — leftovers from an installer that wrote half a pair, and each one is either a half-pair that crashloops identity or a template pointing at a base this box no longer declares"
  if kubectl --kubeconfig="$KUBECONFIG" get deployment identity -n identity >/dev/null 2>&1; then
    kubectl --kubeconfig="$KUBECONFIG" -n identity rollout restart deployment/identity
  else
    kit_substrate_out "      identity Deployment not present — restart skipped (the secret is already converged; the next sync boots clean)"
  fi
  local leftover=""
  for k in ${IDENTITY_COURIER_KEYS[@]+"${IDENTITY_COURIER_KEYS[@]}"}; do
    v="$(read_secret_key identity identity-secrets "$k")"
    if [ -n "$v" ]; then
      leftover="${leftover:+$leftover }$k"
    fi
  done
  if [ -n "$leftover" ]; then
    echo "error: identity-secrets still carries courier key(s) after the orphan sweep:$leftover — the patch did not converge" >&2
    return 1
  fi
}

mint_courier_identity_token() {
  log_step "courier's identity credential, minted on this box"
  # THE WARM-BOX SWEEP runs above the guard on purpose: a box installed before
  # the pair landed together may already hold the minted credential (so the
  # guard below returns early) AND the orphaned half-pair. Converging first
  # means the re-run heals the secret even when there is nothing left to mint.
  if [ -z "$KIT_SUBSTRATE_APP_BASE_URL" ]; then
    converge_identity_courier_block || return 1
  fi
  # The guard is the resume path, and it is the VALUE rather than a step flag:
  # a re-run that finds the credential already minted has nothing to mint.
  if [ -n "$(read_secret_key courier courier-secrets COURIER_IDENTITY_TOKEN)" ]; then
    kit_substrate_out "      credential already minted on this box, skipping (rotate by replacing the secret and restarting the pods)"
    return 0
  fi
  # The one operator value this step derives anything from is refused by SHAPE
  # here, before the port-forward and the four API calls, so a typo costs a
  # sentence rather than a minted account and a rollout that never goes Ready.
  validate_app_base_url
  if dry_run "mint courier's API key from identity's own API (register → session → account → api-key), then patch identity-secrets (COURIER_BASE_URL + COURIER_TOKEN + link templates when KIT_SUBSTRATE_APP_BASE_URL is set) and courier-secrets (COURIER_IDENTITY_URL + COURIER_IDENTITY_TOKEN) and restart both deployments"; then
    return 0
  fi

  # The Deployment is created ASYNCHRONOUSLY by Argo, from the Applications
  # step 6 applied — steps 7 through 10 sit between that apply and this watch,
  # and step 8 alone lasts long enough that the race usually wins itself, but
  # "usually" is not a wait. `rollout status` on a missing named object is
  # `NotFound`, exit 1, not a wait (the empty-list no-op branch is the path a
  # named object never takes) — the same class as step 1's node wait and step
  # 8's CNPG pod wait, so the same shape: the Deployment must EXIST first
  # (bounded, above), then its rollout is watched with the part of this step's
  # 360s that is left. A genuinely unsynced Application still fails — exactly
  # as it did before — and now names the Deployment that never appeared
  # instead of a rollout that never started.
  kit_substrate_await_list "$IDENTITY_DEPLOY_TIMEOUT" deployment identity -n identity
  kubectl --kubeconfig="$KUBECONFIG" -n identity rollout status deployment/identity --timeout="$((IDENTITY_ROLLOUT_TIMEOUT))s"

  # Identity is reachable at its cluster-local Service only from inside the
  # cluster, so the box forwards a port to it — the same mechanism the launch
  # harness uses, on the box, with no ingress and no external route.
  local forward_port="${KIT_SUBSTRATE_IDENTITY_LOCAL_PORT:-18080}"
  kubectl --kubeconfig="$KUBECONFIG" -n identity port-forward "svc/identity" "${forward_port}:8080" >/dev/null 2>&1 &
  local forward_pid=$!
  # The forward is torn down on EVERY path out of this function — a mint that
  # fails halfway must not leave an unauthenticated local port listening.
  #
  # THE TRAP REMOVES ITSELF, and that is not tidiness. A `RETURN` trap is
  # GLOBAL: bash runs it after EVERY function return, not only the return of
  # the function that set it. So a bare `trap 'kill "$forward_pid" …' RETURN`
  # fires correctly when this function returns (the `local` is still in scope;
  # measured, the pid is visible) and then fires AGAIN when the CALLER returns
  # — `main`, at the end of the install — where `forward_pid` has left scope and
  # `set -u` turns the reference into `forward_pid: unbound variable`. The trap
  # command itself then fails, and that failure is the process's exit status:
  # the install printed `install.done`, completed all eleven steps, and exited
  # 1. `trap - RETURN` inside the trap makes it run at most once, on the one
  # return where the variable is still in scope.
  trap 'kill "$forward_pid" 2>/dev/null || true; trap - RETURN' RETURN

  # EXISTENCE, THEN USE. `kubectl port-forward` establishes its local listener
  # ASYNCHRONOUSLY — it must reach the API server, resolve svc/identity and dial
  # the pod — so a curl on the next line races it and dies with
  # `curl: (7) Failed to connect to 127.0.0.1 port 18080`. That is a CONNECT
  # failure and it reads identically to "identity refused", which is the wrong
  # diagnosis. Measured live on the box: the step reported "identity would not
  # mint a signup timestamp" while the actual curl was a (7) connect failure.
  # Wait for the local port to accept a connection (bounded), then use it.
  if ! kit_substrate_await_port "$forward_port" 30; then
    echo "error: the port-forward to svc/identity never accepted a connection on 127.0.0.1:${forward_port} — the forward itself failed, not identity" >&2
    return 1
  fi

  local base="http://127.0.0.1:${forward_port}" out token
  # The four calls, each forced by the one before it. The account is courier's
  # and belongs to the mail path and nothing else; the scope is the floor of
  # the vocabulary, because the mint refuses an empty list and the
  # introspection the key is actually used for is not account-scoped.
  out="$(curl -fsS -X POST "${base}/v1/signup-timestamp")" || {
    echo "error: identity would not mint a signup timestamp" >&2
    return 1
  }
  local mint_timestamp mint_signature owner_password
  mint_timestamp="$(printf '%s' "$out" | jq -r '.timestamp // empty')"
  mint_signature="$(printf '%s' "$out" | jq -r '.signature // empty')"
  if [ -z "$mint_timestamp" ] || [ -z "$mint_signature" ]; then
    echo "error: identity's signup-timestamp response carried no pair" >&2
    return 1
  fi
  # The pair must age before it verifies: identity's signup defence waits
  # MinAge (2s) between mint and register — a person needs seconds to fill a
  # form, a bot submits instantly. This mint is a client of the same route, so
  # the defence applies to it, and the wait is the defence working.
  sleep 3
  owner_password="$(openssl rand -hex 24)"
  out="$(curl -fsS -X POST "${base}/v1/users" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg email "owner+substrate@cafaye.local" \
      --arg password "$owner_password" \
      --argjson timestamp "$mint_timestamp" --arg signature "$mint_signature" \
      '{email: $email, password: $password, website: "", timestamp: $timestamp, signature: $signature}')")" || {
    echo "error: identity would not register this box's owner account" >&2
    return 1
  }
  local session
  session="$(curl -fsS -X POST "${base}/v1/session" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg email "owner+substrate@cafaye.local" --arg password "$owner_password" \
      '{email: $email, password: $password}')")" || {
    echo "error: identity would not open a session for this box's owner account" >&2
    return 1
  }
  local session_token
  session_token="$(printf '%s' "$session" | jq -r '.token // empty')"
  if [ -z "$session_token" ]; then
    echo "error: identity's session response carried no token" >&2
    return 1
  fi
  local account_id
  account_id="$(curl -fsS -X POST "${base}/v1/accounts" \
    -H "Authorization: Bearer ${session_token}" -H 'Content-Type: application/json' \
    -d '{"name":"courier"}' | jq -r '.id // empty')" || {
    echo "error: identity would not create this box's account" >&2
    return 1
  }
  [ -n "$account_id" ] || {
    echo "error: identity's account response carried no id" >&2
    return 1
  }
  token="$(curl -fsS -X POST "${base}/v1/accounts/${account_id}/api-keys" \
    -H "Authorization: Bearer ${session_token}" -H 'Content-Type: application/json' \
    -d '{"name":"courier","scopes":["accounts:read"]}' | jq -r '.token // empty')" || {
    echo "error: identity would not mint courier's credential" >&2
    return 1
  }
  [ -n "$token" ] || {
    echo "error: identity's mint response carried no token" >&2
    return 1
  }

  # ONE value per secret, TWO keys per patch — and a PATCH, not a create.
  # `kubectl apply` with a whole Secret object is a REPLACE: writing through one
  # would delete `DATABASE_URL`, `SIGNUP_SIGNING_KEY`, `MFA_ENCRYPTION_KEY` and
  # the OIDC keys from identity-secrets in the same breath. A merge patch adds
  # the keys and touches nothing else, and it is built by `jq` so a token with a
  # quote in it cannot break the JSON or land in an argv
  # (`--patch-file=/dev/stdin` reads it from a pipe; kubectl has no `-`
  # convention for `--patch-file`, so `--patch-file=-` would open a file
  # literally named `-`).
  #
  # EACH PATCH CARRIES A WHOLE PAIR, because the two keys of a pair are one
  # fact with two names: identity refuses to boot with `COURIER_TOKEN` and no
  # `COURIER_BASE_URL` (`loadCourier`: "must both be set, or neither of them"),
  # and courier's `COURIER_IDENTITY_URL` would otherwise fall back to the
  # compose spelling `http://identity:8080`, which does not cross the
  # namespace boundary. Both halves go in ONE patch so no path can write one
  # without the other.
  #
  # IDENTITY'S MAIL PATH IS ALL-OR-NOTHING, AND THE PAIR ALONE IS ONLY HALF OF
  # IT. Wiring the courier block makes `loadCourier` continue into
  # `resolveLinkTemplates` and `resolveInvitationLinkTemplate`, which REQUIRE at
  # least one link template plus `INVITATION_LINK_TEMPLATE`; identity's own
  # config test names the defect — "a base URL and a token with no link template"
  # → `ErrInvalidCourier` (`identity/internal/config/courier_test.go:62`) — and
  # the mirror case, "a link template and a token with no base URL", is refused
  # too. The templates point at the PUBLIC app URL (the launch stack's
  # `APP_BASE_URL`, `launch/docker-compose.launch.yml`), which this installer
  # cannot know and MUST NOT guess: a localhost default would mail every reader
  # to a screen that is not theirs. So the identity patch is gated on the one
  # operator input that makes it true:
  #
  #   * KIT_SUBSTRATE_APP_BASE_URL SET — the pair AND the four templates land in
  #     ONE merge patch, and the legacy RECOVERY_LINK_TEMPLATE an older
  #     installer wrote is deleted in the SAME patch (a `data`-null). One patch
  #     because a base URL and a token with no template is a refusal at boot,
  #     and deriving all four from the one origin is what keeps them from
  #     drifting — while the deleted default is what keeps identity's
  #     shared-default warning from firing on values that are equal on
  #     purpose (see the derivation below).
  #   * KIT_SUBSTRATE_APP_BASE_URL UNSET — identity's courier block is CONVERGED
  #     (converge_identity_courier_block, one `"key":null` merge patch for a
  #     half-pair or stray template, verified by re-read): a COMPLETE pair the
  #     box already carries is left in place and keeps answering, and no new
  #     identity courier key is written. identity's own loader treats
  #     "everything absent" as a supported deployment with no mail path
  #     deployment with no mail path (`loadCourier`'s `present == 0` branch: "all three absent is a deployment
  #     with no mail path, and is supported"), so it BOOTS and every recovery
  #     route answers 503 — the honest state — instead of a rollout that never
  #     goes Ready. Courier's own pair is STILL written below, because
  #     COURIER_IDENTITY_TOKEN is required by courier's runtime regardless
  #     (`courier/config/runtime.exs:227-229`).
  #
  # The templates are passed as `--arg` VALUES rather than written as literals
  # inside the jq program for a load-bearing reason: `tests/substrate_test.sh`'s
  # record tripwire reads the keys out of every `stringData` block with a regex
  # that stops at the first `}`, and a literal `{token}` placeholder in the jq
  # source would truncate that block after the first template. Keeping the
  # placeholders in shell values keeps every key visible to the check.
  if [ -n "$KIT_SUBSTRATE_APP_BASE_URL" ]; then
    local base reset verify change invite identity_patch
    base="${KIT_SUBSTRATE_APP_BASE_URL%/}"
    reset="${base}/reset-password?token={token}"
    verify="${base}/verify-email/confirm?token={token}"
    # PARLOR SERVES THREE OF THESE SCREENS, and the fourth has none. Read off
    # parlor's route table — src/app and src/routes agree, and routeTree.gen.ts
    # with them: /login, /register, /forgot-password, /reset-password,
    # /verify-email, /verify-email/confirm, /invitations/[token], /accounts,
    # /settings, /admin (/healthz, /readyz) — and no email-change route in
    # either tree, nor in parlor's client (which never calls
    # POST /v1/email-changes/*):
    #   PASSWORD_RESET_LINK_TEMPLATE → /reset-password, the screen that spends
    #     a password-reset token (POST /v1/password-resets/confirm answers 404
    #     for any other purpose's token).
    #   EMAIL_VERIFICATION_LINK_TEMPLATE → /verify-email/confirm, the screen
    #     that spends an address-confirmation token.
    #   EMAIL_CHANGE_LINK_TEMPLATE → /verify-email/confirm as well. Parlor
    #     carries no email-change screen, so there is no honest distinct value
    #     to write, and the installer must not invent one: a path parlor does
    #     not serve is a browser 404. This is a SUBSTITUTION and it is
    #     documented as one — an email-change token spent there answers
    #     identity's single ErrTokenNotFound, and the screen renders its one
    #     generic "this link cannot be used" sentence: a wrong-flow dead end on
    #     a served page, which is a materially better failure than a 404 and is
    #     not dressed up here as more than it is. Same spelling as the launch
    #     stack (`launch/docker-compose.launch.yml`), which argues it at length.
    #   RECOVERY_LINK_TEMPLATE is NOT written. It is the fallback for every
    #     purpose with no variable of its own, and every purpose identity
    #     delivers has one here — the end-state identity's own wiring test
    #     blesses ("all three per-purpose variables set, the legacy one
    #     deleted", cmd/identity/link_template_wiring_test.go). Identity's
    #     warning compares VALUES, so writing the legacy default alongside the
    #     per-purpose templates re-fires it even when every purpose is
    #     configured — that three-identical-string shape is the live-box
    #     warning this closes. The patch deletes a legacy default an older
    #     installer wrote instead: a null under `data`, because a null under
    #     `stringData` merges into a field the stored object does not carry and
    #     deletes nothing (see converge_identity_courier_block). A future
    #     purpose identity adds then refuses at boot naming its variable,
    #     instead of silently inheriting a screen that cannot redeem it.
    change="$verify"
    invite="${base}/invitations/{token}"
    identity_patch="$(jq -nc \
      --arg url "$COURIER_URL" --arg t "$token" \
      --arg reset "$reset" --arg verify "$verify" --arg change "$change" \
      --arg invite "$invite" \
      '{"stringData":{
        "COURIER_BASE_URL":$url,
        "COURIER_TOKEN":$t,
        "PASSWORD_RESET_LINK_TEMPLATE":$reset,
        "EMAIL_VERIFICATION_LINK_TEMPLATE":$verify,
        "EMAIL_CHANGE_LINK_TEMPLATE":$change,
        "INVITATION_LINK_TEMPLATE":$invite
      },"data":{
        "RECOVERY_LINK_TEMPLATE":null
      }}')"
    printf '%s' "$identity_patch" |
      kubectl --kubeconfig="$KUBECONFIG" -n identity patch secret identity-secrets \
      --type=merge --patch-file=/dev/stdin
    kubectl --kubeconfig="$KUBECONFIG" -n identity rollout restart deployment/identity
  else
    # The sweep already ran above the guard; it runs again here so the branch
    # itself converges and re-verifies after the mint (a no-op when the first
    # run removed everything, since the mint writes no identity courier key).
    converge_identity_courier_block || return 1
  fi
  printf '%s' "$(jq -nc --arg url "$IDENTITY_URL" --arg t "$token" \
    '{"stringData":{"COURIER_IDENTITY_URL":$url,"COURIER_IDENTITY_TOKEN":$t}}')" |
    kubectl --kubeconfig="$KUBECONFIG" -n courier patch secret courier-secrets \
    --type=merge --patch-file=/dev/stdin
  kubectl --kubeconfig="$KUBECONFIG" -n courier rollout restart deployment/courier
  if [ -n "$KIT_SUBSTRATE_APP_BASE_URL" ]; then
    kit_substrate_out "      credential minted on this box; identity has a TRUE mail path (four link templates derived from ${KIT_SUBSTRATE_APP_BASE_URL}, legacy shared default deleted) and courier holds the same credential, both deployments restarted"
  elif [ -n "${IDENTITY_MAIL_PATH_KEPT:-}" ]; then
    kit_substrate_out "      credential minted on this box; courier holds it, identity KEEPS its working mail path (this run had no KIT_SUBSTRATE_APP_BASE_URL to rewrite it with, so nothing was rewritten) — every recovery route keeps answering; courier restarted"
  else
    kit_substrate_out "      credential minted on this box; courier holds it, identity's mail path is OFF BY DESIGN (set KIT_SUBSTRATE_APP_BASE_URL to turn it on), courier restarted"
  fi
}

# --- step 13: converge the residual ReplicaSets ---------------------------------
# MEASURED, ON THE LIVE BOX. The gateway namespace held five ReplicaSets for
# one Deployment at `spec.replicas: 1`:
#
#   NAME                DESIRED  CURRENT  READY  AGE
#   gateway-6d5d9495df  1        1        1      2m52s   <-- the digest-pinned RS
#   gateway-6f9c8bfdd   0        0        0      10h     <-- the bare cafaye/gateway:0.1.0 (Docker Hub) RS
#   gateway-7cd45d569   0        0        0      6h52m
#   gateway-858665c58b  1        1        0      93m     <-- a tag-based RS Argo keeps making current
#   gateway-8977f6fcb   0        0        0      4m23s   <-- a mis-transcribed digest
#
# Two live ReplicaSets for one replica: the Deployment controller kept an RS
# holding a pod (`0/1 Running`, against the OLD image, on a readiness probe
# that can never succeed) that the Deployment no longer names. Each generation
# leaves one behind — the Docker Hub RS sat in ImagePullBackOff for seven
# hours and 46 minutes before it was retired — and nothing shrinks the number
# as the box ages, because Argo CD converges the Applications (HELM's
# objects), not the ReplicaSets a previous Deployment revision left behind.
#
# WHAT A RESIDUAL RS IS. One rule, read three ways: an RS owned by one of the
# four service Deployments is residual when it is LIVE (its spec.replicas is
# above 0 — it names pods it wants) and its pod template is NOT the
# Deployment's current one. The CURRENT RS is the owned RS whose pod spec
# matches the Deployment's; its pod-template-hash is read off it for the
# report. An RS at 0 names no pods and is left alone — it is history, not
# load — and an RS with no ownerReference to the Deployment is not this
# Deployment's to judge.
#
# WHY THE HASH IS READ OFF THE CURRENT RS AND NOT THE DEPLOYMENT. The
# Deployment object carries no pod-template-hash — the controller stamps that
# label on the RS and its pods, never on the Deployment's own template. So
# "current" is decided by pod-spec equality with the Deployment (the object
# this repository's Applications actually write), and the hash is what is
# PRINTED, so the operator sees which generation each RS belongs to.
#
# WHY SCALE TO 0 AND NOT DELETE. The box was fixed by hand this circle by
# scaling the residual to 0, and that is what the step does: the RS object
# stays (with its revision history — `kubectl rollout history` keeps working),
# its pods terminate gracefully through the controller, and the write is
# reversible where a delete is not. A second run finds no live residual and
# changes nothing, which is the idempotence the suite asserts.
#
# THE TWO DEPLOYMENTS THIS STEP NEVER TOUCHES. A Deployment at `spec.replicas:
# 0` is OPERATOR INTENT — a deliberately scaled-down service is a state, not a
# defect, and deleting its RSs' pods would destroy the state the operator
# asked for — so the whole Deployment is skipped. A Deployment mid-rollout
# (`status.updatedReplicas` != `spec.replicas`) belongs to its controller for
# the duration: converging an RS the controller is about to scale itself would
# fight the rollout, so the step reports it and moves on. A Deployment Argo
# has not synced yet (steps 7-11 sit between the Applications apply and here)
# is neither: it is skipped quietly, and the next re-run meets it.
#
# WHY NO GUARD. There is no one object whose presence answers "converged" — a
# box with no residuals and a box that never synced gateway give the same
# probe. The step always runs its reads (eight API round trips) and reports
# TIMED, never `skipped`: like the AppProject reapply in step 4, real work
# clears STEP_SKIPPED rather than claiming it.
converge_residual_replicasets() {
  log_step "the residual ReplicaSets of the four service Deployments (identity, gateway, courier, parlor)"
  if dry_run "list the ReplicaSets of identity, gateway, courier and parlor, report each one holding a pod under an old pod template, and scale it to 0"; then
    return 0
  fi
  local pair
  for pair in identity/identity gateway/gateway courier/courier parlor/parlor; do
    converge_one_deployment_rs "${pair%%/*}" "${pair#*/}" || return 1
  done
  # Real work by construction — the reads above ran on every box — so the
  # step is timed rather than reported as a skip, the same clearing the
  # AppProject reapply in step 4 carries.
  STEP_SKIPPED=0
}

# converge_one_deployment_rs <namespace> <deployment> — scale that
# Deployment's live non-current ReplicaSets to 0, reporting each with its
# image, its age and its pod-template-hash. Never touches the current RS,
# never touches a deliberately scaled-to-zero Deployment, never touches a
# rollout in flight. Exit 0 in all three skips: none of them is a failure.
converge_one_deployment_rs() {
  local ns="$1" dep="$2"
  local dep_json
  # Not synced yet is not a defect — see the step note above.
  dep_json="$(kubectl --kubeconfig="$KUBECONFIG" -n "$ns" get deployment "$dep" -o json 2>/dev/null)" || return 0
  [ -n "$dep_json" ] || return 0
  local desired
  desired="$(printf '%s' "$dep_json" | jq -r '.spec.replicas // 1')"
  if [ "$desired" = "0" ]; then
    kit_substrate_out "      ${ns}/${dep} is scaled to 0 by its operator — leaving its ReplicaSets alone"
    return 0
  fi
  local updated
  updated="$(printf '%s' "$dep_json" | jq -r '.status.updatedReplicas // 0')"
  if [ "$updated" != "$desired" ]; then
    kit_substrate_out "      ${ns}/${dep} is mid-rollout (updated ${updated} of ${desired}) — leaving its ReplicaSets to the controller"
    return 0
  fi
  local current_spec
  current_spec="$(printf '%s' "$dep_json" | jq -c '.spec.template.spec')"
  local current_hash
  current_hash="$(kubectl --kubeconfig="$KUBECONFIG" -n "$ns" get rs -o json |
    jq -r --arg dep "$dep" --argjson current "$current_spec" '
      [(.items // [])[]
       | select(((.metadata.ownerReferences // []) | map(select(.name == $dep)) | length) > 0)
       | select((.spec.replicas // 0) > 0)
       | select(.spec.template.spec == $current)
       | .metadata.labels."pod-template-hash" // empty]
      | .[0] // empty
    ')"
  local rs_json
  rs_json="$(kubectl --kubeconfig="$KUBECONFIG" -n "$ns" get rs -o json)"
  # No owned live RS matches the current pod spec. Guessing which live RS is
  # "current" is the defect this step could introduce, so the step converges
  # nothing and says so — the controller owns every live RS until one of them
  # matches the template the Deployment names.
  if [ -z "$current_hash" ]; then
    local live_count
    live_count="$(printf '%s' "$rs_json" | jq -r --arg dep "$dep" '
      [(.items // [])[]
       | select(((.metadata.ownerReferences // []) | map(select(.name == $dep)) | length) > 0)
       | select((.spec.replicas // 0) > 0)] | length')"
    if [ "$live_count" != "0" ]; then
      kit_substrate_out "      ${ns}/${dep} has ${live_count} live ReplicaSet(s) and none matches the current pod template — leaving them to the controller"
    fi
    return 0
  fi
  local residual_found=0
  local rs_name rs_hash rs_image rs_created
  while IFS=$'\t' read -r rs_name rs_hash rs_image rs_created; do
    [ -n "$rs_name" ] || continue
    residual_found=1
    kit_substrate_out "      residual ${ns}/${rs_name} (deployment ${dep}, image ${rs_image}, created ${rs_created}, pod-template-hash ${rs_hash}): scaling to 0"
    if dry_run "scale replicaset/${rs_name} -n ${ns} to 0 (residual: image ${rs_image}, created ${rs_created}, pod-template-hash ${rs_hash})"; then
      continue
    fi
    kubectl --kubeconfig="$KUBECONFIG" -n "$ns" scale "replicaset/${rs_name}" --replicas=0
  done <<EOF
$(printf '%s' "$rs_json" | jq -r --arg dep "$dep" --arg hash "$current_hash" '
  (.items // [])[]
  | select(((.metadata.ownerReferences // []) | map(select(.name == $dep)) | length) > 0)
  | select((.spec.replicas // 0) > 0)
  | select((.metadata.labels."pod-template-hash" // "") != $hash)
  | [.metadata.name,
     (.metadata.labels."pod-template-hash" // "unlabelled"),
     ((.spec.template.spec.containers // [])[0].image // "unknown"),
     (.metadata.creationTimestamp // "unknown")]
  | @tsv')
EOF
  if [ "$residual_found" -eq 0 ]; then
    kit_substrate_out "      ${ns}/${dep}: no residual ReplicaSets (live generations match pod-template-hash ${current_hash})"
  fi
}

# --- main -------------------------------------------------------------------
main() {
  # --headless is the agent-driven mode: JSONL on stdout, a receipt on disk.
  # The flag and the HEADLESS=1 environment variable are the same switch —
  # the flag for a human typing it, the variable for `caf box apply`.
  while [ $# -gt 0 ]; do
    case "$1" in
      --headless) HEADLESS=1; shift ;;
      *)
        printf 'error: unknown argument "%s"\n' "$1" >&2
        printf '  usage: install.sh [--headless]\n' >&2
        exit 1
        ;;
    esac
  done

  # The clock starts before preflight, so the total is the install's
  # start-to-done and not just the steps'.
  INSTALL_START_MS="$(kit_substrate_now)"

  # The receipt opens the install: it names the phase, the next step and the
  # (empty) input needed, so a reader — human or agent — knows what this run
  # is and where it starts before the first step emits.
  R_PHASE="install"
  R_NEXT="k3s ${K3S_VERSION} — single node, sqlite datastore"
  R_STATUS="running"
  kit_substrate_write_receipt
  if [ "$HEADLESS" -eq 1 ]; then
    kit_substrate_emit install.start "install begins: ${TOTAL} steps, receipt at ${RECEIPT_PATH}"
  fi

  CURRENT_PHASE="preflight"
  preflight
  # One line per step, and the phase on its own line above it. The phase is
  # what the receipt and the JSONL name, and it is deliberately a separate
  # statement rather than a `PHASE=x; step` compound: tests/substrate_test.sh
  # asserts `^  install_nats$` in main, and a compound would satisfy nobody
  # while looking tidier.
  CURRENT_PHASE="k3s"
  install_k3s
  CURRENT_PHASE="cert-manager"
  install_cert_manager
  CURRENT_PHASE="cnpg"
  install_cnpg
  CURRENT_PHASE="argocd"
  install_argocd
  CURRENT_PHASE="pull-secret"
  install_pull_secret
  CURRENT_PHASE="applications"
  install_applications
  CURRENT_PHASE="cluster-issuers"
  install_cluster_issuers
  CURRENT_PHASE="postgres"
  install_postgres_cluster
  CURRENT_PHASE="redis-and-secrets"
  install_redis_and_secrets
  CURRENT_PHASE="migrations"
  install_migrations
  CURRENT_PHASE="nats"
  install_nats
  CURRENT_PHASE="courier-mint"
  mint_courier_identity_token
  CURRENT_PHASE="rs-residual"
  converge_residual_replicasets

  # Close the LAST step (every other step was closed by the next one's
  # log_step), then read the total off the same clock. `total` and the steps
  # come from one accounting, so the final event's total can never disagree
  # with the table it carries.
  kit_substrate_step_finalize
  local total_seconds
  total_seconds="$(kit_substrate_seconds "$(( $(kit_substrate_now) - INSTALL_START_MS ))")"

  # The receipt closes the install: phase complete, no next step, and the
  # human sent to the Argo CD UI — the one place a person goes now that the
  # box has done its work.
  R_PHASE="complete"
  R_STATUS="complete"
  R_NEXT=""
  R_INPUT=""
  # The core install ships no UI: no argocd-server, no dex, and no
  # argocd-initial-admin-secret (that secret is minted by the API server at
  # startup, and there is no API server). The human destination is the
  # Applications themselves — the state a person reads to watch the fleet
  # reconcile, and the same command the README gives.
  R_HUMAN="watch Argo CD reconcile the fleet: kubectl -n argocd get applications"
  R_MESSAGE="substrate is up: k3s ${K3S_VERSION}, cert-manager ${CERT_MANAGER_VERSION}, CloudNativePG ${CNPG_VERSION}, Argo CD ${ARGOCD_VERSION}"
  kit_substrate_write_receipt
  if [ "$HEADLESS" -eq 1 ]; then
    kit_substrate_emit readiness "$(kit_substrate_readiness_summary)" "$(kit_substrate_readiness_json)" # honest-done
    kit_substrate_emit install.done "$R_MESSAGE" \
      ",\"seconds\":${total_seconds},\"steps\":$(kit_substrate_steps_json)"
  else
    kit_substrate_out ""
    kit_substrate_out "substrate is up: k3s ${K3S_VERSION}, cert-manager ${CERT_MANAGER_VERSION}, CloudNativePG ${CNPG_VERSION}, Argo CD ${ARGOCD_VERSION}"
    kit_substrate_out "Argo CD state:  kubectl -n argocd get applications"
    kit_substrate_out ""
    kit_substrate_print_table "$total_seconds"
    kit_substrate_readiness_final # honest-done
  fi
}

main "$@"
