#!/usr/bin/env bash
#
# kit — the provenance stamp's own proof. Three things, in the order they fail.
#
#   A. THE GRAMMAR. Every shape that could leak into a registry-stamped label is
#      REFUSED, by shape, and the refusal names the field and the rule. This is
#      the redaction half of P3-18 and it is the part people skip.
#   B. THE THREE AGREE. The field list, the OCI label keys and the JSON the file
#      sink writes are ONE fact stated in three places. This reads all three and
#      fails when they disagree -- and it needs no docker, because it is a
#      comparison of what the scripts EMIT, not of an image.
#   C. THE BUILD. A real image, built from a real Dockerfile, with both sinks
#      compared and the consumer check required to go red on a wrong commit.
#      SKIPs loudly without docker, per the rule that a check which ran nothing
#      is not a pass.
#
# WHY NO DOCKER IN (A) AND (B). They are the security claims, and a security
# claim that is only executed where docker happens to be installed is a claim
# whose coverage depends on the machine. Both are pure text in, pure exit status
# out.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STAMP="$ROOT/docker/provenance.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/kit-provenance-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

_pass=0
_fail=0
_skip=0

pass() { _pass=$((_pass + 1)); printf 'PASS %s\n' "$1"; }
fail() { _fail=$((_fail + 1)); printf 'FAIL %s\n' "$1"; }
skip() { _skip=$((_skip + 1)); printf 'SKIP %s\n' "$1"; }

# `contains` — a shell `case` over a string already in memory, NEVER a pipe.
# `printf '%s\n' "$out" | grep -q` closes the pipe on its first match, `printf`
# dies of SIGPIPE, and `set -o pipefail` promotes 141 to the pipeline's status,
# so the verdict flips on the SIZE of the output rather than on what is in it.
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# stamp <field> <value> — validate one field in isolation, print its output.
stamp() {
  env -u KIT_PROVENANCE_SOURCE -u KIT_PROVENANCE_REVISION -u KIT_PROVENANCE_BUILT_AT \
    -u KIT_PROVENANCE_SOURCE_DIRTY -u KIT_PROVENANCE_TEMPLATE_VERSION \
    "KIT_PROVENANCE_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')=$2" \
    sh "$STAMP" --validate 2>&1
}

# --- A. the grammar ----------------------------------------------------------
#
# A GOOD stamp, so every refusal below is measured against a control that is
# green. Without it a suite where --validate is broken entirely and refuses
# everything would pass every refusal case.
GOOD_REV=0123456789abcdef0123456789abcdef01234567

control_out="$(stamp revision "$GOOD_REV")"
if [ $? -eq 0 ] && ! contains "$control_out" refusing; then
  pass "control: a 40-hex revision is accepted, so the refusals below mean something"
else
  fail "control: a 40-hex revision was NOT accepted: $control_out"
fi

# REFUSALS. Each is `field value why`. The value is the leak shape; the third
# column is what the fleet would learn if it reached the registry.
#
# The shape that CANNOT be refused is a branch name in `source` — `owner/branch`
# is shape-identical to `owner/repo` — and there is a case for it below, named
# as a case rather than hidden.
refuse() {
  local field="$1" value="$2" why="$3" out ec
  out="$(stamp "$field" "$value")"
  ec=$?
  if [ "$ec" -eq 0 ]; then
    fail "redaction: $field=$value was STAMPED — $why"
    return
  fi
  if ! contains "$out" "refusing to stamp $field"; then
    fail "redaction: $field=$value was refused but not by name (got: $out) — $why"
    return
  fi
  pass "redaction: $field=$value refused ($why)"
}

