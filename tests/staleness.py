#!/usr/bin/env python3
"""Report how far each vendored copy of `core` has fallen behind.

    staleness.py --repos-dir ../ --manifest core/fleet.yml
    staleness.py --repos-dir ../ --repo muse --repo caf
    staleness.py --repos-dir ../ --github-org cafaye

WHAT IT IS FOR

  Every consuming repository records which commit of `core` it vendored. That
  record is a claim, and a claim nobody checks is a rumour — the same argument
  `cafaye-ts/specs/index.json` already makes in its own `about` field. This
  script reads those records, resolves where `core`'s default branch is *now*,
  and prints the distance between the two.

  It exists because the fleet's staleness is otherwise visible only as a red
  build in whichever repository happened to be built, which is the reporting
  half of a problem that needs the fixing half. vendir + Renovate is the fixing
  half (see `core/README.md`); this is how you see the backlog before a PR
  exists to fix it.

THE HARD PART, STATED HONESTLY

  Not the comparison — a sha and a sha is a subtraction. The hard part is
  *discovery*: knowing which repositories consume core, and where each one
  records its pin. Three sources, in the order they are tried:

    1. `--repos-dir`  — every immediate subdirectory that looks like a checkout.
       Works offline, works with a partial clone, and is what you use in a test.
    2. `--repo`       — named repositories, resolved under `--repos-dir`.
    3. `--github-org` — enumerate an organisation through the GitHub API.

  A repository that records its pin in a form this script does not recognise is
  reported as `unknown`, never as `current`. That distinction is the whole
  difference between this being a staleness report and this being a report that
  says everything is fine.

THE PIN, AND WHY THE OLD ONE STILL MATTERS

  A repository can record its core pin two ways, and during the migration it is
  usually both at once:

    * `vendir.lock.yml` — a resolved `sha` under a git content entry. This is
      what vendir writes and what Renovate updates.
    * a `CORE_REF` in `.github/workflows/*.yml` — a full sha in an env block.
      This is the hand-bumped form, and it is still what three repositories use
      today. A migration that only learned to read lockfiles would report all
      three as `unknown` on the day it landed, which is the worst possible moment
      to stop being able to see them.

EXIT STATUS

  0  the table was produced
  1  a repository named on the command line could not be read, or a
     --fail-on-* flag fired
  2  bad invocation

  Deliberately NOT non-zero for "something is stale". A scheduled report that
  exits 1 every week is a scheduled report that gets muted, and the whole reason
  this is an artifact rather than a blocking check is that a stale copy is
  legal — it is a copy that has not been bumped yet. What must be loud is
  *unreadable*, because an unreadable pin is a pin nobody is maintaining.

THE TEMPLATES SCOPE, AND WHY IT NEEDED A NEW WORD

  `--scope core` (the default) measures a PIN. `--scope templates` measures a
  FILE, and a file has a state a pin does not have: **it is not there**.

  Run it:

      staleness.py --repos-dir .. --scope templates
      staleness.py --repos-dir .. --scope templates --repo billing
      staleness.py --repos-dir .. --scope templates --json --fail-on-unpinned

  `--fail-on-unpinned` is off by default for the same reason `--fail-on-behind`
  is: a finding nobody has triaged is a backlog, not a defect, and a report
  that is red every week is a report that gets muted. The TABLE always prints
  every finding and the count either way; the flag only decides the exit
  status, which is what makes it usable in a pull request that adopts
  something and useless as a scheduled job.

  Measured on this fleet at `41f8bcb` (nine services, twelve artefacts):
  **9 cells current, 43 diverged, 32 absent, 5 unknown, 19 n/a** — and
  `templates/parity-allowlist` carries all 80 findings, so
  `--fail-on-unpinned` exits 0. The full breakdown is in `README.md`; the
  number that matters most is that **nine of 108 cells are byte-identical to
  kit**, and eight of those nine are the same artefact: the workflow call.

  Adoption happens by copy, so the question "has this drifted?" assumes a copy
  to compare. In the fleet that assumption is false. Measured on
  2026-09-30, of nine services: zero hold `otel-collector.yml`, one holds
  `bin/dev`, and six `docker-compose.yml` files differ from kit's by more than
  four hundred lines each. Those are not drifted copies. They have been
  replaced, and a reporter that only knew `current` and `stale` would have
  nothing to say about any of them — which is the failure this scope exists to
  name.

  So the templates scope reports FOUR states, and the third is the point:

    current   byte-identical to what kit ships, at the declared path
    diverged  present at the declared path, and not byte-identical
    absent    kit ships one and the service holds NOTHING there
    unknown   it could not be measured (see below)
    n/a       this artefact does not apply to this service at all

  `absent` is not a failure by itself and is not silence either. It is a
  finding with a number attached, and the number is printed on every run: an
  absence nobody counts is an absence nobody migrates.

  `n/a` is the fifth state and it exists because it is NOT `unknown`. A `go`
  service has no `lint/rubocop.yml` because it is not a Ruby service, and that
  is a settled fact about the service, not something the reporter failed to
  measure. Reporting it as `unknown` would give every service in the fleet three
  permanent findings that nobody can fix and every finding to be noise. It is
  the one state that never needs a pin, because there is nothing to pin: kit
  makes no claim about a rubocop config in a Go repository.

WHAT `unknown` COVERS, AND WHY IT IS NOT A PASS

  The classifier fails closed — a change it cannot place is the strictest tier,
  not the loosest — and this reporter inherits the rule rather than copying it.
  Four things land in `unknown`, and every one of them is a case where the
  cheap answer would be a guess:

    * the service declares no `language`, so an artefact kit ships per
      language cannot be resolved. Guessing one and reporting the comparison
      is reporting a guess as a measurement.
    * the path is a symlink. A symlink to a byte-identical file has the right
      bytes today and is a bet that the target never moves.
    * the path is not a regular file, or cannot be read.
    * kit no longer ships the artefact, so there is nothing to compare against.

  Each is a finding that requires a pin, exactly like `absent`.

NEVER INFER A PIN FROM CONTENT

  A file that LOOKS like kit's is not evidence that it IS kit's, and the
  reporter never grades resemblance. There is no threshold, no percentage, no
  "closest match", and no search for a file that hashes to kit's artefact. A
  copy is `current` when the bytes at the declared path are equal and the path
  is a real file in the service's own tree, and at no other time. One appended
  byte makes it `diverged`, and `diverged` needs a pin.
"""

from __future__ import annotations

import argparse
import difflib
import glob
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

SHA_RE = re.compile(r"^[0-9a-f]{40}$")

# The states a repository can be in. Ordered worst-last so a sort by this key
# puts the repositories that need attention first.
UNKNOWN = "unknown"
CURRENT = "current"
BEHIND = "behind"
UNDECLARED = "undeclared"

