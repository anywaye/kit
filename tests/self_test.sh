#!/usr/bin/env bash
#
# kit's proof that `tests/validate.sh` is able to fail.
#
#   bash tests/self_test.sh
#
# WHAT THIS IS FOR
#   A gate that only ever goes green is a report, not a gate. This script copies
#   the tree to a throwaway directory, breaks it once per kind of check, and
#   asserts the gate goes RED each time. Each breakage must be caught by a
#   *different* check, so a passing self_test means the checks are independent
#   and not one lucky assertion standing in for all of them.
#
# THE EIGHTY BREAKAGES, and one GREEN control (20 from the tier work, 21
#                               from the fan-out work, 24-26 from the fleet gate,
#                               27-32c from the lint work, 33-40 from the
#                               staleness/parity work, 41-51 from the secrets
#                               work, 52-60 from the fetched-stack work, 61-62
#                               from the licence, 68-74 from the shared-cluster
#                               work, 75 from the rename that disarmed the
#                               fleet check, 76-77 from the bin/dev commands the
#                               documentation promises, 78-79 from the second
#                               callable standard, 89 from the `options:` key
#                               that took the fleet's CI down for two days
#                               without a red check, 90-92 from the account
#                               boundary; 18 shared before the
#                               lint packet)
#   1. delete a language template   -> the artifact-presence check goes red
#   68. .env.example's Postgres tag disagrees with compose's default -> the
#        agreement check goes red. This is the defect that SHIPPED: the stack
#        ran 16.6 on every developer's machine while the compose file, the
#        README and the CHANGELOG all said 17, and commit 48689e6 fixed the
#        compose file and left the file that overrides it alone.
#   69. the tag is switched back to an alpine variant -> red, because pgvector
#        is a glibc-linked layer and does not load on musl.
#   70. the init script is never mounted -> red. Nothing reports a cluster with
#        one database and no per-service roles except this.
#   71. the connection budget set below what the topology needs -> red.
#   72. a generated config stops setting `application_name` -> red.
#   73. a generated config carries a POOLER WORKAROUND -> red. The invisible
#        one: `prepare: :unnamed` on a fleet with no pooler is slower and looks
#        correct, so this list is the only way anyone finds out.
#   74. `DECISIONS.md` deleted -> red. Seven places reference it; it did not
#        exist until this packet, so nothing had ever checked.
#   75. a service runs its own postgres IMAGE, with no published port for
#        another check to report -> red. The regression this packet's own
#        earlier commit shipped: making the cluster a BUILT image renamed kit's
#        from `postgres` to `kit-postgres`, which silently disarmed the fleet
#        check that names a service running its own copy of the platform.
#   76. `bin/dev` stops dispatching a command four files tell the reader to run
#        -> red. `bin/dev db grant` was documented in four places and did not
#        exist.
#   77. `bin/dev` keeps the command but loses the SUBCOMMAND -> red. The harder
#        half: a check that only asks "is `db` dispatched" is green here.
#   78. a COPY of a declared standard parked at another path -> red. The
#        original defect, still caught after kit-32 widened the check.
#   79. a callable workflow at a path kit does not DECLARE -> red. The new one:
#        the widening must exempt declared paths and nothing else, or it has
#        stopped being a check.
#   90-93. from the account boundary. 90 removes `FORCE ROW LEVEL SECURITY` from
#        the substrate — the setting that is in no guide and that no lint in this
#        fleet checked for before `templates/database/tenancy/` existed, and the
#        one whose absence leaves a service with policies, `relrowsecurity = true`
#        and an owner that reads every account's rows. 91 makes a driver stop
#        READING `assertions.txt`, which is the failure that turns six thin
#        drivers into six decorations: the test still runs and still passes, and
#        now asserts "no red rows" about an unknown number of assertions. 92 makes
#        the manifest and the proof disagree, which is the whole reason the
#        manifest exists as a SET rather than a count.
#        93 makes `advisor.sql` and the fixtures that trip its rules stop
#        agreeing, and it is the only breakage whose subject is a LIVE
#        database, which `--static-only` never runs. Its recipe existed while
#        this header did not mention it, and `self_test_claims` is what said so:
#        "recipe proves breakage 93 but the header does not document it". A
#        header that drifts from the recipes is a second, unchecked copy of the
#        truth.
#   2. add a collector exporter    -> the privacy check goes red
#   2b. DELETE the tempo exporter   -> the same check goes red from the other
#        side. A set difference only catches the extra; this catches the
#        missing, which is the mistake that ships a stack that collects
#        everything and prints it.
#   3. corrupt the python codec    -> the executed test suite goes red
#   4. hardcode a compose port     -> the parameterization check goes red
#   5. flip the CI input default   -> the "consumers stay green" check goes red
#   6. ungate the `none` job       -> the option/job agreement check goes red
#   7-10. break the agreement between the documented `uses:` string and the
#         real path, in the four ways it can break -> the callable-path check
#         goes red
#   11-12. break a Dockerfile -> the hadolint check, and the non-root check that
#         exists because hadolint has no rule for a missing USER
#   13-18. one semantic mutation per language implementation -> THAT language's
#         suite goes red. A suite that has never failed has never been proven to
#         test anything, and six suites that only one language's mutation covers
#         is five suites that might assert nothing at all.
#   19. an allowlist entry that matches nothing -> the unused-entry check goes
#         red. This is the sharpest property kit owns, and it is the one with
#         the most room to be decorative: an allowlist rule that has never
#         rejected anything is a comment in a file with a `.gitignore`-shaped
#         name. Modelled on ESLint's reportUnusedDisableDirectives, which
#         reports a disable comment that no longer suppresses anything —
#         without that rule a skip list is a ratchet that only turns one way,
#         and within two quarters it contains every test in the repository.
#
#   Breakages 2 and 4 were both REWRITTEN in kit-03, for the same reason and it
#   is worth recording: their recipes named strings that no longer exist. 2
#   mutated `exporters: [debug]`, which the traces pipeline stopped being when
#   it began fanning out to three backends; 4 replaced a literal
#   `${KIT_POSTGRES_PORT:-5432}`, which stopped existing when the stack moved
#   into kit's 15000-15999 port block. In both cases `edit` refused to apply the
#   mutation — correct behaviour, since a stale recipe must not silently pass —
#   and the gate went red on that breakage and never reached the next one. A
#   self_test whose recipe no longer applies is a self_test that has stopped
#   testing the thing it names.
#   20. nest `includePaths` under `git:` -> the core fan-out check goes red. The
#         shape reads correctly, syncs successfully, and vendors the entire
#         upstream repository; it was run before it was written down.
#   21. make the change classifier FAIL OPEN -> classify_test.sh goes red. This
#         is the sharpest proof here: it inverts the fail-closed property and
#         asserts the suite notices, so the property is a counterexample rather
#         than a claim in a comment.
#   22. report an undeclared core pin as `current` -> staleness_test.sh goes red.
#         Two real repositories are in that state today, which is what makes the
#         difference between `undeclared` and `current` load-bearing.
#   23. delete the interpreter floor from validate.sh -> with a stub ruby older
#         than KitOtel::RUBY_FLOOR on PATH, the ruby suite goes red under its
#         own label. This is the red that three landed-or-landing packets were
#         blocked by, reproduced on purpose.
#  23b. the floor INTACT, same old stub -> the gate stays GREEN and names the
#         skip. The one breakage here that asserts a check while the gate is
#         green: a floor that turns a red into a silent pass is worse than no
#         floor, and only this direction can tell the two apart.
#  24-26. the shapes a workaround for a FIXED core defect takes -> the fleet
#         check goes red. Two are D12 (core 63fd319: `RUN_KEY` could not see a
#         one-line `run:`) and one is D13 (core c63af27: a proof matched against
#         bytes still carrying ANSI colour). Both defects are fixed, so a
#         workaround for either is a second, unversioned copy of a decision that
#         now lives in core, and 26's escape runs make the declaration WEAKER
#         than the same declaration written without them.

# 27-30. the four ways the "lint runs from kit" mechanism stops being a GATE
#         while everything else stays green, all caught by `lint_wiring_check`
#         and all NAMING it, because a check that has quietly stopped being
#         load-bearing should fail here rather than being found months later by
#         the policy it stopped policing:
#           27. a language job's `lint` step DELETED -> the job no longer lints
#           28. that step made ADVISORY — `continue-on-error: true`, the
#                breakage that matters most, because the step still runs, still
#                prints every finding, and the job is green. A linter that only
#                warns is a report, and this is how a report is born without
#                anybody deciding to write one.
#           28b. the same defect written the other way it can be written,
#                `|| true` at the end of the run body. Continue-on-error in
#                shell, and it reads to nobody as anything but a deliberate
#                choice.
#           29. the kit CHECKOUT deleted, so `--config` names a file that is not
#                there and each linter quietly falls back to its own defaults —
#                five linters for golangci-lint, MethodLength 10 for rubocop,
#                no rules at all for eslint. All green, all much weaker, and
#                invisible in the YAML, because the step still says `--config`.
#           30. the config WEAKENED in place. The sharpest of the four, because
#                every other check can be green while it happens: the file still
#                parses, the workflow still points at it, and the policy is now
#                whatever was left. So the linter list is asserted BY VALUE.
#  31. a SERVICE carries a lint config INCONSISTENT with kit's -> the drift
#        check goes red. The failure this whole packet exists to end, at the
#        layer where it lands: a service's own lint config, disagreeing with
#        kit's, in a repository that calls kit.
#
#        The MECHANISM was measured before it was written down, and the first
#        version of this comment was wrong. `--config` WINS: `golangci-lint run
#        -v` prints exactly one `[config_reader] Used config file`, and with the
#        flag it names kit's — a repo-root `.golangci.yml` that disables
#        `misspell` does not survive it, and RuboCop behaves the same way. So a
#        stale copy does NOT hijack kit's CI, and this breakage is not about
#        that. What a copy does is SPLIT the policy: every other invocation in
#        that repository reads it while CI reads kit's, and it becomes live
#        again the instant the flag is lost — silently, because a copy is always
#        weaker than the thing it was copied from. That is the finding, and it is
#        why the check reports the DIFFERENCE rather than banning the file.
# 32-32c. the SEAM, in the three ways `lint_args_seam_check` can stop being a
#         control. The seam is `lint-args`, the one input a service uses to ask
#         for a stricter linter, and its narrowness is a list of refused flags
#         held in a `lint-args guard` step in each lint job:
#           32. the guard DELETED from one job. The other two keep working, so
#                this is the shape of an accident — one merge, one job, no other
#                signal anywhere.
#           32b. the guard KEPT and its list SHORTENED by one token. The edit a
#                well-meaning commit makes when somebody wants `--no-config`:
#                rather than argue about the seam, the token comes out. The
#                build stays green for every service that sets it and the
#                workflow still contains a step called `lint-args guard`. This
#                is the sharpest of the three, and it is only caught because the
#                token list is asserted against a copy held in validate.sh.
#           32c. the guard MOVED after the linter. It still runs, still reads the
#                variable, and still refuses everything it refused — after the
#                linter has been handed `--no-config` and already exited 0. A
#                control that runs after the thing it controls is the most
#                comfortable kind of dead code, because read top to bottom it
#                looks exactly like a live one.
#   ...and one GREEN control, which is the other half of 31's claim: a service
#        config that AGREES with kit's must PASS, because a check that failed on
#        the mere presence of the file would train every service to delete a file
#        it is allowed to keep. It is written here as prose rather than as a
#        numbered entry because it is a control and not a breakage — and because
#        `self_test_claims` counts only the red-expecting helpers, so a numbered
#        entry here would be reported as a header claim with no recipe.

#  33. a parity-allowlist entry naming an artefact kit does not ship -> the
#         dead-entry check goes red. The ESLint direction, and the mutation is
#         well-formed in every other respect, so a shape-only check passes it.
#  34. an EXPIRED parity-allowlist entry -> the same check goes red. The gate
#         reads the clock, and this is the first time anything in kit has
#         actually watched the ratchet fire rather than reading that it exists.
#  35. `tests/artifacts.json` naming a `{lang}` source kit does not ship for
#         every language -> the artefact-table check goes red. Half a language is
#         worse than none, and the table is what says so.
#  36. report an ABSENT artefact as `current` -> staleness_test.sh goes red.
#         This is the breakage the packet is for: the reporter treating the
#         commonest state in the fleet as the one that means everything is fine.
#  37. grade a copy by RESEMBLANCE rather than by equality -> staleness_test.sh
#         goes red. The failure mode the packet names: a file that looks like
#         kit's is not evidence it is kit's.
#  38. give one of the two programs a third-party import -> the carve-out check
#         goes red. "Standard library only" was a sentence in AGENTS.md for the
#         whole life of the rule and nothing checked it; a boundary nobody can
#         cross is not a boundary.
#  39. remove one fixture service's `.git`, so the reporter cannot see it ->
#         staleness_test.sh goes red AND blames the FIXTURE. Observed for real at
#         load average 160 before it was written: one case failed, 35 passed, and
#         the failure text named the reporter when the reporter had simply been
#         handed a smaller fleet. A red that misattributes itself is worse than
#         no red, so this asserts the EXPLANATION, not only the exit status.
#  40. delete the one line that consults the ruby toolchain floor, leaving the
#         probe defined and never called -> the ruby check still runs the suite.
#         A floor check that is written, admired and never fires is the shape
#         this breakage is the well-intentioned version of: `have ruby` is three
#         lines above, so asking whether it is the RIGHT ruby looks redundant.
#         `Array#filter_map` is a runtime call, so without the floor an old
#         interpreter reports three NoMethodErrors and the summary blames a
#         template that is correct.
#
# 41-42. plant a detectable credential, in history and in the working tree ->
#            the secret scanner goes red
# 43-44. remove --redact, then narrow the scan to the last commit -> the
#            scanner's BEHAVIOUR check goes red. Not its source: a `grep -- --redact`
#            is satisfied by the comment above the flag that explains why the flag
#            is mandatory, and that breakage proved exactly that
# 45. add `pull_request_target` -> the dangerous-trigger check goes red
# 46. make the `secrets` job `continue-on-error` -> the not-advisory check goes
#            red. A secret scanner that only warns is a report
# 47-50. break the canary's reference type in the four ways that turn it into
#            the leaky one -> THAT VECTOR's suite goes red
# 51. baseline unpinned-uses in .github/zizmor.yml -> the never-baselined check
#            goes red

# 52-55. THE FLEET GATE, one breakage per failure mode, each against a FIXTURE
#         fleet rather than the real one. A fixture fleet is what makes these
#         mean anything: the real fleet is red on master BY DESIGN, so "the gate
#         went red" there is satisfied by two clean repositories.
#           52. a service carrying its own copy of the shared stack (a second
#               postgres) -> the stale-copy check goes red. Five of the six
#               repositories that declare local infrastructure are in exactly
#               this state today, and the mutation is their real shape rather
#               than a toy.
#           53. a service that overrides the collector's config mount -> the
#               weakened-boundary check goes red. The mount is where the
#               redaction allowlist lives, so this is the failure that leaks
#               prompt content rather than the one that looks untidy.
#           54. an `otel-collector.yml` nothing ever starts -> the dead-config
#               check goes red. Inert is the worst of the four: the file looks
#               authoritative, every edit to it changes nothing, and a
#               developer has no way to find out.
#           55. a `kit.ref` holding `master` -> the pin check goes red.
# 56-58. the override rules, each against the named check.
#           56. a vendor config mount that stopped resolving from the fetched
#               tree. Found by RUNNING the stack; `docker compose config`
#               renders the same project and every other check stays green.
#           57. the pin moved back into `.env`, where it is git-ignored and so
#               exists on exactly one machine.
#           58. a service publishes a port on a service kit already ships. The
#               merge appends rather than substitutes, so nothing errors and the
#               port the developer meant to move is still bound.
# 59-60. THE ADOPTION CEILING, both sides of it, because a ceiling that only has
#         one side proved is not a ceiling — it is a deleted check.
#           59. the SAME stale copy in a repository with NO `kit.ref` -> the gate
#               stays GREEN and the finding is printed as a WARN naming the
#               adoption path. This is the half that could have been quietly
#               wrong: if the unadopted side went red, the ceiling would not
#               exist and this breakage would have caught it.
#           60. that repository's `kit.ref` written -> the gate goes RED on the
#               same defect, same message, same severity. This is the half that
#               proves nothing was weakened: it is the fixture of breakage 52
#               plus one committed line.
#           The pair is also the ratchet proof. 59 and 60 run over the SAME
#           fixture, so a change that softened the adopted side fails 60 and a
#           change that hardened the unadopted side fails 59, and there is no
#           third state in which both pass and the checks are weaker.
# 83. A SERVICE OVERRIDING THE SHARED CLUSTER'S OWN POSTGRES IDENTITY -> the
#         weakened-boundary check goes red, naming the override.
#         The one breakage here whose defect was kit's own ADVICE. For years
#         `check_stale_copy` and the adoption-path block both told a service to
#         "override the postgres service's environment (POSTGRES_DB /
#         POSTGRES_USER)", and that sentence is the whole defect: the official
#         image creates `POSTGRES_USER` as a SUPERUSER, so the override makes
#         the overriding service a cluster superuser; and the image has already
#         created that role and database, so `CREATE ROLE` / `CREATE DATABASE`
#         in `initdb/10-cluster.sh` fail during initdb and the whole cluster
#         refuses to start. Measured both ways; see `_SHARED_CLUSTER_ENV`.
#         `identity` carries the override, inherited from following it, and it
#         was found by a worker doing an unrelated migration.
#
#         It is a breakage in this family and not a new section because
#         correcting the prose alone would have left the gap open from the other
#         side: a service that FOLLOWS the corrected advice deletes its own
#         postgres service, which is precisely the thing `check_stale_copy`
#         stops reporting. Advice and predicate have to move together or the
#         fix walks into a check that no longer sees it.
#
#         The mutation is `POSTGRES_USER` alone, and that choice is the red
#         proof rather than a shorthand. All three keys fire, but `POSTGRES_USER`
#         is the one with BOTH failure modes, and it is the one a real service
#         carries. `POSTGRES_PASSWORD` is the interesting exclusion: it breaks
#         neither the cluster nor the boundary, and asserting on it would have
#         meant asserting on the part of the check that is least like the thing
#         it was written for.
#
#         The needle is the finding's own wording, and `check_override_surface`
#         is named in the label, because a red from the ports rule or the
#         stale-copy rule would satisfy a weaker assertion. The fixture carries
#         `POSTGRES_DB: alpha` on `alpha:` — a service setting the variable on
#         its OWN service, which is the legitimate case — so the check also
#         proves it stays quiet about that, on every fixture recipe in this
#         file, without a separate control.
# 78-82. THE KAMAL CONFIG, which is the one place kit generates YAML that a
#         THIRD-PARTY BINARY has to accept. Everything else kit hands out is
#         read by the service's own toolchain; this is read by `kamal` and
#         `kamal-backup`, so a template can be valid YAML, parse cleanly, and
#         still be a config neither tool will take.
#
#         RENUMBERED, and the header was not moved with it. This block read
#         `61-65` and described these five at 61, 62, 63, 64 and 65; the recipes
#         were renumbered to 78-82 (4a037f3, whose own body note records the
#         collision that forced the move) and this header was left behind. The
#         damage was not cosmetic and not confined to this block: 61 and 62 were
#         REUSED, and by the LICENCE breakages below, which really do exist.
#         So the header claimed two different sets of proofs under the same two
#         numbers, and `self_test_claims` — which exists precisely to catch a
#         block of prose drifting from the recipes — reported both directions at
#         once: "header documents breakage 63 but no recipe carries it" and
#         "recipe proves breakage 78 but the header does not document it". Six
#         findings from one unrenumbered comment, on master, with the integrity
#         check itself being the thing that found it.
#           78. the generated deploy.yml made INVALID for kamal -> the
#                kamal_test check goes red. `builder.arch` is the mutation
#                because it is a real one: removing it is valid YAML, and kamal
#                refuses the file outright ("Builder arch not set").
#           79. the image name given the registry host it already has ->
#                kamal_test goes red. The sharpest of the five, and the one no
#                parse check could ever have caught: `image: ghcr.io/org/repo`
#                with `registry.server: ghcr.io` resolves to
#                `ghcr.io/ghcr.io/org/repo`. Both files are valid, `kamal
#                config` exits 0, and the deploy fails at the push.
#           80. one kamal/ artifact DELETED -> the presence check goes red.
#                Half a set is worse than none, and here the two configs are one
#                contract rather than two files.
#           81. the superseded custom backup toolchain RESTORED -> the
#                must-be-gone check goes red. The only breakage here that is
#                about something being PRESENT, and it exists because "we
#                removed it" is a claim with no mechanical form until something
#                asserts the absence.
#           82. the drill's refusal of a production-looking scratch name WEAKENED
#                -> kamal_test goes red. The safety property, mutated the way a
#                well-meaning commit would mutate it: the `*prod*` pattern
#                narrowed so the common names still match and the awkward one
#                does not.
#
#   ...and one GREEN control for the Kamal work, 78b: an UNMODIFIED tree's
#        generated config must PASS kamal and kamal-backup. Every other recipe
#        here proves a check can go red; this proves the thing they are all
#        measured against actually works, which is the half that decays without
#        a symptom. It is written as prose rather than numbered because
#        `self_test_claims` counts only the red-expecting helpers.
#
# 84-87. THE SHARED CLUSTER, and specifically the two defects that meant no
#         service in the fleet ever had a database on it while reporting itself
#         healthy. Prose for these lives with the recipes, far below and out of
#         this header, because they were added long after the numbers were first
#         laid out; the entry is here only so the set agrees. 83 is NOT in this
#         block and 84-87 do not include it: kit-29 claimed 83 for the
#         superuser-override check in a different worktree, and two packets
#         numbering a breakage the same way is precisely what makes this header
#         unable to say which recipe a line describes.
#
#         87 is the fourth because removing the `:-` fallback from
#         `KIT_POSTGRES_DATABASES` — which is what 84-86 exist to insist on —
#         turned out to break kit's OWN live harness, and 214 static checks and
#         86 proofs did not notice. So the rule now covers kit's own harnesses
#         too, statically, and 87 is the proof that it does.
#
# 88. THE SECOND TENANT, which is the case every other breakage in this file
#         structurally cannot reach. All of them prove that ONE service gets a
#         database; this is the first to ask what happens when a second name is
#         appended, and it exists because that question had never been asked and
#         the answer was wrong. `KIT_POSTGRES_DATABASES="billing neighbour"`
#         provisioned ONE database named `billingneighbour` and reported
#         success, because a `tr -d '[:space:]'` standing in front of
#         `require_identifier` deleted the space before the validator could
#         refuse it. Measured on a live cluster, not inferred.
#
#         It gets its own number rather than joining 84-87 above because that
#         block is about the cluster provisioning NOTHING, and this is about it
#         provisioning the wrong THING while reporting itself healthy. Different
#         defect, different fix — and a header number that covers two of those
#         is a number that cannot say which recipe a line describes.
#
# 89. THE REUSABLE WORKFLOW'S OWN SCHEMA, which every service inherits by CALLING
#         it rather than copying it — which is the property that makes one bad
#         input here a fleet-wide outage rather than a local bug. `workflow_call`
#         inputs do not accept an `options:` block the way `workflow_dispatch`
#         inputs do, and GitHub rejects the FILE for it: not a warning on one
#         input, but a workflow that will not load at all, so every service that
#         calls it fails before a single job starts.
#
# 61-62. THE LICENCE, in the two ways the grant stops being unambiguous. A
#         licence is only unambiguous when exactly ONE place in a repository can
#         declare one.
#           61. `LICENSE` DELETED -> the licence check goes red. cafaye's
#               decision is MIT across the fleet, and a repository with no grant
#               is not permissive: it is all rights reserved, the default
#               copyright position when nothing is granted. The README kept
#               saying MIT the whole time, which is exactly why this needed a
#               check — the documentation was true and the repository was not.
#           62. a root `package.json` declaring `AGPL-3.0-only` -> the same check
#               goes red, with `LICENSE` and the README both still saying MIT.
#               This is the direction nobody looks at, and it is the one that
#               makes the check real: a check asserting only that `LICENSE`
#               exists is satisfied by a repository that has acquired a THIRD
#               statement about its own grant, which a compliance tool reads.
#
#   33-40 continue that numbering above, and the reason the copy-is-gone case
#   gets TWO breakages and not one is that
#   "report absent as current" and "grade by resemblance" are opposite mistakes
#   that a single mutation cannot both produce: one removes a finding, the
#   other invents one, and a gate that can only do one of them is half a gate.
#
#   Forty-seven of them (7-12, 19, 20, 24-32c, 33-35, 38, 40-62) additionally
#         assert WHICH check went red. Every other breakage only proves the gate
#         can fail; those prove the check written for that defect is still
#         load-bearing, which is a different claim and the one that decays
#         silently. 21, 22, 36 and 37 assert the same thing about the two scripts
#         that are themselves proofs, 39 asserts it about the WORDING — a red that
#         blames the reporter when the fixture is at fault is a red that sends
#         the next reader to the wrong file — 52-55 and 58-60 assert it over
#         a FIXTURE fleet rather than over the tree (see `fixture_fleet` below
#         for why that helper exists at all), and 61-62 assert it over the
#         licence, where the named check is the only thing distinguishing
#         "the grant is gone" from "something else went red".
#
#   And one GREEN control, which is a claim the numbered breakages cannot make.
#         31b asserts the gate is green on a copy whose service config MATCHES
#         kit's. A check that failed on the mere presence of a `.golangci.yml`
#         would be satisfied by this packet and would teach every service to
#         delete a file it is allowed to keep — a silent outcome, and a worse one
#         than the drift it was written to catch.
#
#   The counts here were wrong three times and every time a check caught it
#         rather than a reader: the header said "seven" over a four-wide range,
#         it numbered a second entry 19 while the recipes numbered it 20, and it
#         kept saying "twenty-three" after the lint packet added six more. A
#         header that drifts from the recipes is not documentation, it is a
#         second, unchecked copy of the truth — which is the entire thing
#         validate.sh's header/recipe check exists to prevent. That check COUNTS
#         the recipes and diffs them against this header, so the third error was
#         caught the same way as the first two: mechanically, not by reading.
#
# WHAT IT IS NOT
#   This is not exhaustive mutation testing. Each implementation gets exactly one
#   mutant, chosen to be the bug a reviewer would not see: a dropped bit mask, an
#   alphabet that quietly grows a second case, a limit raised until it never
#   fires. One mutant per language proves the suite bites; it does not prove the
#   suite is complete, and nothing here should be read as claiming that is.
#
#   The same applies to breakages 41-51. They prove each check CAN fail; they do
#   not prove the check is complete. A check that fires on the defect it was
#   written for is the floor, and the floor is what a gate nobody runs has.
#
# WHY THE PLANTED PROBES ARE ASSEMBLED RATHER THAN WRITTEN OUT
#   Breakage 24 plants a credential, 25 plants the same one, and 33 plants a
#   canary literal. All three are assembled from parts in a throwaway copy, for
#   one reason: a probe written out is a probe committed, and the scanner and the
#   canary check would then both report THIS FILE — every breakage caught by the
#   wrong thing, and a gate that is red for a reason nobody introduced.
#
#   It happened, twice, while writing these. `tests/validate.sh` reported four
#   leaks in the file that was planting them, and the canary check reported the
#   breakage's own replacement string. Both are recorded in the breakages'
#   comments, because a proof that only ever worked the first time is a proof
#   somebody will trust.


#   These are numbered 20-22 rather than 19-21 because 19 is the allowlist
#   breakage above, from the tier work. Both packets numbered their first entry
#   independently and the collision is only visible in the union — which is what
#   the header/recipe check in validate.sh is for.
#
#   Eight of them (7-10, 11, 12, 19, 20) additionally assert WHICH check went
#         red. Every other breakage only proves the gate can fail; those prove
#         the check written for that defect is still load-bearing, which is a
#         different claim and the one that decays silently. 21 and 22 assert the
#         same thing about the two scripts that are themselves proofs.
#
#   The counts here were wrong twice and both times a check caught it rather
#   than a reader: the header said "seven" over a four-wide range, and it
#   numbered a second entry 19 while the recipes numbered it 20. A header that
#   drifts from the recipes is not documentation, it is a second, unchecked copy
#   of the truth — which is the entire thing validate.sh's header/recipe check
#         exists to prevent.
#
# WHAT IT IS NOT
#   This is not exhaustive mutation testing. Each implementation gets exactly one
#   mutant, chosen to be the bug a reviewer would not see: a dropped bit mask, an
#   alphabet that quietly grows a second case, a limit raised until it never
#   fires. One mutant per language proves the suite bites; it does not prove the
#   suite is complete, and nothing here should be read as claiming that is.
#
# 94 and 95 are the only two that break THIS FILE rather than the gate, and they
# are here because the harness is the one component no other recipe can reach.
#   94. the shard key is 0-based again         -> `shard_test` goes red, naming shard n/n
#   95. an over-provisioned shard stops being refused at the door -> red
#
# 96-100 are THE VERSION STRING'S OWN GATE, and each one names a single check and
# mutates a single thing — the rule breakage 75 exists for, since a fixture that
# can go red two ways proves the gate bites and says nothing about which half.
#   96. a MAJOR bump with no MIGRATION.md      -> the migration the tier owes
#   97. a MINOR bump declaring `### Breaking`   -> additive, and it breaks something
#   98. `### Breaking` under Unreleased         -> no version covers it at all
#   99. VERSION `1.0.0-rc1`                     -> the string cannot be placed
#   100. a reserved path back in the tree       -> the tombstone means nothing
#   101. the OUTPUTS conjunct deleted from the skip -> a cache with no work on
#        disk answers HIT anyway. This is the one that earns the cache: every
#        other breakage here proves a check can fail, and this one proves the
#        cache can be CAUGHT failing. A skip that has never been caught lying is
#        a skip nobody should trust, and the mutation deletes the clause that
#        turns "the fingerprint matches" into "do nothing".
#   102. the correlated-subquery test deleted from the advisor rule -> the slow
#        policy shape goes unreported. The rule is proved on a real cluster, and
#        the mutation is paren-balanced on purpose: the unbalanced spelling
#        fails the function to install and takes EVERY rule silent at once, which
#        is a red from the wrong cause wearing this breakage's name.
#   103. the OWNERSHIP-BY-NAMESPACE check deleted from `--verify` -> a base
#        image's own OCI labels satisfy a stamp that is ours. The one that
#        shipped: `--verify cafaye/guard:e2e` printed `oven-sh/bun`'s source and
#        exited 0, and the suite written to prevent it could not see the case
#        because every `--verify` fixture it built came from a kit Dockerfile --
#        and a foreign base image's labels are precisely the labels kit's
#        Dockerfile did not write.
#
# Both are `expect_red_script` against `tests/shard_test.sh`, which is a proof
# rather than a gate over a tree for the same reason `classify_test.sh` is: the
# property is about the suite's own arithmetic, so there is nothing for a check
# over the tree to look at. The mutation is the defect that shipped — a 0-based
# residue compared against a 1-based shard index — and it is why a four-shard merge
# gate once reported all four green with the fourth having verified nothing.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Standalone runs bootstrap too, and `validate.sh` exports KIT_PYTHON so the
# nested copies use the same interpreter. Self-bootstrapping here is not
# redundancy: `bash tests/self_test.sh` is a documented command, and a
# documented command that only works after a different documented command has
# been run is two commands wearing one name.
if [ ! -r "$ROOT/tests/bootstrap.sh" ]; then
  echo "self_test.sh: tests/bootstrap.sh is missing — cannot resolve a python" >&2
  exit 1
fi
# shellcheck source=tests/bootstrap.sh
. "$ROOT/tests/bootstrap.sh"
kit_bootstrap_python "$ROOT"
export KIT_PYTHON="$PY"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-self-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ONE CACHE DIRECTORY FOR ALL THE COPIES. One line, and it is the precondition
# for the whole rollout: `tests/validate.sh` keeps its fingerprint records in
# `$KIT_CACHE_DIR` if set and in `.kit/cache/gate` under the tree otherwise, and
# every copy here is a throwaway tree that is deleted with the breakage that made
# it. A record written inside copy 23 therefore dies with copy 23, so copy 57 —
# which mutated a file copy 23 never touched — pays full price for a verdict
# copy 23 already earned.
#
# `$WORK/cache` is a SIBLING of every copy (`$WORK/<name>/kit`), not a child of
# one, and that is the whole placement decision: a cache inside a copy is deleted
# with the copy, and a cache in the real tree is neither shared with the copies
# nor thrown away by the trap. `$WORK` is created once and swept by the `trap`, so
# the directory is shared for exactly the lifetime of this suite and leaves
# nothing behind.
#
# WHAT IT DOES AND DOES NOT CHANGE. It makes a skip POSSIBLE; it does not make
# one happen. No check is wired to the cache in this commit, so with the tree as
# it stands this line changes no verdict at all — it is the switch, and the
# declarations are what connect it. `KIT_FINGERPRINT=0` still disables the skip
# outright, and a caller's own `KIT_CACHE_DIR` is respected rather than
# overwritten, because a developer pointing the suite at a warm directory is
# asking a question this line has no business answering.
#
# THE ONE HAZARD, and it is proof 7a rather than a guess. A shared cache across
# the copies is sound only because every breakage changes some file's CONTENT and
# therefore some wired check's fingerprint — which holds only if the mutation
# lands on a file that check's DECLARATION names. Omit one input and a cache hit
# is a green for work nobody did. So a check is wired here only with a
# declaration traced input by input, and the two helpers below run their copies
# with `KIT_FINGERPRINT=0` for the same reason.
export KIT_CACHE_DIR="${KIT_CACHE_DIR:-$WORK/cache}"