# A developer's email. Nothing in the grammar set admits '@'.
refuse source 'kaka@cafaye.com' 'a developer identity, and an email-shaped string'
# An absolute local path. Six segments and a leading slash; `source` has a budget
# of exactly ONE slash.
refuse source '/Users/kaka/Code/any/moon' 'a local working directory'
# An internal hostname with a port. `source` carries NO host at all.
refuse source 'pg.corp.internal:5432' 'an internal hostname'
# A full URL. Two slashes over budget, and a scheme the field does not admit.
refuse source 'https://github.corp/cafaye/identity' 'a URL, so a host we do not control'
# A relative path.
refuse source '../cafaye/identity' 'a relative path'
# A credential. Not hex-40, and not two clean segments.
refuse revision 'ghp_16C7aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 'a credential in the revision field'
# A branch in the REVISION field — refused, unlike in `source`.
refuse revision 'worker/kit-provenance-01' 'a branch name where a commit is claimed'
# A short sha. 7 hex is what git prints by default and it is not enough to
# identify a commit 2^33 commits later.
refuse revision '0123456' 'a short sha, which git prints by default'
# Uppercase hex. A stamp that varies in case for one commit is a stamp two
# consumers can disagree about.
refuse revision '0123456789ABCDEF0123456789ABCDEF01234567' 'uppercase hex, which two consumers would spell differently'
# An email in the timestamp field.
refuse built_at 'kaka@cafaye.com' 'a developer identity in the timestamp field'
# A local-time timestamp with a zone offset: ambiguous in a label nobody parses
# carefully, and `date -u` is one flag.
refuse built_at '2026-10-03 09:20:00+01:00' 'a non-RFC3339, zone-offset timestamp'
# The dirty FILE LIST. The field is a flag and the grammar admits no path.
refuse source_dirty 'modified: go/cmd/service/main.go' 'a dirty file list, which is a local path'
# A dirty flag spelled freely.
refuse source_dirty 'yes' 'a boolean spelled freely rather than clean/dirty'
# An unversioned template version.
refuse template_version '0.1.0' 'a template version with no v prefix'

# THE SHAPE THAT CANNOT BE REFUSED, asserted rather than omitted.
#
# `owner/branch` is shape-identical to `owner/repo`, so no grammar separates
# them and pretending one would is the kind of claim that reads as coverage and
# is not. The suite therefore ASSERTS THE HONEST ANSWER: it is accepted as a
# source, and it is not a leak — the registry already publishes that exact string
# as a tag, to exactly the population that can read the stamp.
stamp source 'worker/kit-provenance-01' >/dev/null 2>&1
if [ $? -eq 0 ]; then
  pass "the asymmetry, asserted: a branch-shaped source is accepted, because no grammar can tell it from owner/repo and the registry publishes it as a tag anyway"
else
  fail "the asymmetry: a branch-shaped source was refused — if this ever becomes true the header in docker/provenance.sh is WRONG and must be rewritten, not the grammar"
fi

# AN EMPTY VALUE IS `unknown`, NOT A STAMP AND NOT A REFUSAL.
#
# A developer's local `docker build` passes nothing and must not be refused for
# it. That leniency is real and it is bounded by the next two cases.
unset_out="$(env -u KIT_PROVENANCE_SOURCE -u KIT_PROVENANCE_REVISION -u KIT_PROVENANCE_BUILT_AT \
  -u KIT_PROVENANCE_SOURCE_DIRTY -u KIT_PROVENANCE_TEMPLATE_VERSION \
  sh "$STAMP" --validate 2>&1)"
if [ $? -eq 0 ]; then
  pass "an unstamped local build is accepted (every field falls back to unknown)"
else
  fail "an unstamped local build was REFUSED: $unset_out"
fi

# --- B. the three agree ------------------------------------------------------
#
# ONE FACT, THREE PLACES. `FIELDS` in the script, the LABEL keys in seven
# Dockerfiles, and the JSON keys `--write` emits. A reader who needs to know
# what a label is called has three places to look and this is what stops them
# from disagreeing — the "assert the AGREEMENT, not the presence of a file"
# rule, applied to the stamp.
#
# It needs no docker because it compares what the scripts EMIT.

# The OCI label keys, written out here rather than read out of a Dockerfile, so
# that a Dockerfile which lost one of them is a finding and not a new normal.

# --write's JSON keys, read out of a real write rather than out of the source.
expected_labels='org.opencontainers.image.source
org.opencontainers.image.revision
org.opencontainers.image.created
com.cafaye.kit.source.dirty
com.cafaye.kit.template.version'

env -u KIT_PROVENANCE_SOURCE -u KIT_PROVENANCE_REVISION -u KIT_PROVENANCE_BUILT_AT \
  -u KIT_PROVENANCE_SOURCE_DIRTY -u KIT_PROVENANCE_TEMPLATE_VERSION \
  sh "$STAMP" --write "$TMP/probe.json" >/dev/null 2>&1