# The templates scope's states. `absent` is the word the reporter did not have,
# and the reason it needed one: with only `current` and `diverged`, an artefact
# kit ships and no service holds has no state at all, and a reporter with no
# state for a thing says nothing about it.
TPL_CURRENT = "current"
TPL_DIVERGED = "diverged"
TPL_ABSENT = "absent"
TPL_UNKNOWN = "unknown"
TPL_NA = "n/a"

# A state that is not `current` is a finding, and a finding needs a pin — with
# ONE exception, `n/a`, where kit makes no claim at all and so there is nothing
# to excuse. This set is the definition of "unproven" in one place, so the
# table, the JSON and the failure report cannot each have their own idea of
# which cells are a problem.
NEEDS_PIN = (TPL_DIVERGED, TPL_ABSENT, TPL_UNKNOWN)


def needs_a_pin(row: dict) -> bool:
    """Does this row require a reason in the parity allowlist?

    The rule is the default one — `diverged`, `absent` and `unknown` all need a
    pin, `current` does not — with ONE exemption, and the exemption is narrower
    than it looks.

    `artifacts.json` has documented an `optional` field since kit-14: "true when
    kit genuinely does not expect universal adoption. Such an artefact is
    reported but does not, by itself, make a service look broken." Nothing
    implemented it, because no artefact in the table used it — a property stated
    in one file and asserted in zero places, which is the exact shape this
    repository's own rules call out. kit-21 added the first `optional`
    artefacts (the per-language connection contract) and the reporter turned
    every one of them into an unpinned finding for every service in the fleet,
    which is the opposite of what the field says.

    It exempts `absent` and ONLY `absent`, and the narrowness is the point:

      * `diverged` — the service HAS the artefact and it is not kit's bytes. A
        field about adoption expectation says nothing about a copy that has
        drifted, and that is the state this whole mechanism exists to catch.
      * `unknown` — the reporter could not measure it. `unknown` inherits the
        fail-closed rule above rather than copying it: an unmeasured optional
        artefact is still an unmeasured one.

    So an optional artefact is reported in the table and contributes no finding.
    It is visible and it is not a pin.
    """
    if row.get("optional") and row["state"] == TPL_ABSENT:
        return False
    return row["state"] in NEEDS_PIN

# Where a pin can hide, in preference order. Lockfile first: it is the form the
# migration moves toward, and a repository that has both is mid-migration and
# its two pins should agree (see `pins_disagree`).
LOCKFILE = "vendir.lock.yml"
WORKFLOW_GLOB = ".github/workflows"


def run_git(args: list[str], cwd: str) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            ["git", *args], cwd=cwd, capture_output=True, text=True, check=False
        )
    except OSError as exc:
        return 127, "", str(exc)
    return proc.returncode, proc.stdout, proc.stderr


def is_checkout(path: str) -> bool:
    return os.path.isdir(os.path.join(path, ".git")) or os.path.isfile(
        os.path.join(path, ".git")
    )


# ===========================================================================
# the templates scope
# ===========================================================================
#
# What kit ships, where a service puts it, and how to tell three states apart.
# The declaration lives in `tests/artifacts.json` — ONE file, read by this
# reporter and by the `parity-allowlist` check in `tests/validate.sh` — because
# a table written down twice is a table that is right in one of the two places.

DEFAULT_TABLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "artifacts.json")
DEFAULT_ALLOWLIST = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "templates", "parity-allowlist"
)

# The ref a caller is documented to use. `@master` is kit's own convention and
# the one its README documents; a caller on any other ref is a caller on a
# different standard, which is a divergence and not a pass.
DOCUMENTED_REF = "master"

# The `uses:` line kit's own README tells a service to write.
#
# ANCHORED, and the anchoring is the whole check. `uses:` must be the first
# token on the line, which excludes three shapes that are all present in this
# fleet and none of which is a call:
#
#   * a `#` comment quoting the line — two of the fleet's callers carry the
#     WRONG path in a comment explaining why it is wrong, and a reader that
#     graded comments would call those two services divergent;
#   * an `echo "    uses: cafaye/kit/...@master"` inside a `run:` block —
#     `docs/.github/workflows/ci.yml` has one, in a step whose entire job is to
#     tell a reader the documented string. It is a string, not a call, and a
#     substring search grades it a call.
#   * a `grep -Eq '^[[:space:]]*uses: cafaye/kit/'` pattern in the same file,
#     which begins with `grep` and is a check rather than the thing checked.
#
# Indentation is allowed, because a `uses:` is a mapping key nested under a job
# and always is. The anchor is on the FIRST TOKEN, and the excluded shapes all
# have something other than `uses:` as theirs.
#
# The ref capture stops at the first quote or whitespace so a trailing `"` from
# the echo case cannot end up inside the ref even if the anchoring is bypassed.
CALLS_KIT = re.compile(
    r"^\s*uses:\s*cafaye/kit/(?P<path>[^\s@]+)@(?P<ref>[^\s'\"]+)"
)
USE_COMMENT = re.compile(r"^\s*#")
LANG_LINE = re.compile(r"^\s+language:\s*['\"]?([A-Za-z0-9_-]+)['\"]?\s*$")