failures=0
skips=0
# Distinct from `skips`, and the reason is in `expect_red_check`: a missing
# toolchain is a machine you cannot equip, and a gate that exited without
# reporting a finding is a proof that could not be evaluated at all. Reporting
# the second as the first sends the next reader after the wrong file.
env_skips=0
copy_name=""

# A fresh throwaway copy per breakage: one breakage must never mask the next,
# and no breakage may touch the worktree this script was invoked from.
#
# EACH COPY GETS ITS OWN PARENT DIRECTORY, and that is load-bearing rather than
# tidiness. `fleet_repos` in tests/validate.sh finds a service fleet by globbing
# `$ROOT/..`, so a copy that sat directly in the shared `$WORK` would see all
# THIRTY of its siblings as the fleet. That is not a tidiness problem, it is a
# correctness one in both directions:
#
#   - every breakage's gate run would be red because a LATER breakage's copy
#     carries a `.golangci.yml`, so a breakage could be "caught" by a defect it
#     did not introduce; and
#   - breakage 31b, which asserts the gate is GREEN on a copy whose config
#     MATCHES kit's, would be red because breakage 31's copy — a sibling, in the
#     same directory — has one that does not.
#
# A control that goes red for a reason another test created is worse than no
# control, because it reads as evidence. One directory per copy makes each
# breakage's fleet exactly itself: deterministic, and each result attributable
# to the breakage under test and nothing else.

# `$WORK/$name/kit`, NOT `$WORK/$name`, and the reason is a proof that passes for the
# wrong reason.
#
# Every `expect_red_check` runs `validate.sh` inside a throwaway copy, and
# `validate.sh` asks `fleet_check.py` about `$ROOT/..` — the copy's PARENT. If
# that parent is `$WORK`, then every fixture fleet an earlier breakage built
# (`$WORK/fixtures/<name>/{alpha,beta}`, each with a `.git`) is a repository the
# gate can see, and the first one's `alpha` is still broken. So breakage 52's
# defect makes EVERY LATER breakage go red, and breakages 53-55 would pass on
# `FAIL fleet` whether or not the mutation they applied was the defect they name.
#
# Four proofs asserting nothing, caused by a directory that was one level too
# high. `<name>/` is a directory that holds one copy and nothing else, so a copy's
# parent contains exactly one entry — itself — and that entry has no `.git`.
# --- SHARDING ----------------------------------------------------------------
#
# WHY. Measured, not guessed: one `--static-only` validate.sh run takes ~50s on
# this machine, and this file runs one per breakage. 76 breakages x 50s is
# roughly 63 MINUTES of wall clock for a suite whose actual work is parallelisable
# and independent. That is the single reason this file was described as taking
# "hours", and it was never the assertions -- it is 76 sequential subprocesses.
#
# WHAT THIS IS. `KIT_SELF_TEST_SHARD=i/n` runs only the breakages whose NUMBER
# is congruent to i modulo n, over the range 1..n. Every other breakage's helper
# becomes a no-op that returns 0 WITHOUT running the gate, and the summary says so
# rather than silently reporting a fraction of the suite as if it were all of it.
#
# WHAT THIS IS NOT. It does not weaken any assertion. A sharded run asserts
# exactly the assertions it would have run unsharded, on the same copies, with
# the same mutations; the only difference is which recipes execute. And a shard
# that goes red is a real red: the exit status is the shard's own.
#
# THE HONEST PART, which is why this is opt-in and never the default. A sharded
# run CANNOT report "all N breakages hold" -- it has not run all N. So the
# summary line says which shard it was, and the count it prints is the count it
# actually ran. A suite that quietly reported 1/8th of itself as a pass is the
# exact failure this file exists to prevent, and it applies to the harness too.
# THE SENTENCE ABOVE WAS WRONG IN A WAY THAT PRODUCED A FALSE GREEN, and the
# arithmetic is the whole defect: it said `i % n == index` while the code asked
# `num % n == i`. `num % n` lands in 0..n-1 and a caller passes i in 1..n, so the
# residue class n is one nobody asks for -- shard n/n matched NOTHING, ever. Four
# shards run as a merge gate with 1/4, 2/4, 3/4, 4/4 covered three quarters of the
# suite and the fourth verified nothing and said PASS. The `ran ZERO of the
# suite's N breakages` guard below is what made it loud instead of silent, and it
# was added after the fact: it reports the consequence, not the cause.
#
# So `i` is 1-BASED ON BOTH SIDES and the range is CLOSED at both ends. Shard
# n/n is the LAST shard, not a sentinel past the end; `tests/shard_test.sh` proves
# the partition property against the real function on every run of the gate, and
# breakages 94 and 95 are the two ways this comes back.
#
# THE SUITE'S HIGHEST BREAKAGE NUMBER, counted here once, for the
# over-provisioning refusal. Not the suite's SIZE: the labels are sparse (they run
# 1..93 with lettered siblings and gaps where packets were renumbered), so `n`
# shards are all non-empty whenever n is at most the highest NUMBER, and
# over-provisioning is `n` above that number rather than above the count. Sizing
# the refusal on the count is what made the first version of this refuse
# correctly by accident and then let `n = 97` through with nine empty shards.
_shard_i="${KIT_SELF_TEST_SHARD:-}"
_shard_n=""
_shard_suite_max=0
if [ -n "$_shard_i" ]; then
  _shard_n="${_shard_i#*/}"
  _shard_i="${_shard_i%%/*}"
  if ! printf '%s\n' "$_shard_n" | grep -qE '^[1-9][0-9]*$'; then
    printf 'self_test: KIT_SELF_TEST_SHARD must look like i/n with n >= 1, got %s\n' "$KIT_SELF_TEST_SHARD" >&2
    exit 2
  fi
  if ! printf '%s\n' "$_shard_i" | grep -qE '^[0-9]+$'; then
    printf 'self_test: KIT_SELF_TEST_SHARD must look like i/n with i a whole number, got %s\n' "$KIT_SELF_TEST_SHARD" >&2
    exit 2
  fi
  # i IS 1..n AND NOTHING ELSE. Zero is refused rather than treated as the
  # unnumbered-label shard it used to be: `0/23` asked for a residue class that
  # exists and is empty of controls in most shapes, so it answered "ran 4 of 97"
  # and read like a shard. A refused shard is a loud misconfiguration; a shard that
  # quietly covers a different set than the caller asked for is the false green.
  if [ "$_shard_i" -lt 1 ] || [ "$_shard_i" -gt "$_shard_n" ]; then
    printf 'self_test: shard i must be 1..n (1-based, both ends), got i=%s n=%s\n' "$_shard_i" "$_shard_n" >&2
    exit 2
  fi
  # OVER-PROVISIONING IS REFUSED, BEFORE ANY RECIPE RUNS. n above the suite's
  # highest number means some shard MUST be empty, and an empty shard is
  # indistinguishable from one the arithmetic emptied by mistake -- which is
  # precisely the ambiguity that made 4/4 a false green. So the one case where
  # "ran zero" is the honest answer is refused at the door with both numbers,
  # rather than discovered at the end of a run that verified nothing.
  #
  # `tail -1` rather than `head -1`, so nothing downstream closes the pipe and
  # promotes a SIGPIPE into a wrong answer -- the rule this suite keeps having to
  # relearn.
  _shard_suite_max=$(grep -oE '^ *expect_(red|green)(_check|_lang|_script)? +.breakage +[0-9]+[a-z]*:|^ *expect_skip_check +.breakage +[0-9]+[a-z]*:' "$0" |
    sed -E 's/.*breakage ([0-9]+)[a-z]*:.*/\1/' | sort -n | tail -1)
  _shard_suite_max="${_shard_suite_max:-0}"
  if [ "$_shard_n" -gt "$_shard_suite_max" ]; then
    printf 'self_test: %s shards cannot partition a suite numbered up to %s.\n' "$_shard_n" "$_shard_suite_max" >&2
    printf '       Some shard would run nothing, and an empty shard is\n' >&2
    printf '       indistinguishable from one the arithmetic emptied by mistake.\n' >&2
    printf '       Run 1..%s.\n' "$_shard_suite_max" >&2
    exit 2
  fi
fi

# _shard_claims <label> -- does this recipe belong to the shard being run?
#
# The breakage NUMBER is the shard key, not the line number: breakages are
# numbered 1..N and a recipe's position in the file is an accident of when it was
# written. Sharding on line number would mean adding a recipe silently moves
# every later recipe into a different shard.
_shard_claims() {
  [ -n "$_shard_i" ] || return 0
  local label="$1" num idx
  num=$(printf '%s' "$label" | sed -n 's/.*breakage \([0-9][0-9]*[a-z]*\):.*/\1/p')
  if [ -z "$num" ]; then
    # A label with no number in it is not a numbered breakage; it cannot be
    # assigned to a shard by congruence, so it runs on shard 1/n only. That is
    # where the unsharded run puts it, and shard 1 is the one shard that is never
    # empty while n <= the suite's size -- so the green controls are exercised by
    # every four-way gate rather than only by a run that asked for all of them.
    # It WAS shard 0/n, which is not a shard at all; see the refusal above.
    [ "$_shard_i" = "1" ] && return 0
    return 1
  fi
  num="${num%%[a-z]}"
  # 1-BASED ON BOTH SIDES, and this one line is the defect the packet is about.
  # `(num - 1) % n + 1` lands in 1..n, so every shard in 1..n is asked for a
  # residue class that exists and the n shards partition 1..N exactly once.
  # `num % n` lands in 0..n-1 and the caller passes 1..n, which is why shard n/n
  # asked for a class nobody is in and matched nothing.
  idx=$(( (num - 1) % _shard_n + 1 ))
  [ "$idx" -eq "$_shard_i" ]
}

# _shard_ran counts what this shard actually executed, so the summary can print a
# number that is true rather than one copied from the file.
_shard_ran=0
_shard_claimed_total=0

