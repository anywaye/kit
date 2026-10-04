#!/usr/bin/env python3
"""account_scope_fleet_check.py — the gate that makes the account-scope contract continuous.

    python3 tests/account_scope_fleet_check.py
    python3 tests/account_scope_fleet_check.py --baseline
    python3 tests/account_scope_fleet_check.py --only pantry
    python3 tests/account_scope_fleet_check.py --repos-dir /path/to/fleet

WHAT THIS IS, AND WHY IT IS NOT core's CI

    Six services in this fleet declare their account-scoped surface in an
    `account_scope.yml`, and `core/harness/account_scope_check.py` is the tool
    that decides whether the declaration still describes the code. Measured:

        cd /Users/kaka/Code/any/moon/cafaye && grep -rln "account_scope_check" \\
            --include="*.sh" --include="*.yml" --include="Makefile" --include="*.exs" . \\
          | grep -v "^./core/harness" | grep -v wt-m39
          -> pantry/account_scope.yml
             courier/account_scope.yml
             guard/account_scope.yml
             core/.github/workflows/ci.yml
             core/harness/tests/account_scope_self_test.sh

    Every hit is either a declaration *mentioning* the tool, or `core` running
    its own SELF-TEST over its own fixtures. `core/.github/workflows/ci.yml`
    runs `harness/tests/account_scope_self_test.sh` and reads that log — it
    proves the CHECKER can fail, which is a different question from whether any
    service's own declaration is checked. Not one service runs the checker
    against itself, so the contract is continuous in nobody's build: a service
    can add a route, widen a declaration, or delete `account_scope.yml` entirely
    and its own gate stays green. That is `DEBT.md` D18's shape one level up
    from where D18 has been looking, and the failure has a name in this
    repository's own history — "the gate that did not run the proof".

    So this file runs the checker against every repository the scope decision
    puts in the MVP, records what it found, and fails on any difference between
    what it found and what `account_scope_fleet_ratchet.yml` says it should
    find. The recording is the point. There is no mode in which a service's
    declaration is checked and the answer is not written down somewhere a later
    commit can be diffed against.

WHY IT REPLACES THE FIVE-FUNCTION ADAPTER CONTRACT INSTEAD OF EXTENDING IT

    `tests/tenant_isolation/cross_tenant_harness.sh` defines five adapter
    functions — `adapter_install_probe`, `adapter_language_tool`,
    `adapter_migrate`, `adapter_prepare`, `adapter_run` — and that contract is
    right for what it drives. Each name answers a question about RUNNING A
    SERVICE: is the toolchain here, does it compile, are the rows loaded, is the
    binary built, does `go test` pass. Four of the five are about a live
    Postgres.

    There is no service to run here. The checker reads a YAML file and a set of
    source files and exits; it does not compile, migrate, seed or connect to
    anything. A harness built on that contract could express "run courier's
    tests against Postgres" and could not express "run a declaration checker
    against nine directories". So this is a program that does the thing and says
    why the other contract does not fit, rather than five adapter names one of
    which returns the fleet's own exit code.

    WHAT IS KEPT FROM THE HARNESS IS THE DISCIPLINE, not the shape: a run that
    could not happen exits non-zero and never reports a pass. `up`/`run`/`down`
    is not here because there is nothing to bring up and nothing to tear down.

THE CONTRACT, and it is five rules rather than one

    1. CONTINUITY. A repository that declares a surface and stops declaring one
       is red. Deleting `account_scope.yml` is the move this rule exists for and
       it is invisible to the checker alone: run it against a repository with no
       declaration and it reports `declaration-missing`, which reads as a finding
       about a service that never opted in. The runner knows the difference,
       because it reads the repository's own git HEAD.
    2. ENTRY. A repository the scope decision puts in the MVP that has never
       declared a surface is red, unless it is named in the ratchet's `exempt:`
       with a condition that ends the exemption.
    3. PROPAGATION. The checker's own exit code and its four counts are reported
       for every repository, and every `fail` finding is this gate's finding.
    4. THE RECORDED STATE IS EXACT AND BOTH-DIRECTIONAL. Every in-scope
       repository carries a row in `account_scope_fleet_ratchet.yml` recording
       its exit code, its four counts, its warning tally and its blindnesses. Any
       difference in EITHER direction is red — a repository that got worse, and a
       repository that got better and whose row nobody retired. A list of
       suppressions cannot do the second half, which is why this file is not one.
    5. BLINDNESS IS AN ERROR. A run that cannot distinguish "this repository is
       clean" from "this runner read nothing" is red. See THE BLINDNESS RULES.

EXIT STATUS

    0  every in-scope repository matches its recorded row exactly
    1  a difference, in either direction, or a row the tree no longer needs
    2  the runner could not run: no fleet, no scope decision, no checker, no
       repository parsed out of the scope decision, an unreadable ratchet, or an
       instrument that would not speak JSON. NEVER 0. An unknown reported as a
       pass is the defect this file exists to remove, so the first thing it does
       on an unreadable input is say which input it could not read.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

import yaml

# --------------------------------------------------------------------------
# constants, and where each one came from
# --------------------------------------------------------------------------

SCOPE_FILE_NAME = "MVP-SCOPE.md"

#: The heading whose table is the in-scope list. Matched on the words rather
#: than the whole line, so a reworded directive still parses and only a rewrite
#: that changes the SENTENCE stops this — and stops it LOUDLY, because
#: `read_in_scope` raises rather than returning an empty list for that case.
#: "the decision names nothing in scope" and "this parse could not find the
#: table" have to be distinguishable, or the fail-open direction wears a
#: success's clothing.
IN_SCOPE_HEADING = r"^##\s+In the MVP\b"
ANY_HEADING = r"^##\s"

#: One row of that table: `| **identity** | MVP service. … |`. The name is
#: required to be BOLD, because the same document carries other tables and a
#: pattern loose enough to read those would answer a different question.
IN_SCOPE_ROW = r"^\|\s*\*\*([A-Za-z0-9][A-Za-z0-9_-]*)\*\*\s*\|"

#: The checker, relative to the fleet root. It lives in `core`, which is in the
#: MVP, which is why the fleet root and the instrument travel together: a gate
#: that could not find its instrument would have to be told where it is.
CHECKER_RELPATH = os.path.join("core", "harness", "account_scope_check.py")

#: `core`'s own exit codes, read out of its `EXIT_*` block rather than
#: remembered: 0 no `fail` finding, 1 a `fail` finding, 2 it could not run.
EXIT_OK = 0
EXIT_FAIL = 1
EXIT_COULD_NOT_RUN = 2

#: `kit`'s SKIP_EXIT (sysexits.h EX_CONFIG), so a missing fleet is a SKIP in
#: `tests/validate.sh` rather than a FAIL that blames the tree for the machine.
#: A CI runner legitimately has no fleet beside it, and the runner's own exit 2
#: is what a direct invocation gets. Neither is 0, which is the part that matters.
EXIT_CONFIG = 78

#: The checker's four enumerated states plus its two tallies. This list is the
#: vocabulary the ratchet counts in, so a ratchet row and a printed row are the
#: same numbers read twice rather than two sets of numbers that can disagree.
COUNT_KEYS = (
    "account-scoped",
    "not-account-scoped",
    "stale",
    "undeclared",
    "failures",
    "warnings",
)

#: This runner's own findings, and they are prefixed `fleet.` so one grep of a
#: log separates what this file is responsible for from what it imported.
FLEET = "fleet."

#: The blindness identifiers, as the ratchet spells them — without the prefix.
BLIND_PROVED_NOTHING = "proved-nothing"
BLIND_SURFACE = "surface-blind"
BLIND_HISTORY = "history-unreadable"


class CouldNotRun(Exception):
    """The runner cannot answer the question it was asked. Always exit 2."""


# --------------------------------------------------------------------------
# reading the inputs
# --------------------------------------------------------------------------


def read_in_scope(path: str) -> list:
    """The repositories the scope decision puts in the MVP.

    Four ways this cannot read the decision, and every one of them raises rather
    than returning an empty list, because an empty list here means "the fleet
    proved everything, vacuously" — the most expensive green available:

      1. the file is absent — a clone of kit with no fleet-wide directive beside
         it. Fail closed.
      2. the file is unreadable. Fail closed, and say THAT, because the two are
         fixed by different people.
      3. there is no `## In the MVP …` section. This is what a REWORDED
         directive looks like: the document is right there and this parse cannot
         find the part it needs.
      4. the section holds no bolded repository row. Same reasoning.

    The section is read to the next `##`, which is what makes "derive from the
    file" mean something: a rewrite that moves the table or reformats the list
    keeps working.
    """
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except FileNotFoundError:
        raise CouldNotRun(f"no scope decision at {path}")
    except OSError as exc:
        raise CouldNotRun(f"scope decision unreadable at {path} ({exc.strerror or exc})")

    found = False
    inside = False
    body: list = []
    for line in lines:
        if re.match(ANY_HEADING, line):
            if found:
                break
            inside = bool(re.match(IN_SCOPE_HEADING, line))
            found = found or inside
            continue
        if inside:
            body.append(line)

    if not found:
        raise CouldNotRun(f"{path} carries no `## ... In the MVP ...` section")
    names = [match.group(1) for match in
             (re.match(IN_SCOPE_ROW, line) for line in body) if match]
    if not names:
        raise CouldNotRun(
            f"the in-scope table in {path} holds no bolded repository row, so this parse "
            f"read no repository as in scope"
        )
    return names


def scope_fingerprint(names: list) -> str:
    """sha256 of the in-scope table, for the vendored copy to be checked against."""
    return hashlib.sha256("\n".join(names).encode("utf-8")).hexdigest()


def read_yaml(path: str, what: str) -> dict:
    """Load one YAML document, raising `CouldNotRun` rather than defaulting."""
    try:
        with open(path, encoding="utf-8") as handle:
            document = yaml.safe_load(handle)
    except FileNotFoundError:
        raise CouldNotRun(f"no {what} at {path}")
    except OSError as exc:
        raise CouldNotRun(f"{what} unreadable at {path} ({exc.strerror or exc})")
    except yaml.YAMLError as exc:
        raise CouldNotRun(
            f"{what} is not a YAML document this runner can read: {path} ({exc})")
    if document is None:
        return {}
    if not isinstance(document, dict):
        raise CouldNotRun(f"{what} is not a mapping: {path}")
    return document


def read_declaration_surface(repo: str) -> tuple:
    """`(minimum, sources)` out of a service's own `account_scope.yml`.

    A THIRD reader of this document, and recorded as a cost rather than hidden:
    `core`'s checker reads it to judge routes, and this reads two fields to judge
    the INSTRUMENT. It is worth one reader because the blindness rule below needs
    to know what the declaration claims the checker can see, and the checker's
    JSON does not carry that.

    `(None, [])` means "there is no declaration", which is a state and not an
    error. A declaration that exists but whose `surface:` block cannot be read
    raises, because "the instrument reads nothing" and "this runner could not
    read what the instrument reads" must not be the same answer.
    """
    path = os.path.join(repo, "account_scope.yml")
    if not os.path.isfile(path):
        return None, []
    document = read_yaml(path, "account_scope.yml")
    surface = document.get("surface")
    if not isinstance(surface, dict):
        raise CouldNotRun(
            f"{path} declares no `surface:` mapping, so nothing here can say what its "
            f"checker is able to see")
    minimum = surface.get("minimum")
    if minimum is None:
        raise CouldNotRun(
            f"{path} declares no `surface.minimum`, so the number of registrations it "
            f"expects the checker to see is unknown"
        )
    if not isinstance(minimum, int) or isinstance(minimum, bool):
        raise CouldNotRun(f"{path}: `surface.minimum` is not an integer")
    sources = surface.get("sources") or []
    if not isinstance(sources, list) or not all(isinstance(item, str) for item in sources):
        raise CouldNotRun(f"{path}: `surface.sources` is not a list of paths")
    return minimum, sources


# --------------------------------------------------------------------------
# one repository, one run
# --------------------------------------------------------------------------


def run_checker(interpreter: str, checker: str, repo: str) -> tuple:
    """`(exit code, report)` from `core`'s checker over one repository."""
    try:
        completed = subprocess.run(
            [interpreter, checker, "--json", repo],
            capture_output=True, text=True, check=False, timeout=300,
        )
    except FileNotFoundError:
        raise CouldNotRun(f"no python3 at {interpreter} to run the checker with")
    except subprocess.TimeoutExpired:
        raise CouldNotRun(f"the checker did not finish on {repo} within 300s")
    if not completed.stdout.strip():
        raise CouldNotRun(
            f"the checker emitted nothing on {repo} and exited {completed.returncode}; "
            f"its own words: {completed.stderr.strip()[:400]}")
    try:
        report = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise CouldNotRun(
            f"the checker exited {completed.returncode} on {repo} without emitting JSON "
            f"this runner can read ({exc}); its own words: {completed.stderr.strip()[:400]}")
    return completed.returncode, report