def load_table(path: str) -> dict:
    """The artefact table, or a refusal. Never a default.

    A table this script cannot read is not an empty report, and a table naming
    a file kit does not ship is worse than no table: every service would be
    reported `absent` forever, which reads as a migration backlog and is
    actually a typo. Both are refusals, on the same principle the classifier
    uses — an input it cannot place is a finding, never a pass.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            table = json.load(fh)
    except OSError as exc:
        raise SystemExit(f"staleness.py: cannot read the artefact table at {path}: {exc}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"staleness.py: {path} is not valid JSON: {exc}")

    artefacts = table.get("artefacts")
    if not isinstance(artefacts, list) or not artefacts:
        raise SystemExit(
            f"staleness.py: {path} declares no artefacts. A report that measured "
            f"nothing would print a table of agreements it did not check."
        )

    seen = set()
    for artefact in artefacts:
        for key in ("id", "source", "dest"):
            if not artefact.get(key):
                raise SystemExit(
                    f"staleness.py: {path} has an artefact with no {key!r}. Every "
                    f"artefact names what kit ships and where a service puts it."
                )
        if artefact["id"] in seen:
            raise SystemExit(
                f"staleness.py: {path} declares {artefact['id']!r} twice. Two rows "
                f"for one artefact means one of them is no longer being read."
            )
        seen.add(artefact["id"])
    return table


def validate_table_against_kit(table: dict, kit_dir: str) -> list[str]:
    """Every artefact source kit actually ships. Returns the problems.

    Split out from `load_table` because the kit checkout is not needed to read
    the table and IS needed to trust it. `--scope templates` treats a non-empty
    problem list as a refusal; the gate calls this directly and reports the
    same list under a named check, so the two cannot disagree about what a
    valid table is.
    """
    problems = []
    for artefact in table["artefacts"]:
        if artefact.get("dest") == "@call":
            # The one artefact a service does not copy. Nothing on disk to find.
            continue
        pairs = artefact.get("bundle") or [
            {"source": artefact["source"], "dest": artefact["dest"]}
        ]
        for pair in pairs:
            # `{lang}` is resolved per service, so the template form is what is
            # checked: a glob is enough to prove the shape exists, and a
            # language-specific absence is a different (and already-reported)
            # finding.
            pattern = os.path.join(kit_dir, pair["source"].replace("{lang}", "*"))
            if not glob_has_match(pattern):
                problems.append(
                    f"{artefact['id']}: artifacts.json names "
                    f"{pair['source']!r}, which kit does not ship. Every service "
                    f"would be reported absent for it, forever, and an absence "
                    f"nobody can act on is worse than no report."
                )
    return problems


def glob_has_match(pattern: str) -> bool:
    """True when at least one path matches `pattern`.

    `glob` rather than a hand-rolled prefix match, and at module scope rather
    than imported inside this function. The second half is the point: the
    carve-out check in `tests/validate.sh` walks the whole AST looking for
    imports, and an import tucked into a function body is exactly the kind of
    thing that check exists to make conspicuous — so nothing here hides one.
    """
    return bool(glob.glob(pattern))


def read_bytes(path: str) -> bytes | None:
    """The bytes at `path`, or None when they cannot be read.

    A file that exists and cannot be read is not an absence. Reporting it as
    one would be a false negative produced by the cheapest possible route:
    the check was not run.
    """
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError:
        return None


def declared_language(repo_dir: str) -> str | None:
    """The `language` a service's own CI caller passes to kit's workflow.

    Read from the DECLARED input, in the same field the build uses, so the
    reporter and CI cannot disagree about which service this is. Not inferred
    from the presence of a `go.mod` or a `Gemfile`: a manifest is a guess about
    intent, an input is a statement of it, and this reporter reports
    measurements. `None` means the service declared nothing, which puts every
    language-keyed artefact in `unknown`.

    Returns `(language, ref)`; `ref` is the ref the caller pinned kit at, and
    is None when there is no caller at all.
    """
    workflows = os.path.join(repo_dir, WORKFLOW_GLOB)
    if not os.path.isdir(workflows):
        return None, None
    for dirpath, _dirs, files in os.walk(workflows):
        for name in sorted(files):
            if not name.endswith((".yml", ".yaml")):
                continue
            try:
                with open(os.path.join(dirpath, name), encoding="utf-8") as fh:
                    lines = fh.read().splitlines()
            except OSError:
                continue
            language = None
            for index, line in enumerate(lines):
                if USE_COMMENT.match(line):
                    continue
                found = CALLS_KIT.match(line)
                if not found:
                    continue
                if found.group("path") != "ci.reusable.yml" and \
                        found.group("path") != ".github/workflows/ci.reusable.yml":
                    # A call to some other kit path. Reported as a divergence by
                    # the caller below, not silently accepted.
                    return language, found.group("ref")
                # The `language:` input is a sibling under the same job's
                # `with:`, so it is the next `language:` line. If there is none
                # the service declared nothing and the answer stays None —
                # which is the fail-closed direction, and the reason this is a
                # scan and not a default.
                for follow in lines[index + 1:]:
                    if USE_COMMENT.match(follow):
                        continue
                    if LANG_LINE.match(follow):
                        language = LANG_LINE.match(follow).group(1)
                        break
                    if follow.strip() and not follow.startswith((" ", "\t")):
                        break
                return language, found.group("ref")
    return None, None


def diff_summary(kit_bytes: bytes, repo_bytes: bytes, dest: str) -> dict:
    """How far apart two copies are, in numbers a reader can act on.

    A `docker-compose.yml` that differs by 420 lines does not want 420 lines
    printed into a scheduled report, and `diverged` alone does not say whether
    the divergence is a version pin or a rewrite. So: counts both ways, the
    first differing line, and — for a file small enough to read — the hunk
    headers, which is where a reader decides whether to look.
    """
    kit_lines = kit_bytes.decode("utf-8", "replace").splitlines()
    repo_lines = repo_bytes.decode("utf-8", "replace").splitlines()
    added = removed = 0
    first = None
    hunks = []
    matcher = difflib.SequenceMatcher(None, kit_lines, repo_lines, autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        if first is None:
            first = i1 + 1
        if tag in ("replace", "delete"):
            removed += i2 - i1
        if tag in ("replace", "insert"):
            added += j2 - j1
        if len(hunks) < 6:
            hunks.append({"at": i1 + 1, "kit": i2 - i1, "service": j2 - j1})
    return {
        "added": added,
        "removed": removed,
        "first_diff_line": first,
        "hunks": hunks,
        "kit_lines": len(kit_lines),
        "service_lines": len(repo_lines),
    }


def read_pins(path: str) -> tuple[dict, list[str]]:
    """`templates/parity-allowlist` into {(repo, artefact): pin}, plus problems.

    The format is templates/tier/skip-allowlist's format, in the same words and
    with the same four rules, because kit does not have two dialects of "record
    why" — two dialects is how one of them goes stale. The verbs are the two
    findings that need a reason, and the verb is checked against the state the
    reporter actually measured rather than trusted, so an entry claiming
    `absent` for a file that is present and byte-identical is a dead entry
    rather than a contradiction nobody notices.
    """
    problems = []
    pins: dict[tuple[str, str], dict] = {}
    if not os.path.isfile(path):
        # Not a malformed entry — a missing ledger. The caller refuses to run
        # rather than reporting a fleet it cannot say anything about.
        return pins, []

    # THREE verbs, not two, and the third is the one a two-verb format cannot
    # express. `unknown` is a finding like the others: the service declares no
    # language, so kit cannot say what it would have copied — which is a fact
    # somebody has to resolve, not a state to shrug at. Forcing it into
    # `absent` or `diverged` would put a false statement in the ledger, and a
    # ledger that has to state something false to record a real thing is a
    # ledger that gets left alone.
    line_re = re.compile(
        r"^(?P<verb>diverged|absent|unknown)\s+(?P<repo>\S+)\s+(?P<artefact>\S+)"
        r"(?P<fields>(?:\s+[a-z]+=(?:\"[^\"]*\"|\S+))*)\s*$"
    )
    field_re = re.compile(r'([a-z]+)=("[^"]*"|\S+)')
    for lineno, raw in enumerate(open(path, encoding="utf-8").read().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        found = line_re.match(line)
        if not found:
            problems.append(
                f"line {lineno}: malformed entry. Expected 'diverged|absent|unknown "
                f"<repo> <artefact-id> reason=\"...\" owner=… since=YYYY-MM-DD "
                f"until=YYYY-MM-DD' on ONE line"
            )
            continue
        fields = {k: v.strip('"') for k, v in field_re.findall(found.group("fields"))}
        key = (found.group("repo"), found.group("artefact"))
        for name in ("reason", "owner", "since", "until"):
            if not fields.get(name):
                problems.append(f"line {lineno}: entry names no {name}")
        if key in pins:
            problems.append(f"line {lineno}: duplicate entry for {key[0]}/{key[1]}")
        pins[key] = {
            "verb": found.group("verb"),
            "repo": found.group("repo"),
            "artefact": found.group("artefact"),
            "reason": fields.get("reason"),
            "owner": fields.get("owner"),
            "since": fields.get("since"),
            "until": fields.get("until"),
            "line": lineno,
        }
    return pins, problems


def pin_text(pin: dict) -> str:
    """A pin as one printable line: reason, owner, expiry. Never the whole file."""
    return f"{pin['reason']} (owner {pin['owner']}, until {pin['until']})"


def collect_cell(repo_name: str, repo_dir: str, artefact: dict, kit_dir: str,
                 lang: str | None, ref: str | None) -> dict:
    """One (repository, artefact) cell, and the state it is in.

    The state is decided by WHERE the artefact is, not by what it resembles:

      * the path is absent                       -> absent
      * the path is a symlink, or not readable   -> unknown
      * the bytes are equal                      -> current
      * the bytes differ                         -> diverged

    There is no similarity score, no nearest match and no search for a file
    that hashes to kit's. A copy is current when the declared path holds
    kit's bytes in a real file of the service's own tree, and at no other time.
    """
    dest = artefact["dest"]
    langs = artefact.get("languages")
    needs_lang = bool(artefact.get("needsLanguage"))

    cell = {
        "repo": repo_name,
        "artefact": artefact["id"],
        "state": TPL_UNKNOWN,
        "note": "",
        "diff": None,
        "pin": None,
        "source": None,
        "dest": dest,
        # Carried onto the row so `needs_a_pin` can act on it without reaching
        # back into the table. See that function for why only `absent` is
        # exempted.
        "optional": bool(artefact.get("optional")),
    }

    # The one artefact a service does not copy. A caller is a reference, and
    # the reference is right when it names the path the file is actually at.
    if dest == "@call":
        if ref is None:
            cell["state"] = TPL_ABSENT
            cell["note"] = "no caller of kit's workflow"
            return cell
        if ref != DOCUMENTED_REF:
            cell["state"] = TPL_DIVERGED
            cell["note"] = f"caller pins kit at @{ref}, not @{DOCUMENTED_REF}"
            return cell
        # The path check happened in declared_language: a caller on a path kit
        # does not serve was reported there. Reaching here means it names
        # ci.reusable.yml at the documented ref.
        cell["state"] = TPL_CURRENT
        return cell

    # A language-keyed artefact for a language this service is not. `n/a`, NOT
    # `unknown`: a Go service having no rubocop config is a settled fact, and
    # calling it unmeasured would put three permanent, unfixable findings on
    # every service in the fleet. An undeclared language is the different case
    # and lands in `unknown`, because there the applicability is genuinely not
    # known.
    if langs is not None and lang is not None and lang not in langs:
        cell["state"] = TPL_NA
        cell["note"] = f"kit ships no {lang} variant of this artefact"
        return cell
    if langs is not None and lang is None:
        cell["state"] = TPL_UNKNOWN
        cell["note"] = (
            "the service declares no language, so whether this artefact applies "
            "to it is unresolvable"
        )
        return cell

    if needs_lang and lang is None:
        cell["state"] = TPL_UNKNOWN
        cell["note"] = (
            "kit ships this per language and the service declares none, so the "
            "source to compare against is unresolvable"
        )
        return cell

    source = artefact["source"].replace("{lang}", lang) if lang else artefact["source"]
    cell["source"] = source
    kit_path = os.path.join(kit_dir, source)
    kit_bytes = read_bytes(kit_path)
    if kit_bytes is None:
        cell["state"] = TPL_UNKNOWN
        cell["note"] = f"kit does not ship {source}"
        return cell

    # Where the copy is allowed to live. `dest` is where kit's README says it
    # goes; `destAlternatives` are paths a service in this fleet is DOCUMENTED
    # as using instead. Resolution is by EXISTENCE among a declared list, never
    # by content and never by a search — a reporter that went looking for a
    # plausible file would eventually find one in a directory nobody meant.
    #
    # This is not the same as inferring identity from content, and the
    # difference is worth being explicit about: the LIST is declared in kit and
    # diffable, the choice among the entries is made by which path exists, and
    # `absent` still means absent of every one of them. A path nobody declared
    # is still an absence.
    #
    # `lexists`, not `exists`: a DANGLING symlink is a real finding — a service
    # pointed at a file that is not there — and `exists` follows the link and
    # reports it as absent, which throws away the only clue about what happened.
    dests = [dest] + [
        d for d in artefact.get("destAlternatives", []) if d != dest
    ]
    present_dest = None
    for candidate in dests:
        if os.path.lexists(os.path.join(repo_dir, candidate)):
            present_dest = candidate
            break
    cell["dests"] = dests
    cell["found_at"] = present_dest
    dest = present_dest or dest

    # A bundle's members carry their own declared destinations, so a service
    # that puts `docker-compose.yml` at the root and the stores in `docker/`
    # still resolves — the bundle is a set of pairs, not one path.
    pairs = artefact.get("bundle") or [{"source": source, "dest": dest}]
    missing, present_identical, differing, unreadable = [], [], [], []
    divergent_sources = []
    for pair in pairs:
        pair_source = pair["source"].replace("{lang}", lang) if lang else pair["source"]
        pair_kit = read_bytes(os.path.join(kit_dir, pair_source))
        repo_path = os.path.join(repo_dir, pair["dest"])
        if os.path.islink(repo_path):
            unreadable.append(pair["dest"])
            continue
        repo_bytes = read_bytes(repo_path)
        if repo_bytes is None:
            missing.append(pair["dest"])
            continue
        if pair_kit == repo_bytes:
            present_identical.append(pair["dest"])
            continue
        differing.append(pair["dest"])
        if pair is pairs[0]:
            divergent_sources.append((pair_source, pair_kit, repo_bytes))

    cell["missing"] = missing
    cell["present_identical"] = present_identical
    cell["differing"] = differing
    cell["unreadable"] = unreadable

    if unreadable:
        cell["state"] = TPL_UNKNOWN
        cell["note"] = (
            "not a copy: "
            + ", ".join(unreadable)
            + (" is a symlink" if len(unreadable) == 1 else " are symlinks")
            + ", and a symlink to identical bytes is a bet that the target never moves"
        )
        return cell
    if missing and (differing or present_identical):
        # PARTIALLY ADOPTED, and it is `diverged` rather than `absent` because
        # the service holds SOME of it. A service carrying four of the stack's
        # twelve files has adopted the stack, badly; calling it `absent` would
        # say it adopted nothing, which is the opposite of the truth and the
        # direction that makes a finding disappear.
        #
        # The breakdown is three numbers, not one, because the three situations
        # call for three different responses. Identical members mean the service
        # copied what was there and never touched the rest — usually a stack that
        # predates the observability profile. Differing members mean it wrote its
        # own. Both means somebody re-copied one file and lost the rest, which is
        # the state that looks most like adoption and is least like it.
        #
        # The note does NOT claim the stack cannot start. An earlier version did,
        # and it was wrong: none of this fleet's compose files mounts any of
        # kit's stack files, so these are REPLACEMENTS that kept a filename, not
        # kit's stack with pieces removed. `docker compose config` is green on
        # five of the six that have one. The reporter compares bytes and cannot
        # tell those two situations apart, so the note says what it measured and
        # stops.
        held = len(present_identical) + len(differing)
        if not differing:
            shape = "every member it holds is byte-identical to kit's"
        elif not present_identical:
            shape = "every member it holds is its own"
        else:
            shape = f"{len(present_identical)} identical, {len(differing)} its own"
        cell["state"] = TPL_DIVERGED
        cell["note"] = (
            f"partially adopted: {held} of {len(pairs)} member(s) held ({shape}), "
            f"{len(missing)} missing — and this is a stack kit's compose file "
            f"mounts by path, so it is either kit's stack adopted badly or a "
            f"replacement that kept one of its filenames"
        )
        return cell
    if missing:
        cell["state"] = TPL_ABSENT
        cell["note"] = (
            f"nothing at {' or '.join(dests)}"
            if len(dests) > 1 else f"nothing at {dest}"
        )
        return cell
    if differing:
        cell["state"] = TPL_DIVERGED
        if artefact.get("bundle"):
            cell["note"] = f"{len(differing)} of {len(pairs)} member(s) differ"
        if divergent_sources:
            pair_source, pair_kit, repo_bytes = divergent_sources[0]
            cell["diff"] = diff_summary(pair_kit, repo_bytes, dest)
            cell["diff"]["source"] = pair_source
        else:
            cell["diff"] = diff_summary(kit_bytes, read_bytes(
                os.path.join(repo_dir, dest)) or b"", dest)
            cell["diff"]["source"] = source
        if present_dest and present_dest != artefact["dest"]:
            # A service that put the artefact somewhere kit did not document is
            # graded on the BYTES, and the placement is recorded rather than
            # inferred: two of the fleet's Dockerfiles live at the root, kit's
            # README says `docker/`, and neither fact is a reason to call the
            # artefact absent.
            cell["note"] = (cell["note"] + "; " if cell["note"] else "") + \
                f"placed at {present_dest}, not kit's documented {artefact['dest']}"
        return cell

    cell["state"] = TPL_CURRENT
    return cell



    index = {(r["repo"], r["artefact"]): r for r in rows}
    unpinned = [r for r in rows if needs_a_pin(r) and not r.get("pin")]
    dead = [
        dict(pin, state=(index.get(key) or {}).get("state", "unmeasured"))
        for key, pin in pins.items()
        if index.get(key) is None or index[key]["state"] not in NEEDS_PIN
    ]
    return rows, unpinned + dead


def render_template_table(rows: list[dict], findings: list[dict], kit_head: str,
                          pins: dict) -> str:
    order = {TPL_ABSENT: 0, TPL_DIVERGED: 1, TPL_UNKNOWN: 2, TPL_CURRENT: 3,
             TPL_NA: 4}
    counts = {state: sum(1 for r in rows if r["state"] == state)
              for state in (TPL_CURRENT, TPL_DIVERGED, TPL_ABSENT, TPL_UNKNOWN,
                            TPL_NA)}
    repos = sorted({r["repo"] for r in rows})

    name_w = max([len("repository")] + [len(r) for r in repos])
    art_w = max([len("artefact")] + [len(r["artefact"]) for r in rows])

    out = [f"kit {kit_head[:12]}: templates", ""]
    header = f"{'repository'.ljust(name_w)}  {'artefact'.ljust(art_w)}  state"
    out.append(header)
    out.append("-" * len(header))
    for row in sorted(rows, key=lambda r: (order.get(r["state"], 9), r["repo"],
                                           r["artefact"])):
        # `current` and `n/a` rows are omitted. A report that printed all 108
        # cells of a nine-repository fleet would bury the 60 that are not fine,
        # and the whole reason a finding is a finding is that it is the thing
        # you read. Their COUNTS are printed below and `--json` has every one of
        # them, so nothing here is hidden — only deprioritised.
        if row["state"] in (TPL_CURRENT, TPL_NA):
            continue
        cell = f"{row['repo'].ljust(name_w)}  {row['artefact'].ljust(art_w)}  {row['state']}"
        if row.get("diff"):
            d = row["diff"]
            cell += f"  +{d['added']} -{d['removed']} lines, first at {d['first_diff_line']}"
        if row.get("note"):
            cell += f"  ({row['note']})"
        if row.get("pin"):
            cell += f"  PINNED: {pin_text(row['pin'])}"
        elif needs_a_pin(row):
            cell += "  UNPINNED"
        elif row.get("optional"):
            # Reported and not a pin. The marker is on the row rather than
            # implied by the absence of UNPINNED, because "absent, and nothing
            # needs saying" and "absent, and kit does not expect this service to
            # have adopted it yet" are different statements and a reader should
            # not have to know which one they are looking at.
            cell += "  (optional — kit does not yet expect this service to hold it)"
        out.append(cell)

    out.append("")
    if findings:
        out.append(f"FINDINGS ({len(findings)}) — every one of these needs a pin")
        for finding in findings:
            if "pin" not in finding:
                out.append(
                    f"  dead pin   {finding['repo']}/{finding['artefact']} — matches "
                    f"nothing, the fleet says {finding['state']}. {pin_text(finding)}"
                )
                continue
            if finding.get("pin_mismatch"):
                out.append(
                    f"  mismatch   {finding['repo']}/{finding['artefact']} — the entry "
                    f"says {finding['pin']['verb']}, the fleet says {finding['state']}"
                )
                continue
            out.append(
                f"  unpinned   {finding['repo']}/{finding['artefact']} — "
                f"{finding['state']}: {finding.get('note') or 'no recorded reason'}"
            )
    else:
        out.append(
            "FINDINGS (0) — every divergence, every absence and every unmeasurable "
            "cell has a recorded reason."
        )

    out.append("")
    out.append(
        f"{len(rows)} cell(s) over {len(repos)} repo(s): "
        f"{counts[TPL_CURRENT]} current, {counts[TPL_DIVERGED]} diverged, "
        f"{counts[TPL_ABSENT]} absent, {counts[TPL_UNKNOWN]} unknown, "
        f"{counts[TPL_NA]} n/a. "
        f"{len(pins)} entr{'y' if len(pins) == 1 else 'ies'} in the parity allowlist."
    )
    out.append(
        "An unpinned finding is unproven, not fine: it is a copy nobody can say "
        "is deliberate. `n/a` is the only state that needs no pin — kit makes no "
        "claim about an artefact it does not ship for that service."
    )
    return "\n".join(out)


def report_template_failures(findings: list[dict]) -> int:
    """Say what is wrong, naming the cell. Never a count alone.

    A finding list is short and specific, so every line names the repository and
    the artefact. "6 unpinned cells" is a number somebody has to go and look up;
    "gateway/docker/Dockerfile is an unpinned divergence" is a task.

    The three shapes are told apart by their KEYS, not by a flag, so a fourth
    shape cannot be silently rendered as one of these three. A dead pin carries
    the state the fleet actually measured, and no `pin`; a mismatch carries a
    `pin` whose verb disagrees with that state.
    """
    print("FAIL parity: the fleet's copies of kit's templates are unproven.")
    for finding in findings:
        if "pin" not in finding:
            print(
                f"  FAIL parity: pin for {finding['repo']}/{finding['artefact']} "
                f"matches NOTHING — the fleet says {finding['state']}, so the entry "
                f"excuses nothing. Delete it. ({pin_text(finding)})"
            )
            continue
        if finding.get("pin_mismatch"):
            print(
                f"  FAIL parity: {finding['repo']}/{finding['artefact']} is "
                f"{finding['state']} but its entry says {finding['pin']['verb']}. An "
                f"entry records a decision, and this one does not describe the fleet."
            )
            continue
        state = finding["state"]
        noun = {"absent": "absence", "diverged": "divergence",
                "unknown": "unmeasurable cell"}.get(state, state)
        print(
            f"  FAIL parity: {finding['repo']}/{finding['artefact']} is an unpinned "
            f"{noun} — {finding.get('note') or 'kit ships this and the service does not'}"
            f". Adopt it, or record in templates/parity-allowlist why this service "
            f"does not."
        )
    print(
        "  A pin is not a waiver: it is a reason, an owner and a date. An entry that "
        "matches nothing is a failure in the other direction too."
    )
    return len(findings)


def resolve_kit_head(kit_dir: str) -> str:
    """kit's own commit, for the header. `master` before `HEAD`, as in the core scope."""
    for ref in ("refs/remotes/origin/master", "master", "HEAD"):
        code, out, _ = run_git(["rev-parse", ref], kit_dir)
        sha = out.strip()
        if code == 0 and SHA_RE.match(sha):
            return sha
    # Not a checkout — a plain directory copy, which is a legitimate thing to
    # point this at. Say so rather than inventing a sha.
    return "unknown"