fresh_copy() {
  copy_name="$1"
  local dst="$WORK/$copy_name/kit"
  mkdir -p "$dst"
  # `.github` is in this list and not an afterthought: the reusable workflow it
  # holds is the artifact every check that reads the workflow's inputs reads by
  # path, so a copy without it cannot fail the same way the real tree does.
  # `core` is here for the same reason `.github` is: the breakages below mutate
  # files in it, and a copy without it would fail on a missing path rather than
  # on the defect under test — which is a self_test that proves nothing.
  # `lint` is here for the same reason `.github` is: the breakages below mutate
  # files in it and read files in it, and a copy without it would fail on a
  # missing path rather than on the defect under test — which is a self_test
  # that proves nothing.
  # `.gitleaks.toml` is here for the same reason, and its absence is the loudest
  # version of that failure this file has: kit-08's gitleaks check reads it by
  # path and REFUSES to run without it, so a copy that left it behind failed the
  # control — "the gate is RED on an unbroken tree" — for a reason that had
  # nothing to do with the tree. Three checks went red at once (the allowlist's
  # own shape, the behavioural `--redact` proof, and the scan), and every one of
  # them was reporting the missing file.
  #
  # The list below is therefore the set of things the gate READS, and it has to
  # be re-extended whenever a packet adds a check that reads a new path. That is
  # a real coupling between the harness and the tree, and it is better than the
  # alternative: a check that silently cannot run in a copy is a proof that
  # proves nothing while reporting something.
  # `LICENSE` is here for the same reason, and its absence is a false GREEN:
  # `license_check` reads the file to assert the MIT grant, so a copy without it
  # fails that check on every breakage — and the two green-expecting proofs
  # (23b, 59) would then be red for a reason that has nothing to do with the
  # defect under test, which is the failure mode this list exists to prevent.
  # `DECISIONS.md` is here for the same reason as `LICENSE`, and its absence is a
  # red on EVERY breakage rather than a false green: `decisions_check` reads it
  # by path to assert the file exists and records real entries, so a copy without
  # it fails that check sixty-odd times over — and the green-expecting proofs
  # (23b, 59) would report a red for a reason that has nothing to do with the
  # defect under test. kit-21 is what exposed this: the file did not exist at all
  # until that packet, so nothing had ever needed it here.
  # `VERSION` and `RESERVED` are here for the same reason as `LICENSE` and
  # `DECISIONS.md`, and their absence is the same FALSE GREEN: `stability_gate`
  # and `reserved_check` read both by path, so a copy without them fails those
  # checks on every breakage — and the two green-expecting proofs (23b, 59) would
  # report a red for a reason that has nothing to do with the defect under test.
  #
  # `MIGRATIONS.md` is here for the same reason and was MISSING until
  # provenance-ownership-01, which is the coupling this comment exists to
  # describe biting a real packet rather than being a hypothetical.
  #
  #   The MAJOR rule reads MIGRATIONS.md by path and requires a `## <version>`
  #   section under it. So the day a MAJOR shipped, every one of the ~107
  #   throwaway copies became a tree where the current VERSION derives tier
  #   `breaking` and owes a migration that is not there — and the suite
  #   reported it as:
  #
  #     FAIL self_test: unbroken tree — the gate is RED on an unbroken tree
  #
  #   ...which is the control this file runs FIRST and the sentence that makes
  #   every proof below it meaningless. The tree was not red. The COPY was, for
  #   a reason that had nothing to do with any breakage, and the honest name for
  #   that is the false green in reverse: a false RED that reads as "every proof
  #   in this suite is worthless".
  #
  # Measured, and the diagnosis is only reachable because the control names the
  # symptom rather than the cause:
  #     $ bash tests/validate.sh --static-only            # on the real tree
  #     EXIT=0, zero FAIL
  #     $ bash tests/self_test.sh
  #     FAIL self_test: unbroken tree — the gate is RED on an unbroken tree
  #
  # So the general rule is the one the comment above already states, and this is
  # the second time this repository has paid it: **when a packet adds a file the
  # gate reads by path, `fresh_copy`'s list is part of that packet.** A new
  # check is not done until a throwaway copy can see the thing the check reads.
  #
  # `reports` is here for that reason, and it is the THIRD KIND of thing on this
  # list. `LICENSE`, `DECISIONS.md`, `VERSION` and `MIGRATIONS.md` are files the
  # gate opens; `.github`, `core` and `lint` are directories the gate reads
  # members of. `reports/` is a directory the gate reaches ONE MEMBER DEEP — and a
  # single member is enough, because `readme_check` asserts both halves for every
  # path it names: that README.md mentions it, and that `os.path.exists` says it
  # is there. So an account-scope packet that documented
  # `reports/account-scope-contract-01/snapshot.sh` turned every throwaway copy
  # this suite makes into a tree whose README describes a file the copy does not
  # have:
  #
  #     FAIL README.md  (documents every new template)
  #            README.md documents reports/account-scope-contract-01/snapshot.sh,
  #            which does not exist
  #
  # NO NUMBER, AND THAT IS THE CORRECTION RATHER THAN A LOSS. This paragraph used
  # to say "all 64 throwaway copies", and 64 is not a count of anything. Measured
  # by instrumenting `fresh_copy` in a throwaway copy of the tree and reading
  # what it wrote — not by grepping, because grepping answers a different
  # question — one full run makes:
  #
  #     92 copies   ruby, kamal and kamal-backup all on PATH
  #     79 copies   the same machine with all three unreachable
  #     89 / 76     either of the above, in a run that FAILED or SKIPPED anything
  #                 and so stopped at this file's own `exit 1` before reaching
  #                 breakages 101-103, whose three `fresh_copy` sites sit below
  #                 that guard rather than above it
  #
  # Four numbers, none of them 64, and which one you get is a property of the
  # machine and of how far the run got rather than of this file. 13 of the 92
  # sites sit inside `command -v ruby` or `command -v kamal && command -v
  # kamal-backup` (breakages 23, 23b, 40, and 78b-82 plus 84-87), and 3 sit
  # after the `exit 1`, which is why an invocation-site count is a ceiling rather
  # than an answer. The static count agrees and is the only one that has never
  # moved: `grep -cE '\$\(fresh_copy ' tests/self_test.sh` says 92 at `master`, at
  # `81fffa6` where the `reports` entry landed, and at every commit between.
  #
  # A number a run cannot reproduce is worse than no number, because the next
  # reader cites it instead of measuring it. That is the rule the
  # `templates/compose/mimir` comment in `tests/validate.sh` states for a path
  # added to a list to satisfy a stale README: the prose is the thing that rots.
  # "every copy this suite makes" was true before the packet and is true after
  # it; the count was never the claim, and pinning one made the true claim
  # unreviewable. `REPORT-kit-freshcopy-count-01.md` carries the method, the raw
  # output and the five points of instrumentation.
  #
  # TWO DIRECTIONS, and the second is the one worth a paragraph.
  #
  #   1. The FALSE RED, which is the loud one and which the control already names.
  #      `expect_green 'unbroken tree'` runs FIRST and prints "the gate is RED on
  #      an unbroken tree" — the sentence that makes every proof below it
  #      meaningless, and the exact symptom the `MIGRATIONS.md` paragraph above
  #      measured. The green-expecting proofs (23b, 31b, 59) go red with it, all
  #      three for a reason that had nothing to do with the defect under test,
  #      which is the failure mode this whole list exists to prevent. That half
  #      is a red suite, and it is at least legible.
  #
  #   2. The SILENT one, and it is the reason this is a check of the harness
  #      rather than a chore. 88 of this file's recipe invocations are
  #      `expect_red_check`, and `expect_red_check` appends `--only=<label>` to
  #      every child that does not already carry one — so the README check does
  #      not RUN in any of them and not one of the 88 ever sees this. What is
  #      left that does is the single plain `expect_red` in the file (breakage
  #      1), and `expect_red` asserts the gate's EXIT STATUS and nothing else:
  #      `the gate went red` is satisfied by a copy that is red for any reason at
  #      all. One recipe is not a number anybody would act on. It is the SHAPE
  #      that matters, because the direction of travel is one recipe per packet
  #      that adds an unfiltered assertion, and the day the count is large the
  #      suite reports "every proof held" while a growing share of the proofs
  #      proved nothing at all — the exact inverse of the false red, and the
  #      harder of the two to notice, because a suite that always goes red is at
  #      least reporting something true.
  #
  # So the rule is the one the paragraph above ends on, paid a third time — and
  # `reports/` is the packet that shows why writing it down is not enough. The
  # file, the README line and the `readme_check` list entry that names it ALL
  # landed in ONE commit, `81fffa6`, together with a header that documents the
  # coupling. So this was not a split across commits and not a case of somebody
  # forgetting a half: the packet did three of the four things a path the gate
  # reads by path requires, in one diff, on a tree whose own gate was green
  # throughout. Nothing in the packet was red and nothing in it looked unfinished.
  # The fourth thing lives in a file the packet had no reason to be reading, and
  # the only witness to its absence is a proof one level down that had been
  # silently passing — which is the shape no review of the packet's own diff can
  # catch, and the reason the honest form of the rule is the one above: the
  # receipt is a green `unbroken tree`, not a remembered step.
  for entry in .gitleaks.toml .github AGENTS.md README.md CHANGELOG.md LICENSE \
    DECISIONS.md MIGRATIONS.md RESERVED VERSION core docker lint reports \
    templates tests; do
    [ -e "$ROOT/$entry" ] && cp -R "$ROOT/$entry" "$dst/"
  done
  # KIT_GITLEAKS, unlike the other two, must ALSO be resolved before the first
  # copy runs. It is a fetched binary rather than a python script, so the copy's
  # `$root/.venv` — which does not exist, because fresh_copy does not copy the
  # gitignored venv — is not where it would be found. Without this, every copy
  # re-downloads a 15MB archive, and the twenty-odd copies this script makes per
  # gate run turn a 90-second suite into a twenty-minute one.
  #
  # Precedence is deliberately: the developer's own gitleaks, then the one this
  # tree fetched, then PATH. A developer's install may be a different version
  # and that is their business, exactly as it is for hadolint.
  if [ -z "${KIT_GITLEAKS:-}" ] && [ -x "$ROOT/tests/.bin/gitleaks" ]; then
    KIT_GITLEAKS="$ROOT/tests/.bin/gitleaks"
  fi
  export KIT_GITLEAKS="${KIT_GITLEAKS:-}"
  # Every script in tests/, not just the two entry points. `cp -R` does NOT
  # preserve the executable bit on macOS, so a copy arrives with every tests/
  # script non-executable — and the gate has a check for exactly that (the two
  # gate scripts are run BY the reusable workflow, so they must be executable).
  # Without this, every one of the twenty-odd copies fails that check, and the
  # control run reports the tree red for a reason that has nothing to do with
  # any breakage under test.
  chmod +x "$dst"/tests/*.sh 2>/dev/null || true
  printf '%s' "$dst"
}

# contains <haystack> <needle> — is `needle` present in `haystack`?
#
# A shell `case`, not `printf … | grep -qF`. See `expect_green_check` for the
# measurement and the 64K pipe-buffer threshold; the short version is that
# `grep -q` closes the pipe at the first match, `printf` dies of SIGPIPE, and
# `set -o pipefail` turns that 141 into the pipeline's exit status — so a proof
# of the form `! printf … | grep -qF x` reads a MATCH as a non-match once the
# output is large enough. Every such assertion in this file goes through here,
# which is also why the two helpers cannot disagree about how to read the output.
contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

# starts_with_line <text> <prefix> — does any LINE of `text` begin with `prefix`?
#
# A SECOND reader, and it exists because `contains` is the wrong tool for this
# one job. A bare substring test for `FAIL` matches the fleet check's own CEILING
# banner, which is printed on GREEN runs and contains the sentence "a finding
# inside a repository that has a kit.ref is a FAIL". So a check asking "did the
# gate report a finding?" would be answered YES by a passing gate — and the
# `env_skips` branch would then swallow every genuine environment failure and
# report them as caught defects. That is the inverse of the bug it replaced, and
# it is a reminder that a matcher loosened to stop false negatives will meet a
# false positive.
#
# Same reason as `contains` for not piping: a `grep -qE '^FAIL'` pipeline exits
# 141 on a report large enough to overflow the pipe buffer, with the match
# present. This walks the string in the shell instead. The trailing-newline
# question matters and is handled by the explicit newline before the first probe:
# `$out` from `$(…)` has its trailing newlines stripped, so a finding on the very
# last line would otherwise never be seen.
starts_with_line() {
  case "
$1" in
    *"
$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

# skip_row_naming <text> <needle> — does any `SKIP` row MENTION <needle>?
#
# A third reader, and the narrowest of the three. `contains` answers "is this
# string anywhere in the output"; `starts_with_line` answers "does a line begin
# with this". What `--no-live` has to be proved by is the conjunction: a line
# that BEGINS with `SKIP ` and NAMES the opt-out.
#
# Why the conjunction and not either half. `contains "$out" '--no-live'` is
# answered by the gate's own summary note — which is a second, independent line
# naming it, and fine on its own — and would be answered just as well by the
# usage block if a future `--help` dump ever reached a child's stdout. And
# `starts_with_line "$out" 'SKIP'` is answered by any skip at all, of which the
# interpreter floor already provides one. So the test a reader wants is: is there
# a row that says "this tier did not run, and here is the flag that says so".
#
# Same reason as the other two for not piping: the output is already in a
# variable, and `grep -q` closes the pipe on the first match, `printf` dies of
# SIGPIPE, and this file's `set -o pipefail` promotes 141 to the status of a
# pipeline that succeeded.
skip_row_naming() {
  local rest
  while IFS= read -r rest; do
    case "$rest" in
      SKIP\ *"$2"*) return 0 ;;
    esac
  done <<<"$1"
  return 1
}

# _stale_edit accumulates the recipes whose `edit` found nothing to replace. It
# is emptied by every shard guard that declines a recipe, so it can only ever be
# read by the check that owns the breakage which set it.
_stale_edit=""

# edit <file> <old> <new> — a textual breakage that FAILS LOUDLY if the source
# has been refactored past it. A self_test that silently stops breaking
# anything is worse than no self_test, so an unmatched edit is an error here.
#
# IT RECORDS RATHER THAN EXITS, and the loudness moved into `expect_red*`. The
# reason is the shard guard, and it was a real failure: `edit` runs EAGERLY,
# before the `expect_red*` call that is the only thing which knows which shard
# owns the recipe. So one stale recipe in one shard aborted every other shard —
# `KIT_SELF_TEST_SHARD=1/8` died on breakage 98's recipe having proved nothing
# about the twelve breakages it had already run. A rotten recipe is still
# evidence, but only against the shard that owns it, and it is reported as a
# FAIL of that breakage rather than as the death of the suite.
edit() {
  if ! "$PY" - "$1" "$2" "$3" <<'PY'
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
body = open(path, encoding="utf-8").read()
if old not in body:
    sys.exit(f"self_test: breakage no longer applies to {path}: {old!r} not found")
open(path, "w", encoding="utf-8").write(body.replace(old, new, 1))
PY
  then
    _stale_edit="$_stale_edit"$'\n'"    $1"
  fi
}

# copy_version <dir> — the version string the COPY carries.
#
# Out of the copy's own VERSION, never out of `$ROOT/VERSION`, and the reason is
# the suite's own rule about copies: a copy is a throwaway tree and the whole
# file depends on it being self-contained, so a recipe that read the version of
# the tree it happens to be running in would be asserting a fact about the
# machine rather than about the tree it is about to mutate. It is also why this
# is a function of the copy rather than a variable read once at the top: a
# suite-start read is correct only while every copy carries the same VERSION,
# and `fresh_copy` copies the live tree so that is true today — but it is true
# because of an accident of the copy list, not because anything says so, and a
# copy that overrode VERSION to test the MAJOR rule would silently break it.
#
# WHY THIS FUNCTION EXISTS AT ALL is `92a1127`. It did the right thing — a
# breaking change may not sit under `## Unreleased`, so the fix for breakage 98
# IS a release, and it moved VERSION 1.0.0 -> 2.0.0 — and three breakages it
# could not have read as related went with it. Its own message names 31b, 23b
# and 59: the breakages whose SYMPTOMS were legible. Four more named no symptom
# anyone could read, because "the recipe no longer applies to its copy" is a
# harness complaint rather than "the only proof that a MAJOR bump owes a
# migration has stopped running". Breakages 96, 97 and 99 anchored their
# mutations on the literal `1.0.0`, so one release detonated all three.
copy_version() {
  printf '%s' "$(head -1 "$1/VERSION")"
}

# bump <version> <major|minor> — the next version of that kind, DERIVED.
#
# It refuses anything it cannot decompose rather than deriving from a guess,
# because `${v%%.*}` on a string that is not N.N.N yields a version which looks
# derived and is not, and a recipe that wrote THAT would go on proving nothing
# while reading as though it had been fixed. The shape refused is the same one
# `stability_parse` refuses in the gate — `01.4.0` is one string and two
# numbers, and kit has no prerelease spelling — so the two cannot disagree about
# what a version is.
bump() {
  local why='' major minor patch
  if ! printf '%s' "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    why='it is not exactly three whole-number components'
  else
    major="${1%%.*}"
    minor="${1#*.}"
    minor="${minor%%.*}"
    patch="${1##*.}"
    # EACH COMPONENT IS CHECKED SEPARATELY, because the check is per component
    # and concatenating them first makes `2.0.0` read as the string `200`, whose
    # second character is a zero. A leading zero is one string and two numbers,
    # which is the reason `stability_parse` refuses `01.4.0`: arithmetic on it is
    # arithmetic on a typo, and `${1%%.*}` would carry the typo into the next
    # version. The exemption for a bare `0` is the same one semver makes, and it
    # is why `0.9.3` is a version this derives from rather than a refusal.
    for part in "$major" "$minor" "$patch"; do
      case "$part" in
        '' | *[!0-9]*) why='a component is not a number' ;;
        0?*) why='a component carries a leading zero' ;;
      esac
      [ -z "$why" ] || break
    done
  fi
  if [ -n "$why" ]; then
    printf 'self_test: cannot derive a %s bump from %s: %s. A recipe that derived from it anyway would write a version that looks derived and is not.\n' \
      "$2" "${1:-<empty>}" "$why" >&2
    return 1
  fi
  case "$2" in
    # The INCREMENT is what makes this a bump rather than a projection of the
    # current version: `2.0.0`'s next MAJOR is `3.0.0`, and a recipe that
    # derived `2.0.0` would mutate nothing and prove nothing.
    #
    # `10#` because `08` is an invalid octal in bash's arithmetic evaluation, so
    # a PATCH reaching 8 does not turn a version bump into a syntax error — the
    # same reason `stability_tier` writes it that way.
    major) printf '%s.0.0' "$((10#$major + 1))" ;;
    minor) printf '%s.%s.0' "$major" "$((10#$minor + 1))" ;;
    *)
      printf 'self_test: bump takes major or minor, not %s\n' "$2" >&2
      return 1
      ;;
  esac
}

# kit_child_gate <dir> <validate.sh args...> — the ONE way this file runs the gate.
#
# Every child gate gets `KIT_NO_LIVE=1`, i.e. `--no-live`, i.e. the observability
# live tier is turned into three named `SKIP` lines instead of three docker stacks.
#
# WHY, MEASURED RATHER THAN ASSUMED, and the measurement is in three parts.
#
# 1. Nothing here needs it. Every one of the 105 labelled recipes asserts a
#    verdict about ONE named check — `templates/compose/otel-collector.yml`,
#    `lint/ + the workflow`, `tests/classify.py`, `templates/parity-allowlist` —
#    and not one of the needles names `canary_test.sh`,
#    `no_telemetry_in_readiness.sh` or `stack_live_test.sh`. The count is 0 and
#    it is a count a check derives rather than a comment asserting:
#    `tests/validate.sh` reads the live tier's own three `live_check`
#    invocations, and fails if any recipe invocation mentions one.
#
#    (105 labelled invocations, 103 distinct breakage numbers: 78 and 79 are each
#    proven twice, once for the kamal config set and once for the callable
#    standard. The count is `validate.sh`'s own, so it cannot drift from the
#    label the gate prints.)
#
# 2. Only one recipe reached it anyway. `expect_red_check` filters every child
#    down to the single check it is about (`--only=$want`), and `bounded_check`
#    honours that filter, so the live tiers were already excluded from every
#    filtered run. The single exception is `expect_skip_check` — deliberately
#    unfiltered, because the string it must find is a SKIP's verdict text and not
#    a check's label — and that is breakage 23b alone. Counted on this tree, of the
#    93 invocations that run the gate at all, 84 pass `--static-only` and the other
#    9 are narrowed to the one check they assert; 23b is the single unfiltered one.
#    One whole gate out of 93.
#
# 3. That one gate was ~half its own wall clock. Profiled on this branch
#    (`KIT_PROFILE`, `--language=ruby --no-self-test`, an otherwise green run):
#    255.2s total, of which canary 19.1 + no_telemetry_in_readiness 63.6 +
#    stack_live 46.1 = 128.8s.
#
#    WHAT IS MEASURED AND WHAT IS REPORTED, kept apart on purpose. The profile
#    above is measured here. The red at position 23 of 104 is REPORTED — it came
#    with the packet, and it did not reproduce on this machine: 23b's own gate
#    run is green here, standalone and in a full suite run. So what this comment
#    claims is the EXPOSURE — one whole gate out of the suite, half of it docker,
#    running a tier the recipe does not assert — and not a failure anyone here
#    watched happen. `REPORT-kit-selftest-live-tier-01.md` §2 says the same thing
#    with the numbers behind it, which is the point of writing it down twice.
#
# WHY ONE FUNCTION AND NOT FIVE EDITS. A property written at five call sites is a
# property that one of them will stop having, and nothing in this file would say
# so — the suite would simply get slower and flakier, which is exactly the shape
# of a regression nobody can see. So `bash tests/validate.sh` appears ONCE in this
# file, inside this function, and `tests/validate.sh` fails if a second one
# appears. The check is the enforcement; the function is the documentation.
#
# IT IS NOT SILENCE, and the difference is the whole point. `--no-live` makes each
# of the three tiers a `report SKIP` naming the flag, counted in the child's skip
# tally and repeated in the child's summary. A child gate therefore says "I did
# not run these three, and here is why" rather than going quiet about them, which
# is what keeps breakage 23b honest: it asserts the gate is GREEN *and names its
# skip*, and it now names two kinds of skip instead of one.
kit_child_gate() {
  local dir="$1"
  shift
  (
    cd "$dir" || exit 1
    KIT_PYTHON="$PY" KIT_NO_LIVE=1 bash tests/validate.sh "$@"
  )
}

# expect_red <label> <dir> <validate.sh args...>
expect_red() {
  # Shard guard: a recipe outside this shard is not run at all, and is not
  # counted as a pass. See KIT_SELF_TEST_SHARD above.
  if ! _shard_claims "$1"; then
    _stale_edit=''
    return 0
  fi
  # A recipe whose `edit` matched nothing was EVALUATED, and what it evaluated to
  # is "this breakage no longer exists". Counting it as ran and reporting it as a
  # FAIL is the honest reading: the check below would otherwise pass by proving
  # that an unmutated tree is green. See `_stale_edit` above.
  if [ -n "$_stale_edit" ]; then
    printf 'FAIL self_test: %s — the recipe no longer applies to its copy:%s\n' "$1" "$_stale_edit"
    _stale_edit=''
    failures=$((failures + 1))
    _shard_ran=$((_shard_ran + 1))
    return 0
  fi
  _shard_ran=$((_shard_ran + 1))
  # PROFILE TAG, and it is the whole reason a profile can say anything about
  # this phase. Every recipe runs a whole `tests/validate.sh` in a throwaway copy
  # and those copies inherit `KIT_PROFILE` from the environment — so with the tag
  # set, every row a child writes is attributed to the BREAKAGE rather than to
  # the gate, which is otherwise indistinguishable from the gate's own ~200 rows
  # of identically-named checks. Without it the profile has one column and the
  # most expensive phase in the run is a column of repetitions.
  KIT_PROFILE_TAG="self_test $1"
  export KIT_PROFILE_TAG
  local label="$1" dir="$2"
  shift 2
  if kit_child_gate "$dir" "$@" >/dev/null 2>&1; then
    printf 'FAIL self_test: %s — the gate stayed GREEN\n' "$label"
    failures=$((failures + 1))
  else
    printf 'PASS self_test: %s — the gate went red\n' "$label"
  fi
}

# expect_red_check <label> <dir> <check-label> <validate.sh args...>
#
# The stronger form of expect_red, and the one the layout/documentation checks
# need. `the gate went red` is a weak proof when forty checks can make it red:
# a breakage can be caught by the wrong check and still read as a pass, and the
# check it was written for can be dead code forever. This asserts that ONE
# named check reported FAIL, so a check that stops being load-bearing fails
# here rather than being discovered months later by the defect it missed.
#
# The check label is matched as a literal prefix of the FAIL line, so it is the
# exact label validate.sh prints. A rename on either side breaks this loudly,
# which is the intended behaviour: a renamed check and a stale proof are the
# same defect.
#
# THE MATCH IS A SUBSTRING TEST ON THE VARIABLE, NOT `printf | grep -q`, and it
# has to be. `grep -q` exits at the FIRST match and closes the pipe, so the
# writer takes SIGPIPE and dies 141 — and this script runs under `set -o
# pipefail`, which promotes that 141 to the status of the whole pipeline. The
# `if` then reads a match as a NON-match.
#
# That is not theoretical here; it is what the first run of this merge
# produced. Breakage 11 (hadolint) and breakage 42 (the working-tree
# credential) both produce a gate run larger than the 64KB pipe buffer, and both
# were reported as "the gate went red, but NOT via `<the check that fired>`" —
# while printing that very check among the FAIL lines it had just proven was
# there. Underneath the threshold it matches; at or above it, the proof of the
# best-behaved check in the file failed for a reason that had nothing to do with
# the check. Same defect `tests/canary_test.sh` already records for
# `docker logs | grep -q`, and the same rule answers it here: the output is
# ALREADY captured in a variable, so there is no reason to introduce a pipe at
# all. Matching the variable is not merely safer than the pipe — it makes the
# assertion independent of how much the gate prints, which is a property the
# piped version did not have.
expect_red_check() {
  # Shard guard: a recipe outside this shard is not run at all, and is not
  # counted as a pass. See KIT_SELF_TEST_SHARD above.
  if ! _shard_claims "$1"; then
    _stale_edit=''
    return 0
  fi
  # A recipe whose `edit` matched nothing was EVALUATED, and what it evaluated to
  # is "this breakage no longer exists". Counting it as ran and reporting it as a
  # FAIL is the honest reading: the check below would otherwise pass by proving
  # that an unmutated tree is green. See `_stale_edit` above.
  if [ -n "$_stale_edit" ]; then
    printf 'FAIL self_test: %s — the recipe no longer applies to its copy:%s\n' "$1" "$_stale_edit"
    _stale_edit=''
    failures=$((failures + 1))
    _shard_ran=$((_shard_ran + 1))
    return 0
  fi
  _shard_ran=$((_shard_ran + 1))
  # PROFILE TAG, and it is the whole reason a profile can say anything about
  # this phase. Every recipe runs a whole `tests/validate.sh` in a throwaway copy
  # and those copies inherit `KIT_PROFILE` from the environment — so with the tag
  # set, every row a child writes is attributed to the BREAKAGE rather than to
  # the gate, which is otherwise indistinguishable from the gate's own ~200 rows
  # of identically-named checks. Without it the profile has one column and the
  # most expensive phase in the run is a column of repetitions.
  KIT_PROFILE_TAG="self_test $1"
  export KIT_PROFILE_TAG
  local label="$1" dir="$2" want="$3"
  shift 3
  local out ec=0
  # `--only=$want`, unless the caller already passed a filter of its own.
  #
  # THIS IS THE 60x. Measured on this machine before the change: one full
  # `--static-only` gate run is ~50s and there are 76 breakages, so the suite
  # spends ~63 MINUTES. The reason is that every breakage re-ran all 214 checks
  # to learn one fact about the single check it names -- roughly 16,000 check
  # runs where 76 were asked for.
  #
  # `$want` is the check this breakage is ABOUT, and the assertion below is that
  # exactly that check goes red. Running the other 213 cannot change that
  # verdict. So the filter narrows WHICH checks run; it does not loosen WHAT
  # they must prove, which is why this is sound and why it belongs here rather
  # than in an assertion.
  #
  # Skipped when the caller supplied its own `--only`, because two filters would
  # be an AND and a breakage that names a check its caller already filtered out
  # would find nothing and fail for a reason that has nothing to do with the
  # defect under test.
  case " $* " in
    *" --only="*) ;;
    *) set -- "$@" "--only=$want" ;;
  esac
  out=$(kit_child_gate "$dir" "$@" 2>&1) || ec=$?
  # A shell pattern, not `printf … | grep -qF`.
  #
  # `grep -q` exits the instant it matches, so a large `$out` gives `printf`
  # SIGPIPE while it is still writing. `set -o pipefail` — which this file sets
  # — then reports 141 for a pipeline that SUCCEEDED, and a passing breakage
  # reads as "the gate went red, but NOT via <the named check>".
  #
  # It hit breakage 30, whose check emits several hundred lines of report and
  # therefore the first output in this file big enough to overflow the 64K pipe
  # buffer. Breakages 7-29 all pass on a small enough output, which is the worst
  # shape a latent defect has: it looks like a failure of the thing under test
  # and is actually a failure of the harness reading it.
  #
  # Measured, not reasoned about: 2000 lines of output still returns 0 and 5000
  # returns 141, on the same match and the same grep. The threshold is a property
  # of the pipe buffer, so it would move with the machine — which is why the fix
  # is to stop piping rather than to bound the output. It now goes through the
  # same `contains` helper as `expect_green_check` and `expect_skip_check`, so
  # the three cannot drift apart on the one thing they all have to get right.
  if contains "$out" "FAIL $want"; then
    printf 'PASS self_test: %s — caught by `%s`\n' "$label" "$want"
  else
    # A gate that exited non-zero having reported NO finding at all is not a red
    # gate — it is a gate that never ran, and reporting it as "the gate went red,
    # but not via <the named check>" blames the check for an environment failure.
    # The distinction matters because the two demand opposite responses: a red
    # means the mutation escaped, a non-finding exit means this machine was too
    # busy, the tree was incomplete, or a tool was missing.
    #
    # It is not hypothetical. Under load average 15 on a 16GB box, kit-19's own
    # full gate reported breakage 35 this way — `exit 1` with an empty finding
    # list — and the only honest description is that the recipe could not be
    # evaluated. Breakage 39 already exists for the same reason and asserts the
    # EXPLANATION rather than the exit status, on the principle that a red which
    # misattributes itself sends the next reader to the wrong file.
    #
    # `validate.sh` exits 1 on a FAIL, 2 on a usage error, and (line 132, 3195)
    # 1 from bootstrap when it cannot install its own dependencies — the last of
    # which prints its reason and never reaches a single check. So: a non-zero
    # exit WITH findings is a real red; a non-zero exit with NONE is an
    # environment failure, and it is named as one rather than counted as a
    # breakage the check failed to catch.
    #
    # `starts_with_line`, and NOT `printf … | grep -qE '^(FAIL|SKIP)'`. This is
    # the same broken-pipe defect the `FAIL $want` test above was fixed for —
    # fixed there and missed here, and the consequence is measured rather than
    # argued: on a 239KB gate report whose findings sit at the TOP, the piped form
    # exits **141** with the match present, so `! pipeline` is true and a gate
    # that printed `FAIL: 1 check(s) failed.` was classified as having reported no
    # finding at all.
    #
    # The mechanism is that `grep -q` closes the pipe on its first match,
    # `printf` dies of SIGPIPE, and `set -o pipefail` promotes 141 to the
    # pipeline's status. So the verdict flips on the size of the output rather
    # than on what is in it, and the threshold is a property of the pipe buffer —
    # it would move with the machine and come back as a flake on somebody else's
    # packet. It is also the *worst* direction to be wrong in: the failure mode is
    # a real red being excused as a machine problem, which is the outcome this
    # counter was added to prevent being lost. Four breakages (71, 75, 76, 77)
    # were reported as ENVIRONMENT failures on a run where every one of them had
    # in fact been caught.
    #
    # `starts_with_line` rather than a bare `contains 'FAIL'`, and the reason is
    # measured too: the fleet check's CEILING banner is printed on GREEN runs and
    # contains the sentence "…a finding inside a repository that has a kit.ref is
    # a FAIL". A substring test is therefore answered YES by a passing gate, and
    # this branch would swallow every genuine environment failure and report it
    # as a caught defect — the exact inverse of the bug being fixed. A matcher
    # loosened to stop reporting false negatives meets a false positive; see the
    # helper for the full argument.
    if [ "$ec" -ne 0 ] \
       && ! starts_with_line "$out" 'FAIL' \
       && ! starts_with_line "$out" 'SKIP'; then
      printf 'SKIP self_test: %s — the gate exited %s with NO finding reported\n' \
        "$label" "$ec"
      printf '%s\n' "$out" | tail -5 | sed 's/^/       /'
      printf '       This is an ENVIRONMENT failure, not a check that failed to\n'
      printf '       catch its defect. Treating it as a red would blame\n'
      printf '       `%s` for a machine problem.\n' "$want"
      env_skips=$((env_skips + 1))
      return
    fi
    if [ "$ec" -eq 0 ]; then
      printf 'FAIL self_test: %s — the gate stayed GREEN\n' "$label"
    else
      printf 'FAIL self_test: %s — the gate went red, but NOT via `%s`\n' "$label" "$want"
      printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/       /'
    fi
    failures=$((failures + 1))
  fi
}

# expect_green_check <label> <dir> <check-label> <needle> <validate.sh args...>
#
# The mirror of `expect_red_check`, and it exists for exactly one case: a
# finding the gate is supposed to report WITHOUT failing on. "The gate stayed
# green" is necessary but far too weak — the gate is green on a tree where the
# fleet check crashed, or exited 2 and had its SKIP swallowed, or printed
# nothing at all. So this asserts BOTH halves:
#
#   1. the named check reported PASS, and
#   2. `needle` — a literal string from the finding — is in the output.
#
# (1) alone is the "silently skipped" failure this repository keeps warning
# about, and (2) alone would be satisfied by a check that printed the word
# somewhere. Together they are the claim: *this* check passed, and it passed
# while telling you about this specific thing.
#
# BOTH halves match the VARIABLE with a shell pattern, and never with
# `printf … | grep -qF`. That is the same rule `expect_red_check` already follows
# for the reason documented at length there: `grep -q` exits at the FIRST match
# and closes the pipe, `printf` takes SIGPIPE and dies 141, `set -o pipefail`
# promotes that 141 to the pipeline's status, and `!` then reads a match as a
# NON-match.
#
# It is not theoretical HERE either, and this helper had the defect that
# `expect_red_check` had already been repaired for. Breakage 59 asserted the
# adoption ceiling stayed green and named its finding, and it began failing the
# moment kit's gate output crossed the 64K pipe buffer — which is exactly what
# `license_check` printing its measurement on PASS did, correctly, as
# `check`'s own contract requires of a check that reports WHICH SPEC it verified.
# So the gate grew, the harness read the growth as a defect in the ceiling, and
# reported a proof red that had in fact passed:
#
#     FAIL self_test: breakage 59: … the gate stayed GREEN but
#       `fleet  (adopting repositories clean;` did not report PASS
#     tests/self_test.sh: line 589: printf: write error: Broken pipe
#
# The two possible fixes were to stop the check printing, or to stop the harness
# piping. Stopping the check printing was the wrong one twice over: it would
# contradict `check`'s documented behaviour, and the threshold it hides behind
# is a property of the pipe buffer, so it would move with the machine and the
# bug would come back as a flake on somebody else's packet. The output was
# already captured in a variable; there is no reason to pipe at all.
expect_green_check() {
  # Shard guard: a recipe outside this shard is not run at all, and is not
  # counted as a pass. See KIT_SELF_TEST_SHARD above.
  if ! _shard_claims "$1"; then
    _stale_edit=''
    return 0
  fi
  # A recipe whose `edit` matched nothing was EVALUATED, and what it evaluated to
  # is "this breakage no longer exists". Counting it as ran and reporting it as a
  # FAIL is the honest reading: the check below would otherwise pass by proving
  # that an unmutated tree is green. See `_stale_edit` above.
  if [ -n "$_stale_edit" ]; then
    printf 'FAIL self_test: %s — the recipe no longer applies to its copy:%s\n' "$1" "$_stale_edit"
    _stale_edit=''
    failures=$((failures + 1))
    _shard_ran=$((_shard_ran + 1))
    return 0
  fi
  _shard_ran=$((_shard_ran + 1))
  # PROFILE TAG, and it is the whole reason a profile can say anything about
  # this phase. Every recipe runs a whole `tests/validate.sh` in a throwaway copy
  # and those copies inherit `KIT_PROFILE` from the environment — so with the tag
  # set, every row a child writes is attributed to the BREAKAGE rather than to
  # the gate, which is otherwise indistinguishable from the gate's own ~200 rows
  # of identically-named checks. Without it the profile has one column and the
  # most expensive phase in the run is a column of repetitions.
  KIT_PROFILE_TAG="self_test $1"
  export KIT_PROFILE_TAG
  local label="$1" dir="$2" want="$3" needle="$4"
  shift 4
  local out ec=0
  # DELIBERATELY NOT FILTERED, and this is `expect_skip_check`'s defect again,
  # in the one helper whose reach table nobody ran.
  #
  # `--only` matches a check's LABEL, and it is applied inside `check`,
  # `check_par`, `report_par` and `bounded_check` — the four that spawn work.
  # `report()` (`tests/validate.sh:351`) has no filter of its own: every
  # `PASS`/`FAIL`/`SKIP` it emits is printed and counted unconditionally. The
  # verdict this recipe names is emitted by a `report`:
  #
  #     tests/validate.sh:5474  report PASS "fleet  (adopting repositories clean; …)"
  #
  # So no `--only` value can select it, and the gate's own no-match rule turns
  # "selected NO check" into `exit 1` — which is the correct behaviour and which
  # fails this recipe's FIRST assertion, on a filter rather than on a defect:
  #
  #     FAIL self_test: breakage 59: an UNADOPTED service copies the stack —
  #       green, and named — the gate went RED (exit 1), so the ceiling is not in force
  #            FAIL: --only='fleet  (adopting repositories clean;' selected NO check
  #                   out of the suite.
  #                   87 check(s) were excluded.
  #
  # Read that failure carefully, because it is the worst direction to be wrong
  # in: it accuses the ADOPTION CEILING of not being in force, and prints a green
  # gate's own findings underneath. The ceiling was in force throughout. This is
  # the same shape as breakage 23b — a green-expecting proof reported red for a
  # reason with nothing to do with the property under test — and the two cost the
  # same thing: a filter whose correctness depends on a string that is not a
  # filterable label.
  #
  # It is the SEVENTH conversion and the one the reach table in
  # REPORT-kit-gate-speed-02.md §4b never measured: that table walked the six
  # `expect_red_check` conversions, and `expect_green_check` is a DIFFERENT
  # helper with a DIFFERENT single caller. A conversion nobody ran is a
  # conversion nobody proved.
  #
  # The whole gate is the correct trade here, exactly as it is in
  # `expect_skip_check`: it costs ~35s on one recipe out of 94. The alternative is
  # a filter that names nothing, or one that names some unrelated `check` while
  # the verdict being asserted is a `report` — a decoration on the command line
  # that proves nothing about the thing the recipe is about, which is the
  # weakened gate this file exists to refuse.
  #
  # `KIT_FINGERPRINT=0` is the OTHER HALF of the shared cache directory set at the
  # top of this file, and it is the half that protects this helper specifically.
  # This proof asserts that the gate STAYS GREEN and names what it said — and a
  # cache hit is a green that no check ran to produce. With one cache shared
  # across the copies, the verdict this recipe exists to establish ("an
  # UNADOPTED service copies the stack: green, and the debt is still named")
  # could be satisfied by a record an EARLIER copy wrote, on a tree this recipe
  # had not yet mutated. That is a control that goes green for a reason it did
  # not introduce — the same shape as a control that goes red for one, and
  # AGENTS.md is explicit that both are the defect. Two tokens, one recipe's
  # worth of cache, and it is the difference between this recipe running the gate
  # and reading its verdict, and this recipe reading a verdict off disk.
  # `expect_skip_check` is the only other helper that asserts GREEN, and it
  # carries the same two tokens for the same reason.
  out=$(export KIT_FINGERPRINT=0; kit_child_gate "$dir" "$@" 2>&1) || ec=$?
  if [ "$ec" -ne 0 ]; then
    printf 'FAIL self_test: %s — the gate went RED (exit %s), so the ceiling is not in force\n' \
      "$label" "$ec"
    printf '%s\n' "$out" | grep -E '^(FAIL|  -|       )' | tail -20 | sed 's/^/       /'
    failures=$((failures + 1))
  elif ! contains "$out" "PASS $want"; then
    printf 'FAIL self_test: %s — the gate stayed GREEN but `%s` did not report PASS\n' \
      "$label" "$want"
    printf '%s\n' "$out" | grep -E '^(FAIL|SKIP)' | tail -20 | sed 's/^/       /'
    failures=$((failures + 1))
  elif ! contains "$out" "$needle"; then
    # The dangerous one. A green run that said nothing is a check that ran
    # nothing, and it is exactly what a deleted ceiling looks like from here.
    printf 'FAIL self_test: %s — GREEN, but the finding was never named (no %q)\n' \
      "$label" "$needle"
    printf '%s\n' "$out" | sed -n '/fleet/,+4p' | sed 's/^/       /'
    failures=$((failures + 1))
  else
    printf 'PASS self_test: %s — stayed green and named the debt\n' "$label"
  fi
}

# expect_red_script <label> <dir> <script> <args...>
#
# For the two scripts that ARE a proof rather than a gate over a tree:
# classify_test.sh asserts the classifier fails closed, staleness_test.sh asserts
# the reporter tells the states apart. Breaking one of them and asserting THAT
# script goes red is the same claim expect_red_check makes — the check written
# for this defect is still load-bearing — expressed over a script.
expect_red_script() {
  # Shard guard: a recipe outside this shard is not run at all, and is not
  # counted as a pass. See KIT_SELF_TEST_SHARD above.
  if ! _shard_claims "$1"; then
    _stale_edit=''
    return 0
  fi
  # A recipe whose `edit` matched nothing was EVALUATED, and what it evaluated to
  # is "this breakage no longer exists". Counting it as ran and reporting it as a
  # FAIL is the honest reading: the check below would otherwise pass by proving
  # that an unmutated tree is green. See `_stale_edit` above.
  if [ -n "$_stale_edit" ]; then
    printf 'FAIL self_test: %s — the recipe no longer applies to its copy:%s\n' "$1" "$_stale_edit"
    _stale_edit=''
    failures=$((failures + 1))
    _shard_ran=$((_shard_ran + 1))
    return 0
  fi
  _shard_ran=$((_shard_ran + 1))
  # PROFILE TAG, and it is the whole reason a profile can say anything about
  # this phase. Every recipe runs a whole `tests/validate.sh` in a throwaway copy
  # and those copies inherit `KIT_PROFILE` from the environment — so with the tag
  # set, every row a child writes is attributed to the BREAKAGE rather than to
  # the gate, which is otherwise indistinguishable from the gate's own ~200 rows
  # of identically-named checks. Without it the profile has one column and the
  # most expensive phase in the run is a column of repetitions.
  KIT_PROFILE_TAG="self_test $1"
  export KIT_PROFILE_TAG
  local label="$1" dir="$2" script="$3" want="${5:-}"
  shift 3
  # The optional 4th argument (always pass an empty one) is where a script's own
  # arguments go; the optional 5th is a string the output MUST contain. A proof
  # that goes red for the wrong reason is not a proof, and the one case that
  # needs the stronger claim is a red that would otherwise be MISREPORTED — so
  # the name is unchanged and the pattern in validate.sh still matches, rather
  # than a new helper that would read as an undocumented breakage.
  if (cd "$dir" && KIT_PYTHON="$PY" bash "$script" "$@" >/dev/null 2>&1); then
    printf 'FAIL self_test: %s — the proof stayed GREEN\n' "$label"
    failures=$((failures + 1))
  elif [ -n "$want" ]; then
    local out
    out=$(cd "$dir" && KIT_PYTHON="$PY" bash "$script" "$@" 2>&1) || true
    if grep -qF "$want" <<<"$out"; then
      printf 'PASS self_test: %s — the proof went red, and said why\n' "$label"
    else
      printf 'FAIL self_test: %s — the proof went red but did NOT say %s\n' "$label" "$want"
      printf '%s\n' "$out" | grep -E '^(FAIL|PASS)' | sed 's/^/       /'
      failures=$((failures + 1))
    fi
  else
    printf 'PASS self_test: %s — the proof went red\n' "$label"
  fi
}

# expect_green_script <label> <dir> <script> [script args...]
#
# The green direction for a PROOF rather than for the gate, and it is here for
# exactly one recipe (61b) because the other three that use it would be measuring
# themselves against nothing.
#
# Deliberately NOT matched by the `self_test_claims` pattern in validate.sh, so
# `61b` is a control rather than a numbered breakage — the same choice 31b made,
# and for the same reason: the header counts red-expecting recipes, and a green
# control listed among them would make the header claim a breakage that nothing
# breaks. It is written in the header as prose instead.
expect_green_script() {
  # Shard guard: a recipe outside this shard is not run at all, and is not
  # counted as a pass. See KIT_SELF_TEST_SHARD above.
  if ! _shard_claims "$1"; then
    _stale_edit=''
    return 0
  fi
  # A recipe whose `edit` matched nothing was EVALUATED, and what it evaluated to
  # is "this breakage no longer exists". Counting it as ran and reporting it as a
  # FAIL is the honest reading: the check below would otherwise pass by proving
  # that an unmutated tree is green. See `_stale_edit` above.
  if [ -n "$_stale_edit" ]; then
    printf 'FAIL self_test: %s — the recipe no longer applies to its copy:%s\n' "$1" "$_stale_edit"
    _stale_edit=''
    failures=$((failures + 1))
    _shard_ran=$((_shard_ran + 1))
    return 0
  fi
  _shard_ran=$((_shard_ran + 1))
  # PROFILE TAG, and it is the whole reason a profile can say anything about
  # this phase. Every recipe runs a whole `tests/validate.sh` in a throwaway copy
  # and those copies inherit `KIT_PROFILE` from the environment — so with the tag
  # set, every row a child writes is attributed to the BREAKAGE rather than to
  # the gate, which is otherwise indistinguishable from the gate's own ~200 rows
  # of identically-named checks. Without it the profile has one column and the
  # most expensive phase in the run is a column of repetitions.
  KIT_PROFILE_TAG="self_test $1"
  export KIT_PROFILE_TAG
  local label="$1" dir="$2" script="$3"
  shift 3
  local out
  if out=$(cd "$dir" && KIT_PYTHON="$PY" bash "$script" "$@" 2>&1); then
    printf 'PASS self_test: %s — the proof is green\n' "$label"
  else
    printf 'FAIL self_test: %s — the proof went RED on an unbroken tree\n' "$label"
    printf '%s\n' "$out" | grep -E '^(FAIL|SKIP)' | sed 's/^/       /'
    failures=$((failures + 1))
  fi
}

# expect_skip_check <label> <dir> <check-label> <validate.sh args...>
#
# The other direction, and it exists because 23b asserts something no other
# helper can. `expect_red*` proves a check CATCHES a defect; this proves a check
# can be load-bearing while the gate stays green — which is the interpreter
# floor's whole job. The floor turns a red gate into a skip; "the gate went
# red" says nothing about whether it did, and "the gate went green" is
# satisfied just as well by a check that was deleted entirely.
#
# So this asserts BOTH halves of the honest-reporting claim — the gate exited 0,
# and the named check is what said so — and, because this helper is also the one
# that runs a whole UNFILTERED gate (and therefore a child that opted out of
# the observability live tier), a THIRD: that a `SKIP` row names `--no-live`.
# The three are listed, and why, at the assertion itself.
#
# `contains`, for the reason given at `expect_green_check`: the output is already
# in a variable, and piping it into `grep -q` makes the answer depend on how much
# of it there is.
expect_skip_check() {
  # Shard guard: a recipe outside this shard is not run at all, and is not
  # counted as a pass. See KIT_SELF_TEST_SHARD above.
  if ! _shard_claims "$1"; then
    _stale_edit=''
    return 0
  fi
  # A recipe whose `edit` matched nothing was EVALUATED, and what it evaluated to
  # is "this breakage no longer exists". Counting it as ran and reporting it as a
  # FAIL is the honest reading: the check below would otherwise pass by proving
  # that an unmutated tree is green. See `_stale_edit` above.
  if [ -n "$_stale_edit" ]; then
    printf 'FAIL self_test: %s — the recipe no longer applies to its copy:%s\n' "$1" "$_stale_edit"
    _stale_edit=''
    failures=$((failures + 1))
    _shard_ran=$((_shard_ran + 1))
    return 0
  fi
  _shard_ran=$((_shard_ran + 1))
  # PROFILE TAG, and it is the whole reason a profile can say anything about
  # this phase. Every recipe runs a whole `tests/validate.sh` in a throwaway copy
  # and those copies inherit `KIT_PROFILE` from the environment — so with the tag
  # set, every row a child writes is attributed to the BREAKAGE rather than to
  # the gate, which is otherwise indistinguishable from the gate's own ~200 rows
  # of identically-named checks. Without it the profile has one column and the
  # most expensive phase in the run is a column of repetitions.
  KIT_PROFILE_TAG="self_test $1"
  export KIT_PROFILE_TAG
  local label="$1" dir="$2" want="$3"
  shift 3
  local out ec=0
  # DELIBERATELY NOT FILTERED, and this is the one helper where `--only` cannot be
  # reached the way it is in `expect_red_check` and `expect_green_check`.
  #
  # `$want` here is the SKIP's own verdict text — `templates/otel/ruby  (ruby
  # 2.6.10 is below the template's 2.7 floor)` — and the label `--only` matches on
  # is the check's label, `templates/otel/ruby  (ruby test suite)`. They are two
  # different strings. Filtering on the verdict text selects no check, and
  # `validate.sh` turns "selected NO check" into `exit 1`, so this recipe's FIRST
  # assertion (`the gate exited 0, so the skip was not clean`) would fail on a
  # filter typo rather than on a defect.
  #
  # It did exactly that, on the first run of the `--only` reach:
  #
  #     FAIL self_test: breakage 23b: an interpreter below the floor is a named
  #     skip, not a silent pass — the gate exited 1, so the skip was not clean
  #
  # A green-expecting proof reported red for a reason that had nothing to do with
  # the interpreter floor, which is the failure mode `fresh_copy`'s path list
  # exists to prevent and which this file keeps warning about. The whole gate is
  # the correct trade here: it costs ~35 s on one recipe out of 94, and the
  # alternative is a filter whose correctness depends on a string that is not the
  # label.
  #
  # `KIT_FINGERPRINT=0`, for the reason `expect_green_check` above spells out: this
  # is a green-expecting proof, and a replayed cache hit is a green no check ran
  # to produce. The interpreter floor is what is under test here, so a skip
  # answered off disk would be exactly the silent pass this recipe exists to
  # distinguish from a named one.
  # A child gate runs with `--no-live`, so THIS recipe's own child is one of the
  # gates that opts out — and this is where that becomes a proof rather than a
  # claim. Three assertions, in order:
  #
  #   1. the gate exited 0, so the interpreter skip was clean;
  #   2. the interpreter skip was NAMED, which is what this recipe has always
  #      asserted; and
  #   3. a `SKIP` ROW names `--no-live`.
  #
  # (3) is the asymmetry the whole opt-out lives or dies on, and it is a
  # different failure from (1). Deleting the three `bounded_check` calls outright
  # satisfies (1) and (2) perfectly — the gate is greener than ever, and it
  # still names the ruby floor — while proving nothing at all about the live
  # tier. A patch that turns the opt-out into silence passes every exit-status
  # assertion in this file. So the assertion is on the ROW, not on the status,
  # and it is asserted here in the one helper that runs a whole unfiltered gate
  # rather than in a comment in `validate.sh` where nobody would watch it fail.
  out=$(export KIT_FINGERPRINT=0; kit_child_gate "$dir" "$@" 2>&1) || ec=$?
  if [ "$ec" -ne 0 ]; then
    printf 'FAIL self_test: %s — the gate exited %s, so the skip was not clean\n' "$label" "$ec"
    printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/       /'
    failures=$((failures + 1))
  elif ! contains "$out" "SKIP $want"; then
    printf 'FAIL self_test: %s — the gate stayed green but never said `%s`\n' "$label" "$want"
    printf '%s\n' "$out" | grep '^SKIP' | sed 's/^/       /'
    failures=$((failures + 1))
  elif ! skip_row_naming "$out" '--no-live'; then
    printf 'FAIL self_test: %s — green, and the floor was named, but NO `SKIP` row names\n' "$label"
    printf '       `--no-live`. The exit status alone cannot tell that apart from a patch\n'
    printf '       that deleted the observability live tiers outright, which is a gate that\n'
    printf '       runs less and reports less and is therefore green for a worse reason.\n'
    printf '       Every SKIP the child did report:\n'
    printf '%s\n' "$out" | grep '^SKIP' | sed 's/^/       /'
    failures=$((failures + 1))
  else
    printf 'PASS self_test: %s — reported as `%s`, and named the --no-live skips too\n' \
      "$label" "$want"
  fi
}


# ONE run, and its output is CAPTURED rather than re-fetched.
#
# The first version ran the gate twice: once discarding the output to read the
# exit status, and again to print the diagnostic. That is a second chance to
# lose the throwaway tree, and on the run where it mattered it lost it — the
# control was reported as
#
#   FAIL self_test: unbroken tree — the gate is RED on an unbroken tree
#   self_test.sh: line 223: cd: /tmp/kit-self-test.XXXX/base: No such file or directory
#
# which is a diagnosis of the DIAGNOSTIC, not of the gate. The gate had already
# said something; nobody could read it. `|| ec=$?` rather than a bare assignment
# is what keeps `set -e` from killing the harness before the status is read —
# the same trap `expect_red_lang` documents, and the reason it is written out
# again here rather than shared: the harness has no library.
expect_green() {
  # Shard guard: a recipe outside this shard is not run at all, and is not
  # counted as a pass. See KIT_SELF_TEST_SHARD above. Every sibling helper has
  # this; this one did not, which is why it was worth writing down rather than
  # fixing silently — a helper that does not count is a helper a sharded run
  # silently skips while still claiming a number.
  if ! _shard_claims "$1"; then
    _stale_edit=''
    return 0
  fi
  # A recipe whose `edit` matched nothing was EVALUATED, and what it evaluated to
  # is "this breakage no longer exists". Counting it as ran and reporting it as a
  # FAIL is the honest reading: the check below would otherwise pass by proving
  # that an unmutated tree is green. See `_stale_edit` above.
  if [ -n "$_stale_edit" ]; then
    printf 'FAIL self_test: %s — the recipe no longer applies to its copy:%s\n' "$1" "$_stale_edit"
    _stale_edit=''
    failures=$((failures + 1))
    _shard_ran=$((_shard_ran + 1))
    return 0
  fi
  _shard_ran=$((_shard_ran + 1))
  # PROFILE TAG, and it is the whole reason a profile can say anything about
  # this phase. Every recipe runs a whole `tests/validate.sh` in a throwaway copy
  # and those copies inherit `KIT_PROFILE` from the environment — so with the tag
  # set, every row a child writes is attributed to the BREAKAGE rather than to
  # the gate, which is otherwise indistinguishable from the gate's own ~200 rows
  # of identically-named checks. Without it the profile has one column and the
  # most expensive phase in the run is a column of repetitions.
  KIT_PROFILE_TAG="self_test $1"
  export KIT_PROFILE_TAG
  local label="$1" dir="$2"
  shift 2
  local out ec=0
  if [ -d "$dir" ]; then
    out="$(kit_child_gate "$dir" "$@" 2>&1)" || ec=$?
  else
    # Distinct from a red gate, because it is: the tree is gone, not failing.
    printf 'FAIL self_test: %s — the throwaway copy %s does not exist\n' "$label" "$dir"
    printf '       Every worker on this machine mktemps under the same TMPDIR, so a\n'
    printf '       sibling that deleted its own tree broadly can delete this one. That\n'
    printf '       is an environment failure and NOT evidence about the gate.\n'
    failures=$((failures + 1))
    return
  fi
  if [ "$ec" -eq 0 ]; then
    printf 'PASS self_test: %s — the gate is green on an unbroken tree\n' "$label"
  else
    printf 'FAIL self_test: %s — the gate is RED on an unbroken tree (exit %s)\n' "$label" "$ec"
    printf '%s\n' "$out" | grep -E '^(FAIL|note:|  -|       )' | tail -20 | sed 's/^/       /'
    failures=$((failures + 1))
  fi
}

# expect_red_lang <label> <dir> <lang> <file> <old> <new>
#
# The per-language mutation. Copies one implementation out, breaks one spec rule
# in it, and asserts THAT language's suite goes red — not the whole gate, and
# certainly not a neighbouring language's. A green result here means the suite
# for that language asserts nothing about that rule.
#
# Each mutant is semantic: it compiles, it parses, it runs. Replacing a call with
# a syntax error would prove only that the toolchain is installed, which is not
# in question.
expect_red_lang() {
  # Shard guard: a recipe outside this shard is not run at all, and is not
  # counted as a pass. See KIT_SELF_TEST_SHARD above.
  if ! _shard_claims "$1"; then
    _stale_edit=''
    return 0
  fi
  # A recipe whose `edit` matched nothing was EVALUATED, and what it evaluated to
  # is "this breakage no longer exists". Counting it as ran and reporting it as a
  # FAIL is the honest reading: the check below would otherwise pass by proving
  # that an unmutated tree is green. See `_stale_edit` above.
  if [ -n "$_stale_edit" ]; then
    printf 'FAIL self_test: %s — the recipe no longer applies to its copy:%s\n' "$1" "$_stale_edit"
    _stale_edit=''
    failures=$((failures + 1))
    _shard_ran=$((_shard_ran + 1))
    return 0
  fi
  _shard_ran=$((_shard_ran + 1))
  # PROFILE TAG, and it is the whole reason a profile can say anything about
  # this phase. Every recipe runs a whole `tests/validate.sh` in a throwaway copy
  # and those copies inherit `KIT_PROFILE` from the environment — so with the tag
  # set, every row a child writes is attributed to the BREAKAGE rather than to
  # the gate, which is otherwise indistinguishable from the gate's own ~200 rows
  # of identically-named checks. Without it the profile has one column and the
  # most expensive phase in the run is a column of repetitions.
  KIT_PROFILE_TAG="self_test $1"
  export KIT_PROFILE_TAG
  local label="$1" dir="$2" lang="$3" file="$4" old="$5" new="$6"
  local work="$WORK/mutant-$lang"

  # No counter is incremented here. This function USED to carry its own
  # `breakages=$((breakages + 1))`, and the omission it was written to fix is
  # the reason this file counts by grepping itself at the end instead: a counter
  # incremented in three of four helpers had already under-reported once (the
  # summary said "all 23" while twenty-nine had run), and a count that
  # under-reports is worse than no count, because it reads as though proofs were
  # missing rather than as a bug in the counter.

  rm -rf "$work"
  cp -R "$dir/templates/otel/$lang" "$work"

  if ! edit "$work/$file" "$old" "$new" 2>/dev/null; then
    # `edit` fails when the source has moved past the mutation. That is a real
    # failure: the proof this breakage was written to provide no longer exists.
    printf 'FAIL self_test: %s — the mutation no longer applies\n' "$label"
    printf '       %s\n' "$file"
    failures=$((failures + 1))
    return
  fi

  # A missing toolchain is a SKIP, reported as such. It is not a pass: an
  # unexecuted mutation proves nothing, and the summary counts it.
  local runner
  case "$lang" in
    go) runner=go ;;
    ruby) runner=ruby ;;
    elixir) runner=elixir ;;
    python) runner=python3 ;;
    node) runner=node ;;
    rust) runner=rustc ;;
  esac
  if ! command -v "$runner" >/dev/null 2>&1; then
    printf 'SKIP self_test: %s — %s not installed\n' "$label" "$runner"
    skips=$((skips + 1))
    return
  fi

  # Captured immediately, with no `&&` between the run and the read, and each
  # capture guarded by `|| ec=$?`.
  #
  # Both halves of that matter, and the first version of this function got the
  # first one wrong in a way that made the whole self_test exit 1 silently at
  # breakage 6, printing nothing at all:
  #
  #   - `out=$(cmd)` on its own line is an ASSIGNMENT. When `cmd` fails, the
  #     assignment's status is `cmd`'s status, so `set -e` kills the script on
  #     that line — before the `ec=$?` beneath it ever runs. The failing suite
  #     was never observed; the harness simply vanished. Guarding with `||`
  #     makes the command part of a list, which `set -e` does not apply to, so
  #     the run completes and its status can be read. This is the same failure
  #     PLAN.md's gate-discipline rule is about, one level down: a gate whose
  #     exit code was not observed is unrun, not green.
  #   - `&& ec=0 || ec=$?` is the obvious wrong fix: it reports the status of
  #     the `||` branch rather than the run's.
  local out ec=0
  case "$lang" in
    go)
      out=$(cd "$work" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local go test ./... 2>&1) || ec=$?
      ;;
    ruby) out=$(ruby "$work/test_traceparent.rb" 2>&1) || ec=$? ;;
    elixir) out=$(elixir -r "$work/traceparent.ex" "$work/test_traceparent.exs" 2>&1) || ec=$? ;;
    python) out=$(python3 "$work/test_traceparent.py" 2>&1) || ec=$? ;;
    node) out=$(node --test "$work/traceparent.test.mjs" 2>&1) || ec=$? ;;
    rust)
      if rustc --test --edition 2021 -o "$work/kit-mutant-rust" "$work/traceparent.rs" \
        >"$work/build.log" 2>&1; then
        out=$("$work/kit-mutant-rust" 2>&1) || ec=$?
      else
        # A mutant that does not compile proves NOTHING. The suite went red
        # without running, which is indistinguishable from a green suite to any
        # harness that only reads the exit code — and a mutation that breaks the
        # build instead of the behaviour means the spec rule under test was
        # never reached. This is its own verdict, not a pass.
        printf 'FAIL self_test: %s — the mutant did not compile, so the suite never ran\n' "$label"
        sed 's/^/       /' "$work/build.log"
        failures=$((failures + 1))
        return
      fi
      ;;
  esac

  if [ "$ec" -eq 0 ]; then
    printf 'FAIL self_test: %s — the suite stayed GREEN on a broken codec\n' "$label"
    # Printed here and nowhere else, because this is the one branch where the
    # output is the diagnosis: a green run tells you the rule is unasserted, and
    # the run tells you which test file claims to assert it.
    printf '%s\n' "$out" | tail -20 | sed 's/^/       /'
    failures=$((failures + 1))
  else
    printf 'PASS self_test: %s\n' "$label"
  fi
}

# fixture_fleet <name> — a throwaway FLEET for the four breakages below.
#
# WHY A FIXTURE AND NOT THE REAL ONE. The fleet gate is red on master, by design
# and on purpose. If these breakages ran against the real sibling checkouts, every
# one of them would be red before it started — and `expect_red_check` answers
# "did THAT NAMED check go red", so a tree that is red for an unrelated reason
# makes the proof meaningless in the one direction that matters. A fixture is
# green, so a red can only have come from the breakage.
#
# It is also what makes the proofs hermetic. They need a fleet-shaped directory
# with two repositories in it, and building two is cheaper and more predictable
# than depending on whoever is checked out next to kit on the machine.
#
# FIXTURE SHAPE, and each part is load-bearing:
#   alpha/  a service that has adopted the stack: a `kit.ref` with a real pin,
#           a compose file that is a genuine OVERRIDE (its own service, no
#           `ports:`, nothing kit ships), and no collector config of its own.
#   beta/   the same, so a breakage aimed at alpha cannot be masked by beta and a
#           check that only ever looks at the first repository is caught.
#
# `.git` is a directory, not a worktree marker file, because fleet_check.py skips
# worktrees — a fixture that looked like a worktree would be skipped and every
# breakage below would pass vacuously.
fixture_fleet() {
  # Two `local`s and not one. `local name="$1" root="…$name"` reads `name` while
  # it is still being assigned, so `root` is built from whatever `name` happened
  # to be — empty on the first call, so every fixture would be written to one
  # directory and the breakages would share it and mask each other. shellcheck
  # says so (SC2318), and the symptom is four proofs that all pass or all fail
  # together.
  local name="$1"
  # `fixtures/`, not `$WORK` directly — for the reason `fresh_copy` writes to
  # `copies/`. A fixture fleet is a fleet of REPOSITORIES, each with a `.git`;
  # anywhere a later `expect_red_check` can discover one, an earlier breakage's
  # still-broken `alpha` makes the next breakage red for the wrong reason. Only
  # the four fleet breakages set `KIT_FLEET`, and they point it here.
  local root="$WORK/fixtures/$name"
  rm -rf "$root"
  mkdir -p "$root/alpha" "$root/beta"
  local svc
  for svc in alpha beta; do
    mkdir -p "$root/$svc/.git"
    printf '# %s: the kit this service runs.\n41f8bcb919e34b14e7c809cbb22e24b74ec25099\n' \
      "$svc" >"$root/$svc/kit.ref"
    cat >"$root/$svc/docker-compose.yml" <<'YAML'
# This service's own file, as an OVERRIDE beside the fetched stack. It owns its
# image and its own database name, and nothing that kit already ships.
services:
  alpha:
    image: cafaye/alpha:dev
    environment:
      POSTGRES_DB: alpha
    depends_on:
      postgres:
        condition: service_healthy
    networks: [platform]
YAML
  done
  printf '%s' "$root"
}

# break_stale_copy <fixture> — give `alpha` a `postgres` of its own.
#
# FACTORED OUT of breakage 52 because breakage 60 needs the identical mutation,
# and the two halves of the adoption-ceiling proof are only a proof if they are
# the SAME defect in the SAME shape. Two hand-written copies of a nine-line
# YAML mutation would drift, and the drift would show up as "60 went green
# because it was mutating something else" — which is indistinguishable from
# "60 proved the ceiling is airtight".
#
# The mutation is the real shape rather than a toy: a service that names its
# database `db` and pins `postgres:17`. The service name is `db` and not
# `postgres` on purpose, because that is what five of the six repositories in
# scope actually do, and the check keys on the IMAGE.
break_stale_copy() {
  "$PY" - "$1/alpha/docker-compose.yml" <<'PYEOF'
import sys

path = sys.argv[1]
body = open(path, encoding="utf-8").read()
old = "  alpha:\n    image: cafaye/alpha:dev"
new = (
    "  db:\n    image: postgres:17\n    environment:\n      POSTGRES_USER: alpha\n"
    "      POSTGRES_DB: alpha\n    ports:\n      - \"15500:5432\"\n"
    "    volumes:\n      - alpha-pg:/var/lib/postgresql/data\n    healthcheck:\n"
    "      test: [\"CMD\", \"pg_isready\", \"-U\", \"alpha\"]\n"
    "      interval: 10s\n      timeout: 5s\n      retries: 5\n"
    "  alpha:\n    image: cafaye/alpha:dev"
)
if old not in body:
    sys.exit(f"self_test: break_stale_copy: {old!r} not in {path}")
open(path, "w", encoding="utf-8").write("volumes:\n  alpha-pg:\n" + body.replace(old, new, 1))
PYEOF
}

# break_stale_copy_no_ports — the SAME copy, minus the `ports:` line.
#
# One difference from `break_stale_copy`, and it is the whole point: without a
# published port `check_override_surface` has nothing to report, so the ONLY
# thing in the fixture that can turn the gate red is `check_stale_copy`'s IMAGE
# comparison. Breakage 60 keeps the port and so can be satisfied by either half;
# this one cannot be satisfied by either half but the right one, which is what
# makes it a proof that the image predicate is load-bearing rather than a proof
# that some check somewhere went red.
#
# Factored rather than inlined for the same reason `break_stale_copy` was: two
# hand-written copies of this mutation would drift, and the drift would show up
# as "75 went green because it was mutating something else".
break_stale_copy_no_ports() {
  "$PY" - "$1/alpha/docker-compose.yml" <<'PYEOF'
import sys

path = sys.argv[1]
body = open(path, encoding="utf-8").read()
old = "  alpha:\n    image: cafaye/alpha:dev"
# Byte-for-byte `break_stale_copy`'s copy EXCEPT the `ports:` stanza, which is
# the one line that lets a different check report the same defect.
new = (
    "  db:\n    image: postgres:17\n    environment:\n      POSTGRES_USER: alpha\n"
    "      POSTGRES_DB: alpha\n"
    "    volumes:\n      - alpha-pg:/var/lib/postgresql/data\n    healthcheck:\n"
    "      test: [\"CMD\", \"pg_isready\", \"-U\", \"alpha\"]\n"
    "      interval: 10s\n      timeout: 5s\n      retries: 5\n"
    "  alpha:\n    image: cafaye/alpha:dev"
)
if old not in body:
    sys.exit(f"self_test: break_stale_copy_no_ports: {old!r} not in {path}")
if 'ports:' in new:
    sys.exit("self_test: break_stale_copy_no_ports: this copy must not publish a "
             "port, or check_override_surface can report the defect instead and "
             "the image predicate stops being load-bearing")
open(path, "w", encoding="utf-8").write("volumes:\n  alpha-pg:\n" + body.replace(old, new, 1))
PYEOF
}

# unadopt <fixture> — remove every `kit.ref` in a fixture fleet.
#
# Every repository, not just `alpha`. The ceiling is per-repository, and a
# fixture where `beta` still adopted would be testing two things at once: that
# an unadopted repository warns, and that a clean adopting repository passes.
# Both are worth proving, but not in one recipe, and not when a failure of the
# first cannot be told from a failure of the second.
unadopt() {
  find "$1" -name kit.ref -type f -delete
}

printf -- '-- self_test: a gate that cannot fail is not a gate\n'

# --------------------------------------------------------------------------
# THE SYNTHETIC FLEET
# --------------------------------------------------------------------------
#
# `tests/gate_declaration_check.py` sweeps a directory of adopting
# repositories — `gate.yml` plus the workflow it names. There is no such
# directory inside kit, for the same reason `tests/staleness_test.sh` builds its
# own: kit is one repository and the fleet is fifteen, and a check that read the
# real working directory would be green on Tuesday and red on Wednesday for a
# reason that has nothing to do with what it checks.
#
# So a clean one is built here, once, and `KIT_FLEET` points every run of
# `validate.sh` in this script at it. Two consequences, both wanted:
#
#   * the control below becomes the fleet check's POSITIVE case. A sweep that
#     only ever runs on a red fleet has proved it can fail and nothing about
#     whether it is right;
#   * a breakage mutates its OWN copy of the fleet and nothing else, so
#     breakages cannot mask each other, exactly as `fresh_copy` guarantees for
#     the rest of this file.
#
# It is a two-file repository on purpose. Both are the real spellings: a
# one-line `run:` in the workflow, and a proof pattern with no escape token —
# which is the state every repository in this fleet is supposed to be in.
FLEET="$WORK/fleet"

synthetic_repo() {
  local root="$FLEET/$1"
  mkdir -p "$root/.github/workflows"
  cat > "$root/gate.yml" <<'YAML'
# gate.yml — the clean shape. One line per proof, no escape tolerance, and a
# `ci` block naming the workflow below.
version: 1
name: synthetic

gate:
  command: [bin/prime]
  entrypoint: bin/prime
  proof:
    - id: suite
      match: '^([0-9]+)/[0-9]+ passed$'
      minimum: 12

external:
  selfContained: true
  requirements: []

ci:
  workflow: .github/workflows/ci.yml
  invokes: [bin/prime]
YAML
  cat > "$root/.github/workflows/ci.yml" <<'YAML'
name: ci
on: [push]
jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: bin/prime
        run: ./bin/prime
YAML
}

# A second, differently-named repository, so the sweep has to enumerate rather
# than read one hardcoded path — and so a check that only ever saw one name
# could not pass.
synthetic_repo clean
synthetic_repo second-clean

# Exported once, so every `validate.sh` invocation below sweeps THIS fleet
# rather than whatever happens to sit beside the throwaway copy. A prefix
# assignment on a function call would not do: in bash an assignment preceding a
# FUNCTION call persists after it returns, so breakage 24 would silently
# redirect breakage 25's sweep.
#
# THE FLEET IS REBUILT BY `fresh_fleet` FOR EVERY RECIPE, AND RESTORED AFTER
# THE LAST ONE. Both halves are load-bearing, and the second half was a real
# cross-packet failure rather than a hypothetical:
#
#   * `fresh_fleet` is called again after this point, so the *clean* pair below
#     is only the starting state, not the state every later recipe sees.
#   * the last fleet recipe leaves a DELIBERATELY BROKEN repository in `$FLEET`
#     — that is the whole mechanism, a sweep that cannot go red proves nothing.
#     With `KIT_FLEET` still exported, every gate run after it inherits that
#     broken repository. The integration branch hit this exactly: breakage 31b,
#     which asserts the gate is GREEN on a copy whose config matches kit's,
#     failed with `FAIL adopting repositories (no workaround for a fixed core
#     defect)` — a red created by another test, which is the exact failure mode
#     this harness exists to prevent.
#
# So the fleet is put back the way it was found before the file does anything
# else. `unset` rather than a reset value, because the honest state of the
# environment on entry is "unset" — and a recipe that must not see a fleet then
# gets the same behaviour it would get outside this file.
unset KIT_FLEET

# The control. If the unbroken tree is already red, the breakages below
# prove nothing, so this runs first and the run is meaningless without it.
base="$(fresh_copy base)"
expect_green 'unbroken tree' "$base" --static-only

# 1. a deleted language template. Caught by the artifact-presence check, which
#    runs with no toolchains at all — so "nobody had Go installed" can never be
#    the reason a missing template passes.
#
#    THE ONE RECIPE `--only` CANNOT REACH, and it is worth saying why rather than
#    leaving it looking like an oversight. The verdict that catches this deletion
#    is `templates/otel/go/  (4 artifacts present)`, and that is a `report`, not a
#    `check`. `--only` is applied inside `check`, `check_par`, `bounded_check`
#    and `tier` — the four things that spawn work — and `report` is called
#    directly by the phase, so a filtered run still prints every `report`
#    verdict and still pays for it.
#
#    Measured, not assumed: this copy run with `--only=ZZZ_NO_SUCH_CHECK_XYZ` (a
#    filter that matches nothing) printed `FAIL templates/otel/go/  (4 artifacts
#    present)` and nothing else. There is no `--only` value that selects it,
#    because it is not selected by anything. So this recipe keeps the unfiltered
#    gate, and pays the full static phase for a verdict no filter can narrow.
one="$(fresh_copy missing-template)"
rm -f "$one/templates/otel/go/traceparent.go"
expect_red 'breakage 1: templates/otel/go/traceparent.go deleted' "$one" --static-only

# The labels the recipes below pass to `expect_red_check`, which appends
# `--only=<label>` to the child gate's command line. They are variables because a
# label a self-test asserts is a contract (see AGENTS.md): a rename on either
# side has to break this file loudly, and a label typed twice is two chances not
# to.
COLLECTOR='templates/compose/otel-collector.yml  (redaction first, env endpoints, no URL)'
PORTS='docker-compose.yml  (host ports all in the 15000-15999 block, no reuse)'
CI_OPTIN='.github/workflows/ci.reusable.yml  (opt-in telemetry job, defaults intact)'

# 2. the privacy boundary, in the shape the check actually forbids. This recipe
#    mutated `exporters: [debug]` -> `exporters: [debug, otlp]`, which was the
#    traces pipeline as it stood before the collector fanned out to three
#    backends. The pipeline now reads `[spanmetrics, otlp/tempo, debug]`, the
#    string is gone, and `edit` refused to apply it — which is the right
#    behaviour (a stale mutation recipe must not silently pass) and is also why
#    the gate went red on breakage 2 and never reached 3.
#
#    The mutation below therefore ADDS the exporter the check warns about by
#    name: a bare `otlp` with an endpoint a developer could paste, sitting
#    beside the three backends it has no business next to.
two="$(fresh_copy exporting-collector)"
edit "$two/templates/compose/otel-collector.yml" \
  '  otlp/tempo:
' \
  '  otlp:
    endpoint: ${env:KIT_TEMPO_OTLP_ENDPOINT}
  otlp/tempo:
'
edit "$two/templates/compose/otel-collector.yml" \
  'exporters: [spanmetrics, otlp/tempo, debug]' \
  'exporters: [spanmetrics, otlp/tempo, debug, otlp]'
expect_red_check 'breakage 2: collector gains an exporter nobody read' \
  "$two" "$COLLECTOR" --static-only

# 2b. THE OTHER HALF OF THE SAME CLAIM, and the one a set difference never
#     checked. Breakage 2 above proves the gate objects to an exporter that
#     should not be there; this proves it objects to a BACKEND THAT IS MISSING.
#     A config whose only exporter is `debug` satisfies "nothing unexpected"
#     while shipping no observability at all — a stack that collects everything
#     and prints it. Deleting the whole tempo exporter block takes out the
#     definition and the pipeline reference together, which is what deleting it
#     in review would actually look like.
two_b="$(fresh_copy missing-backend)"
edit "$two_b/templates/compose/otel-collector.yml" \
  '      exporters: [spanmetrics, otlp/tempo, debug]' \
  '      exporters: [spanmetrics, debug]'
"$PY" - "$two_b/templates/compose/otel-collector.yml" <<'PY'
import re
import sys

# Drop the whole `otlp/tempo:` block by indentation, the same way the canary
# test removes one — a regex anchored on the next key does not survive the
# comment block that sits between the exporters.
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
start = next(i for i, line in enumerate(lines) if line.rstrip("\n") == "  otlp/tempo:")
end = start + 1
while end < len(lines) and (not lines[end].strip() or lines[end].startswith("    ")):
    end += 1
open(path, "w", encoding="utf-8").write("".join(lines[:start] + lines[end:]))
PY
expect_red_check 'breakage 2b: the collector ships no exporter for tempo at all' \
  "$two_b" "$COLLECTOR" --static-only

# 3. a template that compiles, parses, and silently drops the sampled flag.
#    Only an executed suite catches this; no grep would.
three="$(fresh_copy broken-codec)"
edit "$three/templates/otel/python/traceparent.py" \
  'flags & SAMPLED' '0 & SAMPLED'
expect_red_check 'breakage 3: python codec stops preserving trace-flags' "$three" \
  'templates/otel/python' --language=python --no-self-test

# 4. a hardcoded host port. The kind of edit nobody notices in review and every
#    second service on a laptop hits.
#
#    The default this one used to pin was 5432. That was correct when
#    docker-compose.yml was the only compose file in kit; the observability work
#    moved every published port into the 15000-15999 block, so the literal this
#    replaced no longer exists and `edit` refused — which is why the gate went
#    red here having passed 1, 2, 2b and 3. The recipe is now pinned to the port
#    actually shipped, so this breakage is the one a reviewer would really make:
#    taking the default out of the substitution.
four="$(fresh_copy hardcoded-port)"
edit "$four/templates/compose/docker-compose.yml" \
  '"${KIT_POSTGRES_PORT:-15500}:5432"' '"5432:5432"'
expect_red_check 'breakage 4: docker-compose.yml hardcodes a published port' \
  "$four" "$PORTS" --static-only

# 5. a kit change that would break every consumer's CI. The opt-in job must stay
#    opt-in and the six original jobs must stay gated on their language.
five="$(fresh_copy ci-not-opt-in)"
edit "$five/.github/workflows/ci.reusable.yml" "default: 'false'" "default: 'true'"
expect_red_check "breakage 5: the telemetry CI job is no longer opt-in" \
  "$five" "$CI_OPTIN" --static-only

# 6. the option with no job. A caller can pass `language: none` — the value
#    that lets a repository with no service manifest (kit among them) call this
#    workflow at all — and get a green build that ran nothing, because the job
#    is no longer guarded by the input that selects it. The drift AGENTS.md
#    calls out for any new `language` option, proven on the one option whose
#    absence is a broken call rather than a missing toolchain.
six="$(fresh_copy ungated-config-job)"
edit "$six/.github/workflows/ci.reusable.yml" \
  "if: \${{ inputs.language == 'none' }}" \
  "if: \${{ inputs.language == 'go' }}"
expect_red_check 'breakage 6: the `none` job is no longer gated on its own input' \
  "$six" "$CI_OPTIN" --static-only

# 7-10. The four ways the layout and the documentation can drift apart. These
#      are the class of defect this packet exists to make detectable: a stated
#      fact — "callers write `uses: cafaye/kit/.github/workflows/...`" — that
#      stops being true while every other check stays green. Each names the
#      specific check that must catch it, because "the gate went red" is a weak
#      claim when the callable check is one of forty that could have gone red.
CALLABLE='reusable workflows  (callable: exists, on: workflow_call, docs agree)'

# 7. The documented call points at a file that EXISTS. `ci.yml` is right there
#    in the same directory, so a typo that resolves to a real path is invisible
#    to any check that only asks "is there a file at the documented path" — and
#    a `uses:` line naming `ci.yml` gets a caller a workflow that is not
#    reusable at all. Only a comparison against the real path catches it.
seven="$(fresh_copy doc-points-elsewhere)"
edit "$seven/README.md" \
  'uses: cafaye/kit/.github/workflows/ci.reusable.yml@master' \
  'uses: cafaye/kit/.github/workflows/ci.yml@master'
expect_red_check 'breakage 7: README documents a `uses:` path that is not the reusable workflow' \
  "$seven" "$CALLABLE" --static-only

# 8. The file is in the right place and still cannot be called. `on:
#    workflow_call` removed is a legal-looking workflow that GitHub rejects
#    before it reads one input, so every caller gets a red build with no
#    explanation. Parseable is not callable.
eight="$(fresh_copy not-callable)"
edit "$eight/.github/workflows/ci.reusable.yml" \
  '  workflow_call:' '  workflow_dispatch:'
expect_red_check 'breakage 8: the workflow no longer declares `on: workflow_call`' \
  "$eight" "$CALLABLE" --static-only

# 9. A second copy, parked where the documented path does not point. This is the
#    other layout the packet offered — canonical file plus a thin callable
#    copy — and it is only acceptable with a check that fails when the copies
#    differ. kit chose the move, so the gate refuses to find a second one at
#    all. Two CI standards is the drift this repository exists to prevent.
nine="$(fresh_copy divergent-copy)"
mkdir -p "$nine/workflows"
cp "$nine/.github/workflows/ci.reusable.yml" "$nine/workflows/ci.reusable.yml"
expect_red_check 'breakage 9: a second copy of the reusable workflow, out of reach' \
  "$nine" "$CALLABLE" --static-only

# 10. kit's own CI stops calling itself locally, and reaches across the network
#     to some other ref instead. The job still runs and still goes green, so
#     this is invisible — but the job was the proof. A self-proof that fetches
#     `master` proves that master's path works, not that this commit's does.
#
#     The `edit` anchor includes the job name, and not because the job name is
#     interesting. The bare `uses:` line occurs twice in that file — once in the
#     comment explaining why the self-call exists, once in the job — and a
#     first-match replacement hit the comment, left the job alone, and reported
#     the gate stayed GREEN. Which was the check being right and the mutation
#     being sloppy: a `uses:` line inside a comment is documentation, and the
#     callable check deliberately does not read it.
ten="$(fresh_copy self-call-not-local)"
edit "$ten/.github/workflows/ci.yml" \
  '    name: gate
    uses: ./.github/workflows/ci.reusable.yml' \
  '    name: gate
    uses: cafaye/kit/.github/workflows/ci.reusable.yml@master'
expect_red_check 'breakage 10: kit CI calls a remote ref instead of its own local copy' \
  "$ten" "$CALLABLE" --static-only

# 11-12. The Dockerfiles. These are one of the four artifacts every adopting
#       service inherits, and until this packet they were the only artifact in
#       the tree with no parser at all — seven `SKIP ... (no parser for this
#       file type)` lines that nobody had to look at twice because the summary
#       said "note: 7 skipped".
#
#       A skipped check proves nothing (PLAN.md §1), so each breakage asserts a
#       NAMED check went red, and the two breakages target the two different
#       claims: the linter, and the rules the linter does not cover.
DOCKERLINT='docker/Dockerfile.*  (non-root final stage, no :latest, no ADD)'

# 11. A Dockerfile defect only hadolint can see. `pip install uv` with no
#     version is DL3013, and it was in the tree the whole time — a resolver
#     whose version silently decides what your lockfile resolves to.
eleven="$(fresh_copy unpinned-pip)"
edit "$eleven/docker/Dockerfile.python" \
  'RUN pip install "uv==${UV_VERSION}" \' 'RUN pip install uv \'
expect_red_check 'breakage 11: a Dockerfile pins nothing (hadolint DL3013)' \
  "$eleven" 'docker/Dockerfile.python  (hadolint)' --static-only

# 12. A Dockerfile defect hadolint does NOT see: the final stage dropped its
#     USER, so the image would run as root. hadolint has no rule for this —
#     DL3002 ("last USER should not be root") only fires when a USER is
#     present and wrong, and a missing USER is silence. This is the check that
#     has to exist precisely because the real parser cannot cover it.
twelve="$(fresh_copy dockerfile-as-root)"
# `USER 65532:65532`, not `USER nonroot:nonroot`. The Go runtime stage stopped
# naming distroless's user when it moved to `debian:*-slim` — distroless ships
# that account, Debian does not, and a Dockerfile that names a user the base does
# not have fails at `docker run`, not at build — so the line became numeric. The
# recipe did not fail quietly when it stopped matching: it printed "breakage no
# longer applies", which is the behaviour this suite wants, and then failed the
# run. Which is the right outcome, and the reason this comment exists: a recipe
# whose subject moved is a proof of nothing, and the loud version of that is
# better than the quiet version but is still a red gate.
#
# AND THE STRING MUST APPEAR EXACTLY ONCE IN THE FILE. `edit` replaces the FIRST
# occurrence, so when the Go template's STRICTNESS NOTES still quoted that
# directive while explaining why it was numeric, this recipe removed the QUOTE
# and left the instruction — and breakage 12 reported "the gate stayed GREEN",
# which is a proof of nothing wearing a proof's label. The notes were reworded
# not to repeat an instruction verbatim; that is the durable half of the fix, and
# the reason is general: a comment that copies an instruction is a mutation a
# check can be aimed at instead of the instruction. The same file already records
# the mirror-image lesson, "a check that a comment can satisfy is not a check".
edit "$twelve/docker/Dockerfile.go" 'USER 65532:65532' '# USER removed'
expect_red_check 'breakage 12: a Dockerfile final stage runs as root' \
  "$twelve" "$DOCKERLINT" --static-only

# 13-18. One semantic mutation per language implementation, each against a
# different spec rule, and each asserting THAT language's suite goes red.
#
# These all read from the same throwaway copy as breakage 1 rather than taking a
# fresh one each: the copy is only mutated inside a per-language temp dir, so no
# language can see another's breakage.
base="$(fresh_copy language-mutants)"

#   go    §3.2.2.5  stop masking trace-flags on read. Still compiles, still runs,
#                  and quietly forwards reserved bits to the next service.
expect_red_lang 'breakage 13: go stops masking trace-flags (§3.2.2.5)' \
  "$base" go traceparent.go \
  'Flags:      tp.Flags & sampledFlag,' \
  'Flags:      tp.Flags,'

#   ruby  §3.2.2  widen the alphabet to accept uppercase hex. The classic bug:
#                one service folds case, the next rejects the header, and a trace
#                breaks at the hop between them.
expect_red_lang 'breakage 14: ruby accepts uppercase hex (§3.2.2)' \
  "$base" ruby traceparent.rb \
  '!str.empty? && str.match?(/\A[0-9a-f]+\z/)' \
  '!str.empty? && str.match?(/\A[0-9a-fA-F]+\z/)'

#   elixir §3.2.2.2  stop rejecting trailing data on a version-00 header. Nothing
#                   crashes; the header is just no longer the format we claim to
#                   implement.
expect_red_lang 'breakage 15: elixir accepts trailing junk on version 00 (§3.2.2.2)' \
  "$base" elixir traceparent.ex \
  'defp check_trailing(value, 0), do: if(byte_size(value) == @min_header_len, do: :ok, else: {:error, :invalid})' \
  'defp check_trailing(_value, 0), do: :ok'

#   node  §3.3.1.5  raise the tracestate limit until truncation never fires. A
#                   limit nobody enforces is a limit nobody wrote on purpose.
expect_red_lang 'breakage 16: node never truncates tracestate (§3.3.1.5)' \
  "$base" node traceparent.mjs \
  'const TRACESTATE_LIMIT = 512;' \
  'const TRACESTATE_LIMIT = 100000;'

#   rust  §3.2.2.3  accept an all-zero trace-id. The spec forbids it outright; a
#                   codec that allows it merges unrelated traces into one.
expect_red_lang 'breakage 17: rust accepts an all-zero trace-id (§3.2.2.3)' \
  "$base" rust traceparent.rs \
  'if trace_id == ZERO_TRACE_ID || parent_id == ZERO_SPAN_ID {' \
  'if parent_id == ZERO_SPAN_ID {'

#   python §3.2.2.5  the same dropped mask as go, in a different language, on
#                   purpose: a rule asserted in one suite and not the other is a
#                   rule two services will disagree about.
expect_red_lang 'breakage 18: python stops masking trace-flags (§3.2.2.5)' \
  "$base" python traceparent.py \
  'flags=parsed.flags & SAMPLED,' \
  'flags=parsed.flags,'

# 19. THE UNUSED ALLOWLIST ENTRY. The rule that stops the skip allowlist from
#     becoming a list of every test in the repository, and the one most likely to
#     be decorative — a hygiene rule in a data file, which is exactly the shape
#     of a check nobody has ever seen fail.
#
#     The mutation is the realistic one: somebody fixed the skip, or renamed the
#     test, and left the entry behind. The entry it appends is well-formed in
#     every OTHER respect — it has a reason, an owner, a since, an until, and it
#     is not a duplicate. It is only unused, which is precisely the failure the
#     rule exists to catch and precisely the one a shape-only check would pass.
#
#     This asserts the NAMED check, because a tree can go red for a dozen
#     unrelated reasons and "the gate went red" would not prove that the unused
#     -entry rule is what rejected it.
ALLOWLIST='templates/tier/skip-allowlist  (reason, owner, since, until; unused entries fail)'

nineteen="$(fresh_copy unused-allowlist-entry)"
cat >>"$nineteen/templates/tier/skip-allowlist" <<'ENTRY'
skipped db go/tier_db_test.go TestTierDBRenamedAway reason="the test this was written for was renamed; the entry outlived it" owner=kit since=2026-09-30 until=2026-12-31
ENTRY
expect_red_check 'breakage 19: an allowlist entry that matches nothing' \
  "$nineteen" "$ALLOWLIST" --static-only
# 20-22. The core fan-out. Three breakages, and the middle one is the sharpest
#       proof in this file: it INVERTS the fail-closed property and asserts the
#       suite notices. Every other breakage proves a check can fail; this one
#       proves the property is load-bearing rather than asserted in a comment.

# 20. The trap that is not loud. `includePaths` nested under `git:` is dropped
#     silently by vendir's unmarshalling, and the sync then vendors the ENTIRE
#     upstream repository while exiting 0. It was run before it was written down;
#     see core/vendir/README.md. A config that reads correctly and does the
#     opposite of what it says is the worst class of defect to ship, so the gate
#     names the specific check.
COREFANOUT='core/vendir/ + core/renovate/  (structurally what Renovate and vendir need)'

twenty="$(fresh_copy include-paths-under-git)"
edit "$twenty/core/vendir/vendir.yml.pantry" \
  '        newRootPath: schemas
        git:
          url: https://github.com/cafaye/core.git
          ref: master' \
  '        newRootPath: schemas
        git:
          url: https://github.com/cafaye/core.git
          ref: master
          includePaths:
          - schemas/cafaye.manifest.schema.json'
expect_red_check 'breakage 20: includePaths nested under `git:` (vendors everything, exits 0)' \
  "$twenty" "$COREFANOUT" --static-only

# 21. THE SHARPEST ONE. Break the classifier so an UNRECOGNISED change is
#     reported as WIRE instead of FILE — that is, make it fail OPEN. Every test
#     in classify_test.sh that asserts a failure is now asserting nothing, and
#     the suite must go red rather than quietly reporting 16 passes.
#
#     This is the difference between "the classifier fails closed" as a claim in
#     a README and as a property with a counterexample. The counterexample is
#     here, in the gate, and it is one line long: which is the point. The
#     fail-closed property is one `if` returning `"FILE"`, and the only thing
#     standing between that `if` and a fleet-wide silent break is this test.
#
#     It edits `unrecognisedIsBreaking` in tests/rules.json rather than a string in
#     Python, and that is the entire reason the value lives there. The first
#     version of this breakage inverted a hardcoded "FILE" inside classify.py and
#     the suite stayed GREEN - because the same tier was ALSO a rule in
#     rules.json, so the headline case never reached the line that was broken.
#     A property stated in two places is a property stated in neither, and the
#     duplication was invisible until something tried to break it.
twentyone="$(fresh_copy classifier-fails-open)"
edit "$twentyone/tests/rules.json" \
  '"unrecognisedIsBreaking": true' '"unrecognisedIsBreaking": false'
expect_red_script 'breakage 21: the classifier FAILS OPEN on an unrecognised change' \
  "$twentyone" tests/classify_test.sh

# 22. The opposite error, and it is the expensive direction. Reporting a
#     repository with no recorded core pin as `current` makes the fleet look
#     clean. Two of the real repositories are in exactly that state today —
#     `caf` and `pantry` hold vendored bytes with no recorded origin — so the
#     difference between `undeclared` and `current` is the difference between a
#     report and a rumour.
twentytwo="$(fresh_copy undeclared-reads-current)"
edit "$twentytwo/tests/staleness.py" '    return UNDECLARED' '    return CURRENT'
expect_red_script 'breakage 22: the staleness reporter calls an undeclared pin current' \
  "$twentytwo" tests/staleness_test.sh

# 23 and 23b. The interpreter floor, in both directions, and they share one
# fixture: a stub `ruby` that lies about its version.
#
# The stub is the smallest thing that reproduces the real failure. On macOS the
# gate's `ruby` can resolve to /usr/bin/ruby 2.6, which loads
# templates/otel/ruby/traceparent.rb without complaint — every constant and
# method definition parses fine — and then raises NoMethodError on
# `filter_map` at the first tracestate entry. So the *only* honest way to
# reproduce it is a stub that reports 2.6 and refuses the suite. It delegates
# everything else to the real interpreter, because the version probe has to keep
# working: a stub that could not be asked its version would fail the gate in
# the wrong place, and a self_test whose recipe fails for the wrong reason is a
# recipe that stopped testing what it names.
if command -v ruby >/dev/null 2>&1; then
  twentythree="$WORK/old-ruby"
  mkdir -p "$twentythree/stub"
  real_ruby="$(command -v ruby)"
  cat >"$twentythree/stub/ruby" <<STUB
#!/bin/sh
# Reports a ruby older than any cafaye service pins, then refuses to run
# anything. Everything else — `ruby -c`, the RUBY_VERSION probe — is delegated,
# so the only behaviour this fixture changes is "can the suite run here".
case "\$*" in
  *RUBY_VERSION*) printf '2.6.10'; exit 0 ;;
esac
case "\$*" in
  *test_traceparent.rb*) echo 'undefined method \`filter_map' >&2; exit 1 ;;
esac
exec "$real_ruby" "\$@"
STUB
  chmod +x "$twentythree/stub/ruby"

  # PATH is exported rather than prefixed onto the call: `PATH=… expect_red_check`
  # puts something other than `expect_red_check` first, so the count in
  # tests/validate.sh — anchored on `expect_` at the start of a line — would
  # miss this recipe and the summary would report fewer breakages than the file
  # carries. The same reasoning is why both counts allow indentation: the recipe
  # sits inside the `command -v ruby` guard.
  twentythree_old_path="$PATH"
  PATH="$twentythree/stub:$PATH"
  export PATH

  # 23. The floor is defined and never consulted. Removing the guard is the
  #     whole breakage: with the stub on PATH the suite goes red, and it goes
  #     red under the SAME label a genuine template defect uses — which is
  #     precisely why the guard had to exist. Asserted by name, because "the
  #     gate went red" would be satisfied by the unrelated checks in the same
  #     run and would prove nothing about this one.
  twentythree_a="$(fresh_copy old-ruby-no-floor)"
  edit "$twentythree_a/tests/validate.sh" \
    'if [ "$lang" = ruby ]; then' \
    'if false; then'
  expect_red_check 'breakage 23: the interpreter floor is defined but never consulted' \
    "$twentythree_a" 'templates/otel/ruby  (ruby test suite)' --language=ruby --no-self-test

  # 23b. The floor consulted and reported as a skip. Same fixture, guard intact.
  #      This is the assertion that a green gate can still be an honest one: the
  #      suite is NOT run, and the gate says so by name rather than passing on
  #      the strength of thirteen tests it never executed.
  twentythree_b="$(fresh_copy old-ruby-floor-honest)"
  expect_skip_check 'breakage 23b: an interpreter below the floor is a named skip, not a silent pass' \
    "$twentythree_b" "templates/otel/ruby  (ruby 2.6.10 is below the template's 2.7 floor)" \
    --language=ruby --no-self-test

  PATH="$twentythree_old_path"
  export PATH
else
  printf 'SKIP self_test: breakage 23: the interpreter floor is defined but never consulted — ruby not installed\n'
  printf 'SKIP self_test: breakage 23b: an interpreter below the floor is a named skip, not a silent pass — ruby not installed\n'
  skips=$((skips + 2))
fi

# 24-26. THE D12/D13 WORKAROUNDS, in the three shapes they actually took.
#
# `core` shipped two checker defects that forced adopters into local
# workarounds, and both are now fixed: D12 (`RUN_KEY` could not see a one-line
# `run:`) in 63fd319, and D13 (proofs matched against bytes carrying ANSI
# colour) in c63af27. A rule about those lives in `tests/validate.sh` now rather
# than in a report, and these three are that rule's proof.
#
# All three mutate the SYNTHETIC FLEET, not a throwaway copy of the tree: the
# check reads a directory of adopting repositories and kit is not one. Each
# takes its own `fresh_fleet` so one cannot mask the next, which is the same
# discipline `fresh_copy` provides for everything else here.
#
# 24 is the shape `cafaye-rb` shipped for six weeks — a step written `run: |`
# whose entire body is the gate command, plus a comment above it saying the
# one-liner would be invisible. It is the most important of the three because it
# is the only one that is BOTH detectable structurally and invisible in
# behaviour: core reads the step either way, so nothing else in the fleet
# notices.
FLEETWORKAROUND='adopting repositories  (no workaround for a fixed core defect)'

# fresh_fleet <name> — the synthetic fleet, rebuilt clean, with one repository
# added. Not `fresh_copy`, because the unit here is a two-file REPOSITORY inside
# a directory rather than a copy of this tree. A stale repository would make a
# later breakage pass for the wrong reason, so each one starts from clean.
#
# The `export` lives HERE rather than at the top of the file, and that is the
# other half of the fix described at the `unset` above. Exported once at the top
# it would be in force for every gate run in the file, including runs that
# happen after the last fleet recipe has left a broken repository behind; the
# scope this function creates is exactly the one recipe that needs it. A prefix
# assignment would not do — in bash an assignment preceding a FUNCTION call
# persists after it returns, which is the same trap one line up.
fresh_fleet() {
  rm -rf "$FLEET"
  synthetic_repo clean
  synthetic_repo second-clean
  synthetic_repo "$1"
  export KIT_FLEET="$FLEET"
}

# 24. D12, the block-scalar spelling plus its justification.
fresh_fleet d12-block-scalar
edit "$FLEET/d12-block-scalar/.github/workflows/ci.yml" \
  '        run: ./bin/prime
' \
  '        run: |
          ./bin/prime
'
edit "$FLEET/d12-block-scalar/.github/workflows/ci.yml" \
  '      - name: bin/prime
' \
  '      # A block scalar rather than `run: ./bin/prime` on one line. The `run:`
      # key above is invisible to `gate.ci-disagrees` without it.
      - name: bin/prime
'
expect_red_check 'breakage 24: D12 — the gate step is a block scalar, justified' \
  "$base" "$FLEETWORKAROUND" --static-only

# 25. D12 again, and the half that is a false SENTENCE rather than a shape. The
#     step is already correct here; only the comment is wrong. A check that
#     looked for the shape would pass this, and the comment would survive — which
#     is the part that rots, because the next reader cannot tell it is obsolete.
fresh_fleet d12-stale-comment
edit "$FLEET/d12-stale-comment/.github/workflows/ci.yml" \
  '      - name: bin/prime
' \
  '      # `run: ./bin/prime` is invisible to `gate.ci-disagrees`, so this step
      # must be a block scalar. See REPORT-core-10.md.
      - name: bin/prime
'
expect_red_check 'breakage 25: D12 — a correct step with a justification for a fixed defect' \
  "$base" "$FLEETWORKAROUND" --static-only

# 26. D13, and the one that makes a declaration WEAKER rather than merely
#     redundant. The escape runs absorb characters a stricter pattern would
#     reject, so this is not a harmless local convenience: it is a proof that
#     matches lines the author's own gate did not intend to accept. Core strips
#     the escapes in exactly one place (c63af27), so nothing else in the fleet
#     would ever see it.
fresh_fleet d13-escape-tolerant
edit "$FLEET/d13-escape-tolerant/gate.yml" \
  "      match: '^([0-9]+)/[0-9]+ passed$'" \
  "      match: '^(?:[ ]|\\x1b\\[[0-9;]*m)*([0-9]+)/[0-9]+ passed$'"
expect_red_check 'breakage 26: D13 — a proof pattern carries escape tolerance' \
  "$base" "$FLEETWORKAROUND" --static-only

# The fleet goes back to being the environment's business. `$FLEET` still holds
# `d13-escape-tolerant` — deliberately broken, and the whole reason breakage 26
# went red — so leaving `KIT_FLEET` pointed at it would make every gate run from
# here to the end of the file red on a defect this file introduced. See the
# `unset` where the export used to be for what this cost in the integration.
unset KIT_FLEET

# 27-32c. THE LINT GATE. Five ways the "lint runs from kit" mechanism can stop
#       being a gate while every other check in this repository stays green,
#       and the advisory one is the most likely of the five by a wide margin.
#
#       All five name the check that must catch them, because "the gate went red"
#       is a weak claim when a dozen checks could have gone red: a lint step
#       that lost its `--config` would also be caught by, at most, one other
#       thing, and a check that has stopped being load-bearing should fail HERE
#       rather than being discovered months later by the policy it stopped
#       policing.
LINTWIRE='lint/ + the workflow  (every lint step is a gate on kit config)'

# 27. THE LINT STEP DELETED. The crudest form: `ci.reusable.yml` still declares
#     a language, still has a job for it, still runs a build and a test — and
#     nothing in it lints. Everything else about the job is untouched, so this is
#     what "someone removed a step in a hurry" looks like.
#
#     The deletion is done with a parser rather than a text edit, for the same
#     reason breakage 9 was: an `edit` recipe whose anchor no longer matches
#     must FAIL LOUDLY, and one that silently matches the wrong occurrence is
#     worse than no recipe at all. Here the whole step is removed by identity.
twentyseven="$(fresh_copy lint-step-deleted)"
"$PY" - "$twentyseven/.github/workflows/ci.reusable.yml" <<'PY'
import sys

import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
# The go job's lint step, by name. Exactly one must go, or the recipe is stale.
hits = 0
for job in (doc.get("jobs") or {}).values():
    steps = (job or {}).get("steps") or []
    kept = [s for s in steps if not (isinstance(s, dict) and s.get("name") == "lint")]
    hits += len(steps) - len(kept)
    if isinstance(job, dict):
        job["steps"] = kept
if hits < 1:
    sys.exit("self_test: no `lint` step existed to delete — the recipe is stale")
with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(doc, fh, sort_keys=False, default_flow_style=False)
PY
expect_red_check 'breakage 27: a language job no longer lints at all' \
  "$twentyseven" "$LINTWIRE" --static-only

# 28. THE ADVISORY ONE, and the breakage that matters most. `continue-on-error:
#     true` leaves the step running, leaves it printing every finding it found,
#     and turns the job green. Nothing in the YAML is malformed; the build
#     passes; the lint results are on the page where nobody reads them. A linter
#     that only warns is a report, and this is how a report is born without
#     anybody deciding to write one.
#
#     It is asserted on the PARSED step, so it also catches the same defect
#     written the other two ways it can be written: `|| true` at the end of the
#     run body, which is continue-on-error in shell and reads to nobody as
#     anything but a deliberate choice. That one is exercised here too, because
#     the check claims to catch it and a claim nobody has tried to break is a
#     claim nobody has tested.
twentyeight="$(fresh_copy lint-made-advisory)"
edit "$twentyeight/.github/workflows/ci.reusable.yml" \
  '        uses: golangci/golangci-lint-action@v9
        with:' \
  '        uses: golangci/golangci-lint-action@v9
        continue-on-error: true
        with:'
expect_red_check 'breakage 28: the lint step is advisory (continue-on-error) — a report, not a gate' \
  "$twentyeight" "$LINTWIRE" --static-only

twentyeight_b="$(fresh_copy lint-advisory-in-shell)"
edit "$twentyeight_b/.github/workflows/ci.reusable.yml" \
  'run: bundle exec rubocop --parallel --config "$KIT_LINT_DIR/lint/rubocop.yml" ${{ env.KIT_LINT_ARGS }}' \
  'run: bundle exec rubocop --parallel --config "$KIT_LINT_DIR/lint/rubocop.yml" ${{ env.KIT_LINT_ARGS }} || true'
expect_red_check 'breakage 28b: the lint step swallows its exit status with `|| true`' \
  "$twentyeight_b" "$LINTWIRE" --static-only

# 29. THE CONFIG NO LONGER FOUND. The checkout deleted, or the path changed. The
#     step is untouched, it still says `--config`, it still names a file — and
#     the file is not there, so the linter falls back to its defaults: five
#     linters for golangci-lint, MethodLength 10 for rubocop, no rules for
#     eslint. All green, all much weaker. This is the breakage that the
#     `--config` flag's existence is defending against and it is invisible from
#     the YAML alone.
twentynine="$(fresh_copy kit-not-checked-out)"
"$PY" - "$twentynine/.github/workflows/ci.reusable.yml" <<'PY'
import sys

import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
removed = 0
for job in (doc.get("jobs") or {}).values():
    if not isinstance(job, dict):
        continue
    steps = job.get("steps") or []
    kept = [
        s
        for s in steps
        if not (
            isinstance(s, dict)
            and str(s.get("uses", "")).startswith("actions/checkout")
            and (s.get("with") or {}).get("repository") == "cafaye/kit"
        )
    ]
    removed += len(steps) - len(kept)
    job["steps"] = kept
if removed < 1:
    sys.exit("self_test: no kit checkout existed to delete — the recipe is stale")
with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(doc, fh, sort_keys=False, default_flow_style=False)
PY
expect_red_check 'breakage 29: the kit checkout is gone, so `--config` names nothing' \
  "$twentynine" "$LINTWIRE" --static-only

# 30. THE CONFIG WEAKENED. The sharpest of the five, because every check above
#     can be green while it happens. The workflow still points `--config` at
#     `.kit/lint/golangci.yml` on every run, the file still parses, the lint
#     step still exits nonzero on an error — and the policy is now golangci-
#     lint's five defaults, which nobody in the fleet chose.
#
#     A step that lost its flag is a defect a reader can see in a diff. A config
#     that lost three linters is a two-line deletion that looks like tidying,
#     and the build stays green throughout. So the linter list is asserted BY
#     VALUE, parsed as YAML, which also means the three names cannot be
#     satisfied by the comment block that explains why they are enabled.
thirty="$(fresh_copy config-weakened)"
"$PY" - "$thirty/lint/golangci.yml" <<'PY'
import sys

import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
enable = ((doc.get("linters") or {}).get("enable")) or []
before = len(enable)
# Drop the correctness linters one at a time. Each removal is a plausible
# "this is noisy" edit, which is exactly why none of them can be left to review.
doc["linters"]["enable"] = [x for x in enable if x not in ("bodyclose", "noctx", "errorlint")]
if len(doc["linters"]["enable"]) == before:
    sys.exit("self_test: none of the weakened linters was present — the recipe is stale")
with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(doc, fh, sort_keys=False, default_flow_style=False)
PY
expect_red_check 'breakage 30: kit config silently drops correctness linters the policy names' \
  "$thirty" "$LINTWIRE" --static-only

# 31. A SERVICE DRIFTS BACK TO A COPY. The failure this whole packet exists to
#     end, at the layer where it actually lands: a repo that used to lint with
#     kit's config goes back to running its own, and kit has no way to see it
#     from inside its own repository.
#
#     The shape checked here is the one kit CAN see without reading the fleet:
#     a service's own lint config, sitting in a place the reusable workflow's
#     steps never read. A file that nothing points at is not a deviation, it is
#     a copy that has stopped being one — and golangci-lint will still
#     DISCOVER it, because `.golangci.yml` in the repository root beats
#     everything. So a service carrying one is being linted by a policy that
#     kit's CI does not run, and the mismatch is invisible from both sides.
#
#     This is the check the brief asked for in the form it asked for: it reads
#     BOTH files and reports the DIFFERENCE, rather than demanding the file be
#     absent. A repo with no `.golangci.yml` passes; a repo whose file agrees
#     with kit's passes; a repo whose file disagrees is told exactly which
#     linters differ.
LINTDRIFT='lint drift  (a service config is compared to kit, not merely forbidden)'

thirtyone="$(fresh_copy service-drifted-back-to-a-copy)"
# A realistic drift: the service keeps kit's linters but drops the linter that
# was complaining about its generated client, and disables errcheck outright
# rather than excluding one path. Both are real, both are what a team does under
# pressure, and neither is visible in kit's own tree.
cat >"$thirtyone/.golangci.yml" <<'EOF'
---
# A service that went back to owning its lint config.
version: '2'
linters:
  enable:
    - bodyclose
    - copyloopvar
    - errorlint
    - exhaustive
    - misspell
    - noctx
    - revive
    - unconvert
    - wastedassign
  disable:
    - errcheck
EOF
expect_red_check 'breakage 31: a service carries a lint config INCONSISTENT with kit, not merely present' \
  "$thirtyone" "$LINTDRIFT" --static-only

# 31b. The other half of the same claim, and the reason the check reads both
#      files: a config that AGREES with kit's must PASS. A check that fails on
#      the mere presence of a `.golangci.yml` would be satisfied by this packet
#      and would train every service to delete a file it is allowed to keep —
#      which is a worse outcome than the drift, because it is a silent one.
thirtyone_b="$(fresh_copy service-config-agrees-with-kit)"
cp "$thirtyone_b/lint/golangci.yml" "$thirtyone_b/.golangci.yml"
expect_green 'breakage 31b: a service config that MATCHES kit is not a failure' \
  "$thirtyone_b" --static-only

# 32-32c. THE SEAM. Three claims, and each decays on its own: the guard can be
#       deleted, moved, or kept but emptied. The third matters most, because it
#       is the shortest edit in the file and it widens the deviation seam for
#       every service in the fleet while the workflow still reads as it did.
#
#       All three name `lint_args_seam_check`, for the reason 31-31 do: a deleted
#       guard also leaves the YAML valid, the lint step untouched and the build
#       green, and nothing else in this repository has an opinion about it.
SEAM='the seam  (narrow, guarded before the linter, and wired to it)'

# 32. The guard deleted from ONE job. The seam keeps working in the other two,
#     so this is the shape of an accident: one merge, one job, no other signal.
thirtytwo="$(fresh_copy seam-guard-deleted)"
"$PY" - "$thirtytwo/.github/workflows/ci.reusable.yml" <<'PYDEL28'
import sys

import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
job = (doc.get("jobs") or {}).get("ruby") or {}
steps = job.get("steps") or []
kept = [s for s in steps if s.get("name") != "lint-args guard"]
if len(steps) == len(kept):
    sys.exit("self_test: the ruby job had no `lint-args guard` to delete")
job["steps"] = kept
with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(doc, fh, sort_keys=False, default_flow_style=False)
PYDEL28
expect_red_check 'breakage 32: one lint job no longer guards the seam' \
  "$thirtytwo" "$SEAM" --static-only

# 32b. The guard KEPT, and its list shortened by one token. This is the edit a
#      well-meaning commit makes: `--no-config` is a flag somebody wants, and
#      rather than argue about the seam the token comes out. The build stays
#      green for every service that sets it, and the workflow still contains a
#      step called `lint-args guard`.
thirtytwo_b="$(fresh_copy seam-list-shortened)"
edit "$thirtytwo_b/.github/workflows/ci.reusable.yml" \
  '              --config|-c|--no-config|--no-config-lookup|--force-default-config|' \
  '              --config|-c|--no-config-lookup|--force-default-config|'
expect_red_check 'breakage 32b: the guard no longer refuses --no-config' \
  "$thirtytwo_b" "$SEAM" --static-only

# 32c. The guard moved AFTER the linter. It still runs, still reads the variable,
#      and still refuses everything it refused — after the linter has already
#      been handed `--no-config` and already exited 0. A control that runs after
#      the thing it controls is the most comfortable kind of dead code, because
#      reading the workflow top to bottom it looks exactly like a live one.
thirtytwo_c="$(fresh_copy seam-guard-after-the-linter)"
"$PY" - "$thirtytwo_c/.github/workflows/ci.reusable.yml" <<'PYDEL28C'
import sys

import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
for lang in ("go", "ruby", "node"):
    job = (doc.get("jobs") or {}).get(lang) or {}
    steps = job.get("steps") or []
    guard = next((s for s in steps if s.get("name") == "lint-args guard"), None)
    if guard is None:
        sys.exit("self_test: job " + lang + " had no `lint-args guard` to move")
    steps.remove(guard)
    steps.append(guard)
    job["steps"] = steps
with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(doc, fh, sort_keys=False, default_flow_style=False)
PYDEL28C
expect_red_check 'breakage 32c: the seam guard runs AFTER the linter it guards' \
  "$thirtytwo_c" "$SEAM" --static-only


# 33-25. The parity allowlist and the artefact table.
#
#     33 is the ESLint shape — an entry naming an artefact kit does not ship.
#     34 is the ratchet firing. 35 is half a language.
#
#     All three entries are well-formed in every OTHER respect. That is the
#     point: a shape-only check passes all three, and a hygiene rule in a data
#     file is exactly the shape of a check nobody has ever seen fail.
#
#     WHAT THE GATE CANNOT CHECK, AND THE RECIPE THAT CLAIMED IT COULD. An
#     entry naming a repository that does not exist IS a real failure, and the
#     REPORTER catches it — it is handed `--repos-dir` and can see what is
#     there — and `tests/staleness_test.sh` proves it in three shapes, one of
#     which is exactly that. The first version of this recipe asserted it
#     against the GATE, which stayed green and the breakage failed: kit's CI has
#     no sibling checkouts, so no gate in this repository can know which
#     repositories exist. A recipe that asserts a check which does not exist is
#     a proof of nothing, and the fix is to re-point it at a property the gate
#     really has rather than to add a fleet roster to kit so the gate could
#     answer a question it was never asked.
PARITY='templates/parity-allowlist  (reason, owner, since, until; dead entries fail)'
ARTTABLE='tests/artifacts.json  (every declared source exists, for every language)'

# 23. An entry for an artefact kit does not ship. The realistic version is a
#     rename: `lint/eslint.config.mjs` becomes `lint/eslint.config.ts`, the
#     entry keeps the old id, and it is now exempting nothing.
#
#     The id below is checked against `tests/artifacts.json` FIRST, and the
#     first version of this recipe used `lint/eslint.config.mjs` — a real id —
#     so the gate stayed GREEN and the breakage proved nothing. A mutation that
#     has silently stopped breaking the thing it names is the same defect as a
#     stale test, and the fix is to make the recipe assert its own premise
#     rather than to trust that the string looks like an id.
thirtythree="$(fresh_copy dead-parity-entry)"
if grep -q 'lint/eslint.config.ts' "$thirtythree/tests/artifacts.json"; then
  echo "FAIL self_test: breakage 33's dead artefact id is REAL — the recipe no longer mutates anything" >&2
  failures=$((failures + 1))
fi
cat >>"$thirtythree/templates/parity-allowlist" <<'ENTRY'
diverged billing lint/eslint.config.ts reason="this artefact was renamed in artifacts.json, so this entry exempts nothing" owner=kit since=2026-09-30 until=2026-12-31
ENTRY
expect_red_check 'breakage 33: a parity entry naming an artefact kit does not ship' \
  "$thirtythree" "$PARITY" --static-only

# 24. AN EXPIRED ENTRY — THE RATCHER FIRING.
#
#     The first recipe here asserted that a parity entry naming a repository
#     that does not exist takes the gate red. It does not, and it cannot: kit's
#     CI has no sibling checkouts, so the gate has no way to know which
#     repositories exist. The reporter knows (it is handed `--repos-dir`) and
#     `tests/staleness_test.sh` proves it in three shapes, including this one;
#     asserting it again against a check that does not exist would be a proof of
#     nothing. So the recipe is spent on a property the gate really has and
#     nothing has yet tried to break: **the gate reads the clock**.
#
#     The tier skip-allowlist has had that rule for a packet and nothing has
#     ever watched it fire — its own header says "a gate that has never gone
#     red is a report", and this is the first time anything in kit has actually
#     made the statement true. The date is in the past on purpose, and the
#     entry is well-formed in every other respect: a real artefact, a real
#     repository, a reason, an owner and a `since`. Only the `until` is wrong.
thirtyfour="$(fresh_copy expired-parity-entry)"
cat >>"$thirtyfour/templates/parity-allowlist" <<'ENTRY'
diverged billing mise.toml reason="this entry is well formed in every other respect; only the date is wrong, which is the point" owner=billing since=2020-01-01 until=2020-12-31
ENTRY
expect_red_check 'breakage 34: an expired parity entry — the gate reads the clock' \
  "$thirtyfour" "$PARITY" --static-only

# 25. A `{lang}` source kit does not ship for one language. `bun` is the one
#     that matters: it was added late and for a service that had been
#     hand-rolling a whole workflow for want of it, so it is the language most
#     likely to be half-adopted again.
#
#     The mutation DELETES the source rather than corrupting it, because that is
#     the defect: not a broken primer, a missing one, which is the one shape
#     every existing check would sail past.
thirtyfive="$(fresh_copy half-a-language)"
rm -f "$thirtyfive/templates/bin-prime/bun.sh"
expect_red_check 'breakage 35: kit offers `language: bun` but ships no primer for it' \
  "$thirtyfive" "$ARTTABLE" --static-only

# 26. AN ABSENCE REPORTED AS `current`.
#
#     This is the breakage the packet exists for. The templates half's commonest
#     state in the real fleet is `absent` — 0 of 9 services hold the collector,
#     1 of 9 holds `bin/dev` — and the one-line way to make all of that
#     disappear is to grade a path that is not there as fine.
#
#     The mutation is in the state table, not in the comparison, because the
#     comparison is not what is wrong: reading a missing file as "no
#     difference" is a one-word change in the classification and it turns the
#     most alarming column of the report into a green one.
thirtysix="$(fresh_copy absent-reads-current)"
edit "$thirtysix/tests/staleness.py" \
  '    if missing:
        cell["state"] = TPL_ABSENT' \
  '    if missing:
        cell["state"] = TPL_CURRENT'
expect_red_script 'breakage 36: the staleness reporter calls an ABSENT artefact current' \
  "$thirtysix" tests/staleness_test.sh

# 27. GRADE BY RESEMBLANCE.
#
#     The packet's third requirement: never infer a pin from content. The
#     realistic bug is a well-intentioned threshold — a future reader decides
#     99.9% identical is close enough, because the alternative (a flag on every
#     re-copy) is annoying.
#
#     `difflib.SequenceMatcher(...).quick_ratio()` is exactly that threshold,
#     already imported, and it is the shape a helpful patch would take. The
#     assertion it has to break is the one asserting a ONE-BYTE difference is
#     `diverged`, which is the property in its smallest form.
thirtyseven="$(fresh_copy grade-by-resemblance)"
edit "$thirtyseven/tests/staleness.py" \
  '        if pair_kit == repo_bytes:' \
  '        if pair_kit == repo_bytes or matcher_ratio(pair_kit, repo_bytes) > 0.99:'
cat >>"$thirtyseven/tests/staleness.py" <<'PY'


def matcher_ratio(a: bytes, b: bytes) -> float:
    """The resemblance threshold the packet forbids. Added by self_test 27."""
    import difflib

    return difflib.SequenceMatcher(None, a, b, autojunk=False).quick_ratio()
PY
expect_red_script 'breakage 37: the reporter grades a copy by resemblance, not equality' \
  "$thirtyseven" tests/staleness_test.sh

# 28. THE CARVE-OUT BOUNDARY.
#
#     `core/` ships two programs and AGENTS.md says they are "standard library
#     only, no import outside json/os/re/sys/argparse/subprocess". Nothing
#     checked that sentence for the whole life of the rule, which made it a
#     promise — and a promise nobody can break is decoration. kit is a
#     configuration repository; a `pip install` in one of these files is a
#     dependency, and the whole argument for the carve-out is that there are
#     none.
#
#     The mutation is a function-local import, because a function-local import is
#     what a contributor actually writes when they are being careful about
#     looking tidy, and it is the shape a grep-based check would miss. The check
#     walks the AST, so there is nowhere to put one that it cannot see.
#
#     AND THE NEEDLE IS THE LABEL, WHICH `81fffa6` STOPPED BEING. That commit added a
#     fourth carve-out program and, in the same hunk, renamed the check that owns all
#     four of them:
#
#       -  check 'tests/classify.py + tests/staleness.py  (stdlib only; the carve-out, enforced)'
#       +  check 'the carve-out programs  (stdlib plus PyYAML; enforced, and AGENTS.md agrees)'
#
#     `expect_red_check` matches `FAIL $want` AND passes `$want` to `--only`, and
#     `--only` is a substring match on the label. So a label that no longer exists does
#     not weaken this proof, it deletes it — and silently, in the worst direction
#     available, because `--only` matching nothing is ITSELF a fail:
#
#       FAIL: --only='tests/classify.py + tests/staleness.py' selected NO check out of the suite.
#
#     …which is a non-zero exit, so `the gate went red` was satisfied and only the
#     `FAIL $want` half noticed. Measured in a copy with this exact mutation applied,
#     both ways: the old needle selects nothing and can never match; the label below
#     selects exactly one check and prints
#     `FAIL the carve-out programs  (stdlib plus PyYAML; enforced, and AGENTS.md agrees)`.
#
#     AGENTS.md's rule — the needle is the label, and a label a self-test asserts is a
#     contract — has now been paid for here five times; 71, 75, 76 and 77 were the
#     first four. This is the one that matters most, because it is the only proof in
#     the repository that kit stays dependency-free, and from the outside a dead needle
#     and a satisfied assertion are the same line.
thirtyeight="$(fresh_copy a-third-party-import)"
"$PY" - "$thirtyeight/tests/staleness.py" <<'PY'
import sys

path = sys.argv[1]
body = open(path, encoding="utf-8").read()
# Appended at the end, at module scope, so the file still parses and still runs:
# a mutation that broke the program would prove only that Python exists.
with open(path, "a", encoding="utf-8") as fh:
    fh.write("\n\ndef _third_party():\n    import requests  # self_test breakage 38\n")
PY
expect_red_check 'breakage 38: one of the two programs gains a third-party import' \
  "$thirtyeight" 'the carve-out programs' --static-only

# 29. A HARNESS THAT LIES ABOUT ITS OWN FLEET.
#
#     Observed for real before it was written here. Under load average 160 the
#     suite failed one case and passed 35, the reporter having measured 8 repos
#     and 96 cells where the fixture holds 9 and 108 — and the failing case's
#     text named the reporter, which is precisely what it must not do when the
#     reporter was reading a smaller fleet rather than misreading a full one.
#
#     So the fixture is now checked before any case asserts on it: every service
#     the cases name must have a cell the reporter measured. This breakage
#     removes one service's `.git` — the shape a transient `git init` failure
#     leaves behind — and asserts the suite goes red AND says the failure is in
#     the fixture rather than in the reporter. A check that only proved the
#     script exits non-zero would pass on a suite that reported the same
#     misleading red, so the assertion is on the message.
thirtynine="$(fresh_copy a-fixture-service-the-reporter-cannot-see)"
edit "$thirtynine/tests/staleness_test.sh" \
  'mksvc absent-svc node' \
  'mksvc absent-svc node
rm -rf "$TPL/absent-svc/.git"'
expect_red_script 'breakage 39: the suite cannot tell a broken FIXTURE from a broken reporter' \
  "$thirtynine" tests/staleness_test.sh '' 'this is NOT a reporter result'

# 30. A TOOLCHAIN FLOOR THAT IS NOT WIRED TO ANYTHING.
#
#     The ruby floor check exists because a system ruby 2.6.10 on PATH made the
#     suite report three NoMethodErrors and the summary blame the template. A
#     check like that is exactly the kind that is written, admired, and never
#     fires — the floor function can be defined, the suite can still be invoked
#     unconditionally, and the gate is green on a machine that cannot run the
#     template at all.
#
#     So the breakage deletes the ONE line that consults the floor, leaving the
#     probe defined and never called, and asserts the ruby check still reports
#     the suite. Written as the well-intentioned edit a contributor makes when
#     the guard "looks redundant" next to a `have ruby` test three lines above:
#     the tool is present, so why ask whether it is the right one? The assertion
#     is on the check's own label, so a red from any other check does not pass
#     for this one.
#
#     Only meaningful where ruby is installed, and a missing interpreter is
#     reported as a SKIP rather than quietly passing — self_test's own rule is
#     that a skipped proof is a failed proof, so the count below stays honest.
#
#     The recipe call is kept at COLUMN 0 even though it is guarded, because the
#     count is taken with `grep -cE '^expect_red...'`: an indented call runs and
#     passes while the summary counts one fewer than it ran, and a count that
#     under-reports is the exact defect this repo treats as a lie told by a
#     measurement. The guard, not the indentation, is what makes the skip
#     explicit.
#
#     The breakage needs BOTH halves, and the second is the interesting one.
#     Deleting the guard on a machine with a current ruby proves nothing, because
#     the suite passes either way and green is the correct answer. So the copy
#     also gets a `ruby` shim that makes the interpreter old the way 2.6.10 was
#     old: `undef_method`, which raises NoMethodError at the call site exactly
#     as a missing method does. That is a simulation of the interpreter rather
#     than a dependency on one being installed — a self_test that needs a
#     particular ruby present is a self_test that SKIPs on CI and proves
#     nothing there, which is the rule this repo keeps restating.
#
#     With the shim and the guard in place the gate says the toolchain is too
#     old. With the shim and the guard DELETED it says the template is broken.
#     The recipe asserts the second, so the first cannot quietly stop happening:
#     a check that has stopped firing looks identical to a check that never did.
if command -v ruby >/dev/null 2>&1; then
  forty_ready=1
else
  forty_ready=0
fi
forty=""
if [ "$forty_ready" -eq 1 ]; then
  forty="$(fresh_copy a-toolchain-floor-nobody-calls)"
  # `command -v` is resolved BEFORE the shim goes on PATH, so the shim cannot
  # find itself and recurse.
  forty_real_ruby="$(command -v ruby)"
  mkdir -p "$forty/kit14-oldruby"
  cat >"$forty/kit14-oldruby/preload.rb" <<'RB'
# self_test breakage 40: make this interpreter look like one too old for the
# template. `undef_method` raises NoMethodError at the call site, which is
# precisely what a method that does not exist does.
class Array
  undef_method :filter_map if method_defined?(:filter_map)
end
RB
  {
    printf '#!/bin/sh\n'
    printf 'exec %q -r%q "$@"\n' "$forty_real_ruby" "$forty/kit14-oldruby/preload.rb"
  } >"$forty/kit14-oldruby/ruby"
  chmod +x "$forty/kit14-oldruby/ruby"
  # The mutation removes the branch that consults the floor, leaving
  # `toolchain_floor_ruby` defined and never called — which is what the recipe is
  # FOR (see REPORT-kit-14.md 10.6).
  #
  # THE ANCHOR BELOW IS THE BLOCK FORM, AND THAT IS A SECOND RE-POINTING. The
  # recipe first named `if [ "$lang" = ruby ] && ! toolchain_floor_ruby; then`,
  # a one-liner that stopped being the floor check when kit-17 replaced it with
  # the block form below — the SKIP-versus-FAIL distinction, and `ruby_floor`
  # read from the template's own `RUBY_FLOOR` constant rather than restated.
  # `edit` failed closed with "breakage no longer applies", which is exactly
  # right: the breakage had silently stopped testing anything, and a passing
  # suite that no longer runs its own recipe is the failure mode this whole file
  # exists to prevent. It happened a second time here, on the integration branch,
  # for the same reason and with the same fix.
  #
  # It replaces the BLOCK'S GUARD, not its body, so the mutation is the
  # well-intentioned edit it was always meant to be: the branch that asks
  # whether the interpreter can run the code is gone, and everything under it
  # goes with it.
  edit "$forty/tests/validate.sh" \
    '    if [ "$lang" = ruby ]; then
      ruby_seen="$(ruby -e '"'"'print RUBY_VERSION'"'"' 2>/dev/null || true)"' \
    '    if false; then
      ruby_seen="$(ruby -e '"'"'print RUBY_VERSION'"'"' 2>/dev/null || true)"'
  # PATH is exported rather than prefixed onto the call, because a prefixed call
  # reads `PATH=… expect_red_check` — the first token is no longer `expect_red`,
  # so the count would miss this recipe. Both counts now allow indentation, so
  # the call itself may sit inside the `if`.
  forty_old_path="$PATH"
  PATH="$forty/kit14-oldruby:$PATH"
  export PATH
  expect_red_check 'breakage 40: the toolchain floor is defined but never consulted' \
    "$forty" 'templates/otel/ruby  (ruby test suite)' --language=ruby --no-self-test
  PATH="$forty_old_path"
  export PATH
else
  printf 'SKIP self_test: breakage 40: the toolchain floor is defined but never consulted — ruby not installed\n'
  skips=$((skips + 1))
fi

# 41-51. The secret scanner, and the canary harness that answers the question
#        the scanner cannot.
#
#        A scanner that has never gone red is a report, and neither is a
#        detector that has never fired. Breakages 41-46 make the scanner catch
#        things; 47-50 make the canary's four reference-type vectors bite. They
#        are in one place because the two answer different questions about the
#        same subject, and a packet that added both is only honest if both are
#        proven able to fail.
SECRETS='gitleaks  (8.30.1, full history, --redact)'

# THE VARIABLES IN THIS BLOCK ARE NAMED FOR WHAT THEY BREAK, NOT FOR THEIR
# LABEL, and that is a merge repair rather than a style preference — made twice.
# kit-08 renumbered kit-04's 13-23 to 24-34, rewrote the labels, and left the
# variable names behind, so breakage 47 was still called `canary_unexported` and
# breakage 48 `canary_unredacted`. This integration then renumbered 24-34 to
# 41-51, and the descriptive names survived it, which is the outcome worth
# having: a name that says what it breaks cannot collide with a number that a
# later packet moves. It had worked only because each was written and read
# before the next write — four pairs of names meaning two different things in
# one file, where a reordering, an inserted breakage or an early exit would
# have pointed a recipe at a copy somebody else had already mutated. The
# names below cannot collide with master's 1-22 because they do not encode a
# number at all, so the next renumber cannot reintroduce the fault by editing a
# label and missing a variable.

# 41-25. A detectable credential, in history and in the tree.
#
#     THE PROBE IS ASSEMBLED, NOT WRITTEN, and that is the whole difficulty of
#     this packet. The obvious thing — paste a sample PAT into this file — makes
#     `tests/self_test.sh` itself a gitleaks finding, so the real tree's own scan
#     goes red and every breakage here is caught by the wrong thing. It was: the
#     first version of these two breakages did exactly that, and the gate
#     reported four leaks in the file that was supposed to be planting them.
#
#     Assembling it from parts means no credential-shaped string is ever
#     committed — which is the same rule the canary harness asserts about itself,
#     applied to the scanner's own proof. The cost is that a reader cannot see
#     the value, so the comment above says what it is.
#
#     The value is GitLab's own published PAT FORMAT SAMPLE (glpat- followed by
#     the documented 48-character sample body), taken from gitleaks' test data.
#     It is a format sample, not a credential, and it has never been a live
#     token. Nothing in this repository is a live secret, and this packet's
#     entire subject is not printing one.
plant_probe() {
  local dir="$1"
  mkdir -p "$dir/.self-test-probe"
  {
    printf 'endpoint = "https://gitlab.example.invalid"\n'
    # Split across the two halves gitleaks matches on: the `glpat-` prefix and
    # the token body. Neither half is a credential on its own, and the
    # concatenation is what the rule fires on.
    printf 'private_token = "glpat-%s"\n' 'ABC123def456GHI789jkl012'
  } >"$dir/.self-test-probe/config.toml"
}

# 24. Committed and then REMOVED — the shape the full-history requirement exists
#     for. A HEAD-only scanner sees a clean tree here, and a diff scanner sees
#     nothing at all, because by the time the commit lands the file is gone.
probe_history="$(fresh_copy committed-secret)"
plant_probe "$probe_history"
expect_red_check 'breakage 41: a credential in history, since removed' \
  "$probe_history" "$SECRETS" --static-only

# 25. The same credential, still in the tree. A separate breakage from 41
#     because it is a different code path in the scanner and a different claim:
#     41 proves the scan reads history, 42 proves it reads uncommitted files. A
#     scanner that only read history would pass 41 and fail 42, and one that only
#     read the working tree would do the reverse — so neither alone establishes
#     that both are covered.
probe_tree="$(fresh_copy working-tree-secret)"
plant_probe "$probe_tree"
expect_red_check 'breakage 42: a credential in the working tree' \
  "$probe_tree" "$SECRETS" --static-only

# 26. --redact removed from the scan script. The build stays GREEN — nothing
#     about a secret being printed makes it non-zero — and the CI log now
#     contains the credential the scanner just found. This is the reason
#     redaction is asserted in the gate and not left to review: a change that
#     reads as a cleanup is a change that exfiltrates.
scan_unredacted="$(fresh_copy scan-without-redact)"
edit "$scan_unredacted/tests/gitleaks_gate.sh" \
  '  --redact \
  --no-banner \' \
  '  --no-banner \'
expect_red_check 'breakage 43: the scan stops redacting' \
  "$scan_unredacted" 'tests/gitleaks_gate.sh  (finds a real secret, never prints it, reads history)' \
  --static-only

# 27. The scan narrowed to the diff. A shallow or HEAD-only scan cannot see
#     breakage 41's shape at all, and the check that asserts full history is
#     what makes narrowing it a failure rather than a quiet reduction in
#     coverage.
scan_shallow="$(fresh_copy scan-head-only)"
edit "$scan_shallow/tests/gitleaks_gate.sh" \
  "  set -- \"\$@\" --log-opts '-p -U0 --full-history --all'" \
  "  set -- \"\$@\" --log-opts '-1'"
expect_red_check 'breakage 44: the scan narrows to the last commit' \
  "$scan_shallow" 'tests/gitleaks_gate.sh  (finds a real secret, never prints it, reads history)' \
  --static-only

# 28. `pull_request_target` added as a trigger. The workflow still parses, still
#     passes every other check, and every job in it now runs with the base
#     repository's secrets and a writable token on a fork's code. The secret
#     scanner is the job that most invites this edit, which is why the trigger
#     is checked on parsed keys rather than left to review.
dangerous_trigger="$(fresh_copy dangerous-trigger)"
edit "$dangerous_trigger/.github/workflows/ci.reusable.yml" \
  '  workflow_call:' \
  '  pull_request_target:
  workflow_call:'
expect_red_check 'breakage 45: a dangerous trigger appears in the workflow' \
  "$dangerous_trigger" '.github/workflows/*  (no dangerous trigger, on parsed keys)' --static-only

# 29. The `secrets` job made advisory. The single most common way a security job
#     is neutralised, and completely invisible in a green build: continue-on-error
#     means the job reports what it found and the badge stays green. A secret
#     scanner that only warns is a report.
CANARYJOB='.github/workflows/ci.reusable.yml  (secrets job: not advisory, full history, not opt-in)'
advisory_secrets_job="$(fresh_copy secrets-job-advisory)"
edit "$advisory_secrets_job/.github/workflows/ci.reusable.yml" \
  '  secrets:
    name: secrets
    runs-on: ubuntu-latest' \
  '  secrets:
    name: secrets
    continue-on-error: true
    runs-on: ubuntu-latest'
expect_red_check 'breakage 46: the secret scanner is made non-blocking' \
  "$advisory_secrets_job" "$CANARYJOB" --static-only

# 47-33. The canary harness. A detector that has never fired is a detector
#         asserting nothing, and these break the SAFE reference type in the four
#         ways that would turn it into the LEAKY one — each caught by a named
#         vector, so a vector that stops biting fails here rather than being
#         discovered when a token reaches a log aggregator.
CANARY='templates/secrets/go  (five vectors, each with a red proof)'

# 30. The exported pointer field becomes an unexported one. This is the shape
#     that LOOKS safest — unexported, so a reviewer reading the type sees nothing
#     worrying — and it leaks under every verb, because fmt prints unexported
#     fields through reflection. The measurement behind that is in
#     print_shape_test.go; this breakage is what proves the measurement is wired
#     into a vector rather than sitting in a comment.
canary_unexported="$(fresh_copy canary-unexported-token)"
edit "$canary_unexported/templates/secrets/go/internal/safe/creds.go" \
  '	Token *Token `json:"-"`' \
  '	token *Token'
expect_red_check 'breakage 47: the reference type hides its credential in an unexported field' \
  "$canary_unexported" "$CANARY" --language=go --no-self-test

# 31. The redacting String method is renamed, so the type stops being a
#     Stringer. Every dispatched verb then prints the value, which is the leak
#     the whole reference shape exists to prevent — and the `json:"-"` tag is
#     untouched, so nothing else in the tree notices.
canary_unredacted="$(fresh_copy canary-no-redaction)"
edit "$canary_unredacted/templates/secrets/go/internal/safe/creds.go" \
  'func (t *Token) String() string { return "Token(redacted)" }' \
  'func (t *Token) Redeemed() string { return "Token(redacted)" }'
expect_red_check 'breakage 48: the credential type stops redacting when printed' \
  "$canary_unredacted" "$CANARY" --language=go --no-self-test

# 32. The `json:"-"` is dropped. The credential reaches the wire under a `token`
#     key, which is vector 2's finding, and an always-present key is vector 4's.
#     Nothing else changes: the type still redacts, still has no String method,
#     and every static check in the gate is still green.
canary_marshals="$(fresh_copy canary-serialises-token)"
edit "$canary_marshals/templates/secrets/go/internal/safe/creds.go" \
  '	Token *Token `json:"-"`' \
  '	Token *Token'
expect_red_check 'breakage 49: the reference type marshals its credential' \
  "$canary_marshals" "$CANARY" --language=go --no-self-test

# 33. The canary committed as a literal instead of assembled. The one breakage
#     whose failure mode is invisible in a CI log: the suite keeps passing,
#     because the value is the SAME value. What changes is that the repository
#     now holds a credential-shaped string — a gitleaks finding, and an
#     allowlist entry somebody will eventually add. The check that catches it is
#     `the canary (never committed as a literal, anywhere)`.
# The DIRECTORY is `canary_as_literal`, not `canary_literal`, and that is not
# taste. `canary_literal` is the name kit-04 used for the assembled VALUE below,
# and the renumber that gave 41-51 descriptive directory names gave this one
# the value's name. The directory variable was then reassigned to the value a few
# lines later, so `edit` was handed
# `cafaye_canary_…/templates/secrets/go/canary.go` and died with a
# FileNotFoundError — which killed breakage 50 AND 51, and the run, before the
# summary printed. Two proofs dead, reported as a crash rather than as a missing
# check. A directory variable and a value variable must never share a name here;
# `validate.sh` now checks that, because a name collision is invisible to review
# and fatal only when the recipe runs.
canary_as_literal="$(fresh_copy canary-committed-as-literal)"
# The replacement is the EXACT value the check looks for: prefix plus 49 bytes,
# and it is ASSEMBLED here for the same reason `plant_probe` assembles its PAT.
#
# This one is the sharper version of that trap. A committed canary literal makes
# this very file a finding for the check it is proving, so the real tree's own
# `the canary (never committed as a literal, anywhere)` goes red — and every
# breakage in this script becomes caught by the wrong thing. The first version of
# this breakage did exactly that: it wrote the literal out, the check fired on
# tests/self_test.sh, and the breakage reported the right failure for entirely
# the wrong reason.
#
# So the value is built in the throwaway copy, at the moment the defect is
# introduced, and never exists in a committed file. The defect being introduced is
# "a contiguous credential-shaped string in a source file" — which is exactly what
# gets written, into a copy that is deleted when the test finishes.
canary_prefix='cafaye_canary_'
canary_body="$(printf 'notarealsecret%.0s' 1 2 3)"
canary_literal="$canary_prefix${canary_body:0:49}"
edit "$canary_as_literal/templates/secrets/go/canary.go" \
  'canary   = CanaryPrefix + strings.Repeat(canaryBody, 3)[:CanaryBytes]' \
  "canary   = \"$canary_literal\""
expect_red_check 'breakage 50: the canary is committed as a literal' \
  "$canary_as_literal" 'the canary  (never committed as a literal, anywhere)' --static-only

# 34. The zizmor config baselines unpinned-uses — the trade made invisibly, in a
#     file that looks like routine housekeeping. Every finding is still
#     accounted for and the build is still green, which is exactly what makes it
#     the failure mode worth a proof.
zizmor_baseline="$(fresh_copy zizmor-baselines-unpinned)"
edit "$zizmor_baseline/.github/zizmor.yml" \
  '  self-repository:' \
  '  unpinned-uses:
    ignore:
      - "**"
  self-repository:'
expect_red_check 'breakage 51: the zizmor config baselines unpinned-uses' \
  "$zizmor_baseline" '.github/zizmor.yml  (unpinned-uses recorded, never baselined)' --static-only

# 61-62. THE LICENCE, in the two ways the grant stops being unambiguous.
#
# A licence is only unambiguous when there is exactly ONE place in a repository
# that can declare one. Both breakages are the same property failing from
# opposite sides, and one of them is not a file being edited at all:
#
#   61. `LICENSE` DELETED. The direction everybody can see, and the one this
#       check exists for: cafaye's decision is MIT across the fleet, and a
#       repository with no grant is not permissive — it is all rights reserved,
#       which is the default copyright position when nothing is granted. The
#       README kept saying MIT the whole time, which is exactly why it needed a
#       check: the documentation was true and the repository was not.
#   62. a root `package.json` declaring `AGPL-3.0-only`. The direction nobody
#       looks at, and the reason the check inspects manifests rather than merely
#       the file's existence. The grant is still MIT in `LICENSE` and still MIT
#       in the README; the repository has acquired a THIRD statement, a
#       compliance tool reads it, and a reader has no way to tell which one is
#       authoritative.
#
# 62 is the one that decides whether this is a real check. A check that only
# asserts `LICENSE` exists is satisfied by a repository that has drifted into
# saying two different things, which is the more likely failure — a manifest is
# easy to add and nobody thinks of it as a licence decision.
license_missing="$(fresh_copy licence-missing)"
rm -f "$license_missing/LICENSE"
expect_red_check 'breakage 61: LICENSE deleted — a repository with no grant is not permissive' \
  "$license_missing" 'LICENSE  (MIT, and nothing in the tree can disagree with it)' --static-only

# ASSEMBLED, not committed, and the reason is the same one as breakages 24, 25
# and 33: this file is scanned. A literal `package.json` with a licence field is
# harmless to the scanner, but the habit is the rule — a probe written out is a
# probe committed, and the breakage would then be "caught by the wrong thing".
# Written with printf rather than a heredoc so the fixture carries no manifest of
# its own for a later recipe to trip over.
license_conflict="$(fresh_copy licence-conflict)"
printf '%s\n' '{' '  "name": "kit",' '  "private": true,' '  "license": "AGPL-3.0-only"' '}' \
  > "$license_conflict/package.json"
expect_red_check 'breakage 62: a root manifest declares a licence the LICENSE file contradicts' \
  "$license_conflict" 'LICENSE  (MIT, and nothing in the tree can disagree with it)' --static-only


# 52-60. THE FLEET GATE, one breakage per failure mode. Four, because the claim
#        is four separate claims and a check that only proves one of them is a
#        check that has proved nothing about the other three.
#
#        Every one asserts the NAMED check, not merely "the gate went red". The
#        fleet gate is red on master for the whole fleet, so "the gate went red"
#        is the WEAKEST possible assertion here: it would be satisfied by a
#        fixture fleet of two perfectly clean repositories. `expect_red_check`
#        against a green fixture is the only form of this proof that says
#        anything.
FLEETCHECK='fleet  (no stale copy, no weakened boundary, no dead config, every ref pinned)'

# 23. A STALE FULL COPY OF THE STACK. The realistic shape, and the one the packet
#     was written about: a service running its own `postgres` rather than joining
#     kit's. Five of the twelve repositories do exactly this today.
#
#     The mutation is a real service file, not a toy — the same `db:` service with
#     the same `image: postgres:17` that billing, courier, darkroom and identity
#     carry. A fixture that used a name kit does not ship would test a rule nobody
#     broke, which is precisely the bug in the check's first version: five of the
#     six repositories in scope call their database `db`, so a check that matched
#     on the NAME found nothing in any of them.
fiftytwo_fixture="$(fixture_fleet stale-copy)"
break_stale_copy "$fiftytwo_fixture"
export KIT_FLEET="$fiftytwo_fixture"
expect_red_check 'breakage 52: a service carries its own copy of the shared stack' \
  "$base" "$FLEETCHECK" --static-only

# 24. A WEAKENED REDACTION BOUNDARY. The service re-points the collector's config
#     mount at its own `otel-collector.yml` — which is the whole attack: the
#     allowlist is derived from core's schemas by kit's gate, and a service that
#     owns the file owns a boundary nobody derived.
fiftythree_fixture="$(fixture_fleet weakened-boundary)"
cat >"$fiftythree_fixture/alpha/otel-collector.yml" <<'YAML'
# A copy of kit's collector config, with the redaction allowlist thrown away. The
# whole point of the file is that it is DERIVED; a local copy is a boundary
# nobody keeps in step with core.
receivers:
  otlp:
    protocols:
      http:
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [debug]
YAML
"$PY" - "$fiftythree_fixture/alpha/docker-compose.yml" <<'PYEOF'
import sys

path = sys.argv[1]
body = open(path, encoding="utf-8").read()
body = body.replace(
    "services:\n  alpha:",
    "services:\n  otel-collector:\n"
    "    volumes:\n"
    "      - ./otel-collector.yml:/etc/otel/otel-collector.yml:ro\n"
    "  alpha:",
    1,
)
open(path, "w", encoding="utf-8").write(body)
PYEOF
export KIT_FLEET="$fiftythree_fixture"
expect_red_check 'breakage 53: a service re-points the collector config mount' \
  "$base" "$FLEETCHECK" --static-only

# 25. A COLLECTOR CONFIG NOTHING STARTS. The file is present, plausible, and
#     inert: nothing mounts it, so the collector that actually runs is reading the
#     pinned ref's copy. A developer edits this file and nothing changes at all,
#     which is strictly worse than the file being absent.
fiftyfour_fixture="$(fixture_fleet dead-collector-config)"
cp "$ROOT/templates/compose/otel-collector.yml" \
  "$fiftyfour_fixture/alpha/otel-collector.yml"
export KIT_FLEET="$fiftyfour_fixture"
expect_red_check 'breakage 54: an otel-collector.yml that no compose file ever mounts' \
  "$base" "$FLEETCHECK" --static-only

# 26. AN UNPINNED REF. `master`, in the committed `kit.ref` — the shape that is
#     one `sed` away from correct and that a gate is the only thing stopping.
#
#     The brief calls this out separately from 52-54 and it earns its own entry:
#     the other three are about a service carrying something it should not, and
#     this one is about the fleet as a whole running a stack that changes between
#     Tuesday and Monday. A gate that proved the first three and this one would
#     still be missing the one that makes "one command, always current" mean
#     something.
fiftyfive_fixture="$(fixture_fleet unpinned-ref)"
printf '# deliberately unpinned\nmaster\n' >"$fiftyfive_fixture/alpha/kit.ref"
export KIT_FLEET="$fiftyfive_fixture"
expect_red_check 'breakage 55: a service pins a BRANCH rather than a ref' \
  "$base" "$FLEETCHECK" --static-only

# 56-29. THE KIT-SIDE AND OVERRIDE RULES. The four above are about the fleet;
#         these are about kit's own tree, and about what a second `-f` file is
#         allowed to do to it. They are the halves that make the fleet half mean
#         anything: a gate that only checks its callers is checking that they call
#         it correctly, not that it works.
#
# 27. A VENDOR CONFIG MOUNT THAT STOPPED RESOLVING FROM THE FETCHED TREE. One
#     `${KIT_COMPOSE_DIR:-.}` prefix dropped from one mount. The stack still
#     parses, `docker compose config` still renders the same project, and the
#     variable's value is not a property of the YAML — so nothing above it in the
#     gate can see it. What it does is resolve the mount to a path that does not
#     exist, and Docker's answer to that is to CREATE A DIRECTORY, so the failure
#     arrives four containers later as
#     `read /etc/tempo/tempo.yaml: is a directory`. Found by running the stack.
MOUNTCHECK='templates/compose/ + bin/dev  (every vendor config mounts from the fetched tree)'

fiftysix="$(fresh_copy mount-not-anchored)"
edit "$fiftysix/templates/compose/docker-compose.yml" \
  '      - ${KIT_COMPOSE_DIR:-.}/tempo/tempo.yaml:/etc/tempo/tempo.yaml:ro' \
  '      - ./tempo/tempo.yaml:/etc/tempo/tempo.yaml:ro'
expect_red_check 'breakage 56: a vendor config mount stopped resolving from the fetched tree' \
  "$fiftysix" "$MOUNTCHECK" --static-only

# 28. THE PIN MOVED BACK INTO `.env`, where it is git-ignored. The shape is
#     subtler than "the pin is wrong": the template ships
#     `KIT_STACK_REF=<sha>` in `.env.example`, so a fresh clone looks configured
#     and needs no setup. It also means the pin lives in a file that becomes
#     `.env`, and `.env` is git-ignored — so the pin exists on the laptop of
#     whoever ran the command last and on no CI runner and no teammate's
#     checkout. "One command, always current" quietly becomes "one command,
#     whatever this checkout last fetched".
#
#     `bin/dev` reads KIT_STACK_REF from the ENVIRONMENT only, as a one-run
#     override, so the shipped line decides nothing at run time. A gate that asked
#     "is the pin pinned?" would still be green; it has to ask WHERE the pin
#     lives, which is a different question and a different check.
#
#     `rm -f kit.ref` is here for the shape a SERVICE sees, not for kit: kit's own
#     root has no `kit.ref` — the pin belongs to the adopting service. Removing it
#     is a no-op on this tree, and the red comes entirely from the `.env.example`
#     line. Kept because the recipe should read as the defect it is proving
#     rather than as the minimum needed to trip a check.
PINCHECK='templates/bin/dev.sh + .env.example  (the pin is kit.ref, and the gate reads the same file)'

fiftyseven="$(fresh_copy pin-back-in-env)"
rm -f "$fiftyseven/kit.ref"
cat >>"$fiftyseven/templates/compose/.env.example" <<'ENTRY'
KIT_STACK_REF=0000000000000000000000000000000000000000
ENTRY
expect_red_check 'breakage 57: the pin is back in .env, where nothing reads it' \
  "$fiftyseven" "$PINCHECK" --static-only

# 29. A PORT PUBLISHED ON A SERVICE KIT ALREADY SHIPS. The quietest of the three,
#     because nothing errors. `ports:` is a LIST, a second `-f` file's list is
#     APPENDED rather than substituted, and a service that writes
#
#         services:
#           postgres:
#             ports: ["15433:5432"]
#
#     gets postgres listening on kit's 15500 AND on 15433. `docker compose config`
#     renders both and warns about neither, so the file reads like the override it
#     was written to be while doing something else — and the port it meant to move
#     is still bound. The documented way to move a published port is the VARIABLE
#     in `.env`, which replaces.
#
#     No `image:` on the mutation, deliberately: the rule keys on the service NAME
#     kit ships, not on an image, so this fires the ports rule alone and the
#     stale-copy rule stays quiet. A breakage that reddened both would not say
#     which one is load-bearing.
fiftyeight_fixture="$(fixture_fleet published-port)"
cat >>"$fiftyeight_fixture/alpha/docker-compose.yml" <<'YAML'
  postgres:
    ports:
      - "15433:5432"
YAML
export KIT_FLEET="$fiftyeight_fixture"
expect_red_check 'breakage 58: a service publishes a port on a service kit already ships' \
  "$base" "$FLEETCHECK" --static-only

# 59-31. THE ADOPTION CEILING, both sides of it, and the pair is the proof.
#
# The fleet gate was red on master for six repositories that have adopted
# nothing, which is the same shape as a build that has been red for a quarter:
# the red is true, and it has stopped being information. The ceiling is the
# response core-16 applied to a missing OpenAPI document — absence is a named
# warning with the adoption path attached, and it becomes a failure the moment
# the repository adopts.
#
# A ceiling needs BOTH halves proved, and that is why these are two recipes over
# ONE mutation rather than one recipe over two mutations:
#
#   59  the stale copy, with no kit.ref anywhere in the fleet. The gate stays
#       GREEN, and the finding is PRINTED, with the adoption path. If this one
#       goes red the ceiling does not exist — the gate is failing unadopted
#       repositories, which is the state the packet was dispatched to fix.
#   60  the identical stale copy, with kit.ref committed. The gate goes RED on
#       the identical finding. If this one stays green then the ceiling is not
#       a ceiling but a deletion: the checks no longer decide anything at all.
#
# 60 is breakage 52 plus one committed line, and that is the entire argument in
# one diff. Nothing about the predicate, the message or the severity changed
# between them; what changed is whether the repository has accepted the standard
# it is being measured against.
#
# The needle in 59 is a literal substring of the finding rather than the word
# `WARN`. A check that printed "WARN" and nothing else would satisfy the weaker
# assertion, and a check that deleted the finding entirely and left the string
# in a comment would satisfy it too — which is the shape this repository has
# already been bitten by once, with a policy stated in both the Python and a
# rule.
CEILINGCHECK='fleet  (adopting repositories clean;'
fiftynine_fixture="$(fixture_fleet ceiling-unadopted)"
break_stale_copy "$fiftynine_fixture"
unadopt "$fiftynine_fixture"
export KIT_FLEET="$fiftynine_fixture"
expect_green_check 'breakage 59: an UNADOPTED service copies the stack — green, and named' \
  "$base" "$CEILINGCHECK" "which is the image kit's stack already ships" --static-only

sixty_fixture="$(fixture_fleet ceiling-adopted)"
break_stale_copy "$sixty_fixture"
export KIT_FLEET="$sixty_fixture"
expect_red_check 'breakage 60: the same copy in an ADOPTING service is a hard FAIL' \
  "$base" "$FLEETCHECK" --static-only

# 83. A SERVICE OVERRIDING THE SHARED CLUSTER'S OWN POSTGRES IDENTITY. The
#     breakage for the check added because kit's own remediation advice was
#     wrong; see the header entry and `_SHARED_CLUSTER_ENV` for the
#     measurements.
#
#     The mutation is the shape `identity` carries today, copied out of its
#     docker-compose.yml rather than invented: a `postgres:` service with no
#     `image:` — kit ships the container — and the three keys overridden on it.
#
#     The absence of `image:` is load-bearing rather than incidental, and it is
#     the guard that keeps this a proof of the RIGHT check. With an `image:`
#     there, the entry is a stale copy and `check_stale_copy` reports it — one
#     defect, two findings, and this breakage would go red for a reason that has
#     nothing to do with what it is proving. `check_override_surface` therefore
#     fires only when there is no `image:` and no `build:`, which is what makes
#     "an override of kit's cluster" and "a replacement of it" different checks.
#
#     Written to a fixture fleet rather than the real one, for the reason 52 is:
#     the real fleet is red by design, and `expect_red_check` answers "did THAT
#     NAMED check go red", so a dirty fleet makes the proof meaningless in the
#     only direction that matters.
eightythree_fixture="$(fixture_fleet cluster-env-override)"
cat >>"$eightythree_fixture/alpha/docker-compose.yml" <<'YAML'
  postgres:
    environment:
      POSTGRES_USER: alpha
      POSTGRES_DB: alpha
      POSTGRES_PASSWORD: alpha
YAML
export KIT_FLEET="$eightythree_fixture"
expect_red_check 'breakage 83: a service overrides the shared cluster POSTGRES_USER' \
  "$base" "$FLEETCHECK" --static-only

# ---------------------------------------------------------------------------
# 89. A `workflow_call` INPUT DECLARING A KEY `workflow_call` DOES NOT HAVE.
#
# THE DEFECT THAT WAS ACTUALLY SHIPPED, and the only one in kit's history that
# took the whole fleet's CI down without a single red check.
#
# `ci.reusable.yml` carried an `options:` list under its `language` input from
# 2026-09-30 until kit-33. `options:` is a `workflow_dispatch` feature;
# `workflow_call` accepts `description`, `required`, `type` and `default` and
# nothing else. GitHub rejects an unknown key AT PARSE TIME and refuses the
# WHOLE FILE -- not the job, not the input, the file. Every service in the fleet
# calls this workflow, so from that date until the fix, every CI run in every
# repository started zero jobs and reported zero check runs while all 200+
# static checks stayed green. Nothing was red because nothing ran.
#
# This recipe re-adds the exact key to the exact input. If it is not caught, the
# check this packet added cannot see the class of failure that actually
# happened, and the fleet can be down for days again without a single signal.
# ---------------------------------------------------------------------------
CALLABLE_INPUTS='reusable workflows  (workflow_call inputs use only documented keys)'
base89="$(fresh_copy kit-89)"
"$PY" - "$base89/.github/workflows/ci.reusable.yml" <<'PY1'
import sys
path = sys.argv[1]
s = open(path).read()
anchor = "        required: true\n        type: string\n"
i = s.index(anchor) + len(anchor)
open(path, "w").write(s[:i] + "        options:\n          - go\n          - ruby\n" + s[i:])
PY1
expect_red_check 'breakage 89: a workflow_call input declares `options`, which GitHub rejects for the whole file' \
  "$base89" "$CALLABLE_INPUTS" --static-only

# Cleared, because `export` is not scoped to a command the way `VAR=v cmd` is, and
# the final recipe above would otherwise leave the fixture in the environment for
# whatever runs next. The alternative — a `VAR=v` prefix per call — puts
# `expect_red_check` at column 59, where the breakage counter and validate.sh's
# header/recipe check (both `grep -cE '^expect_red...'`) stop being able to see it,
# and a breakage the counter cannot see is a breakage the header is not proved
# against.
unset KIT_FLEET

# ---------------------------------------------------------------------------
# 78-82. THE KAMAL CONFIG, and the green control 78b.
#
# RENUMBERED. This block was 78-82 and its 78b/78/79 collided with the 78/79 of
# the licence block above, which the kit-22 union merge put in the same file
# without either side noticing. Two recipes sharing a label is not cosmetic: the
# suite's own summary counts breakage NUMBERS, so a collision made it report 82
# while 84 recipes existed, and made "breakage 78" ambiguous to anyone reading
# a failure. Found by sharding the suite and checking that the shards covered
# every number exactly once -- 78 and 79 came up claimed twice.
#
# The numbers moved to 78-82 so this block ends the file, next to nothing. If
# more breakages are added, continue from 83.
#
# Every recipe below mutates `templates/kamal/` and asserts a NAMED check goes
# red, because "the gate went red" is a weak claim when forty other checks could
# have gone red instead.
#
# The green control is not optional here in the way it is elsewhere. Breakages
# 78, 79 and 82 all work by making `tests/kamal_test.sh` fail; if the UNMODIFIED
# tree's generated config did not satisfy the real binaries, every one of those
# three would pass for the wrong reason — the check would be reporting "this
# template is broken" when what it reports is "every template is broken". So 78b
# runs the same script on the same binaries and asserts it is green, and it runs
# FIRST, so a red in 78-82 reads as what it is rather than as an environment
# problem.
# ---------------------------------------------------------------------------
KAMALCHECK='kamal_test'

if command -v kamal >/dev/null 2>&1 && command -v kamal-backup >/dev/null 2>&1; then
  sixtyoneb="$(fresh_copy kamal-green-control)"
  expect_green_script 'breakage 78b: the UNMODIFIED generated config satisfies kamal and kamal-backup' \
    "$sixtyoneb" tests/kamal_test.sh

  # 78. `builder.arch` deleted. Valid YAML; kamal refuses the file outright
  # ("Builder arch not set"), so this is the case where a parse check is not
  # merely weaker than the real one but points at a file the real one rejects.
  sixtyone="$(fresh_copy kamal-no-builder-arch)"
  edit "$sixtyone/templates/kamal/deploy.yml.erb" \
    'builder:
  arch: arm64' 'builder:'
  expect_red_check 'breakage 78: the generated deploy.yml is invalid for kamal' \
    "$sixtyone" "$KAMALCHECK" --static-only

  # 79. The doubled registry host. BOTH files are valid YAML and `kamal config`
  # exits 0 — the config resolves to `ghcr.io/ghcr.io/org/repo`, and the failure
  # is a push that cannot authenticate against a host that does not exist. This
  # is the breakage that justifies running the binaries at all: it is invisible
  # to every check that parses.
  sixtytwo="$(fresh_copy kamal-double-registry)"
  edit "$sixtytwo/templates/kamal/deploy.yml.erb" \
    'image: <%= org %>/<%= repo %>' 'image: <%= registry %>/<%= org %>/<%= repo %>'
  expect_red_check 'breakage 79: the image name carries the registry host twice' \
    "$sixtytwo" "$KAMALCHECK" --static-only

  # 80. One artifact of the set deleted. `deploy.yml` and `kamal-backup.yml` are
  # ONE contract — every `{ secret: NAME }` in the second must appear in the
  # backup accessory's `env.secret` in the first — so half a set is a config that
  # is internally valid and jointly wrong.
  sixtythree="$(fresh_copy kamal-half-a-set)"
  rm -f "$sixtythree/templates/kamal/kamal-backup.yml.erb"
  expect_red_check 'breakage 80: one half of the kamal config set is deleted' \
    "$sixtythree" 'templates/kamal/  (4 artifacts present, the set is whole)' --static-only

  # 81. The superseded custom backup toolchain RESTORED. The only breakage here
  # about something being PRESENT rather than absent, and it exists because "we
  # removed it" has no mechanical form until something asserts the absence —
  # which is the whole argument for a check on a path nobody should ever
  # reference again. The recipe writes a single file, not the 1,850 lines: the
  # check is `[ -e ... ]`, so one path is enough to make it red, and a recipe
  # that recreated the tree would only be testing its own ability to copy files.
  sixtyfour="$(fresh_copy kamal-backup-returns)"
  mkdir -p "$sixtyfour/templates/backup"
  printf '# resurrected by self_test breakage 81\n' >"$sixtyfour/templates/backup/job.sh"
  expect_red_check 'breakage 81: the superseded custom backup toolchain is BACK' \
    "$sixtyfour" 'the superseded custom backup toolchain' --static-only

  # 82. The drill's refusal narrowed. The mutation is the one a well-meaning
  # commit makes: `*prod*` becomes `*production*`, so every name containing the
  # word still matches and the abbreviated spellings stop being caught. Nothing
  # about the code reads as a weakening — it reads as tidying a glob.
  #
  # And the drill is the safety property the whole backup path rests on: it
  # restores into a scratch database and DROPS it, so a scratch name that looks
  # like production is a production database that gets dropped.
  sixtyfive="$(fresh_copy kamal-drill-refusal-narrowed)"
  edit "$sixtyfive/templates/kamal/drill.sh" \
    '*prod* | *PROD* | *live* | *LIVE*)' '*production* | *PROD* | *live* | *LIVE*)'
  expect_red_check 'breakage 82: the drill stops refusing a production-looking scratch name' \
    "$sixtyfive" "$KAMALCHECK" --static-only

  # 84-86. The two defects that meant the shared cluster provisioned nothing,
  # both proven able to come back. They are here as three recipes rather than
  # one because they are three SEPARATE rules, and one recipe proving one of
  # them red says nothing about the other two - which is the exact shape of the
  # original miss, where a check over a hand-written list of five vendor configs
  # never mentioned the postgres service.
  #
  # NUMBERED 84-86, NOT 83-85, and 83 belongs to someone else. kit-29 added
  # `breakage 83: a service overrides the shared cluster POSTGRES_USER` for the
  # superuser-override check, independently and in a different worktree, so two
  # packets claimed 83. Numbering is not cosmetic here: `self_test_claims`
  # cross-checks the header against the recipes, so a duplicate does not merely
  # read badly - it makes the integrity check unable to say which recipe a
  # header line is claiming. 83 was already reviewed and committed as e88c345,
  # so these three moved up. If you are adding a recipe, take the next free
  # number above BOTH this block and whatever e88c345 carries.
  #
  # THE WHOLE CHECK LABEL, PREFIX INCLUDED, and that is not fussiness.
  # `expect_red_check` asserts on the literal string `FAIL $want`, and the gate
  # prints the check's registered name - which is `check '<label>' <fn>` and
  # begins with the PATH, not with the prose. So `want` has to be the whole
  # registered name or the comparison is looking for `FAIL every vendor config
  # ...` inside a line that reads `FAIL templates/compose/ + bin/dev  (every
  # vendor config ...`. I wrote both of these as the prose alone and both
  # reported "the gate went red, but NOT via <the named check>" while the log
  # right underneath showed the named check red. The mutation had worked; the
  # harness was reading the wrong string. The trailing paren closes the label.
  STACKMOUNT='templates/compose/ + bin/dev  (every vendor config mounts from the fetched tree)'
  ENVTENANT='templates/compose/.env.example  (every placeholder documented, no tenant named)'
  HARNESSTENANT='kit harnesses  (every .env-writing harness declares its own tenant)'

  # 84. The initdb mount goes back to being relative. Docker CREATES a missing
  # bind source as an empty directory, so this mutation cannot fail visibly at
  # runtime - the cluster comes up healthy with no roles and no databases. The
  # whole reason it needs a static proof is that its failure has no symptom.
  eightythree="$(fresh_copy postgres-initdb-mount-relative)"
  edit "$eightythree/templates/compose/docker-compose.yml" \
    $'\n      - ${KIT_COMPOSE_DIR:-.}/postgres/initdb:/docker-entrypoint-initdb.d:ro' \
    $'\n      - ./postgres/initdb:/docker-entrypoint-initdb.d:ro'
  expect_red_check 'breakage 84: the initdb mount is relative again, so the cluster provisions nothing' \
    "$eightythree" "$STACKMOUNT" --static-only

  # 85. `.env.example` names a tenant again. This is the one that reads as a
  # helpful default: a literal service name in a shared-cluster template looks
  # like an example, and `bin/dev` copies it verbatim into every adopter's
  # git-ignored `.env`, where Compose prefers it over the adopting service's own
  # committed compose file. The service's declaration stops applying and nothing
  # is in any diff.
  eightythree="$(fresh_copy env-example-names-a-tenant)"
  #     ANCHORED AT LINE START, with a leading newline, and that is the whole
  #     difference between this proving the rule and proving nothing. `edit` is a
  #     `body.replace(old, new, 1)`, so it takes the FIRST match anywhere in the
  #     file - and `.env.example` line 164 is a COMMENT that quotes the very
  #     string this recipe is looking for: "This file used to say
  #     `KIT_POSTGRES_DATABASES=courier`". So the unanchored recipe rewrote the
  #     sentence describing the defect, left the assignment empty, and the gate
  #     correctly stayed GREEN. The recipe reported that as the mutation
  #     escaping, which is the worst possible shape: a green gate blamed for a
  #     proof that never touched the thing it names. Verified unique - one
  #     occurrence each - so this is an anchor and not a coincidence.
  edit "$eightythree/templates/compose/.env.example" \
    $'\nKIT_POSTGRES_DATABASES=' $'\nKIT_POSTGRES_DATABASES=courier'
  expect_red_check 'breakage 85: .env.example names a service as the fleet default tenant' \
    "$eightythree" "$ENVTENANT" --static-only

  # 86. And the compose file's own fallback names one. Kept separate from 84
  # because they are caught by different halves of the same rule, and because
  # fixing only the .env leaves a template that still hands a real service's
  # database to any adopter that does not override it.
  eightythree="$(fresh_copy compose-default-names-a-tenant)"
  edit "$eightythree/templates/compose/docker-compose.yml" \
    'KIT_POSTGRES_DATABASES: ${KIT_POSTGRES_DATABASES}' \
    'KIT_POSTGRES_DATABASES: ${KIT_POSTGRES_DATABASES:-courier}'
  expect_red_check 'breakage 86: the shared template defaults the tenant list to one of its own services' \
    "$eightythree" "$ENVTENANT" --static-only

  # 87. And kit's own harness stops declaring its tenant.
  #
  # This one is here because of a regression that every other check in the suite
  # passed straight through. Removing the `:-` fallback above was CORRECT, and it
  # broke `tests/stack_live_test.sh`, which had never declared a tenant because
  # for its whole life the fallback had been doing it. 214 static checks and 86
  # proofs were green. The stack live test was not, and it took ten minutes and
  # eight containers to say so.
  #
  # So the rule now also holds for kit's own harnesses, statically. What this
  # recipe is really proving is that the static rule catches the mistake the
  # live test caught — one second instead of ten minutes, and with no docker.
  eightythree="$(fresh_copy harness-stops-declaring-its-tenant)"
  edit "$eightythree/tests/stack_live_test.sh" \
    $'\nKIT_POSTGRES_DATABASES=kit_probe' ''
  expect_red_check 'breakage 87: a .env-writing harness stops declaring its tenant' \
    "$eightythree" "$HARNESSTENANT" --static-only
else
  # SKIPPED, and loudly, because a skipped proof is not a proof. The recipes above
  # are the only place kit asserts that its generated config is ACCEPTED by the
  # real binaries, so on a machine without them this file's claim about the Kamal
  # templates is simply unexercised — and the summary line is how that stays
  # visible rather than becoming a silent gap.
  printf 'SKIP self_test: breakages 78-82 — kamal or kamal-backup is not installed\n'
  skips=$((skips + 1))
fi


# ---------------------------------------------------------------------------
# 88: the SECOND tenant.
#
# Every other recipe in this file proves that ONE service gets a database. This
# one is the first to ask what happens when a second name is appended, and it
# exists because that question had never been asked and the answer was wrong.
#
# The defect was measured on a live cluster, not inferred:
#
#   $ KIT_POSTGRES_DATABASES="billing neighbour" bin/dev up
#   postgres-1 | [cluster] provisioning billingneighbour
#   postgres-1 | [cluster] done: 1 service database(s), one role each, PUBLIC holds CONNECT on none of them
#
# One database, named after BOTH services fused together, and a stack reporting
# success. `require_identifier` — whose own comment names "builds one identifier
# out of two tokens" as the failure worth preventing — could not see it, because
# the `tr -d '[:space:]'` in front of it DELETED the space first and handed the
# validator a perfectly legal identifier. Every check that could have caught
# this was looking at a single name.
#
# That is the shape of the blind spot, and it is worth stating plainly: this
# suite proved the one-cluster promise for the first tenant and was silent about
# the second. A fleet of nine services is nine repetitions of a case nobody had
# run twice.
#
# The proof runs the real `10-cluster.sh` with the real `psql` stubbed by a
# recording function, so it asserts the actual parse — which names it
# provisions and whether it refuses — without needing a container or a volume.
# ---------------------------------------------------------------------------

base88="$(fresh_copy kit-88)"
# Put the OLD parse back: strip ALL whitespace, so two names fuse into one.
#
# THE MUTATION IS LINE 144, NOT THE `service=` ASSIGNMENT, and getting that wrong
# is what made this proof vacuous for one merge cycle — it stayed GREEN on a tree
# carrying the exact defect it exists to catch.
#
# The fix for the fused name is not "stop using `tr -d`". It is TWO things: the
# outer trim at 144 keeps only the edges, and the `case` at 147 REFUSES a name
# that still holds whitespace inside it. The `service="$trimmed"` assignment at
# 156 is downstream of that refusal and is never reached for a fused name — the
# script has already exited 1 at 152. So mutating 156 puts the old `tr -d` back
# in a line that never runs, the refusal still fires, the test stays green, and
# the proof reports success while reintroducing nothing at all.
#
# Mutating 144 is the defect itself: `trimmed` becomes "billingneighbour", the
# `case` sees no whitespace, nothing is refused, and one database named after
# both services is provisioned by a stack that reports itself healthy. Measured
# both ways; the 144 mutation is the one that goes red.
edit "$base88/templates/compose/postgres/initdb/10-cluster.sh" \
  'trimmed="$(printf '"'"'%s'"'"' "$entry" | sed -e '"'"'s/^[[:space:]]*//'"'"' -e '"'"'s/[[:space:]]*$//'"'"')"' \
  'trimmed="$(printf '"'"'%s'"'"' "$entry" | tr -d '"'"'[:space:]'"'"')"'
# The needle is the FUSED NAME, not `REFUSING`. Those are not interchangeable, and
# picking the wrong one is how a proof that genuinely works still gets reported as
# broken: with the mutation above, the test goes red because the script exited 0
# having provisioned one database called `billingneighbour`, and that sentence
# never says REFUSING. A needle naming the refusal would have sent the harness
# looking for evidence the defect does not produce.
#
# `billingneighbour` appears in exactly two failure messages -- "provisioned:
# billingneighbour" and "the refusal did not create the fused database" -- and in
# neither on a green run, so it pins the defect rather than the file's mood.
expect_red_script 'breakage 88: two tenants separated by a space fuse into one database' \
  "$base88" tests/multi_tenant_split_test.sh '' \
  'billingneighbour'


# ---------------------------------------------------------------------------
# 68-74: the one-cluster topology and the connection contract.
#
# Seven checks, seven breakages, and every one of them is a check that could
# pass while the thing it is about is broken:
#
#   68  the Postgres tag disagrees between .env.example and compose — THE
#       defect that shipped (16.6-alpine against a 17-alpine default) and that
#       48689e6 fixed in the compose file only.
#   69  the tag is switched back to alpine — which builds cleanly and cannot
#       create an extension.
#   70  the init script is not mounted, so no service gets a database.
#   71  the budget is set below what the declared topology needs.
#   72  a generated config drops `application_name`.
#   73  a generated config carries a POOLER WORKAROUND — the invisible one, and
#       the reason the forbidden list exists.
#   74  DECISIONS.md is deleted — the file seven places reference and that did
#       not exist until this packet.
#
# 73 is the one worth the most: nothing about it looks wrong. A service carrying
# `prepare: :unnamed` on a fleet with no pooler is slower and correct-looking,
# and the ONLY way anyone finds out is a check that looks for it.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# THE ACCOUNT BOUNDARY. Three breakages, numbered from 90 because the
# header/recipe check at the bottom of `validate.sh` requires every recipe to be
# DOCUMENTED and every documented number to be CARRIED — so a packet that adds
# checks has to add its own place in this list rather than renumbering ninety
# recipes.
#
#   90. FORCE ROW LEVEL SECURITY removed from the substrate    -> red
#   91. a driver stops READING the assertion manifest          -> red
#   92. the manifest and the proof stop agreeing               -> red
#
# 90 is the one the whole packet exists for, and the reason it is here as well as
# in `tests/tenancy_test.sh` is that the two are different claims about different
# layers. THAT suite proves the templates work against a real Postgres, with the
# live proof going red. THIS one proves kit's STATIC gate would notice the
# templates being edited into an unenforced state — which is the claim about a
# reviewer with no database, and it is the one that keeps the property alive
# between runs of the expensive suite.
#
# All three name the check, because "the gate went red" is a weak proof when a
# hundred checks can make it red: a breakage caught by the wrong check still reads
# as a pass, and the check it was written for can then be dead code forever.
# ---------------------------------------------------------------------------
TENANCY='templates/database/tenancy/*  (the account boundary, in the templates that enforce it)'

# 90. The one no guide mentions and no lint in this fleet checked for. Deleting
# the EXECUTABLE statement rather than the word is the whole mutation: the
# substrate's comments quote `force row level security` twice while explaining why
# it exists, so a mutation that removed the word would satisfy a check that reads
# the file as text — and the tenancy contract check strips SQL comments first
# precisely because of that.
base90="$(fresh_copy kit-90)"
edit "$base90/templates/database/tenancy/substrate.sql" \
  "  execute format('alter table %s force row level security', p_table);
" ""
expect_red_check 'breakage 90: FORCE ROW LEVEL SECURITY is removed from the substrate' \
  "$base90" "$TENANCY" --static-only

# 91. A driver that reads isolation.sql and stops reading assertions.txt. It
# still runs, still passes, and now asserts "no red rows" about an unknown number
# of assertions — a green suite proving less than it says. The mutation replaces
# the manifest read with a SECOND read of the file the driver still reads, which
# is the honest version of the mistake: the token is still in the file, the
# comment above the helper still explains the comparison, and the only thing that
# changed is the argument.
base91="$(fresh_copy kit-91)"
edit "$base91/templates/database/go/tenancy_test.go.snippet" \
  'os.ReadFile(here(t, "assertions.txt"))' 'os.ReadFile(here(t, "isolation.sql"))'
expect_red_check 'breakage 91: a driver reads the proof but no longer the assertion manifest' \
  "$base91" "$TENANCY" --static-only

# 92. The manifest and the proof disagree. One line removed from assertions.txt is
# enough: the driver that reads it then compares against a shorter list than the
# proof produces, which is the failure the file exists to stop. The reverse
# direction — a name in the manifest the proof never makes — is the same check on
# the same token, and one recipe covers it, because the check reports both and a
# check reporting only one would be half a contract.
base92="$(fresh_copy kit-92)"
edit "$base92/templates/database/tenancy/assertions.txt" \
  'owner/another-tenants-rows-read-as-none
' ''
expect_red_check 'breakage 92: the assertion manifest and the proof stop agreeing' \
  "$base92" "$TENANCY" --static-only

# 93. THE ADVISOR AND THE PROOF THAT IT FIRES, STOPPED AGREEING. `advisor.sql`
# is the only thing in the account boundary that grades the LIVE DATABASE, and
# every rule in it is graded by a fixture in `tests/tenancy_test.sh` — a script
# `--static-only` never runs. So before this check the two lists were compared by
# nothing: a rule could be renamed, or its trip fixture renamed with it, and
# every static check in this repository stayed green while the suite proved a
# rule that no longer existed.
#
# THE MUTATION IS THE RULE'S OWN NAME, in the union arm that produces it. That is
# deliberately the smallest thing that moves: the SQL still installs, still
# parses, still returns rows, and the rule is still every bit as correct. It just
# no longer agrees with the fixture that trips it — which is the exact shape of
# the drift this catches, and the drift is silent in the worst direction, since a
# renamed rule is a rule whose proof no longer runs rather than a rule that is
# broken.
#
# AND WHAT THIS RECIPE DOES NOT CLAIM, which is worth as much as what it does.
# The FIRST version of this mutation stripped the rule's `having` — the
# condition that requires the view to read something protected — on the theory
# that removing the narrowing would make the rule fire everywhere and that this
# check could see it. Measured: the gate stayed GREEN. The check compares rule
# NAMES, so a rule that is present, correctly named and no longer selective is
# invisible to it by construction. A static check that read rule bodies would
# have to parse SQL, which is the parse whose misses are silent and which this
# file has already declined three times (advisor.sql is SKIPped by the parser
# loop with a note saying `tests/tenancy_test.sh` is its check).
#
# So the two properties are proved by two different files, deliberately:
#   * THAT THE RULE FIRES, and does not misfire -> tests/tenancy_test.sh, which
#     runs a real cluster and asserts both positives AND six negatives.
#   * THAT THE ADVISOR AND ITS PROOF AGREE -> this check, statically.
# Neither substitutes for the other, and this recipe says which is which rather
# than claiming a mutation it cannot make.
base93="$(fresh_copy kit-93)"
edit "$base93/templates/database/tenancy/advisor.sql" \
  "  select 'security_definer_view'::text as name,
         'ERROR'::text as level," \
  "  select 'security_definer_view_v2'::text as name,
         'ERROR'::text as level,"
expect_red_check 'breakage 93: the advisor and the fixtures that trip its rules stop agreeing' \
  "$base93" "$TENANCY" --static-only

# 93. THE ADVISOR AND THE PROOFS THAT TRIP ITS RULES STOP AGREEING. The last
#     hole of the account boundary's own gate: `advisor.sql` is the only thing
#     here that grades the LIVE DATABASE, its rules are proved by fixtures in
#     `tests/tenancy_test.sh`, and `--static-only` runs neither. So nothing
#     compared the two lists, and a rule renamed with its fixture left the whole
#     static gate green while the suite proved a rule that no longer existed.
#     `tenancy_contract_check` now compares the rule NAMES both ways.
#
#     This is the SECOND check on the account boundary, and not a third: the one
#     that proves the RULES FIRE is `tests/tenancy_test.sh` and cannot be a
#     static check, and the first attempt at this recipe mutated the rule's
#     `having` clause instead of its name — and the gate stayed GREEN, because a
#     rule that is present, correctly named and no longer selective is invisible
#     to a check that compares names. Measured, and written down at the recipe
#     rather than quietly corrected: the mutation a check can see is not always
#     the mutation that matters, and the two are proved by two files.
base68="$(fresh_copy kit-68)"
edit "$base68/templates/compose/.env.example" \
  'KIT_POSTGRES_TAG=17' 'KIT_POSTGRES_TAG=16.6-alpine'
expect_red_check 'breakage 68: the Postgres tag in .env.example disagrees with compose' \
  "$base68" 'postgres tag  (.env.example and compose agree' --static-only

base69="$(fresh_copy kit-69)"
edit "$base69/templates/compose/.env.example" \
  'KIT_POSTGRES_TAG=17' 'KIT_POSTGRES_TAG=17-alpine'
edit "$base69/templates/compose/docker-compose.yml" \
  'POSTGRES_TAG: ${KIT_POSTGRES_TAG:-17}' \
  'POSTGRES_TAG: ${KIT_POSTGRES_TAG:-17-alpine}'
expect_red_check 'breakage 69: the cluster is pinned back to an alpine variant' \
  "$base69" 'postgres tag  (.env.example and compose agree' --static-only

base70="$(fresh_copy kit-70)"
# The search string carries the FIXED form of the line. It did not used to, and
# that is worth recording because the failure mode was silent in the worst way:
# `edit` `sys.exit`s when its search string is absent, so when the P0 fix
# changed the mount from a bare `./postgres/initdb` to
# `${KIT_COMPOSE_DIR:-.}/postgres/initdb` this recipe stopped matching and the
# whole suite DIED partway through, mid-run, after sixty-odd breakages had
# already been reported green. A harness that stops is not a harness that
# reports. Breakage 83 is the same mutation with the opposite polarity - it puts
# the bare form back and asserts the NEW rule catches it - so the two together
# now say both halves: the fixed line is accepted, and the reverted line is not.
edit "$base70/templates/compose/docker-compose.yml" \
  '      - ${KIT_COMPOSE_DIR:-.}/postgres/initdb:/docker-entrypoint-initdb.d:ro
' ''
expect_red_check 'breakage 70: the init script is never mounted, so no service gets a database' \
  "$base70" 'the cluster  (one database + role per service' --static-only

base71="$(fresh_copy kit-71)"
edit "$base71/templates/compose/.env.example" \
  'KIT_POSTGRES_MAX_CONNECTIONS=200' 'KIT_POSTGRES_MAX_CONNECTIONS=12'
expect_red_check 'breakage 71: the connection budget is below what the topology needs' \
  "$base71" 'the connection budget  (max_connections covers' --static-only

# The two halves of the connection contract, and they are broken in opposite
# directions on purpose: 72 removes something the service NEEDS, 73 adds
# something it must not carry. A check that only did one of them would be
# satisfied by a config that has the wrong settings in place of the right ones.
base72="$(fresh_copy kit-72)"
# The whole assignment goes, not its value: an EMPTY value still contains the
# key, so a check that greps for `application_name` would be satisfied by the
# exact defect — a service whose queries cannot be attributed to it, which is the
# bug the setting exists to prevent.
#
# AND THIS RECIPE WAS GREEN ON A CHECK THAT COULD NOT SEE IT, which is the
# second half and the reason it is worth the paragraph above. The go snippet's
# header comment reads "1. application_name — THE ONE THAT IS NOT OPTIONAL", so
# after the line above was deleted the substring was still in the file — in a
# COMMENT — and the contract check reported the contract satisfied. The recipe
# ran, the mutation was real, and the check agreed with the tree.
#
# The rule is the one AGENTS.md states about `-count=1` — a check a comment can
# satisfy is not a check — and the check now strips comments per language before
# looking for a required setting. The two things this recipe proves are
# different and both matter: the SETTING is required (it is), and the check reads
# code rather than prose (it now does). A recipe that passed for the first reason
# would have been green either way.
edit "$base72/templates/database/go/database.go.snippet" \
  '	cfg.ConnConfig.RuntimeParams["application_name"] = serviceName
' ''
expect_red_check 'breakage 72: a generated config does not set application_name' \
  "$base72" 'templates/database/*  (the contract, in the generated output' --static-only

base73="$(fresh_copy kit-73)"
edit "$base73/templates/database/elixir/repo.exs.snippet" \
  '        application_name: @service_name,' \
  '        application_name: @service_name,
      prepare: :unnamed,'
expect_red_check 'breakage 73: a generated config carries a POOLER WORKAROUND' \
  "$base73" 'templates/database/*  (the contract, in the generated output' --static-only

base74="$(fresh_copy kit-74)"
rm -f "$base74/DECISIONS.md"
expect_red_check 'breakage 74: DECISIONS.md deleted — seven places reference it' \
  "$base74" 'DECISIONS.md  (exists, records trades' --static-only

# ---------------------------------------------------------------------------
# 75: THE ONE THAT WOULD HAVE CAUGHT A REGRESSION KIT-21 SHIPPED.
#
# kit-21 turned the cluster into a BUILT image, so kit's compose went from
#
#     image: postgres:${KIT_POSTGRES_TAG:-…}      ->  image: kit-postgres:${…}
#
# and `check_stale_copy` — FAILURE MODE 1, the check whose whole job is naming
# the services running their own copy of the platform — matched a service's image
# against kit's by BARE REPOSITORY NAME. The rename changed `postgres` to
# `kit-postgres`, a duplicating service still writes `postgres`, and the two
# stopped matching. Measured, on the commit that shipped it:
#
#     $ fleet_check.py --repos-dir <fleet whose alpha runs postgres:17>
#     PASS fleet: no service carries a copy of kit's stack, …
#
# Five repositories in the real fleet carry their own postgres, so the check
# written to name them was reporting a clean fleet, and it did so SILENTLY: it
# still ran, still printed PASS, and printed no skip.
#
# WHY 52/59/60 DID NOT CATCH IT, which is the part worth a breakage of its own.
#
# `break_stale_copy` writes a `ports:` entry on the copy, and
# `check_override_surface` reports a published port by SERVICE NAME — a name the
# rename never touched. So breakage 60 went red on the port half and nobody found
# out the image half had stopped working. The recipe was green; the check it was
# proving was half dead.
#
# That is a green control proving less than it appears to, and this repository's
# own rule about controls says so directly: a control that goes red for a reason
# another check created is not evidence. So 75 is the SAME defect with the
# `ports:` line REMOVED, which leaves `check_override_surface` nothing to report
# and makes the image comparison the only thing that can go red. If the image
# half is ever disarmed again, 60 stays green and 75 does not.
#
# The needle is the finding's own text rather than the check's PASS line, so a
# `check_stale_copy` that stopped firing and a fleet check that passed for some
# other reason cannot be confused for one another.
# ---------------------------------------------------------------------------
base75="$(fresh_copy kit-75)"
seventyfive_fixture="$(fixture_fleet stale-image-only)"
break_stale_copy_no_ports "$seventyfive_fixture"
export KIT_FLEET="$seventyfive_fixture"
# The needle is the CHECK LABEL, not the finding's wording — and that is the
# correction, because the first version of this recipe asserted the finding text
# and was therefore WRONG for a reason that had nothing to do with the check it
# was proving. `expect_red_check` matches `FAIL $want`, and the finding is not in
# the label: it is an indented detail line under it.
#
#     FAIL fleet  (no stale copy, no weakened boundary, …)
#            - alpha/db: runs 'postgres:17', which is the image kit's stack …
#
# So the recipe reported "the gate went red, but NOT via `which is the image
# kit's stack already ships`" while printing that exact string two lines above the
# complaint — which is the signature of the 64K pipe-buffer defect this file
# already documents, except here the cause is the needle rather than the reader.
# The general rule, and it is the same one as `reportUnusedDisableDirectives`: a
# needle has to be a thing the check actually EMITS, and the check emits its
# label.
expect_red_check 'breakage 75: a service runs its own postgres IMAGE, with no port to catch it' \
  "$base75" 'fleet  (no stale copy, no weakened boundary' --static-only
unset KIT_FLEET

# ---------------------------------------------------------------------------
# 76-77: THE DOCUMENTED `bin/dev` COMMANDS ARE REAL.
#
# kit-21 added `bin/dev db grant` to four files' prose — templates/database/
# README.md, DECISIONS.md, the init script and the compose file — and never added
# the command. Every one of those four is a reader told the way out of "my
# service's database was never created" exists, running it, and getting
# `unknown command`. DECISIONS.md exists because this repository referenced a
# document that did not exist; this is the same defect one layer down, and it is
# the reason there is now a check for it.
#
# TWO recipes rather than one, because there are two ways to break it and they
# fail differently. Removing the whole `db` arm leaves a documented COMMAND with
# nothing behind it. Removing only the `grant` arm leaves a command whose
# SUBCOMMAND is gone — and that is the harder one, because a check which only
# asks "is `db` dispatched" reports a clean tree while four files still promise
# `db grant`. Both were measured by hand before they were written down here.
#
# The needle is the finding's own wording, so a `bin_dev_command_check` that had
# silently stopped firing cannot be confused with a different check going red.
# ---------------------------------------------------------------------------
base76="$(fresh_copy kit-76)"
"$PY" - "$base76/templates/bin/dev.sh" <<'PYEOF'
import re
import sys

path = sys.argv[1]
body = open(path, encoding="utf-8").read()
# The whole arm, which is several lines ending in `      ;;`.
stripped = re.sub(r"^    db\)\n(?:.*\n)*?      ;;\n", "", body, count=1, flags=re.M)
if stripped == body:
    sys.exit("self_test: breakage 76: the `db` arm was not found in "
             "templates/bin/dev.sh — the recipe's subject has moved")
open(path, "w", encoding="utf-8").write(stripped)
PYEOF
expect_red_check 'breakage 76: bin/dev does not dispatch a command four files tell you to run' \
  "$base76" 'bin/dev  (every command the documentation promises' --static-only

base77="$(fresh_copy kit-77)"
"$PY" - "$base77/templates/bin/dev.sh" <<'PYEOF'
import sys

path = sys.argv[1]
body = open(path, encoding="utf-8").read()
old = """        grant)
          shift
          db_grant "${1:-}"
          ;;
"""
if old not in body:
    sys.exit("self_test: breakage 77: the `grant` subcommand arm was not found in "
             "templates/bin/dev.sh — the recipe's subject has moved")
open(path, "w", encoding="utf-8").write(
    body.replace(old, '        *) die "no subcommand" ;;\n', 1)
)
PYEOF
expect_red_check 'breakage 77: bin/dev takes a command whose subcommand four files promise is gone' \
  "$base77" 'bin/dev  (every command the documentation promises' --static-only

# ---------------------------------------------------------------------------
# 78-79: kit OWNS A SECOND CALLABLE STANDARD, AND THE WIDENED COPY CHECK IS
#         STILL A COPY CHECK.
#
# kit-32 added `.github/workflows/image.reusable.yml` — the workflow that builds
# a service's image and pushes it to ghcr.io — because nothing in the fleet
# built the image `config/deploy.yml` deploys. Adding it made `callable_check`
# go RED, naming a second copy of the CI standard where there was a second
# STANDARD. The check's rule was "exactly one file may declare
# `workflow_call`", which is a freeze dressed as a drift check, and kit-32
# widened it: files at paths in REUSABLE_WORKFLOWS are exempt, and everything
# else is judged on its parsed `name:`.
#
# A widened check is a check that might have been widened into uselessness, and
# the only way to know is to break it in both directions it now claims to cover.
# Two breakages rather than one, for that reason, and they must be caught by
# DIFFERENT findings in the same check: 78 is the original defect (a parked
# copy), 79 is the new one the widening made possible (a callable workflow
# nobody declared).
#
# Without them the honest description of the widening would be "a check that had
# been reporting a defect that did not exist now reports nothing at all", which
# is a plausible sentence and, as far as anyone would know, an accurate one.
# ---------------------------------------------------------------------------
base78="$(fresh_copy kit-78)"
cp "$base78/.github/workflows/ci.reusable.yml" \
   "$base78/.github/workflows/ci-parked-elsewhere.yml"
expect_red_check 'breakage 78: a COPY of a declared standard is parked where no caller can reach it' \
  "$base78" "$CALLABLE" --static-only

base79="$(fresh_copy kit-79)"
# NOT a copy. A different `name:` is the whole point: this is the file kit-32
# added, parked at a path nothing declares. Being under `.github/workflows/` was
# never what exempted it — being at a DECLARED path is, which is exactly the
# distinction the widening was supposed to preserve.
printf -- '---\nname: image\non:\n  workflow_call:\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' \
  >"$base79/.github/workflows/image.yml"
rm "$base79/.github/workflows/image.reusable.yml"
expect_red_check 'breakage 79: a callable workflow ships at a path kit does not declare, so nothing polls it' \
  "$base79" "$CALLABLE" --static-only

# 94 and 95. THE HARNESS'S OWN SHARDING, in the two directions it can be wrong.
#
# Neither is reachable by an `expect_red_check`, and that is the whole reason they
# exist: every other recipe in this file proves that the GATE goes red, and the
# gate is not what shards. What went wrong was arithmetic in this file — a 0-based
# residue compared against a 1-based shard index — so shard `n/n` asked for a
# class nobody is in, ran nothing, and reported PASS. Four shards as a merge gate
# covered three quarters of the suite and said all four were green. A recipe that
# mutated a check could not have found it; there was no check.
#
# `tests/shard_test.sh` is the check, and it evaluates the real `_shard_claims`
# out of this file rather than restating it — a second copy of the modulo would be
# a second thing to be wrong, which is the shape of defect this pair is about.
#
# 94 is the defect itself, in one line. 95 is the half that is easy to delete by
# accident: the refusal that makes an OVER-PROVISIONED shard loud. It is a
# separate recipe because a check proved able to catch the arithmetic and unable
# to notice that the safety net was gone would still have shipped a shard that
# silently verified nothing.
base94="$(fresh_copy kit-94)"
edit "$base94/tests/self_test.sh" \
  'idx=$(( (num - 1) % _shard_n + 1 ))' 'idx=$(( num % _shard_n ))'
# The needle is the sentence that names shard n/n, not the word FAIL: this check
# reports the empty shards it found, and a recipe that asserted only "went red"
# would pass on a mutation that emptied a DIFFERENT shard.
expect_red_script 'breakage 94: the shard key is 0-based again, so shard n/n verifies nothing' \
  "$base94" tests/shard_test.sh '' 'THE SHIPPED DEFECT'

base95="$(fresh_copy kit-95)"
edit "$base95/tests/self_test.sh" \
  'if [ "$_shard_n" -gt "$_shard_suite_max" ]; then' 'if false; then'
expect_red_script 'breakage 95: an over-provisioned shard is no longer refused at the door' \
  "$base95" tests/shard_test.sh '' 'an over-provisioned shard count'

# ---------------------------------------------------------------------------
# THE VERSION STRING'S OWN GATE, and the four properties that make it a promise
# rather than a paragraph. Each one names ONE check and mutates ONE thing, which
# is the rule 75 exists for: a fixture that can go red two ways proves the gate
# can go red and says nothing about which half fired.
#
# EVERY VERSION IN THE FOUR IS DERIVED FROM THE COPY, and that is the whole of
# this section's repair. All four used to spell their mutation out of a literal
# `1.0.0`, which made each of them a time bomb with a fuse of exactly one
# release and this repository has now detonated one (see `copy_version`). What a
# reader can no longer see at a glance is which concrete version each recipe
# exercises today, and the answer is now printed by the gate in the copy rather
# than written here: `bump` is a pure function of the copy's own VERSION, so the
# numbers are in `VERSION` and `CHANGELOG.md` of the tree being mutated, and
# `copy_version` refuses anything it cannot decompose rather than guessing.
# ---------------------------------------------------------------------------

# 96. A MAJOR bump that owes a MIGRATION and does not pay.
#
# VERSION is moved to the next MAJOR of whatever the copy carries, and the
# changelog grows a matching section that says it is breaking — so everything
# the tier DOES require is present except the one artefact it is named after.
# No MIGRATIONS.md section exists for a version that has not shipped, which is
# the point: a consumer who adopts kit by copy cannot apply a sentence, and a
# MAJOR that ships without the migration is exactly the "read the diff" answer
# this packet exists to delete.
#
# The mutation is DERIVED and the derivation is the point rather than a
# convenience: a MAJOR of a MAJOR is what makes this recipe mean the same thing
# at 2.0.0, at 3.0.0 and at 10.4.0. Spelling the destination instead would make
# it prove only that a bump that is no longer possible still goes red.
base96="$(fresh_copy kit-96)"
v96="$(copy_version "$base96")"
v96_major="$(bump "$v96" major)"
edit "$base96/VERSION" "$v96" "$v96_major"
edit "$base96/CHANGELOG.md" "## $v96" "## $v96_major

### Breaking

- the tier is \`breaking\` and this says so.

## $v96"
expect_red_check 'breakage 96: a MAJOR bump ships without the MIGRATION the tier owes' \
  "$base96" 'stability gate' --static-only

# 97. A MINOR that declares a breaking change.
#
# This is the rule the whole mechanism turns on, and it is the one that needs NO
# predecessor to check: a `### Breaking` heading is legal only under a version
# whose MAJOR actually moved. Here the MINOR's section claims a breaking change,
# so the promise "a MINOR takes nothing away" is falsified by the repository's
# own changelog.
#
# MINOR, not MAJOR, and derived: a MINOR is the bump that must not break, so a
# MINOR that says it does is the only falsification of the additive promise. The
# derivation keeps that true for whatever version the copy carries.
base97="$(fresh_copy kit-97)"
v97="$(copy_version "$base97")"
v97_minor="$(bump "$v97" minor)"
edit "$base97/VERSION" "$v97" "$v97_minor"
edit "$base97/CHANGELOG.md" "## $v97" "## $v97_minor

### Breaking

- a MINOR bump that says it breaks something.

## $v97"
expect_red_check 'breakage 97: a MINOR bump declares a breaking change' \
  "$base97" 'stability gate' --static-only

# 98. A `### Breaking` heading parked under a section no version covers.
#
# The subtler half of 97, and it is a different failure: nothing has been
# released, so there is no version to check the bump against, and a breaking
# change covered by no version at all is a consumer reading a promise that no
# number carries. The version file is untouched — this mutation is entirely in
# the changelog — which is what proves the rule reads the whole history rather
# than only the bump being proposed.
#
# THE HEADING IS DERIVED, and this recipe held a second time bomb that the first
# sweep missed: its anchor was `## Unreleased\n\n### Added`, so it died the same
# day 96, 97 and 99 did, for a DIFFERENT reason — `a5f8746` inserted
# `### Changed` as the first subsection under Unreleased and the recipe never
# mentioned it. It also had a bomb the literal hid: the next release renames
# `## Unreleased` to the version it became, and at that point "a `### Breaking`
# under a section no version covers" is a section this recipe has to CREATE
# rather than find, which is the branch below.
#
# BOTH BRANCHES ANCHOR ON A DERIVED HEADING, and that is the asymmetry worth
# being precise about: the one remaining `## Unreleased` literal is on the
# REPLACEMENT side of the create branch, so renaming the convention would change
# what this recipe writes and not whether it applies. A literal in an anchor is
# a recipe that dies; a literal in a replacement is a recipe that writes an
# out-of-date name. The first is a lost proof and the second is a cosmetic bug,
# and only the first is worth deriving — so this one is left written down and
# said out loud rather than defended by a helper.
base98="$(fresh_copy kit-98)"
v98_head="$(grep -m1 '^## ' "$base98/CHANGELOG.md")"
v98_body="${v98_head#\#\# }"
if printf '%s' "$v98_body" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  # everything has been released, so no version-less section is left to park it
  # under and this recipe adds one above the newest version
  edit "$base98/CHANGELOG.md" "$v98_head" "## Unreleased

### Breaking

- parked here, where no version covers it.

$v98_head"
else
  # the copy still carries one, and WHICH `###` subsection follows it is not this
  # recipe's business
  edit "$base98/CHANGELOG.md" "$v98_head" "$v98_head

### Breaking

- parked here, where no version covers it."
fi
expect_red_check 'breakage 98: a breaking change sits under Unreleased, where no version covers it' \
  "$base98" 'stability gate' --static-only

# 99. A version string that cannot be placed.
#
# A prerelease suffix is the interesting case, and refusing it is a decision
# rather than a strictness reflex: a suffix makes the derived tier change
# meaning when it is dropped, so the string stops being the source of truth for
# its own promise. The check must fail closed rather than tier it, and it must
# fail at the DOOR — before anything is derived from a string that means two
# things.
#
# THE SUFFIX IS APPENDED TO THE COPY'S OWN VERSION, so it is a prerelease OF
# whatever is current rather than of a version that stopped existing. A literal
# `1.0.0-rc1` would have kept this recipe alive for exactly as long as the
# tree stayed at 1.0.0, which is a property of the release calendar rather than
# of the check.
base99="$(fresh_copy kit-99)"
v99="$(copy_version "$base99")"
edit "$base99/VERSION" "$v99" "$v99-rc1"
expect_red_check 'breakage 99: a prerelease version string is tiered instead of refused' \
  "$base99" 'stability gate' --static-only

# 100. A reserved name comes back.
#
# RESERVED exists for exactly one thing — a retired template path that must
# never come back, because the services that copied it outlive the decision —
# so the proof that it is load-bearing is that the path can be restored and the
# gate notices. Without this the file is a note, and a note in the same dialect
# as two allowlists reads exactly like the two allowlists' checks.
base100="$(fresh_copy kit-100)"
mkdir -p "$base100/templates/backup"
printf 'the withdrawn distribution, back again under the same name\n' \
  >"$base100/templates/backup/README.md"
expect_red_check 'breakage 100: a reserved name is back in the tree' \
  "$base100" 'reserved tombstones' --static-only

printf '\n'
# TWO skip kinds, counted apart, because they are two different problems and one
# message would misdescribe half of them.
#
#   `skips`         a missing TOOLCHAIN. The recipe is sound and the machine
#                   cannot run it. Fix the machine.
#   `env_skips`     the gate exited non-zero reporting NO finding at all (see
#                   `expect_red_check`). The recipe could not be EVALUATED, so
#                   this is not evidence about the check and must never be
#                   reported as one.
#
# Both are fatal, and both stay fatal: a proof nobody ran is not a proof, and
# collapsing the second into the first is how a machine problem gets filed as a
# gate defect and "fixed" by weakening something.
if [ "$failures" -ne 0 ]; then
  echo "FAIL: self_test — $failures breakage(s) the gate did not catch."
  [ "$skips" -eq 0 ] || echo "note: $skips breakage(s) skipped (no toolchain) — reported above."
  [ "$env_skips" -eq 0 ] || echo "note: $env_skips breakage(s) SKIPPED as ENVIRONMENT failures (the gate reported no finding) — reported above. These are not gate defects."
  exit 1
fi
if [ "$skips" -ne 0 ] || [ "$env_skips" -ne 0 ]; then
  [ "$skips" -eq 0 ] || echo "FAIL: self_test — $skips breakage(s) skipped for a missing toolchain. A skipped proof is not a proof."
  [ "$env_skips" -eq 0 ] || echo "FAIL: self_test — $env_skips breakage(s) could not be evaluated (the gate exited without reporting a finding). An unevaluated proof is not a proof, and this one is an environment failure rather than a gate defect."
  exit 1
fi
# 101. The skip stops requiring the work to still be there.
#
# The single most expensive thing a cache can do is hand back a green for work
# it never did, and the clause that prevents it is the cheapest one in the file:
# the record stored the SET of paths its output globs matched, and the lookup
# re-checks that set before answering. Delete that comparison and the cache
# keeps working perfectly on every case it can still see -- a cold cache is still
# a miss, a changed input is still a miss, a corrupt record is still refused --
# and it goes wrong in exactly one case, which is the case that matters: a tree
# whose outputs were deleted while its inputs did not change.
#
# So the mutation is invisible to everything else in this file, and it is caught
# by `tests/fingerprint_test.sh` proofs 1a and 1b, which assert that a matching
# fingerprint over a tree with no outputs is NOT a hit. The assertion is written
# as an exit CODE rather than as a sentence so that a recipe that stopped
# applying would go red on itself instead of passing on a mutation it no longer
# reaches -- the defect breakage 2 and 4 already paid for once.
base101="$(fresh_copy kit-101)"
edit "$base101/tests/fingerprint.py" \
  '    if now_paths != record["output_paths"]:' '    if False:  # the clause this breakage deletes'
expect_red_check 'breakage 101: the outputs conjunct is deleted from the skip, so a cache with no work on disk still answers HIT' \
  "$base101" 'tests/fingerprint_test.sh' --static-only


# 102. The advisor rule that reads a policy's own correlated subquery, with the
#     test that reads it deleted.
#
# The mutation replaces the `(m[2] ~ ...)` half of `qual_hit` with
# `where (false)`. Two details make it the RIGHT mutation and not merely a red
# one:
#
#   - It is PAREN-BALANCED. The tempting spelling -- prefixing the condition with
#     `false and (` -- leaves an unclosed paren, the function fails to install,
#     and EVERY rule goes silent at once. That is a different red from the one
#     this breakage claims to prove, and a breakage that proves the wrong thing
#     is worse than no breakage: it looks like coverage.
#   - It is the `qual_hit` half only. The text ends at `as qual_hit,` so the
#     match is unambiguous and `edit`'s single replacement cannot reach the
#     check_hit copy. Killing both would prove less precisely.
#
# What it proves: the rule is load-bearing against a real cluster, and the trip
# pair `rls_policy_correlated_membership:correlated_membership` goes red BY NAME
# rather than the suite merely noticing that something changed.
base102="$(fresh_copy kit-102)"
edit "$base102/templates/database/tenancy/advisor.sql" \
  "                      where (m[2] ~ ('(^|[^a-z0-9_\$])' || po.relname || '\\.')
                          or m[2] ~ ('(^|[^a-z0-9_\$])' || po.nspname || '\\.' || po.relname || '\\.'))), false) as qual_hit," \
  '                      where (false)), false) as qual_hit,'
