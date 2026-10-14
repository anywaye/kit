## Unreleased

### Substrate

- **Step 5 asks GHCR first, and only reaches for the capability when an
  artifact is private.** The pull-secret step demanded a single-use,
  minutes-lived, box-bound capability before looking at a single artifact —
  a required ritual that buys nothing where every artifact is public (a
  stale/wrong pull secret does not break a public pull; GHCR falls back to
  anonymous). Now the step derives every GHCR chart and image the
  Applications name (`repoURL`/`targetRevision` plus the image each cafaye
  chart runs — 14 rows, no flag) and asks GHCR for an anonymous token and a
  manifest HEAD per artifact, both bounded. All public: an empty-auths pull
  secret through the same pipe into the same namespaces, with no box id, no
  capability and no exchange. One private: today's exchange unchanged, its
  refusals now naming which artifacts need the credential, and the readiness
  report naming the path taken (`registry: …` / `"registry_path"`). Measured
  today: 11 of 14 anonymously fetchable; `cafaye/box`, `cafaye/charts/box`
  and `cafaye/charts/pantry` refuse anonymous fetch, so installs pulling
  them still take the capability path. See
  `REPORT-roll-c5-public-artifacts.md`.

- **pantry deploys: the registry the routes already named.** gateway has
  published `/v1/pantry` (public) and `/v1/pantry-writes` at
  `http://pantry:8080` since the routes were written, and no pantry has
  ever existed on the box — `GET /v1/pantry` answers gateway's own 503
  ("the service this request needs could not be reached"). The service
  was never deployed because nothing ever published it (no `publish.yml`,
  so no image and no chart in the registry — both token scopes still
  DENIED at this writing) and the substrate named nothing of it. Now:
  a pantry `Application` (`oci://ghcr.io/cafaye/charts/pantry`,
  `targetRevision` 0.1.0) with `imagePullSecrets` pointed at the
  installer-exchanged `ghcr-pull-secret`; a pantry database, owner/app
  roles, the five NOLOGIN RLS roles and three memberships in the Cluster
  manifest; `pantry-secrets` (`PANTRY_DATABASE_URL` + the telemetry
  off-switch — the write path and tier 2 stay unmounted by design); and
  a step-10 migrate Job running the service's own `service migrate` as
  the OWNER role. `KIT_SUBSTRATE_DATABASES` is
  `identity,gateway,courier,parlor,pantry`, and the refusal names the
  new set. The pantry half (publish workflow, digest-pinned chart,
  owner-runnable migrations) ships in `cafaye/pantry`.

- **`KIT_SUBSTRATE_KUBECONFIG`: the substrate installs into a cluster that is
  already there.** One environment variable names a kubeconfig for a cluster that
  already exists, and the substrate runs against it: no k3s is installed on the
  machine the script runs on, and steps 1-3 ask the **cluster** whether the
  component is there rather than asking the host whether `/usr/local/bin/k3s` is
  — the one host probe in the guard set, and the reason a macOS workstation could
  not run the substrate at all (it answered "absent" and the step went off to
  install a Linux host's k3s on a Mac). One input, one derivation
  (`CLUSTER_SUPPLIED`), one code path: the guards, the other ten steps, the
  refusals, the per-step timing events, the receipt and the JSONL are the same
  code. The preflight's split is by what each check is a fact ABOUT — root,
  Linux, arch and memory are the host's and are refusals only when this script
  installs k3s on it; curl, jq, openssl and ghcr.io are the run's and hold in
  both shapes — and a supplied cluster with no Node refuses naming the input
  rather than provisioning the host. Unset is the product: a fresh Linux box is
  provisioned exactly as before, every host probe included. Env var, not a flag,
  on the two precedents already in the file (`KIT_SUBSTRATE_RECEIPT` is
  path-valued, `DRY_RUN` is a runtime switch), and deliberately not the ambient
  `KUBECONFIG`. This is the entry a developer's k3d cluster needs and it is the
  same entry a customer with their own Kubernetes needs — theirs is not a fresh
  box either. Proved by `tests/substrate_test.sh` §16, with the packet's own red
  control beside it: with the input unset this workstation still refuses
  (`must run as root — k3s installs to /usr/local and writes the kubeconfig`),
  because the host probe is still what decides.
- **Headless stdout is a CHANNEL, and the way that is true is a file descriptor
  rather than a policy.** Measured on a local k3d cycle: a headless run's stdout
  carried 26 lines of `kubectl apply`'s own output between step 3's start and done
  events, and the first consumer to read the stream — `jq` over the file — died
  with `parse error: Invalid numeric literal at line 7, column 22`. The events
  around the garbage were correct, so the install looked healthy; the stream
  itself was unreadable, and the box's own `caf box apply` reads it. The static
  check already refuses an `echo` or a `printf` outside the two writers, so the
  only way to break the channel is a command this file **spawns**, and no audit of
  its own statements can see those: `main` saves the real stdout on fd 3 in
  headless mode and the two event writers target the saved descriptor, so
  every tool's progress line lands beside the operator's output instead of inside
  the event stream.
- **`templates/substrate/local-cycle.sh` — the substrate on a cluster that is
  already on this machine, in one command.** Reuses (or creates) a k3d cluster,
  writes that cluster's kubeconfig with `k3d kubeconfig get` to scratch keyed to
  the worktree — touching neither the ambient `~/.kube/config` nor a second git
  repository nested in a checkout — runs the same installer `--headless` against
  it, and prints the per-step table read back out of the same JSONL a box emits,
  the wall clock, the receipt and `kubectl -n argocd get applications`. Measured:
  a warm cycle is 2 s, a cold one (cluster created, the three operators applied
  and waited on) is 3m06s of substrate work before it stops at step 4, against the
  ~10-minute VPS cycle it replaces. k3d lives in that script and nowhere else —
  the installer needs a kubeconfig, which is what a customer with their own
  Kubernetes has too. Its cluster probe reads a variable rather than a pipe:
  `k3d cluster list -o json | grep -q name` under `set -o pipefail` reported an
  existing cluster as absent on one of five identical probes, because `grep -q`
  exits on its first match, k3d dies of SIGPIPE mid-document, and pipefail
  promotes 141 — and the next line was `k3d cluster create`, which FATALs on a
  name that is taken.
- **The readiness preflight reads INGRESS hosts, so the box reports every
  condition it has.** The live box's readiness event named 2 pending hosts
  (`app.cafaye.com`, `auth.cafaye.com`) while `kubectl get ingress -A` on the
  same box held three — gateway's `api.cafaye.com` among them, its Certificate
  READY=False for 98 minutes. An Ingress host is a bare hostname
  (`spec.rules.host`, or a chart's `host` value) and the URL grep the
  derivation used cannot match one by construction — the pattern requires a
  scheme; `app.cafaye.com` was caught only because
  `KIT_SUBSTRATE_APP_BASE_URL` happens to name parlor's Ingress. The
  derivation is now `kit_substrate_intended_host_table` — `host<TAB>source`
  rows from three sources: the operator's two URLs, public https hosts in the
  Applications' `helm.values`, and a NEW `host:` key parsed from the
  manifests and the charts' values (key lines after indentation and an
  optional list dash, over comment-stripped text). `kit_substrate_intended_hosts`
  stays the table's first column, so every caller keeps the hosts-only
  contract; dedup is by host with the first source winning, so a host named
  two ways is reported once in a stable order. The preflight and the final
  report name the source of each host, and the count follows the list — 3 on
  the live box's shape. Stated rather than hidden: an Ingress host that exists
  only inside a chart's templates is not readable by a box-side derivation;
  where a chart's values carry the host it is read, and otherwise the fix
  belongs in the tree — never in a literal here. `kit_substrate_is_checkable_host`
  now also drops `127.*`, which resolves on the box by construction. Proved by
  `tests/substrate_test.sh` §27 (continued): five greens (both host shapes,
  the URL sources beside them, the once-per-dual-named-host count, the
  in-cluster/localhost/loopback/single-label exclusions, the no-comment
  over-reporting control, the count unit) and two reds — the master-shaped
  URL-only derivation and a loose-grep mutant that reads a commented host —
  each asserting its own premise before it runs. 346 passed, 0 failed.

- **Publish writes the image's DIGEST into the chart it pushes, so a new build
  is a textual diff Argo rolls.** Measured on the live box: the registry's
  `ghcr.io/cafaye/gateway:0.1.0` held `sha256:c264…37165` (the merged Redis
  AUTH fix) while the node ran `sha256:8e60…e79b`, six hours older. Both
  reasons nothing closed the gap were structural: the `0.1.0` tag is
  overwritten on every master push (it is this path's own `appVersion`
  hand-off), and charts pinned the image by that tag, so the rendered
  Deployment was textually IDENTICAL before and after a build — Argo's diff
  reported `Synced` with no rollout and `imagePullPolicy: IfNotPresent`
  re-served the stale copy on every restart. `publish.reusable.yml` now hands
  the image job's build output (`needs.image.outputs.digest`) to the chart
  job, whose new `pin the image by digest` step writes it into the chart's
  `values.yaml` as `image.digest` BEFORE `helm package` — a package is a
  tarball of the directory, so an edit afterwards would pin nothing. The
  pushed chart therefore names the bytes the registry holds beside it, and
  the chart VERSION is unchanged, so the substrate Applications'
  `targetRevision: 0.1.0` still resolves — the chart's CONTENT changes under
  a fixed tag and the diff fires. The step refuses a digest that is not
  `sha256:<64 hex>`, replaces a committed `digest:` line (refusing a file
  with two), inserts one for a chart that has not adopted the field, and
  notes-and-skips a chart with no `image:` block. An empty input — a direct
  caller, or a `push: false` run, where the image workflow's digest output is
  empty because nothing was pushed — packages the chart as committed, which
  is why every service keeps a committed digest. Residue, stated: the OCI tag
  `0.1.0` is still overwritten per push; the Application notices because the
  chart content changes and a refresh re-resolves it. Assigned, not asserted
  by eye: `tests/publish_seam_check.sh` now proves the seam and adds five red
  controls — the image workflow's `digest` output deleted, the chart job's
  `needs.image.outputs.digest` hand-off removed, the writing step deleted, the
  writing step moved after `helm package`, and its `sha256:<64 hex>` refusal
  weakened — each of which must go RED under the same assertions the real tree
  passes. The previous attempt left the step reachable only by review; a check
  that passes because the field is absent is worse than no check.

- **A long-lived box accumulates ReplicaSets its Deployments no longer name.**
  The gateway namespace on Contabo held five ReplicaSets for one Deployment
  at `spec.replicas: 1` — two of them live, the older on an image nobody
  asked for, burning CPU on a readiness probe that could never succeed, with
  the Docker Hub generation sitting in `ImagePullBackOff` for seven hours
  and 46 minutes. Argo CD converges the Applications, not the ReplicaSets a
  previous revision left behind, so step 13 now converges them:
  `converge_residual_replicasets` reads each of the four service
  Deployments' `spec.replicas` and pod spec, finds the owned live RS whose
  pod spec matches (reading its pod-template-hash for the report — the
  Deployment object carries none), and scales every other live RS to 0,
  printing each with its image, age and Deployment. Scale, not delete: the
  revision history stays, pods terminate gracefully, and a second run
  changes nothing. A Deployment at `replicas: 0` is operator intent and is
  skipped whole; a mid-rollout Deployment is left to its controller; an
  unsynced Deployment is skipped quietly. `tests/substrate_test.sh` §26
  proves it against a file-backed mock: reported and converged, idempotent,
  current/scaled-down/mid-rollout/unsynced untouched, dry run prints and
  changes nothing, and two red controls (master shape without the step
  leaves the residual; an inverted hash check converges the current RS).
  See `REPORT-roll-c5-rs-residual.md`.

- **The orphan sweep deleted a WORKING mail path and called it leftovers.**
  The live Contabo box carries a complete seven-key courier block
  (`COURIER_BASE_URL` and `COURIER_TOKEN` both present, five link templates
  derived from `https://app.cafaye.com`) and identity boots reporting
  "account recovery can send all four messages through courier". With
  `KIT_SUBSTRATE_APP_BASE_URL` unset the sweep collected all seven keys and
  deleted them as "leftovers from an installer that wrote half a pair" —
  a provenance it never checked — with no line saying the box went from a
  working mail path to 503 on every recovery route. `converge_identity_courier_block`
  now classifies first, mirroring `loadCourier`'s
  `present != 2` rule: a half-pair or stray template is swept exactly as
  before (deleted key by key, restart, read-back still fails the step naming
  leftovers); a complete pair STAYS — nothing deleted, identity not
  restarted — and the run reports the kept working mail path, names
  `KIT_SUBSTRATE_APP_BASE_URL` as the variable that would rewrite it, and
  says nothing was removed. The mint's closing line follows the same split
  (kept path vs off-by-design). `tests/substrate_test.sh` §18e proves it:
  half-pair still swept with only removed keys named, complete pair kept
  with the rewriting variable named, empty run says nothing removed, and two
  red controls (classification disabled deletes the pair; orphan sentence
  planted on a kept path). The OIDC three-key control's fixture no longer
  reads `HEAD~1` — the first commit after the oidc-four merge shifted the
  parent onto the four-key tree and turned it red — it locates the commit
  that wired `OIDC_LOGIN_UI_URL` and reads that commit's parent. See
  `REPORT-roll-c5-sweep-honest.md`.
- **The glob-fixed AppProject never reached a box that already had Argo CD, so
  every Application stayed `Unknown: repo … is not permitted in project
  'default'`.** `install.sh` step 4's guard answers *is the operator installed*
  (a probe of `deployment/argocd-repo-server`) and it wrapped the whole step,
  including `kubectl apply -f appproject.yaml`. The live Contabo box therefore
  carried the pre-glob `sourceRepos` —
  `["https://grafana.github.io/helm-charts", "https://prometheus-community.github.io/helm-charts", "oci://ghcr.io/cafaye/charts"]` —
  while this repository had already written `oci://ghcr.io/cafaye/charts/*`, and
  the only way to land the fix was to delete Argo CD. **A guard that covers an
  operator install and a policy file conflates two lifetimes**, so the AppProject
  apply moved out of the operator's `if`: the OPERATOR stays guarded (a warm box
  still re-applies no remote manifest) and the PROJECT is re-applied on every
  run, below the grouped wait and before step 6's Applications — the same
  convergence mechanism step 6 itself uses. A second guard on the project's own
  existence was rejected because it answers "present" on the box holding the
  *wrong* project. `tests/substrate_test.sh` §26 runs step 4 against a warm box
  that has Argo CD and the stale project and asserts the result permits every
  Application's `repoURL` under §21's glob-aware algorithm, with the pre-fix
  installer as the red control, plus a DRY_RUN plan half that fires with every
  guard forced present.- **A warm box kept the orphaned half of identity's courier pair, and no
  re-run cleared it.** An older installer wrote `COURIER_TOKEN` without
  `COURIER_BASE_URL`; the live box crashloops identity on it
  (`loadCourier`: "must both be set, or neither of them"), and the step's
  unset branch wrote nothing, so every re-run preserved the orphan. Step 12
  now converges the block via `converge_identity_courier_block`: with
  `KIT_SUBSTRATE_APP_BASE_URL` unset it deletes whichever of the seven block
  keys are present in one `"key":null` merge patch under `data` (nulls go
  under `data`, not `stringData`, which is write-only and would delete
  nothing), re-reads to verify the block is empty, fails naming leftovers
  otherwise, and restarts identity. The sweep runs above the mint guard so a
  box that already minted still heals. `tests/substrate_test.sh` §18d proves
  green removal (unrelated keys kept, courier pair written, restart issued)
  with a neutered-list red control, and the patch-convention check pins the
  data/stringData distinction for both mocks.=======
- **`install.done` no longer claims success on a box that cannot become
  Ready.** The live Contabo box finished the install with exit 0 while Argo
  showed gateway Synced/Degraded and its pods logged `Readiness probe
  failed ... 503` 1564 times over four hours — two silent causes: ACME
  HTTP-01 could never self-check (`lookup api.cafaye.com ...: no such host`,
  DNS never pointed at the box) and gateway's `/readyz` could never pass
  (identity serves its JWKS route only when
  `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER` is set, and it was not). Neither is
  refused — a firewalled box is legitimate and an issuer must not be guessed
  — so the installer now REPORTS: preflight resolves the intended hosts read
  out of what it writes (the two operator URLs plus public hosts in the
  Applications' `helm.values`, never a second list) and names each
  unresolving host with its consequence; the done report carries a `THIS BOX
  WILL NOT FULLY SERVE UNTIL` section beside the step times; and headless
  stdout gains a `readiness` event with the named field
  `tls_pending_hosts` beside `oidc_configured`. `tests/substrate_test.sh`
  §25 proves it with three green checks, the headless event check, the
  resolving-host no-warn control, the intended-hosts unit, and four red
  controls against the master-shaped fixture. See
  `REPORT-roll-c5-honest-done.md`.
- **The AppProject permitted the registry ROOT while every Application named
  its own chart's PATH, so the controller refused all eight Applications.**
  A sibling packet moved each Application's OCI `source.repoURL` from
  `oci://ghcr.io/cafaye/charts` to `oci://ghcr.io/cafaye/charts/<chart>`
  (Argo resolves an OCI source's revision against the full path), and
  `manifests/argocd/appproject.yaml` — written before that change — still
  listed the bare root. The box's symptom was
  `application repo oci://ghcr.io/cafaye/charts/gateway is not permitted in
  project 'default'` on every Application; the name-equality check in §21 could
  not see it, because the project and Applications agree on the name and
  disagree on the sources. **`sourceRepos` now lists
  `oci://ghcr.io/cafaye/charts/*`** — a PATTERN, not four enumerated chart
  names, so a fifth service needs no edit here, and **not a bare `*`**: Argo CD
  v3.5.4 (`pkg/apis/application/v1alpha1/app_project_types.go`
  `IsSourcePermitted`, `util/glob.Match(pattern, value, '/')`) matches
  `sourceRepos` with `/` as the glob separator, so `*` covers exactly one
  chart-name segment and cannot cross a `/` into another registry, org or
  nested path. `tests/substrate_test.sh` §21 now asserts every Application's
  `source.repoURL` is permitted by the project's patterns (the same
  normalise-then-glob algorithm the pinned Argo uses), with the pre-fix
  bare-root pair as a red control, a foreign-registry Application as a red
  control, a nested OCI path as a red control (the separator), and a fifth
  chart as a green control (the pattern, not an enumeration).

- **The image workflow's `add the chart's appVersion as a tag` step held a
  quoted assignment split across two physical lines, and `tests/validate.sh`
  § "every run: body" mis-read it as a prefix assignment (`tags="$tags` as the
  assignment, `$IMAGE:…` as its command) and went red on every run — including
  master, so a green gate proved nothing about the branch's own substrate work.
  The assignment is now `tags="$(printf '%s\n%s' "$tags" "$IMAGE:…")"` — the
  same bytes, without the open-quote newline that confused the check, and the
  `every run:` section is green.**

- **Every chart dialled a bare service name, and every service is in its own
  namespace — so no cross-service address resolved on a box.** The substrate
  puts `identity`, `gateway`, `courier` and `parlor` each in a namespace of its
  own and the data plane in `data`. Kubernetes limits a DNS query that names no
  namespace to the CALLER's, so the compose spelling — a bare `identity`,
  `redis`, `postgres-rw`, `pantry` — resolves only inside a namespace of that
  exact name. Measured on a completed install, gateway's ConfigMap carried
  `IDENTITY_URL: http://identity:8080` and a `ROUTE_TABLE` full of
  `http://pantry:8080`, and gateway's `/readyz` answered
  `{"deps":{"identity":"unavailable","redis":"unavailable"}}`; the same defect
  appears at every peer, and each one is a service that boots and never becomes
  Ready. **The substrate owns the namespace layout, so the substrate now spells
  the box's addresses** — in each Application's `spec.source.helm.values`, the
  file kit already owns, so no chart learns a namespace it cannot know:
  gateway's Application sets `IDENTITY_URL` and `IDENTITY_JWKS_URL`, and
  parlor's sets the `IDENTITY_URL` **nothing was setting at all** (parlor's
  chart ships `env: {}` and `parlor-secrets` carried no identity address, so
  parlor fell back to the compose spelling and could not serve a sign-in). The
  installer's own addresses (`COURIER_BASE_URL`, `COURIER_IDENTITY_URL`,
  `REDIS_URL`, the DSNs, `NATS_URL`) were already fully qualified and are
  unchanged. **The public issuer pair is reported, not guessed:**
  `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER` has no default (unset ⇒ identity serves
  no OIDC surface), gateway's chart default is `https://auth.cafaye.com`, and a
  box must set the same origin on both sides or identity mints `iss` gateway
  will not accept; `IDENTITY_ISSUER` stays an operator value. gateway's
  `ROUTE_TABLE` (`pantry`) and parlor's `BILLING_URL` are deliberately left to
  the values commit that deploys those services, because the substrate may only
  name Services its own manifests create. `tests/substrate_test.sh` §24 asserts
  every cross-service address the Applications set — and every
  `.svc.cluster.local` name the installer writes — names a Service the
  manifests ship in the namespace they ship it in, with red controls for a bare
  name, a name in the wrong namespace, a name no manifest ships, a service that
  loses its address, and a drifted installer name.

- **Nothing was instrumented, so no install could say how long it took.**
  `install.sh`'s JSONL carried no timestamps at all, so a step's duration could
  only be reconstructed from the cluster's object-creation times — archaeology
  that says nothing about a cold box or a bad change. Now `step.start` carries
  `seconds` = the step's **offset** since the install began, `step.done` carries
  `seconds` = the step's **duration** (a skipped step reports the string
  `"skipped"`, never `0`), and the final `install.done` carries the total and a
  `steps[]` table of `{step, phase, seconds}`, which interactive mode prints as a
  compact table. The clock is **monotonic** — `/proc/uptime` on the box, the
  highest-resolution wall clock off Linux, where only differences are taken — and
  the window opens *after* the guard decides a component is absent, so a step's
  time is the step's work and not the guard's probe.
  `tests/substrate_test.sh` §24 requires every step to be timed, the total to
  cover the steps it names, and a positive duration somewhere; a step with no
  timing, a total smaller than its steps, and a run of constant zeroes all go
  red, and a guard-forced-present fixture proves a skipped step says `skipped`.
- **The three operator installs are applied first and waited on together.**
  cert-manager, CNPG and Argo CD are independent — separate namespaces, separate
  CRDs, applies that reference nothing the others create — so steps 2–4 now
  apply their manifests back to back and step 4 waits for all three once. Waiting
  inside each step held CNPG's apply behind cert-manager's rollout and Argo CD's
  behind CNPG's, so the three steps added up. Measured on `contabo` with the
  three Deployments deleted to force a cold run (the installer recreated them):
  serial `4.220 + 18.220 + 24.350 = 46.79s`, grouped
  `2.810 + 2.860 + 20.170 = 25.84s` — about 21s, 45%, off the three steps. A
  component present at its guard is not waited on again, so a warm re-run still
  skips. `tests/substrate_test.sh` §25 pins the shape with two controls.
- **identity refused to boot on the *next* check after the credential pair: a
  courier base URL and token with no link template.** Wiring the courier block
  makes `loadCourier` continue into `resolveLinkTemplates` and
  `resolveInvitationLinkTemplate`, which require at least one link template plus
  `INVITATION_LINK_TEMPLATE`; identity's own config test names the shape — *"a
  base URL and a token with no link template"* → `ErrInvalidCourier`
  (`internal/config/courier_test.go:62`) — and the mirror, *"a link template and
  a token with no base URL"*, is refused too. The mint wrote the pair and no
  template, so a box's identity refused on the check after the pair landed. The
  five templates are now derived from **one operator input**,
  `KIT_SUBSTRATE_APP_BASE_URL` (the public origin a browser reaches), and written
  in the **same merge patch** as `COURIER_BASE_URL` + `COURIER_TOKEN` — so no
  path can write a token without its base URL or a base URL without its
  templates. With the value **unset** the mint writes no identity courier key at
  all: identity's own supported `present == 0` "no mail path" state, which boots
  and answers `503` on every recovery route, while courier still gets its
  required pair. A malformed origin is refused by shape, naming the variable,
  before the mint does anything. There is **no default** — a localhost or guessed
  origin would mail a reader to a screen that is not theirs.
  `tests/substrate_test.sh` applies identity's all-or-nothing rule to the secret
  the mint wrote (the matrix in executable form): green on pair + five templates,
  a red control for the shipped shape (pair, no template) that names
  `INVITATION_LINK_TEMPLATE`, and the unset branch proven green.
- **Every service pointed at a collector nobody deploys, and logged the DNS
  failure every ten seconds.** The services' compiled default OTLP endpoint is
  the *compose* stack's name — `http://otel-collector:4318` (identity, courier,
  parlor) and `:4317` (gateway) — and a box deploys no such Service and no OTLP
  endpoint at all, so a live identity pod logged forever:

      level=INFO msg="traces export: Post \"http://otel-collector:4318/v1/traces\":
        dial tcp: lookup otel-collector on 10.43.0.10:53: no such host"

  Measured rather than assumed: the observability set is alloy + loki + grafana
  + prometheus, alloy is pinned at chart `1.13.0` with **no values**, so its
  default config (`config/example.alloy`) declares no `otelcol.receiver.otlp`
  and its default Service exposes only `http-metrics` on `12345`; the substrate
  ships no Tempo (`DEPLOYMENT.md`: "Traces | deferred"); and `kubectl get svc -n
  observability` on the live box returns nothing. So the decision is the
  packet's other branch — **deliberately off** — and the mechanism is core's
  pinned no-op: `OTEL_SDK_DISABLED=true` (free: no queue, no retry, no warning
  per export, no dial at boot). It is written once as `SERVICE_OTEL_DISABLED`
  and referenced by identity/courier/parlor's secrets, whose generated charts
  `envFrom` them; **gateway is the one exception**, because its hand-written
  chart reads clear env from a ConfigMap rather than its secret, so its
  Application carries the same key/value in `spec.source.helm.values`.
  `tests/substrate_test.sh` §23 asserts every service is configured, that the
  switch is spelled once and agrees across both sites, with red controls for the
  dropped switch, a drifted name, a dropped secret reference, and gateway
  losing the key or its value.
- **Step 11 wrote half a credential pair, and identity refused to boot on it.**
  The mint patched `COURIER_TOKEN` into `identity-secrets` and
  `COURIER_IDENTITY_TOKEN` into `courier-secrets`, restarted both, and the
  restarted identity exited 1 on its own fail-closed loader
  (`identity/internal/config/config.go`, `loadCourier`):

      invalid courier configuration: COURIER_BASE_URL and COURIER_TOKEN must
      both be set, or neither of them: a base URL with no credential sends
      every message as an anonymous caller and courier answers 401

  Each secret now gets its **whole pair in one merge patch**: identity gets
  `COURIER_BASE_URL=http://courier.courier.svc.cluster.local:4000` (courier's
  `Service`/port from `courier/chart/values.yaml`) beside the token, and
  courier gets `COURIER_IDENTITY_URL=http://identity.identity.svc.cluster.local:8080`
  (identity's chart) beside its token — without which courier's introspection
  URL falls back to the compose-network spelling `http://identity:8080`, which
  cannot cross a namespace. `tests/substrate_test.sh` asserts all four keys
  against the values read from the charts, with a red control for each half
  and the record tripwire naming both pairs.
- **`install.done` printed, and the install exited 1.** Right after the done
  event: `line …: forward_pid: unbound variable`. A `RETURN` trap is global —
  bash runs it after **every** function return, not only the return of the
  function that set it — so the port-forward teardown fired correctly at the
  mint's return and then fired **again** when the caller (`main`) returned,
  where the `local` had left scope and `set -u` made the reference fatal. The
  trap command's failure became the process's exit status: eleven steps done,
  exit 1. The trap now ends with `trap - RETURN`, so it runs at most once, on
  the return where `forward_pid` is still in scope. `tests/substrate_test.sh`
  runs the mint from a caller, as `main` does, and asserts exit 0 — with the
  pre-fix trap as the red control.

- **Every `kubectl patch` in the installer read its body from `--patch-file=-`,
  which kubectl does not accept.** `kubectl` has no `-` stdin convention for
  `--patch-file`: it opens a file literally named `-` and dies before the
  request is built, so step 8's username reconcile and step 11's two credential
  patches never reached the API server on any box:

      error: unable to read patch file: open -: no such file or directory

  Measured on Contabo, back to back: `--patch-file=-` prints that and exits 1,
  `--patch-file=/dev/stdin` reads the pipe and patches. The three sites now use
  `/dev/stdin`, the convention step 5 already uses for
  `--from-file=.dockerconfigjson=/dev/stdin`, and `kubectl apply -f -` — a real
  convention — is left alone. `tests/substrate_test.sh` was green over this
  because both mocks modelled `-` as stdin: `mock_kubectl` and
  `rollout_kubectl` now read `/dev/stdin` and refuse `-` with kubectl's own
  error, with a direct convention check per mock, an argv assertion that the
  repair travelled on `/dev/stdin`, and two red controls — step 8's spelling
  reverted to `-`, and the mint aborted by it.
- **Nothing ran a service's database migrations, so a box that "finished" the
  substrate booted the fleet against an empty schema.** The Postgres Cluster
  created one empty database per service, the Applications started the
  services against it, and no step applied a schema: `identity` logged
  `level=ERROR msg="outbox publisher pass failed; retrying"
  error="… relation \"outbox_events\" does not exist (SQLSTATE 42P01)"` forever,
  and step 12's integration probe caught it from outside as `identity would not
  mint a signup timestamp` — a 500 on the missing table. The new **step 10**
  runs one one-shot migrate Job per schema-owning service (`identity`,
  `courier`), in that service's own **running image** (read back from the
  Deployment Argo synced, so there is no second pin) and connected as its
  **OWNER** role — a migration is DDL and `<svc>_app` owns nothing. It waits on
  the pod's phase, prints the pod's logs and fails the install naming the
  service and its OWNER DSN, so no pod is ever left `Ready` over an empty
  database. `gateway` (an explicit no-op `bin/migrate`) and `parlor` (no
  database at all) are named in the plan and skipped. Idempotent twice over:
  the tools' version tables make a replay a no-op, and a marker Secret records
  the image whose schema was applied so a re-run does not launch the pods.
  **The migrate inventory is a finding, not an assumption:** `identity`'s
  repository ships `bin/migrate` (a `psql` loop over `migrations/*.sql`) but its
  **image** is `gcr.io/distroless/static-debian12:nonroot` — no shell, no
  `psql`, no migration files — so it cannot migrate from the image it runs;
  `courier`'s release ships `/app/bin/migrate` (`Courier.Release.migrate`) and
  needs `COURIER_OWNER_DATABASE_URL` (plus `DATABASE_URL`, which its release
  eval raises without). The exact service-repo edit for `identity` is named in
  `REPORT-roll-c5-migrations.md`. `tests/substrate_test.sh` §13g executes the
  step against the file-backed `kubectl`: the run, the OWNER DSN in each Job's
  argv, the per-service marker, the re-run guard (no new pod), and a `Failed`
  pod that must fail the step naming the service — with the inventory-shrinks
  control. NATS becomes step 11 and the courier mint step 12; `TOTAL` 11 → 12.
- **gateway's pod mounted a secret key nothing wrote, and waited forever on
  the mount.** The chart's `Deployment` consumes two references from
  `gateway-secrets`: a `secretKeyRef` for `REDIS_URL` and a `volumes.secret`
  **item** for `ASSERTION_SIGNING_KEY`, mounted as
  `/etc/gateway/assertion/signing.pem`. Step 9 created the secret with
  `REDIS_URL` only, and a required volume item is a hard reference — so the pod
  sat in `ContainerCreating` for 152 minutes on

      MountVolume.SetUp failed for volume "assertion-key" : references
      non-existent secret key: ASSERTION_SIGNING_KEY

  while every earlier step reported success. Step 9 now **generates** the
  assertion key on the box — a PKCS#8 RSA-2048 PEM, the spelling gateway parses
  with `x509.ParsePKCS8PrivateKey`, never an operator input — writes it beside
  `REDIS_URL`, and names it in the SECRET RECORD. A box installed before the key
  existed holds all four service secrets, which would make the `secrets` guard
  skip the step whole, so `reconcile_gateway_assertion_key` runs **above** the
  guard and merge-patches only the missing key (a signing key has no ciphertext
  to fork; the same shape the CNPG role-secret repair uses).
  `check_chart_secret_keys` in `tests/substrate_test.sh` reads the four service
  charts beside kit and requires every secret name and key they reference —
  `envFrom.secretRef`, `secretKeyRef`, and `volumes.secret` items — to be in the
  installer's inventory, with three red controls and a green one built on a
  throwaway fixture fleet.
- **An OCI Helm `Application` named the registry root, not the chart's own
  path, and every sync in the fleet's first end-to-end install failed.** The
  four service `Application`s in `templates/substrate/manifests/applications/`
  carried `repoURL: oci://ghcr.io/cafaye/charts` with `chart: <name>`. Argo
  resolves an OCI source's revision against `repoURL` **itself** — the artifact
  it resolves is `<repoURL>:<targetRevision>` — and the published packages are
  `cafaye/charts/<name>`, so the root is not an artifact:

      Failed to load target state: failed to generate manifest for source 1 of 1:
      rpc error: … failed to resolve revision "0.1.0": cannot get digest for
      revision 0.1.0: HEAD "https://ghcr.io/v2/cafaye/charts/manifests/0.1.0"
      → 403 denied

  No `Application` synced, no `Deployment` was created, and step 11 waited on
  an object that never existed. The `repoURL` now names the chart's own path
  (`oci://ghcr.io/cafaye/charts/<name>`; `chart:` stays, and the two may not
  disagree). `check_chart_publish` in `tests/chart_publish_check.sh` is re-aimed
  from `repoURL == registry` to `repoURL == registry + "/" + chart`, with four
  red controls — the registry root (today's shape), a `repoURL` path disagreeing
  with `chart:`, a drifted registry prefix, and the existing flipped `push`
  default — and `check_obs_chart_sources` in the gate grades the same path.
  Measured live: patching one `Application` to
  `oci://ghcr.io/cafaye/charts/identity` moved it to `Synced` and created the
  fleet's first `identity` Deployment.
- **CNPG never set the app roles' passwords, because the Secret's `username`
  key was the secret's name and not the role's.** Every service's pod logged
  `FATAL: password authentication failed for user "identity_app" (SQLSTATE
  28P01)` while the Cluster reported healthy. CNPG's managed-role reconciler
  sets a role's password from the Secret named in `passwordSecret` only when
  that Secret's `username` key equals the **role's** name; step 8 named the
  Secret for the service (`postgres-role-identity-app`, a hyphen) and wrote
  that same spelling into `username`, so the operator recorded the refusal in
  `status.managedRolesStatus.cannotReconcile` and left
  `pg_authid.rolpassword` NULL for all four `_app` roles — the owner roles
  (`<svc>`, both spellings) reconciled to a SCRAM verifier and looked fine.
  The `username` key is now `$role` (`identity` / `identity_app`), computed
  independently of the secret name, and the loop is the named function
  `create_postgres_role_secrets` so it can be executed in a test. A re-run
  keeps the stored password and merge-patches the `username` key, so a box
  already installed with the broken spelling heals on the next pass. The
  reason and the live evidence (`cannotReconcile` text, the NULL, the FATAL)
  are at the code site. `tests/substrate_test.sh` §12c executes step 8 against
  the file-backed kubectl and compares the result to the Cluster manifest and
  to `database_url_for`'s own DSN, with three red controls: the hyphenated
  username (the live defect), one role name drifting from its Secret, and a
  DATABASE_URL built from the owner Secret.
- **The NATS manifest gave Kubernetes a flag where it expected a binary.**
  `templates/substrate/manifests/data/nats.yaml` carried the local stack's flag
  list under `command:` — `[-js, -sd, /data, -m, 8222]` — because
  `templates/compose/docker-compose.yml` spells the same list under the same
  key. Compose's `command:` **appends** to the image's ENTRYPOINT; Kubernetes'
  `command:` **replaces** it and carries arguments in `args:`. So step 10 applied
  the broker, the kubelet tried to exec a binary literally named `-js`, and the
  install timed out:

      StartError: … exec: "-js": executable file not found in $PATH

  The flags move to `args:` beside a `command:` naming `nats-server`; the
  compose-vs-Kubernetes field semantics are written at the code site, and the
  comment that said "the local service's command, flag for flag" is gone.
  `tests/substrate_test.sh` §12b refuses any `command:` whose first element
  begins with a flag, with the `-js` shape as its red control and a binary-first
  fixture as its green one, so the class cannot ship silently again.
- **A macOS-shipped tree made the installer apply AppleDouble sidecars, and one
  of them killed the install.** `kubectl apply -f <dir>` reads every file in the
  directory, **dotfiles included**, so a tree shipped with
  `tar czf - . | ssh box 'tar xzf -'` left `._identity.yaml` beside each
  Application and step 6 handed it to the API server —
  `error parsing …/._identity.yaml: error converting YAML to JSON: yaml:
  control characters are not allowed`. `install.sh` now resolves each manifest
  directory deliberately: the intended `*.yaml` files are applied, AppleDouble
  `._*` sidecars are ignored and named in the output, and any other entry is
  **refused by name** — a stray file in a manifest directory is a mistake to fix
  or a convention to record, never a silent skip. The `applications/`, `tls/`
  and `data/` apply sites all route through the same check, and the filter is
  the glob (no second filename list to drift). `tests/substrate_test.sh` §20
  proves it: a sidecar-bearing tree applies cleanly, a stray non-sidecar YAML
  goes red naming the file, and a fixture with the glob filter removed hands the
  sidecar to kubectl and breaks the apply again.
- **The Postgres Cluster named a field CNPG v1.30.1 does not have, and the gate
  was green over it.** `templates/substrate/manifests/data/postgres-cluster.yaml`
  wrote `spec.storageConfiguration`, the operator's **pre-1.24** name; the pin
  (`CNPG_VERSION="v1.30.1"`) declares `spec.storage`, and its CRD is structural,
  so the box refused the apply — `strict decoding error: unknown field
  "spec.storageConfiguration"` — rather than dropping the key. The manifest now
  writes `storage` (the fields under it are unchanged), and the reason is at the
  code site.
- **The gate gained the check it lacked, and it is derived from the operator,
  not typed from the manifest.** `tests/substrate_test.sh` §9b grades every
  field the manifests write under `spec` against the pinned CRD's own property
  graph (`tests/substrate-crd/schemas.json`, produced by `regen.py` from the
  same release URLs `install.sh` applies). The absent check was the defect's
  accomplice: `check_cluster` asserted `spec.storageConfiguration.size` in so
  many words — a check written from the file it grades can never disagree with
  it. Three controls must go red: the `storageConfiguration` name the box
  refused, a nested retired spelling (`storageClassName`), and a pin bump
  without re-deriving the model. A service tree is not involved, and the gate
  stays offline.

### Substrate

- **Step 5 wrote the pull secret into namespaces that did not exist yet, and
  only a wiped box could have shown it.** Measured live on a Contabo box:
  the secret was applied into `argocd` (step 4's namespace) and the run then
  stopped at `Error from server (NotFound): namespaces "identity" not found`,
  because the other five are created later — by the Argo CD Applications at
  step 6, with `CreateNamespace=true`. `set -e` ended the install at its
  second namespace, and the manager created the namespaces by hand to get
  past it, which is the state a fixed installer has to produce itself.
  **The secret stays early on purpose** — the first pod that pulls a fleet
  image is Argo CD's own, so a credential applied after the pods that need it
  is a `CrashLoopBackOff` nobody can attribute to an ordering choice three
  steps earlier — and the namespace is therefore **made by the step,
  idempotently, before the Secret is written into it**, with the repository's
  own `create --dry-run=client -o yaml | apply -f -` idiom. Moving it into
  step 6 was rejected: Argo creates the namespace when it syncs, which is not
  a moment this file controls, and nothing at step 6 creates `argocd`'s own
  namespace. A namespace the step makes and the `CreateNamespace=true` Argo
  later meets are the same instruction asked twice, so meeting is a no-op by
  construction. A namespace that cannot be created is **refused by name** —
  no sleep, no wait-until-it-appears, no `|| true`, because each of those
  turns a hole the operator can see into one they discover at image-pull time.
  The mock kubectl now models the boundary that produced the failure (a
  Secret created in a namespace nobody made is `NotFound`, exit 1) and the
  suite watches the step make the namespaces and succeed, refuses loudly when
  one cannot be created, and stops at identity with nothing written past it
  when the creation is deleted.

### Publish

- **The publish path had never once run, and the box could not pull what it
  never published.** Two defects, both silent, both measured on the four
  services' failed publish runs:
  - **`publish.reusable.yml` called its siblings with a path that omitted the
    directory** — `uses: ./image.reusable.yml` and `uses: ./chart.reusable.yml`.
    GitHub resolves a local reusable workflow from the repository ROOT as
    `./.github/workflows/<file>`, so the run was refused at
    workflow-resolution time: `referenced_workflows: []`, no jobs, no
    check-runs, no log line. Verified against GitHub's own docs, and
    `actionlint` — which walks the same path — reports `could not read
    reusable workflow file` on any other spelling. Both references are now
    root-relative, and `actionlint` is clean across
    `.github/workflows/*.yml` — which it was not at HEAD.
  - **The image tag the chart pinned was a tag nothing published.** Every
    chart's `values.yaml` pins `image.tag` to its own `appVersion`
    (gateway's `Chart.yaml` states the rule in prose) while the image
    workflow published only `sha-<40>`, `<branch>` and `latest`: a box that
    pulled the published chart asked ghcr for a tag nothing ever created and
    sat in `ImagePullBackOff` with nothing in the symptom naming the publish
    path. The composer is the only party that knows `chart-dir`, so
    `publish.reusable.yml` now reads `appVersion` in a small `resolve` job —
    a job whose whole body is `uses:` cannot carry steps — and passes it to
    a new `app-version` input that `image.reusable.yml` appends to the
    metadata tag list. Nothing is copied into a second file: a service with
    an image and no chart composes exactly as before (empty input, unchanged
    three tags), and a chart that exists with no `appVersion` fails the read
    by name — that is the invariant, not a missing-chart note.
- **The seam is proven, and the proof can go red.**
  `tests/publish_seam_check.sh` — the same file the gate and
  `tests/focused_publish.sh` call — asserts the local `uses:` references are
  root-relative and resolve; that caller and callee agree on inputs in BOTH
  directions (a caller passing an input the callee does not declare is a
  refusal at run time); that the image's `app-version` is the derived
  `needs.…outputs.app-version` and never a literal; that `sha-<40>` is still
  published; and — where a sibling checkout beside this repository carries a
  service's chart — that the chart's `version` is the Application's
  `targetRevision` and its `values.yaml` `image.tag` is the same string as
  its `appVersion`, never `latest`. EVERY sibling carrying a service's chart
  name is asserted, never the first one found (measured: the website repo,
  mid-rename, carried a parlor chart from two worktrees at once, and a
  silent first-match is a verdict the check cannot defend); a service whose
  sibling is absent is NAMED in a note rather than skipped. Four red
  controls: the unresolved path, the literal tag, a values tag the publish
  never produces, and the sha tag deleted.
- **`sha-<40>` remains the immutable tag**, and the appVersion tag is added
  beside it, never instead of it — which is what control (d) of the new
  proof measures.
- **Fixed, found by `actionlint` on the way to clean:** the image
  workflow's `digest` output was read from `steps.meta.outputs.digest` — an
  output docker/metadata-action has never produced — so it was empty for
  every caller. The digest is the BUILD action's output; wired to
  `steps.build.outputs.digest` with the step id the reference needs.
- **The publish path now runs, and two more seams failed the first time it ever
  did.** With the references resolved, identity's `publish` run reached two
  steps that had never once succeeded anywhere in the fleet:
  - **The helm pin's verification used a flag Helm 4 removed.**
    `chart.reusable.yml` pins helm v4 through the upstream installer and then
    ran `helm version --client` to print the pin. Helm 4 removed `--client`
    (the client/server split died with Tiller), so the step printed
    `Error: unknown flag: --client`, exited 1, and killed the chart job before
    it packaged anything. A developer's local helm is typically v3, where
    `--client` is valid — which is why nothing local saw it. The verification
    is now `helm version --template '{{.Version}}'` (a Helm 4.3.0 option, per
    its own documentation), compared against a single `HELM_PIN` that also
    drives the install, and the step exits non-zero naming both versions when
    they disagree — a version check that cannot fail is a log line.
  - **The provenance stamper was read from the caller's checkout, but the
    script lives in kit.** `image.reusable.yml` ran
    `sh docker/provenance.sh --validate` in the service's tree; identity,
    gateway, courier and parlor carry no `docker/` directory, so the step died
    with `cannot open docker/provenance.sh: No such file` and no image in the
    fleet has ever been published. A new step fetches kit's `docker/` tree at
    `job.workflow_sha` — the documented commit of the reusable workflow file
    ITSELF, not the caller's, not `master`, and not a new input a service must
    remember — into `$RUNNER_TEMP` with a sparse `git fetch` (the same shape
    `ci.reusable.yml`'s conformance fallback uses, because `actions/checkout`
    refuses an out-of-workspace path and an in-workspace kit repo would be
    swept into the build context). It refuses by name if
    `docker/provenance.sh` is absent, and the stamp step runs the exported
    `$KIT_PROVENANCE_SCRIPT`.
- **The two seams are proven, with five red controls.**
  `tests/publish_toolchain_check.sh` — called by `tests/focused_publish.sh`
  and by `tests/validate.sh` — asserts no `helm version` invocation carries a
  flag the pinned major lacks (`--client` being the regression), that the pin
  is verified against one value, that no run body invokes the stamper through
  the caller-relative path, that kit is fetched at `${{ job.workflow_sha }}`
  into `$RUNNER_TEMP`, and that the fetch guards the file by name. Five
  controls, each a one-token edit: `--client` restored; the comparison
  disabled; the caller-relative path restored; the ref rewritten to `master`;
  the guard inverted. Each verified red for its own reason.
- **`.github/actionlint.yaml` carries one reasoned, narrow entry.**
  `job.workflow_sha` is a real, documented GitHub context
  (`job.workflow_ref`, `job.workflow_repository` its siblings), but
  actionlint 1.7.12's `job` schema predates it, so it reports a false positive
  on the valid expression. The ignore is scoped to `image.reusable.yml` and
  that one message, with the reason in the file; a second real finding in the
  same file still fails the run.

### Substrate

- **A `kubectl wait` on an empty list is an error, not a wait — and it killed
  step 1 on a wiped box.** `kubectl wait --for=condition=Ready node --all`
  does not wait when the list is empty; it fails within a second with
  `error: no matching resources found`. k3s is started by the line above it and
  the Node object the kubelet registers lands a few seconds LATER, so the wait
  raced the registration: on a warm box the node won, on a freshly wiped Contabo
  box nothing had registered and the install died at step 1, exit 1, before any
  step after it ran. `set -e` makes it fatal.
  - **The fix is a shape, not a sleep.** `kit_substrate_await_list <budget>
    <get args>` polls `kubectl get <args> --no-headers` until the list is
    non-empty, bounded by a deadline, and refuses on timeout naming the object
    that never appeared. The wait that follows then runs against a list that
    exists. The poll is a command substitution rather than a pipe into
    `grep -q .`: `grep -q` closes the pipe on its first match, the producer
    dies of SIGPIPE, and `pipefail` promotes its 141 — so a long list would read
    as an empty one and poll until the deadline on a healthy cluster.
  - **Each budget is SPLIT, not grown**, so the two waits together are the one
    bound the step always had: step 1 is 90s to register + 30s to Ready (120s
    as before), step 8 is 60s for the CNPG operator to make a pod + 540s to
    Ready (600s as before).
  - **Step 8 had the same race on a different controller.** The Cluster CR is
    applied synchronously, but its pods are created ASYNCHRONOUSLY by the CNPG
    operator, so `-l cnpg.io/cluster=postgres` could match ZERO pods the instant
    the apply returned. Existence is proved first there too.
  - **Every other `kubectl wait` in the installer was audited and none of them
    races.** cert-manager's and Argo CD's `--all` waits, and the four named
    waits (`cnpg-controller-manager`, `argocd-server`, `redis`, `nats`), all run
    immediately after a synchronous `kubectl apply` of the very objects they
    select — apply is a round trip that created them, so the list cannot be
    empty. `argocd-server` in step 6 is the closest call: the apply above it is
    the Argo `Application`s, not the deployment, so its safety rests on step 4
    having waited for it earlier in the same run rather than on the line above
    it. `tests/substrate_test.sh` §17 states the rest of that classification as
    a coupling, so a wait added later is covered by construction: a LIST wait is
    excused only by an apply of what it selects earlier in the same function, or
    by a matching `kit_substrate_await_list`.
  - **NOT FIXED, because it is a different mechanism and this packet did not have
    the budget to prove it: step 11's `kubectl -n identity rollout status
    deployment/identity`** (`install.sh`, in `mint_courier_identity_token`) is
    the same *class* of race on a different controller. `identity`'s Deployment
    is created by ARGO, not by this installer — step 6 applies the Application
    and the sync is asynchronous — and `rollout status` on a missing named
    object is a `NotFound` exit 1 rather than a wait, so step 11 can die before
    the mint instead of waiting for the sync. Steps 7-10 sit between them, so
    the window is narrow, and the audit above does not reach that line because
    it reads `kubectl wait` only. Fixing it is one line — the same
    `kit_substrate_await_list` against `deployment identity -n identity`, whose
    ground the harness's file-backed mock does not currently model — and it
    needs §17's pattern widened to `rollout status` in the same commit, or the
    check stays blind to it. Left for the successor, named here rather than
    implied by silence.
  - **Two ways to prove it.** §16 runs step 1 for real against a cluster mock
    that behaves like a real one — a GET of an empty list exits 0 and prints
    nothing, and the WAIT on it is the error — with three cases: a cold box that
    registers on the second poll must reach Ready, a node that never registers
    must refuse inside its bound naming the empty list, and the pre-fix fixture
    as the control, which must abort with no existence check before it in the
    argv log. §17 is the rule, with five controls (each await dropped in turn,
    a new list wait with no excuse, and a step that grew its bound).
  - 151 passed → 159.

- **`kubectl apply` is in one of two modes, and the target decides which.** Two
  installer defects hit Circle 1 on the Contabo box (169.58.108.209) that a
  compose run cannot produce, because neither has a container in the path:
  - **A REMOTE manifest is applied `--server-side=true --force-conflicts`.**
    Client-side apply stores the whole object in the
    `kubectl.kubernetes.io/last-applied-configuration` annotation, and
    cert-manager's, CNPG's and Argo CD's manifests are large enough to overflow
    the 262144-byte cap Kubernetes puts on `metadata.annotations`. The API
    server refuses the CRD, not the apply:
    `CustomResourceDefinition "clusters.postgresql.cnpg.io" is invalid:
    metadata.annotations: Too long: may not be more than 262144 bytes` — and
    `applicationsets.argoproj.io` the same way. Server-side apply keeps that
    bookkeeping on the API server, where no annotation grows.
  - **`--force-conflicts` rides along, because the second defect is the re-run.**
    After the first was hand-repaired, client-side and server-side tenants of
    the same fields collided — `field is managed by another client`. A mode
    chosen per step is exactly the state that leaves a half-applied substrate
    behind, so the flags are one decision, applied to every remote apply and to
    its `DRY_RUN` plan string, so what `caf box apply` reads is the mode the
    installer actually uses.
  - **A LOCAL manifest stays on client-side apply.** Steps 6-10 apply kit's own
    files: small, re-applied on every run as the installer's convergence
    mechanism, and owned outright by the installer — which is why server-side
    mode for them would take away a re-run's ability to reclaim a field it
    previously owned. The remote manifests are third-party inputs whose
    ownership the installer must not contest.
  - `tests/substrate_test.sh` §14 states the rule as a coupling, not a list:
    every apply whose target is an `http(s)` URL carries both flags, every
    apply whose target is a local file or stdin carries neither, and a tree with
    fewer than three remote applies is RED so the check cannot pass on the
    empty case. Five controls: either flag removed alone (each must be red
    NAMING that flag), a fourth remote apply arriving with no flags, a local
    apply that grew the remote flags, and a plan that lost the flags while the
    run kept them.

- **`identity-secrets` carries `NATS_URL`, so identity's outbox loop runs on a
  real box.** The substrate installs the broker (step 10: one Deployment +
  Service + PVC in `data`, plus the fleet's stream defined idempotently) and
  the **only** `NATS_URL` it ever set was on the one-shot `nats-stream-init`
  pod — a `kubectl run` pod that exits. Every service that has a publisher had
  it dark in production, and identity's loop — the one fully wired and tested
  — had never run there: identity builds its NATS publisher only when
  `NATS_URL` is set, so the local compose stack published and the substrate
  did not. The address is now written into `identity-secrets`, which is where
  a service's environment comes from (the generated charts inject env with
  `envFrom: secretRef`, so the secret IS the env list).
  - **The address is the broker's fully qualified name,
    `nats://nats.data.svc.cluster.local:4222`, not the compose spelling.**
    identity runs in the `identity` namespace; a DNS query naming no namespace
    is limited to the caller's own, so `nats://nats:4222` would produce a pod
    that starts and a loop that connects to nothing — the failure this packet
    exists to end. Step 10's stream-init pod reads the same constant, so the
    two writers cannot drift, and the gate derives the expected value from
    the broker's own Service (name, namespace, port) rather than restating it.
  - **It is recorded as a non-secret key.** The SECRET RECORD's job is the
    two-way tripwire over what the charts' `envFrom` reads; a key the record
    cannot see drift on is a key it will not catch being deleted. `NATS_URL` is
    configuration — the address is not sensitive, the broker carries no
    credentials and the stream holds no customer data — and it is written on
    first creation like every other key, never patched (a broker that moves is
    a rotate-by-replacement, not a silent patch of a live secret).
  - `tests/substrate_test.sh` grows a check that runs the installer against
    the file-backed mock kubectl and reads the stored secret back, plus a
    parse check with three controls (the compose spelling, the missing
    literal, a second spelling of the address in the stream-init pod). A
    pre-existing `identity-secrets` without the key is still left alone by a
    re-run; the README's rotate-by-replacement path adds it.

- **The box control plane's env surface is named for the box, and the install
  has one front door: `https://cafaye.com/box/install`.** Two renames that are
  one packet — the plan's §3 L2 and L5 — and neither has a legacy alias,
  because an alias is a second spelling of a fact that moved.
  - **`KIT_SUBSTRATE_CONDUCTOR_URL` is `KIT_SUBSTRATE_BOX_URL`, default
    `https://box.svc.cafaye.com`.** The variable named the service it talks
    to; the fleet renamed that surface to the box, and the hostname followed.
    Nothing consumes the old spelling, so nothing shims it: a box that sets
    the old name gets the new default and redeems nowhere, which is the loud
    answer rather than the silent one.
  - **The test double moved with it: `box.svc.cafaye.test`.** The suite's
    check on `sourced_vars` names the variable, so a rename that reached the
    installer and not the test would have left the suite exporting a value
    under a name nothing reads — green, and measuring nothing.
  - **`kit.cafaye.com` is retired; `cafaye.com/box/install` is the front
    door.** The Worker serves `/box/install` under whatever host it is
    reached on, so the plan's path and the host binding are two moves and
    only the second is an operator action: bind the route to `kit-install`
    the way `cafaye.com` is bound to `site` today. `GET /` and
    `GET /install.sh` keep answering the same bytes — the cutover for a
    hostname-bound Worker, not a second front door.
  - **The byte-equality guarantee follows the path.** `check_install_host`
    asserts `GET /box/install` FIRST and by the same whole-body SHA-256, so
    the proof is about the path a customer actually types into `curl | sh`
    and not about the path that used to be true.

- **Step 6 waited on an object `core-install` never creates, and it killed the
  install on the box.** The step closed with `kubectl wait
  --for=condition=Available deployment -n argocd argocd-server --timeout=120s`,
  and the box answered `Error from server (NotFound): deployments.apps
  "argocd-server" not found`. Step 4 installs `manifests/core-install.yaml`
  (`ARGOCD_VERSION=v3.5.4`), and the core variant ships no API server, no UI
  and no dex. Checked against the pinned upstream manifest: the entire
  workload set in `argocd` is three Deployments
  (`argocd-applicationset-controller`, `argocd-redis`, `argocd-repo-server`) and
  one StatefulSet (`argocd-application-controller`). The wait could therefore
  never succeed — not a race, a wait on a different install variant's object.
  The earlier Substrate entry that named `argocd-server` among the safe named
  waits was wrong: its "safety rested on step 4 having waited for it", but
  step 4's `--all` deployments wait can only wait for objects that exist.
  - **The wait is deleted, not repointed, and the argument is written at the
    code site.** Every repoint target is either already waited on or
    unwatchable: step 4's `wait --for=condition=Available deployment -n argocd
    --all` already holds until every core-install Deployment is Available
    (including `argocd-repo-server`, the one these Applications depend on — it
    pulls their charts), and the reconciler `argocd-application-controller` is a
    StatefulSet, which publishes no status conditions, so
    `kubectl wait --for=condition=Available` has nothing to watch and would
    time out and fail the same way. The reconciler is level-triggered —
    Applications applied before it is up are reconciled when it comes up — and
    the install's real "Argo reconciled" signal is step 11's rollout watch on
    `deployment/identity`.
  - **The guard probed the same non-existent object, in the idempotency path.**
    `kit_substrate_guard argocd` asked `kubectl get deployment -n argocd
    argocd-server`, which never matches on a core-install box, so the guard
    never skipped and step 4 re-downloaded and re-applied the largest manifest
    on every run. It now probes `argocd-repo-server`, a Deployment core-install
    ships (and the full install ships too, so the probe stays correct if the
    variant ever changes).
  - **The human-facing UI lines named components core-install does not ship.**
    The receipt sent the operator to `kubectl -n argocd port-forward
    svc/argocd-server 8443:443` and to read
    `secret/argocd-initial-admin-secret` — no such Service exists in
    core-install, and that secret is minted by the API server at startup, so
    there is no API server to mint it. Both lines are gone; the receipt's human
    destination is now `kubectl -n argocd get applications`, the state a person
    reads to watch the fleet reconcile (and the same command the README
    already gives).
  - **The rest of the file's Argo CD assumptions, audited per line.** Step 4's
    apply of `core-install.yaml` and its `--all` deployments wait are correct
    as they stand; the phase name, the pull-secret namespace list, and the DRY
    plan strings name no component. Nothing else in the runnable code assumes
    the full install.
  - **The proof is the core-install reality, executed.** `tests/substrate_test.sh`
    §19 runs `install_applications` for real against a mock kubectl whose
    deployment list in `argocd` is exactly the pinned core-install set: the
    three Deployments answer, any other name answers the way real kubectl
    answers a missing named object (NotFound, exit 1). Green case: the step
    applies the Applications and waits on nothing — the argv is asserted to
    hold no argocd wait at all, so a reintroduced one is a regression the suite
    catches. Red control: the pre-fix shape with the `argocd-server` wait
    restored must abort with NotFound after the apply. Two further cases pin
    the guard's probe and assert — over the comment-stripped file — that no
    runnable line names `argocd-server` or `argocd-initial-admin-secret`. §17's
    non-vacuity bound on named waits moved 4 → 3 with this commit: the
    population shrank by the wait this packet deleted, and a bound that rotted
    past the population it counts is how a non-vacuity check becomes a no-op.

### Licensing

- **kit's grant is MIT, and it now has a manifest (OPS-D2).** The framework
  split — core, caf, kit and pantry open under MIT, because their job is
  adoption — left `kit` in the one state OPS-D2's own effect column names: no
  grant means "all rights reserved", and a manifestless repo can be both
  unlicensed and undescribed. Both halves land together.
  - **`LICENSE` is byte-identical to `cafaye/core/LICENSE`.** The wording is not
    new and not kit's own draft: seven cafaye repositories already carry this
    exact text — billing, caf, cafaye-py, cafaye-ts, core, darkroom and docs —
    each 1063 bytes, each md5 `cb5ecefdf779acdeacb8709d2ddd56cf`. A reader
    diffing two framework repos sees no grant and only the repository differing.
  - **`cafaye.yml` is added.** `name: kit`, `language: spec` (the schema's enum
    has no config member and AGENTS.md says kit is configuration and
    documentation only), `core: ^0.2.0`, `dependencies: []` (kit is a dependency
    *of* the fleet, never a consumer), `visibility: public`. No `exposes` or
    `consumes`: kit is not a running process, so it has no runtime contract to
    break — the reason core gives for its own omission. Validated against
    `core/schemas/cafaye.manifest.schema.json` (required keys,
    `additionalProperties: false`, and the `serviceName`, `semver`, `repository`
    and `owner` patterns).
  - **`name: kit` is on the reserved-name list** —
    `cafaye`, `caf`, `kit`, `core`, `docs`, `pantry` are "reserved, never usable
    as a service name" (`core/docs/manifest-conventions.md`, Namespace rules) —
    and it is named anyway, which is the exception core already makes for
    itself: the schema does not enforce the list and the rule exists to stop one
    service *calling* another `kit`. This is the one line of the file that is a
    review decision rather than a derivation, and it is flagged in the manifest
    itself.
  - README's `## License` section, the "kit's own licence" section and the
    layout table, and AGENTS.md's layout comment and licence rule, all re-point
    at MIT. Historical records (m168, m172, kit-19 and their reports) are left
    as written: they describe what was decided then, and a changelog that edits
    its own history is a changelog that cannot be read.

  **The gate is red on exactly one check, and that is named rather than hidden.**
  `license_check` in `tests/validate.sh` was written in m172 for the proprietary
  grant: it requires `All rights reserved`, `proprietary property of Cafaye` and
  `separate written Cafaye agreement`, refuses MIT's permission grant, and
  requires README's `## License` section to state `Proprietary` and name
  `Cafaye`. Measured on this packet: 6 of its 8 sub-assertions are red, and the 2
  that stay green are the ones that were never about the grant's *wording*
  (README links the LICENSE file, README names AGPL). The grant is the file and
  the check is what has to move; a licensing packet does not get to edit a
  security-shaped gate to make itself green, so it does not, and the successor's
  move is written into AGENTS.md beside the rule.

### Security

- **The substrate installer no longer takes a long-lived secret as an input
  (W2-P4).** Two values used to be handed TO it — a GHCR
  `dockerconfigjson` (`KIT_SUBSTRATE_PULL_SECRET`) and identity's OIDC signing
  key and id — and both violated invariant 3 ("secrets are born where they are
  used") on the input side, because a value in somebody's shell history is not
  a value born on the box.
  - **The pull secret is redeemed, not supplied.** The installer takes the
    box's enrolled identity (`KIT_SUBSTRATE_BOX_ID`) and a single-purpose,
    minutes-lived, box-bound capability (`KIT_SUBSTRATE_REGISTRY_CAPABILITY`),
    presents it once at `KIT_SUBSTRATE_REGISTRY_URL`, and receives ONE
    short-lived dockerconfigjson which lives in a shell variable, is
    shape-checked (base64, an `auths` object) and is applied as a rendered
    Secret through a pipe. It reaches no disk, no argv and no stdout, and the
    capability is validated by shape BEFORE any network call, so a pasted
    dockerconfigjson from an older runbook is refused rather than sent
    somewhere as an opaque bearer.
  - **Identity's OIDC signing key is generated on the box** — `openssl genrsa
    2048` (identity's own `MinKeyBits`), with a key id DERIVED FROM THE KEY (a
    public thumbprint, so a verifier's cached `kid` keeps matching) instead of
    invented. Both are read back once-only, so a re-run never rotates a live
    system's key. The surface stays all-or-nothing: the operator may set
    `KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER` (configuration, not a secret) and the
    key is born beside it; with no issuer the surface stays absent rather than
    half-wired.
  - **Courier's identity credential is now minted, patched and restarted
    INSIDE one run** (new step 11). The loop used to cross a boundary twice —
    mint an API key in one terminal, paste it into a second run — and the two
    halves identity and courier hold must be the same value, which a hand-off
    cannot be trusted to get right (a mismatch reads as identity's `403`).
    Step 11 makes the same four calls `launch/bin/launch` makes, against
    identity's cluster-local endpoint over a port-forward, writes ONE value
    into `identity-secrets` (`COURIER_TOKEN`) and `courier-secrets`
    (`COURIER_IDENTITY_TOKEN`), restarts both deployments, and prints none of
    it.
  - The one long-lived secret an operator still supplies is
    `KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET`, because the provider is
    the only party that can hold it.

- **`install.sh` step 11 writes the minted credential with a merge PATCH, not
  a whole-Secret apply** — the difference is load-bearing and was a real bug
  in this packet's own first draft. `kubectl apply` carrying a full Secret
  object is a REPLACE: writing `COURIER_TOKEN` through one would delete
  `DATABASE_URL`, `SIGNUP_SIGNING_KEY`, `MFA_ENCRYPTION_KEY` and the OIDC keys
  from `identity-secrets` in the same breath, and the symptom would be an
  identity that boots no further after its next restart. The patch body is
  built by `jq` and read from `--patch-file=/dev/stdin`, so a token with a quote
  in it can neither break the JSON nor reach an argv. `tests/substrate_test.sh`'s
  mock kubectl now MERGES a patch the way kubectl does, so the assertion
  "identity-secrets still holds the keys step 9 wrote" is a real assertion
  rather than an accident of the mock — and the SECRET RECORD check learns the
  patch spelling with a control of its own that removes the patch and must go
  red, so the widened check is proven on the path that changed.

- `templates/substrate/install.sh` step 5's pull-secret write no longer hands
  kubectl a `--from-file=<(...)` path. A `/dev/fd/N` exists only for the
  lifetime of one command, which is a form that works on the machine it was
  written on and nowhere else; the rendered Secret is applied through a pipe,
  which also takes the value out of any argv.

- `tests/substrate_test.sh` gains section 13 — the proofs above, each with a
  control that must answer differently: the retired names planted back into
  code, a short/absent/dockerconfigjson-shaped capability, an echoed key, an
  echo-free log planted with the minted credential, and a manifest with no
  dockerconfigjson type. The retired-name check reads CODE with comments
  stripped, which is the same strip the SECRET RECORD check uses: a comment
  naming a retired variable is the record of the change, and a comment cannot
  read a variable. The `SECRET RECORD` tripwire is unchanged in shape and
  still the drift contract for what the installer writes.

- **`install.sh` gains `--headless` (or `HEADLESS=1`) — the mode an agent
  drives (W2-P5).** `caf box apply --phase N` runs the installer with the flag
  and reads **stdout as a stream of JSONL progress events, one object per
  line, and nothing else**:
  `{"event":"step.start","step":1,"phase":"k3s","message":"…"}`. Interactive
  mode is unchanged and prints the same plain text, byte for byte.
  - **The split between two writers is the property.** `kit_substrate_emit`
    owns stdout — JSONL, headless only. `kit_substrate_out` owns human text —
    stdout interactively, **stderr** in headless mode, so the operator and
    `caf box logs` still read it while stdout stays machine-parseable.
    Nothing else in the file writes to the process stdout.
  - **The tripwire is a parse of every `echo` and `printf`**, in the
    `SECRET RECORD` family rather than a run of one path: continuation lines
    are joined first (the pipe carrying a rendered Secret into
    `kubectl apply -f -` sits on the line AFTER the `printf`, so a line-based
    read flags the one statement whose output most needs to stay off a
    terminal), and then two rules — a statement that reaches stdout must live
    in one of the two writers, and nothing that can reach stdout may expand a
    variable holding secret material. The second is what makes the first
    worth having: a channel only two functions write to is still a channel a
    `$PASSWORD` could be poured into. Both exemptions are closed lists, not
    patterns: a `*SECRET*` glob would also match `secret_name`, a Kubernetes
    object's NAME, which is not a value, and a check that fires on correct
    work teaches its reader to ignore it.
  - **The install-receipt file** (`KIT_SUBSTRATE_RECEIPT`, default
    `/var/lib/kit/substrate-receipt.json`) is rewritten at every state change
    and names the **phase**, the **next step**, the **input needed** and
    **where the human goes**. A refusal writes a `refusal` event *and* a
    receipt with `status: "refused"` — so the agent's only touchpoint with a
    person is the receipt's `human` field, and every operator-input refusal
    (box id, capability, ACME email, database list, courier's relay settings,
    the MFA override, a step run out of order) is routed through it. Writing
    it is best-effort and never stops the install: the receipt is a report,
    not a gate. W5-P4's resumable install is its consumer.
  - The live half proves what a static parse cannot: with kubectl mocked to
    files, stdout parses line by line as JSON, the detail lines are on stderr
    and not on stdout, and none of the values the run *holds* — the generated
    `SIGNUP_SIGNING_KEY`, MFA key, `SECRET_KEY_BASE`, box key, relay token,
    role passwords, the operator's relay password, and the `DATABASE_URL`s
    those passwords sit inside — reach stdout. Those values only exist at
    runtime, which is exactly what a source parse cannot see.
  - Five controls, each proven able to go red: a bare `echo` restored, a
    secret-shaped variable through `kit_substrate_out`, the same through
    `kit_substrate_emit`, a piped secret moved onto the process stdout, and a
    receipt with no `human` destination (plus a second recorded as
    `"running"` — a refusal recorded as running is an install the agent
    believes is still in progress).

### Fixed

- **`tests/launch_test.sh` went red for anyone who had ever launched the
  stack, because its teardown claim read a file the suite does not own
  (m207).** `test '!' -e "$LAUNCH/.env"` asked a question about
  `launch/.env` — generated by `up`, git-ignored, and the credential home of
  a stack that may be RUNNING, where `SIGNUP_SIGNING_KEY` and
  `MFA_ENCRYPTION_KEY` are exactly the two values the launcher keeps stable
  across a teardown on purpose (`launch/bin/launch:327-341`). Measured on a
  checkout holding a live launch's `.env`: **60 passed, 1 failed**; with the
  file moved aside, **61 passed** — so the assertion was reading state the
  suite did not create and going red for the person who did the right thing
  and launched first, which is the population the suite exists for.
  `LAUNCH_DIR` is not an input (the launcher derives it from its own
  location), so both teardowns now run against a **shadow copy of `launch/`**
  in `$WORK` with no `.env` in it, kit's real checkout supplied as the stack
  through `KIT_STACK_DIR`. The claim itself is unchanged and is still about
  the write — a teardown that minted a `.env` on its way out — and it is
  carried by two controls: a down path that appends one line to the credential
  home, whose own premise is asserted first, and the operator's real situation
  (a `.env` already on disk, required byte-identical after the teardown).
  §8 snapshots the real `.env` before anything runs and asserts it comes out
  untouched, so the fixture can never become a licence to edit the live one.
  The first version of this also failed its own comparison for a reason worth
  recording: `$TMPDIR` on macOS ends in `/`, so `mktemp` returns
  `…/T//kit-launch-test.XXX` while the launcher's own `pwd` collapses that to
  one slash — a check comparing the two strings is red on macOS and green on
  every Linux box. Every shadow path is now canonicalised the way the launcher
  canonicalises its own.
- **The launch preflight did not check for `psql`, the one tool the launch
  shells out to on the host, and failed after the build (m201).** Identity's
  image is distroless and migrates nothing itself, so the bring-up runs
  identity's own `bin/migrate` from the host against the published cluster
  port, and identity's migrate pipes each migration's Up section into `psql`
  (`identity/bin/migrate:82-83`). `--check` required `curl`, `git`,
  `openssl` and `jq` and reported "every prerequisite is in place" on a
  machine where the launch could not succeed — the manager hit this for real:
  the failure arrived after both images were built, at `psql: command not
  found`. `REPORT-kit-launch-contract-audit-m195b.md` §3 had named the exact
  gap in advance. `--check` now fails closed on a missing `psql` naming the
  tool, the host-side migration step, and the install; `launch/README.md`
  gains a Prerequisites table that is the same list, tool for tool, with the
  reason each is needed. The test adds a hermetic red control — a bench
  holding only the launcher's stubs plus `bash`/`dirname`/`basename`, with no
  `/usr/bin` in PATH at all, because a PATH of "stubs minus psql" is not
  hermetic on a machine whose `postgresql-client` package puts `psql` in
  `/usr/bin` — plus a second assertion that the refusal names `psql` AND the
  migration, so a red arriving from any other check cannot satisfy it.
- **The launch overlay contradicted the service contracts; four corrections,
  each with a test (m199).** A read-only audit of `launch/` against the current
  Identity, Gateway, Courier and Parlor checkouts
  (`REPORT-kit-launch-contract-audit-m195b.md`) found no blocker that fails
  after an image build — every readiness URL, bootstrap endpoint, response
  field, migration path, required environment variable and port is satisfied —
  and one definite contradiction plus three quality gaps:
  - **identity's runtime `DATABASE_URL` named the OWNER role `identity`**
    (`launch/docker-compose.launch.yml`). Postgres exempts a table's owner
    from its own row-level-security policies, so a pool running as the owner
    reads every account's row while every policy sits in the catalog looking
    like a boundary — and identity's own `docker-compose.yml` has said
    `identity_app` since the switch, with migration 00019 granting the login
    role the DML it needs. It is now `postgres://identity_app:…`, and the
    comment that presented the owner as the safe choice is corrected. The
    login role was VERIFIED rather than assumed: all 18 tables in the schema
    carry a DML grant to `identity_app` (00016 on the five protected ones,
    00019 on twelve more, 00022 on the audit log, 00018 re-issuing), no table
    has a serial or identity column, and kit's `10-cluster.sh` grants the app
    role `CONNECT` on its own database.
  - **gateway carried `BUN_VERSION: "1.3.12"`** for a Dockerfile declaring
    only `ARG GO_VERSION=1.26` and no Bun stage. An unconsumed build arg is a
    BuildKit warning, so the build proceeded under a comment asserting a pin
    that did not exist. Now the arg gateway's Dockerfile consumes, at the
    value identity's own compose pins.
  - **`RECOVERY_LINK_TEMPLATE` pointed at `/reset`**, a path Parlor does not
    serve, and only the email-change purpose falls back to it — so its
    confirmation link was a 404. `EMAIL_CHANGE_LINK_TEMPLATE` (identity's
    third per-purpose variable, previously unset) and the default both name
    `/verify-email/confirm`, the address-confirmation screen and the closest
    path Parlor serves; Parlor carries no email-change screen and the comment
    says so rather than implying the token redeems there.
  - **`kit_ref()` read a committed `kit.ref` that does not exist in this tree
    and was never called** — `resolve_stack`'s three sources are the whole
    resolution. DELETED rather than wired up: wiring it up would make the
    lowest-precedence source something other than "this checkout", the
    documented decision that the harness runs the stack it ships with, and kit
    ships no `kit.ref` for a service to adopt by copy.
  `tests/launch_test.sh` goes 46 → 58 cases, each new check with a control
  built to violate exactly that property. Two are worth naming: the role is
  extracted as the token between `postgres://` and the next colon, because
  `postgres://identity_app:` CONTAINS `postgres://identity:` and a substring
  check answers "owner" for both; and the pin check strips comments before
  reading, because its first version went red on the paragraph recording why
  the function was deleted. Two render checks assert the RESOLVED DSN and link
  paths after `docker compose config` interpolation.

- **`launch/README.md` now states the port collision with `site-launch-*`
  plainly (m199).** This stack's defaults are the same five ports the retired
  stack's overlay published (15025, 15080-15083) and both layer over the same
  Kit base stack, so 15500/15600/15700/15800 collide too. It is a port
  collision and not a composition error: `up` fails on the first bind Docker
  refuses, naming the port and not the stack — and in the partial case a run
  answers on the ports it could bind and reads the wrong container on the ports
  it could not, which is worse than the failure. The recipe for running both
  (a distinct block plus `LAUNCH_STACK_NAME`) is in the README and in the
  overlay's port-block header; the defaults do not change, because they are the
  documented escape hatch and not the defect.

### Added

- **Kit owns the local launch harness: `launch/` (m186).** The retired
  `cafaye/site` launcher (`bin/launch` + `e2e/docker-compose.launch.yml`)
  moves to Kit as `launch/bin/launch` + `launch/docker-compose.launch.yml`
  plus `launch/README.md`: the same four product services (identity,
  gateway, courier, parlor) built from source on Kit's stack with mailpit
  as the SMTP sink, the same stable-secrets/mint-after-ready/bounded-waits
  semantics — generalized so sibling checkouts are explicit `LAUNCH_*_DIR`
  paths (Website and Site are never required; the front door is Parlor, not
  Website) and the stack defaults to this checkout itself, with
  `KIT_STACK_DIR`/`LAUNCH_KIT_REF` overrides resolved by Kit's own
  `templates/bin/dev.sh live` (the pin validated with `bin/dev`'s rule,
  never a second copy of the resolution). `tests/launch_test.sh` proves the
  shape with stubbed tools and no daemon — 46 cases covering layout
  validation, pin behavior, command construction, teardown safety
  (exactly one `down -v`, both compose files, the launch project directory,
  no generated `.env`), compose/schema invariants each with a control that
  must go red, a real `compose config` render, and the installer split (the
  harness names no k3s/Argo/ACME/GHCR/Cloudflare; the customer installer in
  `templates/substrate/` is separate and unproven here) — wired into the
  gate's static phase. See `REPORT-kit-launch-harness-m186.md`.

- **`license_check` for the Cafaye proprietary grant (m172).** m168
  re-pointed the prose — README.md's `## License` section and AGENTS.md's
  licence rule both describe a `license_check` that reads the grant and
  walks every root manifest — but added no check, so the prose described
  a gate that did not exist. `tests/validate.sh` now carries it, in the
  static phase, under the label
  `LICENSE  (Cafaye proprietary, and nothing in the tree can disagree with it)`:
  `LICENSE` must contain the grant's own sentences (`All rights reserved`,
  `proprietary property of Cafaye`, `separate written Cafaye agreement`)
  rather than the bare word `Proprietary`, must not still contain MIT's
  permission grant, and must name Cafaye as the holder; README's own
  `## License` section must state the proprietary grant, name Cafaye, link
  the file, and still name AGPL (the backends distinction); every root
  manifest that can carry a licence field must agree — proprietary has no
  single SPDX token, so agreement is `Proprietary`, `UNLICENSED`, or
  `SEE LICENSE ...`, and an `MIT` left over from the fleet's earlier
  decision fails. A manifest with no licence field is not a disagreement,
  and `templates/` stays out of scope: a licence there is that template's
  business. Red-proved both directions (a root `package.json` declaring
  `MIT`, a `LICENSE` with the reservation edited out, and an MIT
  permission sentence appended all fail the named check; `UNLICENSED`
  passes), then restored.

- **Customer upstream path: `docs/customer-upstream.md` (m167).** The
  customer-facing adoption and contribution page, linked from
  [How a service repo adopts kit](#how-a-service-repo-adopts-kit). Your
  application source merges from a named upstream remote (the Jumpstart
  Pro model, commands verified against its README); Kit's platform
  pieces are pinned to one shared commit SHA across `uses:`,
  `kit-lint-ref` and `kit.ref` — branch comments on the YAML lines
  (Renovate ignores bare SHAs by default), bare SHA in `kit.ref`
  (`bin/dev` reads the whole line as the ref) — and moved by Renovate
  PRs via the `github-digest` datasource, which follows `master`
  directly: no tags or releases needed, and an empty `git tag` is not
  a missing update path. Kit is public (verified via `gh repo view`
  2026-10-08), so everything is fetchable with no grant. The page ships
  the opt-in Renovate block (JSON parses; every `matchStrings` matched
  locally against its §2 pin shape on the captured groups; no
  end-to-end Renovate run observed — managers configured, live behavior
  and PR grouping unverified) and keeps the two upstream directions
  apart: general app fixes go to the canonical app (§1, fork + PR off
  the named `upstream` remote, branding stays downstream — upstream
  takes general fixes, not every customization), Kit improvements back
  as fork + PR (§4) with narrow local verification (`git diff --check` plus the
  focused check for what changed; CI owns the full gate, docs-only
  changes take the fast `docs` route). Held by
  `tests/customer_upstream_check.sh` (11 cases), wired into the static
  phase: README linkage, all three pin sites named, Kit-is-public
  stated, the Renovate block parses and its patterns match, digest
  shape with no `github-tags`, `# master` comments on the YAML
  examples, no retracted tag/access caveat, narrow-verification
  guidance with the forbidden mechanisms named, and the §1/§4 upstream
  separation (app fixes to the canonical app, Kit improvements to Kit).

- **`bin/dev live`: the staged-launcher entrypoint for the service-owned
  live snapshot (m162).** Site's staged `bin/launch` calls
  `templates/bin/dev.sh stack` and then composes using the shared cache
  directly, so a cache retirement, prune or deletion moves a byte a live
  mount resolves to. `live` closes that seam from Kit's side without
  touching Site: it runs the existing `resolve_stack` (same five-source
  resolution `stack` and `up` share) and the existing `sync_live_stack`
  (the same content-addressed snapshot `up` writes — no duplicated
  fetch/cache/snapshot logic), then prints the machine-readable
  `resolved: .kit/live/<ref>` line a launcher parses with `^resolved: `,
  plus `ref: <ref>`. The path is always the service-owned
  `.kit/live/<ref>`, never the cache. `stack` stays read-only (creates
  nothing); `live` is the only command besides `up` that writes the
  snapshot, and unlike `up` it starts no containers, runs no preflight,
  migrates nothing and renders no `compose config` — config output on
  stdout would be noise on the line the launcher parses. Section 11 in
  `tests/fetch_test.sh` proves the contract with no docker: `stack`
  creates no `.kit/live`, `live` prints exactly one `resolved:
  .kit/live/<ref>` line, the snapshot is byte-identical to the pinned
  source and records the ref, and a repeated call reports unchanged with
  identical bytes.

- **`bin/dev up` composes from a service-owned live snapshot, never from the
  Kit cache.** `up` copies the resolved `templates/compose` subtree into
  `.kit/live/<ref>` (ref recorded in `.kit-stack-ref`, bytes compared before
  any write, own `.gitignore` so it is never committed) and every `-f` and
  every bind source resolves from there. Replacing, pruning or outright
  deleting the cache can no longer invalidate a live Compose file mount —
  with the whole cache deleted and the network forbidden, `up` still resolves
  (the snapshot is a resolution source below the cache, above the vendored
  copy) and brings the stack up byte-identical. One directory per deliberate
  pin, written once per ref and never rewritten for a fixed ref; a snapshot
  that differs at an immutable ref is kept aside as a single `.stale`
  generation rather than deleted. `tests/fetch_test.sh` section 9 proves all
  of it against a stubbed docker with no daemon: compose pointed at the
  snapshot with the cache home nowhere in the invocation, byte-identity,
  post-cleanup survival and determinism — red on the old code, green on the
  new, with sections 1–8 untouched.

- **Live snapshot stale retention is mount-safe and the derived subtree is
  fully ignored (m157).** `sync_live_stack` no longer `rm -rf
  .kit/live/<ref>.stale` before `mv .kit/live/<ref> .kit/live/<ref>.stale` on
  repeated corruption — repeated `rm -rf` would delete a generation an older
  stack still bind-mounts (rename keeps inodes, `docker inspect` still
  reports the pre-rename path). It now asks the daemon via `mount_sources` /
  `generation_is_mounted` (absolute paths, conservative when docker is
  unavailable) and, when stale or dest appears mounted, spills the current
  dest to a numbered `.stale.<n>` instead of deleting `.stale`. Root
  `.gitignore` now ignores `.kit/live/` as a whole, so the per-snapshot
  `.gitignore` (`*` + `!.gitignore`) no longer leaves itself untracked and
  `git status --untracked-files=all` never reports a derived snapshot.
  New snapshots live outside `$KIT_STACK_HOME/.retired` and never enter
  `prune_generations`'s glob scope; legacy cache-mounted stacks (pre-m154)
  remain reachable by that matcher until their first `up` from the new tree
  re-renders them — the bounded limitation stated honestly. §10 in
  `tests/fetch_test.sh` proves all three: mounted stale survives repeated
  corruption, `git status` is empty for a derived snapshot, and prune never
  touches `.kit/live`.

- **The substrate install generates `MFA_ENCRYPTION_KEY` by default.**
  `templates/substrate/install.sh` now always writes `MFA_ENCRYPTION_KEY`
  into `identity-secrets` on first creation: a cryptographically random
  32-byte base64url-no-padding key (the exact shape identity's config
  parser accepts — `base64.RawURLEncoding`, exactly 32 bytes, the same
  generation spelling as `SIGNUP_SIGNING_KEY`), so a clean
  `curl https://kit.cafaye.com | sh` install boots an identity whose MFA
  surface works (GET /v1/mfa and enrollment routes mount only when the key
  is present). An operator-supplied `KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY`
  override is preserved for compatibility, validated by shape on the live
  path (charset, 43 characters, decodes to 32 bytes), and never printed —
  refusals name the variable, never the value. The stored key is persistent:
  reruns read it back and never rotate or replace it, and a pre-existing
  `identity-secrets` without the key is deliberately not patched (an imported
  database could hold ciphertext sealed under a key no longer present;
  `templates/substrate/README.md` documents the operator's safe
  existing-install path). OIDC signing and OAuth encryption keys stay
  optional. `tests/substrate_test.sh` section 13 proves all of it locally
  via a file-backed mocked kubectl (no k3s, no box): default generation and
  shape, override honored verbatim, invalid override refused with nothing
  written, rerun persistence under a competing override, distinct keys
  across fresh installs, legacy no-patch, and no key material in installer
  output — each with red-first controls.

- **Proportional CI: route docs/tier/publish changes to focused proofs,
  everything else to the full gate.** `.github/workflows/ci.yml` now
  classifies each pull request with `tests/route.sh` (pure bash, argv in,
  one `ROUTE=` line out — no venv, no network, and it never launches the
  gate) and runs exactly one proving job: `docs` runs `git diff --check`
  and nothing else; `tier` runs `tests/focused_tier.sh` and `publish`
  runs `tests/focused_publish.sh` (family syntax with the gate's own
  tools, plus the gate's exact `chart publish` check for publish —
  `tests/chart_publish_check.sh`, one file called by both the gate's
  `check_chart_publish` and the focused script, so the two verdicts cannot
  drift; the focused script never invokes `tests/validate.sh`, whose
  bootstrap self-tests would re-enter the gate recursively); all
  platform/runtime artifacts, workflows, tests, mixed families, unknown
  or empty diffs, and every non-PR event take `full` — the unchanged
  reusable workflow running `bash tests/validate.sh` with no flags.
  `tests/route_test.sh` proves all 19 routing cases in ~0.1s including
  the fail-closed property and a guard that fails if the router ever
  names the gate in an executable line, and the full gate executes it.
  The stable required check is still `ci / gate`, which passes iff the
  selected route's job passed and prints which checks ran and which did
  not; narrowed runs are never reported as platform-test passes.
  `ci.reusable.yml` is untouched — no new input, no behavior change for
  any consumer. Pushes to `master`, a weekly schedule, and manual
  `workflow_dispatch` runs always take `full` and are the release proof.
  README documents the platform/service boundary and the routing table.

- **The observability `Application`s point at their official upstream chart
  repositories with pinned chart versions.** All eight `Application`s in
  `templates/substrate/manifests/applications/` named
  `oci://ghcr.io/cafaye/charts`, but nothing in the fleet publishes the
  observability four — kit holds no `Chart.yaml` for `alloy`, `grafana`,
  `loki` or `prometheus` and no service publish workflow pushes them — so
  four Applications could never sync. Per `DEPLOYMENT.md` ("Who owns the
  `Application`"), the private-OCI shape governs the closed-source service
  charts only; third-party components we do not author and do not modify
  point upstream, shipped unmodified: `alloy 1.13.0`, `grafana 10.5.15`,
  `loki 7.3.0` from `https://grafana.github.io/helm-charts`, and
  `prometheus 29.36.0` from
  `https://prometheus-community.github.io/helm-charts`, each pin verified to
  exist in its upstream `index.yaml` before it was written. The four service
  `Application`s are untouched. Kit's gate states the rule over all eight
  manifests (`check_obs_chart_sources`: every `Application` resolves to
  either a fleet publication or its pinned upstream, anything else fails
  closed) with a reverted-repoURL control and a drifted-chart-name control
  that must go red; `check_chart_publish`'s registry assertion is narrowed
  to the four service `Application`s in the same commit, since the
  observability half is no longer its seam to govern. Committed red-first:
  the new check failed on all four files before the repoint, and goes green
  after it.

- **The substrate's data layer and the services' secrets: `install.sh`
  steps 8–9.** `DEPLOYMENT.md` (manager decision, 2026-10-06) commits the
  box to a CNPG Postgres `Cluster`, single-instance Redis, and
  box-created service secrets — and `install.sh` installed the CNPG
  *operator* with nothing that used it, no Redis, and no service secret.
  This packet closes that: step 8 applies `manifests/data/
  postgres-cluster.yaml` (one Cluster, `postgres` in namespace `data`,
  reproducing `templates/compose/postgres/initdb/10-cluster.sh` through
  bootstrap `postInitSQL` + `spec.managed.roles`) and creates the eight
  `postgres-role-*` password secrets it names; step 9 applies
  `manifests/data/redis.yaml` (one Deployment + Service + PVC at the exact
  tag `redis:7.4.1-alpine`, password by `secretKeyRef`) with the generated
  `redis-password` secret, then creates `identity-secrets`,
  `gateway-secrets`, `courier-secrets` and `parlor-secrets` with exactly
  the keys each chart reads (the split is by provenance: generated values
  are once-only with read-back, externally-sourced values are
  shape-validated and never echoed, and `DATABASE_URL` agrees with the
  Cluster by construction — the `<svc>_app` role, the service's own
  database, `postgres-rw.data` as host). `spec.imageName` is unset on
  purpose — CNPG's standard image already carries pgvector, so there is no
  custom image and no build step. `tests/substrate_test.sh` grows the
  nine-step plan, the `KIT_SUBSTRATE_DATABASES` refusal (unset, empty, and
  manifest-mismatching, each naming the fix), the Cluster's per-role
  provisioning with REVOKE-removed and hook-re-added fixtures, the
  extension-list default with its own control, Redis's exact tag with a
  `latest` fixture, and the SECRET RECORD tripwire checked both ways
  (key-removed and unrecorded-key fixtures), each red-first with its
  control.
  **What remains unproven, and is stated rather than hidden:** the live
  boot — and two things sharper than that. Per-database `CREATE EXTENSION`
  is the one line of the local contract the Cluster does NOT reproduce: no
  CNPG bootstrap hook can run DDL inside each service database (the app-hook
  runs as a non-superuser and is refused; the superuser hook cannot reach
  across databases), so the manifest carries neither and the extension list
  is declared-and-validated only; none of the launch services reads vector.
  And the CNPG `spec.managed.roles` shape (plus the pod-label wait) is read
  from documentation knowledge, not verified against the CRD source or a
  live apply — the first real boot is what proves it. This machine has no
  root, no Linux kernel and no cluster, so nothing here was installed;
  whether the Cluster reaches Ready and the secrets boot the services is a
  customer-box claim.

- **The install host: `kit-install.mjs` serves `install.sh` at
  `kit.cafaye.com`'s root.** `DEPLOYMENT.md` decides the product's front
  door — `curl https://kit.cafaye.com | sh` — and the script it serves has
  existed since W74 with nothing behind the URL: measured fleet-wide,
  `grep -rln 'kit\.cafaye\.com'` returned only documentation and
  `install.sh` itself; no Worker, no wrangler config, no static host. W74's
  own report named the gap. This packet closes it in kit, because the script
  and its delivery are one fact and belong in one repository and one gate —
  the same reasoning that put the chart-publish seam control in kit.
  `templates/substrate/kit-install.mjs` is a Cloudflare Worker (the fleet's
  established mechanism — `site` and `parlor` are Workers) serving the
  **exact bytes** of `install.sh` at `GET /` and `GET /install.sh` with
  `content-type: text/x-shellscript` and no transformation — `curl | sh`
  executes whatever bytes arrive, so a Worker that reformats, wraps or
  minifies the script is a Worker that breaks the install. Every other path
  404s, including traversal (the URL parser resolves `..` before the handler
  reads the pathname, so `/install.sh/../secrets` arrives as `/secrets`),
  and `GET /healthz` is 200 so the host is observable. The script is
  **imported, not copied**: `wrangler.jsonc`'s Text-module rule bundles the
  file's bytes at deploy time, so the served bytes and the file are one fact
  with one author and there is no hand-copied second file in the tree. The
  Worker holds no secret — `install.sh` reads `KIT_SUBSTRATE_PULL_SECRET`
  and `KIT_SUBSTRATE_ACME_EMAIL` from the operator's environment at run
  time. `wrangler.jsonc` carries no `routes` block, matching the fleet
  (measured: `site`'s has none) — binding `kit.cafaye.com` to the Worker is
  a Cloudflare route/custom-domain **action**, not a file, and cannot be
  asserted from this repository. `check_install_host` in `tests/validate.sh`
  proves it in kit's own gate with no network: it imports the handler as a
  plain module (a loader hook stands in for the Text rule), compares the
  served body's SHA-256 against the file's — not a prefix, so a truncated or
  re-encoded body reds — and requires two controls to go red (a fixture
  whose `install.sh` is one byte shorter; a fixture with the wrong
  content-type). **What remains unproven, and is stated rather than
  hidden:** that `https://kit.cafaye.com` answers. The Worker, its config
  and the byte-equality are proven; the binding is an operator action and
  the URL works only when observed.

- **The publish end of the pull-based loop: `chart.reusable.yml`, the
  composed `publish.reusable.yml`, and the caller template.** `DEPLOYMENT.md`'s
  deploy loop is pull-based — a commit changes a chart, Argo makes the box
  agree — and only the consume end existed: eight Argo CD `Application`s pull
  `oci://ghcr.io/cafaye/charts` and nothing in the fleet ever ran `helm push`
  or `helm package`, so every `Application` pointed at a registry nothing
  wrote to, and the failure is silent — Argo reports no error, it just never
  finds the artifact. `.github/workflows/chart.reusable.yml` is a
  `workflow_call` reusable workflow that packages the chart directory and
  pushes it to the Helm OCI registry, modelled on `image.reusable.yml`: `push`
  is an input defaulting to **false** (a reusable workflow that publishes by
  default is one every caller publishes from by accident); `registry` defaults
  to `oci://ghcr.io/cafaye/charts`, the exact string every `Application`
  carries as `source.repoURL`; `chart-dir` defaults to `chart/`, where
  `caf gen chart` writes. The chart's **name and version are read from
  `Chart.yaml`, never inputs** — the OCI tag of a Helm chart IS its `version`,
  so the push tag and the pull `targetRevision` are one fact written twice,
  and an input is a string a service copies into its own repo, which drifts
  from the chart it names. The credential is the workflow's own `GITHUB_TOKEN`
  (`helm registry login ghcr.io`, no PAT, nothing to rotate) with
  `packages: write` declared in the job and **granted by the caller** — a
  reusable workflow can request a permission but cannot grant itself one.
  helm is pinned (`v4.3.0`, via the upstream script's own `--version`
  mechanism), never `latest`; the job **refuses to publish from a
  `pull_request`** regardless of what a caller asks, because a fork's token
  is read-only and publishing from a PR is a registry write by untrusted
  code; and the chart the repo declares is the chart that is pushed —
  `version`/`appVersion` are never rewritten from git and no `latest` tag is
  added. One measured correction from the first draft: `helm push` APPENDS
  the chart's own name and version to whatever remote it is given, so the
  push target is the registry (`oci://ghcr.io/cafaye/charts`) and the name
  read from `Chart.yaml` appears only in the reference the log prints —
  pushing at `oci://…/charts/<name>` lands the chart at
  `charts/<name>/<name>:<version>`, which no `helm pull oci://…/charts/<name>`
  will ever find (measured against a local registry).
  `.github/workflows/publish.reusable.yml` composes the two halves — one
  `workflow_call` calling both `image.reusable.yml` and `chart.reusable.yml`
  with the caller's single `push` threaded through — so a service's
  `publish.yml` is one `uses:` and the decision "what does a push publish" is
  made once, in kit. It declares the full `contents: read` + `packages: write`
  set at top level so the nested jobs keep `packages: write` through two
  levels of `workflow_call`, and its `concurrency.group` is `kit-`-namespaced
  per the fleet rule. `templates/publish/publish.yml` is the caller a service
  copies: `on: push: branches: [master]`, both permissions, a non-colliding
  concurrency group with `cancel-in-progress: true`, and
  `uses: cafaye/kit/.github/workflows/publish.reusable.yml@master` with
  `push: true`. `check_chart_publish` in `tests/validate.sh` proves the
  publish/consume seam in kit's own gate — the workflow's default registry
  against every `Application`'s `source.repoURL` — with two controls that
  must go red (a drifted `repoURL`; `push`'s default flipped to true), and
  `templates/publish/*` joins the artifact-parses loop. **What remains:** the
  charts themselves do not exist yet — each service runs `caf gen chart` and
  commits `chart/`, and copying the caller into gateway, courier, parlor (and
  migrating identity off its direct `image.reusable.yml` call) is one
  adoption packet per repo.

- **The two Let's Encrypt `ClusterIssuer`s, and the install step that applies
  them.** A service chart annotated `ingress.clusterIssuer: letsencrypt-prod`
  pointed at nothing: the substrate created no issuer at all, cert-manager had
  no `Certificate` to issue, and Traefik served its own self-signed fallback —
  the customer's first impression of the product was a browser warning, with
  no error an operator would ever be shown. `manifests/tls/clusterissuer.yaml`
  now holds `letsencrypt-staging` and `letsencrypt-prod`, identical but for
  the ACME directory URL, solved with HTTP-01 through Traefik's ingress class
  by `ingressClassName` — the field the pinned cert-manager v1.21.2 CRD
  recommends, verified against the release asset rather than memory. The
  solver decision is HTTP-01 because it needs no credential (`DEPLOYMENT.md:28`
  makes Cloudflare a DNS change, never infrastructure), because Traefik is
  already there, and because the cost — wildcards — is a capability this
  product does not need; DNS-01 is not implemented and the README says why.
  Staging exists because Let's Encrypt's production limits (5 duplicate
  certificates a week, 5 failed validations an hour) let one afternoon of
  debugging burn a week of TLS, and the two account keys are distinct because
  staging and production are separate ACME accounts. `install.sh` step 7
  applies them: `KIT_SUBSTRATE_ACME_EMAIL` is read from the environment,
  validated by shape (exactly one `@`, something either side, not the
  `example.com` family — a refused registration reads as a network error from
  the customer's side), substituted into the manifests in a pipe so the value
  reaches the API server and is never written to disk, and never printed. The
  manifests carry the `ACME_EMAIL_PLACEHOLDER` token, never an address: a
  literal would put cafaye's address, or a made-up one, on a customer's ACME
  account. `tests/substrate_test.sh` proves the static half with a control per
  claim (a shared account key, an empty solver list), and the README records
  that whether Let's Encrypt actually issues remains a box-level claim.

- **`nats-stream-init`: the stream the fleet publishes to, defined once, by the
  stack, idempotently.** Every outbox publisher sends each event to a subject
  equal to its event type — no mapping table, no prefix rewriting — and a
  subject no stream claims is a publish the broker neither acks nor refuses:
  the row stays in `outbox_events` with `attempts` climbing and no event ever
  leaves the table. The stack ran NATS with `-js` and defined no streams, so
  on a fresh clone the bus was a black hole. A one-shot service now creates
  the stream on every `bin/dev up` and exits 0: subjects `identity.>`,
  `billing.>`, `courier.>`, `muse.>`, `darkroom.>` (one prefix per publishing
  service, enumerated rather than a bare `>`, which would claim `$JS.>` and
  `$SYS.>` traffic and make the coverage unauditable); storage `file`, retention
  `limits`, max-age `7d` (the replay window a consumer's replay rests on),
  discard `old`, replicas `1`, ack on. It is idempotent by construction —
  `nats stream info cafaye || nats stream add …` — because a plain `add` exits
  1 on the second run ("stream name already in use with a different
  configuration (10058)", measured), and `--defaults` is load-bearing because
  the CLI asks for confirmation and exits 1 with no terminal. It waits for the
  broker with `depends_on: nats: condition: service_healthy`, and runs
  `restart: "no"` — `unless-stopped` would loop, `always` would hide a failed
  add. The publisher still creates no stream: a stream's name, retention and
  replication are a deployment decision, not a service's. The image is
  `natsio/nats-box:0.20.0` — the Docker Hub spelling of the GitHub release
  `v0.20.0`, whose `v` is a GitHub convention; `natsio/nats-box:v0.20.0` does
  not resolve (measured). `tests/nats_stream_test.sh` proves the static half
  with a control per claim (a `latest` pin, a missing `depends_on`, a dropped
  `identity.>`, a bare `>`, a plain non-idempotent `add`, memory storage and a
  tag disagreement each go red under the same check the real tree passes); the
  live half — the stream is created, the second `up` is a no-op, a publish
  reaches a subscriber — was measured on this machine and is recorded in the
  packet's report, not as a tier. An event whose prefix is not covered does not
  leave its publisher's outbox table; pantry, core and gateway are deliberately
  uncovered (pantry's manifest states it publishes nothing, core is the spec
  repository, gateway declares `events: []`).

- **`templates/substrate/`: the customer substrate — the one-command install,
  and the Applications that make it real.** `install.sh` is the executable
  half of `DEPLOYMENT.md`: it installs k3s (single node, sqlite), cert-manager,
  CloudNativePG, Argo CD core, the GHCR image pull secret (from
  `KIT_SUBSTRATE_PULL_SECRET`, never a literal), and the first Applications, in
  that order. Every version is pinned exactly — k3s `v1.37.1+k3s1`,
  cert-manager `v1.21.2`, CloudNativePG `v1.30.1`, Argo CD `v3.5.4` — each
  verified against the GitHub releases API on 2026-10-07. The script is
  idempotent (`kit_substrate_guard` is the named per-component guard), fails
  loudly and early (no root, no curl, non-Linux, unsupported arch, <4GB RAM,
  unreachable registry each refuse by name before anything is half-installed),
  and `DRY_RUN=1` prints every step and executes nothing. The eight
  `Application` manifests are the four launch services (identity, gateway,
  courier, parlor) and the observability set (Alloy, Loki, Grafana,
  Prometheus); traces are deferred, so there is no Tempo Application.
  `tests/substrate_test.sh` proves the parts that need no box — the script
  parses, DRY_RUN runs to completion printing the six steps in order, every pin
  is exact, every manifest parses with `spec.source` and `spec.destination`, no
  image floats on `latest`, and no secret is a literal — and every claim has a
  control that must answer differently (a `latest` pin, a broken manifest, a
  planted `:latest` tag and a planted `stringData:` secret each go red under
  the same check the real tree passes). **What is NOT proven, and is written
  as unexercised rather than done:** that k3s installs, that Argo syncs, that
  the charts exist. This machine is macOS and cannot run k3s, so `install.sh`
  has never been executed here; the proof is `DRY_RUN=1` plus the checks.
  `templates/substrate/README.md` carries the same sentence, and names what a
  customer box must still prove.

- **`tests/lint_test.sh`: the four independent lint sections now run
  concurrently.** The go/ruby/node/yaml sections each build their own fixture in
  their own subdirectory of `$WORK` and share nothing but the helper
  functions, so they overlap with shell `&` and `wait` instead of running
  serially. The verdict is preserved by the same rule the serial path used:
  each section writes to its own log, the logs print in order, and a `FAIL` or
  `SKIP` line in any log makes the whole script exit 1. The check id in
  `validate.sh` is unchanged and the gate's verdict count is unchanged (one
  PASS for `lint_test`). Measured: 31.62 s serial → 26.4 s parallel
  standalone, exit 0, all 22 assertions green; a full-gate after-run confirms
  it end-to-end — the check row reads 24.332 s against the before-run's
  31.625 s, with identical verdict counts (157 PASS / 0 FAIL / 5 SKIP) and
  identical check ids. The saving is bounded by the slowest linter (eslint,
  which does `npm install`), not by the sum. This is the one cut the
  honest profile's levers yielded: the parse region is already at the 4-way
  cap and spawn-latency-bound, the docker tiers are substrate-backed, and the
  remaining serial static checks are each under 0.1 s.

- **`REPORT-kit-m44-gate-profile-truth-01.md`: the two written answers — the
  gate tests no other repository, and `tests/validate.sh` is still needed.**
  (a) Confirmed with a command of the same shape as the manager's: zero
  `$ROOT/..` references in `tests/`, the only `../` hits are fixture strings
  (a relative-path shape the provenance stamper must refuse), every `git
  clone`/`fetch` is over `file://` against a bare repo the gate builds from
  its own tree, and every `curl` is localhost or a GitHub release. (b)
  Inventoried the six docker/network tiers with the substrate claim each
  alone proves, and recommended **keep**: the gate is the only proof of those
  claims, and the profile shows the top costs are substrate-backed tiers and
  an already-parallel spawn-latency-bound parse region, so no cut keeps
  every check and every verdict. The cut was assessed and not made; the
  honest profile and the two answers are the deliverables.

- **`PROFILE-gate-honest.md`: the measured re-derivation of the gate profile,
  from one complete run.** 493.30 s wall clock, 157 PASS / 0 FAIL / 5 SKIP,
  exit 0 — every row a real interval, the 28 `phase` + 2 `par` rows tiling
  the run to within 0.026 s. The honest top costs: the observability tiers
  (200.06 s as a phase, `no_telemetry_in_readiness` alone 63.29 s), the parse
  region (99.20 s, 55 parallel checks, spawn-latency-bound), and `lint_test`
  (31.62 s). The old table's headline — `self_test` at ~96% — is doubly
  retired: the tree-copy layer is gone (`32df467`) and the number was a
  projection from a bad mean. Four of the old rows are gone with it
  (`self_test`, `stack_live_test` as a tier, `staleness_test`, `gitleaks_gate`)
  and the rest are re-measured. Also names the one thing the leaf table cannot
  see: ~99 s in the observability phase and ~22 s in the fetch section that no
  check row claims — real wall clock outside any `check`/`tier` call.

- **`REPORT-kit-gate-speed-overlap-01.md`: the gate-speed packet's target was
  retired before it was dispatched, and the measurement that proves it.** The
  packet commissioned overlap for the 73 `--only`-filtered child gates; those
  lived in `tests/self_test.sh`, which `32df467` deleted on 2026-10-05 by the
  owner's explicit "no tree copies at all" decision — a breakage *was* a tree
  copy, so the layer went whole. Measured across five full-gate runs on
  `08dcccd` (729–968.9 s end-to-end, was a projected ~5,103 s), with zero
  `self_test` rows in the profile and identical PASS/FAIL/SKIP counts in
  every run. No change was made to the gate; the report is the deliverable,
  per the packet's "a measured blocker is a good outcome" clause. It also
  names the one environmental flake seen en route — `onecluster_test.sh`
  failing with "the database system is shutting down" on this shared box,
  green on re-run — and records that the remaining big items are docker-backed
  tiers this packet's own flakiness constraint puts out of scope.

### Fixed

- **Two concurrent onecluster runs could probe the same 10-port block free and
  one died binding it.** `tests/onecluster_test.sh` probed a block and only
  later bound it in `bin/dev up`, and the `$$ % 400` seed does not stop two
  runs starting at the same offset — measured 2026-10-07 as a false RED on a
  tree absent from the onecluster path. Selection now `mkdir`-claims the block
  (atomic across runs; a claim, not a lock, so stacks still start in parallel)
  and releases it in the EXIT trap; stale (owner-dead) claims are reclaimed,
  live ones skipped. `tests/onecluster_ports_race_test.sh` starts two
  `--select-block` selectors at once with the same seed and requires different
  blocks, and runs in the gate's phase 40 (no docker, ~10 s).

- **`KIT_PROFILE` recorded a parallel region's wall clock nowhere, so the
  `phase` row of whatever `section` came next absorbed it whole.** A
  `par_begin`…`par_flush` region's span is now a row of its own — kind `par`,
  measured from the last phase marker to the flush — and `_pf_last` is
  re-armed at the flush, so a phase row covers only the work after the region
  it follows. Until this, `static: handed-out scripts are executable` profiled
  at 212.3 s (a `for` loop over ~25 files doing `[ -x "$f" ]`) and
  `static: templates/otel` at 45.3 s: both were join artifacts — the parse
  region's and the shellcheck region's wall clock respectively, each charged to
  the section that merely followed it. The `cpu` rows already overlapped inside
  the span, so the span itself was the one number nothing recorded. `par` rows
  tile with `phase` rows (regions never overlap each other) and are summed with
  them and never with `check`/`cpu`/`tier`; `tests/profile_report.py` reads the
  new kind. The TSV's four-column shape is unchanged.

- **`templates/kamal/deploy.yml.erb`: the proxy healthcheck path was `/up`, a
  path no adopting service serves — a deploy that could not succeed.** All six
  services that adopt this template (`identity`, `courier`, `gateway`, `parlor`,
  `darkroom`, `muse`) serve `/healthz` and `/readyz`; none serves `/up`.
  `billing` serves `/up` (Rails' boot check) and does not use this template.
  Kamal gates the rollout on that path, so a fresh copy of the template
  deployed a container the proxy probed, read 404 from, and never accepted.
  `identity` and `courier` each hand-patched their own copy to `/readyz`; the
  template catches up to them. The default is now `/readyz`, and
  `tests/kamal_agreement_test.sh` fails if it ever drifts back to a path the
  fleet does not serve.

- **`templates/kamal/README.md`: it told services to set a `migrate` command in
  `deploy.yml.erb` — a key the template does not have and Kamal 2 refuses.**
  `migrate:` was Kamal 1's way; Kamal 2.12.0 rejects the config outright with
  `unknown key: migrate` (measured against courier's copy). Migrations run from
  `.kamal/hooks/pre-deploy`, which is not a key in the file at all. Following
  the README produced a config kamal rejects. The README now says so, and the
  agreement test fails if it ever names a key the template does not have.

- **`templates/kamal/README.md`: the adoption steps never copied `drill.sh` to
  `bin/drill`.** A fleet-wide search finds `bin/drill` in zero repositories: the
  backup path is configured and never proven to restore, which is the one thing
  a backup is for. Step 1 named the two `.erb` files but not the drill, so a
  service that followed the steps exactly ended up with backups configured and
  no way to prove them. Step 1 now names the drill copy, and the agreement test
  fails if the adoption steps ever stop producing it.

- **`templates/bin/dev.sh`: `stack_is_usable` checked `templates/compose/` but
  not `templates/kamal/`.** A service pinned at a ref without `templates/kamal/`
  fetched a tree that passed every compose check and was still missing the files
  its adoption steps tell it to copy (kit-23's defect 1). The kamal files are
  now part of the existence check. Every caller either falls through to a
  re-fetch or dies with a re-vendor message, so a stricter check does not strand
  an existing cache.

- **`bin/dev`: replacing a populated cache RETIRES it instead of deleting it,
  which is the difference between a stack that serves and a stack that reports
  itself broken.** `fetch_stack` used to end with `rm -rf "$dest"; mv "$tmp"
  "$dest"`. The cache directory is not kit's to destroy: `docker compose`
  bind-mounts files out of it into running containers, and on macOS a bind mount
  resolves its source **when the container is created**. So the delete left every
  container serving off descriptors it already held while every **new** open
  through the mount path failed `no such file or directory`. Measured on this
  machine with seven containers up for three hours: the collector kept serving
  the whole time and only its **healthcheck** went red, because the healthcheck
  re-reads the config through the mount on every probe — which then failed
  `bin/dev up` with `stack did not become healthy`, so the recovery path was
  also the thing reporting the fault, and the first run lost its readiness budget
  to a checkpoint that took 271s to write. Replaced with a generation swap:
  `mv "$dest" "$(next_generation "$ref")"`, then `mv "$tmp" "$dest"`. Both moves
  are renames within one filesystem, so **the property the old comment was buying
  is kept** — a second `bin/dev` in another terminal never sees a half-populated
  directory, and there is no instant at which the cache path is neither the old
  tree nor the new one. **Moving it aside is not the whole fix, and the half that
  is easy to get wrong is measured:** a retired generation is the same inode the
  containers are mounted to, so deleting it *later* breaks the mount exactly as
  the original delete did. Against a real container re-reading its mount path
  once a second — rename aside → **OK**, then delete the renamed copy →
  **`no such file or directory` on the very next probe**. So
  `prune_generations` **asks the daemon** (`docker inspect` over every container's
  `.Mounts`) and retains any generation something is mounted from, oldest-first,
  beyond `KIT_STACK_KEEP_GENERATIONS` (default 3). It retains on every answer it
  cannot get — no `docker`, no daemon, `docker info` failing — because reclaiming
  a few hundred KB is never worth a developer's running stack, and a machine that
  cannot answer has no containers mounted from these paths either. The cold path
  never starts a docker process: there is nothing to prune on a fresh cache.
  `tests/fetch_test.sh` gains section 8, which puts the cache in the only state
  that reaches `fetch_stack` with something already there (a populated tree that
  fails `stack_is_usable`), and asserts **both** halves — the new tree is
  correct, and the retired tree's files still open. It needs no daemon, because a
  rename keeps the inodes linked and an unlink does not, which is the filesystem
  statement of the container claim. Mutation: restoring `rm -rf "$dest"` turns
  it red on exactly that assertion.

- **The collector healthcheck's comment described a check the command does not
  run.** `templates/compose/docker-compose.yml` said the healthcheck was "the
  `health_check` extension's real endpoint, not `components`", because `up
  `--wait` should wait for the pipelines to be wired — while the command was
  `otelcol-contrib validate --config=…`, which proves the file parses **from
  disk**. Weaker claim, stronger words, one line apart, in a repository whose
  stated rule is that prose is load-bearing. **Measured whether the stronger probe
  is reachable, rather than assuming:** the whole rootfs of
  `otel/opentelemetry-collector-contrib:0.115.1` is `/otelcol-contrib`,
  `ca-certificates.crt` and the usual empty `/proc`, `/sys`, `/dev` — no shell, no
  `curl`, no `wget`, no `nc` — and the binary's entire command set is
  `completion`, `components`, `help`, `validate`. A compose `test:` in `CMD` form
  execs one binary, so nothing inside the image can open a socket to
  `${KIT_OTEL_HEALTH_ENDPOINT:-0.0.0.0:13133}`, and `CMD-SHELL` would need the
  shell that is not there. So the endpoint is genuinely not reachable this way, and
  the comment now says **what `validate` proves** (the config is readable through
  its bind mount and parses — both load-bearing, and the mount is the thing that
  breaks) and **what it does not** (that the pipelines are wired). The check is
  not deleted: a container that is up and misreporting is worse than one that
  reports nothing, and this one catches a real class of failure — it is the probe
  that surfaced the cache-eviction defect above.

### Docs

- **`AGENTS.md` listed six of the eight suites in `tests/`.** `tests/validate.sh`'s
  gate list and the layout tree both omit `tests/onecluster_test.sh` and
  `tests/failfast_test.sh`, both of which exist, both of which are registered in
  `validate.sh`, and both of which run. Two names added to each of the two places
  that enumerate the suites.

- **`tests/onecluster_test.sh`: the packet's own question, asked of `bin/dev`
  rather than of a compose file.** `tests/isolation_test.sh` already proves
  database-per-service isolation on a two-tenant cluster, and it proves it well —
  but it brings the stack up with its own `docker compose --project-name … up
  -d --wait postgres` call, which is why it can move one port and start one
  container. So the property was proven and **the developer's path to it was
  not**: every step between a person and that cluster lives inside `bin/dev` — the
  ref validation, the `.env` creation, the compose argument assembly, the
  readiness wait — and no tier in `validate.sh` invoked `bin/dev`. A `bin/dev`
  that resolved the wrong project directory or waited on the wrong health signal
  would have left both cluster tiers green. This tier runs `bin/dev up` against a
  service fixture and asserts on the world afterwards: exactly one postgres
  container in the run's compose project, two databases with a non-superuser
  owner role each, two non-owner `LOGIN` roles with the membership running
  owner→app in one direction only, **both services answering a real query as
  their own role** (write, read back, pgvector) in their own database, and —
  the negative control on that last claim — neither reaching the other's database,
  refused at the door by `permission denied for database`. 7s, one container, two
  databases. Registered in the observability phase beside its two siblings and
  not inside `RUN_STATIC`, because a security property nothing executes is worth
  nothing.

- **THE PORT BLOCK IS NOT COLLISION-FREE FOR A SECOND CHECKOUT, and the compose
  file says it is.** `templates/compose/docker-compose.yml`'s port block states
  that the 15000-15999 range "makes two checkouts on one laptop a non-event". It
  is, for **postgres** — whose default is the port most likely to be taken and
  therefore the one you move. The other published defaults sit *inside the same
  range*: nats 15600/15700, redis 15800, grafana 15000, tempo 15900, loki 15901,
  clickstack 15910. `bin/dev up` brings up postgres, nats, redis and the
  collector, so a second checkout beside a running one collides on the first of
  those it reaches. Measured, on this machine, against a developer's own running
  `cafaye` stack: moving only `KIT_POSTGRES_PORT`, as `isolation_test.sh` does,
  fails with `Bind for 0.0.0.0:15800 failed: port is already allocated` — on
  redis, the third container, **after** postgres had already been allocated.
  `tests/onecluster_test.sh` moves all five ports of the cheap stack from one
  free 10-port block as a result. **The defaults are not changed here**: that is a
  different packet, it touches every adopting service's `.env`, and the brief for
  this one holds the compose template's contract load-bearing. Reported with the
  measurement instead, because a documented claim that is false for four of six
  services is a thing a reader believes.

- **`tests/failfast_test.sh`, a new suite that EXECUTES the fail-fast path rather
  than grepping for it.** Seven claims: the refusal is nonzero, arrives under a
  **measured** 10s budget, names the variable, prints the line to set it, creates
  no container (read back by compose project label, because a developer's own
  stack is running on the machine the suite shares), never reaches compose, and —
  **the control** — a set variable does reach compose. Two further claims cover
  set-and-empty being equivalent to unset, and the required set being *derived*:
  a service's own bare `${VAR}` in its own `docker-compose.yml` is caught, and one
  carrying a `:-` default is not. Measured able to go red: removing the single
  call to `preflight_required` from `up()` — one line, restored with
  `git checkout` — produces **5 failed assertions**, and two of them were wrong
  in a way worth recording. `compose_progress` anchored at `^` while compose
  indents its output, so a control run that had demonstrably created three
  containers was reported as never reaching compose; and the teardown named
  `postgres-1`, `postgres-data` and `platform`, leaving three containers and two
  volumes behind on the machine. Both are fixed — leading whitespace allowed, and
  cleanup sweeps by project label — and both are the same shape as the defect
  this suite exists for: an assertion that cannot see the evidence in front of it,
  and a teardown that quietly stops covering the stack. Note which assertions
  stayed green under that mutation: *"an uninterpolatable stack is refused"* and
  *"refused in 3s"* both passed with the preflight gone, because the stack failed
  anyway, later. A non-zero exit is not evidence of a *fast* refusal.

- **`bin/dev` no longer spends its whole readiness deadline noticing one missing
  `.env` line.** Docker Compose does not refuse a bare `${VAR}` — it substitutes
  the empty string and logs one warning — so a service that never declared itself
  in `KIT_POSTGRES_DATABASES` came up with a postgres container whose init script
  refused at its `:?` guard, exited 1, and was only reported when
  `up -d --wait` ran out its 180s budget. Five attempts is the 900 seconds the
  packet names; the variable cost was never the check. `preflight_required` in
  `templates/bin/dev.sh` now derives the required set from the compose files
  themselves — every `${NAME}` with no `:-`/`-`/`:?`/`?` operator, in kit's base
  **and** the service's own override — and refuses before the first
  `docker compose` call, naming the variable and printing the line to add. The
  set is derived rather than restated on purpose: a list kept in the script would
  be a second copy of a fact the compose file owns, and would go stale the way a
  duplicated property does. **Empty counts as missing**, because
  `.env.example` ships `KIT_POSTGRES_DATABASES=` empty and `ensure_env` copies it
  to a fresh clone — so the most likely state of a new checkout is the variable
  present and blank, which compose also substitutes away.

- **Two sentences of the SDK-2.x prose contradicted the evidence written to
  support them.** `hono.ts.snippet`'s comment claimed SDK 2.x removed
  `register()` from the base provider and that `NodeTracerProvider extends
  BasicTracerProvider` *without redeclaring it* — the second clause is false, and
  `npm pack @opentelemetry/sdk-trace-node@2.11.0` shows why:
  `build/src/NodeTracerProvider.d.ts` declares
  `register(config?: SDKRegistrationConfig): void;` on the subclass. The method
  **MOVED**, it was never removed, and a file a service copies without compiling
  should not tell the next reader to go looking for a nonexistent API. The
  conclusion — do not call it here, install the context manager explicitly —
  stands: the call fails because the snippet's own `provider` is typed
  `BasicTracerProvider`. Separately, `pins.md`'s sentence above a **four**-row
  table said "Three calls … and two of the three fail silently"; it is **four**
  calls and **one** of the four is silent, which is what the next paragraph
  already said. A third instance of the same miscount was in
  `templates/otel/node/README.md` ("three of the four used to be in the
  snippet"): `git show d905728~1:templates/otel/node/hono.ts.snippet` shows all
  four as live code. Prose only; no behaviour, test or decision changed.

- **`templates/otel/node/hono.ts.snippet` called four APIs the versions
  `pins.md` pins have removed, and one of them failed in total silence.**
  `provider.addSpanProcessor(...)` and `loggerProvider.addLogRecordProcessor(...)`
  do not exist in SDK 2.x (processors go in the constructor, as `spanProcessors:`
  on the traces side and `processors:` on the logs side); `new
  BatchSpanProcessor({ exporter })` is not that package's constructor at all,
  which is `(exporter, config)` — read as JavaScript it builds a processor whose
  `_exporter` is an object and dies on the first export rather than at boot;
  and `provider.register({ propagator })` is `NodeTracerProvider`'s method, not
  `BasicTracerProvider`'s. **The expensive one is the last:** `register()` used
  to install a context manager as a side effect, so the snippet installed none,
  which made every `context.with(...)` in its request path a no-op that still
  runs its callback. The span is exported with the right `service.name`, nothing
  downstream attributes to the request, and a service copying this template
  emits spans that look entirely healthy and carry no trace context. The snippet
  now sets the three globals explicitly and installs
  `AsyncLocalStorageContextManager().enable()` — hence
  `@opentelemetry/context-async-hooks@2.11.0` as a new `pins.md` row, and hence
  no `@opentelemetry/sdk-trace-node`, whose `register()` this no longer uses.

- **The SDK-2.x removal class is now GATED, not just fixed.** Three new tests in
  `traceparent.test.mjs` read `hono.ts.snippet`'s source with comments stripped
  and fail on any of the removed spellings, require the three globals and an
  **enabled** context manager, and assert `register()` on a receiver *derived*
  from the snippet's own `new BasicTracerProvider(` assignment rather than a
  hardcoded name. The forbidden list is a table so a fifth removal is one row,
  and a fourth test runs a planted 1.x call against every pattern so a row whose
  regex cannot fire is caught as decoration rather than passing forever. The
  suite is executed by `tests/validate.sh` in the static phase, so this runs
  under both `--static-only` and `--language=node`.

- **`templates/otel/node` dropped every inbound traceparent, silently.**
  `propagation.extract(ctx, headers)` with a WHATWG `Headers` returns the context
  unchanged, because `@opentelemetry/api`'s default text-map getter is plain
  property access (`carrier[key]`) and a `Headers` keeps its entries behind
  `.get()`. Nothing throws and every span is still exported with the right
  `service.name`; the trace view shows a healthy pile of unrelated single-span
  traces. `hono.ts.snippet` now passes an explicit `TextMapGetter<Headers>`, and
  `traceparent.mjs`'s `header()` learned the same — the stdlib codec's README
  hands readers `c.req.raw.headers`, which is a `Headers`. Four assertions in
  `traceparent.test.mjs`, and **the node suite is now executed by
  `tests/validate.sh`**, which it was not: it only ever ran in
  `ci.reusable.yml`'s opt-in `telemetry` job, and kit calls that workflow with
  `language: none`, so on kit's own commits it ran nowhere.

- **`pins.md` named a package set that cannot be installed.** Two rows named
  versions that do not exist (`@opentelemetry/api@2.0.0` — there is no 2.x;
  `@opentelemetry/sdk-trace-node@0.57.0` — that package is at 2.x) and the rest
  could not be satisfied by one, since every SDK package peers
  `api >=1.3.0 <1.10.0`. Go rows said 1.34.0 while the three Go services in the
  fleet all run 1.46.0. Every row is now a version resolved by a service in this
  fleet against the real registry or module proxy, and every row names the
  repository it came from. The rust row is marked as the one thing **not**
  fleet-verified, because no service in the fleet is written in rust.

- **The Go snippet's exporter default dialled a port with no gRPC server on it.**
  `otelhttp.go.snippet` installs `otlptracegrpc` and defaulted to
  `http://otel-collector:4318`, which is the HTTP receiver's port; 4317 is the
  gRPC one. Both halves are now named together so neither is "fixed" alone.

### Changed

- **`templates/otel/go/README.md` documents both measured exporter defects** so
  no service rediscovers them: `WithEndpointURL` does not append `/v1/traces`
  (an HTTP defect), and `otlptracegrpc` defaults to TLS against a plaintext
  collector (a gRPC defect). Both produce a service that opens a socket to the
  collector and records nothing, with nothing thrown and nothing logged. Stated
  as a table with the choice of gRPC/4317 or HTTP/4318 as a legitimate one, and
  with which option you hold deciding which bug you have — the same `otlpconfig`
  lines set `Insecure` from the scheme, so `WithEndpointURL("http://…")` is
  already plaintext and only bare `WithEndpoint("host:port")` produces the TLS
  defect.

### Removed

- **Every check that read a repository other than this one.** `tests/fleet_check.py`
  (1169 lines), `tests/account_scope_fleet_check.py` (930),
  `tests/generated_stack_check.py` (716), `tests/gate_declaration_check.py` (582),
  the `account_scope_fleet_scope.yml` and `account_scope_fleet_ratchet.yml`
  tables, the `account-scope-contract` job in `.github/workflows/ci.yml`, and the
  fleet section of `tests/validate.sh`. Roughly 3,600 lines. The argument is
  `DECISIONS.md` MD36 and it is one line: **kit's gate asserts things about kit.**

  Two facts decided it rather than taste. `fleet_check.py` had **no test** — the
  only thing that ever proved it worked was `self_test.sh`, deleted earlier in
  this release — so 1169 lines of parser had been unexercised by a single
  assertion. And it **could not run where it belongs**: a clone of kit has no
  sibling checkouts, so every CI run took the `FLEET-ABSENT` branch and reported
  SKIP. The `account-scope-contract` job existed to work around exactly that, by
  cloning six `cafaye/*` repositories into a fleet layout so the check would have
  siblings to read. That is the removed `secrets` job's shape one layer down: a
  finding that lands on whoever maintains the repository that broke, not on
  someone who can fix it.

  The `kit.ref` adoption ceiling was the best argument for keeping the fleet
  check and it still lost, because it asks who *consented* rather than who is
  *affected*. Consent to be checked does not make it kit's job.

  Three rules that were mechanically enforced are now advice rather than
  controls: no adopter carries a D12/D13 workaround, no service sets
  `POSTGRES_USER`/`POSTGRES_DB`/`POSTGRES_PASSWORD` on the shared cluster, and a
  service's lint config matches kit's. `core` owns the first two. What is given
  up is kit noticing when a service stops obeying — recorded in MD36 rather than
  discovered later.

- **The rest of it, so the claim above is true rather than aspirational.** The
  first pass kept `tests/staleness.py` and the lint-drift check as "the next
  candidates", on the grounds that both were narrower and the first had 26
  assertions. Both claims were about the *program* rather than about what it
  *read*, which is the mistake MD36 exists to correct, applied inside MD36.

  Gone with them: `tests/staleness.py` (1414 lines) and its suite
  `tests/staleness_test.sh` — `--scope templates` takes `--repos-dir ..` and
  grades *each service's* copy of a template, so it never graded kit, and its 26
  assertions proved the reporter's output format against a synthetic fleet rather
  than any property of this repository. `lint_drift_check` and `fleet_repos()` in
  `tests/validate.sh` (~446 lines), which walked `../*` for a `.github/workflows`
  directory and took the SKIP branch on every CI run of every commit — plus its
  allowlist `lint/drift-allowlist`, whose 59 lines assigned dated debts in *other
  people's repositories* with an `owner=` field. And `tests/core_fanout_check.py`
  (338 lines), which had zero callers and a docstring claiming it was run by
  `validate.sh` under a name that appears nowhere in the repository.

- **Two files that existed only to serve those checks.** `tests/artifacts.json`
  (314 lines) declared what kit ships and where a service puts it;
  `templates/parity-allowlist` held 80 entries recording why a given service's
  copy was not kit's bytes. The staleness reporter was their only reader, so
  neither had a consumer the moment it went. Leaving a check's data behind is how
  a repository grows a second unwatched copy of the truth — the next reader
  assumes something grades it. Neither had any other reader in any language.

- **`tests/tenant_isolation/cross_tenant_harness.sh` now requires
  `KIT_SERVICE_REPO` and searches for nothing.** It used to guess by trying
  `$ROOT/../courier` then `$ROOT/../../courier` — the same failure mode as the
  fleet checks, finding a checkout named `courier` wherever one happened to be,
  including a leftover in a shared temp directory, and reporting on that. No CI
  job and no gate check runs this harness, so naming the service costs nothing
  and is the honest reading of what it is.

- **The committed-history secret scanner, and the job that ran it.** `gitleaks`,
  `.gitleaks.toml`, `tests/gitleaks_gate.sh`, the `secrets` job in
  `ci.reusable.yml`, the `KIT_GITLEAKS_VERSION` / `KIT_GITLEAKS_SHA256S` pins in
  `tests/bootstrap.sh`, and the three gate checks that policed them
  (`gitleaks_config`, `gitleaks_ignore`, `scan_behaviour`) are all gone.

  The argument is `DECISIONS.md` MD34, and it is one sentence: **a control whose
  subject is somebody else's repository is not one kit owns.** Every other job in
  `ci.reusable.yml` checks kit's own behaviour. This one scanned the adopting
  service's full git history, so when it went red the finding landed on whoever
  pushed kit rather than on the person who could fix it — and it was the one job
  no service could opt out of, so the first repository to adopt kit with an old
  credential in its history inherited a red build on day one. It was also already
  red: `gitleaks (required: could not be installed)` had been failing in CI while
  the gate's local copy of the same scan ran, which is the drift MD13 was written
  to prevent.

  What replaces it is `templates/secrets/` — the runtime canary — which was
  already the half that answers the question a history scan cannot: not *was a
  secret committed* but *does a secret reach an exporter*. That stays, and
  `canary_literal_check` still proves a canary value never appears as a literal.
  The committed-history half is now the host's push protection, which catches the
  credential on the push that introduces it and attributes it to the author.

  MD13 (one scanner, invoked two ways) is marked superseded; its principle is
  unchanged and now governs `tests/zizmor_gate.sh`, which still has both callers.

### Fixed

- **`image.reusable.yml` has never run. Its `stamp provenance` step read a
  variable it had never set, so `ghcr.io/cafaye/site` has never been
  published.** The step wrote the build timestamp as a PREFIX ASSIGNMENT on the
  command that needed it:

  ```yaml
  KIT_PROVENANCE_BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    KIT_PROVENANCE_SOURCE_DIRTY=clean \
    sh docker/provenance.sh --validate
  { echo "built_at=$KIT_PROVENANCE_BUILT_AT"; … } >>"$GITHUB_OUTPUT"
  ```

  `VAR=value cmd` exists in the environment of `cmd` and in no shell variable,
  so the `echo` two lines down read a name the shell had never been given. Under
  the `set -euo pipefail` every step in this tree begins with, an unset read is
  not an empty value — it is `KIT_PROVENANCE_BUILT_AT: unbound variable` and
  exit 1. Every one of `site`'s `publish` runs failed this way, back to
  2026-10-04; there has never been a green one.

  The other four fields in the same step were unaffected because they arrive
  through the step's `env:` block, which really does populate the shell
  environment. `built_at` was the only one created INSIDE the body, and the only
  one created as a prefix assignment — so the failure was invisible in review
  and identical on every run.

  `built_at` is now a plain assignment followed by `export`, and
  `source_dirty` stays a prefix assignment because the stamper is its only
  consumer. Two shapes for two jobs: the shape follows the consumer.

  `docker/provenance.sh` is **unchanged**, deliberately. `validate()` reads
  `${KIT_PROVENANCE_BUILT_AT:-}` and treats an unset field as `unknown`, which
  is correct for a developer's local `docker build`; the stamper was never the
  broken half. It is worth being explicit about what that leniency costs a
  proof, though: an unset field exits 0, so **a green `--validate` does not
  demonstrate the field arrived.** The export is verified by planting a
  MALFORMED timestamp and requiring the stamper to refuse it by name — the
  control being that the same stamp with the `export` removed passes, stamping
  `unknown`.

- **`run:` bodies are shell, and nothing in the gate ever looked at them.**
  `yaml.safe_load` on a workflow parses the DOCUMENT; a `run:` body is a string
  inside it, so every check the static phase ran was satisfied by the workflow
  that had just failed 179 commits running. `run_body_env_check` asks the
  question that is decidable from the text: is there a name this block creates
  for a command and then reads back as a variable?

  It knows the difference rather than the author having to remember it. A prefix
  assignment that is **never** read bare in the same block is left alone, because
  the command is its only consumer and the command did receive it — which is
  `source_dirty` in the step above and `GOFLAGS=-mod=mod GOPROXY=off
  GOTOOLCHAIN=local go test` in `ci.reusable.yml`, both correct and both
  untouched. Comments are stripped before the body is read, because the fix's
  own comment quotes the broken shape; a check a comment can satisfy is not a
  check, and one a comment can falsify is worse.

  Why a shape check and not a real run: executing every `run:` body needs the
  runner's services, the checked-out tree and each action's inputs, and a check
  that needs all three to reach a verdict is a check that silently stops
  running. The two halves were proved against throwaway fixture workflows — six
  shapes that must go red (single-line, three names on one command, a `case`
  arm) and three that must stay green (`export`, a later reassignment, a prefix
  assignment nothing reads back) — so the check is known to fire and known not
  to fire on correct code.

- **The gate resolved python properly and assumed every other toolchain was
  already on `PATH`.** `tests/bootstrap.sh` had a deliberate resolution order
  for the interpreter — `$KIT_PYTHON`, then `.venv`, then a `python3` that
  already imports yaml, then bootstrap — and `have()` in `tests/validate.sh`
  and `tests/lint_test.sh` was a bare `command -v` for everything else. That
  asymmetry is invisible in an interactive shell and fatal in a non-interactive
  one, because mise is configured in `~/.zshrc` and `~/.zprofile` and a gate
  launched as `bash tests/validate.sh` reads neither. On a machine with go,
  gofmt, node, ruby, elixir, golangci-lint and rubocop all mise-managed and
  installed, the gate reported `gofmt: command not found`, skipped three snippet
  checks and the canary suite, and failed the lint phase — because that phase is
  fatal on a skip, on the grounds that a skipped lint proof is not a proof. A
  fully equipped machine was reported as a missing-toolchain one.

  `kit_activate_mise` now runs before anything resolves an interpreter. It is
  `eval "$(mise hook-env -s bash)"` — mise's supported way to hand a shell that
  was never activated the environment it would otherwise have had — and it is a
  no-op when mise is absent, when the shell is already mise-activated
  (`$MISE_SHELL`/`$__MISE_DIFF`), or when mise has nothing configured, which is
  the CI case. It costs about 70ms. Both entry points call it, because
  `tests/lint_test.sh` is runnable on its own and cannot inherit
  `validate.sh`'s environment.

  kit still ships no `mise.toml` of its own, deliberately: pinning kit's
  toolchain here would be a second source of truth that a runner with no mise
  config cannot honour, and `templates/mise.toml` is already where that decision
  is made, per service. mise owns the versions; the gate asks it what the
  environment was.

- **A reusable workflow has no location of its own, and four `run:` bodies in
  `ci.reusable.yml` were reading one anyway.** `GITHUB_ACTION_PATH` is
  documented by GitHub as supported only in composite actions;
  `.github/workflows/ci.reusable.yml` is a *reusable* workflow, so the variable
  is not set in it. Under `set -euo pipefail` an unset variable is not an empty
  path — it is a fatal on the step's **first line**:

  ```
  …/_temp/9bf3851b-….sh: line 2: GITHUB_ACTION_PATH: unbound variable
  ##[error]Process completed with exit code 1.
  ```

  Measured in `cafaye/site` run 37236386666 and `cafaye/parlor` run 37230458669,
  on the `secrets` job — the one job in the file with no opt-in, the one this
  repository calls the only control a service cannot choose not to run. It was
  not a job that found nothing; it was a job that could not start. `zizmor` has
  the same defect and is fixed in the same place (it is gated on an input, so it
  has never run in the fleet), and so does `telemetry`'s fallback to kit's own
  copy of the conformance suite.

  **The file already knew.** The `kit-lint-ref` input's own comment names
  `GITHUB_ACTION_PATH` as composite-action-only and explains that kit's configs
  therefore have to be **fetched by a name** — and then five lines in three jobs
  contradicted it. The reasoning was applied to the lint configs and not to
  these. That is the whole of it: a rule written down once, obeyed in one place,
  and contradicted in another by nobody reading the other place.

  The fix is `uses: actions/checkout` of `cafaye/kit` pinned by
  `inputs.kit-lint-ref` — the same mechanism the six language jobs already use —
  and the tree lands in `$RUNNER_TEMP`, **not** `<working-dir>/.kit`: `secrets`
  runs a full-history git scan rooted at `$GITHUB_WORKSPACE`, and a second git
  repository inside the tree being scanned is a question with no good answer.

  **`kit_gate_tree_check` is the check, and it has four branches because writing
  it found two defects in it.**

  - 106 restores the variable.
  - 106b is the **obvious fix, refused**: deleting the lines turns a fatal into
    `bash: no such file or directory`, which is the same red job with the
    diagnosis further away, and a variable-only check calls that a pass. So the
    check asserts the *coupling* — a step reading the fetched tree needs a fetch
    above it.
  - 106c drops one checkout's `ref`. This recipe **found a real bug**: the pin
    was originally asserted inside a per-step loop, so it reported one unpinned
    checkout once per reading step and would have passed *entirely* for a
    checkout no step referenced. A check whose coverage depends on an unrelated
    step has a hole shaped like the defect it exists for.
  - 106d pins to the literal `master`. This is what `inputs.kit-lint-ref`
    evaluates to when a caller sets nothing, so it **looks** pinned; a check
    written as "is it pinned to something" accepts it, and a caller pinning
    `uses:` to a sha then gets that workflow with the gate scripts from `master`.
  - 106e is the **green control**, and it exists because this check's first
    version failed **seven jobs that were correct**. It looked for `tests/` and
    `templates/` anywhere in a run body, and every language job prints
    `See templates/tier/README.md` in an error message while running the
    *caller's* own gate. A check that fires on correct work teaches its reader
    to ignore it.

- **`tests/zizmor_gate.sh` read `$PY`, and the `zizmor` job never set it.** A
  second defect in the same job and the same shape as the one above: the script
  ends by piping zizmor's report through `"$PY" - …`, which in kit's own gate
  comes from `kit_bootstrap_python`. A reusable workflow makes no such call, so
  the job reached the script's last line and died on `PY: unbound variable`.
  Both are one mistake wearing two hats — a script written to be called by one
  caller and run by another that had not been read.

- **Every linted file gets type information, or the type-aware rules cannot run
  at all — and `recommendedTypeChecked` is UNSCOPED, so `files` is load-bearing.**
  `lint/eslint.config.mjs` enabled `tseslint.configs.recommendedTypeChecked` and
  supplied `parserOptions` under `files: ['**/*.{js,mjs,cjs,ts,tsx}']`. One
  config *inside* `recommendedTypeChecked` — `typescript-eslint/eslint-recommended`
  — declares `files: ['**/*.ts','**/*.tsx','**/*.mts','**/*.cts']`, which **adds**
  `.mts` and `.cts` to the set of files ESLint will lint. So every `.mts` file in
  a service was linted, was handed the type-aware rules, and was never handed the
  type information those rules require:

  ```
  Error: Error while loading rule '@typescript-eslint/await-thenable':
  You have used a rule which requires type information, but don't have
  parserOptions set to generate type information for this file.
  ```

  Measured in `cafaye/site` run 37236386666 and `cafaye/parlor` run 37230458669,
  on the `node` job — whose first real execution this was, suppressed for four
  days by the collision `ad3e320` fixed. Both services carry three root-level
  `.mts` files, so this was never marginal. The run dies at **exit 2 before
  reporting a single finding**.

  **The diagnosis that arrived with it was wrong, and the wrong one is the more
  useful half.** It was attributed to `tsconfigRootDir: import.meta.dirname` —
  kit's directory rather than the caller's. That is a real misconfiguration and
  it is fixed here, but it is **not** what produced the error. Measured on
  eslint 9.39.5 / typescript-eslint 8: with `projectService: true`, setting
  `tsconfigRootDir` to `/nonexistent-root`, or deleting it entirely, leaves the
  run byte-identical — the project service walks **up from the linted file** to
  find a tsconfig and never consults the root. A check written for the reported
  cause would have been green on the defect that actually shipped.

  `tsconfigRootDir` is still fixed, because it is load-bearing in exactly one
  place and it is a place kit would otherwise reach for: `allowDefaultProject`
  globs are matched **relative to it**
  (`useProgramFromProjectService.js` does
  `path.relative(parseSettings.tsconfigRootDir, filePathAbsolute)`). With kit's
  directory as the root, a pattern meant to cover the caller's own root config
  files resolves to `.kit/lint/*.mts` and matches nothing — and the error says
  so: `allowDefaultProject is set to ["*.mts"], which does not match
  '../../x.mts'`. A latent misconfiguration, invisible until the first entry is
  added. The value is now `process.cwd()`, which is the caller's workspace by
  construction because the lint step carries `working-directory:` — no new
  workflow input, so **no caller in the fleet needs a PR**.

  `.jsx` is deliberately still absent. Nothing above adds it to the linted set,
  so adding it would widen kit's lint in every service and turn each React repo
  red with `was not found by the project service`.

  **Two checks, because the two halves fail differently.**

  - `eslint_typed_scope_check` holds the invariant, in both directions: every
    extension the recommended sets can lint must be present, and an extension
    with no reason is a finding. It **strips JS comments before reading**, and
    that is not hygiene: the file now explains `tsconfigRootDir` in eleven
    comment lines, and the check's first version matched one of those and went
    red on a config that is correct. AGENTS.md's "a check that can be satisfied
    by a comment is not a check" has a mirror image that is worse — a check that
    can be *falsified* by one.
  - `tests/lint_test.sh` **runs** it, with six new assertions and three controls.
    The control for the pre-fix glob asserts the crash *by its own message*, not
    by its exit status, because the pre-fix failure was also red and was
    mistaken for the linter working. The `allowDefaultProject` pair had the same
    defect and it was caught by measurement: both runs exit non-zero, so two
    `red` assertions could not tell "the glob resolved and the linter found the
    bug" from "the glob matched nothing and ESLint exited 2 anyway". Reverting
    kit's `tsconfigRootDir` was 22/22 green until that was fixed, which is the
    same confusion as the defect itself: a red run that found nothing.

### Added

- **The README's file list is now closed in the direction a packet moves in.**
  `readme_check` walks a hand-maintained tuple of 25 paths and asserts two
  things per entry: the README names it, and it exists. So a documented path
  that was **deleted** is a finding — and a path that was **added** and never
  documented is not one at all. That second half is the half a packet produces,
  and it was not theoretical: `templates/deploy/` shipped a 1,067-line
  distribution and appears nowhere in the README, and
  `.github/workflows/image.reusable.yml` is kit's *second* reusable standard
  and appears nowhere either. Measured on this tree, 145 of the 175 tracked
  files under `reports/`, `tests/` and `templates/` are not on the tuple, and
  `grep -nE 'readme' tests/self_test.sh` returned **nothing** — so in a suite of
  107 recipes, not one had ever turned this check on in either direction.

  `readme_closure_check` is the companion. It **reads its coverage out of the
  README** — every path-shaped run of text, with `{a,b}` sets expanded and
  `<lang>` / `*` segments read as wildcards — and walks the five **adoption
  trees** (`.github/`, `core/`, `docker/`, `lint/`, `templates/`) asking
  whether every shipped path sits under one the README names. Coverage is per
  **tree**, not per file: that bound is the argument, because requiring a row
  per shipped file is the failure this check exists to prevent, and a README
  listing 157 paths is a README nobody reads. `tests/` and `reports/` are out of
  scope for stated reasons — one is the gate's own implementation, the other is
  packet evidence — and both exclusions are written into the check.

  Two properties are measured rather than asserted, in the check's own output:
  a new file **inside** a documented tree (`templates/deploy/reference/`) leaves
  the verdict green at 131 walked paths, and a new file **beside** one
  (`templates/payments/gateway.yml`) turns it red naming the path. The first is
  the control the check cannot lose — a closure check that demanded a row per
  leaf would be the 157-paths README wearing a smaller hat.

  Two README rows came out of it, and both were gaps rather than chores:
  `.github/workflows/image.reusable.yml` and `templates/deploy/`.

  **Two defects this found in the harness itself, both pre-existing and both
  the reason the first one was invisible.**

  - `fresh_copy` did not copy `reports/`, and `readme_check`'s tuple requires
    `reports/account-scope-contract-01/snapshot.sh` to **exist**. So every one of
    the suite's throwaway copies was red on an unbroken tree, and the control the
    file calls "the sentence that makes every proof below it meaningless" was
    printing `FAIL self_test: unbroken tree — the gate is RED on an unbroken
    tree`. Measured on `master` at `3cdcd3b`:
    `KIT_SELF_TEST_SHARD=1/104 bash tests/self_test.sh` -> that FAIL line, then
    `PASS self_test: breakage 1`, then `FAIL: self_test — 1 breakage(s) the gate
    did not catch.` Fixed by adding `reports` to `fresh_copy`'s copy list, which
    is the coupling `AGENTS.md` already states twice for `MIGRATIONS.md` and for
    `VERSION`/`RESERVED`. After: a whole `--static-only` gate on a copy is
    `EXIT=0`, 246 PASS, 0 FAIL.
  - The `failures` block stood **mid-stream**, between breakage 100's recipe and
    breakage 101's. A failure among 1-100 exited 1 there and 101-onward never ran;
    a failure among 101-onward was read by nothing, so the summary printed
    `PASS: self_test — all N breakages hold` and **exited 0**. It is now at the
    end of the recipe stream, after the shard branch and before the counts, so
    it sees every recipe and a sharded run still reports itself as a shard. The
    shard path's comment claimed "The un-sharded path below has always checked
    it"; it had not, and the same packet that taught one half of the file to
    judge its recipes left the other half asserting a property it did not have.

- **The account-scope contract is now continuous in a build, which it was not.**
  Six services declare their account-scoped surface in an `account_scope.yml`
  and `core/harness/account_scope_check.py` is what decides whether a
  declaration still describes its code. Measured before this change, **not one
  of the six ran it against itself**: the only references in the fleet were
  three declarations *mentioning* the tool, `core`'s CI running its own
  self-test over its own fixtures, and that self-test's script. So the contract
  was continuous in nobody's build — a service could add a route, widen a
  declaration, or delete `account_scope.yml` entirely and its own gate stayed
  green. `DEBT.md` D18's shape, one level up from where D18 had been looking,
  and the failure has a name in this repository's own history: *the gate that
  did not run the proof*.

  `tests/account_scope_fleet_check.py` runs core's checker over every repository
  `MVP-SCOPE.md` puts in the MVP — nine — and compares the answer with
  `tests/account_scope_fleet_ratchet.yml`, **in both directions**, so a
  repository that got worse is red and a repository that got *better* and whose
  row nobody retired is red too. That second half is the property a suppression
  list does not have, and it is why the record is a full row per repository
  rather than a list of things to ignore: a repository with **no** row is red,
  because adding a repository to the in-scope table has to be a deliberate act.

  **Five rules, and they are four rules plus a refusal.** Continuity: a
  repository that declares a surface and stops declaring one is red, derived
  from `git cat-file -e HEAD:account_scope.yml` because the checker alone reads
  a deleted declaration as one that was never written. Entry: an in-scope
  repository that has never declared is red unless it is on the `exempt:` list
  with a `condition:`. Propagation: the checker's exit code and its four counts
  are reported for every repository. Exactness: every recorded number is
  two-directional. And the refusal — **a run that cannot distinguish "this
  repository is clean" from "this runner read nothing" is red, not green**,
  which is the sentence this packet exists to write down. Five blindnesses are
  detected: a run that attributed no entry point to any registration, a
  declaration that sets `surface.minimum: 0` over source files that exist
  (`pantry`, live, and honestly self-declared), git history that could not be
  read, a `--only` or a scope table that selected nothing, and unreadable
  declared rows — which are counted and exact rather than passed over.

  **It runs in two places, because one would have been the defect again.**
  `tests/validate.sh` invokes it against the fleet beside the repository, with
  a **reported SKIP** when there is none — and a CI runner has none, so a
  second check asserts the wiring itself runs there. A new job in
  `.github/workflows/ci.yml` assembles a fleet of the nine and runs the
  contract for real. It carries no `continue-on-error`: a repository renamed or
  made private turns that job red, which is the state a reader can act on.

  **It replaces the five-function adapter contract rather than extending it**,
  and the reason is in the file: `adapter_install_probe` /
  `adapter_language_tool` / `adapter_migrate` / `adapter_prepare` /
  `adapter_run` are five questions about *running a service*, four of them about
  a live Postgres, and there is no service to run here. The discipline that
  contract carries — a run that could not happen exits non-zero and never
  reports a pass — is kept, and `up`/`run`/`down` is not.

- **A frozen copy of the fleet, because three sessions share this machine and
  two of them work in it.** `pantry`'s master moved twice while this was being
  written, once between two measurements of the same command forty minutes
  apart, so "the current baseline" measured against live working trees is a
  number that changes while the report is being typed.
  `reports/account-scope-contract-01/snapshot.sh` unpacks all nine at named
  commits with `git archive` (which reads a repository and writes nothing in
  it) and gives each copy a git repository of its own — because the runner's
  continuity rule reads `HEAD`, and a copy without history makes the runner
  correctly report itself blind, which is the runner working and also why the
  script commits what it unpacked.

- **A third cross-tenant adapter was attempted against `parlor` and WITHDRAWN,
  because no TypeScript service in this fleet holds a database.** The finding is
  measured rather than asserted: across `cafaye-ts`, `guard`, `parlor`, `site`
  and `docs` there is **not one import** of a postgres or ORM driver, **not one
  declared driver**, and **not one `.sql`** outside an `e2e/` fixture. So
  `adapter_migrate` has no migrations to apply, there is no write path to seed
  two accounts through, and there is no query layer for `adapter_run` to call as
  account A. The adapter is **undefined, not unfinished**.

  `reports/tenant-adapter-ts-01/subject-audit.sh` is the measurement, and it is
  written to fail in the one direction that matters: it exits 0 while no
  TypeScript service holds a database and exits **1 naming the service** the
  moment one does, because that service is the first subject this harness can
  measure in TypeScript and the adapter that must be written for it. An absence
  is the easiest kind of claim to satisfy by accident, so a check that could
  only report green would be reporting nothing.

  `reports/tenant-adapter-ts-01/mutations.sh` is its recipe: **2 controls green,
  6 breakages planted, 4 observed RED each naming its own assertion, 9 greens,
  0 failures** — and the six are deliberately not six reds. B4 must stay GREEN
  (a `.sql` under `e2e/` is a fixture for another service's migration, so the
  exclusion needs its own control), B5 must go GREEN once the migrations
  assertion is deleted from a copy of the audit, and B6 must make the recipe
  **stop** on an anchor that matches zero times.

  **The recipe found a real defect in the audit it was proving**, which is the
  argument for writing it as a falsification rather than a demonstration: B1
  planted a `pg` dependency and the audit stayed green, because `DECLARES` was
  printed and never acted on. It now has its own verdict and its own exit-1
  branch, naming the service and the driver — a declared driver nothing imports
  is not a query layer, so it does not make the adapter definable, but it is
  either dead weight from a removed query layer or a half-finished migration ONTO
  one, and a reader cannot tell which from the tree.

  **`cross_tenant_harness.sh` is unchanged, byte for byte**
  (sha256 `46da0eb4fad234728b62540162df249b59d8e5ac1820fa5828ef05b2635cd760`).

  `tests/tenant_isolation/adapters/README.md` keeps TypeScript in the unproven
  list and now says **why**, in a sentence a reader can check, rather than
  claiming a third proven language. The number stays four.

- **The cross-tenant harness has a second adapter, and the honest claim is now
  two languages rather than one.** `tests/tenant_isolation/adapters/go.sh` is the
  five-function adapter against `identity`, and
  `reports/tenant-adapter-go-01/mutations.sh` is its recipe: six breakages in
  identity's own query layer, each one observed RED with the assertion it was
  written for named, each reverted and green again, with the tree byte-identical
  at the end. Measured: **1 control green (7 assertions), 6 breakages planted,
  6 observed RED, 0 skipped, 0 anchors matching zero times.**

  **`cross_tenant_harness.sh` is unchanged, byte for byte**, which is what
  `adapters/README.md` predicted would fail if a second adapter needed a fork:
  the service comes in through `KIT_SERVICE_REPO`, the adapter through
  `KIT_TENANT_ADAPTER`, and the container name is derived from
  `KIT_TENANT_WORK`. All three were already in the contract.

  **The probe connects as a SUPERUSER, and that is the load-bearing decision.**
  Postgres exempts a superuser from row-level security unconditionally, whatever
  the FORCE says, so on this connection every denial in the probe is caused by
  identity's own `WHERE account_id = $1` and by nothing else. Connected as
  `identity` or `identity_app` instead — which is what a production deployment
  looks like — all six breakages would have stayed green on a tree with every
  predicate removed, and the harness would have been a second, worse measurement
  of the substrate `tests/tenancy_test.sh` already proves. The probe asserts the
  exemption still holds (`TestTheSubstrateIsNotWhatHoldsThisLine`) and that the
  substrate is armed at the same time, so changing the DSN goes red rather than
  quietly re-pointing the suite. `adapter_run` likewise refuses a `go test -run`
  that started zero tests: `go test` prints `ok` and exits 0 in that case, which
  is the vacuous green this repository has a written rule about.

  **A finding about the substrate, reported and not fixed here.** identity's
  `migrations/00016_account_isolation.sql` calls
  `cafaye.protect_table('account_users')` with one argument, and that function
  derives `login_role := coalesce(p_login_role, current_user || '_app')` and
  then **raises** unless such a role already exists and can log in:

      ERROR:  cafaye.protect_table(account_users, postgres_app):
              postgres_app is not a LOGIN role on this cluster.

  The hint the migration ships with names the provider — "kit's cluster
  provisions `<service>` and `<service>_app`" — so the substrate a migration
  installs depends on infrastructure **outside** the migration, and a harness
  that brings up a bare `postgres:17` cannot apply 00016 at all. The adapter
  provisions that role and nothing else: no table, no policy, no column, and the
  name is derived **by the database** with the same expression `protect_table`
  itself uses, so the adapter never becomes a second statement of a fact the
  migration already states.

### Changed

- **The fleet's gateway is `gateway`. Every reference in kit to the service
  formerly named `guard` now names `gateway`, and nothing else moved.**

  kit is the generator every service is built from, so the templates are the
  whole blast radius: a template that still says `guard` regenerates the old
  name into every service scaffolded after it. `templates/otel/node/hono.ts.snippet`
  — the file a new Bun/Hono service is generated from — carried
  `GUARD_OTEL_ENDPOINT`, `GUARD_TENANT_ID` and a default service name of
  `"guard"`, and all three are now `GATEWAY_*` and `"gateway"`.

  `templates/parity-allowlist` moves with it: 8 ratchet rows and their `owner=`
  fields. **The entry count is the measurement and it did not move — 80 across 9
  repositories before and after**, which is what the check prints on PASS. A
  rename that had changed that number would have deleted or invented a debt
  record, and the ledger's dead-entry rule is what makes the number trustworthy
  in the first place.

  **The trap was that `guard` is mostly NOT the service here.** In this
  repository the word is far more often a TRIPWIRE — *a comment-rot guard*, *a
  guard that cannot go red*, *a shard guard* — and kit has been using it that
  way for thirty packets. `templates/parity-allowlist` alone holds 22 of the
  word and only 8 are the service. A mechanical replacement would have produced
  documents that are actively wrong, so the sweep was done by reading every
  sentence and asking whether `guard` names the thing that runs on a port or the
  thing that asserts something. Only the first moved. `lint-args guard` — a STEP
  NAME in three jobs, asserted as a string literal in four places in
  `tests/validate.sh` — is a tripwire and renaming it would break the check that
  requires it.

  Measured: 248 PASS / 2 FAIL / 6 SKIP before and after, with every check's
  verdict and label byte-identical between the two runs. The two FAILs are
  pre-existing and unrelated — `generated stack` and `in-scope repositories`
  both name the `guard` repository **on disk**, and the directory rename is the
  manager's, not this packet's.

- **The account-scope record was RED on arrival with `pantry` and `identity`
  moved, and `pantry` had got BETTER.** Core's D46 replaced a false `stale` on a
  route that is mounted with `account-scope.registration-path-unreadable`, added
  `account-scope.surface-unreadable`, and printed a fifth number on the summary
  line. Measured with `tests/account_scope_fleet_check.py --baseline`:

  | repository | was | is now |
  | --- | --- | --- |
  | `pantry` | exit 1, `0/5/1/0/1/7`, `stale: 1`, `surface-blind` | exit 0, `0/6/0/0/0/9`, `surface-unreadable` |
  | `identity` | exit 0, `17/25/0/0/0/1` | exit 0, `17/25/0/0/0/3`, two `surface-unreadable` |

  `pantry` went from a false FAILURE to a green and that is exactly as red as a
  regression, which is the property a suppression list does not have and the
  reason this file is a full row per repository. Both rows are restated from that
  command's output; the other seven are byte-identical.

  **`pantry`'s old `condition:` did not merely arrive, it was wrong about what
  core would do.** It read "THIS ROW ENDS when core's chi recogniser reads a
  leading concatenation term", after `pantry/DECISIONS.md` D34 §3 — and D46
  lists that as its first **rejected** alternative, stating in the same sentence
  that resolving identifier values through the module index does **not** close
  `pantry`'s, "because `options.BaseURL` has no value in any tree". The chi
  pattern still requires a string literal as the first term after `(`
  (`core/harness/account_scope_check.py:486`) and pantry's D34 is still OPEN. So
  the end is restated as a fact a reader can watch: the row ends when
  `surface-unreadable` reports a **non-zero read count** for
  `internal/api/api.gen.go` — today "0 of the 6 registration(s) in
  `surface.sources` were read" — which is the whole of `surface.minimum: 0` and
  the only reason `fleet.blind.surface-blind` still fires.

  **The row is rewritten, not deleted, and its nine warnings are not a
  tolerance.** A repository with no row is red, so removing it would have made
  adding a repository to `MVP-SCOPE.md` silent. The loader demands a `condition:`
  for `failures:` and `blind:` and for nothing else — a warning a row must write
  down is the record working, not a switch — and this row keeps one condition for
  the one failure it really carries. `identity` keeps none: nothing about it is a
  failure and nothing about it is tolerated.

### Fixed

- **`ci.reusable.yml` asked for the concurrency lock its caller was already
  holding, so the `uses:` job produced no job, no check-run and no log line in any
  caller, for four days.** Every caller in the fleet declared

      concurrency:
        group: ${{ github.workflow }}-${{ github.ref }}
        cancel-in-progress: true

  and `.github/workflows/ci.reusable.yml` declared the identical block from
  `8ebf4db`, the commit that first published it. Inside a reusable workflow
  `github.workflow` is the **caller's** workflow name and `github.ref` is the
  caller's ref, so both sides computed `ci-refs/heads/master` and asked for one
  lock. The caller holds it.

      $ gh api repos/cafaye/parlor/actions/runs/37230458669/jobs \
          --jq '.jobs[] | "\(.name) | \(.status)/\(.conclusion)"'
      typecheck + build | completed/success
      bin/prime         | completed/success
      $ gh api repos/cafaye/parlor/actions/runs/37230458669 --jq '.conclusion'
      failure

  Both jobs green, the run red, and `gh run view --log-failed` returns **nothing
  at all** because no step failed. `bin/prime` runs the suite, so tests were not
  entirely absent — but the `language` gate job is **unconditional** and no
  caller had ever produced a job ending `/ language`, so **no repository in the
  fleet had run kit's linter in CI**, and neither had anything else gated behind
  that job.

  The file itself was never at fault, and that was measured rather than assumed:
  the blob on `master` is byte-identical to the fixed one apart from one line, it
  parses, it declares every input callers pass, and calling it unchanged from a
  throwaway repository produced all thirteen jobs. Reproduced end to end with one
  variable changed at a time:

      caller group `${{ github.workflow }}-${{ github.ref }}`  ->  1 job,  callee gone,  run failure
      caller group `caller-${{ github.workflow }}-${{ ... }}`  -> 13 jobs, callee present

  **The fix is one line in the shared file and not thirteen caller PRs**, which is
  also the only fix that reaches a repository nobody remembers exists: kit's
  reusable workflows namespace their group with `kit-`. That repairs kit's own CI
  too — `ci.yml`'s group is `ci-<ref>` and this one is now `kit-ci-<ref>` — with no
  change to `ci.yml`. The caller's cancellation still propagates into the called
  workflow, measured rather than assumed, because dropping the block is the other
  way to stop a collision and it trades a missing job for an unbounded pile of
  superseded runs:

      push A -> called job in_progress; push B -> A's called job `cancelled`

  `image.reusable.yml` declares no `concurrency` block at all, and `identity`'s and
  `site`'s `publish` runs **do** produce `image / build (and publish, if asked)` on
  every run — the fleet's own control, same mechanism, same org, same ref. The
  one difference is the block.

- **`reusable_concurrency_check`: a check for the collision, because the gate was
  green for the whole four days and every claim it made was TRUE.** The path
  resolved, `workflow_call` was declared, the inputs matched, and the workflow was
  valid — it is two valid workflows asking for one lock, and the only place both
  sides are visible at once is the gate. It asserts two separable claims: every
  standard kit hands out namespaces its group with `kit-`, and a caller must not
  normalise to the same expression as one of kit's. The second is read from kit's
  own `ci.yml`, because kit is a caller of itself and held the defect in both
  files at once; it is deliberately **not** a fleet sweep, because
  `fleet_check.py` already reads the repositories beside this one and a second
  reader of the same fleet would be a second answer to a question kit already
  asks.

  **The normalisation earns its keep because of `core`,** which writes
  `${{ github.workflow }}-${{ ref }}` — not `github.ref`. Same value to GitHub,
  different bytes to a `==`, so a byte comparison would have reported the one
  repository in the fleet that spelled it differently as clean.

  Three breakages, 105 / 105b / 105c, one line in one file each, and each can
  only be caught by its own branch. **105 is not the historical revert**, and that
  is the interesting part: putting the bare group back is the truest mutation
  available and it is the wrong one, because in kit's own tree it also collides
  with `ci.yml`, so it satisfies the comparison branch too and a recipe proving
  two branches proves neither. Measured — that spelling reports both messages.
  The suffix is the shape a "make the group more specific" patch actually takes,
  and it is unprefixed without colliding.

- **`fresh_copy` did not copy `reports/`, so every throwaway copy this suite
  makes was a tree whose README documented a file it did not have.** The
  account-scope packet
  added `reports/account-scope-contract-01/snapshot.sh` to the list
  `readme_check` asserts both halves of — that `README.md` names the path and
  that `os.path.exists` finds it — and `fresh_copy`'s entry list is explicit and
  closed, so the new directory was not in it. Every copy then ran:

      FAIL README.md  (documents every new template)
             README.md documents reports/account-scope-contract-01/snapshot.sh,
             which does not exist

  The false red is the legible half and it is the one the control already names:
  `expect_green 'unbroken tree'` prints "the gate is RED on an unbroken tree",
  which is the sentence that makes every proof below it meaningless, and the
  green-expecting proofs (23b, 31b, 59) go red with it for a reason that had
  nothing to do with the defect under test.

  **The silent half is the reason it is worth a changelog entry rather than a
  one-line edit.** 88 of this suite's recipe invocations are `expect_red_check`,
  which appends `--only=<label>` to every child, so the README check does not run
  in any of them and not one of the 88 ever saw it. What is left that does is the
  single plain `expect_red` in the file, and that helper asserts the gate's exit
  status and nothing else — `the gate went red` is satisfied by a copy that is
  red for any reason at all. **A gate that always exits non-zero makes one
  proof in a hundred pass for the wrong reason, and a gate that always exits
  non-zero is a property a reader cannot see.** `reports` is now on the list,
  and the comment beside it says what breaks if it comes off again.

  `MIGRATIONS.md`, `LICENSE`, `DECISIONS.md` and `VERSION` are on that list for
  the same reason and each of them was a real packet; this is the third, and the
  first in which the file, the README line and the check that names it all
  landed in one commit — so no review of that packet's own diff could have found
  it, and the only witness is a green `unbroken tree`.

  **And this entry first said "all 64 throwaway copies", which was a number
  nothing reproduces.** It is corrected here, in the commit message it came
  from, and in the `fresh_copy` comment, because 64 was in three places and a
  number wrong in one of them teaches a reader to trust the other two. It was
  never a count: instrumenting `fresh_copy` in a throwaway copy of the tree and
  reading what it wrote gives **92 copies** with ruby, kamal and kamal-backup on
  `PATH`, **79** with all three unreachable, and **89 or 76** in a run that
  failed or skipped anything and so stopped at the suite's own `exit 1` before
  reaching breakages 101-103 — whose three `fresh_copy` sites sit below that
  guard. The static count is the only one that has never moved: 92
  `$(fresh_copy …)` sites at `master`, at `81fffa6` and at every commit between.
  The `reports` entry is the fix and it stands; only the count was wrong.

- **`adapters/README.md` listed `guard` as a Go service. It is TypeScript** — 44
  `.ts` files, 0 `.go` files, no `go.mod`. The sentence was a claim about a
  service nobody had measured, which is the defect this harness exists to
  remove. The count of unproven languages therefore drops from five to four, and
  it drops for **two** reasons rather than one: Go became proven, and one entry
  was never a Go service to begin with.

- **`protect_table` granted the login role DML on a table and nothing on the
  sequences behind it, so a protected table with a `bigserial` column could not
  be INSERTed by the role the substrate exists to hand DML to.** A table's INSERT
  reads its sequence before it writes the row, and a sequence is a separate
  object with separate grants — the table grant does not carry it. Measured on
  PostgreSQL 18.6, as `<service>_app`, against the substrate as it stood:

      ERROR:  permission denied for sequence notification_preferences_id_seq

  which is SQLSTATE `42501` — the code the policies themselves raise, so a test
  asserting only the code passes for the wrong reason. That is not hypothetical:
  a probe in `courier` passed on a sequence denial until it also required the
  message. `protect_table` now grants `usage` on every sequence owned by a column
  of the table it is protecting, found through the same `pg_depend` edge Postgres
  itself uses for `serial`, and **not by name**: `<column>_id_seq` is this
  migration's convention and is not the next service's.

  **The grant is `usage` and only `usage`.** `usage` is what `nextval` checks,
  so it is the minimum that makes the INSERT work; it is deliberately not
  `select` (which would let the login role read `last_value` and reason about
  other tables' row counts) and not `update` (which would let it `setval` and
  forge ids). Both refusals are asserted. A blanket `grant all on all sequences
  in schema public` also makes the INSERT work and hands the same role every
  sequence in the database, and the negative control is built to catch exactly
  that.

  **MEASURED, AND IT CORRECTS THE PREMISE: an `identity` column was never locked
  out.** On PostgreSQL 17.11 and 18.6, `INSERT` into a table whose id is
  `generated always as identity` succeeds for a role holding **no** privilege on
  the sequence at all, while that same role's explicit `nextval()` on the
  sequence is refused — the fetch happens on a path with no ACL check. So the
  `bigserial` case is the lockout and the `identity` case was not. The loop grants
  `usage` on the identity sequence anyway, because it is the table's own sequence
  and nothing wider, and because a substrate whose correctness rests on an
  undocumented executor detail is one minor version from the same lockout — and
  because a column declared `DEFAULT nextval('…')` by hand rather than by
  `serial` is the `bigserial` case again.

  The loop is a `for … in select`, so an empty result set is a loop that does not
  run. Most tables in any service have no serial column, and the same loop written
  as `select … into` would raise on every one of them.

  There is no second copy of the grant story to go stale:
  `protect_credential_table` calls `protect_table` rather than repeating it, and
  that was run rather than argued — a `bigserial api_keys` table through
  `protect_credential_table('api_keys', 'token_digest')` leaves `probe_app`
  holding `USAGE` on `api_keys_id_seq`.

  Five cases and three mutated controls, red first, in
  `reports/substrate-sequence-grant/` — `BEFORE.txt` is the run against the
  substrate as it stood (`FAIL bigserial — permission denied for sequence`,
  `2/8 green, 4 N/A, 2 failed`), `AFTER.txt` is the same script on the fix
  (`8/8 cases green`). The negative control is green on an EMPTY grant set before
  the fix and the run says so out loud, because "nothing changed" and "nothing is
  too wide" are the same observation when the set is empty.

  `courier` carries this file verbatim at `priv/repo/substrate.sql`, sha256
  `e2b4917be2a7f7c48964bd40fea0da93db503b4c736a42a44e44425cfbf7bf5e`, and its
  migration pins both that digest and the commit — untouched here, because that
  pin is what stops a substrate edit silently changing a migration in a
  repository nobody was looking at. **A follow-up packet re-copies from kit**;
  editing the copy here would defeat the pin. `identity` needs the same change and
  its copy is a different shape: the function body is inlined into
  `migrations/00016_account_isolation.sql` rather than copied as a file, so it has
  no digest to re-pin the way courier's does. `identity` carries **no latent
  lockout today** — none of its four protected tables has a sequence-backed id;
  its keys are `uuid DEFAULT gen_random_uuid()` and composite. It acquires one the
  first time a protected table grows a serial column.

- **`templates/database/tenancy/isolation.sql` asserts the SQLSTATE and not the
  message, so every `'42501'` in it would be satisfiable by a sequence denial —
  and is not, only because its probe table has no sequence column.** Reported,
  not fixed here: the file and `assertions.txt` are one contract compared in both
  directions across six language templates, and changing what `cafaye_observed`
  returns changes the meaning of every assertion in it.

  `pg_temp.cafaye_observed` is `return sqlstate;` in its `exception` handler, and
  four assertions compare against the literal `'42501'` — the same code both the
  policies and a missing sequence grant raise. That is the ambiguity the entry
  above exists to remove, one layer in and in kit's own tree.

  What has kept it unreachable is the fixture: `cafaye_probe_things` is
  `id uuid primary key default gen_random_uuid()`, so no statement in the file can
  produce a sequence denial and 39 assertions have been green straight through
  this defect. That is also the trap — the natural next step for that suite is to
  give the probe table a serial column, and on the day that happens every
  `'42501'` assertion becomes satisfiable by the wrong failure, silently.
  `reports/substrate-sequence-grant/` requires the message today, which is what
  tells the two apart.

### Added

- **`tests/tenant_isolation/` and `reports/tenant-isolation-harness/mutations.sh`:
  a harness that PROVES one account cannot read another's rows, by running the
  service's real query layer against a real database.** D18 says nothing proves
  it and nothing can ask. `core`'s `account_scope_check.py` (landing
  concurrently) is the other half — it DECLARES which entry points reach customer
  data. This is the half that proves it, and it is in kit rather than in core for
  the same reason `gate_check.py` is in core and `tests/gate_self_test.sh` is
  here: kit has the docker fixtures and the fleet-wide shape.

  **It runs the code, so it is not a linter.** A grep for `account_id` near a
  query is blind in three ways this harness is not: a bind parameter passed as
  the *previous* one (the predicate is right, the value under it is not); a query
  that scopes in production and not on the error path; and an entry point that is
  not a query at all — courier's `update/2` takes a struct, so the predicate that
  scoped it is four frames away at the load site and a per-query lint sees a clean
  `Repo.update`. Instead: a throwaway copy of the service, a real `postgres:17`
  container whose name and host port are BOTH derived from the session, **the
  service's own migrations**, two accounts seeded through the service's own write
  path, and the service's own functions called as account A.

  **The control passes, and that is a measurement: six negative assertions,
  `Result: 6 passed`, 0.1s, against a real database.**

  **The six breakages were each observed RED, on the assertion named after the
  breakage** — a control never observed red is a check that cannot see the
  defect it was written for, and that is worse than no check because it reports
  green:

  | # | breakage | planted in | the literal receipt |
  |---|---|---|---|
  | 1 | missing `WHERE` | `enabled/1` loses the account predicate, keeps `status == :enabled` | `1) test cross_tenant_enabled_list` |
  | 2 | missing bind parameter | `list/1` keeps the predicate, pins a constant | `1) test cross_tenant_list_own_row_visible` |
  | 3 | unscoped list | `page/3`, the query the HTTP index runs | `1) test cross_tenant_list` |
  | 4 | unscoped update | the controller's `update/2` resolves its row by id alone | `1) test cross_tenant_update` |
  | 5 | unscoped delete | the controller's `delete/2` resolves its row by id alone | `1) test cross_tenant_delete` |
  | 6 | IDOR on fetch-by-id | `Repo.get_by(…, account_id:)` becomes `Repo.get` | `2) test cross_tenant_fetch_by_id` |

  Each was reverted and green again. Four things are asserted per case: the
  mutation is in the file **by text**, the suite goes red **and names the
  assertion it was written for**, the literal failure line is kept rather than
  paraphrased, and the revert returns it to green. Breakage 2 is why the probe has
  an **allowance** assertion of its own — a predicate bound to the wrong account
  reads as "zero rows", which every denial-only assertion is perfectly happy with.

  Two of the six are worth naming because they are the class of defect this
  replaces. Breakage 6 unscopes the controller's SHARED fetch, so update and
  delete go red with it — reported as `2)` rather than `1)`, because the recipe
  prints what the suite said instead of filtering it to one name. And breakage 3
  was first written against `list/1`, which the recipe caught: courier's
  controller paginates, so unscoping `list/1` proved nothing about the list
  endpoint. **A breakage aimed at a function no entry point calls is a breakage of
  a function, not of a surface.**

  **And the claim is one language wide, in those words: cross-tenant isolation is
  proven for Elixir, on a service that scopes correctly. Five languages remain
  unproven.** The harness holds no Elixir — five functions, in
  `tests/tenant_isolation/adapters/README.md`, are the whole contract, and the
  recipe's *anchors* are the only language-specific part.

- **the docker-tier rules now walk `tests/` RECURSIVELY, and the reason is that a
  check whose scope is narrower than a reader believes costs its trust in the
  findings it does report.** `docker_tier_project_name`'s `scripts` list was
  `os.listdir(tests_dir)`, which reads the top level only — so the new harness,
  in a subdirectory, was in neither `tiers` nor `uncovered`, and the gate would
  have printed a tier count that did not include it and said nothing at all. It
  brings a container up and derives its container name and its host port from the
  session; that is now a fact the rules are pointed at rather than a fact a reader
  has to notice.

- **`reports/tenant-isolation-harness/BEFORE-*.ex` and `AFTER-*.ex`: the two source
  files the six breakages are applied to, so a reviewer reads what is being broken
  instead of reconstructing it.** They are byte-identical by construction — every
  case reverts before the next — and they are committed because
  `reports/wrapper-tier-scope/mutations.sh` already commits its `BEFORE.txt` and
  `AFTER.txt` for the same reason.

### Added

- **`tests/generated_stack_check.py`, and a gate section that runs it: the file
  `caf dev` GENERATES is not a source file, and nothing said so in the six
  repositories nobody had visited yet.** `caf dev` renders a stack from
  `cafaye.yml` and writes it to `caf.dev.compose.yaml` on every run — including
  the run that finds no services, because the write precedes the empty-stack
  return (`caf/internal/cli/dev.go:186`, before the `len(stack.Services) == 0`
  check at `:194`). Two states are now failures:

  - a repository that neither ignores it nor has un-tracked it, which is one
    `git add -A` from a commit and, from there, a merge conflict nobody can
    resolve by reading it because both sides are generated;
  - a repository that TRACKS it, which was `core`'s state and is the case where
    an ignore entry is necessary and **not** sufficient — git applies ignore
    rules only to paths it is not already tracking, so `git check-ignore` keeps
    answering "not ignored" about a tracked path however correct the
    `.gitignore` is, until `git rm --cached` moves it.

  Scope is read off the FILESYSTEM: a root `cafaye.yml` is exactly what `caf dev`
  uses to decide a directory is a project at all, so a repository is in scope
  the day it grows a manifest and nothing here is edited. Measured against the
  real fleet with the five per-repository fixes not yet merged: **11 findings
  across 10 of 16 repositories**, exit 1. Five of those ten — `cafaye-rb`,
  `cafaye-ts`, `docs`, `guard`, `muse` — hold a manifest, no ignore entry and no
  file on disk, and they are invisible to a hand-written list precisely because
  nobody has run `caf dev` on that machine yet.

  Green control over three conforming fixture repositories: exit 0. The TRACKED
  branch is proved by a planted divergence (`git add -f`, then `git rm --cached`
  turns it green) and the not-ignored branch by deleting the ignore line from a
  conforming fixture. It is a third use of the `config only` carve-out and is
  named in the `carve-out boundary` check's list in the same commit; it is stdlib
  for the same reason the others are, and it parses no file type at all — it asks
  git two questions, because re-implementing gitignore semantics in Python is
  wrong on `!` negation, anchored paths, `**`, and a developer's global
  `core.excludesFile`.

  It is deliberately **not** part of `fleet_check.py`, and `tests/validate.sh`
  argues both reasons: that gate's scope predicate is "declares local
  infrastructure", which EXCLUDES `core` — the repository this check exists for —
  and its adoption ceiling would make a hard FAIL a WARN in every repository
  forever, on the grounds that none has adopted `kit.ref`. This defect has no
  adopter.
### Fixed

- **The docker-tier guard counted five tiers and three more were bringing a stack
  up, so it was green on a tree carrying the exact defect it exists to catch.**
  `docker_tier_project_name`'s success line claimed *the sixth tier is covered on
  the day it lands*. `tests/canary_test.sh`, `tests/no_telemetry_in_readiness.sh`
  and `tests/stack_live_test.sh` were all out of scope: the first two bring the
  stack up through a `compose()` wrapper that forwards `"$@"`, so no logical line
  contains both `docker compose` and `up`; the third writes `bash ./bin/dev up` and
  names the project only from `ps`/`exec`/`port`/`logs`. A file dropped from the
  tier set is invisible to a rule that counts tiers, so **no finding named them** —
  not even the emptiness finding. Measured with the mutation asserted by text:
  `PROJECT="kit-canary-$$"` → `PROJECT="kit-canary"`, guard exit 0, **0 findings**.
  - The tier set is now three derived arms — direct bring-up, bring-up through a
    local wrapper **definition**, and any script naming a shared namespace — and a
    **fifth emptiness finding** reports a script under `tests/` that invokes docker
    without being a tier, from a predicate deliberately wider than the tier set so
    it is not a tautology.
  - That finding named **`tests/provenance_test.sh`**, which builds
    `-t kit-provenance-test:good` and tears it down with `docker rmi -f`: an image
    tag is a **fifth** shared namespace, reached by bare name, and no `-p` has any
    say over it. Both tags now derive from the pid.
  - **`tests/deploy_test.sh:456` is a `note` printing an example command**, which
    the new image rule first read as a hardcoded tag; matches are now ignored when
    the `docker` itself lies inside a quoted run. `-t` is matched only after
    `docker build`, because `-t` is `--tty` to `run` and `exec`.
  - Recipe: `reports/wrapper-tier-scope/mutations.sh`, **8 cases, all bit**, guard
    extracted from `tests/validate.sh` on every run so it cannot outlive it. Text
    scan only — no image, no container, no docker.


- **The generated-stack gate failed on two repositories the scope decision holds
  frozen, so merging it would have made kit's gate permanently red on a tree
  nobody is permitted to fix.** `MVP-SCOPE.md` freezes `billing`, `darkroom` and
  `muse` out of the MVP until it is launched and selling, and `darkroom` and
  `muse` each hold the defect today: a manifest, no ignore entry, no file on
  disk. `tests/generated_stack_check.py` asked git both questions of both
  repositories and counted every answer, which is right — and then exited 1, and
  the exit status is the part that decides whether a gate is ever run again. The
  predictable response to a gate that cannot go green is a human disabling it,
  and that would have stopped the check running in the nine repositories that
  **can** be fixed today.

  **Only the exit status moved. Detection, both messages and the `git rm
  --cached` advice are unchanged**, and the frozen findings are still printed,
  under their own `FROZEN-FINDINGS:` heading: a finding nobody may fix is still a
  true finding, and suppressing it would be the same false green in a different
  costume. What a reader can no longer do is mistake "clean" for "clean because
  frozen" — the gate row itself now reads `generated stack (…; 2 in frozen
  repositories, reported not counted)`, and a run with no scope decision at all
  says `no scope decision read, so nothing is exempt`.

  **The frozen set is READ from `MVP-SCOPE.md`, and no repository name is
  written into this repository.** It comes in on `--scope`, whose default is the
  directory above `--repos-dir` (a fleet-wide directive belongs beside the fleet
  and in no repository, since putting it in one would make that repository the
  owner of the others' exemptions), and `KIT_SCOPE_FILE` overrides the location
  for a machine whose fleet is not beside its directive. A hardcoded frozen list
  has the same defect as the hand-written dirty list this check replaced, with
  the opposite polarity: it goes stale silently, and the day the scope lifts the
  exemptions outlive the decision that granted them. Three properties of the
  read are deliberate and each fails closed:

  - **the out-of-scope list is the ONLY exemption.** A repository the decision
    does not name is blocking, including one it never mentions — reading the
    "in the MVP" table instead would have exempted precisely the four
    repositories nobody has scoped yet;
  - **an unreadable decision exempts nothing**, with a `SCOPE-ABSENT:` marker
    naming the file and the reason — absent, unreadable, no such section, or a
    section naming nothing this read as a name. The exemption is the only thing
    that can turn a finding green, so the state in which it cannot be read must
    not be a state in which it is granted;
  - **a section this cannot parse is a loud red, not an empty set.** A rewrite
    that moves the section, renames its trailing clause or reformats the list
    keeps working; one that changes the sentence it keys on stops it, and says
    so.

  Measured on the fleet as it stands: `exit 1` before this commit with 6
  findings, `exit 1` after with the same 6 — `darkroom` and `muse` reclassified
  from blocking to frozen and printed under their own heading, and the four
  blocking ones (`cafaye-rb`, `cafaye-ts`, `docs`, `guard`) unchanged. Proven
  both ways on a two-repository fixture over the real `MVP-SCOPE.md`: the same
  defect in `darkroom` alone is `exit 0` with the finding printed, and adding
  `guard` makes it `exit 1`.

- **Two of this repository's docker tiers hardcoded their compose project name, so
  two concurrent runs were one stack with two owners — and the failure read as a
  database-boundary violation.** `tests/isolation_test.sh` and
  `tests/tenancy_test.sh` each wrote `--project-name kit-isolation` /
  `kit-tenancy` at two sites apiece. A compose project name is the namespace for
  that stack's containers, networks and volumes, so a fixed one means one run's
  teardown destroys the other's cluster mid-assertion. Observed on this box, not
  argued from the source (`reports/compose-collision/`):
  - **isolation**, two concurrent runs: `A exit=0 B exit=1`. The second run
    replaced the first's running container (`kit-isolation-postgres-1 Recreate`)
    and could not bring up a cluster of its own.
  - **tenancy**, two concurrent runs: `A exit=2 B exit=1`. The second could not
    bring up a cluster (`removal of container … is already in progress`), and the
    **first died part way through assertion 5 with no `FAIL:` line of its own**,
    exiting 2 — psql's code, propagating out of the `docker exec` under `set -e`,
    because the other run's teardown had taken the project volume out from under
    it. Through `validate.sh`'s `FAIL:` summary that reads as an account-boundary
    violation, which is precisely the claim that tier exists to make trustworthy.

  After the fix, both pairs are green, with two distinct projects, two distinct
  host ports and two live clusters counted while both were up — because "both
  green" is also what two runs sharing ONE stack look like, which is the false
  pass worth fearing most here.

- **The host port was hardcoded too, which is the same defect in a worse hat, and
  fixing only the project name would have moved the collision rather than fixed
  it.** `KIT_POSTGRES_PORT=15521` / `15531` are fixed **host ports**: they
  collide with a developer's own running stack, not merely with another test run.
  Measured: with only the project name derived, two concurrent runs were still
  red on `port is already allocated`. Each tier now takes a free port found by
  the same dependency-free probe `tests/stack_live_test.sh` uses, seeded from `$$`
  so two concurrent runs do not begin their search in the same place.

- **`tests/tenancy_test.sh`'s teardown was deleting objects the tier never
  created.** It ran `docker rm -f kit-tenancy-control` and `docker volume rm
  kit-tenancy-control-vol`; nothing in that file creates either, because every
  control there is a SQL mutation against its own cluster rather than a second
  container. `docker rm` takes a bare name and does not care who made it, so those
  two lines reached outside the run's own namespace. Removed rather than derived —
  the honest version of that line is no line.

- **`tests/rls_perf_test.sh` had the same defect and was on nobody's list.**
  `C="kit-rlsperf-pg"` is a fixed container name, so two concurrent runs were one
  container with two owners. Found by the new guard, whose scope is derived from
  the directory rather than from a list of the two files already known to be
  broken — which is the argument for deriving that scope, made concrete.

### Added

- **`tests/validate.sh` gained `docker_tier_project_name`: a docker tier may not
  hardcode a name in a shared namespace.** Covers four — project, container,
  volume and published host port — and a copy-paste reintroducing any of them is
  a red gate at authoring time rather than an interference in CI. The set of
  tiers is derived from `tests/` rather than enumerated, so a sixth tier is
  covered on the day it lands; within a tier the rule is applied at both
  declaration and use site, so a tier that derives its project but writes its
  control container literally is caught by the same rule. Emptiness is a finding,
  as in `self_test_no_version_literal`: a guard that covers nothing says so
  rather than reporting nothing.
  - **The guard was wrong three times before it was right, and the mutation
    suite is what said so** (`reports/compose-collision/mutations.sh`, which
    breaks each property in turn, requires the gate to go red *and name the
    site*, then restores and re-asserts green): bring-up was detected per line,
    so the `if ! docker compose …` / `up -d` pair that is one command matched
    neither half and `tenancy_test.sh` dropped out of scope entirely; a literal
    could hide in an *assignment*, where every use site reads a derived `$VAR`;
    and an inline `$$` was called a literal, which fired on `deploy_test.sh`'s
    correctly-unique decoy volume.

### Fixed (continued)

- **The VERSION gate's own gate: a `### Breaking` heading was compared against
  the wrong section of the changelog, and the comparison was vacuous.** Rule (4)
  resolves the version a breaking heading is checked against with `grep -B1`,
  which is the section **above** it. The section above a version is whatever was
  released *after* it, which says nothing about whether that version was allowed
  to break anything; the version it was released *against* — and the only fact
  "a breaking change moves MAJOR" is a claim about — is the section **below**,
  because the changelog is newest-first. Two measured consequences:
  - **The clause had never executed.** The only `### Breaking` in this tree is
    under `## 2.0.0`, whose section above is `## Unreleased`, which
    `stability_parse` refuses — so the comparison short-circuited every time. A
    rule this file calls "the load-bearing one" had never once run.
  - **And it went red on a correct tree.** Rename `## Unreleased` to `## 2.1.0`
    and set `VERSION` to 2.1.0 — an additive release that breaks nothing — and
    the gate failed, reporting `2.0.0`'s *legal* `### Breaking` against the
    `2.1.0` written after it.

  Separately, `-B1` on the first entry of a list returns that entry itself, so
  the newest section was compared against its own MAJOR and `MAJOR <= MAJOR` was
  true by construction — visible as breakage 96's mutation reporting "the section
  above it is 4.0.0" about 4.0.0. And `stability_parse` returns no value; it
  sets globals, so parsing the neighbour **overwrote** `STAB_MAJOR` before the
  test read it, making the test `[ neighbour -le neighbour ]`. The wrong
  neighbour was `Unreleased`, which fails to parse, which short-circuited — so
  the clause was dead *and* vacuous at once, and each defect hid the other.
  Fixing only the neighbour turns a dead clause into one that fires forever, and
  did: with `below` correct and the aliasing left alone, this tree's own legal
  `### Breaking` went red. Fixed together, and the message now reads "which was
  released against" because that is the fact being checked. Five trees, one
  property each; see `REPORT-kit-version-recipe-drift-01.md`.

- **Breakages 96, 97 and 99 died on `92a1127` and nobody could read it as
  related.** All four version-gate recipes spelled their `edit` anchor as the
  literal `1.0.0`, so the commit that correctly shipped breakage 98's fix as a
  release — and so moved `VERSION` to `2.0.0` — took three proofs with it, and
  reported `the recipe no longer applies to its copy`. That sentence reads as a
  harness complaint; what it meant was *the only proof that a MAJOR bump owes a
  migration has stopped running*. The commit's own message names 31b, 23b and
  59, because those breakages' symptoms were legible and these four had none.
  Rewriting the anchors to `2.0.0` would have been green and would have re-armed
  the same bomb for `3.0.0`, so the versions are now **derived**:
  `copy_version <dir>` reads the version out of the copy and
  `bump <v> <major|minor>` computes the destination, refusing any string it
  cannot decompose rather than deriving from a guess.

- **Breakage 98 carried a second time bomb the version sweep did not see.** Its
  anchor was `## Unreleased\n\n### Added`, so it failed the same day for a
  *different* reason — `a5f8746` inserted `### Changed` as the first subsection
  and the recipe never mentioned it — and the next release renames that heading
  to a version, at which point the section it has to mutate is one it has to
  *create*. Both states are now handled and neither reads a spelling this
  repository can change.

### Added

- **A gate over the gate: no recipe may anchor on a bare version literal.** The
  four recipes above were corrected, and corrected recipes are correct until the
  next bump — so `tests/validate.sh` now refuses a version literal in any
  argument of any `edit` that touches `VERSION` or `CHANGELOG.md`, naming the
  line, the file, the literal, and whether it is the version the tree is at or
  one it has never been at. The set of files in scope is **derived** from the
  recipes, so the next version recipe covers itself. It is not a louder `edit`:
  `edit` already refuses an unmatched anchor, and by the time it does the recipe
  is dead. This runs before anyone writes one. Its measured limits — a literal
  reaching a recipe through a variable is invisible to a scan of arguments — are
  recorded in `DECISIONS.md` (MD31) and in the report rather than footnoted.

### Changed

- **`tests/validate.sh` grew `--no-live`, and the 104 throwaway gates in
  `tests/self_test.sh` use it.** Nobody had asked whether the self-test's child
  gates need the observability live tier; the answer is that **0 of the 107
  recipe invocations name one**. Every recipe asserts a verdict about ONE named
  check — a collector config, a workflow, a linter, a reporter — and
  `canary_test.sh` / `no_telemetry_in_readiness.sh` / `stack_live_test.sh` are
  not among them. Exactly one recipe reached the tier anyway: breakage 23b,
  because its helper (`expect_skip_check`) is deliberately unfiltered, since the
  string it has to find is a SKIP's verdict text and not a check's label. That
  one gate ran **128.8 s of docker out of 255.2 s** — profiled, measured, not
  estimated — and it is the exposure behind 23b, a green-expecting proof about
  the ruby interpreter floor, being reported red at position 23 of 104 in a full
  suite run while green standalone. (That red did **not** reproduce on this
  machine: 23b's own gate run is green here, standalone and inside a full suite
  run. The claim is the exposure, not a failure anyone watched.)
  - `--no-live` turns the three tiers into `report SKIP` lines naming the flag:
    counted in the skip tally, printed, and repeated in the summary with the
    consequence in it. It is **not** `--no-observability`, which drops the two
    cluster tiers too; those are a different claim at a tenth of the cost
    (23.9 s measured), and the two sets have to stay separable.
  - **No bound was widened.** The 900 s numbers are the same numbers. A bound
    widened until it stops firing on a loaded machine stops answering the
    question it exists to answer, and it does so invisibly — see `DECISIONS.md`
    (MD30) for the three alternatives that were rejected and what each costs.
  - The top-level gate is untouched: with no flag it still runs all three, and
    `--help` says so. The opt-out is set in exactly one place,
    `kit_child_gate`, and a new check fails if a second `bash tests/validate.sh`
    spawn appears outside it, if that spawn loses `KIT_NO_LIVE=1`, or if any
    recipe ever names a live tier.
  - **Breakage 23b now asserts a third thing**, and the third is the one that
    makes the opt-out honest: that a `SKIP` **row** names `--no-live`. Deleting
    the three `bounded_check` calls satisfies 23b's first two assertions
    perfectly — the gate is greener than ever and still names the ruby floor —
    and proves nothing about the live tier. The assertion is on the row, not on
    the exit status. 23b is the only helper in the suite that runs a whole
    unfiltered gate, so it is the only place the property can be watched failing.
- **`bash tests/validate.sh --help` no longer prints
  `kit_phase: command not found`.** The `EXIT` trap is armed ~120 lines before
  `kit_phase` is *defined*, so the `--help` path ran a trap made of three
  unknown commands. The temp directory is now removed explicitly and the trap
  disarmed. `--help` also prints the whole leading comment block instead of a
  hand-counted `sed -n '2,35p'` range that already cut a sentence in half — the
  flag added above would have moved that cut by another line.

- **`tests/kamal_test.sh` now answers `--only`.** It was invoked by a bare
  `bash` rather than through `bounded_check`, so its 24 cases against the real
  `kamal` and `kamal-backup` binaries ran on **every** invocation of the gate —
  including the 86 `self_test` copies that were told, by name, to run exactly
  one check. Measured with the gate's own profiler: **3.805 s, 55.6% of a child
  gate's startup floor**, on a floor measured at 6.850 s. The floor is now
  **2.85 s** (paired, 3 runs per arm, same tree, same box), and 86 copies of
  the floor is **≈ 343 s** off the suite.
  - **No coverage is lost.** The filter was already the gate's contract for
    `check`, `check_par`, `report_par` and `bounded_check`; this makes one more
    check obey it. `ONLY_SKIPPED` counts the exclusion and the summary prints
    it, a filter that selects nothing is still a hard `FAIL`, and an
    **unfiltered** run — the gate itself and all nine whole-gate copies — is
    unchanged: same command, same output, same verdict.
  - **It also fixed a spurious failure breakages 78, 79 and 82 had been
    printing on every run.** The check's label was derived from the script's own
    output, so it did not exist until after the work was done, `--only=kamal_test`
    selected **nothing**, and the gate printed a second
    `FAIL: --only='kamal_test' selected NO check out of the suite.` The recipes
    passed only because `expect_red_check` greps for its own needle and ignores
    the next line. After: `1 check(s) ran, 94 excluded`.
  - **And it withdraws a standing suggestion.** `REPORT-kit-cache-rollout-01.md`
    §5 listed "interpreter resolution → resolved once" among the floor's fixes.
    Measured: `00 bootstrap` is **0.040 s**, 0.6% of the floor. It cannot be
    made to matter, and it is struck rather than left standing.
  - The general lesson: **`--only` gates the verdict, not the work.** Before
    wiring a check into the fingerprint cache, find out whether a filtered copy
    is running it at all — a check that ignores the filter is charged to every
    copy that asked for something else, and no input declaration reaches that.
    See `REPORT-kit-startup-floor-01.md` and `PROFILE-startup-floor.md`.

### Added

- **Rule 4 can now see through a function a policy calls.** `pg_depend` on a
  policy records the FUNCTION its qualifier calls and never the relation inside
  that function's body, so a `SECURITY DEFINER` helper made rule 4 — "an
  authorization input the caller can edit" — go silent on exactly the defect it
  exists for. `policy_reaches` is `security_definer_view`'s transitive
  `pg_depend`/`pg_class` walk applied to rule 4's subject, so there is one walk
  in the file rather than two, and the finding reports `via_functions` so a
  reader can tell **which route** a policy took. Same rule name, same
  `cache_key`, same ERROR level: one more join on one rule.
  - **Measured, and the answer is a split, which is the point.** Against a real
    `postgres:17` (17.11), three body kinds and their `pg_depend`: a
    `BEGIN ATOMIC` body **is** recorded (`pg_proc → pg_class → <relation>`,
    `deptype 'n'`, because PG14+ parses it at `CREATE FUNCTION`), while a
    `language sql` **string** body (`as $$ … $$`) records one `pg_namespace` row
    and nothing else, and a `plpgsql` helper records only `pg_language` and
    `pg_namespace`. `prosrc` is empty for the ATOMIC body, so `probin IS NOT
    NULL` and `prosrc <> ''` partition the two cases exactly, in the catalog.
    Script and rows: `measure-advisor-pgproc.sql`,
    `measurement-pgproc.out`, `measurement2-pgproc.out`.
  - **So the hop ships and a `prosrc` scan does not.** The unrecorded edge
    exists only as SQL **text**, and a substring match fires on a table named in
    a comment, on a name inside a string literal, and on a table that has since
    been dropped. The gap is stated in `advisor.sql`'s **first screen** ("what
    this does not find") rather than left for a reader to infer from a rule's
    silence, and rule 6 is named as the thing that does still see the helper
    (`login_role_security_definer_executable`).
  - The fixture is **one caller-writable table and three routes**: a policy
    reaching it directly (the control), one reaching it through a `BEGIN
    ATOMIC` `SECURITY DEFINER` helper (fires, and names the helper), and one
    through a string-body helper (**must stay silent**, and does). Without the
    control, "rule 4 fires on a helper-routed policy" and "rule 4 fires on
    everything" are the same observation.

- **Rule 10 of the advisor: `rls_policy_correlated_membership` (WARN,
  PERFORMANCE).** A policy whose `IN (SELECT …)` subquery references the policy's
  own table is correlated, so the membership lookup runs once per candidate row
  instead of once per statement. Measured on this kit by the new
  `tests/rls_perf_test.sh`, through the real `cafaye.begin_account` seam with
  `FORCE ROW LEVEL SECURITY` on every policy table, 200,000 rows and a
  membership table indexed in **both** directions: **2000 ms against 18 ms — the
  plan's own loop counter reads `loops=200000` against `loops=1`.**
  - **111x here, and the reference's 450x was never a promise about this
    substrate.** The ratio is set by the membership table's size (the slow plan
    seq-scans a 200-row table 200,000 times, which is the entire cost) and by the
    row count. The direction and the mechanism are what transfer, and the
    mechanism is what the rule reads.
  - **`protect_table` cannot emit the shape.** It writes
    `account_id = (select cafaye.current_account_id())` — no membership table, so
    no join to invert. The slow form is only reachable by a hand-written policy.
  - **Deliberately silent on a correlated `EXISTS`**, because it measured 56 ms:
    with the *inner* hop inverted the planner re-associates it into a semi-join and
    resolves the membership once. **The boundary is per HOP, not per policy**, and a
    rule firing on correlation in general would fire on the shape that is already
    fast.
  - Proven against its fixture and against two negatives — the inverted direction,
    and the correlated `EXISTS` — all in `tests/tenancy_test.sh`, all with FORCE on.
    `tenancy_contract_check` compares rule names to the trip list both ways and
    still agrees: 10 rules, 11 trip pairs.
- **`tests/rls_perf_test.sh` — the measurement, as a gate.** Four shapes (correlated,
  inverted, `protect_table`, and the boundary case where the outer hop cannot be
  inverted) and four assertions: every shape returns the **same rows** (a timing
  measured against a predicate that returns nothing is not a speed claim), the slow
  form is at least 10x slower (the constant is not the claim, the sign is), the
  membership subquery's **loop count** differs per row against once (a loop counter
  does not move with machine load), and the boundary case still resolves once.
  SKIP(3) without docker, naming what is missing. **Not yet wired into
  `validate.sh`** — it needs a home in the observability phase, sequentially.
- **The self-test's 94 copies share ONE cache directory.** `tests/self_test.sh`
  points `KIT_CACHE_DIR` at `$WORK/cache`, a sibling of every copy inside the
  directory the existing `trap` already sweeps, so a verdict one breakage earned
  is available to the next instead of being deleted with the copy that earned it.
  The two GREEN-expecting proofs (`expect_green_check`, `expect_skip_check`) run
  their copies with `KIT_FINGERPRINT=0`, because a replayed cache hit is a green
  no check ran to produce. **No check is wired by this change**, so it moves no
  number yet: the switch is on and the declarations are what connect it. See
  `DECISIONS.md` (MD28).
- **The provenance stamp (P3-18 + the reader half of P3-19).** A pulled
  `:e2e` image could not say which commit was in it — a tag is a mutable name,
  and every e2e tier now pulls one. `docker/provenance.sh` stamps five fields
  into all seven `docker/Dockerfile.<lang>` templates:
  `org.opencontainers.image.source`, `.revision`, `.created`,
  `com.cafaye.kit.source.dirty`, `.template_version`.
  - **Labels, not an attestation.** `image.reusable.yml` already set
    `provenance: mode=max`, and it is the wrong answer for a *consumer*: reading
    one fetches a referrer from the registry over the network, and the e2e
    artifacts are pushed by a bare `docker build` that never runs that workflow,
    so the stamp would be absent exactly where it is needed. The attestation
    stays on — it costs one manifest entry and answers a different question.
  - **Labels, not a manifest beside the image.** A side manifest joins two
    independently mutable things, so "the registry and the source disagree"
    becomes a state you cannot detect. A stamp has to be able to disagree
    visibly.
  - **Plus a file in the image**, because labels live in the image config and a
    running process cannot reach them. `docker/entrypoint.sh` prints the revision
    at boot; `tests/provenance_test.sh` asserts the two sinks agree.
  - **Redaction is a closed grammar, not a denylist.** A value may be stamped
    iff it matches the exact shape of its field, so there is no way to add a
    field without writing its shape. Eleven leak shapes are asserted refused by
    name against a green control. `source` admits exactly one `/`, which is what
    makes `owner/repo` expressible and every path, URL, hostname and credential
    inexpressible. The one shape no grammar can refuse — a branch-shaped
    `source`, which is shape-identical to `owner/repo` — is asserted in the
    suite and argued in the header rather than left to look covered.
  - **It is provable able to fail.** `docker/provenance.sh --verify IMAGE
    --expect-revision SHA` returns 5 on a wrong commit, 4 on an unstamped image
    and 0 on the right one. Three distinct codes because one code for both
    failures cannot tell a consumer which happened, and `unknown` fails an
    assertion even though it is accepted at build time.
  - `tests/provenance_test.sh`, 32 assertions, wired into the static phase.
    Runs with no docker for the grammar and the agreement checks; SKIPs loudly
    for the build.

## 2.0.0

### Breaking

- **`docker/provenance.sh --verify` fails on images it used to accept.**

**This changes the meaning of an exit code's neighbour, so it is not a silent
patch.** Six cases in this repository were accepted a moment ago and are now
refused, and the reason in every one of them is the same:
`org.opencontainers.image.*` are **standard OCI labels that every published base
image sets**, so an image built `FROM` a stamped one inherits them without
anybody stamping it. Measured against real images, in
`measurement-provenance-ownership-01.out`.

| what | before | after |
| --- | --- | --- |
| `cafaye/guard:e2e` (built `FROM oven/bun`) | exit **0**, printing `https://github.com/oven-sh/bun` as our source | exit **6**, naming `oven-sh/bun` |
| `cafaye/e2e-parlor:local`, `cafaye/e2e-site:local` (compose labels only) | exit **0**, printing five `<absent>` lines | exit **6** |
| a source that is a URL, or has three segments | exit **0** | exit **6**, with the `expect_source` line |
| a well-formed **foreign** source, no `--expect-source` | exit **0**, silently | exit **0**, plus a `WARN` that repository ownership was **not** established |
| a well-formed **foreign** source, **with** `--expect-source owner/repo` | not expressible | exit **5** |
| `cafaye/identity:e2e` (no labels at all) | exit 4 | exit **4** — unchanged |

**The exit codes, and what a caller should do about each.**

- **4 — unchanged and load-bearing.** "This image carries no labels at all."
  Something upstream depends on telling this apart from "this image carries
  somebody else's", so **4 and 6 are not collapsed** and must not be. A caller
  testing `== 4` still means *predates the stamp*; a caller testing `!= 0` is
  unaffected.
- **5 — unchanged in meaning, wider in reach.** "An expectation you gave was not
  met." The new `--expect-source` assertion lands here.
- **6 — new.** "The labels are present and are not a valid cafaye stamp": a
  field violates its own grammar, an identity field is absent, or the stamp
  carries nothing in kit's own namespace. Code written before this release only
  ever saw 4 and 5, so a caller branching on either is still correct, and a
  caller treating *any* non-zero as "unverifiable" now correctly includes the
  inherited-stamp case — which is the case it was blind to.
- **2 — new use.** `--expect-source` is grammar-checked before it judges
  anything, so a URL written as the expectation is refused rather than reported
  as a mismatch against a correctly stamped image.

**What to do if `--verify` goes red on you.** One of three things, all real,
none a false alarm: the image was built `FROM` something already stamped and
inherits its labels (make the Dockerfile emit all five, which every
`docker/Dockerfile.<lang>` already does); the image predates the stamp (exit
**4**, meaning the tag is old rather than untrustworthy); or a base image sets
`source` to a URL — real, because Bun's publisher does exactly that, and Bun's
`created` carries milliseconds where the grammar requires RFC3339 to the second.

**Adopting without changing anything.** The printing form still exits 0 on a
correctly stamped image, so `provenance.sh --verify IMG || true` is unaffected.
What is new is that the *default* is no longer silent: an inherited stamp now
fails with no flag at all. Add `--expect-source owner/repo` to assert the
repository as well.

**What is deliberately not here.** `parlor` and `site` each carry a copy of this
script and are mid-packet with the consumer wiring; copying the fixed script
into them is a separate, later change. `identity` and `guard` do not stamp
themselves — `identity:e2e` has `null` labels and `guard:e2e` has Bun's — and
that debt is named in the handoff rather than paid here.

### Changed

- **`tests/provenance_test.sh` gained part D**: the consumer side with the LABEL SINK
  STUBBED, so shape, ownership, the absent-field policy and the 4/5/6 split are
  executable with no daemon and no build. 46 assertions.
- **`self_test` breakage 103**, above the shard summary. It deletes the
  ownership-by-namespace block and nothing else.


## 1.0.0

### Added

- **`VERSION`, and three tiers derived from it rather than asserted beside it.**
  kit is consumed by copy and by `uses:` at a ref, so a consumer's only question
  is whether a version is safe to take, and until this it was answered by a
  person reading a diff — in every repository, forever. The numbers did not mean
  anything consistent either (`0.0.0` in four manifests, per-repo versions, no
  version at all here), so a consumer who learned the rule in one place could not
  apply it in the next.
  - The **source of truth is `VERSION`**, not a service manifest. A service's
    manifest describes that service; nine of them carry no `version` key on
    purpose, and none of them would be a place to record how safe it is to take
    *kit*. The two numbers are different questions and they stay in different
    files.
  - `1.0.0` and not `0.x`: in semver `0.x` *means* "unstable, anything may
    change", which is the sentence this removes, and a version a consumer has to
    re-read the meaning of is not a source of truth.
  - A version string this check cannot place is a **red build**, not a guess:
    `2.4.0-rc1` and `v2.4.0` are both refused, and `v2.4.0 -> 1.9.0` is a
    retraction rather than a fourth tier. The reasons are in
    `tests/validate.sh`.
  - The tier a release **owes** is a file, not a sentence: a MAJOR bump needs a
    `MIGRATIONS.md` section for its version, and a `### Breaking` heading in the
    changelog is only legal under a version whose MAJOR actually moved — under
    `## Unreleased` it is covered by no version at all, and that is a failure.
- **`RESERVED` — a tombstone for every name kit retires.** `buf`'s `reserved` and
  Kubernetes' `+k8s:deprecated` are the two references and they are **not the same
  mechanism**: buf's is a WIRE tombstone (a retired field *number* must never be
  reused, because the bytes still mean the old thing) and k8s's is a LIFECYCLE
  marker on a field that is still there. kit has no encoding, so the wire half
  does not transfer; what does transfer is the weaker half both of them enforce,
  which is the half that matters when a service's copy outlives the decision — **a
  retired name stays retired**. The file is in the `skip-allowlist` dialect, with
  the fourth hygiene rule inverted: a reserved name that EXISTS is the failure.
  Two entries, both from kit-20's withdrawn backup distribution.

### Fixed

- **`KIT_SELF_TEST_SHARD=n/n` verified NOTHING and reported PASS.** The shard
  index a caller passes is 1-based (`1/4` … `4/4`) and the shard key was
  computed as `num % n`, which lands in `0..n-1`. Shard `n/n` therefore asked for
  a residue class nobody is in, matched no breakage, ran zero recipes and — the
  part that mattered — was reported green by a four-way merge gate that had
  covered three quarters of the suite and said "all four shards green". The key
  is now `((num - 1) % n + 1)`, 1-based at both ends.
  - `i` is refused outside `1..n`, including the `0/n` spelling that used to mean
    "the shard carrying the unnumbered controls". Those controls now run on shard
    `1/n`.
  - An **over-provisioned** `n` — one above the suite's highest breakage number —
    is refused at the door with both numbers rather than discovered at the end of
    a run that verified nothing.
  - `tests/shard_test.sh` (new) evaluates the real `_shard_claims` out of
    `tests/self_test.sh` and proves the n shards partition the suite exactly once
    for n in 1, 2, 3, 4, 5, 7, 8 and the largest gap-free n. It runs in ~23s and
    asserts the refusals above.
  - Measured: with 97 breakages numbered 1..93 sparsely, the largest n with no
    empty shard is **62** — breakage numbers 63..67 are unused, so `n` in 64..93
    leaves a shard empty. That case is reported as a FAIL by the summary, not a
    PASS.

### Added — `security_definer_view`, the one ERROR/SEC rule the advisor never carried

- **`templates/database/tenancy/advisor.sql` gains a ninth rule**, and the header
  now says ten where it said nine. Postgres gives a view the privileges **and the
  row-level-security exemption** of the role that created it, so a view over an
  account-scoped table enforces the policies that apply to its *owner* — and a
  policy that applies to the owner is not a policy, because the owner bypasses its
  own policies unless the table is `FORCE`d. Writing a view over `account_users`
  is a way to hand every caller who can reach it every account's rows, and it reads
  in review as a `SELECT`.
- **It matters more here than in the Supabase reference it comes from
  (`lints.ts:604-614`, ERROR / SECURITY), and that is the whole reason the rule
  exists.** kit's model is per-service `NOINHERIT` login roles that **own** their
  tables, so "the owner is exempt from its own policies" is not a corner case of
  the definer model — it is every table in the fleet. A definer view here is a
  hole, and before this there was **no lint anywhere in the fleet watching for
  it**.
- **Three narrowings, each the difference between a rule that is trusted and one
  that gets switched off.** A view with `security_invoker = true` is not this
  finding — that is the remedy. A view that reads **no** table with row-level
  security is not this finding, or the rule becomes "every view in the schema is
  an ERROR". A view no login role can `SELECT` is not this finding;
  `has_table_privilege`, not a grant scan, for rule 2's reason that a grant is not
  the capability.
- **The dependency graph is walked transitively through views.** A view over a
  view is the *same* hole: Postgres evaluates the outer view with the outer
  view's owner's privileges and no hop in the chain puts a caller's policies back
  in force. A rule that stopped at the first hop would report the inner view and
  stay silent about the one a caller actually queries. The walk **stops at an
  invoker view**, which is the entire meaning of the flag.
- **The remediation is branched on the server version**, because
  `security_invoker` arrived in Postgres 15. Below it the option does not exist,
  every view is a definer view, every finding is true and none is clearable —
  so printing `ALTER VIEW … SET (security_invoker = true)` there would hand out a
  remediation that cannot execute, which is the one thing that column must never
  do. This fleet floors at PG15, so the branch is unreachable on kit's own
  cluster; it is written anyway, because a rule that means something different on
  two supported server versions is not a rule to be trusted on either.
- **Two Postgres behaviours measured rather than assumed, and both would have been
  silent:**
  - `pg_depend` records one row per *(rewrite rule, reference)*, so a view that
    names a table twice in its body reported it twice — `{plain, plain}` for one
    relation. `DISTINCT` in both the detail and the metadata.
  - **`pg_class.reloptions` is stored verbatim and the boolean is not
    canonicalised.** `security_invoker = on` is stored as `on`, `= true` as
    `true`, `= off` as `off`. The chain-stop hop was first written as an equality
    test against the literal `security_invoker=true` and it **missed the `on`
    spelling** — which is the spelling `core`'s own conforming fixture uses
    (`harness/tests/fixtures/tenancy/conforming/migrations/0002_rls.sql:89`). It
    would have walked straight past a view whose policies were already in force
    and reported a chain as broken that is not. Both spellings are now asserted.

### Added — the advisor and the fixtures that trip its rules were compared by nothing

- **`tests/validate.sh`'s tenancy contract check now compares rule NAMES, both
  ways.** `advisor.sql` is the only thing in the account boundary that grades the
  **live** database, every rule in it is proved by a fixture in
  `tests/tenancy_test.sh`, and `--static-only` runs neither — so nothing compared
  the two lists. A rule renamed, or its trip fixture renamed with it, left every
  static check green while the suite proved a rule that no longer existed.
  Over **names** rather than counts, because nine rules and nine fixtures that do
  not correspond is exactly the state this exists to make impossible.
- **`self_test` breakage 93** is the recipe. Its first version mutated the rule's
  `having` clause — the condition requiring the view to read something protected —
  on the theory that a rule which no longer narrows would be visible to the new
  check. **Measured: the gate stayed green**, because a check that compares names
  cannot see a rule that is present, correctly named and no longer selective. The
  recipe now mutates the name, and says plainly which file proves which property:
  `tests/tenancy_test.sh` proves the rule fires and does not misfire; the static
  check proves the advisor and its proof agree. Neither substitutes for the other.

### Fixed — the credential audit told the cluster's own admin role it had found nothing

- **`cafaye.credential_tables()` no longer reads a deparsed expression.** It
  returned `public | api_keys | token_digest` as role `alpha` and **zero rows** as
  role `cafaye` — same database, same policy — because `pg_get_expr` drops the
  schema from a name the *reader's* `search_path` resolves, `"$user"` is a
  `search_path` entry, and role `cafaye`'s own schema is the `cafaye` schema the
  substrate creates. The function's regexp required the qualified spelling, so an
  operator auditing credentials as the cluster's admin role was told this database
  holds no table resolvable without an account. Its own comment had already warned
  that *"an audit query that returns an empty column forever looks exactly like an
  audit query that found nothing"*; the trap was never the regexp's strictness, it
  was reading a pretty-printer's spelling at all.
- **What it reads instead: `pg_depend`.** `CREATE POLICY` records the policy's own
  `using` expression as dependencies — one `pg_proc` row for each function called
  (`deptype = 'n'`) and one `pg_class` row per referenced column of the policy's
  own table, with the column's `attnum` in `refobjsubid`. Both are OIDs, so the
  answer is the same for every role and every `search_path`. Measured on 16.15 and
  17; **not** on 15, kit's floor, because no 15 image was available to measure and
  an unmeasured version is not a verified one.
- **Semantics unchanged, in both directions, and measured.** A resolve-named policy
  whose qualifier is not the digest call still does not appear; a hand-written
  policy that mentions the digest under another name still does not appear; a
  qualifier reading *another* table's column does not appear. A qualifier naming
  **more than one** column of its own table cannot be narrowed to one — nothing
  structural says which the digest is compared against — so that row is reported
  with `'(unresolved)'` rather than with a NULL column, because a table named with
  an unresolved column is an audit finding and a table absent from the audit is the
  silence the function exists to prevent.
- **Rejected: `(cafaye\.)?` in the pattern.** That is the quiet fix, it is what
  `advisor.sql` does with its own regexps, and it is still a regexp over a
  pretty-printer's output — it accepts two spellings of one name and stays silent
  on a third, and the next reader cannot tell which spelling the audit saw.
- **`tests/tenancy_test.sh` assertion 8** reads the audit as three roles — the
  owner, the cluster's admin role, and the non-owner LOGIN role — and requires one
  answer that is **non-empty**, because three roles agreeing on nothing proves only
  that the audit has stopped working. Its control asserts the trap is still live on
  this cluster (one policy, two renderings), so the property half cannot pass
  vacuously.
- **`advisor.sql` keeps reading the text, deliberately, and says so.** Its rules are
  about what a predicate *says* — `using (true)` is invisible in every dependency
  catalog — so `(cafaye\.)?` stays and the residual reader-dependence is listed
  under that file's "what this does not find" rather than left to be inferred.
  Its comments no longer claim the substrate's audit requires the qualified form,
  which stopped being true.
- Mechanism semantics do not change: only how this mechanism is **audited**.
  `begin_credential/1`, the resolve policy, its predicate and the digest are
  untouched.

### Added — the account boundary's own advisor: the database grades its own policies

- **`templates/database/tenancy/advisor.sql`.** Eight row-level-security rules as
  one SQL function, `cafaye.advisor_findings(p_schemas text[])`, answering with
  one row per finding in the shape `(name, level, facing, categories,
  description, detail, remediation, metadata, cache_key)`. The **database** is the
  layer that can see what a migration-as-text and a set of denials cannot: a
  policy whose predicate is `true` satisfies every assertion in `isolation.sql`,
  because a permissive predicate RETURNS ROWS and a denial cannot tell
  permitted-by-predicate from permitted-by-accident; and two permissive policies on
  one (table, role, command) combine with **OR**, which no file scanner reads.
  The rules are ported from the shape of Supabase's database advisor and are
  **written from scratch against this fleet's catalogs** — nothing is vendored,
  per that project's own MIT-licensed-advisor rule and this repository's
  no-copy-from-`moon/refs/` rule. Every substitution is stated at the point it
  happens: `anon`/`authenticated` → any non-owner LOGIN role (so the
  source's anonymous-vs-signed-in distinction collapses and two rules become
  four-word rules rather than four), `pgrst.db_schemas` → the `p_schemas`
  argument, `auth.uid()` → `cafaye.current_account_id()`,
  `pg_policies` → `pg_policy` + `pg_get_expr()` (the source reads a materialized
  view their platform refreshes), `facing = EXTERNAL` dropped, and the
  documentation-URL `remediation` replaced by the SQL that fixes the finding.
- **`rls_references_user_metadata` gained a CATALOG half.** The source rule is that
  `auth.users.user_metadata` is user-editable, and the source *admits* it cannot
  do better than a string match. Postgres records a policy's dependencies, so
  "does this predicate read a table a login role may `INSERT` or `UPDATE`" is a
  question about `pg_depend`: a service keeping a `profile_flags` table and writing
  `using (exists (select 1 from profile_flags f where f.is_admin))` has built its
  own `user_metadata` and the keyword half can never find it. The keyword half is
  kept, caveat intact.
- **`multiple_permissive_policies` carries an exemption, and the exemption has a
  control.** A credential table holds FIVE policies, so `(api_keys, <owner>,
  SELECT)` holds two permissive ones permanently — that is MD24's mechanism, and
  they combine as `account_id = the session's account OR token_digest = the digest
  presented`. The rule stays at `WARN` and unsoftened; a group is exempt when
  **every** policy in it was written by the substrate, which is an all-of
  condition, so a hand-written sixth is not exempt. `tests/tenancy_test.sh` plants
  one and requires the rule to fire *and name it*.
- **`tests/tenancy_test.sh` runs it, three ways.** Zero `ERROR`/`WARN` against the
  two tables a service's migration writes, over a scope **derived** from the
  policies `protect_table` created; the exemption released by one hand-written
  policy, asserted to clean up after itself; and every rule fired on a fixture
  built to trip it, each naming itself and its table, scoped to the fixture schema
  alone so no rule is satisfied by whichever other rule happened to return a row.
- **Measured on the way in, and it shaped the file.** `pg_get_expr` deparses a
  name unqualified whenever the **reader's** `search_path` resolves it, and
  `"$user"` is a search_path entry: the same substrate policy reads as
  `cafaye.current_account_id()` for role `alpha` and as `current_account_id()` for
  role `cafaye`, whose `"$user"` schema is `cafaye`. Every regexp therefore accepts
  both forms, and says why. Requiring the qualified form alone would make
  `multiple_permissive_policies` report MD24's own policy as hand-written, and
  make `auth_rls_initplan` silently miss a bare call, to exactly the reader least
  likely to know why. That sentence also named the latent defect this entry's
  follow-up fixes: `cafaye.credential_tables()` read the qualified form only and
  returned nothing at all in that second session. Recorded rather than fixed here,
  because `substrate.sql` was out of scope.
- `assertions.txt` is **unchanged**: the advisor answers a different question with a
  different row shape, and the manifest names `isolation.sql`'s assertions.
- Gate shape: `tests/validate.sh` (the `.sql` parse-loop arm and the presence
  check) and `tests/artifacts.json` (`database/tenancy/advisor`, optional, with the
  same "optional is not the same as unexamined" argument the substrate makes).

### Fixed — the `--only` conversion on breakage 59, which could not have held

- **`expect_green_check` no longer appends `--only=<the check the recipe names>`,
  and breakage 59 runs the unfiltered gate again.** Its verdict is emitted by
  `report`, not by `check`:

      tests/validate.sh:5474  report PASS "fleet  (adopting repositories clean; …"

  `--only` is applied inside `check`, `check_par`, `report_par` and
  `bounded_check` — the four that spawn work. `report()` has no filter: every
  `PASS`/`FAIL`/`SKIP` it emits is printed and counted unconditionally. So no
  `--only` value could select it, and the gate's own no-match rule turned "the
  filter matched nothing" into `exit 1`, which failed the recipe's **first**
  assertion:

      FAIL self_test: breakage 59: an UNADOPTED service copies the stack —
        green, and named — the gate went RED (exit 1), so the ceiling is not in force
             FAIL: --only='fleet  (adopting repositories clean;' selected NO check
                    out of the suite.
             87 check(s) were excluded.

  Read that failure carefully, because it is the worst direction to be wrong in:
  it **accuses the adoption ceiling of not being in force** and prints a green
  gate's own findings underneath. The ceiling was in force throughout.

- **It was the SEVENTH conversion, and the only one never measured.** The reach
  table in `REPORT-kit-gate-speed-02.md` §4b walked the six `expect_red_check`
  conversions plus a control. `expect_green_check` is a *different helper* with a
  *different single caller*, so the conversion was made and never run. A
  conversion nobody ran is a conversion nobody proved — the same lesson as
  breakage 59's own history in that helper, which was once reported red because
  the harness read the gate through a pipe.

- **Cost, honestly: ~35 s on one recipe out of 94.** The alternative is a filter
  that names nothing, or one naming an unrelated `check` while the verdict under
  assertion is a `report` — a decoration on the command line that proves nothing
  about the thing the recipe is about. That is the weakened gate this suite
  exists to refuse, and it is the same trade already made for `expect_skip_check`
  (23b).

- **Verified both directions on the real recipe, not by reading the code:** with
  the conversion present, breakage 59 fails with the output above and
  `failures=1`; with it reverted, the same recipe on the same fixture prints
  `PASS self_test: breakage 59: … stayed green and named the debt` and
  `failures=0`.

### Changed — `--only` now reaches every recipe it can reach, and two helpers
  prove less than they did

- **`tests/self_test.sh`: breakages 2, 2b, 3, 4, 5 and 6 now run
  `expect_red_check` and append `--only=<the check the recipe names>`** — the
  mechanism that was already in `expect_red_check` and in nothing else. Measured
  on this machine: a full `--static-only` gate run is **42.70 s** and a run
  filtered to one check is **7.88 s**, so each converted recipe saves ~35 s.
  **`expect_green_check` (59) and `expect_skip_check` (23b) were converted by
  this packet too and have since been reverted** — see the Fixed entry above and
  `git show ab25775`. Both name a verdict that is a `report`, and `--only`
  cannot reach a `report`.

- **Six proofs got STRONGER, not just faster.** `expect_red` asserts only "the
  gate went red", which is a weak claim when forty checks can make it red; all
  six now assert `FAIL <the named check>`, and each names the check it is about
  as a variable, so a rename on either side breaks the file loudly.

- **Breakage 1 deliberately still runs the unfiltered gate, and says why.** The
  verdict that catches a deleted `templates/otel/go/traceparent.go` is
  `templates/otel/go/  (4 artifacts present)`, which is a `report`. `--only` is
  applied inside `check`, `check_par`, `bounded_check` and `tier` — the four that
  spawn work — so a `report` is printed on a filtered run and still paid for.
  Measured: that copy under `--only=ZZZ_NO_SUCH_CHECK_XYZ` printed exactly that
  one `FAIL` and nothing else.

- **The two green controls are unfiltered on purpose** (`expect_green`: the
  unbroken tree, and breakage 31b). Their whole claim is that the gate is green
  on a tree it did not break, and a filter would narrow the claim to the named
  check instead of the tree.

### Added — the profile, and what it says

- **`PROFILE-gate.md` — where this gate's time actually goes, measured rather
  than guessed.** `self_test` is **~96%** of a full run (~4,905 s of ~5,103 s
  projected), because each of its 94 breakages is a whole `tests/validate.sh`
  running 113.6 timed checks to learn one fact about one named check. The top
  three costs are **98.2%** of the run; the longest tail row is 1.2 s. The run
  it is from was truncated at 569.0 s and the file says so in its own first
  paragraph.

- **`HANDOFF-kit-gate-speed.md`** — the successor's brief, including the finding
  that decides the order of work: **`--only`, which the recipe comments call
  "the 60×", is appended by `expect_red_check` and by nothing else, so 21 of 94
  recipes still run the whole static phase.** The real factor is ~47×.

### Added — the gate can now say where its own time went

- **`KIT_PROFILE=<file>` writes a timing profile of any gate run.** A gate that
  takes ten minutes cannot be improved from intuition, and every claim about
  which part is slow is a claim about a measurement nobody else can take on the
  same tree — so the measurement is part of the gate rather than something a
  worker hand-assembles with `date` calls and a scratch file. The TSV is four
  tab-separated columns — kind, label, seconds, tag — and every row in it is
  already an answer to some question about the run.

- **One TSV row per timed region, in five kinds that are never summed together.**
  `check` (a serial `check`/`check_verbose`), `cpu` (a `check_par` child — these
  OVERLAP, so their sum is an upper bound on the parallel region, not its
  duration), `tier` (a `bounded_check`), `phase` (the interval between two
  `section` headers, plus a hand-placed marker per top-level phase), `verdict` (a
  loop that reached its verdict from a `[ -x ]` rather than a command) and
  `total`. The phase rows are the safety net: a tier that is a bare `report` over
  a heredoc spawns no command at all, so the per-check rows cannot see it and the
  phase rows can. A profile whose rows add up to more than the run is a profile
  that has been read wrong, which is why `cpu` rows are never summed with the
  rest.

- **Every verdict line is a row, because `report` is where the row is written.**
  Timing the check *helpers* left forty `PASS` lines with no measurement beside
  them — a hole that reads as "cheap" to everyone who reads the table later. The
  arms that reach a verdict without spawning anything are the case that proves
  it, and they are now measured too: `report` closes whatever interval is open
  and re-arms it, so the cost lands on the verdict that ends the work.

- **The self-test's 94 child gates are separable without touching
  `tests/self_test.sh`.** Every recipe runs a whole `tests/validate.sh` in a
  throwaway copy, and those copies inherit `KIT_PROFILE` — so without a boundary
  the most expensive phase in the run would be one undifferentiated mass of rows
  whose labels are the same ones the gate's own rows carry. `kit_total` writes a
  `total` row on the EXIT trap of *every* invocation, and `self_test` runs its
  children in sequence, so the `total` rows ARE the segment boundaries: rows
  between two consecutive `total` rows are one gate invocation. `KIT_PROFILE_TAG`
  is read into the tag column and inherited when set, which lets a caller label
  a child without this file knowing anything about it.

- **Off by default, and off means off.** Every measurement site reads
  `_t0=0; [ -n "$_PROFILE" ] && _t0="$(_pf_now)"`, so with the variable unset the
  clock is never read and no process is spawned — which is a real design
  constraint rather than a nicety, because a profiler that makes the run it
  profiles slower reports its own overhead as the gate's cost. The clock is
  integer milliseconds from `perl -MTime::HiRes` rather than `awk`: an `awk`-per-
  measurement version would have added ~38,000 processes to a run that spawns
  ~19,000 checks, and its numbers would have been wrong in the direction that
  matters. `kit_total` runs on the EXIT trap so the table's denominator is a
  measurement rather than the reader's arithmetic over rows that are
  individually correct and collectively incomplete.

- **The gate's own output is byte-identical with the profiler on and off.**
  Verified, not asserted: `diff` over a full `--static-only` run's stdout and
  stderr, profiled against plain, is empty. Nothing here writes to stdout, and
  `--only` and `tests/self_test.sh` both read that output by position.

- **It is not a gate.** Nothing in the profiler can change a verdict, and a
  profiling run is not a substitute for a plain one — the run that printed the
  table is still the run whose exit status counts.

### Fixed — `bin/dev down` left the observability containers running

- **Measured, and it is the mirror of the `print_urls` fix.** The backends are
  behind a compose profile, and `docker compose down` without that profile does
  not touch them. So `KIT_DEV_PROFILES=observability bin/dev up` followed by a
  plain `bin/dev down` exited 0, printed "stopping the stack (volumes kept)", and
  left tempo, loki and grafana **running and healthy**. A teardown that reports
  success while three containers and their memory limits are still up costs more
  than a printed URL that does not resolve.

- **`down` and `nuke` now stop the whole project.** Both read the project's own
  profile list from `compose config --profiles` and pass every one, so the
  teardown covers what is actually running whichever variable the shell happens
  to have. The list comes from the compose file because a hardcoded
  `observability` would be a second copy of a name that already lives there.

- **`nuke` mattered more.** It removes the volumes the observability containers
  were writing to while leaving those containers running, so Docker recreated
  the volumes empty on the next start — a half-deleted stack rather than a clean
  one.

- Re-measured after the full stack is up: `bin/dev down` with `KIT_DEV_PROFILES`
  unset leaves **0 containers and 6 volumes**, which is what "stop, keep the
  data" says.


### Changed — the metrics store is gone, and nothing is left dialled at nothing

- **The fourth backend left the stack: mimir.** Its own healthcheck was
  `retries 12 × interval 10s` — 130 seconds of readiness budget per cold start,
  against a 180-second deadline for the whole stack, and 384m of memory — for a
  fleet that does not have the series to put in it. It is **removed rather than
  disabled**: `mimir.yaml` deleted, and with it the compose service, the volume,
  the published port (`15902`), the `KIT_MIMIR_*` variables in `.env.example`,
  the collector's exporter, and the `prometheus`-typed datasource. An exporter
  pointed at a host with nothing behind it is one connection refused per flush,
  forever, in a log nobody reads — while `up --wait` reports the stack healthy.

- **Span metrics are still derived and still redacted; they go to the
  collector's own stdout.** `spanmetrics`, `redaction/cafaye_metrics`,
  `transform/cafaye_metrics_ingest_drop` and `batch` all still run, and
  `exporters: [debug]` is where they land. That is not a consolation prize: it
  keeps the allowlist exercised on real derived metrics rather than only
  asserted about. **Putting a store back is four edits that belong together** —
  the endpoint variable in `.env.example`, the exporter block in
  `otel-collector.yml`, the `exporters:` line on the metrics pipeline, and the
  compose service plus its Grafana datasource. Any subset of them is the
  half-removed backend this will not ship, and two checks now say so out loud.

- **The gate's own assertions follow it out, and two of them got STRONGER.**
  Eight checks were red on this tree, all of them naming a container that no
  longer exists. Each lost the name and kept its shape; two gained a claim that
  could not be made before: the metrics pipeline must export to `debug` **and to
  nothing else**, and Grafana must provision **no** metrics datasource — because
  a datasource nothing fills renders panels that are permanently empty and teach
  a reader that empty means nothing. A third is new: nothing under
  `templates/compose/` may be unreferenced, which is the half of "nothing names a
  container that does not exist" that a hand-written mount list cannot hold.

- **`tests/stack_live_test.sh` reads the metrics out of the collector instead of
  a store.** The two PromQL assertions became three assertions over the
  collector's own `debug` output, at `KIT_OTEL_DEBUG_VERBOSITY=detailed` because
  at `normal` the exporter does not print the attribute map and "the
  high-cardinality dimensions are absent" would be satisfied by the exporter
  being quiet. It now proves something the store never did: that the ingest deny
  set runs on the way out.

- `templates/AGENTS.md`, `README.md`, `templates/parity-allowlist`,
  `templates/compose/loki/loki-config.yaml` and the compose header stop saying
  "four" and stop naming a directory that is gone.

### Changed — `bin/dev` starts the cheap stack, and observability is the deliberate spelling

- **`KIT_DEV_PROFILES` defaults to empty.** `templates/bin/dev.sh` read
  `${KIT_DEV_PROFILES-observability}`, so every developer's `bin/dev up` paid for
  four observability backends by default — and the compose file's own readiness
  budgets are the argument: mimir 130s (retries 12 × interval 10s), tempo 65s,
  loki 16s, grafana 20s once and over 180s another time on a cold volume while it
  downloads a plugin zip nobody asked for. Against a 180s stack deadline and a
  76s typical cold start (`RESEARCH-fleet-velocity.md` P1), the default was the
  tax and `KIT_DEV_PROFILES= bin/dev up` — documented as the *escape hatch* — was
  the good path. That is backwards, so it is now the highway:
  `KIT_DEV_PROFILES=observability bin/dev up` brings up tempo, loki and grafana.

- **Telemetry is unaffected, and that is the part worth stating.** The collector
  is not behind the profile, so `<SERVICE>_OTEL_ENDPOINT` still has somewhere to
  send on the default path, and `redaction/*` still runs before anything would be
  stored. On the cheap path the data is dropped because there is no store to hand
  it to, which is strictly better than paying 130 seconds to keep it.

- **Deliberately NOT read from `.env`.** Every other `KIT_*` goes through
  `stack_setting`, which cannot distinguish "unset" from "set to empty" — so a
  `.env` reader here would be a second reader of one fact with different
  semantics, and a `.env` saying `observability` would silently re-impose the tax.

- Docs that described the old default are updated in the same commit
  (`README.md`, `templates/AGENTS.md`, the compose file's header, and `bin/dev`'s
  own `--help` and completion message), because a doc that describes a default
  the script no longer has is drift the next reader pays for.

### Changed — the sweep no longer assumes it owns the database

- **`cafaye.unprotected_tables/0` is scoped to the schemas the substrate was
  applied in**, plus `cafaye` and the session's temporary schema. It scanned
  every table in the database, so the assertion set assumed it owned the
  database: true in `tests/tenancy_test.sh`, false for every adopter whose tests
  build private fixture schemas.

  **Measured, on `identity`** — which adopted this substrate and whose whole-suite
  run then failed kit's own control:

  ```
  sweep/the-only-finding-is-the-control
    expected "cafaye_probe_unprotected:row level security is not enabled"
    actual   "...,account_users:...,api_keys:...,oidc_clients:..."
  ```

  `relforcerowsecurity` is `t` on all five real tables. Those names are
  `identity`'s **fixture** schemas, built by a test helper cloning tables with
  `LIKE … INCLUDING ALL` — and `LIKE` does not copy row-level security, so each
  fixture carries an `account_id` column and no policies. The count moved per run
  (5, then 21) with how many neighbouring tests were mid-flight, which is the
  evidence that it was a reach rather than a defect.

- **The scope is DERIVED from the catalog, not recorded in a table**, and that is
  what makes it an adopter's fix rather than an adopter's migration. A registry
  table would have to be created by the new substrate, so the repair would arrive
  only with a migration — decided by the very proof it repairs. Instead the scope
  is read back out of what the substrate already wrote: `protect_table` names its
  policies `<table>_cafaye_<command>`, so every schema it was applied in is
  discoverable from `pg_policy` with nothing new to install.

- **The scope is per SCHEMA, not per table**, deliberately: a table added next
  month to a schema already in scope is still named, so the sweep keeps its
  growth-guard property rather than only its adopter-safety one. Scoping to
  `cafaye` + `pg_temp` alone — the obvious minimal fix — was rejected: it sweeps
  no real table in any adopter, so its positive control and its empty result are
  both satisfied by a sweep that could never have run.

- **`tests/tenancy_test.sh` gained two assertions, and neither means anything
  alone.** `0b` plants `identity`'s shape — a private fixture schema cloned with
  `LIKE … INCLUDING ALL` — and requires the proof to stay green and the sweep to
  name neither of its tables. `5` plants an unprotected account-scoped table in a
  schema the substrate **does** own, permanently, and requires the proof to go
  red. Narrow the scope to `pg_temp` alone and `0b` passes forever while `5` goes
  red: which is the only reason `5` exists. Both read the catalog before
  asserting on it, so neither can be satisfied by a fixture that failed to
  install.

- **`string_agg` over the sweep carries an explicit `order by`.** The expected
  value is a string, and a string built from an unordered aggregate is a red on a
  correct database whenever the planner is in a different mood.

- **No assertion NAME changed**, so `assertions.txt` and the six drivers are
  untouched, and no enforcement changed: `protect_table`, `begin_account`, the
  four policies and `FORCE ROW LEVEL SECURITY` are not in the diff. `FORCE`
  control re-measured: **6 reds before, 6 reds after**, every one an `owner/` or
  `sweep/` row, with the `login/` half green throughout.
### Added — the service entrypoint migrates before it serves

- **`docker/entrypoint.sh`, and all seven Dockerfiles wired to it.** Every image
  template shipped a bare `ENTRYPOINT ["/app/service"]`, so the schema a service
  booted against was whatever the last deploy or the last developer left behind,
  and a second replica booting beside the first met the cold-start failure:
  the service is up, the schema is not. `RESEARCH-fleet-velocity.md` P0-6.
  Both references that get this right do it in one shape — migrate first, serve
  last, chained so a failure refuses the start
  (`refs/signoz/…/compose.yaml:7-12`, `refs/bugsink/Dockerfile:54`) — so that
  shape is one script rather than seven hand-written wrappers.

- **THE DEPLOY STORY CHANGED, and this is the feature.** A failed migration now
  means a **failed container**: the service crash-loops instead of serving
  requests against a schema it does not understand. Two consequences a service
  has to decide about: **every replica migrates at boot**, and an image can no
  longer be `docker run` for a side purpose (`--help`, a debug shell) without
  `KIT_MIGRATE=off`.

- **`KIT_MIGRATE=auto|required|off`, `KIT_MIGRATE_CMD`, and
  `KIT_MIGRATE_ADVISORY_LOCK`.** The resolution order — `KIT_MIGRATE_CMD`, then
  `./bin/migrate`, then `./bin/rails db:prepare` — is deliberately the same probe
  `templates/bin/dev.sh` performs, in the same order, minus `mix ecto.create &&
  mix ecto.migrate`, which is a developer sequence against a database it may
  have to create. `auto` is the default because a service with no database is a
  real member of this fleet and must not be made unbootable; `required` is for a
  service that owns a schema.

- **CONCURRENCY, stated rather than papered over.** Every replica migrates at
  boot and the entrypoint does **not** serialize them by default — it prints
  that fact on every boot with no lock set. The delegation is explicit: the
  fleet's `bin/migrate` has **no lock at all** (no version table, no advisory
  lock, no transaction around the set) and relies on idempotent replay.
  `KIT_MIGRATE_ADVISORY_LOCK=<int>` holds a Postgres **session**-level
  `pg_advisory_lock` around the migration. Verified against a real `postgres:17`:
  two replicas with the lock do not overlap and the same two without it do, a
  failing migration releases it, and a replica `SIGKILL`ed mid-migration
  releases it because the session dies. It is opt-in because it needs `psql`.

- **AND NOT `psql -c "\! <cmd>"`.** Measured on PostgreSQL 17: psql does not
  propagate a `\!` command's exit status — `\! sh -c 'exit 7'` exits 0. A lock
  wrapper that swallowed the failure would serve against exactly the schema it
  just failed to apply. So the lock is held by a dedicated `psql` session driven
  over a FIFO, and the migration's exit status is the shell's own.

### Changed — `go` and `rust` images finish on `debian:*-slim`, not distroless

- **Measured, not assumed, and the measurement reversed the expectation.** The
  reason those two templates used distroless was that it carries no shell, and
  the entrypoint is a script. **Neither distroless variant ships a shell** — not
  `static`, and not `base` either:

  ```console
  $ docker run --rm --entrypoint /bin/sh gcr.io/distroless/base-debian12:nonroot -c 'echo hi'
  exec: "/bin/sh": stat /bin/sh: no such file or directory
  $ docker export $(docker create gcr.io/distroless/base-debian12:nonroot) | tar -tf - | grep '^bin/'
  bin/                       # empty
  ```

  So "no shell, so a compromised process cannot curl and pipe" and "the
  entrypoint migrates" cannot both be true. Migrating at boot wins; the price is
  named in each file, and the escape hatch is written down: `KIT_MIGRATE=off`, a
  `pre-deploy` job, distroless back. Non-root is preserved as numeric
  `65532:65532`, which needs no passwd entry, and manifest-before-source
  ordering and the layer structure are unchanged.

- **`docker/entrypoint.sh` joins the shellcheck loop and the executable-files
  check.** `$ROOT/docker/*` was already in the artifact-parses loop, so the
  script got `bash -n` for free; shellcheck and the `chmod +x` assertion are the
  two the gate's shape did not reach on its own.
### Added — the account boundary, shipped once in kit

- **`templates/database/tenancy/substrate.sql`.** The account boundary inside one
  service's own database: the identity seam (`cafaye.begin_account/1`,
  `cafaye.current_account_id/0`), `cafaye.protect_table/2`, and the sweep
  (`cafaye.unprotected_tables/0`). Measured, before and after.

- **`templates/database/tenancy/isolation.sql` + `assertions.txt`.** The assertion
  set — **39 assertions**, run twice, once as the login role and once as the
  owner — and the manifest they are compared against. `templates/database/<lang>/
  tenancy_test.*` drives it in all six languages kit templates.

- **`FORCE ROW LEVEL SECURITY`, and a proof it is load-bearing.** It is in no
  guide and **no lint in this fleet checked for it** — measured across all nine
  account-scoped services: zero `ROW LEVEL SECURITY`, zero `CREATE POLICY`, zero
  non-owner login roles. On a protected three-row table, read as the owner
  carrying another tenant's identity: **1 row with FORCE, 3 without.**
  `tests/tenancy_test.sh` deletes the statement and requires six assertions to go
  red — all of them `owner/` or `sweep/`, with the `login/` half staying green,
  which is what makes the control specific rather than merely present. With the
  credential fixture added it is **eleven** red on the same terms, and the five new
  ones are the credential half's owner rows: an owner that bypasses its own table
  turns a resolution context into a browsing context, which is exactly the failure
  a resolution path has to be proved against.

- **Credential resolution — `cafaye.protect_credential_table/3`, the one answer to
  "the account is what the query is for".** `identity` adopted the substrate
  (migration 00016) and then measured, against its real protected `api_keys` table
  and as the OWNER, that a request presenting a scoped token reads **zero** rows:
  the account cannot scope the lookup that is trying to learn it, so every machine
  credential authenticates to a **401 "not found"**. `protect_credential_table` is
  **one call, the same size as `protect_table`'s**, and it protects the table
  exactly as `protect_table` does and then adds a fifth policy:

  ```sql
  using (token_digest = (select cafaye.current_credential_digest()))
  ```

  The predicate lives in the **policy**, not only in the caller's query, which is
  the whole design — policies combine permissively, so a policy saying "a
  credential session may select this table" would be a table-wide `SELECT` and
  every key in the database browsable. The honest semantics, asserted in both
  roles: **a resolution session may read exactly the credential row whose digest
  it presented, and nothing else in the database** — `select *` returns that one
  row, and every other table reads zero. It also cannot write (so a resolution
  cannot mint a credential), it is a second transaction-local GUC for the pool
  reason `begin_account/1` is, and `cafaye.credential_tables/0` is the audit that
  answers *which tables can be read with no account*. Rejected and why:
  a `BYPASSRLS` role (right for Supabase's topology, which has a separate service
  role and no per-request one), a `SECURITY DEFINER` function (**does not work
  under `FORCE`** — it applies to the definer), dropping `FORCE`, and leaving
  `api_keys` unprotected. `DECISIONS.md` **MD24** carries the argument and the five
  things the mechanism cannot do.

- **`(select …)` around the identity call, measured rather than asserted.**
  `tests/tenancy_test.sh` counts invocations over five rows on every run:
  **1 wrapped, 5 bare.**

- **`tests/tenancy_test.sh`** — a real cluster from the stack kit ships, the
  substrate applied, the proof run three times (clean, with the FORCE control
  mutated in, and measuring the init plan). Bounded at 1800s in the observability
  phase, next to `tests/isolation_test.sh`.

- **`tests/validate.sh` — `templates/database/tenancy/*  (the account boundary,
  in the templates that enforce it)`.** Ten required strings and five forbidden
  ones in the substrate, **over SQL comments stripped** (the substrate's own
  comments quote every required string while explaining why it exists); four
  required strings in the proof; the eight-name spine asserted to be CONSTRUCTED;
  the manifest and the proof compared **in both directions**; and every one of the
  six drivers required to READ both files on the same line as a read call rather
  than merely mention them. Every list it iterates has an empty-list guard.

- **`tests/validate.sh` — six parse checks for the six drivers**, on the rule
  "parse what you hand out". `templates/database/tenancy/*.sql` are reported as
  parsed by `tests/tenancy_test.sh` rather than by this loop, because a migration's
  syntax is only observable by a server.

- **Self-test breakages 90-92**: `FORCE ROW LEVEL SECURITY` removed from the
  substrate; a driver that reads the proof but no longer the manifest; the
  manifest and the proof disagreeing.

### Changed — a second role per service, which changes nothing for a service that has not adopted it

- **`templates/compose/postgres/initdb/10-cluster.sh` provisions `<service>_app`
  beside `<service>`,** grants it CONNECT and the two per-role timeouts, and grants
  it **TO** `<service>` — never the reverse. `<service>` is unchanged: it still owns
  the database and every table, still runs migrations, and still carries the
  `CONNECTION LIMIT`. The app role deliberately does **not** carry one: the budget
  is nine services' worth, and a service that adopts the tenancy templates opens
  its connections as `<service>_app`.

- **Why the role is not optional decoration.** Postgres exempts a table's **owner**
  from its own row-level-security policies, and every service in this fleet runs
  its migrations as its own role. A login role that owns its tables can
  `ALTER TABLE … DISABLE ROW LEVEL SECURITY` and can `DROP POLICY`, so an account
  boundary enforced only by policies is one privilege away from meaning nothing.

- **`bin/dev db grant` prints both roles** and both sets of grants, because
  `docker-entrypoint-initdb.d` only runs on a fresh volume and a service
  provisioned before this existed would otherwise have no app role at all.

- **`tests/isolation_test.sh` asserts the role topology**, including the direction
  that is NOT allowed: `<service>_app` must not be a member of `<service>`.

- **`tests/artifacts.json` gains ten rows** — the substrate, the isolation script
  and manifest as one bundle, the README, and one driver per language. All marked
  `optional`, because a service holding no customer rows is core's **honest
  zero** and must be able to say `accountScoped: false` without carrying a
  row-level-security substrate it has nothing to scope. Optional is not the same
  as unexamined: `tests/validate.sh` asserts all ten exist in this repository.

- **`templates/database/contract.json` gains a `tenancy` block**, rather than a
  second contract file: `requiredSettings` says what a generated config must
  carry, `tenancy` says what the substrate must contain, and two subjects belong
  in one machine-readable place rather than two that can disagree.

### Not changed, deliberately

- **`core`.** `schemas/tenant-isolation.schema.json`, `docs/tenancy.md` and
  `harness/tenancy_check.py` are untouched. `tenancy.yml` remains a service's
  DECLARATION of where its scoping happens and which test proves it; what ships
  here is the ENFORCEMENT that makes the declaration honest. A service still
  carries its own `where account_id = ?` on every query, and `core` still requires
  it — RLS is defence in depth, not a licence to delete the predicate, which is
  also what makes the query indexable.

- **Any service.** Nothing was adopted anywhere. The nine services keep their
  hand-written predicates until the adoption wave, and `templates/parity-allowlist`
  is unchanged rather than padded with nine new `absent` rows this packet cannot
  verify.

### Added — a check for the one defect the static phase was structurally unable to see

- **`tests/validate.sh` — `conflict_markers_absent`, run as the first check of the
  static phase.** Found by this packet's own merge: two merge-conflict markers
  reached `origin/master` here and in `billing`, and the residue in both was a
  `CHANGELOG.md`.

- **Why no existing check caught it.** Not oversight — a category the static
  phase cannot cover. Every parse in that phase runs over YAML, JSON, shell, Go,
  Ruby, Python and compose, and all of them were clean. Both markers were in
  *prose*, which this suite reads for the presence of headings and never parses
  for content. A half-resolved merge is still valid markdown: all three marker
  forms at the start of a line render as ordinary text, so nothing downstream
  objects and the suite reports green on a tree that is wrong.

- **All three forms are matched, and that is the part worth having.** What
  actually got through was the `||||||| base` line that `diff3` writes *beside*
  the `<<<<<<<` / `=======` / `>>>>>>>` triple. Resolving a merge by hand
  removes the triple and leaves the base marker, so the result *looks* resolved to
  anyone skimming the diff — and `grep -c '<<<<<<<'` reports `0` on a tree that
  is still wrong. A check for the classic pair alone would have stayed green
  through exactly the case that reached master.

- **The pattern is written `^<{7} `, not as seven literal angle brackets.** That
  is load-bearing. A checker whose own source contains the literal marker line
  flags itself, and both conventional escapes are worse than the problem:
  excluding the checker from its own scan leaves a hole in the one file most
  likely to hold residue, and suppressing the finding wholesale makes the check
  unable to report the truth. The interval form is a *regex*, so the literal
  sequence never appears in the file and the check is self-excluding by
  construction rather than by exception.

- **Measured, not assumed.** Proved green on the tree, red on the real tree with
  a base-only marker injected (reported as `CHANGELOG.md:4249`, naming file and
  line), and green again after the revert. Against a fixture it flags all three
  forms and stays quiet on the four things that must stay quiet: its own source
  line, prose that merely *discusses* markers mid-sentence, six angle brackets,
  and a binary file carrying the bytes.

### Fixed — an `options:` key GitHub does not accept had silently stopped the whole fleet's CI from running

- **`.github/workflows/ci.reusable.yml`, five checks in `tests/validate.sh`,
  `AGENTS.md`, and `tests/self_test.sh`. Found by `actionlint`, not by a failing
  check — which is the point of the last part of this entry.**

  The `language` input carried an `options:` list from 2026-09-30 until now.
  `workflow_call` inputs accept `description`, `required`, `type` and
  `default`; `options:` belongs to `workflow_dispatch`, which is a different
  event with a different schema. GitHub does not ignore an unknown key under
  `workflow_call` — it **rejects the entire workflow file at parse time.**

  Every service in the fleet calls this workflow. So from that date until this
  commit, every CI run in every repository started **zero jobs** and reported
  **zero check runs**, while all 200+ of kit's static checks stayed green.
  Nothing was red because nothing ran. The workflow file was not merely
  degraded; it was not a workflow.

- **`actionlint` named it in one line and 214 checks did not:**
  ```
  .github/workflows/ci.reusable.yml:60:9: unexpected key "options" for inputs at
  workflow_call event. expected one of "default", "description", "required", "type"
  ```
  A sweep of every workflow in the fleet found this one file and no other.

- **The fix is a job, not a list.** `options:` was doing one job — rejecting a
  value no language job handles — and it did it by making the value
  unexpressible. Without a dropdown that guarantee is gone: `language: golang`
  matches no `if: inputs.language == '…'` condition, so all eight language jobs
  skip and the run goes green having tested nothing. A new first job named
  `language` now runs unconditionally and `case`es the value, failing the run on
  anything it does not recognise. That is strictly stronger than the dropdown:
  the dropdown was a UI affordance, this is a gate.

- **A new check, `reusable workflows (workflow_call inputs use only documented
  keys)`, so the class cannot recur.** It is deliberately **not** a full Actions
  schema validator — it cannot know about expression contexts, runner labels or
  `uses:` resolution — and it asserts exactly one property: every key directly
  under a `workflow_call` input is one GitHub documents for that event. Its
  message names `options` and says what to do instead, because a message naming
  the key is one the next author can act on.

- **Five checks were reading the illegal key, which is how the defect stayed
  invisible.** `ci_check`, `kit_languages`, `mise_check`, `tier_declaration_check`
  and `tier_demand_check` all read the `options:` list as *the* list of languages
  kit ships — and `tests/artifacts.json`'s `{lang}` check read it too. Removing
  an illegal key correctly turned all five red. They now read the gate job's
  `case` statement, which is where the enumeration actually lives, so the list
  and the thing that enforces it are the same object rather than two copies that
  can drift.

- **Each of those five now refuses to pass on an empty list.** Deleting or
  renaming the gate job used to make every one of them loop zero times and
  report success — the same failure mode as the outage itself, one level down.
  Verified by mutation: with the gate job renamed away, **six** checks go red
  (it was two before the guards were added). A check that could not ask its
  question now says so.

- **`tests/self_test.sh` breakage 89** re-adds the exact key to the exact input
  and asserts that named check catches it. The proof failed before the check
  existed and passes after; the unbroken tree is green on both sides.

### Fixed — kit's own remediation advice was telling services to make themselves a cluster superuser

- **`tests/fleet_check.py`, `README.md`, `templates/AGENTS.md`,
  `templates/database/README.md` and `templates/compose/docker-compose.yml`'s own
  header — five copies of one wrong sentence, all corrected, and a check added
  because correcting prose alone would have left the gap open from the other
  side.** The stale-copy finding ended *"Point it at its own database by
  overriding the `postgres` service's environment (POSTGRES_DB /
  POSTGRES_USER)"*, and the adoption-path block printed the same instruction to
  every unadopted repository in the fleet. It was wrong in a way that does not
  merely fail to help.

- **Measured, on a cluster built from this repository's own
  `initdb/10-cluster.sh` against `postgres:17` — not inferred.** A service that
  follows the advice and sets `POSTGRES_USER: <itself>` gets a role the official
  image created, and the image creates it as a **superuser**. One cluster, with
  one service provisioned the supported way and one the overridden way
  (`KIT_POSTGRES_DATABASES=courier`, `POSTGRES_USER=identity`):

  ```
  $ psql -U identity -d identity -tAc \
      "select rolname, rolsuper from pg_roles where rolname not like 'pg\_%'"
   courier|f         <- made by the init script: NOSUPERUSER
   identity|t        <- made by the image, for the service's own name
  ```

  That is the whole of `10-cluster.sh:108`'s `LOGIN NOSUPERUSER NOCREATEDB
  NOCREATEROLE NOREPLICATION`, undone by the override the same repository
  recommended. The consequence, from inside that cluster:

  ```
  $ psql -U identity -d courier -tAc "select count(*) from invoices"
  2
  $ psql -U courier  -d identity -tAc "select token from sessions"
  psql: error: FATAL:  permission denied for database "identity"
  DETAIL:  User does not have CONNECT privilege.
  ```

  The second is `MD21d`'s boundary refusing a service — at the door, before a
  table is even named — and the first is the same query not being refused.

- **The other two keys stop the CLUSTER, not just the service.** The image
  creates `POSTGRES_USER` and `POSTGRES_DB` *before* any init script runs, so
  `CREATE ROLE` / `CREATE DATABASE` in the script then find them already there.
  `admin()` runs psql with `ON_ERROR_STOP=1` (`10-cluster.sh:78`), this happens
  **during initdb**, and so the whole cluster refuses to start. Measured, both
  shapes, exit status 3:

  ```
  $ docker run -e POSTGRES_USER=identity -e KIT_POSTGRES_DATABASES=identity,courier …
    [cluster] provisioning identity
    ERROR:  role "identity" already exists
  $ docker run -e POSTGRES_DB=identity -e KIT_POSTGRES_DATABASES=identity,courier …
    [cluster] provisioning identity
    ERROR:  database "identity" already exists
  ```

- **`POSTGRES_PASSWORD` is refused for a third reason, and the finding says so
  rather than borrowing the other two.** It breaks neither the cluster nor the
  boundary. It is the credential every role is handed (`10-cluster.sh:107` passes
  `$POSTGRES_PASSWORD` to each), so one service's file chooses it for all the
  others — measured, a service overriding it authenticates `courier` with its
  own password on a fresh volume. It is still refused, and the message says that
  is *why*.

- **The advice is now `KIT_POSTGRES_DATABASES` in `.env`**, which is the
  mechanism the init script was always built around: each name becomes a
  `NOSUPERUSER` role and a database it owns, and the `REVOKE CONNECT ... FROM
  PUBLIC` boundary is applied to it. No compose file at all. The `down -v` that
  goes with it is in the message too, because `docker-entrypoint-initdb.d` runs
  once per volume and a developer who adds their name and runs `up` gets a
  cluster that looks fine and a database that was never created.

- **`check_override_surface` grew a check, and `tests/self_test.sh` grew
  breakage 83.** A service that sets any of the three on kit's `postgres` is now
  a finding, in the same family as the `otel-collector` `volumes:`/`command:`
  rule — a service reaching into a boundary that belongs to the whole fleet.
  Self-test breakage count 82 → 83.

- **The false-positive analysis is written down in the check, because a check
  that cries wolf gets deleted.** The rule fires only on an entry with **no
  `image:` and no `build:`**, so a service shipping its own postgres under kit's
  service name stays `check_stale_copy`'s finding alone — one defect, one
  finding. It keys on the CLUSTER service name (derived from
  `KIT_POSTGRES_DATABASES`, not written down as `"postgres"`), so a service
  setting `POSTGRES_DB` on its **own** service — the ordinary connection-string
  case — is untouched, and every existing self-test fixture is that green
  control without a new one. `env_file:` is deliberately not read: `.env` is
  git-ignored, and every legitimate way of setting any of the three is the
  `KIT_POSTGRES_*` variable, which never appears as a `POSTGRES_*` key in a
  service's compose file.

- **Found in the fleet for real, by a worker doing an unrelated migration.**
  `identity` carried precisely the override kit recommended. On re-measurement
  it is not the only one: **`billing` and `courier` carry it too**, and all
  three have a `kit.ref`, so this check turns three repositories from green to
  FAIL against a standard they have already adopted. That is the check working,
  not a regression — but it is a real change in what the fleet gate reports, and
  it is called out here rather than discovered by whoever runs the gate next.

- **`REPORT-kit-13.md` is left as it was.** Its line 95 is a verbatim copy of the
  output as it was printed, and a dated report is a record of what a packet did.
  Rewriting it would make the history lie about itself.

### Added — `image.reusable.yml`: the fleet's images are now built by something

**Nothing in the fleet built the image its deploy config names.** Every
deployable service has a `config/deploy.yml` saying `image: <org>/<repo>` with
`registry.server: ghcr.io`, and as of kit-32 not one repository had a workflow, a
Makefile target or a script that produced that artifact. `config/deploy.yml` was
a description of a deploy whose input had no pipeline behind it, so
`kamal build push` on an operator's laptop was the only way the image came to
exist — one machine, one person, no record of which commit it was built from.

The new `.github/workflows/image.reusable.yml` is called rather than copied, for
the same reason `ci.reusable.yml` is:

```yaml
# .github/workflows/publish.yml, in a service repository
on:
  push:
    branches: [master]
permissions:
  contents: read
  packages: write        # the caller's to grant — a reusable workflow cannot
jobs:                    # grant itself a permission
  image:
    uses: cafaye/kit/.github/workflows/image.reusable.yml@master
    with:
      push: true
```

Five decisions in it, each of which is a decision somebody could get wrong in a
way that still produces a green run:

- **GitHub Packages, with `GITHUB_TOKEN` as the only credential.** No PAT, no
  `secrets:` entry, no registry account, nothing to rotate. The caller grants
  `packages: write`; without it the push fails 401, which reads like a wrong
  password rather than a missing grant, so the header says so at the example.
- **`push` defaults to `false`.** Publishing is opt-in at the call site. A
  reusable workflow that pushed by default would publish from every caller that
  only meant to check a Dockerfile still builds.
- **The image name is DERIVED — `ghcr.io/${{ github.repository }}`,
  lowercased — and is not an input.** An input is a string each service copies
  into its own repository, and a copied string drifts from the repository it
  names; CI would push to one place while `kamal` pulled from another and the
  deploy would fail hours later on a release whose build was green. The
  lowercasing is a real step rather than a comment, because GitHub Packages
  404s an uppercase path and says so by naming a package.
- **Tags are `sha-<full 40>`, `<branch>`, and `latest`; no semver.** The sha tag
  is immutable, so a deploy that names it means it. A semver tag here would let
  a release pin `v1.0.0` to whichever commit happened to be on master that week.
- **`provenance: mode=max` and `sbom: true`**, costing two referrers, because a
  registry of launch artifacts with no recorded provenance cannot be audited
  after the fact and adding it later means it was never there.

The build also refuses to publish from a `pull_request` even if a caller adds
that trigger — the condition is `inputs.push && github.event_name !=
'pull_request'`, which is the fork that `GITHUB_TOKEN` cannot write to anyway,
refused before the attempt rather than after it.

### Fixed — the copy check was a freeze, and a second standard made it say so

Adding the workflow above made kit's own `callable_check` go **red**, reporting
`a second workflow declaring workflow_call exists` — naming, as drift, a second
*standard* added on purpose. The rule it enforced was "exactly one file in the
tree may declare `workflow_call`", which is not a drift check. It is a freeze,
and following it would mean kit could never grow past one standard no matter how
many the fleet needed.

It is now: files at paths declared in a new `REUSABLE_WORKFLOWS` variable are
exempt, and every other file is judged on its **parsed `name:`**, with the two
failures reported as the two different mistakes they are —

- same `name:` as a declared standard → a **copy** parked where no caller can
  reach it, which is the original defect and is still the failure the walk
  exists to catch;
- a different `name:` → an **undeclared standard**, a callable workflow kit ships
  without listing, which is this packet's own bug class one file over.

Declaring the second path also asserted, for the first time, that every path in
the list exists and is callable — otherwise widening the list would have exempted
a path with no file behind it, quietly weakening the check it was added to
police.

**Both new branches are proved by breakage** (78 and 79), because a widened
check is a check that may have been widened into uselessness and the only way to
know is to break it in both directions it now claims to cover. Breakage 78 is
the original defect and 79 is the one the widening made possible; a check that
had been reporting a defect that did not exist and now reports nothing at all is
a plausible sentence, and as far as anyone would know an accurate one.

### Fixed — the shared cluster worked for exactly one tenant, and the identifier rule was half a rule

Both of these were found by **running a second tenant**, which is the operation
"one Postgres cluster for the whole fleet, a database and a role per service" is
actually made of. Everything kit had checked about the cluster was true of the
first service and untested for the second — and the second is the case that makes
the shared cluster worth having.

**1. Two tenants separated by a space became one database, and the stack said it worked.**

```console
$ KIT_POSTGRES_DATABASES="billing neighbour" bin/dev up
postgres-1 | [cluster] provisioning billingneighbour
postgres-1 | [cluster] done: 1 service database(s), one role each, PUBLIC holds CONNECT on none of them
```

One database, named after both services fused together, on a healthy-looking
stack. The parse split on commas and then ran `tr -d '[:space:]'` over each
entry to tolerate `billing, neighbour`, so a space *instead of* a comma arrived
at `require_identifier` with the space already deleted — a perfectly legal
identifier.

That is why nothing caught it. `require_identifier`'s own comment names this as
the failure worth preventing — *"builds one identifier out of two tokens"* — but
the only route to that outcome produced an **identifer that passed validation**,
and every check in kit was looking at a single name. The fused database exists,
the second service's migrations then fail against a database nobody created, and
the service that does have one reports clean.

Outer whitespace is now trimmed and inner whitespace is refused by name, with the
separator that was probably meant.

**2. `require_identifier` was enforcing about half of what its error message said.**

The rule is built entirely from shell bracket ranges — `[!a-z_]`,
`[![:a-z0-9_]]` — and those follow **collation**, which is locale-dependent.
Under `en_US.UTF-8`, the default on the machine this fleet is developed on,
collation is case-insensitive at the primary level, so `[!a-z]` does not match
`B`. Measured, same pattern, two locales:

```console
$ LC_ALL=C          bash -c 'case Billing in [!a-z_]*) echo REFUSE;; *) echo ACCEPT;; esac'
REFUSE
$ LC_ALL=en_US.UTF-8 bash -c '…'
ACCEPT
```

So `Billing`, `BILLING` and `cafayé` were all accepted while the error string
promised `must match [a-z_][a-z0-9_]*`.

This is **not** injection: the characters that would break out of an unquoted
identifier still sort outside `[a-z]` and were refused under either locale. It is
a quieter failure with a worse shape. Postgres folds unquoted identifiers to lower
case, so `KIT_POSTGRES_DATABASES=Billing` and `…=billing` name **the same
database** — two services differing only in case would share one database and one
role, which is exactly the harm `require_identifier`'s message says it exists to
prevent, arriving by the one route that yields a legal-looking name.

`10-cluster.sh` now exports `LC_ALL=C`. That is the whole fix rather than
rewriting the pattern with `[[:lower:]]`, because the locale also governs `tr`,
`sort` and `printf` further down, and a provisioning script that compares strings
differently depending on whose laptop ran it is not deterministic in any sense
that matters.

**What now checks both.** `tests/multi_tenant_split_test.sh` is kit's first check
that asks what a *second* tenant does. It runs the shipped init script with
`psql` stubbed — the real parse, the real refusals, no container and no volume —
and covers 28 cases: the fused-name refusal, the four legitimate comma-separated
spellings people actually write, empty and trailing entries, `require_identifier`
still refusing what it refused before, and the identifier rule re-checked under
`C`, `en_US.UTF-8`, `en_GB.UTF-8` and `POSIX` with a legal name alongside each so
the fix cannot pass by refusing everything. Breakage 88 reverts the parse and
watches it go red.

The honest summary of why these survived: **every proof kit held about the
cluster was a proof about the first tenant.** A fleet of nine services is nine
repetitions of a case nobody had run twice.

### Fixed — the shared cluster provisioned nothing, and reported itself healthy

Two defects, and the reason they survived is the same one: each was invisible to
every check kit had, and together they meant **no service in this fleet has ever
had a database on the shared cluster.** Both are fixed here, both are now
checked, and the checks are derived from the files rather than from a list.

**1. `docker-entrypoint-initdb.d` was mounted from an empty directory, always.**
`templates/compose/docker-compose.yml` mounted the init scripts as
`./postgres/initdb`, and `bin/dev` runs compose with `--project-directory .` — the
**service** root. Docker Compose resolves a relative bind source and build context
against the *project directory*, not against the directory holding the compose
file, so `./postgres/initdb` meant `<service>/postgres/initdb`. No service has
that directory. Docker's answer to a missing bind source is to **create it as an
empty directory**, so there was no error to see.

Measured, on `identity`, before this fix:

    $ docker exec cafaye-postgres-1 ls /docker-entrypoint-initdb.d/
    (nothing)
    $ docker exec cafaye-postgres-1 psql -U cafaye -d postgres \
        -tAc "select rolname,rolsuper from pg_roles where rolname not like 'pg\_%'"
    cafaye|t
    $ docker compose up -d --wait postgres ; echo $?
    0        # and the container reports HEALTHY

`10-cluster.sh` never ran. No service got a role, no service got a database, no
`REVOKE CONNECT ... FROM PUBLIC` was ever applied — and the stack came up green,
which is the one outcome a provisioning contract must never produce. The same
wall was hit independently by the courier-27 worker, who worked around it rather
than patching the stack it fetches.

The fix is the one the other five services in that file already use:
`${KIT_COMPOSE_DIR:-.}/postgres`, which `bin/dev` exports
(`templates/bin/dev.sh:652`). After it, the same command shows `identity|f|50`
and a database named `identity`, created by the script, with no override file and
no manual SQL.

**2. `.env.example` named one service as the whole fleet's default tenant.**
`KIT_POSTGRES_DATABASES` defaulted to `courier` in the compose file *and* in
`.env.example`, and `bin/dev` copies `.env.example` verbatim into each service's
git-ignored `.env` — which Compose resolves **ahead of** a service's own
committed `docker-compose.yml`. So the literal did not act as a default; it
**cancelled** every adopting service's own declaration, on every machine where
`bin/dev` had run, with nothing in any diff. Measured on `identity`: its compose
file said `${KIT_POSTGRES_DATABASES:-identity}`, the copied `.env` said
`courier`, and the cluster provisioned `courier`.

The same mechanism made a *second* committed value inert in the same run.
`identity`'s compose file raised `KIT_POSTGRES_ROLE_CONNECTIONS` to 50; the
copied `.env` said 10; `pg_roles.rolconnlimit` was 10; and **175 tests failed**
with `FATAL: too many connections for role "identity"` — a failure caused
entirely by a value the repository had already raised, reviewed and merged. Both
variables are now empty in `.env.example`, and the rule is written out there: *a
value in this file defeats a service's committed compose file.*

`KIT_POSTGRES_DATABASES` in the compose file loses its `:-courier` fallback
entirely rather than gaining an empty one, and the reason is measured rather than
preferred. An empty default is the obvious repair and it is wrong: bringing the
template up with it produces, from `10-cluster.sh:48`,

    KIT_POSTGRES_DATABASES: KIT_POSTGRES_DATABASES is unset. Name the services,
    comma-separated. A service with no entry has no database, and its migrations
    fail against a database that was never created.

and a container that exits 1. That failure is the *correct* one — far better than
the default it replaces, which handed a real service's database to whoever
adopted the template — so the list stays required, compose passes it through
unset, and a service that forgot to declare itself gets that message instead of
somebody else's rows.

**What now fails if either comes back.** Three rules, all derived from the files:

- *No host path in `docker-compose.yml` may be bare-relative.* The pre-existing
  guard listed five vendor configs by name, which is why it missed the postgres
  service's two paths — a check over a list only ever says something about the
  list. This one reads the file, so an eighth service cannot escape it.
- *No tenant as a shared default.* `KIT_POSTGRES_DATABASES` holds service names,
  so a non-empty fallback in a template nine services fetch is a hardcoded
  tenant. The rule does **not** extend to `KIT_POSTGRES_ROLE_CONNECTIONS`:
  `10` is a blast-radius default, not a tenant, and conflating the two would
  have had the check demanding the cluster stop having a connection limit.
- *An empty value must be CAUGHT, not merely absent.* Emptiness with no fallback
  is a silent breakage; emptiness the init script refuses by name is a loud one
  naming the fix. The rule checks for the guard in `10-cluster.sh` rather than
  trusting a comment asserting it exists.

Two of these three caught their own author. The `.env.example` rule rejected the
empty `KIT_POSTGRES_DATABASES` default described above, which is why that default
is gone rather than shipped; and the first version of the tenant rule failed on
the *comment* documenting the old value, because it scanned raw text and could
not tell a sentence about a value from the value. Comments are stripped before
both scans now.

The connection-budget check was reading `KIT_POSTGRES_DATABASES` and
`KIT_POSTGRES_ROLE_CONNECTIONS` out of `.env.example`, which no longer carries
them, so it began describing a cluster that cannot exist. It now resolves each
value through the chain the container actually sees — `.env.example`, then the
compose `:-` fallback, then the init script's own — and, with no tenant declared
by default, asserts the budget against the nine services this template's prose
claims to serve (`9 × 10 + 8 = 98 ≤ 200`) rather than against `0 × 10 + 8`, which
is true of every number ever written and so proves nothing.

### Fixed — `self_test_claims` was reporting six findings on an unrenumbered comment

`tests/self_test.sh` has a check (`self_test_claims`, run by the gate) that
cross-checks the file's **header** — every breakage it documents — against the
**recipes** it actually carries, and fails when either side names a number the
other does not. On `master` it was reporting six findings, in both directions:

```
header documents breakage 63 but no recipe carries it
header documents breakage 64 but no recipe carries it
header documents breakage 65 but no recipe carries it
recipe proves breakage 78 but the header does not document it
recipe proves breakage 79 but the header does not document it
recipe proves breakage 80 but the header does not document it
recipe proves breakage 81 but the header does not document it
recipe proves breakage 82 but the header does not document it
```

One comment caused all of it. The Kamal block in the header was written as
`61-65`; its five recipes were renumbered to `78-82` by `4a037f3` — whose own
body note records the collision that forced the move — and the header was not
carried along. The reason this was not a tidy-up but a real defect is that
**61 and 62 were reused**: by that point they belonged to the licence
breakages, which genuinely exist. So the header was describing two different
sets of proofs under the same two numbers, and the integrity check was
reporting the disagreement rather than causing it.

The header block is renumbered to `78-82` and its prose follows its recipes.
`self_test_claims` now reports agreement. Worth recording for the next person
who renumbers anything in that file: the header is not documentation, it is
**input to a check**, and the check is the only thing standing between a
renumbered recipe and a set of proofs the file claims but does not run.

### Fixed — a check that guarded the initdb mount was reading a comment about it

This is a regression *introduced by the fix above*, found by that fix's own
proof, and it is recorded because a check that cannot fail is worse than a
missing check: it is a check that reports success.

`cluster_topology_check` asserts that the postgres service mounts anything at
`/docker-entrypoint-initdb.d`, and it did so with `if "<path>" not in block`
over the raw YAML text of the service. Correct when the only mention of that
path was the mount. The fix above adds a comment explaining why the mount must
be `${KIT_COMPOSE_DIR:-.}/postgres/initdb` rather than `./postgres/initdb`, and
that comment quotes the path.

Measured, on this tree, with the mount deleted and nothing else changed:

| | `/docker-entrypoint-initdb.d` occurrences in the postgres block |
|---|---|
| before the fix | 1 — the mount |
| after the fix | 2 — the mount, and the comment about the mount |

So deleting the mount left the comment, `in` returned true, and
`cluster_topology_check` went **green**. Deleting the same line from `origin/master`
turns it red, which is how the difference was isolated to this change rather than
to the check having always been broken.

This is the third time in this release that a check scanning YAML text has
matched a sentence about a value instead of the value — the other two being the
`.env.example` tenant rule and the connection-budget scan. All three are now the
same shape, and the general statement is the one worth keeping: **a check that
reads compose text to decide whether something is wired can be satisfied by a
comment saying it is wired.** `cluster_topology_check` now strips comment lines
before both of its assertions — the mount, and the set of `KIT_POSTGRES_*` the
service passes into the container — so a well-commented file no longer passes for
a well-wired one. The durable fix is to parse the YAML rather than scan it; that
is not in this release, and until it lands every text-scanning check in this file
carries the same hazard.

### Fixed — a comment inside an unquoted heredoc ran as a command, and the gate stayed green

Also a regression *introduced by the fix above*, and the second one in this
release to be found by being wrong in the same place: the first was a check
reading a comment, this one is a comment being read by a shell.

`tests/stack_live_test.sh` writes its fixture `.env` with
`cat >"$SERVICE/.env" <<ENV`. The delimiter is unquoted **on purpose** —
`$REMOTE`, `$WORK` and the port arithmetic all have to expand. The price of that
is that the heredoc body is a shell script, and the fix above's explanation of
why `tests/stack_live_test.sh` now has to declare a tenant was written *inside*
it, with backticks around the filenames.

So bash ran every backticked word as a command. The first run after that edit
printed:

```
tests/stack_live_test.sh: line 227: docker-compose.yml: command not found
tests/stack_live_test.sh: line 227: KIT_POSTGRES_DATABASES: command not found
tests/stack_live_test.sh: line 227: bin/dev: No such file or directory
tests/stack_live_test.sh: line 227: kit_probe: command not found
```

…and then **exited 0 with all fifteen assertions PASS**, including "the fetched
stack came up healthy". `KIT_POSTGRES_DATABASES=kit_probe` had been swallowed
into a command substitution and never reached the `.env` at all, so the line
every other assertion was relying on was not there.

This is the fourth comment-as-data failure in this release and the first one
where the comment *did something* rather than merely satisfying a substring test.
The general statement is now sharper than the one recorded above: **prose
written into a construct that expands is not prose.** The fix is placement, not
wording — the explanation moved above the `<<ENV`, where it cannot execute, and
the heredoc body is nothing but assignments. The general rule for every heredoc
in this repository is that a comment explaining one belongs *outside* it.

### Fixed — the live stack test caught a regression that 214 static checks and 86 proofs passed

Removing the `:-` fallback from `KIT_POSTGRES_DATABASES` — which is the whole
point of entry 1 above, and which breakages 85 and 86 exist to insist on — broke
`tests/stack_live_test.sh`, which had never declared a tenant because for its
whole life the fallback had been doing it for them.

Nothing noticed. The static gate ran 214 checks and the self-test ran 86
breakage proofs, and every one of them was green, because every one of them
reads the template or a service's committed files — and kit's own test harnesses
are none of those. The live test was the only thing that brought the cluster up,
and it said so in ten minutes and eight containers:

```
/docker-entrypoint-initdb.d/10-cluster.sh: line 48: KIT_POSTGRES_DATABASES:
KIT_POSTGRES_DATABASES is unset. Name the services, comma-separated.
bin/dev: stack did not become healthy
```

The init script was right and the harness was wrong, and the reason is worth
stating because it is the general shape of this bug: **kit's own harness
consuming kit's own template looks exactly like "the template broke."** A test
that is also a consumer cannot tell the difference from the inside.

Three things landed here.

**A static check, so it costs a second and not ten minutes.** Every file under
`tests/` that writes a `.env` carrying a `KIT_` variable must declare a tenant in
the same heredoc body — derived from the files, so a harness written tomorrow is
covered the day it is written. It reads the heredoc body rather than the file,
because an assignment outside the heredoc does not reach the `.env` either, and
it matches an assignment at the start of a line with a value rather than the
substring `KIT_POSTGRES_DATABASES`, because this file's own `.env.example`
mentions that name in prose and the comment above the heredoc mentions it too.
Breakage 87 is its red proof. It exits 1 if no harness is found at all, so it
cannot pass by finding nothing.

**Three live assertions, so the file now proves the cluster was provisioned.**
`stack_live_test.sh` previously asserted that eight containers came up healthy
and telemetry flowed — and an empty `/docker-entrypoint-initdb.d` produces
exactly that. It now asks the running server: that database `kit_probe` exists
and is owned by role `kit_probe`, that the role exists and is **not** a
superuser, and that `datacl` grants `PUBLIC` nothing. That last one is read by
its empty-grantee shape (`=c/cafaye`) rather than by a search for the word
`PUBLIC`, which appears in no `datacl` at all, and a NULL `datacl` is a failure
rather than a skip because NULL means Postgres's defaults still stand — and the
default is CONNECT to PUBLIC. Red proof: dropping the database and the role from
the running container turns all three red, which is the state an empty initdb
directory produces. It deliberately does not assert the cross-tenant refusal;
`tests/isolation_test.sh` owns that claim and owns it better, and a second
weaker copy of a fact that already has a home helps nobody.

**A general note.** The lesson is not "write more static checks." It is that a
repository has consumers nobody enumerated — its own test harnesses among them —
and a template that got stricter moved the burden onto all of them at once. The
static gate was green because nothing in it looked at the thing that broke.

### Fixed — the postgres accessory no longer publishes its port on every interface

- **`templates/kamal/deploy.yml.erb` — one line deleted, and what replaces it is a
  comment that says why.** The postgres accessory carried `port: 5432`, which is
  valid YAML and which `kamal config` accepts and exits 0 — the two strongest false
  greens available. Kamal expands it (`Configuration::Accessory#port` returns
  `"#{port}:#{port}"` when the value carries no colon) and hands it to
  `docker run --publish` (`Commands::Accessory#publish_args`), and Docker's
  `--publish HOST:CONTAINER` with no host address binds `0.0.0.0` and `::`.

  **Measured, on a real Kamal 2.12.0 boot, not inferred:** a boot with the line
  present fails with
  `Bind for 0.0.0.0:5432 failed: port is already allocated`
  when something else holds 5432 — which is Docker naming the bind it is about to
  make. On a VPS where 5432 is free it succeeds, and the database is on every
  interface the host has. kit does not ship a firewall, and the only thing between
  that and the internet is one the operator wrote.

- **The loopback alternative is not the fix, and the comment says so, because it
  is the obvious answer and it does not work.** `port: "127.0.0.1:5432:5432"`
  really does bind only that host — measured, `docker ps` shows
  `127.0.0.1:5432->5432/tcp` and nothing on `::`. But the application is not on
  the host's loopback: it is a container on the `kamal` Docker network, where
  `127.0.0.1` is its own. Measured, from a container on that network:
  `pg_isready -h 127.0.0.1 -p 5432` gets **no response**, while
  `pg_isready -h <service>-postgres -p 5432` **answers**. So the loopback bind
  reduces the exposure, does not make the application work, and the only thing it
  buys is a `psql` on the box itself.

- **What the application uses instead, measured rather than argued.** Kamal boots
  the accessory with `--network kamal` and `--name <service_name>`, Docker's
  embedded DNS resolves that name, and the app reaches the database at
  `<service>-postgres:5432`. Measured from **inside a deployed app container**
  with this template and no `port:` line: `pg_isready -h <service>-postgres -p
  5432` → `accepting connections`, and `docker ps` for the accessory shows
  `5432/tcp` with no host binding at all.

  **`DATABASE_URL` must therefore name the container, not the server.** That is
  the one migration this costs, and it is a one-line change per service in a file
  that is already a secret and already per-service. The fleet's own probe URLs
  already use the container-name form, which is independent evidence that
  name-based access is the intended shape.

- **`tests/kamal_test.sh` — two new cases, and one of them is a control.** The
  first asserts that the **resolved** accessories block (read back from the real
  `kamal config`, not grepped out of the template) carries no `port:`. The second
  plants the line it forbids and asserts the same check catches it, because a grep
  that finds nothing because it read nothing is the failure mode a negative test
  has by construction.

  Both were needed more than expected. The first version of the block-extraction
  was `sed -n '/^:accessories:/,/^[^-:]/p'`, which stops on `  postgres:` the
  very next line — `p` is neither `-` nor `:` — so it read a two-line document and
  the case passed for the wrong reason; the control caught it, which is what a
  control is for.

### Added — Kamal deploy and backup configuration, and the custom toolchain removed

- **`templates/kamal/` — the deploy and backup configuration a service copies,
  in the shape `kamal` and `kamal-backup` already expect.** Four files:
  `deploy.yml.erb`, `kamal-backup.yml.erb`, `drill.sh`, and a README.

  kit does not ship a deployment tool or a backup tool. `kamal` and
  `kamal-backup` are both, both are installed wherever cafaye deploys, and
  kit-20 demonstrated the cost of the alternative by building one: **3,012 lines
  across seven files** — the four in `templates/backup/`, plus
  `templates/bin/backup.sh`, `docker/Dockerfile.backup` and
  `tests/backup_test.sh` — reimplementing a command surface that already
  existed. 1,411 of those were shipped code and configuration. Every one of those
  files is **removed**, and
  `tests/validate.sh` asserts their absence — "we removed it" has no mechanical
  form until something checks, and self_test breakage 64 resurrects one file to
  prove that check is load-bearing.

  What each custom feature maps to, and where it went:

  | custom | kamal-backup | 
  |---|---|
  | `pg_dump` piped into `restic backup` | `backup` |
  | `schedule.crontab` | `backup.schedule: 1d` — state in a volume, so a reboot does not trigger a full dump |
  | retention flags by hand | `restic.retention` |
  | `restic init` if absent | `restic.init_if_missing` |
  | `redact.py` wrapped around every command | the gem's own `Redactor`, applied to every command including the drill's check output |
  | a hand-written restore path | `restore production`, `restore local` |
  | a hand-written drill | `drill production` |
  | a hand-written redacted report | `evidence` |

- **`config/kamal-backup.yml` names ONE database, and says why.** The queue,
  cache and cable databases are rebuildable working data; backing them up
  snapshots caches and job bookkeeping. The restore is the product: one database
  means one restore path and one row count an operator can check by eye.

- **`drill.sh` — the two things kamal-backup does not do, both found by reading
  the gem rather than by using it.** `restore_to_scratch`
  (`databases/base.rb:52-55`) validates, restores, and does **not drop the
  scratch database** — the only `DROP SCHEMA` in the gem runs against the *live*
  database — so cleanup is an operator's job, and a step remembered after a
  failure is a step that does not happen after a failure. And the gem decides the
  drill passed by the **exit status** of `--check` (`app.rb:307-325`), which
  makes `psql -tAc "SELECT count(*) FROM t"` useless: it exits 0 for zero rows, so
  a restore of an empty database is reported as a successful drill. The wrapper
  therefore drops the scratch database on every exit path with `WITH (FORCE)`, and
  generates a `DO $$ … RAISE EXCEPTION` block under `ON_ERROR_STOP=1` so an empty
  table becomes a non-zero exit. There is no default table list — a drill with no
  `--table` is a usage error rather than a drill that quietly passes.

- **`tests/kamal_test.sh` — the gate EXECUTES the generated config.** 22 cases,
  every one against the **real** `kamal` and the real `kamal-backup`. This is the
  one place kit hands out YAML a third-party binary has to accept, and a parse
  check cannot do the job: three real defects in these templates' own first draft
  were valid YAML that `yaml.safe_load` called fine —

  - a doubled registry host. `image: ghcr.io/org/repo` with
    `registry.server: ghcr.io` resolves to `ghcr.io/ghcr.io/org/repo` (measured:
    `kamal config` reports it), and `kamal config` still exits **0**. The deploy
    fails at the push.
  - a missing `builder.arch`. Valid YAML; kamal refuses the file outright with
    "Builder arch not set".
  - a secret named in `config/kamal-backup.yml` and missing from the backup
    accessory's `env.secret`. **Both files are valid and neither is internally
    inconsistent** — `kamal-backup validate` builds the accessory's environment
    from the deploy config alone, so only running the pair finds it.

  self_test breakages 61, 62 and 65 are those three, inverted.

- **Retention is written out rather than inherited.** kamal-backup 0.5.2's
  `DEFAULT_RETENTION` happens to be exactly the five numbers the template states,
  so omitting the block would work today. A retention policy living in a
  dependency's defaults is a policy that changes on a version bump, and the diff
  at that moment is about the gem rather than about how far back a restore can
  reach.

- **A missing `KIT_*` variable fails the render by name.** `<%= ENV['X'] %>` with
  `X` unset renders an empty string, which YAML reads as a null list item and
  which surfaces three layers away as a deploy that cannot find a host. The
  templates `raise` and name the variable instead.

### Changed

- **`templates/kamal/README.md` answers the Ruby question explicitly, because it
  is a boundary and not a caveat.** The service image contains no Ruby. The backup
  accessory **ships its own**, which is why the `backup` block in `deploy.yml.erb`
  is an ordinary accessory. `kamal` is a Ruby gem and always has been — an
  operator deploying with Kamal has Ruby, and that is not a requirement kit adds.
  A service that wants backups and no `kamal-backup` gem locally **still gets
  backups**, because the accessory's scheduler loop is what takes snapshots; what
  it loses is `restore local` and `drill local`, not the backups. ERB costs
  nothing extra because Kamal evaluates `config/deploy.yml` through
  `ERB#result` itself.

### Fixed

- **four self-test recipes asserted a string the check does not emit.** All four
  were *correct checks* on *correct mutations* whose recipe could not tell either
  from a failure, and all four reported "the gate went red, but NOT via …" —
  three of them while printing the needle two lines above the complaint.

  `expect_red_check` matches `FAIL $want`, so the needle has to be the check's
  **label**. Breakages 75, 76 and 77 asserted the finding's own wording
  (`"which is the image kit's stack already ships"`, `"promises a command the
  script does not dispatch"`), and those strings are printed as indented detail
  lines *under* the `FAIL <label>` header. Breakage 71 asserted
  `the connection budget  (max_connections covers` against a label that read
  `max_connions` — a misspelling of a setting that does not exist, in the one line
  a reader greps for to learn what a check measures.

  Two consequences beyond the four recipes. The `max_connions` label is corrected
  to `max_connections`, which is the variable the check reads. And a check label
  that a self-test asserts is now a **contract**: renaming one silently un-proofs
  the breakage, which is the same coupling as the `callable path` check and is now
  written down in `AGENTS.md` with the diagnostic to use next time — read the real
  FAIL line before assuming the check missed the defect.

- **the connection-contract check was satisfied by a comment.** It tested
  `if key not in body` over the whole snippet, and the go snippet's header says
  "1. `application_name` — THE ONE THAT IS NOT OPTIONAL". So deleting the single
  line that *sets* it left the substring in the file and the contract reported
  satisfied — and **self-test breakage 72, which performs exactly that deletion,
  was green.** This is the rule AGENTS.md already states about `-count=1` ("a
  check that a comment can satisfy is not a check") arriving in a new place, and
  the only reason it is written down here is that the self-test could not see it:
  the mutation was real, the recipe ran, and the check agreed with the tree.

  All three of the check's tests now read code with the comments stripped, per
  language — `//` for go/node/rust, `#` for python, and for elixir a `#` that is
  **not** `#{`, because interpolation is code and can carry a setting. The
  stripper does not track string literals, which is deliberate and conservative:
  a comment marker inside a string leaves its line scanned rather than eating the
  code after it, so the failure this can cause is a missed setting, never a
  setting wrongly reported absent.

  Fixing it also corrected `contract.json`'s bounded-pool token: it listed
  `:pool_size`, a spelling that existed only in the Elixir snippet's *prose*,
  while the code says `pool_size: @pool_size`. Once the comments stopped
  counting, the token read as absent and named a real defect in the token list.

- **`self_test.sh` classified a caught defect as a machine failure, on a large
  gate report.** The `env_skips` branch added in `1d98e42` tested for a finding
  with `printf '%s\n' "$out" | grep -qE '^(FAIL|SKIP)'` — while the verdict three
  lines above it had been changed to the non-piping `contains` for exactly this
  reason. **The fix was applied to one branch and missed in the one beside it.**

  The mechanism, measured: on a 239KB gate report whose findings sit at the top,
  that pipeline exits **141** *with the match present*. `grep -q` closes the pipe
  on its first match, `printf` dies of SIGPIPE, and `set -o pipefail` promotes 141
  to the pipeline's status — so the verdict flipped on the SIZE of the output
  rather than on what was in it. The threshold is a property of the pipe buffer,
  so it moves with the machine.

  And it fails in the worst direction available: the false answer is "this is an
  ENVIRONMENT failure", which is precisely the verdict that excuse was added to
  stop being lost. Four breakages — 71, and the three this packet adds (75, 76,
  77) — were reported as unevaluated on a run where every one of them had in fact
  been caught, and 72 was reported as "the gate stayed GREEN". Now a `contains`
  call, like its neighbours.

- **`fleet_check.py` no longer reported a clean fleet while five repositories
  carried their own Postgres.** `check_stale_copy` — failure mode 1, the check
  whose entire job is naming a service running its own copy of the shared
  platform — matched a service's image against kit's by **bare repository
  name**. kit-21 made the cluster a *built* image (MD21b), so kit's went from
  `postgres:${KIT_POSTGRES_TAG:-…}` to `kit-postgres:${…}`; a duplicating service
  still writes `postgres`, and the two stopped matching. Measured on the commit
  that shipped it:

  ```console
  $ fleet_check.py --repos-dir <a fleet whose alpha runs postgres:17>
  PASS fleet: no service carries a copy of kit's stack, none weakens the
               redaction boundary, no collector config is dead, …
  ```

  The comparison is now over the **upstream** image kit's stack is built *from*,
  not over the name of the local artefact kit built it into — a service cannot
  know to write `kit-postgres`, which is a build tag that exists on one
  developer's machine.

  It went unnoticed for a reason worth recording, because it is the same shape as
  the bug: self-test breakages 52/59/60 mutate a fixture to carry a stale copy
  **with a `ports:` entry**, and `check_override_surface` reports a published
  port by *service name* — a name the rename never touched. So breakage 60 went
  red on the port half while the image half was dead, and a green control was
  evidencing a different check. New **breakage 75** mutates the same fixture
  *without* the port, so the image comparison is the only thing that can go red;
  it is red on the pre-fix code and green on the post-fix code, both measured.

- **`bin/dev db grant` now exists.** Four files in this repository told a service
  author to run it — `templates/database/README.md`, `DECISIONS.md`,
  `templates/compose/postgres/initdb/10-cluster.sh` and
  `templates/compose/docker-compose.yml` — and `bin/dev` had no `db` command at
  all. Every one of those four is a reader who is told the way out of "my
  service's database was never created" exists, runs it, and gets
  `unknown command`. `DECISIONS.md` was created to stop this repository
  referencing a document that did not exist; this was the same defect one layer
  down, and it is now a check (**breakages 76 and 77**) rather than a fix, since
  the class is "a document names an interface and the interface disagrees".

  The command **prints** the statements and does not run them: they are
  `CREATE ROLE` and `CREATE DATABASE` on a cluster a service is about to be
  handed credentials for, and a wrapper whose failure mode is half-provisioned is
  not something to perform on a stack it did not start. It prints the
  `REVOKE ALL ON DATABASE … FROM PUBLIC` with them, which is the whole point —
  see the next entry.

- **the operator-side half of the isolation boundary is now stated rather than
  implied.** `DECISIONS.md` listed "the `REVOKE` for a database added by hand"
  among the things left to the operator, in one line, as a pointer to a command
  that did not exist. It now says what the position actually is: the boundary
  holds **by construction** for every database declared in
  `KIT_POSTGRES_DATABASES` on a fresh volume, and a database added afterwards is
  **the operator's to close** — because `docker-entrypoint-initdb.d` runs once per
  volume and cannot sweep a database that does not exist yet. A database created
  by hand and not revoked is reachable by every role in the cluster, whatever the
  table grants say. `tests/isolation_test.sh` proves the first half against a real
  cluster; the second is a documented step, and the document now says so where an
  adopter will read it.

### Changed

- **`templates/deploy/compose.deploy.yml`'s comment claimed its Postgres was "the
  same tag `templates/compose/docker-compose.yml` uses", so "a deploy and a
  `bin/dev up` are running the same database."** Both halves became false at
  kit-21: the dev stack moved to `postgres:17` because pgvector is a glibc-linked
  layer (MD21b), and the developer topology became one cluster of N databases
  rather than one database. The tag is unchanged and the deploy file is
  deliberately a *different* topology — one database for one service, with no
  initdb script, no per-service roles and no revoke, because there is nothing to
  isolate it from. The comment now says that, so the two are not "unified" by a
  reader in a hurry.

### Added

- **one Postgres cluster, one database and one role per service, and the database
  is the isolation boundary.** Nine services, one cluster, no pooler. A service
  adds its own name to `KIT_POSTGRES_DATABASES` and gets a role, a database and a
  refused-at-the-door boundary — there is no second container, no second port and
  no second volume, which is the entire point of sharing a cluster.

  `templates/compose/postgres/initdb/10-cluster.sh` provisions one non-superuser
  role and one owned database per name, then applies the boundary by **sweeping
  `REVOKE ALL ON DATABASE … FROM PUBLIC` over every non-template database** in
  the cluster rather than over a list of the ones it created. Measured, and this
  is the load-bearing part: with the revoke, `psql -U courier -d billing` answers
  `FATAL: permission denied for database "billing"` / `DETAIL: User does not have
  CONNECT privilege` before a query is parsed; without it, the connection
  **succeeds** and only the `SELECT` on billing's table is refused — by the
  accident that nobody granted it. A cluster provisioned without the revoke has,
  by Postgres's default, no isolation at all, and fails open silently.

- **`tests/isolation_test.sh` — the proof, not the claim.** Brings the *shipped*
  stack up through compose, creates two service databases and two service roles,
  and asserts service A cannot reach service B's, printing the refused query and
  the server's answer. Four assertions: A reaches its own; A is refused B's; B is
  refused A's (one lucky direction is not isolation); and a **control cluster of
  the same shape with the revoke removed must let A in**.

  The control is the assertion that makes the rest mean anything, and it is
  there because of the rule this repository already applies to allowlists and
  proofs: an assertion that cannot be shown to fail is not known to be
  load-bearing. Without it, a check asserting "A cannot SELECT from B's rows"
  would pass on a cluster with no isolation at all. Wired into the gate's
  observability phase with its own `BOUND` bound (1800s — three container
  lifecycles and two initdb runs), and a loud SKIP when docker is absent.

- **`templates/database/` — the connection contract, published and consumed.** The
  topology is only finished if a service's config actually works against it, so
  the four settings that only matter on a shared cluster are generated per
  language rather than described in a comment:

  | setting | what it prevents on one cluster |
  |---|---|
  | `application_name` | an unattributable query — nine services in one `pg_stat_activity` and no way to say whose |
  | `statement_timeout` | one service's runaway query occupying shared resources |
  | `idle_in_transaction_session_timeout` | one forgotten `BEGIN` blocking `VACUUM` cluster-wide |
  | a bounded pool | one service taking the connections the other eight need |

  Six languages (go, elixir, python, ruby, node — also bun — and rust), each
  parsed by **its own parser** in the gate, and each required to carry the
  contract by `templates/database/contract.json` rather than by a grep repeated
  six times. The cluster sets the two timeouts **per role** as a backstop, so a
  service that forgets them is bounded rather than unbounded.

- **the pooler decision, as a check rather than a paragraph.** kit runs **no
  PgBouncer**: direct connections, `max_connections` raised to 200, a per-role
  `CONNECTION LIMIT`, and per-role timeouts. The argument is in
  `templates/database/README.md` and the measurements in `DECISIONS.md` (MD21); the
  deciding sentence is from PgBouncer's own configuration documentation, which
  describes `RECONNECT` on its admin console as the remedy for
  `ERROR: cached plan must not change result type` after a DDL migration — a
  manual operator step after every schema change in nine repositories.

  The pooler workarounds are **forbidden** in `contract.json` and the gate fails
  the build if one appears in any generated config. A service carrying
  `prepare: :unnamed` on a fleet with no pooler is slower and looks entirely
  correct, so nothing else would ever find it.

- **`DECISIONS.md` — the file seven places referenced and that did not exist.**
  `AGENTS.md` (twice), `README.md` (twice, one of them a markdown link),
  `.github/zizmor.yml`, `ci.reusable.yml` (three times) and three of the gate's
  own scripts all pointed at it. A reference to a decision document that is not
  there tells the reader the trade was made and then leaves them with nothing to
  read — worse than not claiming it, because the absence looks like they have not
  looked hard enough. It now exists, with MD10, MD12, MD13 and the four MD21
  entries this packet decided, and a check asserts it is present, records real
  entries, and that every reference to it resolves.

### Changed

- **the cluster image is `postgres:17` (Debian), not `postgres:17-alpine`.**
  pglayers publishes each extension as a glibc-linked layer built from the PGDG
  Debian packages, and alpine is musl. Measured, on the alpine base: the image
  **builds cleanly** and then `CREATE EXTENSION vector` reports the extension is
  not available, with `ldd` showing `Error loading shared library
  ld-linux-*.so.1`. Two independent failures — the loader cannot resolve a glibc
  binary, and alpine's PostgreSQL looks under
  `/usr/local/share/postgresql/extension` while pglayers writes to
  `/usr/share/postgresql/17/extension`. On `postgres:17` the same layer answers a
  real query. An image that claims pgvector and does not have it is worse than one
  that is visibly missing it.

  The layer is composed rather than pulled: `pglayers-full` would be one line
  instead of four, but it *replaces* the official `postgres` image with a
  community build for every service permanently, and loads 80+ extensions and a
  raised `max_worker_processes` onto the cluster whether or not any is used.
  Trade recorded as MD21b, including that pglayers is a community project and
  **not** a PostgreSQL one — it layers onto the official images, which is a
  weaker claim.

- **extensions are a cluster decision, created by the admin role.** A service role
  cannot `CREATE EXTENSION`: pgvector's control file is not marked `trusted`, so
  a non-superuser is refused with `HINT: Must be superuser to create this
  extension`. Verified against pglayers' layer *and* upstream pgvector v0.8.6,
  whose `vector.control` is byte-identical — this is pgvector's own
  classification, not something the packaging drops. The `SET ROLE` design that
  looked right could not work, and the measurement is why.

- **`lint/hadolint.yaml` ignores DL3067 as well as DL3008.** The cluster image is
  `COPY --from=<layer> / /`, which is pglayers' whole mechanism and has no
  narrower form on PG17. The rule's rationale — an accidental whole-filesystem
  copy pastes in unreviewed files — is answered by pinning a specific published
  version of one extension rather than by the rule.

- **`templates/compose/.env.example` said `KIT_POSTGRES_TAG=16.6-alpine` while
  `docker-compose.yml` defaulted to `17-alpine`, and `.env.example` WINS** —
  `bin/dev` copies it to `.env` on first run, so every developer's stack ran 16.6
  while the compose file, this README and the CHANGELOG all said 17. Commit
  `48689e6` fixed the compose default and left the file that overrides it alone,
  which is the more dangerous half of that fix: it made the repository agree with
  itself and the developer's machine disagree with both.

  Now asserted in **both directions** — a tag in `.env.example` that is not the
  compose default fails, and a compose default that is not that tag fails. A
  check that only asked "is `KIT_POSTGRES_TAG` in `.env.example`" would be
  satisfied by the broken state, because the broken state has it. The check also
  refuses an alpine variant, with the reason. self_test breakage 68 is the shipped
  defect and breakage 69 is the alpine regression.

- **`artifacts.json` documented an `optional` field that no code implemented.**
  "Such an artefact is reported but does not, by itself, make a service look
  broken" — a property stated in the table's own `_about` and asserted in zero
  places, because no artefact in the table used it. kit-21 added the first
  optional artefacts and the reporter turned every one into an unpinned finding
  for every service in the fleet, which is the opposite of what the field says.
  `staleness.py` now implements it, and the exemption is **`absent` only**: a
  `diverged` optional artefact is a copy that has drifted and still needs a pin,
  and an `unknown` one is an unmeasured artefact and inherits the fail-closed
  rule rather than copying it.

### Fixed (previously open in this release)

- **a gate that exited non-zero reporting NO finding was reported as "the gate
  went red, but NOT via `<the named check>`", which blames a check for a machine
  problem.** `expect_red_check` had exactly two verdicts — green, or red-for-a-
  different-reason — and neither of them is true when the nested gate died before
  reporting anything: it is neither a proof the mutation escaped nor a proof the
  check failed to catch, it is a proof that could not be **evaluated**.

  It surfaced on kit-19's own full gate, at load average 15 on a 16GB box:
  breakage 35 came back `exit 1` with an empty finding list and was counted as a
  check that failed to catch a half-adopted language. `validate.sh` exits 1 on a
  FAIL *and* exits 1 from bootstrap when it cannot install its own dependencies
  (lines 132 and 3195), and the second never reaches a single check — so the two
  are indistinguishable from the exit status alone.

  A third verdict now exists, `SKIP`, and it is distinguished from a missing
  toolchain by a **separate counter** (`env_skips` against `skips`) because they
  are two different problems demanding two different responses. Both remain
  fatal: a proof nobody ran is not a proof, and an unevaluated one is not a proof
  either — but neither is reported as a gate defect, so the next reader does not
  go looking for a weakened check that is in fact fine. The summary names the
  count explicitly, because `env_skips` cannot appear in the PASS line at all
  (it is non-zero only on a run that exits 1).

  Verified against all four cases with the predicate isolated from the harness —
  a dead gate with no output classifies as an environment failure; a real red
  naming a *different* check still classifies as a red-for-the-wrong-reason; the
  named check firing is a pass; and green-with-no-finding is still a failure.
  That last one is the point: this widens what counts as an excuse by exactly the
  case where the gate said nothing, and no further.

  Same principle as breakage 39, which asserts the **explanation** rather than
  the exit status for the same reason: a red that misattributes itself sends the
  next reader to the wrong file.

- **`expect_green_check` read a MATCH as a non-match once the gate's output was
  large enough, so breakage 59 reported the adoption ceiling red when it had
  passed.** `printf '%s\n' "$out" | grep -qF` is the SIGPIPE defect
  `expect_red_check` was already repaired for and recorded at length: `grep -q`
  exits at the first match and closes the pipe, `printf` dies 141, `set -o
  pipefail` promotes that to the pipeline's status, and `!` inverts a success into
  a failure. It was latent because the gate's output had never crossed the 64K
  pipe buffer; kit-19's `license_check` printing its measurement on PASS — which
  is what `check`'s own contract asks of a check reporting which spec it
  verified — was the crossing point.

  Reproduced outside the suite to establish the mechanism rather than the
  coincidence: at 5000 lines `grep -qF` returns 141 and the shell `case` returns
  0 on the same input and the same match. The failing run printed the diagnosis
  itself — `printf: write error: Broken pipe` — inside a phase whose output nobody
  reads on a green run.

  **The fix is a `contains` helper** (a shell `case`, no pipe) used by
  `expect_red_check`, `expect_green_check` and `expect_skip_check`. Three correct
  copies were the wrong shape: the failure is a property of how the harness READS
  output and has nothing to do with which check it is reading. Stopping the new
  check printing was the alternative and it was worse twice over — it contradicts
  `check`'s documented behaviour, and the threshold it hides behind is a property
  of the pipe buffer, so it moves with the machine and returns as a flake on
  somebody else's packet. No recipe, threshold or pin changed.

- **`templates/compose/docker-compose.yml` defaulted to postgres 16.6 while the
  rest of the fleet floated at 17.** `postgres:${KIT_POSTGRES_TAG:-16.6-alpine}`
  meant a developer running `bin/dev` with nothing configured got postgres 16.6
  and a different database build from every CI runner in the fleet — which is the
  drift `core`'s `compose.postgres-pin` rule exists to make visible, and which
  it had recorded as a known exception since the rule landed.

  Now `postgres:${KIT_POSTGRES_TAG:-17-alpine}`, so an unconfigured developer
  gets the fleet's build. `core`'s recorded expectation in `tests/test_specs.py`
  and the table in `docs/postgres-pin.md` moved in the same commit as this one,
  because they are one claim stated twice.

  One kit reference to the rule remains and is now recorded rather than fixed:
  `templates/deploy/compose.deploy.yml` carries a `services.app.image` of
  `${KIT_DEPLOY_IMAGE:?the deploy tool sets KIT_DEPLOY_IMAGE}`. It is not a
  postgres image — it is a variable the deploy tool sets at run time — but it
  sits in `services:`, so the rule reads it. It is left visible on purpose:
  suppressing it would teach the rule to skip variables, and
  `${KIT_POSTGRES_TAG:-default}` is exactly the form the rule exists to resolve.

- **kit-17 — `templates/otel/ruby` had no interpreter floor, so the gate blamed
  the template for the interpreter it picked.** `FAIL templates/otel/ruby (ruby
  test suite)` on every gate run on macOS, minitest `.EE.......E..` — three of
  thirteen tests erroring, all three the same `NoMethodError: undefined method
  'filter_map'`, called from `usable_tracestate_entries`.

  **The template was right and the runner was wrong.** `filter_map` arrived in
  ruby 2.7; kit's own pin is 3.4 (`templates/mise.toml`, `lint/rubocop.yml`'s
  `TargetRubyVersion`), and the macOS system interpreter at `/usr/bin/ruby` is
  2.6.10. Every method *definition* in the file parses fine on 2.6, so 2.6 loads
  `traceparent.rb` without complaint and only raises on the first tracestate
  entry — which reads exactly like a bug in trace propagation, and was
  measured as one for three packets' worth of gate runs before anyone read a
  version number. (kit-14 attributed it pre-existing and reproduced it on a
  clean clone of master; this entry is the fix, not the attribution.) The other
  five templates are unaffected: go, node and rustc all *refuse* an old
  toolchain at build time with a message naming their own requirement. Ruby is
  the only one of the six that can fail silently.

  - **`KitOtel::RUBY_FLOOR = '2.7'`, in the file.** Not a sentence in the header,
    because the failure it prevents does not look like a version problem. 2.7 is
    `filter_map` and nothing else — everything else in the file and its suite is
    2.4 or older (`casecmp?` 2.4, `allbits?` 2.5, `&.` 2.3) — so it is the
    file's real requirement rather than a guess, and well below the 3.4 kit hands
    a service.
  - **The gate reads that constant** (`ruby_floor()`) instead of keeping its own
    copy of the number. A version restated in the runner is a second place for it
    to rot, and asking the artifact is the same reason the classifier's tier
    lives in `rules.json` and nowhere else.
  - **A below-floor interpreter is a loud, counted `SKIP`, not a `FAIL`.** The
    template is correct and the interpreter is too old; reporting that red would
    keep three landed-or-landing packets blocked by a red naming a file none of
    them touched. Reporting it `PASS` would be worse — a pass on the strength of
    thirteen tests that never ran. An unreadable floor is still a `FAIL`: that one
    *is* a template defect.
  - **`version_at_least()` — a hand-rolled version comparison.** Not `sort -V`,
    which is a GNU coreutils extension older BSD sort lacks; a floor comparison
    that degrades to a *string* compare on the sort macOS ships reads `2.10` <
    `2.9`. An unparseable field refuses rather than assuming the version is new
    enough — fail-closed, like `tests/classify.py`.
  - **Two new self-test breakages, 23 and 23b, both on a stub `ruby` that
    reports 2.6.10 and refuses the suite.** 23 deletes the floor guard and
    asserts the suite goes red *under its own label*; 23b keeps the guard and
    asserts the gate stays **green** while naming the skip. 23b needed a fourth
    helper, `expect_skip_check`: "the gate went red" cannot express a check that
    is load-bearing precisely by not going red, and "the gate went green" is
    satisfied just as well by a check that was deleted entirely.
  - **Two counting bugs found on the way, both the same shape.** The breakage
    counts in `self_test.sh` and `validate.sh` anchored on `^expect_`, which also
    matches the four helper *definitions* — `expect_red() {` looks exactly like a
    call to a name-only pattern — so both printed **28 over 23 recipes**. And the
    header/recipe check anchored on `^expect_` too, so the indented calls in
    breakages 23/23b (inside a `command -v ruby` guard) were reported as two
    documented breakages carrying no recipe: the check was right about the
    disagreement and wrong about the cause. All three now anchor on the breakage
    *label*, which a function definition cannot carry. `[ \t]*` rather than `\s*`
    in the header check, because under `re.M` `\s` matches a newline and `\s*`
    could span onto the next line and match a label that is not a recipe at all.
  - `self_test.sh` is now **25 breakages — 24 that assert the gate goes red, and
    one (23b) that asserts a green gate with a named skip.** The summary line
    says which is which rather than claiming all 25 "went red", because that
    would be a false statement about a proof that passed.

  Gate on this branch: **143 pass, 0 fail, 2 skip** (both the pre-existing
  `node --check cannot read TypeScript` skips for `templates/tier/{node,bun}`,
  which are a parser gap in a packet that owns it, not this one). All six
  traceparent suites green, `canary_test.sh` green against a real collector.


### Changed

- **kit-12 — lint runs from kit. The `cp` is gone.**
  `lint/` was 249 lines of golangci, rubocop, eslint, yamllint and hadolint
  configuration that **not one service in the fleet had ever copied**, and every
  check in this repository was green the whole time. Adoption correlated
  *inversely* with how much a file did: `uses: cafaye/kit/...@master` is 11/11
  because it is live, and `cp lint/golangci.yml` is 1/11 because a snapshot has
  no propagation and rots silently. So the config moved to where the step already
  is, and adoption becomes 11/11 with no per-service action.

  (The brief this packet answered put those at 8/8 and 0/9. The second is
  stale — `identity` has since landed a `.golangci.yml` of its own on `master`,
  for a reason recorded in `lint/drift-allowlist`. Writing `0/9` here would have
  been a number this work had measured and known to be wrong.)

  - **`kit-lint-ref` and a sparse `lint/` checkout, in the go, ruby and node
    jobs.** The workflow file and the configs are two different things:
    `uses: cafaye/kit/...@X` pins the *workflow*, and a reusable workflow is not
    handed its own ref — so the configs are fetched by name, and the name has to
    be an input. Pin it to the **same** ref you pinned `uses:` to; a caller who
    pins one and not the other gets that SHA's workflow with today's lint
    policy, which nothing detects automatically and is therefore documented in
    the input and in README.md rather than pretended to be automatic.
  - **The ESLint config is checked out *inside* the repository, at
    `<working-dir>/.kit`.** Measured, not preferred: node resolves an ESM import
    from the config file's own directory upward, so a config beside the
    repository finds no `@eslint/js` and the run dies with
    `ERR_MODULE_NOT_FOUND` — a red build that has linted nothing. One location
    serves all three linters.
  - **`lint/eslint.config.mjs` ignores `.kit/**`.** Without it the run is red
    with a parse error about *kit's own* config file, in a service that did
    nothing wrong, on a file the service never wrote.
  - **`lint-args` is the deviation seam**, and it is deliberately narrow: it is
    appended *after* kit's flags, so a service can add and cannot remove the
    `--config`; and it is a string rather than a path, so there is no
    service-side file to rot. What it may not do — change which config is read,
    what is linted, or whether a finding fails the build — is a list of 15
    refused flags enforced by a **`lint-args guard` step in the workflow**, not
    by kit's gate, because `lint-args` is the caller's value and kit has never
    got it. `lint_args_seam_check` asserts the guard is in all three lint jobs,
    that the copies are byte-identical, that it runs *before* the linter, and
    that its token list is the one written in the gate.
  - **ESLint runs directly, not `npm run lint`.** `npm run lint` is whatever
    script the repository happens to define — a repository that defines none gets
    a confusing "Missing script" rather than a lint, and one that defines it is
    running its own config, which is the copy this packet exists to end.

### Added

- **kit-19 — kit carries a licence, and a check that keeps it unambiguous.**
  cafaye's decision is MIT across the fleet, and `kit` had no `LICENSE` at all.
  That is not "unlicensed, therefore free": it is **all rights reserved**, the
  default copyright position when a public repository grants nothing, and it is
  the state `docs`' `licensing.md` names `kit` in. The grant is now the MIT text
  in `LICENSE`, and the README says so in two places — a `### kit's own licence`
  paragraph next to the AGPL one, and a `## License` section a reader looking for
  a licence actually finds.

  - **The check is for AGREEMENT, not for the file's existence, and that is the
    half that matters.** A licence is only unambiguous when exactly one place in
    a repository can declare one. `license_check` asserts the grant by MIT's own
    sentences rather than by the string `MIT` — the identifier is also how a
    badge line, a summary, or a note about some *other* repository's licence is
    spelled, and matching it passes on all three — asserts a copyright holder
    exists, asserts the README states MIT and links the file *in its own section*
    rather than anywhere in the document (the AGPL paragraph names a licence that
    is not kit's, so a whole-file substring search is satisfied by the exact
    conflation the section split exists to prevent), and then walks every root
    manifest that can carry a licence field and fails on any that is not MIT.

  - **It checks agreement, and does not ban the manifest.** A check satisfied by
    "kit has no `package.json`" would be satisfied by deleting one, and would be
    a `FAIL` the day kit legitimately grew one — the same shape as breakage
    31b's control. `templates/` is untouched by design: a licence in a template is
    that template's business, and only the root can be about kit.

  - **Two breakages, `61` and `62`, and 62 is the one that makes it real.** 61
    deletes `LICENSE`, which is the direction everybody can see. 62 writes a root
    `package.json` declaring `AGPL-3.0-only` while `LICENSE` and the README both
    still say MIT: the repository has acquired a third statement about its own
    grant, a compliance tool reads the manifest, and a reader has no way to tell
    which is authoritative. A check asserting only that `LICENSE` exists is
    satisfied by exactly that state, and a manifest is easy to add without
    anybody thinking of it as a licence decision. 62's fixture is **assembled**
    with `printf`, not written out — the same rule as breakages 24, 25 and 33,
    because a probe written out is a probe committed.

  - **`fresh_copy` now copies `LICENSE`.** Without it the new check fails on
    every throwaway copy for a reason that has nothing to do with the defect
    under test, and the two green-expecting proofs (23b, 59) go red for that
    reason. A check that cannot run in a copy is a proof that proves nothing
    while reporting something.

  - **Two counts moved, both in prose rather than in code.** The self-test is
    now 67 breakages, 65 of which must go red, and 47 assert the *named* check.
    `self_test.sh`'s header is checked against the recipes by
    `self_test_claims`, so the header could not simply be left at sixty-five; the
    README and `AGENTS.md` prose is not mechanically checked, which is why it is
    worth saying the numbers were updated in all three places deliberately.

- **kit-13 — the observability stack gets a live path, and a gate that says which
  repositories are not on it.** `templates/compose/` shipped a complete local
  observability platform and **no service used it**: no repository had an
  `otel-collector.yml`, six carried a bespoke 52–158 line
  `docker-compose.yml` whose only infrastructure was a Postgres, and **none**
  adopted `bin/dev`. The stack was built, gated, and running nowhere.

  - **`bin/dev` fetches the stack from a PINNED kit ref** and runs it beside the
    service's own `docker-compose.yml`, which is an override. A compose file
    cannot be `uses:`-ed — GitHub resolves reusable *workflows* and nothing else —
    so `bin/dev` is the callable path and the pin is what makes it one.
    `git init` + `fetch --depth 1` rather than `clone --branch`, because
    `--branch` cannot take a commit sha and so cannot express the stricter of the
    two pin forms.

  - **The pin is `kit.ref`, a committed one-liner — and it was `.env` first.**
    `.env` is git-ignored, so a pin there exists on exactly one machine and on no
    CI runner or teammate's checkout, which turns "one command, always current"
    into "one command, whatever this checkout last fetched". `bin/dev pin <ref>`
    moves it deliberately and prints the stack diff first. A 40-char sha or a
    `v<semver>` tag; a branch is refused **before any network call**, because by
    the time a fetch has returned it has already changed under you.

  - **`KIT_STACK_OFFLINE=1` is a real mode.** It uses only `KIT_STACK_DIR`, the
    cache, or a copy vendored at `.kit/stack` — and fails loudly, naming each,
    when none holds the pin. A cached or vendored tree must RECORD its ref in
    `.kit-stack-ref`; a directory that merely contains `templates/compose/` is
    refused, because accepting one silently is how an offline loop stops matching
    what the team runs.

  - **`tests/fetch_test.sh`** — 14 assertions, executed. A pinned ref resolves and
    the fetched bytes are byte-identical to the tree; a branch, a short sha and
    an empty pin are each refused with a message that says why; offline runs from
    a cache with the remote deleted from disk, fails loudly with a cold one, and
    accepts or refuses a vendored copy by whether it declares the pin. The remote
    is a local `file://` bare repository built from this tree, so the suite needs
    no network.

  - **`tests/stack_live_test.sh`** — 15 assertions, executed, and the reason the
    packet is not "a compose file that parses". It brings the **fetched** stack up
    (all eight containers healthy), sends real OTLP, and reads a trace out of
    Tempo and a metric out of Mimir — including the `spanmetrics` connector's
    `cafaye_duration_count`, which is what the fleet dashboard is built on. The
    canary reaches no exporter, asserted as an absence against a search that first
    proved the data is there. The collector's config is checked by
    `docker inspect .Mounts`: the daemon's own record of the bind, not the host's
    idea of it and not the container's (the image is distroless).

  - **`tests/fleet_check.py`, wired into the gate as `fleet`.** Four failure
    modes, one check each: a service carrying a copy of the shared stack, a
    service that re-points the collector's config mount (the redaction allowlist,
    derived from core's schemas), an `otel-collector.yml` nothing ever mounts, and
    a pin that is a branch. It reads the **sibling repositories**, not kit's own
    files, because the defect is in the callers — the same shape as D4.
    **It is red against the current fleet and that is the deliverable**: five
    repositories carry their own copy of the shared stack, six have no pin, and
    two publish a port on a service kit already ships. The predicate is the
    image, not the service name, and the image set is read out of kit's own
    compose file rather than a hand-kept list — three of the five copies name
    their database `db` rather than `postgres`, so a name-keyed check would report
    the fleet clean while five copies stood right there.

  - **Nine breakages (52–60), eight asserting the NAMED check and one asserting
    the gate stays green while naming its finding.** The fleet ones run against a
    **fixture fleet** rather than the real one — which is what makes the
    assertion mean anything when the real fleet is red by design. Breakage 58
    covers the `ports:` append rule and carries **no `image:`**, so it fires the
    port rule alone: a breakage that reddened two rules at once would not say
    which of them is load-bearing. 59 and 60 are the adoption ceiling's two
    sides and are described below.

- **kit-14 — the staleness reporter, pointed at `templates/`, and the word
  `absent`.**
  kit already had a change classifier and a staleness reporter for `core/`, and
  both work. Both also **only watched `core/`**, while `templates/` — the
  directory that has drifted furthest — was watched by nothing.

  This is not "detect drift in `templates/`". Drift detection assumes a copy
  exists, and in the fleet the copies are gone: of the twelve files in
  `templates/compose/`, the nine services hold `docker-compose.yml` in seven of
  them and **none of the collector, Tempo, Loki, Mimir or Grafana provisioning
  in any of them**. A reporter that only knew `current` and `stale` would have
  nothing to say about the commonest state in the fleet.

  - **`tests/artifacts.json` — the one place kit says what it ships and where a
    service puts it.** Twelve artefacts, the language each applies to, and the
    `compose` bundle's twelve members. Read by the reporter *and* by the gate,
    because a table written down twice is a table that is right in one of the
    two places. `destAlternatives` records the six Dockerfiles that live at the
    repository root rather than at kit's documented `docker/Dockerfile`: a
    documented, working placement is not an absence, and a reporter that cries
    wolf over it is a reporter that gets muted.
  - **`tests/staleness.py --scope templates` — five states.**
    `current`, `diverged`, **`absent`**, `unknown`, and `n/a`. `absent` is the
    new word and the whole reason the packet existed. `unknown` inherits the
    classifier's fail-closed rule rather than copying it: no declared language,
    a symlink where a copy should be, an unreadable file, an artefact kit has
    stopped shipping — each is a finding, because the cheap answer in every one
    of those cases is a guess. `n/a` exists so `unknown` can stay honest; a Go
    service has no `.rubocop.yml` because it is not a Ruby service, and calling
    that unmeasured would put three permanent, unfixable findings on every
    service in the fleet.
  - **A copy is never inferred from its content.** No similarity threshold, no
    percentage, no search for a file that hashes to kit's. A copy is `current`
    when the bytes at the declared path are equal and the path is a real file
    in the service's own tree, and at no other time. Proved by
    `tests/self_test.sh` breakage 37, written as the `quick_ratio() > 0.99`
    patch somebody would write to relax it.
  - **`templates/parity-allowlist` — why a copy is not kit's bytes.** The tier
    skip-allowlist's four hygiene rules in the same words and the same one-line
    dialect, because kit does not have two dialects of "record why". It adds the
    rule the tier file does not need: **an unpinned divergence or absence is a
    failure**, since its entries name copies in repositories the gate cannot
    read, and a record that silently omits a cell reads as "handled". **80
    entries**, and the count is printed on every green run because 80 is a bad
    number and everybody should be able to see that it is one.
  - **Eight new self-test breakages (33–40) and a boundary that finally has a
    check behind it.** 33 is a dead ledger entry (the ESLint shape) and 34 is an
    **expired** one — the first time anything in kit has watched a ratchet fire
    rather than reading that it exists, and it took spending a recipe to find
    that out. 35 is a `{lang}` source kit offers but does not ship: half a
    language is worse than none. 36 reports an `absent` artefact as `current`,
    and 37 grades by resemblance; they are separate because they are opposite
    mistakes, one removing a finding and the other inventing one, and a gate
    that can only do one of them is half a gate. 38 gives one of the two
    programs a third-party import, 39 removes a fixture's `.git` so the
    reporter cannot see it (and asserts the EXPLANATION, not just the exit
    status), and 40 deletes the line that consults the ruby toolchain floor.
  - **Two of those recipes were wrong, and `self_test` is what said so.**
    33 named an artefact id `artifacts.json` really declares, so the mutation
    broke nothing; the recipe now asserts its own premise before it mutates.
    34 asserted that the GATE rejects an entry naming a repository that is not
    on disk — it cannot, because kit's CI has no sibling checkouts and no gate
    here knows which repositories exist. The reporter does know, and
    `staleness_test.sh` proves that case; so 34 was re-pointed at the expiry
    rule the gate really has, rather than kit gaining a fleet roster so the
    gate could answer a question nobody asked it.
  - **`carve-out boundary` — a check, and the sentence it found out of date.**
    `AGENTS.md` has said "standard library only" since the carve-out was made
    and nothing verified it. The new check walks the **AST** of both programs —
    so a function-local import is read the same as a top-level one — and asserts
    that every module it finds is named in the sentence as well as on the list.
    It failed on its first run: `glob` arrived with this packet and `urllib` had
    been imported all along without ever being written down.

- **`tests/staleness.py --scope templates` measured the fleet, and the brief's
  numbers did not survive it.** `README.md` opens
  [what the fleet actually adopted](#what-the-fleet-actually-adopted) with the
  result. The corrections worth stating here: `mise.toml` is 9/9 diverged and
  the divergence is **adoption working**, because the template is the union of
  every language's pins (19 tools) and a service keeps the two it needs;
  `AGENTS.md` is 9/9 diverged and the divergence is the **opposite** — the
  template was superseded, only 12–40 of its 121 lines survive per service, and
  `## Observability` survives in **none** of the nine; and
  `lint/*` is **3 diverged, 3 absent**, not 0/9, because `billing`, `parlor` and
  `identity` each hold a linter config that is their own — none carrying kit's
  STRICTNESS NOTES block. The honest sentence is "nobody lints with kit's
  rules", not "nobody lints".

- **Four numbers in my own first draft were wrong, and all four flattered the
  measurement.** They are corrected above, in `templates/parity-allowlist` and
  in the report, and they are written down here because the pattern is the
  point: a figure that cannot survive being recomputed is a liability in a file
  whose whole job is to be believed.
  - **`AGENTS.md` "8–19 lines with markdown comments stripped".** The template
    has no comments to strip, and normalising the `<...>` placeholders does not
    shrink the diff either — still 315–669 changed lines. The nine are not
    filled-in forms, and this is the artefact where the fleet has the **least**
    of kit's template.
  - **`mise.toml` "8–19 code lines apart".** Not a number this comparison
    produces; the real figure is 80–110, and legitimately so.
  - **`bin/prime` "32 to 63 lines", and "the fleet's versions begin `#!/bin/sh`".**
    The range is 12–58. Only `caf` and `courier` use that shebang; `darkroom`,
    `muse` and `parlor` use kit's own, and **`identity/bin/prime` has no shebang
    at all**. All seven reasons asserted it; it was true for two. `billing`'s
    is not stale either — it carries the STRICTNESS NOTES block and is 12 lines
    from kit's ruby template, with Rails commands added.
  - **`billing/bin/dev` "predates kit's observability profile, brings up postgres
    and nats only".** It is two lines: `#!/usr/bin/env ruby` and
    `exec "./bin/rails", "server", *ARGV`. A Rails server shim, not a copy of
    kit's loop in any era. The claim was inferred from a line count rather than
    read off the file.

- **One of my own sentences was wrong, which is why it is here.** The first draft
  of `REPORT-kit-14.md` and of eight ledger entries said a partially-adopted
  compose stack "cannot start". Checked with `docker compose config`: it does
  not. None of the six services' compose files mounts any of kit's stack files,
  each declares one or two services of its own, and five of six pass validation
  — they are **replacements that kept a filename**, not broken copies. The
  reporter now says what it measured ("partially adopted: N of 12 members
  held") and stops there, because comparing bytes cannot tell a replacement from
  a broken copy.

- **A defect the byte-comparison cannot see, found while checking the sentence
  above.** `muse/docker-compose.yml` **does not parse**: an unquoted
  `${MUSE_VAULT_KEY:?…, or run: …}` whose error message contains a colon, and
  YAML reads the value as the start of a mapping. `docker compose config` fails
  with `yaml: line 65, column 67`. The reporter calls that cell `diverged`,
  which is true and is not the interesting thing about it; the ledger entry for
  `muse` now says so.

- **kit-16 — the first deployment, and the shape the other eight copy.**
  Nine services, nine languages, nine green gates, and not one of them had ever
  been deployed: there was no `deploy/` or `infra/` directory anywhere in the
  organisation and no ruling that mentioned production deployment. This is one
  reference deployment, run end to end, with the differences between the nine
  runtimes tabled rather than papered over.

  - **`templates/deploy/` — the distribution shape.** `compose.deploy.yml` is a
    real, runnable file rather than a template with holes in it: every value is
    a compose substitution, so it runs once `SERVICE_NAME` and
    `KIT_DEPLOY_IMAGE` are set. No `build:` section, `restart: unless-stopped`
    on every service, a healthcheck on every service, and **no credential
    anywhere in the file** — which is the property that shapes everything else.

  - **`templates/bin/deploy.sh` — the tool**, beside `dev.sh`, the other script
    kit hands out. `up` / `verify` / `rollback` / `status` / `down`. A deploy
    does not report success until the container's own healthcheck says
    `healthy`; a deploy that cannot reach green **rolls itself back** rather
    than leaving a broken version quietly replacing a working one.

  - **Credentials arrive on an inherited file descriptor and nowhere else.**
    There is no `--secrets-file`; `deploy` refuses the option by name. Values
    go into a **tmpfs** (RAM, per container, destroyed with the container)
    through the container's own stdin, so they never appear in `docker
    inspect`, in `docker compose config`, on the host disk, or in the image.
    The container starts and the application does not: `entrypoint.sh` waits
    for `/run/secrets/.loaded`, which the tool creates only once every claimed
    secret is in place, and **exits non-zero if it never arrives**.

  - **`templates/deploy/redact.py` — the log redactor.** Everything the tool
    prints is filtered: `docker inspect`, `docker compose config`, migration
    output, the health gate's own messages. Two layers — the exact values it
    was given, and **shape** (JWT, bearer token, AWS key, provider key, GitHub
    token, connection URL with a password, PEM header, any `*password*`/
    `*secret*`/`*token*` assignment) — because a filter that only knows its own
    inputs is defeated by anything it did not already hold. The credential's
    *name* survives, so the log still says which one was in play.

  - **`templates/deploy/reference/courier.deploy.yml` — the reference
    deployment**, and the thing this packet actually ran. `courier` (Elixir/
    Phoenix, 535 tests at `35c6a27`) was chosen over `caf` deliberately: it
    already has a release build and a readiness endpoint that really checks
    its database, so the template is written against the best story in the
    fleet rather than the worst. `caf` was rejected because a bug in its deploy
    path carries the authority to destroy shared Docker state.

  - **Rollback that is demonstrated, not described.** The previous artifact is
    recorded in a ledger (image tags and digests only — no secrets) *before*
    the new container starts, and `deploy rollback` runs the same deploy code
    path with a different tag and the same health gate.

  - **`tests/deploy_test.sh` — 66 assertions in nine sections, no sleeps.**
    Every health gate is demonstrated red **and** green: the database is taken
    away underneath the running service (`docker pause`, not `stop` — stopping
    the container destroys its tmpfs, so restarting it brings the database back
    *without its password* and tests the wrong thing), and `/readyz` is watched
    going 503, the container healthcheck is watched going unhealthy, and
    `deploy verify` is watched exiting non-zero; then all three are watched
    coming back. `/healthz` is asserted to stay 200 throughout, because a
    liveness probe that fails on a dependency turns a database blip into a
    crash-restart loop. The leak audit runs last, against the accumulated
    deploy log, the rendered compose config and `docker inspect`, and asserts
    the secret is present in the container's tmpfs so the negatives are real
    negatives.

    Two further sections close claims that would otherwise rest on reading the
    source. One deploys a **deliberately broken artifact** — the good image minus
    `/app/bin/migrate`, so the two differ by exactly the thing under test — and
    requires the deploy to report failure, to say it is rolling back, and to
    leave the previous artifact serving. The other creates a **decoy container
    and volume outside the compose project** and requires both to survive `down`
    *and* `down --purge`, so "never touch state you do not own" is executed
    rather than grepped for; it goes red if `cmd_down` ever grows a prune.

    **13 static proofs run without Docker; the 53 live ones SKIP loudly when the
    daemon or the image is absent, never silently.**

  - **The polyglot table, and why it is a table.** `docker/Dockerfile.go` and
    `docker/Dockerfile.rust` are `gcr.io/distroless/static` — **no shell, no
    coreutils** — so a shell-script secret gate cannot be mounted into them at
    all. The tool asks the container rather than the operator and switches to
    a tar streamed over `docker cp` when there is no shell, with the `.loaded`
    barrier as an extra tar member so a distroless service gets the identical
    guarantee; measured end to end against a distroless image carrying one bare
    binary and deliberately no `/bin/sh`. Separately, a `curl` healthcheck needs
    `curl`, and **the `-slim` runtimes ship neither `curl` nor `wget`** — a
    shell they do have, measured on `python:3.13-slim`. So each service writes
    its healthcheck in its own runtime's HTTP client, or, for distroless, in
    exec-form against a `healthcheck` subcommand the service itself provides.
    Migrations are a per-service label rather than a rule, because
    `bin/rails db:migrate`, `manage.py migrate` and `/app/bin/migrate` have no
    common form and Go and Rust have no schema at all.

  - **The database is pinned `postgres:17-alpine`**, the fleet's standard tag and
    the one `templates/compose/docker-compose.yml` already uses, so a deploy and
    a `bin/dev up` run the same server. Measured rather than assumed: `/bin/sh`
    (busybox), `pg_isready`, uid 0 and `docker-entrypoint.sh` on `PATH` — and no
    `curl`, with `wget` present, which is why the database's health probe is
    `pg_isready` and not an HTTP fetch. It runs behind the same secret gate as
    the application, because a `POSTGRES_PASSWORD` in `environment:` is a
    password `docker inspect` prints.

- **kit-15 — a check that fails when an adopting repository carries a workaround
  for a fixed core defect.** `core`'s gate checker had two defects that forced
  repositories which adopted `gate.yml` into local workarounds: **D12**
  (`RUN_KEY` could not see a one-line `run:`, fixed in core `63fd319`) and
  **D13** (a proof matched against bytes still carrying ANSI colour, fixed in
  core `c63af27`). Both are fixed, and a workaround for a fixed defect is not
  neutral — it is a second, local, unpolicied copy of a decision that now lives
  in core, and it is the kind that rots. A `gate.yml` carrying a hand-rolled
  escape-tolerant regex is now **weaker** than one without it: the escape runs
  absorb characters a stricter pattern would have rejected.

  - **`tests/gate_declaration_check.py`** — sweeps the adopting repositories for
    three shapes, each of which is *structural* rather than a keyword: a
    `proof[].match` carrying an escape token (D13), a `run:` block scalar whose
    entire body is the declared argv and nothing else (D12), and a comment
    naming a checker-internal term while claiming a `run:` spelling the checker
    cannot see (D12). It does **not** prescribe a `run:` spelling — doing that
    would be a second copy of a decision core owns, and `courier`'s block scalar
    is correct for three real reasons.
  - Wired into `tests/validate.sh` as `adopting repositories (no workaround for
    a fixed core defect)`, with the fleet root discovered beside the repository
    and a reported SKIP when there is none — the same treatment the
    core-allowlist check already gets, for the same reason.
  - **Three breakages in `tests/self_test.sh` (24-26)**, over a synthetic fleet
    built in the work directory, because kit is one repository and the fleet is
    fifteen. All three name the check they expect to go red, and the control is
    now the check's *positive* case: a sweep that has only ever run against a
    red fleet has proved it can fail and nothing about whether it is right.
  - `cafaye-rb`'s primary checkout is **red on this check today**, which is the
    check working: it carries the D12 workaround and the comment justifying it.
    It is fixed on `worker/kit-15-restore` and this is the report's evidence
    that the sweep found it.

  **The first version of the checker was a keyword scan and it cried wolf** —
  4 repositories, 24 findings, nearly all false, including `core/gate.yml` for
  the sentence "That is MD12's collect-then-run machinery" (`D12` is a substring
  of `MD12`) and `caf`'s declaration for comments arguing that a workaround is
  now *unnecessary*. Both fixes came from reading every comment it flagged, and
  both narrowed the check rather than loosening it. A check that fires on
  correct work teaches the reader to ignore it, and it had taught on the first
  repository scanned.

- **kit-12 — the gate now knows whether a linter ran.**
  - **`tests/lint_test.sh` (a sixth phase, `lint`, deliberately outside the
    `RUN_STATIC` guard).** Four linters are **executed** against a throwaway
    service built to violate exactly one rule, with kit's config, each paired
    with a control that must answer differently. `lint/` spent its whole life
    behind a parse check — `yaml.safe_load` on `golangci.yml`, `node --check` on
    the eslint config — and both are green on a file no linter has ever been
    pointed at. This phase is the only thing that tells a working config from a
    valid one, and it is **fatal on a skip**: the claim under test is "kit's
    configs work", and a run in which no linter executed has not tested it.
  - **`lint drift`, which reads BOTH files and reports the DIFFERENCE.** A
    service carrying a `.golangci.yml` that disagrees with kit's is told which
    linters it dropped or added. Banning the file was the first version and it is
    worse than the drift: a config that agrees with kit's has reached the same
    policy by another route, and failing it teaches the lesson that kit's config
    is a thing you get shouted at for having. Self-test breakage 31b asserts the
    agreeing copy **passes**, so the check cannot be satisfied by deleting it.
  - **`lint/drift-allowlist`**, for a difference that cannot be deleted yet:
    reason, owner, `since`, `until`, and four rules of which the fourth is the
    load-bearing one — **an entry that no longer describes a real difference
    fails**, modelled on ESLint's `reportUnusedDisableDirectives`. One entry is
    live: `identity`, whose `.golangci.yml` enables no linter and exists only to
    exclude one generated file.

### Fixed

- **A promise this repository made in a comment, with no control behind it.**
  The `lint-args` input's own description said `lint_wiring_check` "fails on
  exactly that string" for `--no-config`, and `lint_wiring_check` had no such
  assertion anywhere in it. The reason it *could* not have one is worth
  recording: `lint-args` is the **caller's** value, and kit's gate never sees
  it. So the control moved to where the value is — a `lint-args guard` step in
  every lint job — and kit's gate now asserts the guard exists, is identical in
  all three jobs, runs before the linter, is handed the variable, and still
  refuses all 15 flags. A comment promising a check is worse than no comment:
  the second one stops the reader looking for the first.
- **A claim this repository made about golangci-lint, before running it.** The
  drift check was written on the belief that a repo-root `.golangci.yml` is
  discovered "ahead of any flag the workflow passes", so a stale copy silently
  hijacked CI. **That is backwards.** `golangci-lint run -v` prints exactly one
  `[config_reader] Used config file`, and with `--config` it names kit's; a local
  config that disables `misspell` does not survive it, and RuboCop agrees. A copy
  does not hijack the build — it **splits** the policy, because every other
  invocation in that repository reads it while CI reads kit's, and it becomes
  live again the instant the flag is lost. That is still a finding, and it is the
  honest one. `GOLANGCI_LINT_CONFIG` **is** confirmed unread in v2, as claimed.
- **An allowlist rule that was red on a correct tree.** "An entry that no longer
  describes a difference" treated a repository that was *not in this checkout's
  fleet* as one that had stopped differing, so every run on a copy of kit — which
  is what `self_test.sh` does, twenty-odd times — reported the whole allowlist as
  dead. The rule is now scoped to repositories the run actually looked at; an
  entry naming one that was not looked at is reported as **unverified**, which is
  neither a pass nor a failure.


- **kit-08 — kit-04 landed on a master that had moved, without losing a check
  or a number.** `worker/kit-04` (secrets: gitleaks over full history, a
  runtime-leak canary, zizmor) branched before kit-05 and kit-07 and renumbered
  its breakages from the same base of 18 that master did. A textual union of the
  two files carries **34 recipes with four labels used twice** — 19, 20, 21 and
  22 — and `self_test_claims` compares the documented set against the carried
  set *as sets*, so the duplicates collapse silently and the check reports an
  agreement that does not exist.
  - Master's numbering is canonical and did not move. kit-04's **six language
    mutants** were dropped, not renumbered: they are master's 13–18 byte for
    byte, and a second copy would prove the same six rules twice under two
    names. kit-04's **eleven unique breakages** moved to **41–51**.
  - `tests/validate.sh`: 45 check sites on master, 34 on kit-04, **59
    merged** — twenty of the sites are shared verbatim, which is why the union is
    less than the sum. Both sides' checks survive, and what proves it is the
    *label* set rather than the count: every label on either side is still present
    in the merged file, except two that were resolved deliberately —
    `collector_check`, which is one function whose label disagreed (master's
    fuller revision won) and whose kit-04 version was an earlier, smaller copy of
    the same function; and the `self_test` invocation site itself, which is the
    union documented below.
    Master's `collector_check` also *subsumes* the part of kit-04's that is not
    superseded: `receivers` and `batch` are asserted per signal rather than for
    `traces` alone. The rest is deliberately gone — kit-04's "the traces pipeline
    ships to no non-local exporter" described the pre-fan-out stack, whose only
    exporter was `debug`, and it would go red against the tempo/loki/mimir
    fan-out master now ships. Keeping it would have been a check that fails on a
    correct tree, which is worse than no check.
  - The `self_test` invocation site now takes the union of both: `check_verbose`
    (kit-04's — the list of breakages that went red *is* the evidence, and a
    plain `check` prints one line and throws the rest away) with master's
    counted label. The count is `grep`-derived in both files from the same
    expression.
  - One mechanism replaced two: `self_test.sh` had a runtime `breakages=$((…))`
    counter *and* the grep. The counter also decremented itself on a skipped
    language, so a machine missing a toolchain would print a *lower* total than
    the file contains — which reads as though proofs had been dropped rather
    than as a missing prerequisite.
  - **The renumbering was left in two visible states, and both are fixed here.**
    The recipes ran `1`–`18`, then `41`–`51`, then `19`–`22`, so the file did not
    read in the order its own header documents it. Recipes `19`–`22` now sit
    between `18` and `41`, and the file runs in label order.
  - **`41`–`51` no longer share variable names with `19`–`22`.** The renumber
    rewrote the labels and left the variable names behind, so breakage `47` was
    still called `nineteen`; master's `19`–`22` then bound those same four names
    to a second directory. It worked only because each was read before the next
    write. Those eleven variables are now named for what they break.
  - **There is no breakage 23, and it was never a lost recipe.** The block moved
    by `+11`, carrying kit-04's `23` — the zizmor `unpinned-uses` baseline — to
    `51`. The gap is now documented where a renumber script will read it as a
    bug, and README states the scheme.

### Fixed

- **The gitleaks gate was red on kit-16's JWT canary, and the allowlist was empty
  by design.** `.gitleaks.toml` carried no `[[allowlists]]` entry because kit's own
  history scanned clean — but the gate runs `git log --all`, and every worker in
  this fleet is a worktree of one shared repository, so `--all` reaches
  `worker/kit-16-deploy`'s commit `924b725`: a `jwt` finding on
  `tests/deploy_test.sh` line 155. It is a fixture. kit-16's deploy story proves
  the redactor scrubs a token the deploy never supplied, and a canary built from a
  name the filter already knows would prove nothing — so the token is committed
  and the `jwt` rule fires on it. **The scanner did the one thing it is for.**
  The entry is the narrowest the config format allows — `targetRules = ["jwt"]`
  with `paths = ['''^tests/deploy_test\.sh$''']`, and `condition = "AND"`
  written out rather than left to the default, which is **OR**
  (`config/config.go`, `parseAllowlist`: an empty `condition` maps to
  `AllowlistMatchOr`) and would silently make the entry a union the day somebody
  adds a second criterion. Measured in a throwaway repository, both directions: a
  `jwt` in that file is suppressed, while a `generic-api-key` in the **same file**
  and a `jwt` in a **different file** are both still reported.
  - **The canary was re-proved after the entry was added**, because allowlisting a
    canary is only honest if the canary can still fail. `redact.py`'s JWT pattern
    weakened from `\.[A-Za-z0-9_-]{4,}` to `{99,}` in a scratch export of
    `worker/kit-16-deploy`, and `tests/deploy_test.sh` went red on **exactly one**
    claim — "the redactor left a JWT in the output" — with its other 16 green.
    Reverted, and the scratch copy is byte-identical to the branch.
  - **The better fix is kit-16's, and it is recorded as such.** The canary could
    be assembled at run time from a prefix, the way `templates/secrets/` already
    does, which is the pattern that exists so this file never needs an entry. That
    branch is not merged here. The entry is written so it decays: if kit-16 stops
    committing the string it matches nothing, and the next reader deletes it.
  - **The scan was not narrowed.** `--all` is what catches a secret that only ever
    existed on a branch, and it is the reason this finding was ever visible: on a
    single-branch clone the canary is invisible and the gate is green.
  - **README now says to delete the entry when copying the file.** kit's config is
    copied verbatim into thirteen repositories, and this entry names
    `tests/deploy_test.sh`, which none of them has. A `paths` allowlist matching
    nothing excuses nothing, so it cannot weaken a service's scan — but an entry
    whose reason is only true of the repository it came from is how the next reader
    learns that descriptions are optional in practice. gitleaks cannot report a
    dead allowlist entry the way `templates/tier/skip-allowlist` reports a dead one
    there, so the obligation is the reader's, and the README is the only place it
    can be stated.
- **`templates/otel/ruby` is red on master, and this merge neither caused nor
  fixed it.** Three `NoMethodError`s for `Array#filter_map` (Ruby 2.7+,
  `traceparent.rb:278`) under `/usr/bin/ruby` 2.6.10. Re-derived rather than
  inherited: `run_ruby` is byte-identical to master's, `git diff master --
  templates/otel/ruby/` is empty, and `git archive master` into a clean directory
  reproduces `3 errors` with master's own template and master's own runner —
  while the pinned `ruby 4.0.1` gives `1407 assertions, 0 errors`. The
  1370-vs-1407 gap is the tell: an interpreter too old to define a method does not
  skip assertions, it aborts the three tests that reach it. kit-14 has the real fix
  on `worker/kit-14-stale` (a `toolchain_floor_ruby` feature probe that FAILs
  naming the toolchain, proven by its breakage 30 — which is **breakage 40** on
  this branch); that branch was not merged when this was written.
  Not fixed here: it is pre-existing, it does not reproduce on this box's `PATH`,
  and a fix for a red I cannot see is a change I cannot verify. Rewriting
  `traceparent.rb` to avoid `filter_map` is recorded as the fix that is not the fix
  — it makes the gate green on an old interpreter by removing what the suite
  exists to exercise.
- **`expect_red_check` reported a proof as failing when the check it named was
  the one that fired.** The matcher was `printf '%s\n' "$out" | grep -qF`, and
  under `set -o pipefail` a writer that takes SIGPIPE makes the whole pipeline
  non-zero — so `grep -q` exiting at its first match turned a **hit** into a
  miss. Deterministic on output size, not on load: below the 64KB pipe buffer the
  assertion is correct, at or above it, `printf` is killed mid-write. Breakages
  **11** (hadolint) and **42** (the working-tree credential) both exceed it and
  were both reported as *"the gate went red, but NOT via `<the check that fired>`"*
  while printing that check among the FAIL lines it had just proven present.
  Now a substring test on the already-captured `$out`: no pipe, no SIGPIPE, and
  the assertion no longer depends on how much the gate prints. The same defect
  and the same answer were already recorded in `tests/canary_test.sh` for
  `docker logs | grep -q`.
- `tests/validate.sh` and `templates/secrets/go/sweep.go` cited breakages by their
  **kit-04** numbers — `15` for the `--redact` removal (now `43`) and `21` for the
  marshalling canary (now `49`). Both are the renumber's fallout, and both
  pointed a reader at the wrong recipe.
- Count drift in the prose, all of it second-hand rather than measured: `AGENTS.md`
  said *twenty-three* breakages in one place and *thirty-four* in another, *eight*
  named checks against the real **nineteen** (+2 over proof scripts = twenty-one),
  and *nineteen ways* in its own pre-commit checklist. `README.md` and
  `tests/self_test.sh` both counted the named proofs as *twenty* against the
  **nineteen** their own lists enumerate. Every one of these is a copy of the
  truth taken by hand, which is the failure the derived count exists to prevent.
- `tests/self_test.sh`'s header described the thirty-four breakages as *18 from
  the fan-out work, 17 from the tier work, 11 from the secrets work, 12 shared* —
  58, for a file that carries 34.
- A section comment read `# 47-22.` where the canary vectors are `47`–`50`: the
  renumber script's arithmetic leaking into prose.
- **Two of the thirty-four proofs were dead, and the renumber is what killed
  them.** Giving breakages `41`–`51` descriptive directory names named breakage
  50's copy `canary_literal` — which was already the name of the canary **value**
  assembled six lines below it. The recipe reassigned the variable to the value,
  so `edit` was handed `cafaye_canary_…/templates/secrets/go/canary.go` and died
  with a `FileNotFoundError`. Breakage 50 never ran, and because the script stops
  at the first crash neither did 51: *"the canary is committed as a literal"* and
  *"the zizmor config baselines unpinned-uses"* had silently stopped being
  tested, and the run died before printing its summary. Restored to `kit-04`'s
  naming, where the directory was `twentytwo` and the value `canary_literal`.
  Nothing about reading the file shows this — both lines are correct in
  isolation, `bash -n` is happy, and the header/recipe agreement below is
  perfect while both are wrong — so `self_test_claims` now also asserts that no
  throwaway-copy directory variable is ever reassigned.
- **kit-07 — the declared tier, and the allowlist that is supposed to shrink.**
  A tier is a class of test that needs a real dependency. The failure this
  exists to prevent has already happened in this fleet: a green run in which the
  whole database tier never executed once, because the suite printed `ok`.

  - **`templates/tier/<lang>/` — the declaration, per language, for all seven.**
    Declared in the test source and read by the runner's own collector, never
    grepped for a sentinel. A sentinel fails *open*: a test reaching Postgres
    through a helper two files away does not match Identity's
    `dbtest.Pool|Schema|EnvVar|TEST_DATABASE_URL`, so its package never enters
    the required list and the run is never required to contain it. Rust
    (`#[ignore = "cafaye:tier=db reason=…"]`), Go (`//go:build tier_db`) and
    Python (`@pytest.mark.tier_db`) have a collector that already exists. Ruby
    gets a `tier :db` macro, Elixir a `@tier :db` attribute, and Node and Bun an
    exported `TIER` const — each a **no-op at runtime**, so the collector is a
    ~15-line adapter rather than a parser.
  - **Two collector claims measured, and both corrected the prior claim.**
    `cargo test -- --list --format json` is **nightly-only** (`-Z
    unstable-options`, rustc 1.95.0) — on stable, `--list` includes ignored
    tests and `--list --ignored` gives the ignored subset, which between them
    carry everything the JSON would have. `--list --include-ignored` lists
    *everything* and filters nothing. And `bun test --reporter=junit` **does**
    emit a full inventory: a filtered-out test is still a `<testcase>`, so the
    absent-testcase failure mode does not occur there. What bun lacks is a
    declared *reason* — `test.skip` takes none.
  - **`templates/tier/README.md` — the normalised result format**, the three-way
    `ran` / `skipped` / `filtered` distinction JUnit XML cannot express, the
    allowlist rules, and **what a tier gate cannot catch**. A package filtered
    out of the run entirely is the sharpest: the test asserting the tier ran
    lives *inside* the tier and cannot observe its own absence. Only the
    inventory-vs-run set difference catches it, and that is `caf gate`'s.
  - **`templates/tier/skip-allowlist` — one file for the fleet**, with four
    hygiene rules: every entry names a **reason**, an **owner**, a `since` and a
    `until`; and **an entry matching nothing is a failure**. That last rule is
    modelled on ESLint's `reportUnusedDisableDirectives`, which reports a
    disable comment that no longer suppresses anything. Without it an allowlist is
    a ratchet that only turns one way, and within two quarters it contains every
    test in the repository. The **total is printed on every run, green included**
    — individual entries look justified; the aggregate is the problem.
  - **`required-tier` on the reusable workflow.** Demanded, not inferred: the
    caller names the gate variable (`REQUIRED_DB`) and the workflow exports it
    as `1` on every language job's test step — guard's `GUARD_REDIS_REQUIRED`
    pattern, which fails at *tier-invocation* time, before a report exists. A
    `tier demand` step then fails **naming the variable** if the run produced no
    `ran` line, because a gate variable that is set while a tier runs zero tests
    is a green build that verified nothing. Opt-in: the default is `''`.
  - **`-count=1` mandated on the Go job.** Go keys its test cache on the
    environment a test reads, so a gated and an ungated run already have
    different cache keys — genuinely good news — but mandating the flag removes
    the question rather than reasoning about it, and it costs nothing.
  - **Never cache a test report**, documented in README with the reasoning:
    `restore-keys` matches by **prefix**, and the default branch's cache is
    documented as available to other branches, so a key built from
    `hashFiles('**/lockfile')` restores a report written by a run that *had* the
    database into a run that did not. **A witness from a different run is not a
    witness.** Also stated: fork PRs get read-only cache access, which is a
    cross-trust-boundary path into the gate in any workflow using
    `actions/cache` today.
  - **Floors are relabelled as decrease detectors.** Identity's
    `1254/1166`-style floors are kept and are cheap at catching deletion, but a
    floor is satisfied by *any* 1254 tests including the wrong 1254. Calling one
    a tier gate is worse than having none.

- **`core/` — the `cafaye/core` fan-out standard.** Six repositories copy bytes
  out of `core` and nothing makes the copy reach them. This ships the standard
  that does, plus the two runnable pieces that make it enforceable:
  - `core/vendir/vendir.yml.{muse,pantry,caf}` — the three real consumers, in
    three languages. `muse` and `pantry` are **proven byte-identical (sha256)**
    to what those repositories have committed today, by running vendir 0.46.2
    against the real `cafaye/core`. `caf` **cannot migrate as-is** and its banner
    says why: vendir has no rename, `caf` holds the bytes as
    `manifest-0.2.json`, and core publishes them as
    `cafaye.manifest.schema.json`.
  - `core/vendir/vendir.yml.template` — the onboarding template. Four things to
    change, each marked, each with the reason it is easy to get wrong.
  - `core/renovate/renovate.json5` and `core/renovate/SETUP.md` — one
    `inheritConfig` policy for the fleet, and the ordered steps to stand it up
    **including what to verify before onboarding a second repository**.
  - `core/release/release.yml` — what `core` needs to be taggable. Ships here;
    belongs in `core/.github/workflows/`.
- **`tests/classify.py` + `tests/rules.json` — a change classifier that fails
  closed.** `self_test.sh` proves twenty-three synthetic breakages go red; it
  cannot prove a future change to `event-envelope.schema.json` is one of them. So
  a difference between two vendored schema sets is classified into
  `FILE`/`PACKAGE`/`WIRE_JSON`/`WIRE` (buf's four tiers, because *pick the
  category that matches what your consumers actually depend on*), and **anything
  the catalogue does not name is `UNRECOGNISED`, which is the strictest tier**.
  A new JSON Schema keyword arriving in core cannot be auto-merged green by
  omission. The escape hatch is fenced: a rule may set `breaking: false` only for
  an operation in the closed `advisoryOps` list, or the catalogue refuses to
  load.
- **`tests/staleness.py` — the fleet staleness reporter.** Reads every consuming
  repository's recorded pin — a `vendir.lock.yml` sha *or* the hand-bumped
  `CORE_REF`, because three repositories still use the second — resolves where
  `core` is now, and prints the distance. `--fail-on-behind` makes it a gate;
  `--fail-on-behind` is *off* by default because a stale copy is legal and a
  scheduled report that is red every week is a report that gets muted. Run
  against the real working tree it reports the first measured fleet fact:
  **`muse` is nineteen commits behind**, and `caf` and `pantry` hold vendored
  bytes with **no recorded origin at all**.
- **Three new self-test breakages (18 → 21 at the time of writing; 23 after
  the merge with the tier work).** `includePaths` nested under
  `git:`; the classifier made to **fail open**; the staleness reporter calling an
  undeclared pin `current`. The second is the sharpest proof in the file: it
  inverts the fail-closed property and asserts the suite notices.
- **A check for a file type kit was already shipping unlinted.** The vendir
  templates are YAML under non-`.yml` names, so the `git ls-files '*.yml'
  '*.yaml'` sweep skipped them — and a service that copies one greets its first
  CI run with a failure nobody authored. They are linted by name now.
- **Two new `classify_test.sh` cases that exist to keep the gate honest rather
  than red.** An advisory change must be *reported and not fail*, and a
  reordered `required`/`enum` must not break `FILE` — JSON Schema defines both as
  sets, so a reorder is provably not a semantic change. A gate that goes red on a
  cosmetic edit trains the first person who hits it to reach for the gate rather
  than the cause, which is how a fail-closed gate becomes a fail-open one.
- `core/README.md` records what the fan-out measurement actually found, which is
  **not** what the design was briefed on, and states plainly what stays unproven
  until the first real tag moves.

-
 
*
*
k
i
t
-
0
5
 
m
e
r
g
e
d
 
o
n
t
o
 
a
 
m
a
s
t
e
r
 
c
a
r
r
y
i
n
g
 
t
h
e
 
t
i
e
r
 
w
o
r
k
:
 
t
w
o
 
`
f
i
`
s
 
l
o
s
t
,
 
a
n
d
 
t
h
e


 
 
g
a
t
e
 
w
o
u
l
d
 
h
a
v
e
 
l
i
e
d
.
*
*
 
B
o
t
h
 
s
i
d
e
s
 
o
f
 
t
h
e
 
m
e
r
g
e
 
p
u
t
 
t
h
e
i
r
 
n
e
w
 
c
h
e
c
k
s
 
i
n
s
i
d
e
 
a


 
 
`
R
U
N
_
*
`
 
c
o
n
d
i
t
i
o
n
a
l
,
 
a
n
d
 
`
g
i
t
 
m
e
r
g
e
 
-
-
u
n
i
o
n
`
 
d
r
o
p
p
e
d
 
t
h
e
 
c
l
o
s
i
n
g
 
`
f
i
`
 
o
f
 
*
t
w
o
*


 
 
d
i
f
f
e
r
e
n
t
 
b
l
o
c
k
s
.
 
O
n
e
 
w
a
s
 
c
o
s
m
e
t
i
c
;
 
t
h
e
 
o
t
h
e
r
 
p
u
t
 
k
i
t
-
0
5
'
s
 
`
c
l
a
s
s
i
f
y
_
t
e
s
t
.
s
h
`


 
 
a
n
d
 
`
s
t
a
l
e
n
e
s
s
_
t
e
s
t
.
s
h
`
 
*
*
i
n
s
i
d
e
*
*
 
`
R
U
N
_
O
B
S
E
R
V
A
B
I
L
I
T
Y
`
,
 
s
o
 
a
 
r
u
n
 
w
i
t
h


 
 
o
b
s
e
r
v
a
b
i
l
i
t
y
 
d
i
s
a
b
l
e
d
 
w
o
u
l
d
 
h
a
v
e
 
s
i
l
e
n
t
l
y
 
e
x
e
c
u
t
e
d
 
n
e
i
t
h
e
r
 
—
 
a
n
d


 
 
*
*
`
b
a
s
h
 
-
n
`
 
p
a
s
s
e
d
 
t
h
r
o
u
g
h
o
u
t
*
*
,
 
b
e
c
a
u
s
e
 
t
h
e
 
f
i
l
e
 
w
a
s
 
s
t
i
l
l
 
*
b
a
l
a
n
c
e
d
*
.
 
A


 
 
s
y
n
t
a
x
 
c
h
e
c
k
 
i
s
 
n
o
t
 
a
 
s
t
r
u
c
t
u
r
a
l
 
c
h
e
c
k
,
 
a
n
d
 
t
h
i
s
 
i
s
 
t
h
e
 
s
e
c
o
n
d
 
t
i
m
e
 
t
h
i
s
 
f
l
e
e
t


 
 
h
a
s
 
t
a
k
e
n
 
a
 
g
r
e
e
n
 
f
r
o
m
 
a
 
c
h
e
c
k
 
t
h
a
t
 
c
o
u
l
d
 
n
o
t
 
s
e
e
 
t
h
e
 
d
e
f
e
c
t
.


-
 
*
*
k
i
t
-
0
5
'
s
 
c
l
a
s
s
i
f
i
e
r
 
a
n
d
 
s
t
a
l
e
n
e
s
s
 
p
r
o
o
f
s
 
s
h
i
p
p
e
d
 
w
r
a
p
p
e
d
 
i
n


 
 
`
i
f
 
[
 
"
$
R
U
N
_
S
T
A
T
I
C
"
 
-
e
q
 
1
 
]
`
,
 
u
n
d
e
r
 
a
 
c
o
m
m
e
n
t
 
s
a
y
i
n
g
 
t
h
e
y
 
"
r
u
n


 
 
u
n
c
o
n
d
i
t
i
o
n
a
l
l
y
,
 
b
e
c
a
u
s
e
 
b
o
t
h
 
a
r
e
 
t
h
e
 
p
r
o
p
e
r
t
y
 
r
a
t
h
e
r
 
t
h
a
n
 
t
h
e
 
s
h
a
p
e
.
"
*
*
 
T
h
e


 
 
c
o
d
e
 
a
n
d
 
t
h
e
 
c
o
m
m
e
n
t
 
s
a
i
d
 
o
p
p
o
s
i
t
e
 
t
h
i
n
g
s
,
 
a
n
d
 
t
h
e
 
c
o
d
e
 
w
a
s
 
t
h
e
 
o
n
e
 
t
h
a
t
 
r
a
n
.


 
 
T
h
e
y
 
a
r
e
 
n
o
w
 
u
n
c
o
n
d
i
t
i
o
n
a
l
,
 
a
n
d
 
t
h
e
 
r
e
a
s
o
n
 
i
s
 
r
e
c
o
r
d
e
d
 
a
t
 
t
h
e
 
c
a
l
l
 
s
i
t
e
:
 
a


 
 
c
h
e
c
k
 
t
h
a
t
 
o
n
l
y
 
p
a
r
s
e
d
 
t
h
o
s
e
 
t
w
o
 
f
i
l
e
s
 
w
o
u
l
d
 
p
a
s
s
 
o
n
 
a
 
c
l
a
s
s
i
f
i
e
r
 
t
h
a
t
 
w
a
v
e
s


 
 
e
v
e
r
y
 
c
h
a
n
g
e
 
t
h
r
o
u
g
h
,
 
s
o
 
s
k
i
p
p
i
n
g
 
s
t
a
t
i
c
 
a
n
a
l
y
s
i
s
 
m
u
s
t
 
n
o
t
 
b
e
 
a
b
l
e
 
t
o
 
r
e
m
o
v
e


 
 
t
h
e
 
p
r
o
o
f
 
t
h
a
t
 
t
h
e
 
c
l
a
s
s
i
f
i
e
r
 
f
a
i
l
s
 
c
l
o
s
e
d
.


-
 
*
*
`
s
e
l
f
_
t
e
s
t
.
s
h
`
 
s
a
y
s
 
t
w
e
n
t
y
-
o
n
e
;
 
t
h
e
 
f
i
l
e
 
p
r
o
v
e
s
 
t
w
e
n
t
y
-
t
h
r
e
e
.
*
*
 
B
o
t
h
 
s
i
d
e
s
 
o
f


 
 
t
h
e
 
m
e
r
g
e
 
c
a
r
r
i
e
d
 
a
 
c
o
u
n
t
 
t
h
a
t
 
h
a
d
 
d
r
i
f
t
e
d
,
 
a
n
d
 
`
v
a
l
i
d
a
t
e
.
s
h
`
 
r
e
c
o
m
p
u
t
e
d
 
i
t


 
 
w
i
t
h
 
a
 
p
a
t
t
e
r
n
 
t
h
a
t
 
*
*
o
m
i
t
t
e
d
 
`
e
x
p
e
c
t
_
r
e
d
_
s
c
r
i
p
t
`
*
*
 
—
 
w
h
i
c
h
 
i
s
 
w
h
y
 
k
i
t
-
0
5


 
 
h
a
r
d
c
o
d
e
d
 
`
2
1
`
 
i
n
s
t
e
a
d
 
o
f
 
c
o
u
n
t
i
n
g
.
 
T
h
e
 
p
a
t
t
e
r
n
 
n
o
w
 
c
o
v
e
r
s
 
a
l
l
 
f
o
u
r
 
h
e
l
p
e
r
s


 
 
(
`
e
x
p
e
c
t
_
r
e
d
`
,
 
`
_
c
h
e
c
k
`
,
 
`
_
l
a
n
g
`
,
 
`
_
s
c
r
i
p
t
`
)
,
 
t
h
e
 
h
e
a
d
e
r
 
r
e
a
d
s
 
t
w
e
n
t
y
-
t
h
r
e
e
,


 
 
a
n
d
 
t
h
e
 
c
o
m
p
o
s
i
t
i
o
n
 
i
s
 
s
t
a
t
e
d
 
i
n
 
b
o
t
h
 
f
i
l
e
s
:
 
*
*
8
*
*
 
n
a
m
e
d
-
c
h
e
c
k
,
 
*
*
6
*
*


 
 
p
e
r
-
l
a
n
g
u
a
g
e
 
m
u
t
a
t
i
o
n
,
 
*
*
2
*
*
 
p
r
o
o
f
-
i
n
v
e
r
s
i
o
n
,
 
*
*
7
*
*
 
w
h
o
l
e
-
g
a
t
e
.
### Changed

- **`templates/compose/docker-compose.yml` — the vendor config mounts are anchored
  to `${KIT_COMPOSE_DIR:-.}`.** The file is no longer copied into the service, so
  a bare `./` resolves against the service, where `otel-collector.yml` no longer
  is; and Docker's answer to a missing bind source is to **create a directory**, so
  all four backends died with `read /etc/tempo/tempo.yaml: is a directory` —
  naming a file type rather than the thing that is wrong. `docker compose config`
  renders the same project either way, and every static check was green. The
  default `.` is the directory holding this file, so a hand-copied stack is
  unchanged; `bin/dev` sets the variable to the fetched tree.

- **`templates/compose/docker-compose.yml` — Grafana no longer downloads a plugin
  on first boot** (`GF_INSTALL_PLUGINS_PREINSTALL_DISABLED=true`). Grafana 11.3
  preinstalls `grafana-lokiexplore-app` and holds the sqlite lock its own
  migrations want, so a cold start took anywhere from 26s to over **180s** to
  answer `/api/health` — a network call in a dev loop, and one that made the stack
  unstartable for an air-gapped developer. Nothing kit ships uses that plugin:
  both dashboards read Loki through the provisioned datasource and the alert rules
  are PromQL. It is *configuration*, not a modification — the AGPL condition is
  about not building a `grafana/*` image. **The Grafana healthcheck budget was
  left at its shipped value**: the wrong fix, raising the retries, would have hidden
  the network dependency and left the loop unusable offline. With the cause
  removed, Grafana answers at ~26s against a 65s budget and the whole stack is up
  in 76s.

### Fixed

- **`expect_red_check` reported a successful match as a failure, once the output
  was large enough.** It read the checker's verdict through
  `printf '%s\n' "$out" | grep -qF "FAIL $want"`. `grep -q` exits the instant it
  matches, so `printf` takes SIGPIPE while still writing; `set -o pipefail` then
  reports 141 for a pipeline that **succeeded**, and a passing breakage reads as
  "the gate went red, but NOT via `<the named check>`".

  It surfaced on breakage 25, whose check emits several hundred lines and is
  therefore the first output in this file big enough to overflow the 64K pipe
  buffer. Breakages 7-24 all pass on smaller output, which is the worst shape a
  latent defect can have: it presents as a failure of the thing under test while
  being a failure of the harness reading it. Measured rather than reasoned
  about — 2000 lines of output still returns 0 and 5000 returns 141, same match,
  same grep. The threshold is a property of the pipe buffer and would move with
  the machine, so the fix is to **stop piping** (a `case` pattern) rather than to
  bound the output.
- **A check that a comment could satisfy.** The `-count=1` assertion was a plain
  substring test over the go step's `run:` body, and that body's own comment
  block names the flag twice while explaining why removing it would be a
  mistake — so deleting the flag from the command left the check green. Found by
  deliberately breaking the tree, not by reading it. `strip_shell_comments`
  now removes comments while preserving `#` inside quotes, and it is applied
  wherever a check greps a `run:` body.
- **`templates/tier/go/*.go` was never gofmt'ed, and nothing checked it.** The
  gofmt check covered `templates/otel/go/*.go` only, so the new tree shipped
  with doc headings Go 1.19 would rewrite. It is checked now, over both trees.
- **`python3 -m py_compile` wrote `__pycache__/` into the template tree**, and
  the two checks that walk `templates/tier/<lang>/` then died with
  `IsADirectoryError` — a gate that went red on its own artefacts. The parse is
  now `compile()`, which is the same check with no filesystem side effect, and
  both checks skip non-files and *report* a stray directory rather than
  crashing on it.

- **kit-03 rebased onto a master that moved nine commits underneath it.** The
  branch point was `badcc2a`; master gained the move of the reusable workflow to
  `.github/workflows/` (`d42aebb`), kit calling its own workflow (`fb664a9`), a
  real Dockerfile parser and two real Dockerfile bugs (`9a8c3d7`), the gate
  bootstrapping its own dependencies (`a1cad0d`), and the hadolint asset rename
  from `darwin-*` to `macos-*` (`9b3dbeb`). Five files conflicted and all five
  were resolved as unions rather than as a choice between sides:
  - `tests/self_test.sh` — the breakage list is **19**, not master's 18 and not
    kit-03's 12. Master's 7-10 (four ways to break the documented `uses:` string
    against the real path), 11-12 (the two Dockerfile defects) and 13-18 (one
    semantic mutation per language) are intact, and kit-03's `2b` and its
    rewritten recipes for 2 and 4 are kept. Picking a side would have deleted a
    check that currently works, and the self-test's claim is that every breakage
    is caught by a *different* one.
  - `tests/validate.sh` — kit-03's `observability` phase, the `dev_escape_hatch`
    execution check, the eleven observability checks, and master's `callable path`
    check, `tests/bootstrap.sh` wiring and the whole-tree `yamllint` are all
    present. kit-03's own walk of `templates/compose` was **dropped as
    redundant**: master's `yamls_of_the_tree` enumerates by `git ls-files` and
    reaches the same files plus the rest of the repo, and two loops over one set
    of files report every problem twice and disagree about which is
    authoritative.
  - `AGENTS.md`, `README.md`, `CHANGELOG.md` — both sides' entries, with the
    breakage counts updated to 19 and the CHANGELOG's two `### Added` sections
    folded into one.
  - The collector and compose work was re-pointed at `.github/workflows/`
    rather than reintroducing the old path, and `fb664a9`'s local self-call is
    untouched.
- **The self_test count was a hardcoded string in two places, and both were
  wrong the moment either side added a breakage.** `self_test.sh`'s summary line
  and `validate.sh`'s check label now both **count** the recipes, so the number
  cannot drift from what the file proves. A new check asserts that every
  breakage the header documents has a recipe and every recipe has a header
  entry — the union requirement stated as an assertion, so the next packet that
  adds a breakage without documenting it (or documents one without writing it)
  gets a red gate instead of a stale sentence.

### Added

- **The observability stack** (PLAN.md §7b). Observability is ON BY DEFAULT and
  worked on in dev: `bin/dev up` brings up the OTel collector and the four LGTM
  backing services, and a service with nothing configured exports into them
  because `<SERVICE>_OTEL_ENDPOINT` *defaults* to the collector that ships with
  the stack. `<SERVICE>_OTEL_ENDPOINT` is the only contract (core D16); the
  shipped collector is just its default value, and unsetting it is a genuine
  no-op implemented with `OTEL_SDK_DISABLED`.
  - `templates/compose/otel-collector.yml` — OTLP **and** container-stderr
    receivers, the redaction allowlist **derived from core's schemas**, the
    `spanmetrics` connector, and fan-out to Tempo/Loki/Mimir. Every endpoint is
    a `${env:...}`; the gate fails on a literal.
  - `templates/compose/{tempo,loki,mimir}/` and
    `templates/compose/grafana/provisioning/` — vendor **configuration** and
    Grafana provisioning as files: three datasources, the dashboard provider, two
    dashboards and three alert rules, all working on first load.
  - `templates/compose/docker-compose.yml` — the four backing services, pinned
    to exact tags, healthchecked, memory-bounded, in an `observability` profile.
    **Grafana, Loki, Tempo and Mimir are AGPL-3.0 and ship UNMODIFIED**;
    `tests/validate.sh` fails on a `build:` stanza on any of them.
  - `templates/compose/.env.example` — every `${KIT_*}` the stack reads, with
    the port block documented.
  - `tests/canary_test.sh` — plants a canary in ten shapes a leak could take
    against a real collector and asserts it reaches no exporter, **and** that the
    allowed data survived.
  - `tests/no_telemetry_in_readiness.sh` — proves a service starts, serves and
    reports healthy with the collector killed, and that a collector whose three
    backends all refuse connections stays healthy, does not restart and does not
    enter a retry loop.
  - The six `templates/otel/<lang>/*.snippet` files now honour
    `<SERVICE>_OTEL_ENDPOINT`, default to the shipped collector, implement the
    free no-op with `OTEL_SDK_DISABLED`, record `error.type` and never
    `error.message`, and emit **exception log records** rather than the
    deprecated `exception` span event.
  - `templates/AGENTS.md` — an Observability section, so the endpoint contract
    and "telemetry is never in a readiness path" reach the service repo where a
    probe would actually be written.

- **The secret scanner.** A `secrets` job in `ci.reusable.yml` running
  **gitleaks 8.30.1** over the adopting repository's **full history**, with
  `--redact`. It is the one job in the workflow with **no opt-in**: an opt-in
  security control is not a control, and a secret scanner that only warns is a
  report. `fetch-depth: 0` is load-bearing — the runner default is a shallow
  clone, and a secret committed and deleted in one PR is still in the packfile
  of anyone who cloned. **Adopting this can turn a repo's first build red**;
  README says what to do, and the first thing to do is rotate.
  - gitleaks rather than trufflehog: trufflehog is **AGPL-3.0**, and it is the
    only candidate that verifies live credentials against the issuer's API,
    which for a fleet whose CI has network access is the wrong behaviour for a
    scanner. gitleaks is MIT, a static binary, and makes no network call.
  - `tests/gitleaks_gate.sh` is the **one** scan, called by both the `secrets`
    job and `tests/validate.sh`. A scanner whose CI and local invocations have
    drifted is two scanners, and the one that goes red is whichever nobody runs.
  - `.gitleaks.toml` — the allowlist, and **nothing else**. `extend.useDefault`
    so the rules stay gitleaks', and every `[[allowlists]]` entry must carry a
    `description` of at least 40 characters. An allowlist that grows and is never
    pruned is not an allowlist, it is a deferred disclosure. A `.gitleaksignore`
    fails the gate.
- **A `zizmor` job** (opt-in, `zizmor: 'true'`), running the GitHub Actions
  security audit on the adopting repo's own workflows. `tests/zizmor_gate.sh`
  counts `unpinned-uses` and prints the count and the reason on every run, and
  **fails on every other audit**. It is recorded, not baselined: see
  `DECISIONS.md` (MD10a), where the pin trade is costed in three options and none
  of them has been taken.
- **`templates/secrets/`** — the runtime credential-leak canary. A
  **language-neutral contract** (`templates/secrets/README.md`) and the **Go
  adapter**, with five vectors each carrying its own red proof: log/stdout/stderr,
  unknown serialisation fields, the whole error chain, keys present-but-empty,
  and Go type coverage.
  - It exists because **nothing off the shelf does this**. gosec's
    `credentials.Match` has no `*ast.CallExpr` case, so it finds literals and not
    a token passed to a logger. Bandit matches `ast.Constant` only. Brakeman's
    secret check is off by default. Of 268 Semgrep taint rules, **zero** intersect
    CWE-532.
  - The canary is **assembled at run time**, never written as a literal, so it is
    safe to commit and needs no allowlist entry. Two checks enforce that.
- **Ten new checks** in `tests/validate.sh` for the above, including one that
  asserts the scanner's **behaviour** by executing it: over a throwaway git
  repository holding a detectable credential, the scan must find it, must name
  the rule that fired, must not print the value, and must still find it after the
  file is deleted.
- **Eleven new `self_test` breakages**, each asserting that one *named* check
  went red: a credential in history, a credential in the working tree,
  `--redact` removed, the scan narrowed to the last commit,
  `pull_request_target` added, the `secrets` job made `continue-on-error`, four
  ways of breaking the canary's reference type, the canary committed as a
  literal, and `unpinned-uses` baselined in `.github/zizmor.yml`.
  - These were numbered 13–23 on `worker/kit-04` and are **24–34** here.
    kit-04's other six breakages (its 24–29) were its copies of the six language
    mutants, which master already carried as 13–18; those copies are dropped
    rather than renumbered, so no rule is proved twice under two numbers. The
    union is **34 breakages**, master's 1–23 unmoved.
  - `self_test` counts itself by grepping its own recipe calls, the same
    expression `validate.sh` uses for its label, so the summary and the gate
    label cannot disagree. It was a literal `18` in two files kept in step by
    hand, and for one commit a second runtime counter beside it.
- `tests/gitleaks_gate.sh` and `tests/zizmor_gate.sh`, `chmod +x` and asserted
  executable — they are run by the reusable workflow from a service's repository,
  so a missing executable bit is a `secrets` job that dies in thirteen repos.

### Fixed

- **`artipacked` (9 findings) in `ci.reusable.yml`.** Every `actions/checkout`
  now sets `persist-credentials: false`. No job in the file pushes, so a token
  left on disk after a checkout is a credential that outlives the job for no
  reason — and every job here runs `upload-artifact`, which is the combination
  the audit exists to catch. Found by zizmor, and fixed rather than baselined.
- **`.github/zizmor.yml` is no longer walked for stray copies of the workflow.**
  The `callable path` check reported `tests/self_test.sh` as "a second workflow
  declaring `workflow_call`" — it names the key in a comment explaining breakage
  8. A check that fires on the file proving it wrong is a check people delete.
- **Fetched tools now land in `tests/.bin/`, not `.venv/bin/`.** `.venv` is
  gitignored and `tests/self_test.sh` copies the tree twenty-nine times per run,
  so hadolint and gitleaks were being re-downloaded once per copy. The copy
  carries `tests/.bin`; it does not carry `.venv`.
- **The self_test control run no longer fails on a missing executable bit.**
  `cp -R` does not preserve mode bits on macOS, so every throwaway copy arrived
  with `tests/*.sh` non-executable and the new handed-out-scripts check failed in
  all of them — for a reason that had nothing to do with any breakage under test.

### Changed

- `tests/requirements.txt` pins **`zizmor==1.30.1`**, and an auditor is pinned
  where a parser is not: a new release adds findings, and a gate whose result
  depends on when it last ran is a gate nobody can reason about. zizmor comes
  from PyPI rather than a release archive because it publishes no checksums file,
  and pinning its archives would mean pinning hashes we computed ourselves.
- `kit_bootstrap_binary` takes an asset-name template and an inner-path, so it
  can install a tarball as well as a bare binary, and its sha256 table is keyed
  by **exact asset filename**. It used to be keyed by `macos-arm64`, which forced
  every caller's asset name to be derivable from `<name>-<os>-<arch>` — true for
  hadolint, false for gitleaks, and the reason this function could not install a
  second tool. There are now three spellings of the OS name in play
  (`macos`/`darwin`/`apple-darwin`) and all three are mapped explicitly.
- The `callable path` check's copy-walk skips `.bin` and shell scripts.

### Earlier

- A **`callable path` check** in `tests/validate.sh`: the reusable workflow
  exists at the path callers are documented to use, it declares
  `on: workflow_call`, every real `uses:` that names kit — in `README.md`,
  `AGENTS.md` and this repo's own workflow files — is exactly that path,
  `kit`'s own CI calls it with the local `./` form, and there is exactly one
  copy of it in the tree. The failure it exists for: for six months the file
  sat at `workflows/ci.reusable.yml`, the README told every reader to call
  `cafaye/kit/workflows/ci.reusable.yml@master`, GitHub resolved that to
  nothing, and **every check in the suite was green throughout**. A layout bug
  and a documentation bug that agree with each other are invisible to any check
  that reads only one of them.
- `tests/bootstrap.sh` — the gate now installs its own dependencies.
  `bash tests/validate.sh` is the **whole procedure on a clean clone**: it
  resolves an interpreter, builds `.venv` and pip installs
  `tests/requirements.txt` on first run, printing a `note:` line. `AGENTS.md`
  and the README no longer instruct anyone to run a two-line step first.

  This was the second time the gate failed on arrival. It exited 1 with
  `no python with PyYAML: pip install -r tests/requirements.txt` on every fresh
  clone and every CI runner, because it preferred the gitignored `.venv` and
  fell back to a `python3` that has no PyYAML. The prerequisite was documented,
  which is exactly why it got skipped: by every runner, and by anyone who
  cloned without reading the file first.
- `yamllint` now lints **every** YAML in the tree, enumerated by `git ls-files`
  rather than a hand-kept list of the two compose templates, and a missing
  yamllint is a `FAIL` instead of a `SKIP`. kit ships the config and a repo
  that copies it lints its own CI against it on day one, so a YAML that breaks
  the config greets the first adopting repo with a failure nobody authored. A
  skip here would hide a broken config behind a missing tool on precisely the
  machine that had not run the gate before.
- **`lint/hadolint.yaml`, and real lint on all seven Dockerfiles.** They were
  the only artifact in the tree with no parser at all — seven `SKIP ... (no
  parser for this file type)` lines, honest and completely uncovered, on a file
  every adopting service inherits. They now get three layers: hadolint
  (required, pinned to 2.15.1, verified against hadolint's published
  `checksums.sha256`); a non-root / no-`:latest` / no-`ADD` check for the two
  properties hadolint cannot see; and a check that each template's own
  STRICTNESS NOTES state the non-root guarantee to the reader deciding whether
  to adopt the file.

  **hadolint found a real defect on its first run.** `docker/Dockerfile.python`
  ran `pip install uv` with no version, so the resolver's own version decided
  what every build resolved to — an unpinned build input in the one image whose
  whole point is a frozen resolution. Now `ARG UV_VERSION=0.5.11`, in step with
  the `uv` pin in `templates/mise.toml`.

  **The third check found a documentation bug in the same run.**
  `Dockerfile.bun`'s STRICTNESS NOTES said *"The official image has no
  unprivileged user, so we create one."* `oven/bun:1.3.12-slim` ships `bun` at
  uid 1000 (verified against the running container) and the `useradd` that note
  described was never in the file — the note described a different Dockerfile
  than the one being read. Three of the seven said nothing about non-root at
  all; all seven say so now.
- The one ignored hadolint rule is DL3008 ("pin apt versions"), argued in
  `lint/hadolint.yaml` rather than assumed: a hardcoded `build-essential=12.9`
  in a template thirteen repos copy is a version thirteen people must remember
  to bump, and the day Debian drops that build every one of them fails at once —
  a correlated outage caused by a security patch landing. A service that wants
  reproducible apt resolution pins in its own repo, which is the
  "callers override, they never fork" rule.
- `expect_red_check` in `tests/self_test.sh`, which asserts that one *named*
  check reported `FAIL` rather than merely that the gate went red. Breakages
  7-10 use it, so the check written for each layout/documentation drift is
  proven load-bearing instead of being one of forty checks that could have
  gone red for an unrelated reason.
- `.github/workflows/ci.yml` — kit calling its own reusable workflow with
  `uses: ./.github/workflows/ci.reusable.yml`. The repository that defines the
  standard is now the first repository held to it, and if the callable path ever
  breaks again it is red on kit's own commit rather than discovered by the
  first service that adopts it.
- A `none` value for the `language` input, and a `none` job that runs the
  calling repository's own `tests/validate.sh`. **This is a bug fix, not a
  feature.** The workflow was uncallable by any repository without a service
  manifest — which includes `kit`. `language` is `required: true` and every
  value in `options` named a toolchain, so `uses: ./.github/workflows/ci.reusable.yml`
  had no input that could make it resolve. The job fails when `tests/validate.sh`
  is absent, because a config gate with no gate in it is the same defect as a
  coverage threshold left at `0`.
- `workflows/ci.reusable.yml` — a `bun` job: `bun install --frozen-lockfile` →
  `bun run typecheck` → `bun test`, with an opt-in coverage step. Exists because
  `guard` was hand-rolling a whole workflow for want of one; a repo that adopts
  it can collapse that file to a `uses:` call.
- `workflows/ci.reusable.yml` — an opt-in `telemetry` input (string, default
  `'false'`) and a `telemetry` job that runs the W3C traceparent conformance
  suite for all six languages in a matrix. Opt-in so that adopting kit never
  turns a green repo red.
- `docker/Dockerfile.bun` and `templates/bin-prime/bun.sh` — the other two
  artifacts a language ships, so `bun` is a first-class `language` value.
- `templates/bin/dev.sh` — the local developer loop. `up --wait`, migrate, seed
  an admin, print the URLs. Idempotent; fails loudly and stops *before*
  migrating rather than half-starting.
- `templates/compose/otel-collector.yml` — receiver, batch processor, and a
  `debug` exporter that writes to the collector's own stdout. Sends nothing
  anywhere, by default and by gate. **Superseded by kit-03** below: the
  collector now fans out to Tempo, Loki and Mimir, because observability is on
  by default. The `debug` exporter and the "no literal endpoint" rule stay.
- `templates/otel/<lang>/` — per language: a stdlib `traceparent.*` codec, an
  executed conformance suite, an SDK wiring snippet with a documented
  "when to use which" README, and a statement of the W3C sections implemented.
- `templates/otel/pins.md` — the OTel versions the snippets reference, at the
  otel root because it covers all six languages. kit vendors nothing.
- `README.md` — sections for the local stack and for trace propagation,
  including a worked example of a service adopting propagation, and an accurate
  description of what the gate actually does.


### Fixed

- **`tenant_id` was silently stripped from every trace and log resource.** The
  `redaction/cafaye_metrics` processor listed the private stash names
  (`cafaye.stashed.tenant_id`, `cafaye.stashed.account_id`) in its
  `ignored_keys`; `redaction/cafaye_traces` and `redaction/cafaye_logs` did not.
  The redaction processor deletes every attribute it does not exempt, so on
  traces and logs it deleted the carrier the restore was about to read, and the
  restore put `tenant_id` back from an empty source. Per-tenant metric totals
  worked; per-tenant trace and log identity did not, with no error anywhere.
  **Every static check passed on the broken tree** — being *stashed* and being
  *exempted* are different questions and only the second survives contact with a
  running collector. Two assertions added: every private stash name must be
  exempted in all three processors, and the three `ignored_keys` lists must be
  equal.
- **The collector's `_total` rename never fired, so every dashboard panel
  rendered "No data".** `transform/cafaye_metrics_labels` matched
  `IsMatch(name, "\\.calls$")` inside a YAML *single-quoted* scalar, where a
  backslash is not an escape — so OTTL received a regex requiring a literal
  backslash and it matched no metric, ever. The processor was wired in and
  documented at length. The pattern now avoids escapes entirely.
- **Every Grafana panel had `"datasource": null`**, which Grafana resolves to the
  *default* datasource — Mimir. All LogQL panels and the TraceQL panel were being
  sent to a Prometheus API and rejected (`parse error: unexpected character:
  '|'`); 12 of 15 panel queries were invalid. The alert rules grouped on
  `otel.status_code`, which is a parse error in PromQL because OTLP ingestion
  mangles dots in label names to underscores. Both fixed, and a check now holds
  it: every query must name the backend that can answer it, and every PromQL
  expr must use the underscored spelling.
- **`tests/self_test.sh` had two breakages whose recipes no longer applied.**
  `edit` correctly refuses a stale pattern, so the gate went red on breakage 2
  and never reached 3, and then again on 4. Both recipes rewritten against the
  shipped config; a twelfth breakage added covering a *missing* backend
  exporter, which the set-difference check could never have seen.
- **`tests/no_telemetry_in_readiness.sh` proved less than it claimed.** It passed
  bare `host:port` to the `otlphttp` exporters, which made the collector exit(1)
  with `endpoint must be a valid URL` — indistinguishable from the bug the test
  exists to catch. Its stand-in service was `traefik/whoami`, which ships no
  `wget` (so the probe never ran) and answers every path with 200 (so its
  `/readyz` could never fail). Replaced with a real two-service stack whose
  `/readyz` is proven to go 503 before the "still serving" claim means anything.
- **The canary's redaction receipt was flaky, 1 pass in 3.**
  `docker logs ... | grep -qi` under `set -o pipefail` is a SIGPIPE race: `grep -q`
  exits at the first match, so `docker logs` dies with 141 whenever the log is
  large enough to still be writing. The log is now captured to a file. The
  spanmetrics assertion had the same shape — the connector flushes on its own
  interval — and is now polled with a deadline. Both are PASSes, not NOTEs.
- **The local compose stack could not start.** `otel-collector.yml` resolves its
  values from the collector's own process environment, and Docker Compose does
  not inject the `.env` values it substitutes into containers. Every one resolved
  empty and the collector exited with `processors::memory_limiter: ... must be
  greater than zero`, which names a memory limiter rather than the missing
  environment. The nine `KIT_OTEL_*` values are now passed into the collector
  container. The stack parses, passed every check kit had, and did not work.
- The compose **port check** flagged the collector's in-network bind addresses
  (`0.0.0.0:4317`) as hardcoded published ports. It now reads the parsed
  `ports:` lists, so it can tell a published port from a bind address, and its
  failure message names the service and the value.
- The elixir conformance suite failed 2/13 on two tests that called
  `.outbound_headers` as map access on a struct with no such field, where the
  rest of the file uses the local `outbound/1` helper.
- The elixir "new identifiers are random" test rebound its `seen` set inside a
  `for` comprehension, shadowing the outer binding. The uniqueness assertion
  compared 256 draws against an empty set and could never fail.


### Changed

- **The port block.** Every published host port moved into **15000-15999**,
  one hundred per service: 15000 Grafana, 15500 Postgres, 15600 NATS client,
  15700 NATS monitoring, 15800 Redis, 15900 Tempo, 15901 Loki, 15902 Mimir. Not
  5432/4222/6379, which are the two or three most likely things already
  listening on a developer's machine — and `bin/dev` is the first command a new
  person runs. The gate asserts membership of the block and no reuse, as a RANGE
  rather than a list, so adding a service does not mean editing a check.
  **Unverified against the rest of the fleet**: the block is claimed
  fleet-wide and nothing coordinates it across repos. A sibling repo's scratch
  container was observed holding 15500 during kit-03's own verification.
- **`templates/compose/otel-collector.yml` no longer ships `debug` only.** It
  fans out to three backends now, so the privacy boundary is restated as what it
  can actually be: every endpoint a `${env:}`, the exporter set exactly those
  three plus the local `debug`, and a `redaction/*` processor in every pipeline
  before `batch` and therefore before every exporter.
- `templates/bin/dev.sh` — `STACK_TIMEOUT` 120s → 180s (five more containers,
  four with a real initialisation), brings up the `observability` profile by
  default, prints the wall-clock, and prints the observability URLs. The
  escape hatch is `KIT_DEV_PROFILES=`.
- `templates/compose/docker-compose.yml` — the collector's healthcheck probes
  its real `health_check` endpoint instead of printing its component list, and
  the four stores' healthcheck budgets were raised after measuring them.
- `tests/validate.sh` gained an `observability` phase and a `--no-observability`
  flag; both docker-requiring proofs SKIP loudly when docker is absent.

- **The reusable workflow moved to `.github/workflows/ci.reusable.yml`.** It was
  at `workflows/ci.reusable.yml`, and GitHub documents that subdirectories of
  the workflows directory are not supported — so the `uses: cafaye/kit/workflows/
  ci.reusable.yml@master` line in the README resolved to nothing. No repository
  in the fleet was calling it. It is now a **move, not a mirror**: one file, at
  the only path GitHub will resolve, so there is no second copy to diverge.
- `self_test.sh` grew from 5 breakages to **19** — master's 18 plus kit-03's
  `2b`, which deletes a backend exporter entirely. A set-difference check on the
  exporter set catches an exporter that should not be there and is silent about
  one that is *missing*, and a missing exporter ships a stack that collects
  everything and prints nothing. Six are per-language semantic mutations, each
  against a different W3C section, so
  **every** suite is proven able to fail rather than assumed to. A mutant that
  fails to compile is its own verdict rather than a pass, a missing toolchain is
  a skip that fails the run, and an unmatched mutation is a hard failure so the
  proof cannot rot into proving nothing.
  Both sides' recipes for breakages **2** and **4** were kept, and they are not
  the same recipe: kit-03's rewrote them because they named strings that no
  longer exist — `exporters: [debug]` stopped being the traces pipeline when it
  fanned out to three backends, and a literal `${KIT_POSTGRES_PORT:-5432}`
  stopped existing when the stack moved into the 15000-15999 port block.
  `edit` refuses an unmatched pattern, so a stale recipe fails loudly instead of
  passing silently; that is correct, and it is also how a self_test stops testing
  the thing it names.
  The count in the summary line is now **counted from the recipes** rather than
  written down, and a check asserts that every breakage the header documents has
  a recipe and every recipe has a header entry — so the two cannot drift.
- `validate.sh` reads the CI workflow's `language` options and requires a
  Dockerfile, a `bin/prime` and a `[tools]` pin for each — "half a language is
  worse than none", enforced rather than trusted. It also requires `language`
  options and the job set to be the same list, a ref on every `uses:`, no
  branch refs, and every `${{` to close.
- New checks: the otel-collector environment wiring, that every `*.snippet`
  carries an install line and a pinned version, that every snippet **parses in
  its own language**, and that the README's documented callers only pass inputs
  the workflow actually declares.
- The `telemetry` CI job is a matrix while the seven language jobs stay one-per-
  language: a matrix is right for six stdlib test suites that share nothing, and
  wrong for six toolchains that install different things.
- The `telemetry` input is a string rather than a boolean, because GitHub
  coerces the bare word `false` in some positions and `if: inputs.telemetry` is
  a trap as a result.

### Fixed

- A `pipefail` bug in the new staleness test, where a successful `grep` was
  masked by the classifier command's own deliberate non-zero exit. The output is
  captured to a variable and the status read from the command, never from a pipe:
  **a piped exit code is the exit of the last stage.** The same trap, one level
  down from the one `self_test.sh` already documents at breakage 6.
- The fail-closed tier was stated in **two** places — a string in `classify.py`
  and a rule in `rules.json` — and the self-test breakage written to invert it
  left the suite **green**, because the headline case never reached the line that
  was broken. A property asserted in two places is asserted in zero. Both facts
  now live in `rules.json` alone, and the counterexample is one token.
- A `current`-at-head pin was reported as `unknown`. That is the state a reader
  learns to ignore, which makes it the expensive direction to get wrong.

### Changed

- `AGENTS.md` records that the classifier **fails closed** as a rule about code
  and not about data, and carves `core/`'s two programs out of the config-only
  rule explicitly — stdlib only, nothing imports them, no committed output — so
  that the exception is bounded rather than the start of a trend.
- `AGENTS.md` and `README.md` describe twenty-three breakages rather than
  eighteen, and the phase list gains the classifier and staleness phases.

### Not done, and why

- **No repository was migrated.** `vendir.yml` files for `muse`, `pantry` and
  `caf` are shipped as templates with the exact steps in
  `core/renovate/SETUP.md`; applying them is thirteen pull requests in thirteen
  repositories, and this change is scoped to `kit`.
- **`oasdiff` is not wired in.** It is the right tool for the OpenAPI half — a
  static Go binary, a live GitHub Action, and **755 level-tagged checks** measured
  by running `oasdiff checks changelog` at v1.32.1 — but `core`'s fan-out is raw
  JSON Schema, and adding a pinned binary would make `kit` a repository with a
  dependency, which `AGENTS.md` forbids.
- **`expectOperations` is untouched and stays in `cafaye-ts`.** vendir has no
  opinion about whether a copy should have been allowed to change size, and a
  guard moved into a tool that cannot enforce it is a guard deleted.
- **Three of the fleet's five parity guards still skip** when the core checkout
  they compare against is absent. Fixing that is independent of vendir, more
  urgent than vendir, and belongs to the repositories that own them.


### Earlier (kit-01)

- `README.md` — what kit is, how a service repo adopts it, adoption checklist.
- `AGENTS.md` — conventions for this repo.
- `workflows/ci.reusable.yml` — reusable GitHub Actions workflow. Inputs
  `language` (go|ruby|elixir|python|node|rust), `working-dir`, `versions`, and
  `coverage-fail-under`; one job per language, each install → lint → test →
  coverage. No job builds or pushes an image.
- `lint/` — `yamllint.yml`, `golangci.yml`, `rubocop.yml`, `eslint.config.mjs`,
  each with its strictness decisions written down.
- `docker/Dockerfile.{go,rust}` — multi-stage, distroless final.
  `docker/Dockerfile.{ruby,elixir,python,node}` — multi-stage, `*-slim` final.
  All non-root, none on `:latest`, all versioned through build args.
- `templates/bin-prime/{go,ruby,elixir,python,node,rust}.sh` — worktree
  primers; exit 0 only when the tree is genuinely ready.
- `templates/mise.toml` — per-language tool sections with placeholder versions.
- `templates/AGENTS.md` — skeleton repo-conventions file.
- `tests/validate.sh` + `tests/requirements.txt` — the gate, and its deps.