written_keys="$(sed -n 's/^  "\([a-z_]*\)":.*/\1/p' "$TMP/probe.json" | sort | tr '\n' ' ')"

expected_keys='built_at revision source source_dirty template_version '
if [ "$written_keys" = "$expected_keys" ]; then
  pass "the file sink writes exactly the five fields, and nothing else"
else
  fail "the file sink wrote [$written_keys], expected [$expected_keys]"
fi

langs='bun elixir go node python ruby rust'
for lang in $langs; do
  df="$ROOT/docker/Dockerfile.$lang"
  if [ ! -f "$df" ]; then
    fail "agreement: $df does not exist"
    continue
  fi
  # `grep -oE`, not `sed`. Two failures were in this line before it worked, and
  # both are worth recording because both read as "every Dockerfile is broken":
  #   - a pattern anchored at the start of the line sees only the FOUR
  #     continuation lines, because the FIRST key sits after the `LABEL `
  #     keyword. It reported five missing and the Dockerfiles were fine.
  #   - BSD sed has no `\|` alternation, so the alternation matched NOTHING at
  #     all and every language failed identically. Identical failures across
  #     seven inputs is the signature of the CHECK being wrong, not the tree.
  # Comment lines are stripped first, per the same rule `strip_shell_comments`
  # exists for: a comment that NAMES a label key is documentation, not a label.
  got="$(grep -v '^[[:space:]]*#' "$df" |
    grep -oE '(org\.opencontainers\.image\.[a-z]+|com\.cafaye\.kit\.[a-z.]+)=' |
    sed 's/=$//' | sort -u | tr '\n' ' ')"
  want="$(printf '%s\n' "$expected_labels" | sort | tr '\n' ' ')"
  if [ "$got" != "$want" ]; then
    fail "agreement: Dockerfile.$lang labels [$got] != the script's [$want]"
    continue
  fi
  # Every label must be fed by an ARG of the matching name, or it expands to
  # empty — and an empty label is a stamp that is present and says nothing.
  missing=''
  for key in org.opencontainers.image.source org.opencontainers.image.revision \
    org.opencontainers.image.created com.cafaye.kit.source.dirty \
    com.cafaye.kit.template.version; do
    case "$key" in
      org.opencontainers.image.source) arg='KIT_PROVENANCE_SOURCE' ;;
      org.opencontainers.image.revision) arg='KIT_PROVENANCE_REVISION' ;;
      org.opencontainers.image.created) arg='KIT_PROVENANCE_BUILT_AT' ;;
      com.cafaye.kit.source.dirty) arg='KIT_PROVENANCE_SOURCE_DIRTY' ;;
      com.cafaye.kit.template.version) arg='KIT_PROVENANCE_TEMPLATE_VERSION' ;;
    esac
    grep -q "^ARG $arg=" "$df" || missing="$missing $arg"
  done
  if [ -n "$missing" ]; then
    fail "agreement: Dockerfile.$lang has label(s) with no ARG:$missing — they would expand to empty"
  else
    pass "agreement: Dockerfile.$lang declares all five labels and all five ARGs"
  fi
done

# The Dockerfiles must STAMP, not merely declare: a template that lists the
# ARGs and forgets the LABEL ships an image whose provenance is a file nothing
# outside the container can read.
for lang in $langs; do
  df="$ROOT/docker/Dockerfile.$lang"
  grep -q '^LABEL org.opencontainers.image.source=' "$df" ||
    fail "stamp: Dockerfile.$lang declares the provenance ARGs but no LABEL"
  grep -q 'provenance.sh --write' "$df" ||
    fail "stamp: Dockerfile.$lang writes no provenance file"
done
pass "stamp: all seven Dockerfiles write both sinks (per-language findings above, if any)"