expect_red_check 'breakage 102: the correlated-subquery test is deleted from the advisor rule, so the slow policy shape goes unreported' \
  "$base102" 'tests/tenancy_test.sh'

# ---------------------------------------------------------------------------
# 103: THE OWNERSHIP CHECK IS LOAD-BEARING.
#
# WHAT IT PROVES, and what it is the second recipe for. `HANDOFF-kit-provenance-01`
# scoped a breakage to prove the REDACTION grammar (widen `shape_source` to
# accept anything); that claim is now carried by part A of
# `tests/provenance_test.sh`, which asserts all eleven refusals. This one is the
# packet's other half and it was previously unprovable, which is why the defect
# survived: `--verify` had NO ownership check, so there was nothing to mutate.
#
# THE MUTATION DELETES THE NAMESPACE OWNERSHIP BLOCK — the `if [ -z "$got_dirty" ]
# && [ -z "$got_tv" ]` test and its body — from `emit_verify`. Nothing else. The
# grammar is untouched, the exit codes are untouched, `docker/provenance.sh`
# still parses, still prints all five fields, and every part A refusal still
# passes: this is not a script that broke, it is a script with one decision
# removed.
#
# ONE MUTATION, ONE CAUSE. Two other mutations would have been available and
# both are the trap this repo's own header warns about:
#   - deleting the SHAPE loop instead also reds part A, so the recipe could
#     report red for a reason it did not introduce and the needle would prove
#     nothing about ownership;
#   - deleting the `--expect-source` mismatch branch instead leaves D1/D2 GREEN,
#     because those two cases carry no `--expect-source` and the namespace block
#     is what catches them. A control satisfiable by two different checks proves
#     the gate can go red and says nothing about either.
# So the mutation is chosen to be reachable by exactly one assertion group, and
# the needle below names that group.
#
# WHY IT MUST SIT ABOVE THE SUMMARY BLOCK. Breakage 101 sat below it and no
# shard ever claimed it, so a run that could fail counted it as evaluated; that
# hidden exit code is the reason this placement is commented at all.
base103="$(fresh_copy kit-103)"
edit "$base103/docker/provenance.sh" '  if [ -z "$got_dirty" ] && [ -z "$got_tv" ]; then' '# 103: ownership-by-namespace removed
  if false; then'
