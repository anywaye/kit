# Migrations

kit is adopted by **calling** `.github/workflows/ci.reusable.yml@master` and by
**copying** files out of `docker/` and `templates/`. So a version number only
means something if a consumer who took the bytes can find out what to do about
them, and this file is what `tests/validate.sh` requires a MAJOR to owe. Read
the diff is what the version number is supposed to replace.

Each section is one MAJOR, and each says what a consumer must change — not what
changed, which the changelog already says.

## 2.0.0

**The bump is because `docker/provenance.sh --verify` now FAILS on images it
used to accept.** A consumer who copied the script into a service repository
gets a red result on an image that previously verified clean. Nothing about the
labels changed; the verifier now has an opinion about them.

### What a consumer has to do

**If you copied `docker/provenance.sh`, copy it again.** The old copy will keep
printing a third party's provenance as yours and keep exiting 0. There is no
way to get this fix any other way — kit is adopted by copy, so an old copy is
an old verifier.

`parlor` and `site` each carry a copy and are mid-packet with the consumer
wiring; that copy is tracked in `HANDOFF-provenance-ownership-01` rather than
done here, because kit cannot commit to those repositories.

### What to expect to go red, and what each answer means

`org.opencontainers.image.*` are **standard OCI labels that every published base
image sets**, so an image built `FROM` a stamped one inherits them whether or
not anybody stamped it. The four verdicts are distinct and none of them is 0 by
accident:

| exit | meaning | what changed |
| --- | --- | --- |
| **0** | well-shaped, ours, and every expectation given was met | unchanged |
| **4** | the image carries **no labels at all** | unchanged, and load-bearing |
| **5** | an expectation **you gave** was not met | `--expect-source` is new and lands here |
| **6** | labels present, and they are **not a valid anywaye stamp** | **new** |

**4 and 6 are not collapsed and must not be.** A caller testing `== 4` still
means *this image predates the stamp*; a caller testing `!= 0` is unaffected. A
caller that treats every non-zero as "unverifiable" now correctly includes the
inherited-stamp case, which is the case it was blind to.

If `--verify` goes red, it is one of three real things and not a false alarm:

1. the image was built `FROM` something already stamped and inherits its
   labels — make the Dockerfile emit all five, which every
   `docker/Dockerfile.<lang>` in kit already does;
2. the image predates the stamp — that is exit **4**, and it means the tag is
   *old*, not *untrustworthy*;
3. a base image sets `org.opencontainers.image.source` to a URL. Real: Bun's
   publisher does exactly that, and Bun's `created` carries **milliseconds**
   where the grammar requires RFC3339 to the second, so both of those fields
   fail shape.

### Adopting without changing anything

The printing form still exits 0 on a correctly stamped image, so
`provenance.sh --verify IMG || true` — the form kit's own handoff tells services
to use — is unaffected. What is new is that the **default is no longer silent**:
an inherited stamp fails with no flag at all.

Add `--expect-source owner/repo` to assert the repository too. A *well-formed*
foreign source (two clean segments, exactly one slash — `oven-sh/bun`) passes
every grammar in the file, so the repository assertion is the only thing that
catches it, and a mismatch is exit **5**.

**An absent `--expect-source` is a loud warning, not a failure.** That is a
deliberate decision and it is recorded here because a consumer who disagrees
should be able to see it was a choice: a mandatory failure there would make
every printing-form caller print a FAIL on a good image and continue, which
teaches a reader the line is noise. The namespace check still fails the run
with no flag at all.