# --- C. the build ------------------------------------------------------------
#
# The only part that needs docker, and the only part that can prove the CONSUMER
# side. It builds a real image from the real Dockerfile and requires the check
# to go red on a wrong commit — a check that has only ever been seen green is a
# check nobody knows can fail.

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  skip "build: no docker, so the two sinks were not compared on a real image and --verify was not exercised"
else
  GO=0123456789abcdef0123456789abcdef01234567
  # The IMAGE TAGS are names in a shared namespace too, and they were two
  # literals for the whole life of this file. An image tag is namespaced by
  # nothing: `docker rmi -f NAME` at the bottom of this block takes a bare
  # name and will delete an image a concurrent run is still asserting
  # against, and `docker build -t NAME` writes over it. Two runs of this
  # suite on one machine therefore shared both tags, and one run's teardown
  # is what makes the other run's `docker image inspect` and `docker create`
  # come back empty - which reads as "the stamp disagrees with itself", the
  # one failure this section exists to rule out. The pid makes them ours.
  GOOD_IMAGE="kit-provenance-test-$$:good"
  PLAIN_IMAGE="kit-provenance-test-$$:plain"
  BAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  fixture="$TMP/svc"
  mkdir -p "$fixture/docker" "$fixture/cmd/service"
  cp "$ROOT/docker/Dockerfile.go" "$ROOT/docker/entrypoint.sh" "$ROOT/docker/provenance.sh" "$fixture/docker/"
  printf 'module svc\n\ngo 1.24\n' >"$fixture/go.mod"
  : >"$fixture/go.sum"
  printf 'package main\n\nfunc main() {}\n' >"$fixture/cmd/service/main.go"

  # `-f` gets an ABSOLUTE path: `docker build -f docker/Dockerfile` resolved
  # against something other than the context and read a 2-byte file on this box.
  if docker build -q -f "$fixture/docker/Dockerfile.go" -t "$GOOD_IMAGE" \
    --build-arg KIT_PROVENANCE_SOURCE=cafaye/identity \
    --build-arg KIT_PROVENANCE_REVISION="$GO" \
    --build-arg KIT_PROVENANCE_BUILT_AT=2026-10-03T09:20:00Z \
    --build-arg KIT_PROVENANCE_SOURCE_DIRTY=clean \
    --build-arg KIT_PROVENANCE_TEMPLATE_VERSION=v0.1.0 \
    "$fixture" >/dev/null 2>&1; then
    pass "build: a real image built from docker/Dockerfile.go with all five build args"
  else
    fail "build: docker/Dockerfile.go did not build with the provenance block in it"
    printf '\n%d passed, %d failed, %d skipped\n' "$_pass" "$_fail" "$_skip"
    exit 1
  fi

  # THE TWO SINKS MUST AGREE. A stamp that disagrees with itself is worse than no
  # stamp, because a reader trusts whichever one they happened to look at.
  l_rev="$(docker image inspect "$GOOD_IMAGE" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null)"
  cid="$(docker create "$GOOD_IMAGE" 2>/dev/null)"
  f_rev=""
  if [ -n "$cid" ]; then
    f_rev="$(docker cp "$cid:/app/kit-provenance.json" - 2>/dev/null | tar -xO kit-provenance.json 2>/dev/null |
      sed -n 's/.*"revision": "\([^"]*\)".*/\1/p')"
    docker rm -f "$cid" >/dev/null 2>&1
  fi
  if [ -n "$l_rev" ] && [ "$l_rev" = "$f_rev" ] && [ "$l_rev" = "$GO" ]; then
    pass "sinks: the label and the file name the same commit on a real image"
  else
    fail "sinks: label=[$l_rev] file=[$f_rev] expected=[$GO] — a stamp that disagrees with itself is worse than none"
  fi

  # THE RED PROOFS. Three different exit codes, and each one is asserted
  # separately because a check that returns the same code for "wrong commit" and
  # for "no labels" cannot tell a consumer which of the two happened.
  sh "$STAMP" --verify "$GOOD_IMAGE" --expect-revision "$GO" >/dev/null 2>&1
  [ $? -eq 0 ] && pass "verify: the expected commit exits 0" || fail "verify: the expected commit did NOT exit 0"

  red="$(sh "$STAMP" --verify "$GOOD_IMAGE" --expect-revision "$BAD" 2>&1)"
  ec=$?
  if [ "$ec" -ne 0 ] && contains "$red" "$BAD"; then
    pass "verify: a WRONG commit exits $ec and names both commits — this is the check being able to fail"
  else
    fail "verify: a wrong commit exited $ec (want non-zero) with [$red]"
  fi

  # An unstamped image. Built from a Dockerfile with no block, so this is a real
  # pre-stamp image rather than a missing one.
  printf 'FROM debian:12-slim\nCMD ["true"]\n' >"$TMP/plain.Dockerfile"
  docker build -q -f "$TMP/plain.Dockerfile" -t "$PLAIN_IMAGE" "$TMP" >/dev/null 2>&1
  red2="$(sh "$STAMP" --verify "$PLAIN_IMAGE" 2>&1)"
  ec2=$?
  if [ "$ec2" -ne 0 ] && contains "$red2" "no labels"; then
    pass "verify: an image with no stamp exits $ec2 and says so — distinct from the wrong-commit answer"
  else
    fail "verify: an unstamped image exited $ec2 with [$red2]"
  fi

  # The leniency boundary: `unknown` must fail an ASSERTION even though it is
  # accepted at build time. That asymmetry is the design.
  red3="$(sh "$STAMP" --verify "$GOOD_IMAGE" --expect-revision unknown 2>&1)"
  ec3=$?
  if [ "$ec3" -ne 0 ] && contains "$red3" "unknown"; then
    pass "verify: an image stamped unknown FAILS an assertion — unstamped is fine to create and not fine to assert about"
  else
    fail "verify: asserting `unknown` exited $ec3 with [$red3]"
  fi

  docker rmi -f "$GOOD_IMAGE" "$PLAIN_IMAGE" >/dev/null 2>&1