edit "$base103/docker/provenance.sh" '    return 6
  fi

  # --- OWNERSHIP, HALF TWO' '    return 0
  fi

  # --- OWNERSHIP, HALF TWO'
expect_red_check 'breakage 103: the ownership-by-namespace check is removed, so a base image inherits a stamp that satisfies ours' \
  "$base103" 'tests/provenance_test.sh  (11 leak shapes refused'

# The count is COUNTED, not written down. Every breakage above calls exactly one
# of the four red-expecting helpers, so this cannot drift from the recipes the
# way a hardcoded "all N breakages" does — and the header's list is checked
# against it by `tests/validate.sh`, so a breakage added without a header entry
# (or a header entry with no recipe) is a red gate rather than a doc that lies.
#   Anchored on the breakage LABEL, and identical to the `_st_breakages` /
#   `_st_reds` patterns in tests/validate.sh. Both used to anchor on `^expect_`,
#   which also matched the four helper *definitions* — `expect_red() {` looks
#   exactly like a call to a name-only pattern — so this printed 28 over 23
#   recipes for a run. Two files printing two different counts of the same file,
#   side by side, is the defect this repo keeps refusing to ship; the fix is to
#   count something that cannot be a definition.
#
#   Only the reds are counted as reds, and the green-expecting proofs are named
#   separately. Breakages 23b and 59 assert a green gate on purpose — 23b names a
#   SKIP, 59 names a FINDING — and a summary claiming either "went red" would be
#   a false statement about a proof that passed. kit-12's 31b is an `expect_green`
#   and is deliberately not in either count: it is a control, and its label
#   carries a number so the header can name the claim without giving a control a
#   numbered entry. `tests/validate.sh` says the same thing in the same words.
#
#   `env_skips` cannot appear in this sentence at all, and that is deliberate: it
#   is non-zero only on a run that exits 1 above, so the PASS line is only ever
#   printed when every recipe was EVALUATED. A count of proofs that ran is not a
#   claim that they held, which is why the sentence says "hold" and why the
#   unevaluated case is fatal rather than footnoted.
if [ -n "$_shard_i" ]; then
  # The suite's size, counted from THIS SOURCE rather than from a running
  # total. A shard does not run every recipe, so a counter incremented as
  # recipes execute would report the shard's OWN count here and print
  # "ran N of N" -- true of every shard, and a claim about the suite made by a
  # run that never saw the suite. Counted the same way the un-sharded summary
  # below counts it, so both agree on what "the suite" means.
  total=$(grep -cE '^ *expect_(red|green)(_check|_lang|_script)? +.breakage +[0-9]+[a-z]*:|^ *expect_skip_check +.breakage +[0-9]+[a-z]*:' "$0" || true)
  # A SHARD, not the suite. This line is deliberately NOT the sentence above: a
  # sharded run has not evaluated every breakage, so claiming it did is the one
  # false statement available here. It reports the shard, how many recipes it
  # actually ran, and -- because a shard that ran NOTHING is a misconfigured
  # shard rather than a passing one -- that case is a failure, not a clean run.
  if [ "$_shard_ran" -eq 0 ]; then
    echo "FAIL: self_test — shard $_shard_i/$_shard_n ran ZERO of the suite's $total breakages."
    echo "       A shard that evaluates nothing agrees with a suite that evaluates nothing."
    echo "       A mis-sharded run reporting PASS is worse than no run at all."
    exit 1
  fi
  # A SHARD THAT FAILED MUST NOT PRINT "EVERY ONE IT RAN HELD".
  #
  # This block exited 0 without reading `failures` at all, so a breakage that
  # genuinely failed inside a sharded run printed its own FAIL line and then had
  # the shard summarised as PASS — the sentence asserting the opposite of what
  # the line above it said. The un-sharded path below has always checked it; the
  # shard path was written as if counting the recipes were the same as judging
  # them, which is the exact conflation the count-vs-declared check further down
  # exists to prevent.
  #
  # It was found by running breakage 101, which had been unreachable: it sat
  # BELOW this block, so no shard ever claimed it and the suite counted it as
  # declared. Moving it above the summary is what exposed the missing check —
  # one unreachable recipe hid a red exit code for every other recipe too.
  if [ "$failures" -ne 0 ]; then
    echo "FAIL: self_test — shard $_shard_i/$_shard_n ran $_shard_ran of $total breakages and $failures of them did NOT hold."
    echo "       The FAIL lines above name them. This shard is RED: a proof that"
    echo "       failed is not a proof, and 'every one it ran held' would be the"
    echo "       one sentence here that is untrue."
    echo "       Skipped for a missing toolchain: $skips"
    exit 1
  fi
  echo "PASS: self_test — shard $_shard_i/$_shard_n ran $_shard_ran of $total breakages and every one it ran held."
  echo "       This is a SHARD. It has NOT evaluated the other $((total - _shard_ran)) breakage(s); run the rest to claim the suite."
  exit 0