def is_worktree(path: str) -> bool:
    """True when `path` is a git WORKTREE rather than its own repository.

    A worktree's `.git` is a file containing `gitdir: <main>/.git/worktrees/<name>`
    and it shares the main repository's history and remotes. Treating one as a
    separate consumer counts the same pin twice, which inflates the denominator
    and — worse — makes a repository look like it holds two independent copies of
    core at two different ages, which is a story nobody should have to disprove.

    The cost of getting this wrong is invisible, which is why it is a named
    function rather than an `if` in the caller.
    """
    marker = os.path.join(path, ".git")
    if not os.path.isfile(marker):
        return False
    try:
        with open(marker, encoding="utf-8") as fh:
            return fh.read(6).strip() == "gitdir"
    except OSError:
        return False


def read_lockfile_sha(repo_dir: str) -> tuple[str | None, str | None]:
    """The `sha` of the first git content entry in a vendir lockfile.

    Returns (sha, ref) where ref is the tag or branch the lockfile names, or
    (None, None) when there is no lockfile or it has no git content.
    """
    path = os.path.join(repo_dir, LOCKFILE)
    if not os.path.isfile(path):
        return None, None
    with open(path, encoding="utf-8") as fh:
        body = fh.read()
    sha = re.search(r"^\s*sha:\s*([0-9a-f]{40})\s*$", body, re.MULTILINE)
    if not sha:
        return None, None
    tags = re.search(r"^\s*-\s*(v?\d+\.\d+\.\d+[^\s]*)\s*$", body, re.MULTILINE)
    return sha.group(1), (tags.group(1) if tags else None)