fi

# --- D. the consumer side, WITHOUT docker -------------------------------------
#
# The defect this part exists for: `--verify` printed `oven-sh/bun`'s
# `org.opencontainers.image.source` as our provenance and exited 0, and the
# suite above could not see it, because every `--verify` case in part C is a
# case about an image kit's own Dockerfile built -- and a foreign base image's
# labels are precisely the labels kit's Dockerfile did NOT write.
#
# So the LABEL SINK IS STUBBED. A `docker` on PATH that answers
# `image inspect` with a canned JSON and nothing else, which makes the whole
# consumer side -- shape, ownership, absent-field policy, exit-code separation --
# executable as pure text in and exit status out, with no daemon and no build.
# That is the same rule part A and part B are under, applied to the half that
# had no coverage at all: a security claim whose coverage depends on whether
# docker happens to be installed is a claim about the machine.
#
# It is ALSO the control for part C. Part C proves the checks fire on a real
# image; this proves they fire on labels kit would never have written, which is
# the case part C structurally cannot produce.

STUB="$TMP/stubbin"
mkdir -p "$STUB"
cat >"$STUB/docker" <<'STUBEOF'
#!/bin/sh
# The stub. `$1` is always `image` here; anything else is not this suite's call.
[ "${1:-}" = 'image' ] || { printf 'stub: unhandled docker %s\n' "$1" >&2; exit 127; }
case "$3" in
  null) printf 'null\n'; exit 0 ;;
  inherit)
    # EXACTLY what `cafaye/gateway:e2e` carries: an image built FROM oven/bun,
    # measured from the real image on the machine that wrote this suite.
    printf '%s\n' '{"org.opencontainers.image.created":"2026-04-10T03:06:38.682Z","org.opencontainers.image.revision":"700fc117a2fd01ac0201deaa6fa69c5557acb04f","org.opencontainers.image.source":"https://github.com/oven-sh/bun"}'
    exit 0 ;;
  inheritshape)
    # THE FIXTURE THAT MAKES THE OWNERSHIP CHECK PROVABLE, and it exists because
    # the first version of this suite got it wrong in the exact way this
    # repository's header warns about. `inherit` above is refused by the SHAPE
    # check — its source is a URL — so it never reaches the namespace check, and
    # deleting the namespace check left this suite GREEN. A control satisfiable
    # by two different checks proves the gate can go red and says nothing about
    # either; breakage 103 was unprovable against `inherit` and green on the
    # mutation it names.
    #
    # So this one is a base image that stamps its OCI labels in kit's OWN
    # grammar: `owner/repo`, 40 hex, RFC3339 to the second, and nothing in
    # `com.cafaye.kit.*`. Every field PASSES shape. The one thing wrong with it
    # is that nobody in kit wrote it, and only the namespace check can say so.
    # Real publishers do this: the grammar kit chose is the grammar these labels
    # use when they are not a URL, which is precisely why shape cannot be the
    # thing that catches them.
    printf '%s\n' '{"org.opencontainers.image.created":"2026-10-03T09:20:00Z","org.opencontainers.image.revision":"0123456789abcdef0123456789abcdef01234567","org.opencontainers.image.source":"oven-sh/bun"}'
    exit 0 ;;
  ours) printf '%s\n' '{"com.cafaye.kit.source.dirty":"clean","com.cafaye.kit.template.version":"v0.1.0","org.opencontainers.image.created":"2026-10-03T09:20:00Z","org.opencontainers.image.revision":"0123456789abcdef0123456789abcdef01234567","org.opencontainers.image.source":"cafaye/gateway"}'
    exit 0 ;;
  foreign) printf '%s\n' '{"com.cafaye.kit.source.dirty":"clean","com.cafaye.kit.template.version":"v0.1.0","org.opencontainers.image.created":"2026-10-03T09:20:00Z","org.opencontainers.image.revision":"0123456789abcdef0123456789abcdef01234567","org.opencontainers.image.source":"oven-sh/bun"}'
    exit 0 ;;
  badshape) printf '%s\n' '{"com.cafaye.kit.source.dirty":"clean","com.cafaye.kit.template.version":"v0.1.0","org.opencontainers.image.created":"2026-10-03T09:20:00Z","org.opencontainers.image.revision":"0123456789abcdef0123456789abcdef01234567","org.opencontainers.image.source":"https://github.com/cafaye/gateway"}'
    exit 0 ;;
  *) printf 'stub: unhandled fixture %s\n' "$3" >&2; exit 127 ;;