fi

counted=$(grep -cE '^ *expect_red(_check|_lang|_script)? +.breakage +[0-9]+[a-z]*:' "$0" || true)
total=$(grep -cE '^ *expect_(red|green)(_check|_lang|_script)? +.breakage +[0-9]+[a-z]*:|^ *expect_skip_check +.breakage +[0-9]+[a-z]*:' "$0" || true)
green_check=$(grep -cE '^ *expect_green_check +.breakage +[0-9]+[a-z]*:' "$0" || true)

# `total` and `_shard_ran` COUNTED DIFFERENT THINGS, and the check that compares
# them was therefore red on a tree where every proof ran.
#
# `total` greps for labels of the form `breakage N:`, so it counted 93. But the
# one helper whose label is NOT of that form is `expect_green 'unbroken tree'`
# — the CONTROL, the assertion that an unmutated tree is green. It is a real,
# required evaluation and it increments `_shard_ran` like every other call, so the
# run side read 94. Every proof had been evaluated and the suite still failed,
# naming eleven that never ran.
#
# That is the worst shape this file has: a check that manufactures a shortage
# out of its own counting rule. A reader who believed it would go looking for
# missing proofs that are all present.
#
# So the declaration side counts what the run side counts — every helper
# invocation — and `total` keeps its narrower meaning for the breakdown below,
# which is arithmetic about BREAKAGES and would be thrown off by a control that
# is not one.
declared=$(grep -cE '^ *expect_(red|green|skip)(_check|_lang|_script)? +.' "$0" || true)