def read_core_ref(repo_dir: str) -> str | None:
    """A `CORE_REF: <sha>` in any workflow file.

    The hand-bumped form. Read as text rather than as YAML on purpose: it is a
    grep for one literal in a known shape, and a YAML round-trip here would add a
    parser dependency to a script whose entire virtue is that it cannot fail to
    start.
    """
    root = os.path.join(repo_dir, WORKFLOW_GLOB)
    if not os.path.isdir(root):
        return None
    for dirpath, _dirs, files in os.walk(root):
        for name in sorted(files):
            if not (name.endswith(".yml") or name.endswith(".yaml")):
                continue
            try:
                with open(os.path.join(dirpath, name), encoding="utf-8") as fh:
                    body = fh.read()
            except OSError:
                continue
            found = re.search(r"^\s*CORE_REF:\s*([0-9a-f]{40})\s*$", body, re.MULTILINE)
            if found:
                return found.group(1)
    return None


def pins_disagree(lock_sha: str | None, core_ref: str | None) -> bool:
    """A repository mid-migration whose two pins do not match.

    This is a real and reportable state, not a rounding error: the lockfile says
    the vendored bytes came from one commit and the workflow says the CI gate
    checks another, so the bytes under test and the bytes on disk are not the
    same bytes and the parity test is proving something narrower than it claims.
    """
    return bool(lock_sha and core_ref and lock_sha != core_ref)