esac
STUBEOF
chmod +x "$STUB/docker"

# stub_verify <fixture> [flags...] — the OUTPUT of --verify against a canned
# label set, and the exit code in `VERIFY_EC`. A global rather than an echo of
# `$(...)`, because `ec=$?` after an assignment reads the ASSIGNMENT's status,
# not the command's — which is the same class of bug as reading the gate's
# output through a pipe: the harness asks the wrong question and reports a
# confident answer.
VERIFY_EC=0
stub_verify() {
  _fx="$1"; shift
  STUB_OUT="$(PATH="$STUB:$PATH" sh "$STAMP" --verify "$_fx" "$@" 2>&1)"; VERIFY_EC=$?
}

# verify_exits <want-ec> <label> <fixture> [flags...] — a SPECIFIC code, and
# the words. A check that only asked "!= 0" could not tell "no labels" from
# "someone else's labels", which is the distinction exit 4 exists for.
verify_exits() {
  local want="$1" label="$2" fixture="$3"
  shift 3
  stub_verify "$fixture" "$@"
  if [ "$VERIFY_EC" -ne "$want" ]; then
    fail "verify/$label: exited $VERIFY_EC, want $want — [$STUB_OUT]"
    return
  fi
  pass "verify/$label: exits $want"
}

# verify_says <needle> <label> <fixture> [flags...] — exit code AND the words,
# at the code the previous case established. `contains`, never a pipe: see the
# note at the top of this file. The exit code is a PARAMETER because one of the
# cases below asserts a warning at exit 0, and a helper that hardcoded
# "non-zero" would have made the most important warning in this packet
# unassertable — which is how a warning becomes decorative.
verify_says() {
  local needle="$1" label="$2" want="$3" fixture="$4"
  shift 4
  stub_verify "$fixture" "$@"
  if [ "$VERIFY_EC" -ne "$want" ]; then
    fail "verify/$label: exited $VERIFY_EC, want $want — [$STUB_OUT]"
    return
  fi
  if ! contains "$STUB_OUT" "$needle"; then
    fail "verify/$label: exited $want but the message never said \"$needle\" — [$STUB_OUT]"
    return
  fi
  pass "verify/$label: exits $want and names \"$needle\""
}

# THE WITNESS. `inherit` is the real `cafaye/gateway:e2e` label set, byte for byte
# off the image on the machine that wrote this suite, and it is the one case
# that was green before this packet's fix.
verify_exits 6 'D1 inherited base-image labels are refused with NO flags at all' inherit
verify_says 'oven-sh/bun' 'D1b the refusal NAMES Bun rather than us' 6 inherit
verify_exits 6 'D2 inherited labels are refused even asserting our own repo' inherit --expect-source cafaye/gateway