def head_declares(repo: str) -> bool:
    """Whether this repository's own git HEAD carries an `account_scope.yml`.

    Read from git rather than from a list this file keeps, because a list this
    file keeps is a second copy of the fleet's shape and would rot exactly the
    way the declarations would have.

    `None` means "this runner could not derive the answer" — no `.git`, no `git`
    on PATH, or a git error that is not "the path does not exist in that commit".
    It is deliberately NOT `False`: an unverifiable continuity rule is not a
    satisfied one, and rule 1 of the contract is worth nothing without this
    answer.
    """
    if not os.path.exists(os.path.join(repo, ".git")):
        return None
    try:
        completed = subprocess.run(
            ["git", "-C", repo, "cat-file", "-e", "HEAD:account_scope.yml"],
            capture_output=True, text=True, check=False, timeout=60,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if completed.returncode == 0:
        return True
    # git exits 128 for "path does not exist in that commit" and for a broken
    # repository, and this runner cannot tell those apart from the exit code
    # alone — so the stderr word is checked too, and anything else is `None`.
    if completed.returncode == 128 and "does not exist" in completed.stderr:
        return False
    return None


class Finding:
    """One thing that is wrong, with the repository it belongs to."""

    def __init__(self, repo: str, identifier: str, message: str, severity: str = "fail"):
        self.repo = repo
        self.id = identifier
        self.message = message
        self.severity = severity


def check_one(name: str, repo: str, interpreter: str, checker: str) -> dict:
    """Measure one repository and return its row and this runner's findings."""
    findings: list = []
    exit_code, report = run_checker(interpreter, checker, repo)

    if report.get("couldNotRun"):
        raise CouldNotRun(f"{name}: the checker reports it could not run: "
                          f"{report['couldNotRun']}")
    if exit_code == EXIT_COULD_NOT_RUN:
        raise CouldNotRun(
            f"{name}: the checker exited {EXIT_COULD_NOT_RUN}, which means 'could not run'")

    counts = dict(report.get("counts") or {})
    for key in COUNT_KEYS:
        counts.setdefault(key, 0)

    imported: list = []
    for item in report.get("findings") or []:
        imported.append({
            "id": item.get("id", "?"),
            "severity": item.get("severity", "fail"),
            "message": item.get("message", ""),
        })

    minimum, sources = read_declaration_surface(repo)
    declares_here = minimum is not None
    present_sources = [item for item in sources if os.path.isfile(os.path.join(repo, item))]

    # ---------------------------------------------------------------- the
    # blindness rules. Each is an ERROR or a COUNTED WARNING, never a pass, and
    # each is about the same sentence: a run that cannot distinguish "this
    # repository is clean" from "this runner read nothing" has proved nothing.

    # B1 proved-nothing. The checker attributed NO entry point to a live
    #    registration anywhere. `0 failures, 0 warnings` over zero enumerated
    #    rows is byte-identical to a checker pointed at an empty directory, and
    #    it exits 0. This is the plant in the report: emptying the instrument's
    #    view of a real service leaves a green gate over a service whose surface
    #    is no longer declared at all.
    attributed = counts["account-scoped"] + counts["not-account-scoped"] + counts["undeclared"]
    if declares_here and attributed == 0:
        findings.append(Finding(
            name, FLEET + "blind." + BLIND_PROVED_NOTHING,
            "the checker attributed no entry point to a registration anywhere in this "
            "repository, so its exit code is a statement about a surface it never read. "
            "This is a passing run of an instrument with nothing under it."))

    # B2 surface-blind. The declaration itself says the instrument reads none of
    #    the surface it names. `pantry` is the live instance and its own file
    #    states the number honestly (`minimum: 0`), which is why this rule reads
    #    the declaration rather than trying to second-guess it.
    if declares_here and minimum == 0 and present_sources:
        findings.append(Finding(
            name, FLEET + "blind." + BLIND_SURFACE,
            f"the declaration sets `surface.minimum: 0` while naming "
            f"{len(present_sources)} source file(s) that exist, so it asserts that the "
            f"checker sees none of them. A checker's `0 undeclared` over a surface it "
            f"cannot read is not a pass."))

    # B3 history-unreadable. Rule 1 of the contract is unverifiable here. It is
    #    an error because "I could not check the thing I exist to check" and "the
    #    thing I check is fine" must not be the same exit code.
    in_head = head_declares(repo)
    if in_head is None:
        findings.append(Finding(
            name, FLEET + "blind." + BLIND_HISTORY,
            "this repository's git history could not be read, so this runner cannot tell a "
            "declaration that was never written from one that was deleted. Rule 1 of the "
            "contract is unverifiable here, and an unverifiable rule is not a pass."))

    # B4 unreadable-rows. A WARNING, and counted rather than passed over: the
    #    checker says out loud, per row, that it could not resolve the code
    #    behind a declaration. The ratchet records the tally exactly, so a new
    #    unreadable row is red on the next run and today's stay visible.
    unreadable = sum(1 for item in imported
                     if item["id"] == "account-scope.contradiction-unreadable")
    if unreadable:
        findings.append(Finding(
            name, FLEET + "blind.unreadable-rows",
            f"{unreadable} declared row(s) report `account-scope.contradiction-"
            f"unreadable`: the checker could not resolve the code behind them, so those "
            f"rows were neither verified nor refuted.", severity="warn"))

    # B5 empty-scope is checked once, fleet-wide, in `main`: it is not a
    #    per-repository property, and printing it nine times would make it look
    #    like nine findings rather than one.

    # ---------------------------------------------------------------- the
    # contract rules.

    if declares_here and in_head is False:
        findings.append(Finding(
            name, FLEET + "declaration-uncommitted",
            "an account_scope.yml is present in the tree and absent from this repository's "
            "HEAD. The continuity rule reads the committed state, so commit it before "
            "asking this gate to agree.", severity="warn"))
    if not declares_here and in_head is True:
        findings.append(Finding(
            name, FLEET + "declaration-dropped",
            "account_scope.yml is in this repository's HEAD and not in its tree: the "
            "surface stopped being declared and nothing failed until now. The checker "
            "alone reports this repository as one that never opted in, which is how a "
            "deleted contract reads as an absent one."))

    # Imported findings carry `core`'s own severity, so a ratchet row records what
    # the checker said rather than a flattened summary of it.
    for item in imported:
        findings.append(Finding(name, item["id"], item["message"], item["severity"]))

    if exit_code == EXIT_OK and any(item["severity"] == "fail" for item in imported):
        findings.append(Finding(
            name, FLEET + "checker-inconsistent",
            f"the checker exited {EXIT_OK} while reporting "
            f"{sum(1 for i in imported if i['severity'] == 'fail')} `fail` finding(s)"))

    return {
        "repo": name,
        "exit": exit_code,
        "counts": counts,
        "declared": declares_here,
        "in_head": in_head,
        "minimum": minimum,
        "sources": sources,
        "present_sources": present_sources,
        "unreadable": unreadable,
        "findings": findings,
    }


# --------------------------------------------------------------------------
# the record: one row per in-scope repository, exactly
# --------------------------------------------------------------------------


def load_record(path: str) -> dict:
    """`account_scope_fleet_ratchet.yml` — the fleet's recorded state.

    Two lists with the same shape, because a reader should not have to learn two
    dialects to check a fleet:

      `fleet:`   one row per in-scope repository, recording `exit`, `counts`,
                 `warnings`, `failures` and `blind`. A row may tolerate nothing;
                 most do.
      `exempt:`  repositories in scope that have never declared a surface. Each
                 forgives `account-scope.declaration-missing` and NOTHING else.

    EVERY LOAD-TIME RULE below refuses the file rather than the run, because a
    record that cannot be read is not a record that says everything is fine:

      * a row with no repository name, or a name this parser will not accept;
      * the same repository in both lists, or twice in one list;
      * a row that tolerates a failure or a blindness and carries no
        `condition:` — a tolerance with no stated end is a switch;
      * a row with a `condition:` that is not a string;
      * a `counts:` block missing one of the six keys, or carrying one this
        checker does not emit — so a typo cannot read as "not recorded";
      * `failures:`/`warnings:`/`blind:` of the wrong shape.
    """
    document = read_yaml(path, "account-scope record")

    rows: dict = {}
    for key, is_exempt in (("fleet", False), ("exempt", True)):
        entries = document.get(key) or []
        if not isinstance(entries, list) or not all(isinstance(item, dict) for item in entries):
            raise CouldNotRun(f"{path}: `{key}:` is not a list of mappings")
        for entry in entries:
            name = entry.get("repo")
            if not isinstance(name, str) or not name or not name.replace("-", "").isalnum():
                raise CouldNotRun(
                    f"{path}: a `{key}:` row names no repository this read as a name ({name!r})")
            if name in rows:
                raise CouldNotRun(
                    f"{path}: {name} appears twice in the record. One repository, one "
                    f"statement about what it is expected to report, so a reader is never "
                    f"left choosing.")
            failures = {str(k): int(v) for k, v in (entry.get("failures") or {}).items()}
            blind = [str(item) for item in (entry.get("blind") or [])]
            warns = {str(k): int(v) for k, v in (entry.get("warnings") or {}).items()}
            counts = entry.get("counts")
            if counts is None:
                raise CouldNotRun(f"{path}: the `{key}:` row for {name} records no `counts:`")
            if not isinstance(counts, dict):
                raise CouldNotRun(f"{path}: `counts:` for {name} is not a mapping")
            missing = [item for item in COUNT_KEYS if item not in counts]
            if missing:
                raise CouldNotRun(
                    f"{path}: `counts:` for {name} is missing {', '.join(missing)}")
            unknown = [item for item in counts if item not in COUNT_KEYS]
            if unknown:
                raise CouldNotRun(
                    f"{path}: `counts:` for {name} carries {', '.join(sorted(unknown))}, "
                    f"which this checker does not emit")
            if (failures or blind) and not str(entry.get("condition") or "").strip():
                raise CouldNotRun(
                    f"{path}: the `{key}:` row for {name} tolerates "
                    f"{len(failures)} failure(s) and {len(blind)} blindness(es) and carries "
                    f"no `condition:`. A tolerance with no stated end is a switch, not a "
                    f"ratchet.")
            rows[name] = {
                "repo": name,
                "exempt": is_exempt,
                "exit": entry.get("exit"),
                "counts": {key_: int(counts[key_]) for key_ in COUNT_KEYS},
                "warnings": warns,
                "failures": failures,
                "blind": sorted(blind),
                "condition": str(entry.get("condition") or "").strip(),
                "note": str(entry.get("note") or "").strip(),
            }
    return {"rows": rows, "path": path}


def compare(row: dict, recorded: dict) -> list:
    """Every difference between one measured repository and its recorded row."""
    name = row["repo"]
    notes: list = []

    if recorded["exit"] is not None and int(recorded["exit"]) != int(row["exit"]):
        notes.append(f"records exit={recorded['exit']} and the checker exited {row['exit']}")

    for key in COUNT_KEYS:
        want = recorded["counts"][key]
        have = int(row["counts"].get(key, 0))
        if want != have:
            notes.append(f"records {key}={want} and the run measured {have}")

    # Findings, tallied by (id, severity). Both directions, which is the property
    # that separates this from a list of suppressed identifiers: a repository
    # that got BETTER and whose row nobody retired is as red as one that got
    # worse.
    have: dict = {}
    for item in row["findings"]:
        key = f"{item.id}/{item.severity}"
        have[key] = have.get(key, 0) + 1

    # An exemption forgives a MISSING DECLARATION and nothing else, because that
    # is what was granted for it.
    forgiven = "account-scope.declaration-missing"
    for key, count in sorted(have.items()):
        identifier, _, severity = key.rpartition("/")
        want = (recorded["failures"] if severity == "fail" else recorded["warnings"]).get(
            identifier, 0)
        if recorded["exempt"] and severity == "fail" and identifier == forgiven:
            want = count  # the exemption, and nothing else in this list
        if count != want:
            notes.append(
                f"records {identifier} ({severity}) x{want} and the run found it x{count}")
    for identifier, count in sorted(recorded["failures"].items()):
        if f"{identifier}/fail" not in have and not (
                recorded["exempt"] and identifier == forgiven):
            notes.append(f"records failure {identifier} x{count} and this run did not report it")
    for identifier, count in sorted(recorded["warnings"].items()):
        if f"{identifier}/warn" not in have:
            notes.append(
                f"records warning {identifier} x{count} and this run did not report it")

    have_blind = sorted({
        item.id[len(FLEET + "blind."):] for item in row["findings"]
        if item.severity == "fail" and item.id.startswith(FLEET + "blind.")})
    if have_blind != recorded["blind"]:
        notes.append(f"records blind {recorded['blind']} and this run reported {have_blind}")

    if recorded["exempt"] and row["declared"]:
        notes.append(
            "is exempt as a repository that has never declared, and now HAS a declaration. "
            "The exemption was a hole through which nothing was checked; delete it.")

    return notes


# --------------------------------------------------------------------------
# printing
# --------------------------------------------------------------------------

HEADER = (f"{'repo':<10} {'exit':>4}  {'scoped':>6} {'not-scp':>7} {'stale':>5} "
          f"{'undcl':>5} {'fails':>5} {'warns':>5} {'blind':>5}  state")


def render_table(rows: list) -> list:
    out = [HEADER]
    for row in rows:
        blind = sum(
            1 for item in row["findings"]
            if item.severity == "fail" and item.id.startswith(FLEET + "blind."))
        counts = row["counts"]
        out.append(
            f"{row['repo']:<10} {row['exit']:>4}  {counts['account-scoped']:>6} "
            f"{counts['not-account-scoped']:>7} {counts['stale']:>5} "
            f"{counts['undeclared']:>5} {counts['failures']:>5} {counts['warnings']:>5} "
            f"{blind:>5}  {row['state']}")
    return out


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main(argv: list) -> int:
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser(
        prog="account_scope_fleet_check.py",
        description="Run core's account-scope checker over every repository the scope "
                    "decision puts in the MVP, and fail on any difference from the "
                    "recorded state.")
    parser.add_argument("--repos-dir", default=None,
                        help="directory holding one checkout per cafaye repository "
                             "(default: the directory above this one)")
    parser.add_argument("--scope", default=None,
                        help=f"the scope decision naming what is in the MVP "
                             f"(default: {SCOPE_FILE_NAME} above the fleet root)")
    parser.add_argument("--scope-table", default=None,
                        help="kit's vendored copy of the in-scope table, for a machine "
                             "that has no scope decision beside it. Checked against "
                             "`--scope` whenever that is readable.")
    parser.add_argument("--record", default=None,
                        help="the recorded state of the fleet (default: "
                             "tests/account_scope_fleet_ratchet.yml beside this program)")
    parser.add_argument("--only", default=None, help="check one repository and no other")
    parser.add_argument("--baseline", action="store_true",
                        help="report the raw verdict for every repository and exit "
                             "non-zero if any of them is red, ignoring the record. This "
                             "is how the packet's baseline was measured and how a reader "
                             "re-derives it without editing a file.")
    arguments = parser.parse_args(argv)

    repos_dir = os.path.abspath(arguments.repos_dir or os.path.dirname(here))
    scope_path = os.path.abspath(
        arguments.scope or os.path.join(os.path.dirname(repos_dir), SCOPE_FILE_NAME))
    record_path = os.path.abspath(
        arguments.record or os.path.join(here, "tests", "account_scope_fleet_ratchet.yml"))
    vendored_path = arguments.scope_table or os.path.join(
        here, "tests", "account_scope_fleet_scope.yml")

    # `EXIT_CONFIG`, and this used to be `EXIT_COULD_NOT_RUN`. Both are non-zero,
    # which is the part that was always right; they are not the same claim, and
    # the difference is that `tests/validate.sh` maps 78 to SKIP and maps 2 to
    # FAIL. So this branch was reporting, in the gate's own vocabulary, that kit's
    # TREE is defective because a FLEET has no `core` beside it — and
    # `EXIT_CONFIG`'s own docstring says that is the mistake it exists to prevent
    # ("a missing fleet is a SKIP in tests/validate.sh rather than a FAIL that
    # blames the tree for the machine"). Three lines below, the sibling branch
    # for a missing fleet directory does exactly that. So the two adjacent
    # conditions, both statements about the machine rather than about kit, were
    # reported in two different vocabularies, and only one of them named what it
    # could not do.
    #
    # WHAT THAT COST, measured, and it is the whole reason this is not a comment.
    # The gate's own fleet-adoption ceiling is proved green by
    # `tests/self_test.sh` breakage 59, which points `KIT_FLEET` at a fixture
    # fleet — a fixture is a directory of service repositories and nothing else,
    # so it has no `core` and this branch fired. The child gate exited 1 and the
    # recipe reported, in those words, that the adoption ceiling was NOT in force:
    #
    #     FAIL self_test: breakage 59: an UNADOPTED service copies the stack —
    #       green, and named — the gate went RED (exit 1), so the ceiling is not in force
    #            FAIL in-scope repositories  (every one declares its account-scoped surface)
    #              COULD NOT RUN: no account-scope checker at <fixture>/core/harness/
    #                account_scope_check.py. … this exit is 2, not 0.
    #
    # The ceiling was in force throughout, and the finding printed underneath it
    # was about a directory nobody shipped. That is the worst direction to be
    # wrong in: a red line that accuses an enforcement mechanism of not being
    # enforced, produced by an unrelated check that could not run at all.
    #
    # SKIP is not a quieter FAIL. It prints the same sentence, names what is
    # absent and where it was looked for, and is counted in the gate's skip
    # total — so "the account-scope contract was not exercised by this run" is on
    # the record instead of being indistinguishable from "the contract is broken".
    checker = os.path.join(repos_dir, CHECKER_RELPATH)
    if not os.path.isfile(checker):
        print(f"COULD NOT RUN: no account-scope checker at {checker}. The instrument this "
              f"gate exists to run is not on disk, so nothing below verified anything and "
              f"this exit is {EXIT_CONFIG}, not 0.", file=sys.stderr)
        return EXIT_CONFIG

    if not os.path.isdir(repos_dir):
        print(f"COULD NOT RUN: no fleet at {repos_dir}. Set --repos-dir, or KIT_FLEET.",
              file=sys.stderr)
        return EXIT_CONFIG

    # ---- the scope decision, and kit's vendored copy of its table ----------
    #
    # The DIRECTIVE is the authority. The vendored copy exists because a CI runner
    # that clones nine sibling repositories has no `moon` checkout, and a CI job
    # that cannot name the fleet has two choices: do not run, or guess. Not
    # running is this packet's own defect. So the copy is a derived cache with a
    # fingerprint, it is compared against the directive whenever the directive is
    # readable, and a disagreement is exit 2 rather than a quietly narrowed watch.
    if os.path.isfile(scope_path):
        names = read_in_scope(scope_path)
        scope_source = scope_path
    elif os.path.isfile(vendored_path):
        vendored = read_yaml(vendored_path, "vendored in-scope table")
        names = [str(item) for item in (vendored.get("inScope") or [])]
        scope_source = f"{vendored_path} (vendored — no {SCOPE_FILE_NAME} beside the fleet)"
        recorded_fingerprint = str(vendored.get("fingerprint") or "")
        if not names:
            print(f"COULD NOT RUN: {vendored_path} names no repository, so this run would "
                  f"check nothing and report a vacuous pass.", file=sys.stderr)
            return EXIT_COULD_NOT_RUN
        if recorded_fingerprint != scope_fingerprint(names):
            print(f"COULD NOT RUN: {vendored_path} records fingerprint "
                  f"{recorded_fingerprint or '(none)'} and its own list hashes to "
                  f"{scope_fingerprint(names)}. The file disagrees with itself, so the "
                  f"list it carries is not the list it claims.", file=sys.stderr)
            return EXIT_COULD_NOT_RUN
    else:
        print(f"COULD NOT RUN: no scope decision at {scope_path} and no vendored table at "
              f"{vendored_path}. Which repositories are in the MVP is a question this "
              f"runner refuses to answer by guessing, so it checked nothing.",
              file=sys.stderr)
        return EXIT_COULD_NOT_RUN

    if os.path.isfile(scope_path) and os.path.isfile(vendored_path):
        vendored_names = [str(item) for item in
                          (read_yaml(vendored_path, "vendored in-scope table")
                           .get("inScope") or [])]
        if vendored_names != names:
            print(f"COULD NOT RUN: kit's vendored in-scope table and {scope_path} "
                  f"disagree.\n  {SCOPE_FILE_NAME} says: {', '.join(names)}\n"
                  f"  {vendored_path} says: {', '.join(vendored_names) or '(nothing)'}\n"
                  f"  The directive is the authority; the vendored copy is what a machine "
                  f"with no `moon` checkout runs on. Re-derive the copy.",
                  file=sys.stderr)
            return EXIT_COULD_NOT_RUN

    # ---- BLINDNESS, FLEET-WIDE -------------------------------------------
    #
    # Zero repositories checked is not a pass; it is a pattern that matched
    # nothing, which in this repository's history has a name. This is the same
    # rule as `tests/validate.sh`'s refusal to report PASS for a `--only` that
    # selected no check, and the same rule as `templates/tier/skip-allowlist`'s
    # dead-entry rule: an instrument that found nothing has proved nothing, and a
    # green is the most expensive thing it could report.
    if not names:
        print(f"COULD NOT RUN: {scope_source} named no repository as in scope. Zero "
              f"repositories checked is not a pass.", file=sys.stderr)
        return EXIT_COULD_NOT_RUN

    if arguments.only:
        if arguments.only not in names:
            print(f"COULD NOT RUN: --only={arguments.only!r} names no repository "
                  f"{scope_source} puts in scope ({', '.join(names)}). A filter that "
                  f"selects nothing has verified nothing.", file=sys.stderr)
            return EXIT_COULD_NOT_RUN
        selected = [arguments.only]
    else:
        selected = list(names)

    record = load_record(record_path)

    print(f"SCOPE-READ: {scope_source} puts {len(names)} repositories in the MVP: "
          f"{', '.join(names)}")
    if scope_source != scope_path:
        print(f"SCOPE-FINGERPRINT: {scope_fingerprint(names)}")
    print(f"INSTRUMENT: {checker}")
    print(f"RECORD: {record_path} ({len(record['rows'])} row(s): "
          f"{len(names) - len(record['rows'])} missing)"
          + (" — NOT APPLIED (--baseline)" if arguments.baseline else ""))
    print()

    interpreter = sys.executable or "python3"
    rows: list = []
    for name in selected:
        repo = os.path.join(repos_dir, name)
        if not os.path.isdir(repo):
            print(f"COULD NOT RUN: {name} is in the scope decision and there is no "
                  f"checkout at {repo}. A repository that cannot be read is not a "
                  f"repository that passed.", file=sys.stderr)
            return EXIT_COULD_NOT_RUN
        row = check_one(name, repo, interpreter, checker)
        if arguments.baseline:
            row["state"] = "FAIL" if row["counts"]["failures"] else "OK"
            row["notes"] = [] if row["state"] == "OK" else [
                f"{row['counts']['failures']} failure(s) reported with the record not applied"]
            rows.append(row)
            continue
        recorded = record["rows"].get(name)
        if recorded is None:
            row["state"] = "UNRECORDED"
            row["notes"] = [
                f"{name} is in the scope decision and the record carries no row for it, so "
                f"this run proved nothing about it. A new in-scope repository needs a row "
                f"naming what it is expected to report."]
        else:
            row["notes"] = compare(row, recorded)
            # A `note:` is recorded prose about a repository, not a difference,
            # so it is printed on a row that MATCHES and never moves a verdict.
            # Printing it on every run and on every verdict would make it noise,
            # and a note nobody reads is a comment.
            row["note"] = recorded["note"]
            row["state"] = "OK" if not row["notes"] else "FAIL"
        rows.append(row)

    for line in render_table(rows):
        print(line)
    print()

    for row in rows:
        if row["state"] == "OK":
            if row.get("note"):
                print(f"{row['repo']}: OK — {row['note']}")
            continue
        print(f"{row['repo']}: {row['state']}")
        # `core`'s own findings first, each id once with its own message and the
        # number of rows that carry it, because the table's counts are a summary
        # and a summary is what a reader skims.
        seen: dict = {}
        for item in row["findings"]:
            if item.id.startswith(FLEET):
                continue
            seen.setdefault(item.id, [item.severity, item.message, 0])[2] += 1
        for identifier, (severity, message, count) in sorted(seen.items()):
            suffix = f"  (x{count} rows)" if count > 1 else ""
            print(f"    {severity.upper()} {identifier}{suffix}\n        {message}")
        for item in row["findings"]:
            if not item.id.startswith(FLEET):
                continue
            print(f"    {item.severity.upper()} {item.id}\n        {item.message}")
        for note in row["notes"]:
            print(f"    {note}")
        print()

    bad = [row for row in rows if row["state"] != "OK"]
    matched = len(rows) - len(bad)
    print(f"TALLY: {len(rows)} in-scope repositories checked — {matched} match their "
          f"recorded state exactly, {len(bad)} do not."
          + ("  (--baseline: the record was not applied, so `OK` means the checker exited 0."
             if arguments.baseline else ""))
    if bad:
        print("FAIL account-scope-fleet: " + "; ".join(
            f"{row['repo']} {row['state']}" for row in bad))
        return EXIT_FAIL
    if arguments.baseline:
        print("PASS account-scope-fleet: the checker exited 0 on every in-scope repository "
              "with the record not applied.")
        return EXIT_OK
    print("PASS account-scope-fleet: every in-scope repository reports exactly what "
          "account_scope_fleet_ratchet.yml records, in both directions.")
    return EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except CouldNotRun as exc:  # pragma: no cover — the paths above raise inline
        print(f"COULD NOT RUN: {exc}", file=sys.stderr)
        sys.exit(EXIT_COULD_NOT_RUN)