def resolve_core_head(core_dir: str) -> str | None:
    """The sha the core checkout has locally, preferring the remote-tracking ref.

    `master` before `HEAD` on purpose: a repository that has been sitting on a
    branch for a week is reporting the wrong thing, and the thing being reported
    should be what the fleet would pull.
    """
    for ref in ("refs/remotes/origin/master", "refs/remotes/origin/main", "master", "HEAD"):
        code, out, _ = run_git(["rev-parse", ref], core_dir)
        sha = out.strip()
        if code == 0 and SHA_RE.match(sha):
            return sha
    return None


def commits_between(core_dir: str, older: str, newer: str) -> int | None:
    """How many commits `older` is behind `newer`, or None if unknown.

    `git rev-list --count older..newer`. An unknown count is None rather than 0,
    because "0" would claim the copies are identical, which is a different claim
    from "I could not tell".
    """
    code, out, _ = run_git(["rev-list", "--count", f"{older}..{newer}"], core_dir)
    if code != 0:
        return None
    try:
        return int(out.strip())
    except ValueError:
        return None


def classify_state(pin: str | None, behind: int | None) -> str:
    if pin is None:
        return UNDECLARED
    if behind is None:
        return UNKNOWN
    return CURRENT if behind == 0 else BEHIND


def discover_local(repos_dir: str, include_worktrees: bool = False,
                   exclude: tuple[str, ...] = ("core",)) -> list[str]:
    """Immediate subdirectories of repos_dir that are their own git repository.

    `exclude` names the directories that are REFERENCES rather than consumers, so
    a row reading "core is undeclared" — a true sentence about a meaningless
    question — is never printed. It is a parameter rather than a hardcoded
    `if entry == "core"` because the two scopes have different references: the
    core scope measures services against `core`, the templates scope measures
    them against `kit`, and a service is a consumer of neither.
    """
    found = []
    try:
        entries = sorted(os.listdir(repos_dir))
    except OSError as exc:
        raise SystemExit(f"staleness.py: cannot read {repos_dir}: {exc}")
    for entry in entries:
        if entry in exclude:
            continue
        path = os.path.join(repos_dir, entry)
        if not os.path.isdir(path) or not is_checkout(path):
            continue
        if not include_worktrees and is_worktree(path):
            continue
        found.append(entry)
    return found