# THE CLAIM BELOW IS "EVERY RECIPE WAS EVALUATED", AND UNTIL THIS LINE IT WAS
# NOT CHECKED. It was asserted from the SOURCE — `total` is a `grep` of the
# recipes this file contains — while the number of recipes that actually RAN was
# never compared to it. That is the same false statement the shard guard above
# exists to prevent, one level up: a shard that ran nothing is caught, but a
# FULL run that stopped early is not.
#
# Measured, on this machine, with the disk full:
#
#   $ bash tests/self_test.sh; echo "EXIT=$?"
#   … PASS self_test: breakage 78: the generated deploy.yml is invalid for kamal
#   tests/self_test.sh: line 682: cannot create temp file for here document: No space left on device
#   EXIT=0
#
# EXIT=0. Eighty-nine recipes in the file, the run reached seventy-eight, and the
# shell reported success — because `cp` failing inside the suite is not the suite
# failing, and nothing between the first recipe and this summary noticed. The
# eleven unevaluated breakages included the one added for the multi-tenant split,
# so the run that was supposed to prove that fix proved nothing about it.
#
# A suite whose failure mode is "stops early and says PASS" is worse than no
# suite, because it is believed. So the count of recipes that RAN is now compared
# against the count that EXIST, and a shortfall is a failure in its own right —
# named as a shortfall, because "the suite failed" would send somebody looking for
# a broken check instead of at the eleven proofs that never ran.
if [ "$_shard_ran" -ne "$declared" ]; then
  echo "FAIL: self_test — the file declares $declared evaluation(s) but only $_shard_ran were EVALUATED."
  echo "       $((declared - _shard_ran)) recipe(s) never ran. A suite that stops early and"
  echo "       reports success is worse than no suite, because it is believed."
  echo "       Look for an environment failure ABOVE this line (a full disk, a missing"
  echo "       tool, a deleted worktree) rather than for a broken check: the checks that"
  echo "       would have reported a defect are among the ones that never ran."
  echo "       Skipped for a missing toolchain: $skips"
  exit 1
fi

echo "PASS: self_test — all $total breakages hold ($counted assert red, $((total - counted - green_check)) assert a green gate with a named skip, $green_check assert a green gate with a named finding), and the unbroken tree is green."
echo "       Every recipe above was EVALUATED — $_shard_ran ran against $declared declared ($total breakages and the unbroken-tree control), and the two are compared rather than assumed: 0 environment failures, 0 skipped for a missing toolchain."

