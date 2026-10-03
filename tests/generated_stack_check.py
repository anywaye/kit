#!/usr/bin/env python3
"""kit's gate on the generated local stack: is `caf.dev.compose.yaml` build output?

    tests/generated_stack_check.py [--repos-dir <dir>] [--scope <file>] [--no-fleet]

WHAT IT IS FOR
    `caf dev` reads a repository's `cafaye.yml`, renders a stack from it, and
    WRITES that stack to `caf.dev.compose.yaml` in the repository root on every
    run. The file's own first three lines say so:

        # caf dev — the local stack for "courier-dev", generated from cafaye.yml.
        # Do not edit: every run rewrites this file. The manifest is the
        # source of truth; this is what it turned into.

    So it is build output shaped like a source file, and there are two ways that
    goes wrong, in increasing order of how long they take to notice:

      1. UNTRACKED AND NOT IGNORED. `git status` is permanently dirty in a
         repository whose whole job is to be clean, and the file is one
         `git add -A` from being committed.
      2. TRACKED. It is committed, and it is now a merge conflict nobody can
         resolve by reading it — both sides are generated, and the manifest
         neither side was derived from is not in the diff. Ignoring the path
         does NOT fix this one: git keeps tracking a file it already has, and
         the ignore entry would be a comment about a file that is still in the
         index. `git rm --cached` is the only thing that is.

    `core` was in state 2. It arrived in `8007d07` ("core: record kit-32's
    second non-database image reference in the fleet scan"), a commit about
    something else entirely, which is what state 2 looks like from the outside:
    nobody decided to track it.

WHY THIS IS A SEPARATE FILE AND NOT PART OF `fleet_check.py`
    Three reasons, and the third is the one that decided it.

    1. SCOPE. `fleet_check.py` checks repositories that DECLARE LOCAL
       INFRASTRUCTURE — a root compose file or a root collector config. The
       population here is every repository that HAS A `cafaye.yml`, which is a
       different set: `core`, `docs` and `caf` have manifests and no stack, and
       `core` is the repository this check exists for. Folding this into the
       other check would have scoped the one that matters most to the
       predicate that excludes it.
    2. SEVERITY. Every finding in `fleet_check.py` is routed through the
       ADOPTION CEILING — a warning in a repository that has not adopted
       `kit.ref`, a failure in one that has. That ceiling is correct there and
       wrong here, because it is about WHO OWNS A DEBT, and this defect has no
       adopter. A repository that has never heard of kit's stack still must not
       commit its generated one; there is no wave that makes it acceptable.
    3. DIFFERENT QUESTIONS, DIFFERENT TOOLS. `fleet_check.py` parses YAML.
       This one asks git two questions — is this path ignored, is it tracked —
       and the authoritative answer to both comes from `git` itself. Reading a
       `.gitignore` and pattern-matching it in Python would be a second, worse
       implementation of a language git already has, and it would disagree with
       git on every negation and every anchored path.

WHY IT ASKS GIT RATHER THAN READING `.gitignore`
    `git check-ignore` and `git ls-files` are the two questions, asked of the
    tool that owns both. The alternative — parse the `.gitignore` here — would be
    a reimplementation that is wrong in the cases that matter: `!` negation,
    a directory pattern that matches everything beneath it, an anchored `/`
    prefix, `**`, and a `core.excludesFile` in a developer's global config that
    silently ignores a path for them and not for anybody else. A check that
    answers "is this ignored" from a text file is a check whose answer is a
    guess about git.

    It also means the finding is about the REPOSITORY AS GIT SEES IT, which is
    the thing that actually decides what a `git add -A` picks up.

WHO IS IN SCOPE, AND WHY IT IS DERIVED RATHER THAN LISTED
    In scope: every repository under `--repos-dir` that HAS a `cafaye.yml` at
    its root. That predicate is read off the filesystem, and it is the same
    predicate `caf dev` itself uses to decide a directory is a project at all
    (`dev.Load` → `ErrNoManifest` if `cafaye.yml` is absent,
    `caf/internal/dev/project.go:26`). So the population cannot drift from the
    population that produces the file: a repository that grows a manifest is in
    scope the day it does, with nothing here edited.

    A hand-written list of repository names was rejected for the reason the
    packet's own table was: it goes stale silently. The list that prompted this
    work named four repositories as broken and one as tracked, and named
    correctly only because somebody had run `caf dev` on that laptop and left a
    file behind. Six further repositories had manifests and no ignore entry, and
    a list cannot tell you about a repository that has not been visited yet.

    Reported, not silently dropped, and in three directions:
      - a repository with NO `cafaye.yml` is counted and named in the summary.
        It cannot produce this file, so there is nothing to check — but a count
        is what lets a reader see that the checked population is smaller than
        the fleet rather than guessing.
      - a repository with NO `.git` at all cannot be asked either question, and
        is REPORTED rather than skipped. A repository whose git state cannot be
        read is not a clean repository; it is an unreadable one, and treating
        the two alike is how a check passes by not looking.
      - worktrees are EXCLUDED, and the reason is that a worktree shares its
        repository's history but has its OWN index, so `git ls-files` in one
        answers about the branch checked out there. A worker worktree sitting
        next to a main checkout would otherwise be counted as a second
        repository and reported on for another branch's state. This is the same
        exclusion `fleet_check.py`'s `discover()` makes, and `staleness.py` makes
        a third time — three callers, one rule.

THE REVERSE DIRECTION, and why it is a finding rather than a curiosity
    A repository holding `caf.dev.compose.yaml` with NO `cafaye.yml` is
    reported. The file is generated from a manifest, so its absence means either
    the manifest was deleted — and every consumer of this repository's contract
    now has nothing to read — or the file was committed from somewhere it does
    not belong. Both are worth a human's attention and neither is visible from
    either file alone. `core` reached state 2 of the failure above without
    anybody noticing; a reverse-direction check is cheap and it is the only one
    that would have asked.

WHICH FINDINGS FAIL THE GATE, AND WHY THAT IS A FILE AND NOT A LIST
    The exit status is a question about SCOPE, and the scope decision is a FILE.
    `MVP-SCOPE.md` — one directory above the fleet, in no repository — names the
    repositories held out of the MVP until it is launched and selling. A finding
    in one of those is PRINTED and does not fail.

    Four things about that, and each is a thing that has to be true rather than a
    thing that is usually true:

    - IT IS READ, NEVER WRITTEN DOWN HERE. No repository name appears in this
      file as DATA — `darkroom` and `muse` are named below, and in two comments,
      only to say that neither is here as code. A hand-written frozen list has
      the same defect as the hand-written dirty list this check was written to
      replace, with the opposite polarity: it goes stale silently, and the day
      the scope lifts, the exemptions outlive the decision that granted them — a
      gate that has stopped looking at two repositories without anybody having
      turned it off.
    - THE OUT-OF-SCOPE LIST IS THE ONLY EXEMPTION. A repository the decision
      does not name is BLOCKING, including one it never mentions at all. An
      unmentioned repository has not been granted anything, and reading the
      "in the MVP" table instead would invert the default: the four repositories
      nobody has scoped yet would be the only four exempt.
    - THE DECISION LIVES BESIDE THE FLEET AND IN NO REPOSITORY, because it
      governs dispatch across nine repositories and putting it in one of them
      would make that repository the owner of the others' exemptions. It comes
      in on `--scope`, and the default is the directory above `--repos-dir`,
      which is where a fleet-wide directive lives.
    - AN UNREADABLE DECISION EXEMPTS NOTHING, and says so. See
      `read_out_of_scope` and the `SCOPE-ABSENT:` marker. The exemption is the
      only thing that can turn a finding green, so the state in which it cannot
      be read must not be a state in which it is granted — and the state in
      which it cannot be read must be VISIBLE, because "clean" and "clean
      because frozen" are different facts and a reader is entitled to tell them
      apart. `SCOPE-ABSENT:` is the sibling of `FLEET-ABSENT:` and means
      something different from it in the direction that matters: FLEET-ABSENT
      means nothing was looked at, SCOPE-ABSENT means everything was looked at
      and nothing was forgiven.

WHY IT SKIPS AND DOES NOT PASS WHEN THERE IS NO FLEET
    A clone of kit on CI has no siblings. "No fleet was found" is not "the
    fleet is clean", and a gate that reports the second when it means the first
    is the `unknown` vs `current` confusion `tests/staleness.py` exists to
    avoid. It exits 0 with `--no-fleet` and prints the `FLEET-ABSENT:` marker,
    which is the same machine-readable marker `fleet_check.py` prints and
    `validate.sh` already knows how to read. One marker, one meaning, two
    callers.

EXIT STATUS
    0  every repository IN SCOPE ignores the generated file, none tracks it, and
       none holds one with no manifest to generate it. Findings in repositories
       the scope decision holds frozen are printed and do not change this.
    1  at least one repository IN SCOPE does not ignore the generated file, or
       tracks it, or holds one with no manifest to generate it from. Findings
       that exist only in frozen repositories are not one of these.
    2  bad invocation, or git could not be read for a repository in scope
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

# The one name, in one place, because three things have to agree on it: the
# file `caf dev` writes (`defaultComposeFile`, `caf/internal/cli/dev.go:72`),
# the manifest that produces it, and this check. `dev.go`'s own comment says a
# generated file belongs where a developer can "add it to .gitignore", which is
# this check asserting the other half of that sentence.
GENERATED_STACK_FILE = "caf.dev.compose.yaml"

# The manifest whose presence makes a directory a project at all. Derived from
# the generator rather than invented here — see the module docstring.
MANIFEST_FILE = "cafaye.yml"

# Seconds. `git check-ignore` is a millisecond operation; this is here so a git
# that has stopped answering cannot hang a gate, and so a hung git is a named
# exit code rather than a gate with no verdict.
GIT_TIMEOUT = 30

# THE SCOPE DECISION, by name and by shape. Neither is a promise about its
# contents: `MVP-SCOPE.md` is a directive document a person writes and revises,
# and the two expressions below are what this check needs from it — a heading
# that says which section holds the frozen repositories, and backticked names in
# the prose under it. Everything about it is derived from the file, because a
# list written into this script would be a list this script has to be edited to
# keep true, and the day nobody edits it is the day two repositories stop being
# checked without any event to point at.
SCOPE_FILE_NAME = "MVP-SCOPE.md"

# `## Out of the MVP — do not develop these`. Matched on the words rather than
# the whole line so a rewording of the trailing clause does not silently empty
# the exemption set: it would empty it LOUDLY instead (see `read_out_of_scope`),
# which is the only acceptable direction for a match that has gone stale.
OUT_OF_SCOPE_HEADING = re.compile(r"^##\s+.*out\s+of\s+the\s+mvp", re.IGNORECASE)

# Any `##` heading ends the current section. `###` does not, so a subsection
# under the out-of-scope heading is still part of it.
SECTION_HEADING = re.compile(r"^##\s")

# What the decision's own backticked names have to look like to count as a
# repository: lowercase, and then letters, digits, `-`, `_` or `.`. Deliberately
# shape-only and deliberately example-free — an example would be a real
# repository name sitting in this file one careless edit away from a set. It
# also matches things that are not repository names, which is why the tokens it
# rejects are printed rather than dropped (see `main`) — a parse that silently
# discarded half of what it read would be indistinguishable from a decision that
# named half as much.
BACKTICKED = re.compile(r"`([^`\n]+)`")
REPOSITORY_NAME = re.compile(r"^[a-z0-9][a-z0-9._-]*$")


def is_checkout(path: str) -> bool:
    """Is this directory a repository — or a worktree of one?

    `.git` is a directory in a normal clone and a FILE in a worktree, so both
    count. This is `fleet_check.py`'s predicate and `staleness.py`'s, kept
    identical: three callers, one rule, and a fourth copy would be the first
    place the fleet has a different size depending on which script asked.
    """
    return os.path.isdir(os.path.join(path, ".git")) or os.path.isfile(
        os.path.join(path, ".git")
    )


def is_worktree(path: str) -> bool:
    """Is this a git worktree rather than its own repository?

    Read from the SHAPE of `.git`, not from `git rev-parse`, and this function
    carries the scar of having got that wrong the first time.

    The first version asked `git rev-parse --is-inside-work-tree`, which answers
    `true` for EVERY checkout -- a clone is inside a work tree too, and that is
    the entire meaning of the flag. So it classified all fifteen repositories as
    worktrees, `discover()` returned an empty list, and the gate reported "no
    cafaye repositories under ..." -- which under `--no-fleet` is exit 0 and the
    `FLEET-ABSENT:` marker. It was not a crash and not a red. It was a gate that
    skipped the whole fleet and printed the marker that means "nothing to look at
    here", on the one machine where all five repositories this check was written
    for still carried the defect. A check that examines nothing and says so is
    the failure mode this file exists to prevent, and it would have shipped
    behind a test that only ever asserted a green run.

    A `.git` FILE means a linked worktree; a `.git` DIRECTORY means an ordinary
    clone. That is git's layout rather than a promise, which is why the two fleet
    checks that already enumerate repositories read it the same way
    (`fleet_check.py` and `staleness.py`, each carrying its own copy of this
    reasoning): three callers, one rule, and a fourth copy would be the first
    place the fleet has a different size depending on which script asked.

    It is also free, where `rev-parse` costs a subprocess per repository -- which
    matters for a check that runs on every gate invocation across the fleet.
    """
    marker = os.path.join(path, ".git")
    if not os.path.isfile(marker):
        return False
    try:
        with open(marker, encoding="utf-8") as fh:
            return fh.read(6).strip() == "gitdir"
    except OSError:
        return False


def git(repo: str, *args: str) -> tuple:
    """Run git in `repo`. Returns (exit code, stdout+stderr), never raises.

    Every git call in this file goes through here so that a git which is
    missing, slow, or refuses answers as a non-zero code the caller inspects,
    rather than as a traceback from the middle of a loop over the fleet.
    """
    try:
        proc = subprocess.run(
            ["git", "-C", repo, *args],
            capture_output=True,
            text=True,
            timeout=GIT_TIMEOUT,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, str(exc)
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def ignores_generated_stack(repo: str) -> bool | None:
    """Does git ignore `caf.dev.compose.yaml` here? True / False / None.

    None means git could not answer, and it is deliberately not False: a git
    that failed is not a repository that does not ignore the file, and
    collapsing the two would report a failure nobody can act on as though it
    were a finding.
    """
    code, _ = git(repo, "check-ignore", "-q", GENERATED_STACK_FILE)
    if code == 0:
        return True
    if code == 1:
        return False
    return None


def tracks_generated_stack(repo: str) -> bool | None:
    """Does git's index hold `caf.dev.compose.yaml`? True / False / None.

    `--error-unmatch` rather than matching the output of a bare `ls-files`, so
    the answer is a STATUS and not a string this file has to parse. The status
    is then printed by git itself on failure, which is why stderr is dropped:
    a 1 here means "not tracked", which is the common case, and its message
    ("error: pathspec ... did not match") is noise on every clean repository.
    """
    code, _ = git(repo, "ls-files", "--error-unmatch", "--", GENERATED_STACK_FILE)
    if code == 0:
        return True
    if code == 1:
        return False
    return None


def check_repo(name: str, repo: str) -> list:
    """Every finding about one repository, in the order a reader needs them.

    A TRACKED file produces ONE finding and suppresses the not-ignored one, which
    took a fixture to learn and is the reason this function reads the way it
    does.

    The fact is measured, not remembered: in a repository whose `.gitignore`
    carries `/caf.dev.compose.yaml` and whose index ALSO carries the file,
    `git check-ignore -q caf.dev.compose.yaml` exits **1**. Git does not apply
    ignore rules to a path it is already tracking — the rule governs what `git
    add` will pick up, and this path is not up for picking up. So the first
    version of this function asked both questions independently and reported
    both answers, which on that repository read:

        epsilon: caf.dev.compose.yaml is TRACKED ...
        epsilon: caf.dev.compose.yaml is not ignored. ... Add
                 `/caf.dev.compose.yaml` to .gitignore with the reason beside it.

    The second line asks for something the repository already does, from
    somebody who will go and add it, add it a second time, and conclude the
    check is broken. It is the shape of an unactionable finding, and it is worse
    than a missing one: this finding is the one that names `core`'s actual
    state, and sending the reader off to re-add a line they already wrote is how
    a gate teaches people to skim it.

    So TRACKED is reported ALONE, and its message carries the thing the
    suppressed finding would have said — that the ignore entry is necessary and
    is not sufficient, and that `git rm --cached` is what makes it take effect.
    The order matters and is why the fix is `rm --cached` first: until the path
    leaves the index, `check-ignore` will keep answering "no" about it however
    correct the `.gitignore` is.
    """
    found = []
    tracked = tracks_generated_stack(repo)

    if tracked is None:
        return [
            f"{name}: git could not be read for {GENERATED_STACK_FILE!r} "
            f"(ls-files). Reported rather than skipped: a repository whose index "
            f"cannot be read is not a clean repository, it is an unreadable one."
        ]

    if tracked:
        found.append(
            f"{name}: {GENERATED_STACK_FILE} is TRACKED, which is the worse of the "
            f"two states and does not go away by being ignored. Git applies ignore "
            f"rules only to paths it is not already tracking, so a `.gitignore` "
            f"entry here is necessary and NOT sufficient — `git check-ignore` will "
            f"keep answering 'not ignored' about this path however correct the "
            f"`.gitignore` is, until the path leaves the index. Fix it with "
            f"`git rm --cached {GENERATED_STACK_FILE}`, and read the file first: a "
            f"script, a test or a document that named that path as a checked-in "
            f"file is now wrong, and finding that out is part of the fix rather "
            f"than something after it."
        )
        return found

    ignored = ignores_generated_stack(repo)
    if ignored is None:
        found.append(
            f"{name}: git could not be read for the ignore rules "
            f"(check-ignore). Reported rather than skipped, for the reason above."
        )
    elif not ignored:
        found.append(
            f"{name}: {GENERATED_STACK_FILE} is not ignored. `caf dev` GENERATES it "
            f"from {MANIFEST_FILE} and rewrites it on every run — the file says so "
            f"in its own first line — so it is build output shaped like a source "
            f"file. Untracked and not ignored it is one `git add -A` from being "
            f"committed, and from there it is a merge conflict nobody can resolve "
            f"by reading it, because both sides are generated. Add "
            f"`/{GENERATED_STACK_FILE}` to .gitignore with the reason beside it."
        )

    return found


def check_reverse_direction(name: str, repo: str) -> list:
    """A generated stack file with no manifest to have generated it.

    Reported rather than tolerated. The file is rendered from `cafaye.yml`, so
    its manifest being absent means the manifest was deleted — and every
    consumer of this repository's contract now has nothing to read — or the
    file arrived from somewhere it does not belong. Neither is visible from
    either file alone, and the second is how `core` reached TRACKED in a commit
    about an image reference.
    """
    if os.path.isfile(os.path.join(repo, GENERATED_STACK_FILE)) and not os.path.isfile(
        os.path.join(repo, MANIFEST_FILE)
    ):
        return [
            f"{name}: {GENERATED_STACK_FILE} is present but there is no "
            f"{MANIFEST_FILE}. The file is generated FROM that manifest, so one of "
            f"two things is true: the manifest was deleted and every consumer of "
            f"this repository's contract now has nothing to read, or the file was "
            f"committed from a repository it does not belong to."
        ]
    return []


def discover(repos_dir: str) -> list:
    """Every immediate subdirectory that is a repository, not a worktree.

    `kit` is excluded by name and everything else by `is_worktree`, which is
    `fleet_check.py`'s rule verbatim: a sibling worker worktree is another
    branch's index, and reporting on it as though it were a repository is how a
    gate goes red for a state nobody is in.
    """
    try:
        entries = sorted(os.listdir(repos_dir))
    except OSError as exc:
        raise SystemExit(f"generated_stack_check.py: cannot read {repos_dir}: {exc}")
    found = []
    for entry in entries:
        if entry == "kit" or entry.startswith("kit-worker"):
            continue
        path = os.path.join(repos_dir, entry)
        if not os.path.isdir(path) or not is_checkout(path):
            continue
        if is_worktree(path):
            continue
        found.append(entry)
    return found


def read_out_of_scope(path: str) -> tuple:
    """The frozen repositories this scope decision declares. (exempt, dropped, reason)

    `exempt` is the set of repository names, or None when the decision could not
    be read at all. `reason` says why, and is None exactly when `exempt` is a
    set. `dropped` is the backticked tokens in the out-of-scope section that are
    not repository names — `caf dev`, a file name — kept so the caller can print
    them: a parse that quietly discarded what it did not recognise is a parse
    whose result cannot be checked by reading the output.

    FOUR WAYS THIS CANNOT READ THE DECISION, and every one of them returns None
    rather than an empty set, because "the decision says nothing is frozen" and
    "there is no decision" have to be distinguishable:

      1. THE FILE IS ABSENT, which is a clone of kit with no fleet-wide
         directive beside it. Fail closed: everything is in scope.
      2. THE FILE CANNOT BE READ — permissions, a directory where a file was
         promised. Fail closed, and say THAT rather than "not found", because
         the two are fixed by different people.
      3. THERE IS NO OUT-OF-SCOPE SECTION. This is the interesting one, because
         it is what a REWORDED directive looks like: the document is right there
         and this check cannot find the part it needs. Returning an empty set
         would be the fail-open direction wearing a success's clothing — the gate
         would go red on two repositories the decision froze, and the reader
         would be told the decision named nothing rather than told this parse
         could not find it.
      4. THE SECTION NAMES NOTHING RECOGNISABLE. Same reasoning, and it is the
         case a check written against one document's exact formatting always
         eventually hits.

    The section is located by its heading and read to the next `##`, which is
    what makes "derive from the file" mean something: a rewrite that moves the
    section, renames the heading's trailing clause or reformats the list keeps
    working, and only a rewrite that changes the SENTENCE this check keys on
    stops it — and stops it loudly.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        return None, [], "no such file"
    except OSError as exc:
        return None, [], f"unreadable ({exc.strerror or exc})"

    found = False
    inside = False
    body: list = []
    for line in lines:
        if SECTION_HEADING.match(line):
            inside = bool(OUT_OF_SCOPE_HEADING.match(line))
            found = found or inside
            continue
        if inside:
            body.append(line)

    if not found:
        return None, [], "it carries no `## ... Out of the MVP ...` section"

    tokens = [m.group(1).strip() for m in BACKTICKED.finditer("\n".join(body))]
    exempt = {t for t in tokens if REPOSITORY_NAME.match(t)}
    dropped = sorted({t for t in tokens if t not in exempt})
    if not exempt:
        return None, dropped, "its out-of-scope section names no repository this read as a name"
    return exempt, dropped, None


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(
        prog="generated_stack_check.py",
        description="Gate the fleet on not committing the file `caf dev` generates.",
    )
    parser.add_argument("--repos-dir", default=None,
                        help="directory holding one checkout per cafaye repository")
    parser.add_argument(
        "--scope",
        default=None,
        help=f"the scope decision naming the repositories that are frozen "
             f"(default: ../{SCOPE_FILE_NAME}, the directory above --repos-dir). "
             f"A repository it does not name is IN scope, and fails this gate.",
    )
    parser.add_argument("--no-fleet", action="store_true",
                        help="accept that there is no fleet (exit 0 with a note)")
    args = parser.parse_args(argv)

    repos_dir = os.path.abspath(
        args.repos_dir or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
    )
    # The default is DERIVED from --repos-dir rather than from this file's own
    # location, so a caller who points the check at another fleet gets that
    # fleet's decision rather than this checkout's — and so the two flags cannot
    # disagree about which tree is being gated.
    scope_path = os.path.abspath(
        args.scope or os.path.join(os.path.dirname(repos_dir), SCOPE_FILE_NAME)
    )
    frozen_by_decision, dropped_names, scope_reason = read_out_of_scope(scope_path)
    names = discover(repos_dir)

    if not names:
        if args.no_fleet:
            print(f"FLEET-ABSENT: no cafaye repository under {repos_dir}")
            return 0
        raise SystemExit(
            f"generated_stack_check.py: no cafaye repositories under {repos_dir}. "
            f"Pass --repos-dir, or --no-fleet to accept it."
        )

    # Findings as (repository, message) rather than as a flat list of strings, so
    # the partition below never has to parse a name back out of prose it wrote.
    problems: list = []
    checked = 0
    # The three populations, counted separately so the summary can be read as a
    # claim about the fleet rather than as a number with no denominator. A gate
    # that says "0 problems" without saying how many repositories it looked at
    # has told the reader nothing, which is the "a skip nobody can see is a
    # silent pass" failure this repository keeps naming.
    no_manifest = 0
    in_scope = []
    for name in names:
        repo = os.path.join(repos_dir, name)
        # The scope predicate, read off the filesystem. It is the same one
        # `caf dev` uses to decide a directory is a project at all, so the
        # population here cannot drift from the population that writes the file.
        if not os.path.isfile(os.path.join(repo, MANIFEST_FILE)):
            no_manifest += 1
            # The reverse direction is checked for the repositories that are OUT
            # of scope, because holding the generated file without the manifest
            # is precisely the case the scope rule excludes.
            problems.extend((name, m) for m in check_reverse_direction(name, repo))
            continue
        in_scope.append(name)
        problems.extend((name, m) for m in check_repo(name, repo))
        problems.extend((name, m) for m in check_reverse_direction(name, repo))
        checked += 1

    # THE PARTITION, and it is the whole correction. Detection is unchanged and
    # stays unconditional: every repository is asked the same two questions and
    # every answer is printed. What the scope decision changes is which findings
    # the EXIT STATUS counts — and the two lists are printed under separate
    # headings, so no reader can mistake a frozen finding for a suppressed one.
    #
    # The exempt set is `frozen_by_decision`, which is None whenever the decision
    # could not be read. `name in None` is False for every name, so an unreadable
    # decision puts every finding in the blocking list — and that is the intended
    # behaviour rather than an accident of the expression: the alternative is a
    # gate that forgives everything on the machines where nobody could say who
    # forgave what.
    blocking = [p for p in problems if p[0] not in (frozen_by_decision or ())]
    frozen = [p for p in problems if p[0] in (frozen_by_decision or ())]
    frozen_repos = sorted({n for n, _ in frozen})

    summary = (
        f"{checked} of {len(names)} repository(ies) have a {MANIFEST_FILE} and were "
        f"checked for {GENERATED_STACK_FILE}"
    )
    if no_manifest:
        summary += (
            f"; {no_manifest} have none, cannot produce the file, and were counted "
            f"rather than dropped"
        )
    # stdout, always, and this is a change: the summary used to move to stderr
    # when there were problems, so the two lines a reader needs in order to
    # interpret a verdict — how many repositories, and what scope applied to
    # them — were split across two streams by a rule nobody chose deliberately.
    print(summary)

    # THE SCOPE, stated on every run whether or not anything was found, because
    # its absence is what makes "clean" ambiguous: a run that found nothing and
    # had no decision to compare against has proved less than a run that found
    # nothing with one.
    if frozen_by_decision is None:
        print(
            f"SCOPE-ABSENT: no scope decision was read from {scope_path} — "
            f"{scope_reason} — so NO repository is exempt and every finding below is "
            f"blocking. The frozen set is read from that file and is never written into "
            f"this script; pass --scope <path>, or set KIT_SCOPE_FILE, where a decision "
            f"exists."
        )
    else:
        present = sorted(n for n in frozen_by_decision if n in names)
        print(
            f"SCOPE-READ: {scope_path} holds {len(frozen_by_decision)} repository(ies) "
            f"out of scope until the MVP is launched and selling, and "
            f"{len(present)} of the {len(frozen_by_decision)} are in this fleet: "
            f"{', '.join(present) if present else '(none of them)'}. A finding in one "
            f"of those is printed and does NOT fail this gate. Nothing else is exempt — "
            f"a repository the decision does not name is blocking, including one it "
            f"never mentions at all."
        )
    if dropped_names:
        print(
            f"SCOPE-NOT-NAMES: {len(dropped_names)} backticked token(s) in that section "
            f"are not repository names and were read as prose, not as exemptions: "
            f"{', '.join(dropped_names)}"
        )

    # FLUSH before anything reaches stderr. validate.sh captures `2>&1` into a
    # variable, which makes stdout block-buffered, so without this the summary
    # and the scope line — the two lines a verdict has to be read against —
    # arrive AFTER the verdict that uses them.
    sys.stdout.flush()

    if blocking:
        print(f"BLOCKING: {len(blocking)} finding(s) below — every one of them fails "
              f"this gate:", file=sys.stderr)
    for finding in blocking:
        print(f"  - {finding[1]}", file=sys.stderr)
    if frozen:
        print(
            f"FROZEN-FINDINGS: {len(frozen)} ({', '.join(frozen_repos)}) are reported "
            f"below and do NOT fail this gate, because the scope decision holds those "
            f"repositories out of the MVP until it is launched and selling and nobody "
            f"is permitted to fix them today. They are printed because they are true "
            f"and worth knowing, not because they can be acted on now: a defect nobody "
            f"may fix still gets fixed the day the scope lifts, and the only way that "
            f"day is cheap is if it was written down before it.",
            file=sys.stderr,
        )
        for finding in frozen:
            print(f"  - {finding[1]}", file=sys.stderr)

    if blocking:
        also = (
            f", and {len(frozen)} further finding(s) in frozen repositories that do not "
            f"count against it"
            if frozen
            else ""
        )
        print(
            f"FAIL generated-stack: {len(blocking)} blocking problem(s) across the "
            f"fleet{also}. {GENERATED_STACK_FILE} is build output: `caf dev` renders it "
            f"from {MANIFEST_FILE} and rewrites it on every run. A repository that has "
            f"never heard of kit's stack still must not commit its generated one — "
            f"unlike the adoption debt `fleet_check.py` names, this defect has no "
            f"adopter and no wave that makes it acceptable.",
            file=sys.stderr,
        )
        return 1

    if frozen:
        # NOT the sentence below, and the difference is the whole correction: the
        # existing PASS line asserts that EVERY repository with a manifest ignores
        # the file, and it would be saying that about darkroom and muse, which do
        # not. A green that overstates what was checked is the false green this
        # line exists instead of.
        print(
            f"PASS generated-stack: no repository the scope decision leaves in scope "
            f"commits the file `caf dev` generates. {len(frozen)} finding(s) in frozen "
            f"repositories ({', '.join(frozen_repos)}) are printed above and do not "
            f"fail this gate. Checked {len(in_scope)}: "
            f"{', '.join(in_scope) if in_scope else '(none)'}."
        )
        return 0

    print(
        f"PASS generated-stack: every repository with a {MANIFEST_FILE} ignores "
        f"{GENERATED_STACK_FILE}, none tracks it, and none holds one with no "
        f"manifest to have generated it. Checked {len(in_scope)}: "
        f"{', '.join(in_scope) if in_scope else '(none)'}."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))