def discover_github_org(org: str, token: str | None) -> list[str]:
    """Every repository in a GitHub organisation.

    The token is read from the environment and never echoed, never logged, and
    never placed in a URL — a token in a URL is a token in a proxy log, and a
    token in this script's output is a token in a CI log. An unauthenticated
    request works for a public organisation and is what the cafaye fleet uses;
    the token exists for a private one.
    """
    url = f"https://api.github.com/orgs/{org}/repos?per_page=100&type=all"
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"staleness.py: GitHub API returned {exc.code} for org {org}")
    except urllib.error.URLError as exc:
        raise SystemExit(f"staleness.py: cannot reach the GitHub API: {exc.reason}")
    return sorted(repo["name"] for repo in payload)


def collect_row(name: str, repo_dir: str, core_dir: str, head: str) -> dict:
    lock_sha, ref = read_lockfile_sha(repo_dir)
    core_ref = read_core_ref(repo_dir)
    pin = lock_sha or core_ref
    behind = None
    if pin and head:
        if pin == head:
            # Pinned at exactly what core publishes right now: that is `current`,
            # and it is a DIFFERENT claim from "I could not measure". Reporting it
            # as `unknown` was a real bug this suite caught — and it is the
            # expensive direction to get wrong, because `unknown` is the state a
            # reader learns to ignore.
            behind = 0
        else:
            behind = commits_between(core_dir, pin, head)
    row = {
        "repo": name,
        "pin": pin,
        "pin_source": (
            LOCKFILE if lock_sha else ("CORE_REF" if core_ref else "none")
        ),
        "ref": ref,
        "state": classify_state(pin, behind),
        "behind": behind if behind is not None else 0,
        "behind_known": behind is not None,
        "disagrees": pins_disagree(lock_sha, core_ref),
    }
    return row


def render_table(rows: list[dict], head: str) -> str:
    order = {BEHIND: 0, UNKNOWN: 1, UNDECLARED: 2, CURRENT: 3}
    rows = sorted(rows, key=lambda r: (order.get(r["state"], 9), r["repo"]))
    name_w = max([len("repository")] + [len(r["repo"]) for r in rows])
    src_w = max([len("source")] + [len(r["pin_source"]) for r in rows])

    out = [f"core master: {head}", ""]
    header = (
        f"{'repository'.ljust(name_w)}  {'pin'.ljust(12)}  {'source'.ljust(src_w)}  "
        f"{'ref'.ljust(8)}  {'behind'.rjust(7)}  state"
    )
    out.append(header)
    out.append("-" * len(header))
    for row in rows:
        behind = str(row["behind"]) if row["behind_known"] else "?"
        pin = (row["pin"] or "-")[:12]
        flag = ""
        if row["disagrees"]:
            # A mid-migration disagreement is worth its own column's worth of
            # attention: both pins exist, and they name different commits.
            flag = "  PINS DISAGREE"
        out.append(
            f"{row['repo'].ljust(name_w)}  {pin.ljust(12)}  "
            f"{row['pin_source'].ljust(src_w)}  {(row['ref'] or '-')[:8].ljust(8)}  "
            f"{behind.rjust(7)}  {row['state']}{flag}"
        )
    behind_count = sum(1 for r in rows if r["state"] == BEHIND)
    unknown_count = sum(1 for r in rows if r["state"] in (UNKNOWN, UNDECLARED))
    out.append("")
    out.append(
        f"{len(rows)} repo(s): {behind_count} behind, {unknown_count} not measured, "
        f"{len(rows) - behind_count - unknown_count} current"
    )
    return "\n".join(out)


def run_templates_scope(args: argparse.Namespace) -> int:
    """`--scope templates`. Measure files, not pins.

    Split from the core scope rather than threaded through it: the two halves
    share discovery and nothing else, and the core half's measured numbers are
    published in kit's README. Interleaving them would risk the one thing that
    makes this reporter worth reading, which is that its two reports are
    independently true.
    """
    kit_dir = args.kit or os.path.join(args.repos_dir, "kit")
    if not os.path.isdir(kit_dir):
        raise SystemExit(f"staleness.py: no kit checkout at {kit_dir}")

    table = load_table(args.table)

    # The table is only trustworthy if every source it names is a file kit
    # actually ships. A typo here would report the entire fleet `absent`,
    # forever, and would be indistinguishable from a migration backlog.
    problems = validate_table_against_kit(table, kit_dir)
    if problems:
        for problem in problems:
            print(f"staleness.py: {problem}", file=sys.stderr)
        raise SystemExit(
            f"staleness.py: the artefact table names {len(problems)} file(s) kit does "
            f"not ship. Refusing to report: every service would read absent, and an "
            f"absence nobody can act on is worse than no report at all."
        )

    pins, pin_problems = read_pins(args.allowlist)
    for problem in pin_problems:
        print(f"staleness.py: {args.allowlist}: {problem}", file=sys.stderr)
    if pin_problems:
        raise SystemExit(
            f"staleness.py: the parity allowlist has {len(pin_problems)} problem(s). "
            f"A malformed entry is an entry nobody is maintaining."
        )
    if not os.path.isfile(args.allowlist):
        raise SystemExit(
            f"staleness.py: no parity allowlist at {args.allowlist}. An unpinned "
            f"divergence is unproven rather than fine, so a run with no ledger to "
            f"check pins against cannot conclude anything about the fleet."
        )

    names = resolve_repo_names(args, exclude=("core", "kit"))

    rows = []
    missing = []
    for name in names:
        repo_dir = os.path.join(args.repos_dir, name)
        if not os.path.isdir(repo_dir):
            missing.append(name)
            continue
        lang, ref = declared_language(repo_dir)
        for artefact in table["artefacts"]:
            cell = collect_cell(name, repo_dir, artefact, kit_dir, lang, ref)
            cell["language"] = lang
            pin = pins.get((name, artefact["id"]))
            if pin is not None:
                cell["pin"] = pin
                if pin["verb"] != cell["state"] and cell["state"] in NEEDS_PIN:
                    cell["pin_mismatch"] = True
            rows.append(cell)

    index = {(r["repo"], r["artefact"]): r for r in rows}
    measured = {r["repo"] for r in rows}
    unpinned = [r for r in rows if needs_a_pin(r) and not r.get("pin")]
    mismatched = [r for r in rows if r.get("pin_mismatch")]
    dead: list[dict] = []

    # THREE outcomes for a pin, and collapsing any two of them is a bug.
    #
    #   the cell is a finding      -> the pin is doing its job
    #   the cell is current / n/a  -> DEAD: it excuses nothing
    #   the repo was not measured  -> NOT EVALUATED, unless it is not ON DISK
    #
    # The third case is the one that bit the first version, and it is worth the
    # whole comment. `--repo X` measures ONE repository, and the fleet-wide
    # ledger then held eighty entries for repositories the run never looked at;
    # every one of them was reported as a dead pin. A reporter cannot tell "not
    # in scope" from "gone" by looking at what it measured, and guessing the
    # destructive one is how a scoped run becomes a false alarm.
    #
    # So the question "does this repository exist?" is answered by the FILESYSTEM
    # rather than by the scope of this run. `not-a-real-service` is a real dead
    # entry whatever `--repo` selected; `pinned-svc` is a real live entry that
    # this run is not looking at. Both are decidable, and the difference is a
    # directory.
    for key, pin in pins.items():
        if pin["repo"] in measured:
            cell = index.get(key)
            if cell is None or cell["state"] not in NEEDS_PIN:
                dead.append(dict(pin, state=(cell or {}).get("state", "no such cell")))
        elif not os.path.isdir(os.path.join(args.repos_dir, pin["repo"])):
            dead.append(dict(pin, state="no such repository"))
    findings = unpinned + mismatched + dead

    kit_head = resolve_kit_head(kit_dir)
    if args.json:
        json.dump(
            {
                "kit_head": kit_head,
                "scope": "templates",
                "cells": rows,
                "findings": [
                    {"repo": f.get("repo"), "artefact": f.get("artefact"),
                     "state": f.get("state", f.get("verb")), "why": f.get("reason")}
                    for f in findings
                ],
                "missing": missing,
                "pins": len(pins),
            },
            sys.stdout, indent=2, sort_keys=True,
        )
        sys.stdout.write("\n")
    else:
        print(render_template_table(rows, findings, kit_head, pins))
        if missing:
            print(f"\nnot found under {args.repos_dir}: {', '.join(sorted(missing))}")

    if missing:
        print(
            f"FAIL: {len(missing)} repository(ies) named on the command line could not "
            f"be read. A service nobody can read is a service nobody is maintaining.",
            file=sys.stderr,
        )
        return 1

    if args.fail_on_unpinned and findings:
        report_template_failures(findings)
        return 1
    return 0