# THE CASE THAT ONLY OWNERSHIP CAN SEE, and the one that makes breakage 103
# provable. Every field here passes the shape grammar — `owner/repo`, 40 hex,
# RFC3339 to the second — and there is nothing in `com.cafaye.kit.*`. So the
# shape loop finds nothing to complain about and the namespace check is the ONLY
# thing that can refuse it.
#
# This pair is a CONTROL and its own control, and both directions are asserted
# because only one of them being true would leave the check unproven:
#   - D2a: it is refused with no flags at all (the check fires);
#   - D2b: it is refused WITHOUT --expect-source (so the refusal is not the
#     warning, and not the flag doing the work).
verify_exits 6 'D2a a stamp in kit'"'"'s own grammar but with NO kit namespace is refused' inheritshape
verify_says 'BASE' 'D2b and the refusal is the NAMESPACE one, not shape and not the warning' 6 inheritshape

# A FOREIGN BUT WELL-FORMED source: `oven-sh/bun` is two clean lowercase
# segments with exactly one slash, so it passes every grammar in the file. This
# is the case shape cannot see and the reason `--expect-source` exists.
verify_exits 5 'D3 a well-formed FOREIGN source fails --expect-source' foreign --expect-source cafaye/gateway
# THE OVERRULE, asserted rather than asserted-against: no `--expect-source` is a
# loud WARNING at exit 0, and the warning says in words that ownership was not
# established. If a successor hardens this to a failure, D4 goes red and the
# CHANGELOG has to say so — which is the point of writing the decision down here
# as well as in the script's header.
verify_says 'OWNERSHIP OF THE REPOSITORY WAS NOT ESTABLISHED' 'D4 no --expect-source warns at exit 0' 0 foreign
verify_says 'unknown was expected' 'D5 asserting `unknown` fails and names the expectation' 5 ours --expect-source unknown

# SHAPE, on the consumer side, with nothing else wrong: the stamp is in kit's
# own namespace and asserts the right repository, and the source is a URL — over
# the one-slash budget, with a scheme, a host and a port. The authoring path
# already refuses it; this asserts the VERIFY path does too.
verify_exits 6 'D6 a source violating the shape grammar fails on shape' badshape --expect-source cafaye/gateway
verify_says 'it must be owner/repo' 'D7 and the failure carries the expect_* line' 6 badshape --expect-source cafaye/gateway

# A correct stamp with a matching expectation exits 0. Without this control a
# verifier that refused everything would pass every refusal above.
verify_exits 0 'D8 a correct stamp with matching --expect-source and --expect-revision' ours --expect-source cafaye/gateway --expect-revision 0123456789abcdef0123456789abcdef01234567
verify_says 'no labels at all' 'D9 an image with NO labels still exits 4, not 6' 4 null

# `--expect-source` is a stamp value, so it is checked against the source
# grammar before it judges anything: a caller who writes a URL as the
# expectation must be refused, not told their correctly stamped image is wrong.
bad_expect="$(PATH="$STUB:$PATH" sh "$STAMP" --verify ours --expect-source 'https://github.com/cafaye/kit' 2>&1)"
bad_expect_ec=$?
if [ "$bad_expect_ec" -ne 0 ] && contains "$bad_expect" 'refusing to ASSERT source'; then
  pass "verify/D10 --expect-source is itself grammar-checked, so a URL expectation is refused rather than reported as a mismatch"
else
  fail "verify/D10 --expect-source https://… exited $bad_expect_ec with [$bad_expect]"
fi

# THE ABSENT-FIELD POLICY is a DECISION, so it is asserted in the direction that
# matters most: a stamp with every field present must print NO absent note, or
# the note has stopped carrying information. The other direction — an absent
# identity field is a refusal and an absent metadata field is a note — is what
# D1, D2 and the `cafaye/e2e-parlor:local` measurement cover.
stub_verify ours --expect-source cafaye/gateway
if contains "$STUB_OUT" '<absent>'; then
  fail "verify/D11 a fully stamped image reported an absent field: [$STUB_OUT]"
elif contains "$STUB_OUT" 'note:'; then
  fail "verify/D11 a fully stamped image printed an absent-field note: [$STUB_OUT]"
else
  pass "verify/D11 a fully stamped image notes nothing as absent, so the note still carries information"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$_pass" "$_fail" "$_skip"
[ "$_fail" -eq 0 ]