def resolve_repo_names(args: argparse.Namespace, exclude: tuple[str, ...]) -> list[str]:
    """The repositories to report on, by the same three discovery routes as core.

    `exclude` differs per scope and the difference is the whole point of the
    argument: `core` is the reference the core scope measures against, and `kit`
    is the reference the templates scope measures against. Neither is a consumer
    of itself, and a row saying so is a true sentence about a meaningless
    question.
    """
    if args.repo:
        return list(args.repo)
    if args.github_org:
        token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
        return discover_github_org(args.github_org, token)
    found = discover_local(args.repos_dir, args.include_worktrees, exclude=exclude)
    return found


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="staleness.py",
        description="Report how far each vendored copy of core has fallen behind, "
                    "and whether each service's copy of kit's templates still IS "
                    "kit's bytes.",
    )
    parser.add_argument("--repos-dir", required=True,
                        help="directory holding one checkout per cafaye repository")
    parser.add_argument("--scope", choices=("core", "templates"), default="core",
                        help="core: how far a vendored copy has fallen behind (default). "
                             "templates: whether a service's copy of kit's artefacts "
                             "is byte-identical, diverged, or simply not there.")
    parser.add_argument("--core", default=None,
                        help="path to the core checkout (default: <repos-dir>/core)")
    parser.add_argument("--kit", default=None,
                        help="path to the kit checkout (default: <repos-dir>/kit). "
                             "templates scope only.")
    parser.add_argument("--table", default=DEFAULT_TABLE,
                        help="the artefact table (default: tests/artifacts.json "
                             "beside this script). templates scope only.")
    parser.add_argument("--allowlist", default=DEFAULT_ALLOWLIST,
                        help="the parity allowlist (default: "
                             "templates/parity-allowlist). templates scope only.")
    parser.add_argument("--repo", action="append", default=[], metavar="NAME",
                        help="restrict to these repositories (repeatable)")
    parser.add_argument("--github-org", default=None, metavar="ORG",
                        help="discover repositories from this GitHub organisation "
                             "instead of listing --repos-dir")
    parser.add_argument("--fail-on-behind", action="store_true",
                        help="exit 1 when any repository is behind. Off by default, "
                             "because a stale copy is LEGAL — it is a copy that has "
                             "not been bumped yet — and a scheduled report that is red "
                             "every week is a report that gets muted. Turn this on in "
                             "a pull request, where a stale copy is the defect.")
    parser.add_argument("--fail-on-unpinned", action="store_true",
                        help="exit 1 when any copy of kit's templates is diverged, "
                             "absent or unmeasurable and nothing records why. Off by "
                             "default, for the same reason as --fail-on-behind: a "
                             "finding nobody has triaged yet is a backlog, not a "
                             "defect. Turn it on in a pull request that adopts "
                             "something.")
    parser.add_argument("--include-worktrees", action="store_true",
                        help="count git worktrees as repositories. Off by default: "
                             "a worktree shares its parent repository's history, so "
                             "counting one reports one consumer as two.")
    parser.add_argument("--json", action="store_true", help="emit JSON")
    args = parser.parse_args(argv)

    if args.scope == "templates":
        return run_templates_scope(args)

    core_dir = args.core or os.path.join(args.repos_dir, "core")
    if not os.path.isdir(core_dir):
        raise SystemExit(f"staleness.py: no core checkout at {core_dir}")
    head = resolve_core_head(core_dir)
    if head is None:
        raise SystemExit(
            f"staleness.py: cannot resolve core's published commit in {core_dir}. "
            f"A report that cannot say what `now` means would print a table of "
            f"agreements it did not check."
        )

    if args.repo:
        names = list(args.repo)
    elif args.github_org:
        token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
        names = discover_github_org(args.github_org, token)
    else:
        names = discover_local(args.repos_dir, args.include_worktrees)

    rows = []
    missing = []
    for name in names:
        repo_dir = os.path.join(args.repos_dir, name)
        if not os.path.isdir(repo_dir):
            missing.append(name)
            continue
        rows.append(collect_row(name, repo_dir, core_dir, head))

    if args.json:
        json.dump({"core_head": head, "rows": rows, "missing": missing},
                  sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        print(render_table(rows, head))
        if missing:
            print(f"\nnot found under {args.repos_dir}: {', '.join(sorted(missing))}")

    if missing:
        print(
            f"FAIL: {len(missing)} repository(ies) named on the command line could not "
            f"be read. A pin nobody can read is a pin nobody is maintaining.",
            file=sys.stderr,
        )
        return 1

    if args.fail_on_behind:
        behind_rows = [r for r in rows if r["state"] == BEHIND]
        if behind_rows:
            for row in behind_rows:
                print(
                    f"FAIL staleness: {row['repo']} is {row['behind']} commit(s) behind "
                    f"core master (pin {(row['pin'] or '')[:12]}, via {row['pin_source']}). "
                    f"Re-vendor, or record in the PR why this repository is pinned here."
                )
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
